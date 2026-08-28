import Network
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum JournalNetworkAccess: Equatable, Sendable {
    case offline
    case wifi
    case metered
    case other

    var allowsAutomaticSync: Bool { self == .wifi }
}

@MainActor
final class JournalSyncCoordinator: ObservableObject, @unchecked Sendable {
    enum State: Equatable {
        case idle
        case waitingForWiFi
        case syncing(progress: Double, completed: Int, total: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var networkAccess: JournalNetworkAccess = .offline
    @Published private(set) var revision = 0

    let localStore: LocalJournalStore
    private let api: APIClient
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.nuannuan.travel-companion.journal-network")
    private var isAuthenticated = false
    private var tripID: Int?
    private var syncTask: Task<Void, Never>?
    private var currentSyncAllowsMeteredNetwork = false

    init(localStore: LocalJournalStore = LocalJournalStore(), api: APIClient = APIClient()) {
        self.localStore = localStore
        self.api = api
        monitor.pathUpdateHandler = { [weak self] path in
            let access = Self.access(for: path)
            Task { @MainActor [weak self] in
                self?.networkDidChange(to: access)
            }
        }
        monitor.start(queue: monitorQueue)
    }

    deinit {
        monitor.cancel()
        syncTask?.cancel()
    }

    var pendingEntryCount: Int { localStore.snapshot.entries.count }

    var hasPendingContent: Bool {
        !localStore.snapshot.entries.isEmpty || !localStore.snapshot.groups.isEmpty
    }

    func updateSession(isAuthenticated: Bool, tripID: Int?) {
        self.isAuthenticated = isAuthenticated
        self.tripID = tripID.flatMap { $0 > 0 ? $0 : nil }
        guard isAuthenticated, self.tripID != nil, hasPendingContent else {
            if !hasPendingContent { state = .idle }
            if !isAuthenticated || self.tripID == nil { syncTask?.cancel() }
            return
        }
        if networkAccess.allowsAutomaticSync {
            startSync(allowsMeteredNetwork: false)
        } else if syncTask == nil {
            state = .waitingForWiFi
        }
    }

    func syncNow() {
        startSync(allowsMeteredNetwork: true)
    }

    private nonisolated static func access(for path: NWPath) -> JournalNetworkAccess {
        guard path.status == .satisfied else { return .offline }
        if path.usesInterfaceType(.cellular) || path.isExpensive || path.isConstrained {
            return .metered
        }
        if path.usesInterfaceType(.wifi) { return .wifi }
        return .other
    }

    private func networkDidChange(to access: JournalNetworkAccess) {
        networkAccess = access
        if syncTask != nil,
           access == .offline || (!access.allowsAutomaticSync && !currentSyncAllowsMeteredNetwork) {
            syncTask?.cancel()
            return
        }
        guard isAuthenticated, tripID != nil, hasPendingContent else { return }
        if access.allowsAutomaticSync {
            startSync(allowsMeteredNetwork: false)
        } else if syncTask == nil, case .failed = state {
            // Keep the actionable failure until the user retries or Wi-Fi resumes.
        } else if syncTask == nil {
            state = .waitingForWiFi
        }
    }

    private func startSync(allowsMeteredNetwork: Bool) {
        guard syncTask == nil,
              isAuthenticated,
              let tripID,
              hasPendingContent,
              networkAccess != .offline,
              networkAccess.allowsAutomaticSync || allowsMeteredNetwork
        else {
            if hasPendingContent, networkAccess != .wifi { state = .waitingForWiFi }
            return
        }
        currentSyncAllowsMeteredNetwork = allowsMeteredNetwork
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let wasCancelled = await self.migrateLocalJournal(to: tripID)
            self.syncTask = nil
            self.currentSyncAllowsMeteredNetwork = false
            if wasCancelled,
               self.isAuthenticated,
               self.tripID != nil,
               self.hasPendingContent,
               self.networkAccess.allowsAutomaticSync {
                self.startSync(allowsMeteredNetwork: false)
            }
        }
    }

    private func migrateLocalJournal(to tripID: Int) async -> Bool {
        let local = localStore.snapshot
        do {
            var groupIDs = try localStore.syncGroupIDs(for: tripID)
            let pendingGroupCount = local.groups.filter { groupIDs[$0.id] == nil }.count
            let resourceCount = local.entries.reduce(into: 0) { count, entry in
                for image in entry.images { count += image.pairedVideo == nil ? 1 : 2 }
            }
            let total = max(1, pendingGroupCount + local.entries.count + resourceCount)
            var completed = 0
            publishProgress(completed: completed, total: total)

            for group in local.groups.sorted(by: { $0.position < $1.position }) {
                if groupIDs[group.id] != nil { continue }
                try Task.checkCancellation()
                let created = try await api.createJournalGroup(
                    JournalGroupRequest(name: group.name, color: group.color, position: group.position),
                    tripID: tripID
                )
                groupIDs[group.id] = created.id
                try localStore.recordSyncedGroup(localID: group.id, remoteID: created.id, tripID: tripID)
                completed += 1
                publishProgress(completed: completed, total: total)
            }
            for entry in local.entries.sorted(by: { $0.createdAt < $1.createdAt }) {
                try Task.checkCancellation()
                var media: [JournalMediaReference] = []
                for image in entry.images {
                    guard let attachment = try localStore.attachment(for: image) else {
                        throw JournalSyncError.missingLocalAttachment
                    }
                    media.append(try await upload(
                        attachment,
                        tripID: tripID,
                        completed: &completed,
                        total: total
                    ))
                }
                _ = try await api.createJournalEntry(
                    JournalEntryRequest(
                        groupId: entry.groupId.flatMap { groupIDs[$0] },
                        title: entry.title,
                        content: entry.content,
                        imageKeys: media
                    ),
                    tripID: tripID
                )
                try localStore.markEntrySynced(entry.id)
                revision += 1
                completed += 1
                publishProgress(completed: completed, total: total)
            }
            try localStore.clear()
            state = .idle
            revision += 1
            return false
        } catch is CancellationError {
            if hasPendingContent { state = .waitingForWiFi }
            return true
        } catch {
            state = .failed(error.localizedDescription)
            return false
        }
    }

    private func upload(
        _ attachment: JournalAttachment,
        tripID: Int,
        completed: inout Int,
        total: Int
    ) async throws -> JournalMediaReference {
        let primaryBase = completed
        let primaryKey = try await api.uploadJournalFile(
            at: attachment.primary.url,
            contentType: attachment.primary.contentType,
            fileName: attachment.primary.fileName,
            tripID: tripID,
            progress: { [weak self] sent, expected in
                let fraction = expected > 0 ? min(1, Double(sent) / Double(expected)) : 0
                Task { @MainActor [weak self] in
                    self?.publishProgress(completed: primaryBase, total: total, partial: fraction)
                }
            }
        )
        completed += 1
        publishProgress(completed: completed, total: total)

        let pairedUpload: JournalMediaUploadResource?
        if let paired = attachment.pairedVideo {
            let pairedBase = completed
            let key = try await api.uploadJournalFile(
                at: paired.url,
                contentType: paired.contentType,
                fileName: paired.fileName,
                tripID: tripID,
                progress: { [weak self] sent, expected in
                    let fraction = expected > 0 ? min(1, Double(sent) / Double(expected)) : 0
                    Task { @MainActor [weak self] in
                        self?.publishProgress(completed: pairedBase, total: total, partial: fraction)
                    }
                }
            )
            pairedUpload = .init(
                key: key,
                contentType: paired.contentType,
                fileName: paired.fileName,
                sizeBytes: paired.sizeBytes
            )
            completed += 1
            publishProgress(completed: completed, total: total)
        } else {
            pairedUpload = nil
        }
        return .item(.init(
            key: primaryKey,
            kind: attachment.kind,
            contentType: attachment.primary.contentType,
            fileName: attachment.primary.fileName,
            sizeBytes: attachment.primary.sizeBytes,
            pairedVideo: pairedUpload
        ))
    }

    private func publishProgress(completed: Int, total: Int, partial: Double = 0) {
        let value = min(1, (Double(completed) + partial) / Double(max(1, total)))
        if case .syncing(let current, _, _) = state, value < current { return }
        state = .syncing(progress: value, completed: completed, total: total)
    }
}

private enum JournalSyncError: LocalizedError {
    case missingLocalAttachment
    case pendingForAnotherTrip

    var errorDescription: String? {
        switch self {
        case .missingLocalAttachment: String(localized: "journal.missingAttachment")
        case .pendingForAnotherTrip: String(localized: "journal.conflictTrip")
        }
    }
}

struct NotesView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var journalSync: JournalSyncCoordinator
    @ObservedObject private var localStore: LocalJournalStore

    @State private var snapshot = JournalSnapshot(groups: [], entries: [])
    @State private var selectedGroupID: Int?
    @State private var editor: JournalEntry?
    @State private var showsGroupEditor = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    private let api = APIClient()

    init(syncEngine: SyncEngine, journalSync: JournalSyncCoordinator) {
        self.syncEngine = syncEngine
        self.journalSync = journalSync
        _localStore = ObservedObject(wrappedValue: journalSync.localStore)
    }

    private var visibleEntries: [JournalEntry] {
        snapshot.entries.filter { selectedGroupID == nil || $0.groupId == selectedGroupID }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PrimaryTabPalette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    journalHeader
                        .allowsHitTesting(!isSyncingJournal)
                    journalSummary
                    journalSyncBanner

                    Group {
                        if isLoading && snapshot.entries.isEmpty {
                            ProgressView("journal.loading")
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .padding(.bottom, 112)
                        } else if visibleEntries.isEmpty {
                            ContentUnavailableView(
                                "journal.emptyTitle",
                                systemImage: "book.closed",
                                description: Text("journal.emptyDesc")
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(.bottom, 112)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(visibleEntries) { entry in
                                        journalCard(entry)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.bottom, 128)
                            }
                            .scrollIndicators(.hidden)
                            .refreshable { await reload() }
                        }
                    }
                    .allowsHitTesting(!isSyncingJournal)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .task { await reload() }
            .onChange(of: syncEngine.isUserAuthenticated) { _, authenticated in
                journalSync.updateSession(isAuthenticated: authenticated, tripID: syncEngine.selectedTripID)
                Task { await reload() }
            }
            .onChange(of: syncEngine.selectedTripID) { _, tripID in
                journalSync.updateSession(isAuthenticated: syncEngine.isUserAuthenticated, tripID: tripID)
                Task { await reload() }
            }
            .onChange(of: journalSync.revision) { _, _ in Task { await reload() } }
            .sheet(item: $editor) { entry in
                JournalEditor(
                    entry: entry.id == 0 ? nil : entry,
                    groups: snapshot.groups,
                    defaultGroupID: entry.groupId
                ) { request, attachments in
                    await save(entry: entry, request: request, attachments: attachments)
                }
            }
            .sheet(isPresented: $showsGroupEditor) {
                JournalGroupsEditor(groups: snapshot.groups) {
                    await saveGroup($0)
                } onDelete: { group in
                    await deleteGroup(group)
                }
            }
            .alert(
                "journal.incompleteTitle",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var journalHeader: some View {
        ZStack {
            Text("journal.headerTitle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack {
                Menu {
                    Button("journal.allEntries") { selectedGroupID = nil }
                    Divider()
                    ForEach(snapshot.groups) { group in
                        Button(group.name) { selectedGroupID = group.id }
                    }
                    Divider()
                    Button("journal.manageGroups", systemImage: "folder.badge.plus") {
                        showsGroupEditor = true
                    }
                } label: {
                    Image(systemName: "folder")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .primaryTabHeaderButtonStyle()
                .accessibilityLabel(Text("journal.groupMenuA11y"))

                Spacer(minLength: 0)

                Button {
                    createEntry()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .primaryTabHeaderButtonStyle()
                .accessibilityLabel(Text("journal.newA11y"))
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private var journalSummary: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(selectedGroupTitle)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(String(format: String(localized: "journal.countFormat"), visibleEntries.count))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var selectedGroupTitle: String { snapshot.groups.first(where: { $0.id == selectedGroupID })?.name ?? String(localized: "journal.allGroups") }

    @ViewBuilder
    private var journalSyncBanner: some View {
        if remoteTripID != nil, journalSync.hasPendingContent || isSyncingJournal {
            HStack(spacing: 12) {
                syncBannerIcon
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(syncBannerTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                    if case .syncing(let progress, let completed, let total) = journalSync.state {
                        ProgressView(value: progress)
                            .tint(PrimaryTabPalette.accent)
                        Text(String(format: String(localized: "journal.syncProgress"), completed, total, Int(progress * 100)))
                            .font(.caption2)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else {
                        Text(syncBannerDetail)
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 4)

                if shouldShowManualSyncButton {
                    Button("journal.syncNow") { journalSync.syncNow() }
                        .font(.system(size: 13, weight: .semibold))
                        .buttonStyle(.bordered)
                        .tint(PrimaryTabPalette.accent)
                        .disabled(journalSync.networkAccess == .offline)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 13))
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        }
    }

    private var isSyncingJournal: Bool {
        if case .syncing = journalSync.state { return true }
        return false
    }

    private var shouldShowManualSyncButton: Bool {
        switch journalSync.state {
        case .waitingForWiFi, .failed: true
        case .idle, .syncing: false
        }
    }

    @ViewBuilder
    private var syncBannerIcon: some View {
        switch journalSync.state {
        case .syncing:
            ProgressView().tint(PrimaryTabPalette.accent)
        case .failed:
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
        case .idle, .waitingForWiFi:
            Image(systemName: journalSync.networkAccess == .offline ? "wifi.slash" : "icloud.and.arrow.up")
        }
    }

    private var syncBannerTitle: String {
        switch journalSync.state {
        case .syncing: String(localized: "journal.syncingTitle")
        case .failed: String(localized: "journal.pausedTitle")
        case .idle, .waitingForWiFi:
            journalSync.networkAccess == .offline ? String(localized: "journal.waitNetworkTitle") : String(localized: "journal.waitWifiTitle")
        }
    }

    private var syncBannerDetail: String {
        return switch journalSync.state {
        case .failed(let message): message
        case .idle, .waitingForWiFi:
            if journalSync.networkAccess == .offline {
                String(localized: "journal.syncSafeNote")
            } else {
                String(format: String(localized: "journal.pendingNote"), journalSync.pendingEntryCount)
            }
        case .syncing: ""
        }
    }

    private var remoteTripID: Int? {
        guard syncEngine.isUserAuthenticated,
              let tripID = syncEngine.selectedTripID,
              tripID > 0 else { return nil }
        return tripID
    }

    private func journalCard(_ entry: JournalEntry) -> some View {
        Button { editor = entry } label: {
            VStack(alignment: .leading, spacing: 12) {
                if let first = entry.images.first {
                    JournalMediaView(media: first)
                        .frame(height: 180)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    if entry.images.count > 1 {
                        Text(String(format: String(localized: "journal.attachmentCount"), entry.images.count))
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
                Text(entry.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                if let content = entry.content, !content.isEmpty {
                    Text(content)
                        .font(.subheadline)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(3)
                }
                HStack {
                    if let group = snapshot.groups.first(where: { $0.id == entry.groupId }) {
                        Label(group.name, systemImage: "folder.fill")
                            .foregroundStyle(PrimaryTabPalette.accent)
                    }
                    Spacer()
                    Text(entry.updatedAt, style: .date)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                .font(.caption)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .primaryTabCardStyle(
                color: entry.images.isEmpty
                    ? PrimaryTabPalette.elevatedSurface
                    : PrimaryTabPalette.surface,
                cornerRadius: 16
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("common.edit", systemImage: "pencil") { editor = entry }
            Button("common.delete", systemImage: "trash", role: .destructive) {
                deleteEntry(entry)
            }
        }
    }

    private func createEntry() {
        editor = JournalEntry(
            id: 0,
            groupId: selectedGroupID,
            title: "",
            content: nil,
            images: [],
            createdAt: .now,
            updatedAt: .now
        )
    }

    private func deleteEntry(_ entry: JournalEntry) {
        guard let index = visibleEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        deleteEntries(at: IndexSet(integer: index))
    }

    private func reload() async {
        guard let tripID = remoteTripID else {
            snapshot = localStore.snapshot
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let remote = try await api.fetchJournal(tripID: tripID)
            snapshot = merge(remote: remote, local: localStore.snapshot)
            if let selectedGroupID, !snapshot.groups.contains(where: { $0.id == selectedGroupID }) {
                self.selectedGroupID = nil
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func merge(remote: JournalSnapshot, local: JournalSnapshot) -> JournalSnapshot {
        JournalSnapshot(
            groups: remote.groups + local.groups,
            entries: (remote.entries + local.entries).sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    private func save(entry: JournalEntry, request: JournalEntryRequest, attachments: [JournalAttachment]) async {
        guard let tripID = remoteTripID else {
            do {
                try localStore.save(entryID: entry.id == 0 ? nil : entry.id, request: request, attachments: attachments)
                snapshot = localStore.snapshot
                self.editor = nil
            } catch { errorMessage = error.localizedDescription }
            return
        }
        do {
            var media = request.imageKeys
            for attachment in attachments {
                media.append(try await upload(attachment, tripID: tripID))
            }
            let request = JournalEntryRequest(
                groupId: request.groupId,
                title: request.title,
                content: request.content,
                imageKeys: media
            )
            _ = entry.id == 0
                ? try await api.createJournalEntry(request, tripID: tripID)
                : try await api.updateJournalEntry(id: entry.id, request, tripID: tripID)
            self.editor = nil
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteEntries(at offsets: IndexSet) {
        guard let tripID = remoteTripID else {
            do {
                try localStore.deleteEntries(offsets.map { visibleEntries[$0].id })
                snapshot = localStore.snapshot
            } catch { errorMessage = error.localizedDescription }
            return
        }
        for index in offsets { let entry = visibleEntries[index]; Task { do { try await api.deleteJournalEntry(id: entry.id, tripID: tripID); await reload() } catch { errorMessage = error.localizedDescription } } }
    }

    private func saveGroup(_ request: JournalGroupRequest) async {
        guard let tripID = remoteTripID else {
            do {
                try localStore.createGroup(request)
                snapshot = localStore.snapshot
            } catch { errorMessage = error.localizedDescription }
            return
        }
        do { _ = try await api.createJournalGroup(request, tripID: tripID); await reload() } catch { errorMessage = error.localizedDescription }
    }

    private func deleteGroup(_ group: JournalGroup) async {
        guard let tripID = remoteTripID else {
            do {
                try localStore.deleteGroup(group.id)
                if selectedGroupID == group.id { selectedGroupID = nil }
                snapshot = localStore.snapshot
            } catch { errorMessage = error.localizedDescription }
            return
        }
        do { try await api.deleteJournalGroup(id: group.id, tripID: tripID); if selectedGroupID == group.id { selectedGroupID = nil }; await reload() } catch { errorMessage = error.localizedDescription }
    }

    private func upload(_ attachment: JournalAttachment, tripID: Int) async throws -> JournalMediaReference {
        let primaryKey = try await api.uploadJournalFile(
            at: attachment.primary.url,
            contentType: attachment.primary.contentType,
            fileName: attachment.primary.fileName,
            tripID: tripID
        )
        let pairedUpload: JournalMediaUploadResource?
        if let paired = attachment.pairedVideo {
            let key = try await api.uploadJournalFile(
                at: paired.url,
                contentType: paired.contentType,
                fileName: paired.fileName,
                tripID: tripID
            )
            pairedUpload = .init(
                key: key,
                contentType: paired.contentType,
                fileName: paired.fileName,
                sizeBytes: paired.sizeBytes
            )
        } else {
            pairedUpload = nil
        }
        return .item(.init(
            key: primaryKey,
            kind: attachment.kind,
            contentType: attachment.primary.contentType,
            fileName: attachment.primary.fileName,
            sizeBytes: attachment.primary.sizeBytes,
            pairedVideo: pairedUpload
        ))
    }
}

@MainActor
final class LocalJournalStore: ObservableObject {
    @Published private(set) var snapshot: JournalSnapshot

    private let defaults: UserDefaults
    private let storageKey = "localJournal.snapshot.v1"
    private let syncCheckpointKey = "localJournal.syncCheckpoint.v1"
    private let imagesDirectory: URL

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        imagesDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelCompanion/LocalJournalImages", isDirectory: true)
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(JournalSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = JournalSnapshot(groups: [], entries: [])
        }
    }

    func save(entryID: Int?, request: JournalEntryRequest, attachments: [JournalAttachment]) throws {
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        var entries = snapshot.entries
        let existingIndex = entryID.flatMap { id in entries.firstIndex(where: { $0.id == id }) }
        let existing = existingIndex.map { entries[$0] }
        let retainedKeys = Set(request.imageKeys.map(\.primaryKey))
        let retainedImages = existing?.images.filter { retainedKeys.contains($0.key) } ?? []
        let newImages = try attachments.map { attachment -> JournalImage in
            let primaryExtension = attachment.primary.url.pathExtension.isEmpty
                ? "bin"
                : attachment.primary.url.pathExtension
            let primaryKey = UUID().uuidString.lowercased() + "." + primaryExtension
            let primaryURL = imagesDirectory.appendingPathComponent(primaryKey)
            try FileManager.default.copyItem(at: attachment.primary.url, to: primaryURL)
            let paired: JournalMediaResource?
            if let pairedVideo = attachment.pairedVideo {
                let pairedExtension = pairedVideo.url.pathExtension.isEmpty ? "mov" : pairedVideo.url.pathExtension
                let pairedKey = UUID().uuidString.lowercased() + "." + pairedExtension
                let pairedURL = imagesDirectory.appendingPathComponent(pairedKey)
                try FileManager.default.copyItem(at: pairedVideo.url, to: pairedURL)
                paired = .init(
                    key: pairedKey,
                    url: pairedURL.absoluteString,
                    contentType: pairedVideo.contentType,
                    fileName: pairedVideo.fileName,
                    sizeBytes: pairedVideo.sizeBytes
                )
            } else {
                paired = nil
            }
            return JournalImage(
                key: primaryKey,
                url: primaryURL.absoluteString,
                kind: attachment.kind,
                contentType: attachment.primary.contentType,
                fileName: attachment.primary.fileName,
                sizeBytes: attachment.primary.sizeBytes,
                pairedVideo: paired
            )
        }
        let now = Date()
        let entry = JournalEntry(
            id: existing?.id ?? nextID(in: entries.map(\.id)),
            groupId: request.groupId,
            title: request.title,
            content: request.content,
            images: retainedImages + newImages,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        if let existingIndex {
            entries[existingIndex] = entry
        } else {
            entries.insert(entry, at: 0)
        }
        snapshot = JournalSnapshot(groups: snapshot.groups, entries: entries)
        try persist()
    }

    func createGroup(_ request: JournalGroupRequest) throws {
        var groups = snapshot.groups
        groups.append(JournalGroup(
            id: nextID(in: groups.map(\.id)),
            name: request.name,
            color: request.color,
            position: request.position,
            updatedAt: .now
        ))
        snapshot = JournalSnapshot(groups: groups, entries: snapshot.entries)
        try persist()
    }

    func deleteGroup(_ id: Int) throws {
        let groups = snapshot.groups.filter { $0.id != id }
        let entries = snapshot.entries.map { entry in
            guard entry.groupId == id else { return entry }
            return JournalEntry(
                id: entry.id,
                groupId: nil,
                title: entry.title,
                content: entry.content,
                images: entry.images,
                createdAt: entry.createdAt,
                updatedAt: .now
            )
        }
        snapshot = JournalSnapshot(groups: groups, entries: entries)
        try persist()
    }

    func deleteEntries(_ ids: [Int]) throws {
        let idSet = Set(ids)
        for entry in snapshot.entries where idSet.contains(entry.id) {
            for image in entry.images {
                if let url = image.url.flatMap(URL.init(string:)), url.isFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
                if let url = image.pairedVideo?.url.flatMap(URL.init(string:)), url.isFileURL {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
        snapshot = JournalSnapshot(
            groups: snapshot.groups,
            entries: snapshot.entries.filter { !idSet.contains($0.id) }
        )
        try persist()
    }

    func attachment(for image: JournalImage) throws -> JournalAttachment? {
        guard let url = image.url.flatMap(URL.init(string:)), url.isFileURL else { return nil }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let primary = JournalLocalResource(
            url: url,
            contentType: image.contentType ?? "image/jpeg",
            fileName: image.fileName ?? url.lastPathComponent,
            sizeBytes: image.sizeBytes ?? values.fileSize ?? 0
        )
        let paired: JournalLocalResource?
        if let resource = image.pairedVideo,
           let pairedURL = resource.url.flatMap(URL.init(string:)),
           pairedURL.isFileURL {
            paired = .init(
                url: pairedURL,
                contentType: resource.contentType,
                fileName: resource.fileName,
                sizeBytes: resource.sizeBytes
            )
        } else {
            paired = nil
        }
        return try JournalAttachment(
            kind: image.kind ?? "photo",
            primary: primary,
            pairedVideo: paired,
            previewImage: UIImage(contentsOfFile: url.path)
        )
    }

    func syncGroupIDs(for tripID: Int) throws -> [Int: Int] {
        guard let data = defaults.data(forKey: syncCheckpointKey) else { return [:] }
        let checkpoint = try JSONDecoder().decode(LocalJournalSyncCheckpoint.self, from: data)
        guard checkpoint.tripID == tripID else { throw JournalSyncError.pendingForAnotherTrip }
        return checkpoint.groupIDs
    }

    func recordSyncedGroup(localID: Int, remoteID: Int, tripID: Int) throws {
        var groupIDs = try syncGroupIDs(for: tripID)
        groupIDs[localID] = remoteID
        let checkpoint = LocalJournalSyncCheckpoint(tripID: tripID, groupIDs: groupIDs)
        defaults.set(try JSONEncoder().encode(checkpoint), forKey: syncCheckpointKey)
    }

    func markEntrySynced(_ id: Int) throws {
        try deleteEntries([id])
    }

    func clear() throws {
        snapshot = JournalSnapshot(groups: [], entries: [])
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: syncCheckpointKey)
        if FileManager.default.fileExists(atPath: imagesDirectory.path) {
            try FileManager.default.removeItem(at: imagesDirectory)
        }
    }

    private func persist() throws {
        defaults.set(try JSONEncoder().encode(snapshot), forKey: storageKey)
    }

    private func nextID(in values: [Int]) -> Int {
        min(-1, (values.filter { $0 < 0 }.min() ?? 0) - 1)
    }
}

private struct LocalJournalSyncCheckpoint: Codable {
    let tripID: Int
    let groupIDs: [Int: Int]
}

private struct JournalEditor: View {
    let entry: JournalEntry?
    let groups: [JournalGroup]
    let defaultGroupID: Int?
    let onSave: (JournalEntryRequest, [JournalAttachment]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var content = ""
    @State private var groupID: Int?
    @State private var attachments: [JournalAttachment] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showsCamera = false
    @State private var showsFileImporter = false
    @State private var isSaving = false
    @State private var isImporting = false
    @State private var mediaError: String?

    private var availableAttachmentSlots: Int {
        max(0, 9 - (entry?.images.count ?? 0) - attachments.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("journal.thisPageSection") {
                    TextField("journal.titlePlaceholder", text: $title)
                    Picker("journal.groupLabel", selection: $groupID) {
                        Text("journal.ungrouped").tag(Int?.none)
                        ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextEditor(text: $content).frame(minHeight: 150)
                }
                Section("journal.attachmentsSection") {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(attachments) { item in
                                    ZStack(alignment: .topTrailing) {
                                        attachmentPreview(item)
                                        Button {
                                            attachments.removeAll { $0.id == item.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .symbolRenderingMode(.hierarchical)
                                        }
                                        .padding(4)
                                    }
                                }
                            }
                        }
                    }
                    if availableAttachmentSlots > 0 {
                        PhotosPicker(
                            selection: $pickerItems,
                            maxSelectionCount: availableAttachmentSlots,
                            matching: .any(of: [.images, .videos]),
                            preferredItemEncoding: .current,
                            photoLibrary: .shared()
                        ) {
                            Label("journal.fromLibrary", systemImage: "photo.on.rectangle")
                        }
                        Button("journal.fromFiles", systemImage: "doc.badge.plus") {
                            showsFileImporter = true
                        }
                        if CameraPicker.isAvailable {
                            Button("journal.takePhoto", systemImage: "camera") { showsCamera = true }
                        }
                    }
                    Text("journal.mediaCaption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isImporting {
                        ProgressView("journal.preparingFile")
                    }
                }
            }
            .navigationTitle(entry == nil ? "journal.newTitle" : "journal.editTitle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "journal.saving" : "common.save") {
                        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        isSaving = true
                        Task {
                            await onSave(
                                JournalEntryRequest(
                                    groupId: groupID,
                                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                                    content: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content,
                                    imageKeys: entry?.images.map(\.uploadReference) ?? []
                                ),
                                attachments
                            )
                            isSaving = false
                        }
                    }
                    .disabled(isSaving || isImporting)
                }
            }
            .onAppear { title = entry?.title ?? ""; content = entry?.content ?? ""; groupID = entry?.groupId ?? defaultGroupID }
            .onChange(of: pickerItems) { _, values in
                Task {
                    await importPhotoItems(values)
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.data],
                allowsMultipleSelection: true
            ) { result in
                Task { await importFiles(result) }
            }
            .sheet(isPresented: $showsCamera) {
                CameraPicker {
                    if let attachment = JournalAttachment($0), availableAttachmentSlots > 0 {
                        attachments.append(attachment)
                    }
                }
            }
            .alert(
                "journal.cannotAttachTitle",
                isPresented: Binding(
                    get: { mediaError != nil },
                    set: { if !$0 { mediaError = nil } }
                )
            ) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(mediaError ?? "")
            }
        }
    }

    @ViewBuilder
    private func attachmentPreview(_ attachment: JournalAttachment) -> some View {
        ZStack(alignment: .bottomLeading) {
            if let image = attachment.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .allowedDynamicRange(.high)
                    .scaledToFill()
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: attachment.kind == "video" ? "play.rectangle.fill" : "doc.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                    }
            }
            Text(attachment.kind == "livePhoto" ? String(localized: "journal.liveBadge") : attachment.primary.fileName)
                .font(.caption2.bold())
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.58), in: Capsule())
                .foregroundStyle(.white)
                .padding(6)
        }
        .frame(width: 110, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func importPhotoItems(_ values: [PhotosPickerItem]) async {
        guard !values.isEmpty else { return }
        isImporting = true
        defer {
            isImporting = false
            pickerItems = []
        }
        do {
            for item in values.prefix(availableAttachmentSlots) {
                attachments.append(try await JournalAttachment.load(from: item))
            }
        } catch {
            mediaError = error.localizedDescription
        }
    }

    private func importFiles(_ result: Result<[URL], Error>) async {
        isImporting = true
        defer { isImporting = false }
        do {
            for url in try result.get().prefix(availableAttachmentSlots) {
                attachments.append(try await JournalAttachment.loadFile(at: url))
            }
        } catch {
            mediaError = error.localizedDescription
        }
    }
}

private struct JournalGroupsEditor: View {
    let groups: [JournalGroup]; let onCreate: (JournalGroupRequest) async -> Void; let onDelete: (JournalGroup) async -> Void
    @Environment(\.dismiss) private var dismiss; @State private var name = ""; @State private var color = "indigo"

    /// 颜色选项的本地化展示名（存储值仍为英文色名，仅展示层转换）。
    private func colorName(_ color: String) -> String {
        switch color {
        case "indigo": String(localized: "journal.colorIndigo")
        case "pink": String(localized: "journal.colorPink")
        case "orange": String(localized: "journal.colorOrange")
        case "teal": String(localized: "journal.colorTeal")
        default: color
        }
    }

    var body: some View { NavigationStack { List { Section("journal.newGroupSection") { TextField("journal.groupPlaceholder", text: $name); Picker("journal.colorLabel", selection: $color) { ForEach(["indigo", "pink", "orange", "teal"], id: \.self) { option in Text(colorName(option)).tag(option) } }; Button("journal.createGroup") { let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { return }; Task { await onCreate(JournalGroupRequest(name: trimmed, color: color, position: groups.count)); name = "" } } }; Section("journal.existingGroupsSection") { ForEach(groups) { group in HStack { Image(systemName: "folder.fill").foregroundStyle(.indigo); Text(group.name); Spacer(); Button(role: .destructive) { Task { await onDelete(group) } } label: { Image(systemName: "trash") } } } } }.navigationTitle("journal.groupsTitle").toolbar { ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } } } } }
}
