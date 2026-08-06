import Combine
import Foundation

@MainActor
final class SyncEngine: ObservableObject {
    enum Status: Equatable {
        case loading, synced, syncing, pending(Int), conflict, offline(String), failed(String)
        /// The user is not signed in; data is local-only and no network calls
        /// are attempted. Mutations are persisted to a separate local workspace
        /// so account-backed cached trips cannot be edited after sign-out.
        case localOnly
    }

    @Published private(set) var trip: SharedTripSnapshot?
    @Published private(set) var trips: [TripSummary] = []
    @Published private(set) var selectedTripID: Int?
    @Published private(set) var status: Status = .loading
    @Published private(set) var apiBaseURLText: String
    /// Mirrors the current Apple sign-in state for UI display. The source of
    /// truth is the keychain token read by ``APIClient``; this is updated via
    /// ``Notification.Name.appleSignInStateChanged``.
    @Published private(set) var isUserAuthenticated = false

    private let repository: SharedTripRepository
    private var apiClient: APIClient
    private let localMigrationStore: LocalTripMigrationStore
    private var foregroundPollingTask: Task<Void, Never>?
    private var authObserver: NSObjectProtocol?

    init(
        repository: SharedTripRepository,
        apiClient: APIClient? = nil,
        localMigrationStore: LocalTripMigrationStore = LocalTripMigrationStore(),
        authenticatedOverride: Bool? = nil
    ) {
        self.repository = repository
        self.apiClient = apiClient ?? APIClient()
        self.localMigrationStore = localMigrationStore
        apiBaseURLText = AppConfiguration.apiBaseURL()?.absoluteString ?? ""
        // Check the keychain directly at init time so we don't need to await
        // an actor call inside the synchronous initializer.
        isUserAuthenticated = authenticatedOverride ?? ((try? KeychainStore().accessToken()) != nil)
    }

    /// Whether the engine should avoid all network traffic. The user may still
    /// create and edit trips in the isolated local workspace.
    private var localOnly: Bool { !isUserAuthenticated }

    /// Starts listening for Apple sign-in state changes. When the user signs
    /// in, the engine transitions out of ``localOnly`` and replays any queued
    /// operations. When the user signs out, it returns to local-only mode.
    func observeAuthChanges() {
        guard authObserver == nil else { return }
        authObserver = NotificationCenter.default.addObserver(
            forName: .appleSignInStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let nowAuthed = await self.apiClient.isAuthenticated
                let becameAuthenticated = nowAuthed && !self.isUserAuthenticated
                self.isUserAuthenticated = nowAuthed
                if becameAuthenticated {
                    // The user just signed in: pull the latest server state and
                    // replay anything they created while offline.
                    await self.refresh()
                    await self.replayPendingOperations()
                    self.startForegroundSync()
                } else if !nowAuthed {
                    // Signed out: stop polling and isolate account-backed cache
                    // from the editable, signed-out local workspace.
                    self.stopForegroundSync()
                    self.activateLocalOnlyTrips()
                }
            }
        }
    }

    func bootstrap() async {
        do {
            let cached = try repository.cachedTrips()
            if localOnly {
                try activateLocalOnlyTrips(from: cached)
            } else {
                trip = selectedTripID.flatMap { id in cached.first { $0.id == id } } ?? cached.first
                selectedTripID = trip?.id
            }
        } catch {
            status = .failed("本机缓存无法读取。")
            return
        }
        if localOnly {
            // No token yet: the complete product remains available against the
            // local snapshots. Authentication only turns on cloud sync.
            status = .localOnly
            return
        }
        await refresh()
        await replayPendingOperations()
    }

    func refresh() async {
        guard !localOnly else { status = .localOnly; return }
        status = .syncing
        do {
            var summaries = try await apiClient.fetchTrips()
            let accountStartedEmpty = summaries.isEmpty
            if let pendingMigration = try localMigrationStore.pendingMigration() {
                if pendingMigration.source.id < 0 {
                    localMigrationStore.beginInitialImportBatch()
                    try await importLocalTrip(
                        pendingMigration,
                        serverTrips: summaries,
                        allowsExistingTrips: localMigrationStore.isInitialImportBatchActive
                    )
                    localMigrationStore.completeCurrentMigration()
                    summaries = try await apiClient.fetchTrips()
                } else {
                    // Discard legacy migration state created from an
                    // account-backed cache entry. Replaying it under a
                    // different account would copy data across accounts.
                    localMigrationStore.discardInvalidMigrationState()
                }
            }
            if !localMigrationStore.didFinishInitialImport {
                if accountStartedEmpty {
                    localMigrationStore.beginInitialImportBatch()
                }
                if localMigrationStore.isInitialImportBatchActive {
                    while let localTrip = try repository.cachedTrips().first(where: { cached in
                        cached.id < 0 && !summaries.contains(where: { $0.id == cached.id })
                    }) {
                        let migration = PendingLocalTripMigration(source: localTrip)
                        try localMigrationStore.save(migration)
                        try await importLocalTrip(migration, serverTrips: summaries, allowsExistingTrips: true)
                        localMigrationStore.completeCurrentMigration()
                        summaries = try await apiClient.fetchTrips()
                    }
                    localMigrationStore.markInitialImportFinished()
                } else {
                    // Either there is no local shared trip to claim, or this
                    // account already owns cloud trips. Never merge an
                    // unowned cache into a non-empty account implicitly.
                    localMigrationStore.markInitialImportFinished()
                }
            }
            trips = summaries
            if selectedTripID == nil || !summaries.contains(where: { $0.id == selectedTripID }) {
                selectedTripID = summaries.first?.id
            }
            await apiClient.setActiveTripID(selectedTripID)
            guard let selectedTripID else {
                trip = nil
                status = .synced
                return
            }
            if let snapshot = try await apiClient.fetchTrip(id: selectedTripID, afterVersion: trip?.id == selectedTripID ? trip?.version : nil) {
                trip = snapshot
                try repository.save(snapshot)
                try await queueConfirmedAIDraftCardsIfReady()
            }
            status = .synced
        } catch {
            if localMigrationStore.hasPendingMigration {
                status = trip == nil
                    ? .failed("本地数据同步失败，请重试。")
                    : .offline("本地数据等待同步，联网后会自动重试")
            } else {
                status = trip == nil ? .failed("无法加载共享行程") : .offline("离线浏览中")
            }
        }
    }

    /// Claims the pre-login shared snapshot for a brand-new account. The
    /// migration is persisted before the first request and is content-aware,
    /// so an interrupted import resumes without duplicating days, cards or
    /// expenses. LocalWalletItem is deliberately outside this data path.
    private func importLocalTrip(
        _ storedMigration: PendingLocalTripMigration,
        serverTrips: [TripSummary],
        allowsExistingTrips: Bool = false
    ) async throws {
        var migration = storedMigration
        let targetTripID: Int
        if let existingTarget = migration.targetTripID {
            guard serverTrips.isEmpty || serverTrips.contains(where: { $0.id == existingTarget }) else {
                throw LocalTripMigrationError.accountMismatch
            }
            targetTripID = existingTarget
        } else {
            guard serverTrips.isEmpty || allowsExistingTrips else { throw LocalTripMigrationError.accountMismatch }
            let source = migration.source
            let created = try await apiClient.createTrip(
                TripPatchRequest(
                    destination: source.destination,
                    startDate: source.startDate,
                    endDate: source.endDate,
                    currency: source.currency
                ),
                idempotencyKey: migration.createIdempotencyKey
            )
            migration.targetTripID = created.id
            try localMigrationStore.save(migration)
            targetTripID = created.id
        }

        selectedTripID = targetTripID
        await apiClient.setActiveTripID(targetTripID)
        guard var remote = try await apiClient.fetchTrip(id: targetTripID, afterVersion: nil) else {
            throw LocalTripMigrationError.missingCreatedTrip
        }

        remote = try await importLocalDays(migration.source.days, into: remote)
        remote = try await importLocalCards(migration.source.days, into: remote)
        remote = try await importLocalExpenses(migration.source.expenses, sourceDays: migration.source.days, into: remote)

        // Only now is the old optimistic queue redundant. Removing it before
        // the full snapshot lands would risk losing unsynced local edits.
        try repository.discardOperations(for: migration.source.id)
        if migration.source.id != targetTripID {
            try repository.removeCachedTrip(id: migration.source.id)
        }
        trip = remote
        try repository.save(remote)
        try await queueConfirmedAIDraftCardsIfReady()
    }

    private func importLocalDays(_ localDays: [TripDaySnapshot], into initialRemote: SharedTripSnapshot) async throws -> SharedTripSnapshot {
        var remote = initialRemote
        var version = remote.version
        let existingDates = Set(remote.days.map(\.date))
        for day in localDays.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) where !existingDates.contains(day.date) {
            version = try await sendMigrationWrite(
                path: "/v1/days",
                request: DayRequest(date: day.date, position: day.position),
                tripID: remote.id,
                baseVersion: version
            )
        }
        if version != remote.version {
            remote = try await requireTripSnapshot(id: remote.id)
        }
        return remote
    }

    private func importLocalCards(_ localDays: [TripDaySnapshot], into initialRemote: SharedTripSnapshot) async throws -> SharedTripSnapshot {
        var remote = initialRemote
        var version = remote.version
        var remoteCounts = Self.cardCounts(in: remote)

        for localDay in localDays.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
            guard let remoteDay = remote.days.first(where: { $0.date == localDay.date }),
                  let remoteDayID = remoteDay.serverID else { throw LocalTripMigrationError.missingImportedDay }
            for card in localDay.cards.sorted(by: Self.cardTimeOrder) {
                let fingerprint = MigrationCardFingerprint(day: localDay.date, card: card)
                if remoteCounts[fingerprint, default: 0] > 0 {
                    remoteCounts[fingerprint, default: 0] -= 1
                    continue
                }
                version = try await sendMigrationWrite(
                    path: "/v1/cards",
                    request: Self.migrationCardRequest(card, dayID: remoteDayID),
                    tripID: remote.id,
                    baseVersion: version
                )
            }
        }
        if version != remote.version {
            remote = try await requireTripSnapshot(id: remote.id)
        }
        return remote
    }

    private func importLocalExpenses(
        _ localExpenses: [ExpenseSnapshot],
        sourceDays: [TripDaySnapshot],
        into initialRemote: SharedTripSnapshot
    ) async throws -> SharedTripSnapshot {
        var remote = initialRemote
        var version = remote.version
        let cardIDMap = Self.migratedCardIDMap(sourceDays: sourceDays, remote: remote)
        var remoteCounts = Self.expenseCounts(in: remote)

        for expense in localExpenses.sorted(by: { ($0.occurredOn, $0.updatedAt) < ($1.occurredOn, $1.updatedAt) }) {
            let migratedCardID = expense.cardID.flatMap { cardIDMap[$0] }
            let fingerprint = MigrationExpenseFingerprint(expense: expense, cardID: migratedCardID)
            if remoteCounts[fingerprint, default: 0] > 0 {
                remoteCounts[fingerprint, default: 0] -= 1
                continue
            }
            version = try await sendMigrationWrite(
                path: "/v1/expenses",
                request: ExpenseRequest(
                    amountMinor: expense.amountMinor,
                    currency: expense.currency,
                    category: expense.category,
                    paidBy: expense.paidBy,
                    splitMode: expense.splitMode,
                    occurredOn: expense.occurredOn,
                    note: expense.note,
                    cardID: migratedCardID
                ),
                tripID: remote.id,
                baseVersion: version
            )
        }
        if version != remote.version {
            remote = try await requireTripSnapshot(id: remote.id)
        }
        return remote
    }

    private func sendMigrationWrite<Request: Encodable & Sendable>(
        path: String,
        request: Request,
        tripID: Int,
        baseVersion: Int
    ) async throws -> Int {
        let body = try await apiClient.encode(request)
        let payload = PendingOperationPayload(
            method: "POST",
            path: path,
            tripID: tripID,
            body: body,
            baseVersion: baseVersion,
            idempotencyKey: UUID()
        )
        return try await apiClient.send(payload, tripID: tripID).tripVersion
    }

    private func requireTripSnapshot(id: Int) async throws -> SharedTripSnapshot {
        guard let snapshot = try await apiClient.fetchTrip(id: id, afterVersion: nil) else {
            throw LocalTripMigrationError.missingCreatedTrip
        }
        return snapshot
    }

    func selectTrip(_ id: Int) async {
        guard id != selectedTripID else { return }
        selectedTripID = id
        await apiClient.setActiveTripID(id)
        do { trip = try repository.cachedTrip(id: id) } catch { trip = nil }
        if localOnly {
            status = .localOnly
            return
        }
        await refresh()
    }

    func createShareInvite() async -> URL? {
        guard let selectedTripID else {
            status = .failed("请先创建一个旅程。")
            return nil
        }
        guard trips.first(where: { $0.id == selectedTripID })?.canShare == true else {
            status = .failed("只有行程创建者可以创建邀请。")
            return nil
        }
        do {
            let invite = try await apiClient.createInvite(for: selectedTripID)
            return try await apiClient.inviteLandingURL(token: invite.token)
        } catch {
            status = .failed("无法创建共享邀请。")
            return nil
        }
    }

    func fetchTripMembers() async throws -> [TripMemberSummary] {
        guard !localOnly, let selectedTripID else {
            throw TripSharingError.requiresSignIn
        }
        return try await apiClient.fetchTripMembers(for: selectedTripID)
    }

    func joinTrip(inviteToken: String) async -> Bool {
        guard !localOnly else { return false }
        do {
            let joined = try await apiClient.joinTrip(inviteToken: inviteToken)
            // The request may have completed after the user signed out. The
            // server already accepted the invite, but account-backed state must
            // not leak back into the isolated local workspace.
            guard !localOnly else { return true }
            if !trips.contains(where: { $0.id == joined.id }) { trips.insert(joined, at: 0) }
            selectedTripID = joined.id
            await apiClient.setActiveTripID(joined.id)
            trip = nil
            await refresh()
            return true
        } catch {
            status = .failed("无法加入共享旅程。请确认邀请仍有效。")
            return false
        }
    }

    func createTrip(destination: String, startDate: Date, endDate: Date, currency: String) async {
        let request = TripPatchRequest(
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: Self.dayFormatter.string(from: startDate),
            endDate: Self.dayFormatter.string(from: endDate),
            currency: currency.uppercased()
        )
        if localOnly {
            do {
                let snapshot = SharedTripSnapshot(
                    id: try repository.nextLocalTripID(),
                    destination: request.destination,
                    startDate: request.startDate,
                    endDate: request.endDate,
                    currency: request.currency,
                    version: 0,
                    updatedAt: .now,
                    days: []
                )
                try repository.save(snapshot)
                trip = snapshot
                selectedTripID = snapshot.id
                await apiClient.setActiveTripID(snapshot.id)
                updateLocalSummary(for: snapshot)
                status = .localOnly
            } catch {
                status = .failed("无法创建本地旅程。")
            }
            return
        }
        do {
            let created = try await apiClient.createTrip(request)
            selectedTripID = created.id
            await apiClient.setActiveTripID(created.id)
            trips.insert(created, at: 0)
            trip = nil
            await refresh()
        } catch {
            status = .failed("无法创建旅程。")
        }
    }

    func saveSetup(destination: String, startDate: Date, endDate: Date, currency: String) async {
        if let current = trip, !current.expenses.isEmpty, current.currency?.uppercased() != currency.uppercased() {
            status = .failed("已有支出记录，不能变更行程币种。")
            return
        }
        let formatter = Self.dayFormatter
        let request = TripPatchRequest(
            destination: destination.trimmingCharacters(in: .whitespacesAndNewlines),
            startDate: formatter.string(from: startDate),
            endDate: formatter.string(from: endDate),
            currency: currency.uppercased()
        )
        if localOnly, var current = trip {
            current.destination = request.destination
            current.startDate = request.startDate
            current.endDate = request.endDate
            current.currency = request.currency
            current.updatedAt = .now
            do { try saveLocalSnapshot(current) } catch { status = .failed("无法保存本地修改。") }
            return
        }
        await enqueueTripPatch(request)
    }

    func addDay(_ date: Date) async {
        guard var current = trip else { return }
        let stringDate = Self.dayFormatter.string(from: date)
        guard !current.days.contains(where: { $0.date == stringDate }) else { return }
        let request = DayRequest(date: stringDate, position: current.days.count)
        do {
            current.days.append(TripDaySnapshot(date: stringDate, position: current.days.count))
            current.updatedAt = .now
            if localOnly {
                try saveLocalSnapshot(current)
                return
            }
            let body = try await apiClient.encode(request)
            trip = current
            try repository.save(current)
            try repository.enqueue(method: "POST", path: "/v1/days", tripID: current.id, body: body, baseVersion: current.version)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存本地修改。")
        }
    }

    func retry() async {
        guard !localOnly else { status = .localOnly; return }
        await refresh()
        await replayPendingOperations()
    }

    private static func localSummary(for snapshot: SharedTripSnapshot) -> TripSummary {
        TripSummary(
            id: snapshot.id,
            destination: snapshot.destination,
            startDate: snapshot.startDate,
            endDate: snapshot.endDate,
            currency: snapshot.currency,
            version: snapshot.version,
            updatedAt: snapshot.updatedAt,
            role: "owner",
            joinedAt: snapshot.updatedAt
        )
    }

    private func activateLocalOnlyTrips() {
        do {
            try activateLocalOnlyTrips(from: repository.cachedTrips())
            status = .localOnly
        } catch {
            trip = nil
            trips = []
            selectedTripID = nil
            status = .failed("本机缓存无法读取。")
        }
    }

    private func activateLocalOnlyTrips(from cached: [SharedTripSnapshot]) throws {
        var localTrips = cached.filter { $0.id < 0 }
        if localTrips.isEmpty {
            let placeholder = SharedTripSnapshot(
                id: try repository.nextLocalTripID(),
                destination: nil,
                startDate: nil,
                endDate: nil,
                currency: nil,
                version: 0,
                updatedAt: .now,
                days: []
            )
            try repository.save(placeholder)
            localTrips = [placeholder]
        }
        let selectedLocal = selectedTripID.flatMap { id in localTrips.first { $0.id == id } } ?? localTrips.first
        trip = selectedLocal
        selectedTripID = selectedLocal?.id
        trips = localTrips.map(Self.localSummary(for:))
    }

    private func updateLocalSummary(for snapshot: SharedTripSnapshot) {
        let summary = Self.localSummary(for: snapshot)
        if let index = trips.firstIndex(where: { $0.id == snapshot.id }) {
            trips[index] = summary
        } else {
            trips.insert(summary, at: 0)
        }
    }

    private func saveLocalSnapshot(_ snapshot: SharedTripSnapshot) throws {
        trip = snapshot
        try repository.save(snapshot)
        updateLocalSummary(for: snapshot)
        status = .localOnly
    }

    /// Creates a temporary draft only. The caller keeps the original text in
    /// the sheet state; neither the input nor the response is saved here.
    /// Runs one stateless turn of the conversational itinerary chat. The caller
    /// owns the message history and replays it each turn; the response carries
    /// the assistant reply and the latest batch of proposed cards. Existing
    /// cards are sent as read-only context. Nothing is persisted here until the
    /// caller confirms selected cards via `importAIDraft`.
    func sendItineraryChat(messages: [AIItineraryChatRequest.Message], preferences: String?, images: [String]? = nil) async throws -> AIItineraryChatResult {
        guard let trip, let startDate = trip.startDate,
              let start = Self.dayFormatter.date(from: startDate),
              let endDate = trip.endDate, let end = Self.dayFormatter.date(from: endDate) else {
            throw AIDraftImportError.tripNotConfigured
        }
        let calendar = Calendar(identifier: .gregorian)
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? -1) + 1
        guard days > 0 else { throw AIDraftImportError.tripNotConfigured }
        return try await apiClient.itineraryChat(AIItineraryChatRequest(
            messages: messages,
            startDate: startDate,
            days: days,
            destination: Self.nonEmptyTrimmed(trip.destination),
            preferences: preferences?.trimmingCharacters(in: .whitespacesAndNewlines),
            images: images?.isEmpty == true ? nil : images,
            existingItinerary: existingItinerarySnapshot()
        ))
    }

    /// Streaming variant of ``sendItineraryChat``. Returns an async stream of
    /// reply deltas and a final validated result, so the chat view can render
    /// the assistant reply as it is generated. The same trip-config guard and
    /// request shape as the non-streaming call apply.
    func streamItineraryChat(messages: [AIItineraryChatRequest.Message], preferences: String?, images: [String]? = nil) async throws -> AsyncThrowingStream<AIItineraryChatStreamEvent, Error> {
        guard let trip, let startDate = trip.startDate,
              let start = Self.dayFormatter.date(from: startDate),
              let endDate = trip.endDate, let end = Self.dayFormatter.date(from: endDate) else {
            throw AIDraftImportError.tripNotConfigured
        }
        let calendar = Calendar(identifier: .gregorian)
        let days = (calendar.dateComponents([.day], from: start, to: end).day ?? -1) + 1
        guard days > 0 else { throw AIDraftImportError.tripNotConfigured }
        return try await apiClient.itineraryChatStream(AIItineraryChatRequest(
            messages: messages,
            startDate: startDate,
            days: days,
            destination: Self.nonEmptyTrimmed(trip.destination),
            preferences: preferences?.trimmingCharacters(in: .whitespacesAndNewlines),
            images: images?.isEmpty == true ? nil : images,
            existingItinerary: existingItinerarySnapshot()
        ))
    }

    private static func nonEmptyTrimmed(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// Display, routing, and AI context must agree on chronological order.
    /// Legacy/Agent-created cards can share the same `position`, so position
    /// is only a stable tiebreaker after the itinerary start time.
    private static func cardTimeOrder(_ left: TravelCardSnapshot, _ right: TravelCardSnapshot) -> Bool {
        if left.startAt != right.startAt { return left.startAt < right.startAt }
        if left.position != right.position { return left.position < right.position }
        return left.title.localizedStandardCompare(right.title) == .orderedAscending
    }

    /// Compact, read-only snapshot of the trip's current cards, sent so the AI
    /// can enrich rather than duplicate what is already planned.
    private func existingItinerarySnapshot() -> [AIExistingItineraryDay]? {
        guard let trip else { return nil }
        let days = trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }.map { day in
            AIExistingItineraryDay(
                date: day.date,
                cards: day.cards.sorted(by: Self.cardTimeOrder).map { card in
                    AIExistingItineraryCard(
                        kind: card.kind.rawValue,
                        title: card.title,
                        time: Self.cardTimeFormatter.string(from: card.startAt),
                        place: card.place?.name,
                        notes: card.notes
                    )
                }
            )
        }
        return days.isEmpty ? nil : days
    }

    /// Reads a public Xiaohongshu note server-side and returns a single card
    /// draft. Like the itinerary draft, nothing is persisted here: the caller
    /// fills the card editor and saves via the normal card queue.
    func importCardFromLink(url: String) async throws -> LinkImportResult {
        return try await apiClient.importFromLink(LinkImportRequest(url: url))
    }

    /// 卡包照片录入：把一张照片交给服务端 AI 识别，返回标签、号码、备注与类型。
    /// 结果不落库、不写共享行程；由卡包编辑器按需填入并加密保存到本机。
    func scanWalletCard(image: String, styleHint: String) async throws -> WalletCardScanResult {
        // The scanned result is never persisted to the shared trip — the
        // wallet itself remains local-only regardless of auth state.
        return try await apiClient.scanWalletCard(WalletCardScanRequest(image: image, styleHint: styleHint))
    }

    /// 备忘智能助手：把当前共享行程脱敏后交给后端 AI，让其针对「明日」的安排给出
    /// 闹钟、提醒事项和物品建议。不落库、不写共享行程，结果由备忘页按需一键落地。
    func createMemoAssist() async throws -> MemoAssistResult {
        guard let trip else { throw MemoAssistError.tripNotConfigured }
        let itinerary = MemoAssistRequest.Itinerary(
            destination: trip.destination,
            startDate: trip.startDate,
            endDate: trip.endDate,
            currency: trip.currency,
            days: trip.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }.map { day in
                MemoAssistRequest.Day(
                    date: day.date,
                    cards: day.cards.sorted(by: Self.cardTimeOrder).map { card in
                        MemoAssistRequest.Card(
                            kind: card.kind.rawValue,
                            title: card.title,
                            startAt: card.startAt,
                            endAt: card.endAt,
                            place: card.place?.name,
                            fromAirport: card.fromAirport,
                            toAirport: card.toAirport,
                            notes: card.notes
                        )
                    }
                )
            }
        )
        let tomorrow = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: .now) ?? .now
        let request = MemoAssistRequest(itinerary: itinerary, tomorrowDate: Self.dayFormatter.string(from: tomorrow))
        return try await apiClient.createMemoAssist(request)
    }

    /// 扫小票/对话生成一笔实际价支出草案。客户端持有对话历史每轮重放；服务端不落库。
    func createAIExpenseDraft(dayDate: String, messages: [AIExpenseConversationRequest.Message], images: [String]? = nil) async throws -> AIExpenseDraft {
        return try await apiClient.createExpenseDraft(AIExpenseConversationRequest(
            dayDate: dayDate,
            currency: trip?.currency,
            messages: messages,
            images: images?.isEmpty == true ? nil : images
        ))
    }

    /// Confirmed AI cards use the existing day/card queue. Cards whose target
    /// day is still offline are locally held without the source text, then
    /// converted to ordinary POST /v1/cards operations after that day syncs.
    func importAIDraft(_ draft: AIItineraryDraft) async throws {
        guard let trip, let startDate = trip.startDate,
              let start = Self.dayFormatter.date(from: startDate),
              let endDate = trip.endDate, let end = Self.dayFormatter.date(from: endDate) else {
            throw AIDraftImportError.tripNotConfigured
        }
        let days = (Calendar(identifier: .gregorian).dateComponents([.day], from: start, to: end).day ?? -1) + 1
        if let message = draft.validationMessage(startDate: startDate, days: days) {
            throw AIDraftImportError.invalidDraft(message)
        }
        let selected = draft.selectedCards
        try repository.queueConfirmedAIDraftCards(selected)
        let targetDates = Set(selected.map(\.date))
        for date in targetDates where !(self.trip?.days.contains { $0.date == date } ?? false) {
            guard let parsed = Self.dayFormatter.date(from: date) else { throw AIDraftImportError.invalidDraft("日期格式无效。") }
            await addDay(parsed)
        }
        try await queueConfirmedAIDraftCardsIfReady()
        await replayPendingOperations()
        if case .failed(let message) = status {
            throw AIDraftImportError.submissionFailed(message)
        }
    }

    func startForegroundSync() {
        guard !localOnly else { return }
        guard foregroundPollingTask == nil else { return }
        foregroundPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.retry()
            }
        }
    }

    func stopForegroundSync() {
        foregroundPollingTask?.cancel()
        foregroundPollingTask = nil
    }

    func updateAPIBaseURL(_ value: String) -> String? {
        guard let url = AppConfiguration.saveAPIBaseURL(value) else {
            return AppConfiguration.apiBaseURLValidationMessage(for: value)
                ?? "无法保存 API 地址。"
        }
        apiClient = APIClient(baseURL: url)
        apiBaseURLText = url.absoluteString
        return nil
    }

    func updateDay(_ day: TripDaySnapshot, date: Date) async {
        guard let current = trip else { return }
        let newDate = Self.dayFormatter.string(from: date)
        guard newDate != day.date, !current.days.contains(where: { $0.date == newDate }) else { return }
        if localOnly {
            var updated = current
            guard let index = updated.days.firstIndex(where: { $0.id == day.id }) else { return }
            updated.days[index].date = newDate
            updated.days[index].updatedAt = .now
            updated.updatedAt = .now
            do { try saveLocalSnapshot(updated) } catch { status = .failed("无法保存本地修改。") }
            return
        }
        guard let dayID = day.serverID else { return }
        let request = DayRequest(date: newDate, position: day.position)
        await queueDayMutation(method: "PATCH", path: "/v1/days/\(dayID)", request: request) { snapshot in
            guard let index = snapshot.days.firstIndex(where: { $0.id == day.id }) else { return }
            snapshot.days[index].date = newDate
            snapshot.days[index].updatedAt = .now
        }
    }

    func deleteDay(_ day: TripDaySnapshot) async {
        if localOnly, var current = trip {
            current.days.removeAll { $0.id == day.id }
            for index in current.days.indices { current.days[index].position = index }
            current.updatedAt = .now
            do { try saveLocalSnapshot(current) } catch { status = .failed("无法保存本地修改。") }
            return
        }
        guard let dayID = day.serverID else { return }
        await queueDayMutation(method: "DELETE", path: "/v1/days/\(dayID)", request: EmptyRequest()) { snapshot in
            snapshot.days.removeAll { $0.id == day.id }
        }
    }

    func moveDay(_ day: TripDaySnapshot, direction: Int) async {
        guard var current = trip, localOnly || day.serverID != nil else { return }
        let sorted = current.days.sorted { ($0.date, $0.position) < ($1.date, $1.position) }
        guard let oldIndex = sorted.firstIndex(where: { $0.id == day.id }) else { return }
        let newIndex = oldIndex + direction
        guard sorted.indices.contains(newIndex) else { return }
        if !localOnly {
            guard sorted[oldIndex].serverID != nil, sorted[newIndex].serverID != nil else { return }
        }

        var reordered = sorted
        reordered.swapAt(oldIndex, newIndex)
        for index in reordered.indices { reordered[index].position = index }
        current.days = reordered
        trip = current
        do {
            if localOnly {
                try saveLocalSnapshot(current)
                return
            }
            try repository.save(current)
            for changedDay in reordered where changedDay.serverID != nil {
                let body = try await apiClient.encode(DayRequest(date: changedDay.date, position: changedDay.position))
                try repository.enqueue(method: "PATCH", path: "/v1/days/\(changedDay.serverID!)", tripID: current.id, body: body, baseVersion: current.version)
            }
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存日期顺序。")
        }
    }

    func addCard(to day: TripDaySnapshot, request: CardRequest) async {
        guard var current = trip,
              let index = current.days.firstIndex(where: { $0.id == day.id }) else { return }
        guard localOnly || day.serverID != nil else { return }
        let dayID = day.serverID ?? Self.takeLocalResourceID()
        let baseVersion = current.version
        do {
            let card = TravelCardSnapshot(
                dayID: dayID,
                kind: request.kind ?? .activity,
                title: request.title ?? "未命名行程",
                startAt: Self.parseTimestamp(request.startAt) ?? .now,
                endAt: Self.parseTimestamp(request.endAt),
                place: Self.optimisticPlace(from: request.place),
                bookingCode: request.bookingCode,
                url: request.url,
                description: request.description,
                fromAirport: request.fromAirport,
                toAirport: request.toAirport,
                priceMinor: request.priceMinor,
                actualPriceMinor: request.actualPriceMinor,
                ticketPriceMinor: request.ticketPriceMinor,
                stayDurationMinutes: request.stayDurationMinutes,
                tips: request.tips,
                images: request.images,
                notes: request.notes,
                position: request.position ?? (current.days.first(where: { $0.id == day.id })?.cards.count ?? 0)
            )
            current.days[index].cards.append(card)
            current.updatedAt = .now
            if localOnly {
                try saveLocalSnapshot(current)
                return
            }
            let body = try await apiClient.encode(request)
            trip = current
            try repository.save(current)
            try repository.enqueue(method: "POST", path: "/v1/cards", tripID: current.id, body: body, baseVersion: baseVersion)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存行程卡片。")
        }
    }

    func updateCard(_ card: TravelCardSnapshot, request: CardRequest) async {
        if localOnly, var current = trip {
            Self.apply(request, to: card, in: &current)
            current.updatedAt = .now
            do { try saveLocalSnapshot(current) } catch { status = .failed("无法保存行程卡片。") }
            return
        }
        guard let cardID = card.serverID else { return }
        await queueCardMutation(method: "PATCH", path: "/v1/cards/\(cardID)", request: request) { snapshot in
            Self.apply(request, to: card, in: &snapshot)
        }
    }

    func deleteCard(_ card: TravelCardSnapshot) async {
        if localOnly, var current = trip {
            for index in current.days.indices {
                current.days[index].cards.removeAll { $0.id == card.id }
            }
            current.updatedAt = .now
            do { try saveLocalSnapshot(current) } catch { status = .failed("无法保存行程卡片。") }
            return
        }
        guard let cardID = card.serverID else { return }
        await queueCardMutation(method: "DELETE", path: "/v1/cards/\(cardID)", request: EmptyRequest()) { snapshot in
            for index in snapshot.days.indices {
                snapshot.days[index].cards.removeAll { $0.id == card.id }
            }
        }
    }

    func addExpense(_ request: ExpenseRequest) async {
        guard var current = trip, let currency = current.currency, request.currency == currency,
              let amountMinor = request.amountMinor, let category = request.category,
              let occurredOn = request.occurredOn else {
            status = .failed("请先设置行程币种，并填写完整支出。")
            return
        }
        let baseVersion = current.version
        do {
            let body = try await apiClient.encode(request)
            let expense = ExpenseSnapshot(amountMinor: amountMinor, currency: currency, category: category, occurredOn: occurredOn, note: request.note, cardID: request.cardID)
            current.expenses.append(expense)
            trip = current
            try repository.save(current)
            try repository.enqueue(method: "POST", path: "/v1/expenses", tripID: current.id, body: body, baseVersion: baseVersion, clientEntityID: expense.id)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存支出。")
        }
    }

    func updateExpense(_ expense: ExpenseSnapshot, request: ExpenseRequest) async {
        guard let expenseID = expense.serverID else {
            await updatePendingExpense(expense, request: request)
            return
        }
        await queueExpenseMutation(method: "PATCH", path: "/v1/expenses/\(expenseID)", request: request) { snapshot in
            guard let index = snapshot.expenses.firstIndex(where: { $0.id == expense.id }) else { return }
            snapshot.expenses[index] = ExpenseOptimisticMutation.applying(request, to: snapshot.expenses[index])
        }
    }

    func deleteExpense(_ expense: ExpenseSnapshot) async {
        guard let expenseID = expense.serverID else {
            await cancelPendingExpense(expense)
            return
        }
        await queueExpenseMutation(method: "DELETE", path: "/v1/expenses/\(expenseID)", request: EmptyRequest()) { snapshot in
            snapshot.expenses = ExpenseOptimisticMutation.removing(expense, from: snapshot.expenses)
        }
    }

    func moveCard(_ card: TravelCardSnapshot, in day: TripDaySnapshot, direction: Int) async {
        guard var current = trip, localOnly || card.serverID != nil,
              let dayIndex = current.days.firstIndex(where: { $0.id == day.id }) else { return }
        var cards = current.days[dayIndex].cards.sorted(by: Self.cardTimeOrder)
        guard let oldIndex = cards.firstIndex(where: { $0.id == card.id }) else { return }
        let newIndex = oldIndex + direction
        guard cards.indices.contains(newIndex) else { return }
        if !localOnly {
            guard cards[oldIndex].serverID != nil, cards[newIndex].serverID != nil else { return }
        }
        cards.swapAt(oldIndex, newIndex)
        for index in cards.indices { cards[index].position = index }
        current.days[dayIndex].cards = cards
        trip = current
        do {
            if localOnly {
                try saveLocalSnapshot(current)
                return
            }
            try repository.save(current)
            for changedCard in cards {
                guard let serverID = changedCard.serverID else { continue }
                let body = try await apiClient.encode(CardRequest(position: changedCard.position))
                try repository.enqueue(method: "PATCH", path: "/v1/cards/\(serverID)", tripID: current.id, body: body, baseVersion: current.version)
            }
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存卡片顺序。")
        }
    }

    private func enqueueTripPatch(_ request: TripPatchRequest) async {
        let baseVersion = trip?.version ?? 0
        do {
            let body = try await apiClient.encode(request)
            guard let activeTripID = selectedTripID ?? trip?.id else {
                status = .failed("请先选择一个旅程。")
                return
            }
            let now = Date()
            var current = trip ?? SharedTripSnapshot(id: activeTripID, destination: nil, startDate: nil, endDate: nil, currency: nil, version: 0, updatedAt: now, days: [], expenses: [])
            current.destination = request.destination
            current.startDate = request.startDate
            current.endDate = request.endDate
            current.currency = request.currency
            current.updatedAt = now
            trip = current
            try repository.save(current)
            try repository.enqueue(method: "PATCH", path: "/v1/trip", tripID: current.id, body: body, baseVersion: baseVersion)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存本地修改。")
        }
    }

    private func replayPendingOperations() async {
        guard !localOnly else { return }
        do {
            let operations = try repository.pendingOperations()
            guard !operations.isEmpty else { return }
            var encounteredConflict = false
            status = .pending(operations.count)
            for operation in operations {
                do {
                    let activeTripID = operation.tripID
                    let meta = try await apiClient.send(operation.payload, tripID: activeTripID)
                    try repository.remove(operation)
                    try repository.removeConfirmedAIDraftCard(for: operation.clientEntityID)
                    await refresh()
                    if meta.conflict == true {
                        encounteredConflict = true
                    }
                } catch let problem as APIProblem where problem.code == "not_found" {
                    if operation.clientEntityID != nil {
                        // An AI card may be waiting on a day that a
                        // collaborator removed. Retain the editable draft and
                        // stop automatic retries instead of silently dropping it.
                        try repository.markTerminal(operation, message: problem.message)
                        status = .failed(problem.message)
                        return
                    }
                    // A collaborator may have deleted a card while its editor was open.
                    // Discard the stale intent and refresh instead of re-creating it locally.
                    try repository.remove(operation)
                    await refresh()
                    let resource = operation.path.contains("/expenses") ? "支出" : "行程卡片"
                    status = .failed("该\(resource)已在另一台设备删除，已刷新行程。")
                    return
                } catch let problem as APIProblem where problem.isPermanentClientFailure {
                    // A 4xx means this exact request will not become valid by
                    // retrying in the background. Keep it local for context,
                    // surface the message, and wait for an explicit user edit.
                    try repository.markTerminal(operation, message: problem.message)
                    status = .failed(problem.message)
                    return
                } catch {
                    try repository.incrementRetry(operation)
                    status = encounteredConflict ? .conflict : .offline("有 \(operations.count) 项待同步")
                    return
                }
            }
            let remaining = try repository.pendingOperations()
            if !remaining.isEmpty {
                // A just-synced AI day may have released normal card writes.
                // Replay the new regular operations using their own keys.
                await replayPendingOperations()
                return
            }
            status = encounteredConflict ? .conflict : .synced
        } catch {
            status = .failed("待同步队列无法读取。")
        }
    }

    private func queueDayMutation<Request: Encodable & Sendable>(method: String, path: String, request: Request, optimisticUpdate: (inout SharedTripSnapshot) -> Void) async {
        guard var current = trip else { return }
        let baseVersion = current.version
        do {
            let body = try await apiClient.encode(request)
            optimisticUpdate(&current)
            current.updatedAt = .now
            trip = current
            try repository.save(current)
            try repository.enqueue(method: method, path: path, tripID: current.id, body: body, baseVersion: baseVersion)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存本地修改。")
        }
    }

    private func queueCardMutation<Request: Encodable & Sendable>(method: String, path: String, request: Request, optimisticUpdate: (inout SharedTripSnapshot) -> Void) async {
        guard var current = trip else { return }
        let baseVersion = current.version
        do {
            let body = try await apiClient.encode(request)
            optimisticUpdate(&current)
            current.updatedAt = .now
            trip = current
            try repository.save(current)
            try repository.enqueue(method: method, path: path, tripID: current.id, body: body, baseVersion: baseVersion)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存行程卡片。")
        }
    }

    private func queueExpenseMutation<Request: Encodable & Sendable>(method: String, path: String, request: Request, optimisticUpdate: (inout SharedTripSnapshot) -> Void) async {
        guard var current = trip else { return }
        let baseVersion = current.version
        do {
            let body = try await apiClient.encode(request)
            optimisticUpdate(&current)
            current.updatedAt = .now
            trip = current
            try repository.save(current)
            try repository.enqueue(method: method, path: path, tripID: current.id, body: body, baseVersion: baseVersion)
            await replayPendingOperations()
        } catch {
            status = .failed("无法保存支出。")
        }
    }

    private func updatePendingExpense(_ expense: ExpenseSnapshot, request: ExpenseRequest) async {
        guard var current = trip else { return }
        do {
            guard let operation = try repository.pendingOperation(for: expense.id), operation.method == "POST", operation.path == "/v1/expenses" else {
                status = .failed("这笔离线支出正在确认服务器结果，请稍后重试。")
                return
            }
            let body = try await apiClient.encode(request)
            guard let index = current.expenses.firstIndex(where: { $0.id == expense.id }) else { return }
            current.expenses[index] = ExpenseOptimisticMutation.applying(request, to: current.expenses[index])
            trip = current
            try repository.save(current)
            // The create has not received a response, so preserving its key keeps one server mutation.
            try repository.replaceBody(operation, with: body)
            await replayPendingOperations()
        } catch {
            status = .failed("无法更新离线支出。")
        }
    }

    private func cancelPendingExpense(_ expense: ExpenseSnapshot) async {
        guard var current = trip else { return }
        do {
            guard let operation = try repository.pendingOperation(for: expense.id), operation.method == "POST", operation.path == "/v1/expenses" else {
                status = .failed("这笔离线支出正在确认服务器结果，请稍后重试。")
                return
            }
            current.expenses = ExpenseOptimisticMutation.removing(expense, from: current.expenses)
            trip = current
            try repository.save(current)
            try repository.remove(operation)
            let remaining = try repository.pendingOperations().count
            status = localOnly ? .localOnly : (remaining == 0 ? .synced : .pending(remaining))
        } catch {
            status = .failed("无法取消离线支出。")
        }
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func apply(_ request: CardRequest, to card: TravelCardSnapshot, in snapshot: inout SharedTripSnapshot) {
        guard let dayIndex = snapshot.days.firstIndex(where: { $0.cards.contains(where: { $0.id == card.id }) }),
              let cardIndex = snapshot.days[dayIndex].cards.firstIndex(where: { $0.id == card.id }) else { return }
        var updated = snapshot.days[dayIndex].cards[cardIndex]
        if let kind = request.kind { updated.kind = kind }
        if let title = request.title { updated.title = title }
        if let startAt = parseTimestamp(request.startAt) { updated.startAt = startAt }
        if let endAt = parseTimestamp(request.endAt) { updated.endAt = endAt }
        if request.fieldsToClear.contains("endAt") { updated.endAt = nil }
        if request.fieldsToClear.contains("place") {
            updated.place = nil
        } else if let place = request.place {
            updated.place = optimisticPlace(from: place)
        }
        updated.bookingCode = request.bookingCode ?? (request.fieldsToClear.contains("bookingCode") ? nil : updated.bookingCode)
        updated.url = request.url ?? (request.fieldsToClear.contains("url") ? nil : updated.url)
        updated.description = request.description ?? (request.fieldsToClear.contains("description") ? nil : updated.description)
        updated.fromAirport = request.fromAirport ?? (request.fieldsToClear.contains("fromAirport") ? nil : updated.fromAirport)
        updated.toAirport = request.toAirport ?? (request.fieldsToClear.contains("toAirport") ? nil : updated.toAirport)
        updated.priceMinor = request.priceMinor ?? (request.fieldsToClear.contains("priceMinor") ? nil : updated.priceMinor)
        updated.actualPriceMinor = request.actualPriceMinor ?? (request.fieldsToClear.contains("actualPriceMinor") ? nil : updated.actualPriceMinor)
        updated.ticketPriceMinor = request.ticketPriceMinor ?? (request.fieldsToClear.contains("ticketPriceMinor") ? nil : updated.ticketPriceMinor)
        updated.stayDurationMinutes = request.stayDurationMinutes ?? (request.fieldsToClear.contains("stayDurationMinutes") ? nil : updated.stayDurationMinutes)
        updated.tips = request.tips ?? (request.fieldsToClear.contains("tips") ? nil : updated.tips)
        updated.images = request.images ?? (request.fieldsToClear.contains("images") ? nil : updated.images)
        updated.notes = request.notes ?? (request.fieldsToClear.contains("notes") ? nil : updated.notes)
        if let position = request.position { updated.position = position }
        updated.updatedAt = .now
        snapshot.days[dayIndex].cards[cardIndex] = updated
    }

    private func queueConfirmedAIDraftCardsIfReady() async throws {
        guard var current = trip else { return }
        let queued = try repository.confirmedAIDraftCards()
        var queuedAny = false
        for draftCard in queued {
            guard let dayIndex = current.days.firstIndex(where: { $0.date == draftCard.date }),
                  let kind = TravelCardSnapshot.Kind(rawValue: draftCard.kind) else { continue }
            guard try repository.pendingOperation(for: draftCard.localID) == nil else { continue }
            let time = (draftCard.time?.isEmpty == false ? draftCard.time! : "09:00")
            let startAt = "\(draftCard.date)T\(time):00Z"
            let place = await resolvedPlace(from: draftCard.placeData)
            let extras = draftCard.extraData.flatMap { try? JSONDecoder().decode(AICardExtras.self, from: $0) }
            let resourceDayID = current.days[dayIndex].serverID ?? Self.takeLocalResourceID()
            let request = CardRequest(
                dayId: current.days[dayIndex].serverID,
                kind: kind,
                title: draftCard.title,
                startAt: startAt,
                place: place,
                bookingCode: extras?.bookingCode,
                url: extras?.url,
                description: extras?.description,
                fromAirport: extras?.fromAirport,
                toAirport: extras?.toAirport,
                priceMinor: extras?.priceMinor,
                notes: draftCard.notes,
                position: current.days[dayIndex].cards.count
            )
            current.days[dayIndex].cards.append(TravelCardSnapshot(
                dayID: resourceDayID,
                kind: kind,
                title: draftCard.title,
                startAt: Self.parseTimestamp(startAt) ?? .now,
                place: Self.optimisticPlace(from: request.place),
                bookingCode: request.bookingCode,
                url: request.url,
                description: request.description,
                fromAirport: request.fromAirport,
                toAirport: request.toAirport,
                priceMinor: request.priceMinor,
                notes: draftCard.notes,
                position: request.position ?? 0
            ))
            if localOnly {
                try repository.removeConfirmedAIDraftCard(draftCard)
                queuedAny = true
                continue
            }
            guard current.days[dayIndex].serverID != nil else { continue }
            let body = try await apiClient.encode(request)
            try repository.enqueue(
                method: "POST", path: "/v1/cards", tripID: current.id, body: body,
                baseVersion: current.version, clientEntityID: draftCard.localID
            )
            queuedAny = true
        }
        if queuedAny {
            current.updatedAt = .now
            if localOnly {
                try saveLocalSnapshot(current)
            } else {
                trip = current
                try repository.save(current)
            }
        }
    }

    private static var nextLocalResourceID = -1
    private static var nextOptimisticPlaceID = -1

    private static func takeLocalResourceID() -> Int {
        defer { nextLocalResourceID -= 1 }
        return nextLocalResourceID
    }

    private static func optimisticPlace(from request: PlaceRequest?) -> PlaceSnapshot? {
        guard let request else { return nil }
        defer { nextOptimisticPlaceID -= 1 }
        return PlaceSnapshot(
            id: nextOptimisticPlaceID,
            name: request.name,
            address: request.address,
            latitude: request.latitude,
            longitude: request.longitude,
            placeId: request.placeId,
            cityCode: request.cityCode,
            updatedAt: .now
        )
    }

    private static func migrationCardRequest(_ card: TravelCardSnapshot, dayID: Int) -> CardRequest {
        CardRequest(
            dayId: dayID,
            kind: card.kind,
            title: card.title,
            startAt: migrationTimestampFormatter.string(from: card.startAt),
            endAt: card.endAt.map(migrationTimestampFormatter.string(from:)),
            place: card.place.map {
                PlaceRequest(
                    name: $0.name,
                    address: $0.address,
                    latitude: $0.latitude,
                    longitude: $0.longitude,
                    placeId: $0.placeId,
                    cityCode: $0.cityCode
                )
            },
            bookingCode: card.bookingCode,
            url: card.url,
            description: card.description,
            fromAirport: card.fromAirport,
            toAirport: card.toAirport,
            priceMinor: card.priceMinor,
            actualPriceMinor: card.actualPriceMinor,
            ticketPriceMinor: card.ticketPriceMinor,
            stayDurationMinutes: card.stayDurationMinutes,
            tips: card.tips,
            images: card.images,
            notes: card.notes,
            position: card.position
        )
    }

    private static func cardCounts(in trip: SharedTripSnapshot) -> [MigrationCardFingerprint: Int] {
        var counts: [MigrationCardFingerprint: Int] = [:]
        for day in trip.days {
            for card in day.cards {
                counts[MigrationCardFingerprint(day: day.date, card: card), default: 0] += 1
            }
        }
        return counts
    }

    private static func expenseCounts(in trip: SharedTripSnapshot) -> [MigrationExpenseFingerprint: Int] {
        var counts: [MigrationExpenseFingerprint: Int] = [:]
        for expense in trip.expenses {
            counts[MigrationExpenseFingerprint(expense: expense, cardID: expense.cardID), default: 0] += 1
        }
        return counts
    }

    private static func migratedCardIDMap(sourceDays: [TripDaySnapshot], remote: SharedTripSnapshot) -> [Int: Int] {
        var remoteCards: [MigrationCardFingerprint: [TravelCardSnapshot]] = [:]
        for day in remote.days {
            for card in day.cards {
                remoteCards[MigrationCardFingerprint(day: day.date, card: card), default: []].append(card)
            }
        }
        for key in remoteCards.keys {
            remoteCards[key]?.sort { ($0.serverID ?? Int.max) < ($1.serverID ?? Int.max) }
        }

        var consumed: [MigrationCardFingerprint: Int] = [:]
        var result: [Int: Int] = [:]
        for day in sourceDays.sorted(by: { ($0.date, $0.position) < ($1.date, $1.position) }) {
            for card in day.cards.sorted(by: cardTimeOrder) {
                guard let sourceID = card.serverID else { continue }
                let fingerprint = MigrationCardFingerprint(day: day.date, card: card)
                let index = consumed[fingerprint, default: 0]
                guard let candidates = remoteCards[fingerprint], candidates.indices.contains(index),
                      let targetID = candidates[index].serverID else { continue }
                result[sourceID] = targetID
                consumed[fingerprint] = index + 1
            }
        }
        return result
    }

/// Resolve an AI-proposed name with Apple MapKit at import time. Existing
/// coordinates from older drafts remain usable; new AI drafts never depend on
/// a server-side map provider.
private func resolvedPlace(from placeData: Data?) async -> PlaceRequest? {
    guard let placeData, let place = try? JSONDecoder().decode(AIChatPlace.self, from: placeData) else { return nil }
    if let latitude = place.latitude, let longitude = place.longitude {
        return PlaceRequest(name: place.name, address: place.address, latitude: latitude, longitude: longitude, placeId: place.placeId, cityCode: place.cityCode)
    }

    // Treat the model's place as a search hint, never as verified location data.
    // The trip destination scopes ambiguous names (for example, "万达广场") to
    // the intended city before the card is persisted or route planning uses it.
    let city = Self.nonEmptyTrimmed(trip?.destination)
    guard let result = try? await AppleMapService.searchPlaces(query: place.name, city: city).first else {
        return nil
    }
    return result.request
}

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let migrationTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Formats a card start time the way the timeline displays it (device-local
    /// wall-clock), so the AI sees the same time the user sees when enriching.
    private static let cardTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct EmptyRequest: Encodable, Sendable {}

enum TripSharingError: LocalizedError {
    case requiresSignIn

    var errorDescription: String? {
        switch self {
        case .requiresSignIn: "请先使用 Apple 登录，再查看共享成员。"
        }
    }
}

struct PendingLocalTripMigration: Codable {
    let source: SharedTripSnapshot
    var targetTripID: Int?
    let createIdempotencyKey: UUID

    init(source: SharedTripSnapshot, targetTripID: Int? = nil, createIdempotencyKey: UUID = UUID()) {
        self.source = source
        self.targetTripID = targetTripID
        self.createIdempotencyKey = createIdempotencyKey
    }
}

@MainActor
final class LocalTripMigrationStore {
    private static let pendingKey = "localTripMigration.pending.v1"
    private static let finishedKey = "localTripMigration.finished.v1"
    private static let batchKey = "localTripMigration.batch.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var didFinishInitialImport: Bool {
        defaults.bool(forKey: Self.finishedKey)
    }

    var hasPendingMigration: Bool {
        defaults.data(forKey: Self.pendingKey) != nil
    }

    var isInitialImportBatchActive: Bool {
        defaults.bool(forKey: Self.batchKey)
    }

    func pendingMigration() throws -> PendingLocalTripMigration? {
        guard let data = defaults.data(forKey: Self.pendingKey) else { return nil }
        return try JSONDecoder.sharedTrip.decode(PendingLocalTripMigration.self, from: data)
    }

    func save(_ migration: PendingLocalTripMigration) throws {
        defaults.set(try JSONEncoder.sharedTrip.encode(migration), forKey: Self.pendingKey)
    }

    func beginInitialImportBatch() {
        defaults.set(true, forKey: Self.batchKey)
    }

    func completeCurrentMigration() {
        defaults.removeObject(forKey: Self.pendingKey)
    }

    func discardInvalidMigrationState() {
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.batchKey)
    }

    func markInitialImportFinished() {
        defaults.set(true, forKey: Self.finishedKey)
        defaults.removeObject(forKey: Self.pendingKey)
        defaults.removeObject(forKey: Self.batchKey)
    }
}

private enum LocalTripMigrationError: LocalizedError {
    case accountMismatch
    case missingCreatedTrip
    case missingImportedDay

    var errorDescription: String? {
        switch self {
        case .accountMismatch: "本地数据迁移记录与当前账户不匹配。"
        case .missingCreatedTrip: "服务器未返回刚创建的旅程。"
        case .missingImportedDay: "服务器未返回刚同步的行程日期。"
        }
    }
}

private struct MigrationCardFingerprint: Hashable {
    let day: String
    let kind: String
    let title: String
    let startAt: Date
    let endAt: Date?
    let placeName: String?
    let placeAddress: String?
    let latitude: Double?
    let longitude: Double?
    let bookingCode: String?
    let url: String?
    let description: String?
    let fromAirport: String?
    let toAirport: String?
    let priceMinor: Int64?
    let actualPriceMinor: Int64?
    let ticketPriceMinor: Int64?
    let stayDurationMinutes: Int?
    let tips: [String]?
    let images: [String]?
    let notes: String?
    let position: Int

    init(day: String, card: TravelCardSnapshot) {
        self.day = day
        kind = card.kind.rawValue
        title = card.title
        startAt = card.startAt
        endAt = card.endAt
        placeName = card.place?.name
        placeAddress = card.place?.address
        latitude = card.place?.latitude
        longitude = card.place?.longitude
        bookingCode = card.bookingCode
        url = card.url
        description = card.description
        fromAirport = card.fromAirport
        toAirport = card.toAirport
        priceMinor = card.priceMinor
        actualPriceMinor = card.actualPriceMinor
        ticketPriceMinor = card.ticketPriceMinor
        stayDurationMinutes = card.stayDurationMinutes
        tips = card.tips
        images = card.images
        notes = card.notes
        position = card.position
    }
}

private struct MigrationExpenseFingerprint: Hashable {
    let amountMinor: Int64
    let currency: String
    let category: String
    let paidBy: String?
    let splitMode: String?
    let occurredOn: String
    let note: String?
    let cardID: Int?

    init(expense: ExpenseSnapshot, cardID: Int?) {
        amountMinor = expense.amountMinor
        currency = expense.currency
        category = expense.category.rawValue
        paidBy = expense.paidBy?.rawValue
        splitMode = expense.splitMode?.rawValue
        occurredOn = expense.occurredOn
        note = expense.note
        self.cardID = cardID
    }
}

enum AIDraftImportError: LocalizedError {
    case tripNotConfigured
    case invalidDraft(String)
    case submissionFailed(String)

    var errorDescription: String? {
        switch self {
        case .tripNotConfigured: "请先设置有效的旅行日期。"
        case let .invalidDraft(message): message
        case let .submissionFailed(message): message
        }
    }
}
