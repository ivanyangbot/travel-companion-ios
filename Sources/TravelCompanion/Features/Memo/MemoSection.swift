import SwiftData
import SwiftUI

/// 账本页的备忘分区。清单数据只在本设备保存；新建入口由账本页右上角
/// 的统一加号承载，智能操作统一交给右下角的账本 Agent。
struct MemoSection: View {
    @Binding var creatingList: Bool
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocalMemoList.updatedAt, order: .reverse) private var lists: [LocalMemoList]

    @State private var editingList: LocalMemoList?
    @State private var pendingDeletion: LocalMemoList?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("memo.title")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("memo.subtitle")
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)

            if lists.isEmpty {
                ContentUnavailableView(
                    "memo.emptyTitle",
                    systemImage: "checklist",
                    description: Text("memo.emptyDesc")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 112)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(lists) { list in
                            listCard(list)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 128)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(PrimaryTabPalette.background)
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $creatingList) {
            MemoListEditor(list: nil) { _, _ in }
        }
        .sheet(item: $editingList) { list in
            MemoListEditor(list: list) { _, _ in }
        }
        .alert("memo.deleteTitle", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { list in
            Button("common.delete", role: .destructive) {
                modelContext.delete(list)
                try? modelContext.save()
                pendingDeletion = nil
            }
            Button("common.cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("memo.deleteMessage")
        }
        .task { MemoListSeed.ensureDefaultList(context: modelContext) }
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
}
