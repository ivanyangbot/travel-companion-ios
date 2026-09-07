import SwiftData
import SwiftUI

/// 账本页的备忘分区。SwiftData serves as the offline cache; signed-in trips
/// synchronize the same checklist with every member of the shared trip.
struct MemoSection: View {
    @ObservedObject var syncEngine: SyncEngine
    @Binding var creatingList: Bool
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocalMemoList.updatedAt, order: .reverse) private var lists: [LocalMemoList]

    @State private var editingList: LocalMemoList?
    @State private var pendingDeletion: LocalMemoList?

    private var visibleLists: [LocalMemoList] {
        guard let tripID = syncEngine.selectedTripID else { return lists.filter { $0.tripID == nil } }
        return lists.filter { $0.tripID == tripID || $0.tripID == nil }
    }

    var body: some View {
        VStack(spacing: 0) {

            if visibleLists.isEmpty {
                ScrollView {
                    ContentUnavailableView(
                        "memo.emptyTitle",
                        systemImage: "checklist",
                        description: Text("memo.emptyDesc")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.bottom, 112)
                }
                .refreshable { await reload() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(visibleLists) { list in
                            listCard(list)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 128)
                }
                .scrollIndicators(.hidden)
                .refreshable { await reload() }
            }
        }
        .background(PrimaryTabPalette.background)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $creatingList) {
            MemoListEditor(list: nil) { list in saveAndBind(list) }
        }
        .sheet(item: $editingList) { list in
            MemoListEditor(list: list) { saved in saveAndBind(saved) }
        }
        .alert("memo.deleteTitle", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { list in
            Button("common.delete", role: .destructive) {
                let id = list.id
                modelContext.delete(list)
                try? modelContext.save()
                Task { try? await syncEngine.deleteSharedMemo(id: id) }
                pendingDeletion = nil
            }
            Button("common.cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("memo.deleteMessage")
        }
        .task(id: syncEngine.selectedTripID) { await reload() }
    }

    @ViewBuilder
    private func listCard(_ list: LocalMemoList) -> some View {
        let items = list.items.sorted { $0.position < $1.position }
        let checked = items.filter(\.isChecked).count
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(list.title, systemImage: list.symbol).font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if !items.isEmpty {
                    Text(String(format: String(localized: "memo.progressFormat"), checked, items.count))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(PrimaryTabPalette.surface, in: Capsule())
                }
                Menu {
                    Button("common.edit", systemImage: "pencil") { editingList = list }
                    Button("common.delete", systemImage: "trash", role: .destructive) { pendingDeletion = list }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(Text(String(format: String(localized: "common.moreActions"), list.title)))
            }
            if items.isEmpty {
                Text("memo.itemsEmpty")
                    .font(.subheadline)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            } else {
                ForEach(items) { item in
                    itemRow(item)
                }
            }
        }
        .padding(16)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        .contentShape(Rectangle())
        .onTapGesture { editingList = list }
    }

    @ViewBuilder
    private func itemRow(_ item: LocalMemoItem) -> some View {
        HStack(spacing: 12) {
            Button {
                item.isChecked.toggle()
                item.updatedAt = .now
                try? modelContext.save()
                if let list = item.list {
                    Task { try? await syncEngine.saveSharedMemo(list) }
                }
            } label: {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(item.isChecked ? PrimaryTabPalette.accent : PrimaryTabPalette.secondaryText)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .strikethrough(item.isChecked, color: PrimaryTabPalette.secondaryText)
                    .foregroundStyle(item.isChecked ? PrimaryTabPalette.secondaryText : .white.opacity(0.82))
                if let category = item.category, !category.isEmpty {
                    Text(category)
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.tertiaryText)
                }
            }
            Spacer(minLength: 4)
        }
    }

    private func reload() async {
        if syncEngine.isUserAuthenticated, syncEngine.selectedTripID != nil {
            do {
                let tripID = syncEngine.selectedTripID!
                // One-time migration for checklists created before shared sync existed.
                for list in lists where list.tripID == nil {
                    try await syncEngine.saveSharedMemo(list)
                    list.tripID = tripID
                }
                try? modelContext.save()
                var remote = try await syncEngine.fetchSharedMemos()
                let remoteByID = Dictionary(uniqueKeysWithValues: remote.map { ($0.id, $0) })
                var uploadedLocalChange = false
                for list in lists where list.tripID == tripID {
                    if let server = remoteByID[list.id], list.updatedAt > server.updatedAt {
                        try await syncEngine.saveSharedMemo(list)
                        uploadedLocalChange = true
                    }
                }
                if uploadedLocalChange { remote = try await syncEngine.fetchSharedMemos() }
                try SharedMemoCache.replace(with: remote, tripID: tripID, context: modelContext)
            } catch {
                // Cached checklists remain fully usable while offline.
            }
        } else {
            MemoListSeed.ensureDefaultList(context: modelContext)
        }
    }

    private func saveAndBind(_ list: LocalMemoList) {
        Task {
            do {
                try await syncEngine.saveSharedMemo(list)
                list.tripID = syncEngine.selectedTripID
                try? modelContext.save()
            } catch {
                // The SwiftData copy remains available and will be retried on refresh.
            }
        }
    }
}
