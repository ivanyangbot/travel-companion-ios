import CoreLocation
import Network
import PhotosUI
import SwiftUI
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
                        sourceImage: image,
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
        sourceImage: JournalImage?,
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
        if attachment.kind == "photo" || attachment.kind == "livePhoto" {
            JournalPhotoLoader.shared.persistLocalPhoto(at: attachment.primary.url, key: primaryKey)
        }
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
            latitude: sourceImage?.latitude,
            longitude: sourceImage?.longitude,
            capturedAt: sourceImage?.capturedAt,
            description: sourceImage?.description,
            isHDR: sourceImage?.isHDR,
            pairedVideo: pairedUpload
        ))
    }

    private func publishProgress(completed: Int, total: Int, partial: Double = 0) {
        let value = min(1, (Double(completed) + partial) / Double(max(1, total)))
        if case .syncing(let current, _, _) = state, value < current { return }
        state = .syncing(progress: value, completed: completed, total: total)
    }
}

/// Persists the last server snapshot for each trip. Photo bytes use
/// `JournalPhotoDiskCache`; this cache keeps the metadata needed to find and
/// render those photos after the app restarts without a network connection.
final class JournalSnapshotDiskCache: @unchecked Sendable {
    static let shared = JournalSnapshotDiskCache()

    private let directory: URL
    private let lock = NSLock()

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("TravelCompanion/JournalSnapshots", isDirectory: true)
    }

    func snapshot(for tripID: Int) -> JournalSnapshot? {
        guard tripID > 0 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: fileURL(for: tripID).path) else { return nil }
        return try? JSONDecoder().decode(JournalSnapshot.self, from: data)
    }

    func store(_ snapshot: JournalSnapshot, for tripID: Int) throws {
        guard tripID > 0 else { return }
        let data = try JSONEncoder().encode(snapshot)
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: tripID), options: .atomic)
    }

    private func fileURL(for tripID: Int) -> URL {
        directory.appendingPathComponent("trip-\(tripID).json", isDirectory: false)
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

/// 手书 tab 的展示模式：列表阅读 或 照片地图（仿行程 tab 的列表/地图切换）。
enum JournalDisplayMode {
    case list
    case map
}

/// 地图弹窗上下文：单张或聚合组（组内在查看器中翻页）。
private struct MapViewerContext: Identifiable {
    let id: String
    let pins: [JournalPhotoPin]
}

private struct JournalPhotoItem: Identifiable {
    let entry: JournalEntry
    let image: JournalImage
    var id: String { image.key }
}

private struct JournalPhotoEditorContext: Identifiable {
    let entryID: Int
    let image: JournalImage
    var id: String { image.key }
}

private struct JournalListViewerContext: Identifiable {
    let id: String
    let photos: [JournalPhotoViewer.Photo]
    let initialIndex: Int
}

struct NotesView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var journalSync: JournalSyncCoordinator
    @ObservedObject private var localStore: LocalJournalStore

    @State private var snapshot = JournalSnapshot(groups: [], entries: [])
    @State private var selectedGroupID: Int?
    @State private var showsGroupEditor = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var displayMode: JournalDisplayMode = .list
    @State private var mapViewer: MapViewerContext?
    @State private var listViewer: JournalListViewerContext?
    @State private var photoEditor: JournalPhotoEditorContext?
    @State private var showsQuickPhotoPicker = false
    @State private var quickPhotoSelection: [PhotosPickerItem] = []
    @State private var isSelectingPhotos = false
    @State private var selectedPhotoIDs = Set<String>()
    @State private var isQuickImporting = false
    private let api = APIClient()
    private let snapshotCache = JournalSnapshotDiskCache.shared

    init(syncEngine: SyncEngine, journalSync: JournalSyncCoordinator) {
        self.syncEngine = syncEngine
        self.journalSync = journalSync
        _localStore = ObservedObject(wrappedValue: journalSync.localStore)
    }

    private var visibleEntries: [JournalEntry] {
        snapshot.entries.filter { selectedGroupID == nil || $0.groupId == selectedGroupID }
    }

    private var visiblePhotos: [JournalPhotoItem] {
        visibleEntries.flatMap { entry in
            entry.images.compactMap { image in
                guard image.kind == nil || image.kind == "photo" || image.kind == "livePhoto" else { return nil }
                return JournalPhotoItem(entry: entry, image: image)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PrimaryTabPalette.background.ignoresSafeArea()

                if displayMode == .map {
                    JournalPhotoMapScreen(pins: photoPins) { selectedPins in
                        mapViewer = MapViewerContext(
                            id: selectedPins.first?.id ?? UUID().uuidString,
                            pins: selectedPins
                        )
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(!isSyncingJournal)
                }

                VStack(spacing: 0) {
                    journalHeader
                        .allowsHitTesting(!isSyncingJournal)
                    if displayMode == .list {
                        journalSummary
                    }
                    Group {
                        switch displayMode {
                        case .list:
                            listContent
                        case .map:
                            Spacer().allowsHitTesting(false)
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
                // 行程切换时先移除上一行程的画面，避免并发请求把两份手书短暂混在一起。
                snapshot = JournalSnapshot(groups: [], entries: [])
                selectedGroupID = nil
                Task { await reload() }
            }
            .onChange(of: journalSync.revision) { _, _ in Task { await reload() } }
            .onChange(of: journalSync.networkAccess) { oldValue, newValue in
                if newValue == .offline {
                    errorMessage = nil
                } else if oldValue == .offline {
                    Task { await reload() }
                }
            }
            // 手书 agent 在工作台保存了新条目：手书数据不在 SyncEngine，
            // 收到广播后重拉，避免返回手书 tab 时短暂显示旧列表。
            .onReceive(NotificationCenter.default.publisher(for: .agentJournalEntriesDidChange)) { _ in
                Task { await reload() }
            }
            .fullScreenCover(item: $mapViewer) { context in
                JournalPhotoViewer(
                    photos: context.pins.map { pin in
                        JournalPhotoViewer.Photo(
                            id: pin.id,
                            url: pin.imageURL,
                            description: pin.description,
                            capturedAt: pin.capturedAt,
                            media: pin.image
                        )
                    },
                    initialIndex: 0,
                    onSaveDescription: { imageKey, description in
                        // 组内照片可能分属不同条目，按 key 找到所属 entry。
                        let pin = photoPins.first { $0.id == imageKey }
                            ?? context.pins.first { $0.id == imageKey }
                        guard let pin else { return }
                        await updateImageMetadata(
                            entryID: pin.entryID,
                            imageKey: imageKey,
                            description: description,
                            latitude: pin.latitude,
                            longitude: pin.longitude
                        )
                    }
                )
            }
            .fullScreenCover(item: $listViewer) { context in
                JournalPhotoViewer(
                    photos: context.photos,
                    initialIndex: context.initialIndex,
                    onSaveDescription: nil
                )
            }
            .sheet(item: $photoEditor) { context in
                JournalPhotoMetadataEditor(image: context.image) { description in
                    await updateImageMetadata(
                        entryID: context.entryID,
                        imageKey: context.image.key,
                        description: description,
                        latitude: context.image.latitude,
                        longitude: context.image.longitude
                    )
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .photosPicker(
                isPresented: $showsQuickPhotoPicker,
                selection: $quickPhotoSelection,
                maxSelectionCount: 9,
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: quickPhotoSelection) { _, values in
                guard !values.isEmpty else { return }
                quickPhotoSelection = []
                Task { await importQuickPhotos(values) }
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

    @ViewBuilder
    private var listContent: some View {
        if isLoading && snapshot.entries.isEmpty {
            ProgressView("journal.loading")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 112)
        } else if visiblePhotos.isEmpty {
            ContentUnavailableView(
                "journal.emptyTitle",
                systemImage: "book.closed",
                description: Text("journal.emptyDesc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 112)
        } else {
            ScrollView {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<2, id: \.self) { column in
                        LazyVStack(spacing: 10) {
                            ForEach(Array(visiblePhotos.enumerated()).filter { $0.offset % 2 == column }, id: \.element.id) { indexedPhoto in
                                journalPhoto(indexedPhoto.element)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 128)
            }
            .scrollIndicators(.hidden)
            .refreshable { await reload() }
        }
    }

    /// 地图 pin：当前分组过滤下的全部带位置照片。
    private var photoPins: [JournalPhotoPin] {
        visibleEntries.flatMap { entry in
            entry.images.compactMap { image in
                JournalPhotoPin(entry: entry, image: image, fallbackCoordinate: fallbackTripCoordinate)
            }
        }
    }

    private var fallbackTripCoordinate: CLLocationCoordinate2D? {
        for day in syncEngine.trip?.sortedDaysInDateRange ?? [] {
            for card in day.cards {
                guard let latitude = card.place?.latitude,
                      let longitude = card.place?.longitude,
                      (-90.0 ... 90.0).contains(latitude),
                      (-180.0 ... 180.0).contains(longitude),
                      latitude != 0 || longitude != 0 else { continue }
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            }
        }
        return nil
    }

    private var journalHeader: some View {
        ZStack {
            Text("journal.headerTitle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack {
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        isSelectingPhotos.toggle()
                        if isSelectingPhotos { displayMode = .list }
                        if !isSelectingPhotos { selectedPhotoIDs.removeAll() }
                    }
                } label: {
                    Image(systemName: isSelectingPhotos ? "xmark" : "checkmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .primaryTabHeaderButtonStyle()
                .accessibilityLabel(Text(isSelectingPhotos ? "common.cancel" : "journal.multiSelect"))

                Spacer(minLength: 0)

                Button {
                    withAnimation(.snappy(duration: 0.28)) {
                        displayMode = displayMode == .list ? .map : .list
                    }
                } label: {
                    Image(displayMode == .list ? "icon-mapview-outline" : "icon-timeview-outline")
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .frame(width: 40, height: 40)
                }
                .primaryTabHeaderButtonStyle()
                .accessibilityLabel(Text(displayMode == .list ? "journal.mapModeA11y" : "journal.listModeA11y"))

                if isSelectingPhotos {
                    Button(role: .destructive) {
                        Task { await deleteSelectedPhotos() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 20, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .primaryTabHeaderButtonStyle()
                    .disabled(selectedPhotoIDs.isEmpty)
                } else {
                    Button {
                        showsQuickPhotoPicker = true
                    } label: {
                        Group {
                            if isQuickImporting {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: "photo.badge.plus")
                                    .font(.system(size: 20, weight: .medium))
                            }
                        }
                        .frame(width: 40, height: 40)
                    }
                    .primaryTabHeaderButtonStyle()
                    .disabled(isQuickImporting)
                    .accessibilityLabel(Text("journal.newA11y"))
                }
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private var journalSummary: some View {
        HStack(alignment: .center) {
            Text(visiblePhotoDateRange)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 8)

            journalSyncStatus

            Text(String(format: String(localized: "journal.countFormat"), visiblePhotos.count))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var journalSyncStatus: some View {
        if journalSync.networkAccess == .offline, journalSync.hasPendingContent {
            Text("journal.waitNetworkTitle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        } else if case .syncing(let progress, _, _) = journalSync.state {
            let displayedProgress = min(1, max(0.02, progress))
            ZStack {
                Circle()
                    .stroke(.gray.opacity(0.65), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: displayedProgress)
                    .stroke(.orange, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 18, height: 18)
            .animation(.easeInOut(duration: 0.2), value: displayedProgress)
            .accessibilityLabel(Text("journal.syncingTitle"))
            .accessibilityValue(Text(displayedProgress, format: .percent))
        }
    }

    private var visiblePhotoDateRange: String {
        let dates = visiblePhotos.map { $0.image.capturedAt ?? $0.entry.createdAt }.sorted()
        guard let first = dates.first, let last = dates.last else { return "" }
        let calendar = Calendar.current
        let firstText = Self.fullDateFormatter.string(from: first)
        if calendar.isDate(first, inSameDayAs: last) { return firstText }
        let lastText = calendar.component(.year, from: first) == calendar.component(.year, from: last)
            ? Self.shortDateFormatter.string(from: last)
            : Self.fullDateFormatter.string(from: last)
        return "\(firstText)~\(lastText)"
    }

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = .current
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private var isSyncingJournal: Bool {
        if case .syncing = journalSync.state { return true }
        return false
    }

    private var remoteTripID: Int? {
        guard syncEngine.isUserAuthenticated,
              let tripID = syncEngine.selectedTripID,
              tripID > 0 else { return nil }
        return tripID
    }

    private func presentErrorUnlessOffline(_ error: Error) {
        let offlineCodes: Set<URLError.Code> = [
            .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
        ]
        if let urlError = error as? URLError, offlineCodes.contains(urlError.code) {
            return
        }
        errorMessage = error.localizedDescription
    }

    private func journalPhoto(_ item: JournalPhotoItem) -> some View {
        ZStack(alignment: .bottomLeading) {
            JournalPhotoThumbnail(
                url: item.image.url.flatMap(URL.init(string:)),
                cacheKey: item.image.key,
                maxPixelSize: 1000
            )
                .frame(height: waterfallImageHeight(for: item.image))
                .frame(maxWidth: .infinity)
                .clipped()
            if let description = photoDescription(item.image) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.84)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                Text(description)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if isSelectingPhotos {
                Image(systemName: selectedPhotoIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(selectedPhotoIDs.contains(item.id) ? PrimaryTabPalette.accent : .white)
                    .padding(8)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 4) {
                if item.image.kind == "livePhoto" { Image(systemName: "livephoto") }
                if item.image.isHDR == true { Text("HDR") }
            }
            .font(.caption2.bold())
            .foregroundStyle(.white)
            .padding(6)
        }
        .onTapGesture {
            if isSelectingPhotos {
                if !selectedPhotoIDs.insert(item.id).inserted { selectedPhotoIDs.remove(item.id) }
            } else {
                presentPhotoViewer(startingAt: item.image.key)
            }
        }
        .contextMenu {
            Button("journal.editPhotoTitle", systemImage: "square.and.pencil") {
                photoEditor = JournalPhotoEditorContext(entryID: item.entry.id, image: item.image)
            }
            Button("journal.photoViewAction", systemImage: "arrow.up.left.and.arrow.down.right") {
                presentPhotoViewer(startingAt: item.image.key)
            }
        } preview: {
            JournalPhotoPreview(url: item.image.url.flatMap(URL.init(string:)), cacheKey: item.image.key)
        }
        .accessibilityLabel(item.image.description ?? String(localized: "journal.photoPinA11y"))
        .accessibilityHint(Text("journal.photoLongPressHint"))
    }

    private func waterfallImageHeight(for image: JournalImage) -> CGFloat {
        let variants: [CGFloat] = [168, 196, 224]
        let bucket = image.key.utf8.reduce(0) { ($0 + Int($1)) % variants.count }
        return variants[bucket]
    }

    private func photoDescription(_ image: JournalImage) -> String? {
        let value = (image.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func presentPhotoViewer(startingAt imageKey: String) {
        let photos = visiblePhotos.map {
            JournalPhotoViewer.Photo(
                id: $0.image.key,
                url: $0.image.url.flatMap(URL.init(string:)),
                description: $0.image.description,
                capturedAt: $0.image.capturedAt,
                media: $0.image
            )
        }
        guard let index = photos.firstIndex(where: { $0.id == imageKey }) else { return }
        listViewer = JournalListViewerContext(id: imageKey, photos: photos, initialIndex: index)
    }

    /// 顶部“添加照片”只有一个系统选择步骤；点系统对勾后立即创建手书记录。
    private func importQuickPhotos(_ values: [PhotosPickerItem]) async {
        guard !values.isEmpty else { return }
        isQuickImporting = true
        defer {
            isQuickImporting = false
        }
        do {
            var attachments: [JournalAttachment] = []
            for item in values.prefix(9) {
                attachments.append(try await JournalAttachment.load(from: item))
            }
            guard !attachments.isEmpty else { return }
            if attachments.contains(where: { $0.latitude == nil || $0.longitude == nil }),
               let fallback = await resolvedJournalLocation() {
                for index in attachments.indices
                where attachments[index].latitude == nil || attachments[index].longitude == nil {
                    attachments[index].latitude = fallback.latitude
                    attachments[index].longitude = fallback.longitude
                }
            }
            let capturedAt = attachments.compactMap(\.capturedAt).min() ?? .now
            let title = capturedAt.formatted(.dateTime.year().month().day())
            let entry = JournalEntry(
                id: 0,
                groupId: selectedGroupID,
                title: title,
                content: nil,
                images: [],
                createdAt: capturedAt,
                updatedAt: .now
            )
            await save(
                entry: entry,
                request: JournalEntryRequest(groupId: selectedGroupID, title: title, content: nil, imageKeys: []),
                attachments: attachments
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// PHPicker 在无完整照片库权限时可能移除 EXIF GPS。此时优先记录用户
    /// 已授权的当前位置；仍不可用时用当前行程首个有效地点，保证照片可进入地图。
    private func resolvedJournalLocation() async -> CLLocationCoordinate2D? {
        if let current = await JournalOneShotLocationProvider.resolve() { return current }
        return fallbackTripCoordinate
    }

    private func deleteEntry(_ entry: JournalEntry) {
        guard let index = visibleEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        deleteEntries(at: IndexSet(integer: index))
    }

    private func reload() async {
        guard let tripID = remoteTripID else {
            isLoading = false
            snapshot = localStore.snapshot
            return
        }
        let local = localStore.snapshot
        let cached = snapshotCache.snapshot(for: tripID)
        if let cached {
            snapshot = merge(remote: cached, local: local)
        } else if snapshot.entries.isEmpty && snapshot.groups.isEmpty {
            snapshot = local
        }
        guard journalSync.networkAccess != .offline else {
            isLoading = false
            return
        }
        isLoading = cached == nil && snapshot.entries.isEmpty
        defer {
            if remoteTripID == tripID { isLoading = false }
        }
        do {
            let remote = try await api.fetchJournal(tripID: tripID)
            // 用户可能在请求途中切换行程；旧响应绝不能覆盖当前行程的手书。
            guard remoteTripID == tripID else { return }
            try? snapshotCache.store(remote, for: tripID)
            snapshot = merge(remote: remote, local: localStore.snapshot)
            prefetchRemotePhotos(in: remote)
            if let selectedGroupID, !snapshot.groups.contains(where: { $0.id == selectedGroupID }) {
                self.selectedGroupID = nil
            }
        } catch {
            guard remoteTripID == tripID else { return }
            presentErrorUnlessOffline(error)
        }
    }

    private func merge(remote: JournalSnapshot, local: JournalSnapshot) -> JournalSnapshot {
        var groups: [Int: JournalGroup] = [:]
        for group in remote.groups { groups[group.id] = group }
        for group in local.groups { groups[group.id] = group }
        var entries: [Int: JournalEntry] = [:]
        for entry in remote.entries { entries[entry.id] = entry }
        for entry in local.entries { entries[entry.id] = entry }
        JournalSnapshot(
            groups: groups.values.sorted { $0.position < $1.position },
            entries: entries.values.sorted { $0.updatedAt > $1.updatedAt }
        )
    }

    private func prefetchRemotePhotos(in remote: JournalSnapshot) {
        let images = remote.entries.flatMap(\.images).filter {
            $0.kind == nil || $0.kind == "photo" || $0.kind == "livePhoto"
        }
        Task(priority: .utility) {
            for image in images {
                guard !Task.isCancelled,
                      let url = image.url.flatMap(URL.init(string:)) else { continue }
                _ = await JournalPhotoLoader.shared.thumbnail(
                    for: url,
                    maxPixelSize: 320,
                    cacheKey: image.key
                )
            }
        }
    }

    private func save(entry: JournalEntry, request: JournalEntryRequest, attachments: [JournalAttachment]) async {
        guard let tripID = remoteTripID, journalSync.networkAccess != .offline else {
            do {
                try localStore.save(entryID: entry.id == 0 ? nil : entry.id, request: request, attachments: attachments)
                if remoteTripID == nil {
                    snapshot = localStore.snapshot
                } else {
                    snapshot = merge(
                        remote: JournalSnapshot(
                            groups: snapshot.groups.filter { $0.id > 0 },
                            entries: snapshot.entries.filter { $0.id > 0 }
                        ),
                        local: localStore.snapshot
                    )
                }
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
            await reload()
        } catch {
            presentErrorUnlessOffline(error)
        }
    }

    /// 详情页快捷加照片：保留既有附件引用，追加新上传，复用编辑器的保存链路。
    private func addPhotos(entry: JournalEntry, attachments: [JournalAttachment]) async {
        guard let latest = snapshot.entries.first(where: { $0.id == entry.id }) else { return }
        let request = JournalEntryRequest(
            groupId: latest.groupId,
            title: latest.title,
            content: latest.content,
            imageKeys: latest.images.map(\.uploadReference)
        )
        await save(entry: latest, request: request, attachments: attachments)
    }

    /// 查看器里保存照片描述：整条 PATCH（imageKeys 携带全部元数据）或本地更新。
    private func updateImageMetadata(
        entryID: Int,
        imageKey: String,
        description: String,
        latitude: Double?,
        longitude: Double?
    ) async {
        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let latest = snapshot.entries.first(where: { $0.id == entryID }) else { return }
        guard let tripID = remoteTripID else {
            do {
                try localStore.updateImage(
                    entryID: latest.id,
                    imageKey: imageKey,
                    description: trimmed.isEmpty ? nil : trimmed,
                    latitude: latitude,
                    longitude: longitude
                )
                snapshot = localStore.snapshot
            } catch { errorMessage = error.localizedDescription }
            return
        }
        do {
            var images = latest.images
            guard let index = images.firstIndex(where: { $0.key == imageKey }) else { return }
            images[index].description = trimmed.isEmpty ? nil : trimmed
            images[index].latitude = latitude
            images[index].longitude = longitude
            let request = JournalEntryRequest(
                groupId: latest.groupId,
                title: latest.title,
                content: latest.content,
                imageKeys: images.map(\.uploadReference)
            )
            _ = try await api.updateJournalEntry(id: latest.id, request, tripID: tripID)
            await reload()
        } catch {
            presentErrorUnlessOffline(error)
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
        for index in offsets { let entry = visibleEntries[index]; Task { do { try await api.deleteJournalEntry(id: entry.id, tripID: tripID); await reload() } catch { presentErrorUnlessOffline(error) } } }
    }

    private func deleteSelectedPhotos() async {
        let keys = selectedPhotoIDs
        guard !keys.isEmpty else { return }
        if let tripID = remoteTripID {
            do {
                for entry in snapshot.entries where entry.images.contains(where: { keys.contains($0.key) }) {
                    let remaining = entry.images.filter { !keys.contains($0.key) }
                    if remaining.isEmpty {
                        try await api.deleteJournalEntry(id: entry.id, tripID: tripID)
                    } else {
                        let request = JournalEntryRequest(
                            groupId: entry.groupId,
                            title: entry.title,
                            content: entry.content,
                            imageKeys: remaining.map(\.uploadReference)
                        )
                        _ = try await api.updateJournalEntry(id: entry.id, request, tripID: tripID)
                    }
                }
                selectedPhotoIDs.removeAll()
                isSelectingPhotos = false
                await reload()
            } catch { presentErrorUnlessOffline(error) }
        } else {
            do {
                try localStore.deleteImages(keys)
                selectedPhotoIDs.removeAll()
                isSelectingPhotos = false
                snapshot = localStore.snapshot
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func saveGroup(_ request: JournalGroupRequest) async {
        guard let tripID = remoteTripID else {
            do {
                try localStore.createGroup(request)
                snapshot = localStore.snapshot
            } catch { errorMessage = error.localizedDescription }
            return
        }
        do { _ = try await api.createJournalGroup(request, tripID: tripID); await reload() } catch { presentErrorUnlessOffline(error) }
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
        do { try await api.deleteJournalGroup(id: group.id, tripID: tripID); if selectedGroupID == group.id { selectedGroupID = nil }; await reload() } catch { presentErrorUnlessOffline(error) }
    }

    private func upload(_ attachment: JournalAttachment, tripID: Int) async throws -> JournalMediaReference {
        let primaryKey = try await api.uploadJournalFile(
            at: attachment.primary.url,
            contentType: attachment.primary.contentType,
            fileName: attachment.primary.fileName,
            tripID: tripID
        )
        if attachment.kind == "photo" || attachment.kind == "livePhoto" {
            JournalPhotoLoader.shared.persistLocalPhoto(at: attachment.primary.url, key: primaryKey)
        }
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
            latitude: attachment.latitude,
            longitude: attachment.longitude,
            capturedAt: attachment.capturedAt,
            description: nil,
            isHDR: attachment.isHDR,
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
                pairedVideo: paired,
                latitude: attachment.latitude,
                longitude: attachment.longitude,
                capturedAt: attachment.capturedAt,
                description: nil,
                isHDR: attachment.isHDR
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

    func deleteImages(_ keys: Set<String>) throws {
        var entries: [JournalEntry] = []
        for entry in snapshot.entries {
            let removed = entry.images.filter { keys.contains($0.key) }
            for image in removed {
                if let url = image.url.flatMap(URL.init(string:)), url.isFileURL { try? FileManager.default.removeItem(at: url) }
                if let url = image.pairedVideo?.url.flatMap(URL.init(string:)), url.isFileURL { try? FileManager.default.removeItem(at: url) }
            }
            let remaining = entry.images.filter { !keys.contains($0.key) }
            guard !remaining.isEmpty else { continue }
            entries.append(JournalEntry(
                id: entry.id,
                groupId: entry.groupId,
                title: entry.title,
                content: entry.content,
                images: remaining,
                createdAt: entry.createdAt,
                updatedAt: removed.isEmpty ? entry.updatedAt : .now
            ))
        }
        snapshot = JournalSnapshot(groups: snapshot.groups, entries: entries)
        try persist()
    }

    /// 更新单张照片的描述（游客/离线路径，查看器与地图弹窗共用）。
    func updateImage(
        entryID: Int,
        imageKey: String,
        description: String?,
        latitude: Double?,
        longitude: Double?
    ) throws {
        guard let entryIndex = snapshot.entries.firstIndex(where: { $0.id == entryID }),
              let imageIndex = snapshot.entries[entryIndex].images.firstIndex(where: { $0.key == imageKey })
        else { return }
        var entries = snapshot.entries
        entries[entryIndex].images[imageIndex].description = description
        entries[entryIndex].images[imageIndex].latitude = latitude
        entries[entryIndex].images[imageIndex].longitude = longitude
        entries[entryIndex] = JournalEntry(
            id: entries[entryIndex].id,
            groupId: entries[entryIndex].groupId,
            title: entries[entryIndex].title,
            content: entries[entryIndex].content,
            images: entries[entryIndex].images,
            createdAt: entries[entryIndex].createdAt,
            updatedAt: .now
        )
        snapshot = JournalSnapshot(groups: snapshot.groups, entries: entries)
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

private struct JournalPhotoMetadataEditor: View {
    let onSave: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var description: String
    @State private var isSaving = false

    init(image: JournalImage, onSave: @escaping (String) async -> Void) {
        self.onSave = onSave
        _description = State(initialValue: image.description ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("journal.descriptionSection") {
                    TextField("journal.descriptionPlaceholder", text: $description, axis: .vertical)
                        .lineLimit(3...8)
                }
            }
            .navigationTitle("journal.editPhotoTitle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "journal.saving" : "common.save") {
                        isSaving = true
                        Task {
                            await onSave(description)
                            isSaving = false
                            dismiss()
                        }
                    }
                    .disabled(isSaving)
                }
            }
        }
    }

}

@MainActor
private final class JournalOneShotLocationProvider: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?
    private var timeoutTask: Task<Void, Never>?

    static func resolve() async -> CLLocationCoordinate2D? {
        let provider = JournalOneShotLocationProvider()
        return await provider.resolveLocation()
    }

    private func resolveLocation() async -> CLLocationCoordinate2D? {
        guard [.authorizedAlways, .authorizedWhenInUse].contains(manager.authorizationStatus) else {
            return nil
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.requestLocation()
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finish(nil)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.last?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        manager.delegate = nil
        continuation.resume(returning: coordinate)
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
