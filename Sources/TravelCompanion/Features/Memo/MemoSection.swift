import SwiftData
import SwiftUI

/// 「本」页的备忘分区：本机物品清单 + 智能生成入口。清单数据只在本设备保存，
/// 智能生成会把行程脱敏交给后端 AI，再在结果页一键写入闹钟/提醒/物品。
struct MemoSection: View {
    @ObservedObject var syncEngine: SyncEngine
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LocalMemoList.updatedAt, order: .reverse) private var lists: [LocalMemoList]

    @State private var editingList: LocalMemoList?
    @State private var creatingList = false
    @State private var pendingDeletion: LocalMemoList?
    @State private var showsAssist = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("物品清单").font(.title3.bold())
                Spacer()
                Button("智能生成", systemImage: "sparkles") { showsAssist = true }
                    .buttonStyle(.glass)
                    .disabled(syncEngine.trip?.isConfigured != true)
                    .accessibilityLabel("根据行程生成明日闹钟、提醒和物品")
                Button("添加清单", systemImage: "plus") { creatingList = true }
                    .buttonStyle(.glass)
            }
            .padding(.horizontal)
            .padding(.top, 8)

            if lists.isEmpty {
                ContentUnavailableView(
                    "还没有清单",
                    systemImage: "checklist",
                    description: Text("添加行李、待办等物品清单；或点「智能生成」让 AI 根据明日行程一键给出建议。")
                )
                .padding(.top, 48)
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(lists) { list in
                            listCard(list)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $creatingList) {
            MemoListEditor(list: nil) { _, _ in }
        }
        .sheet(item: $editingList) { list in
            MemoListEditor(list: list) { _, _ in }
        }
        .sheet(isPresented: $showsAssist) {
            MemoAssistSheet(syncEngine: syncEngine)
        }
        .alert("删除清单？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { list in
            Button("删除", role: .destructive) {
                modelContext.delete(list)
                try? modelContext.save()
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("清单及其所有物品会从本机删除，不可恢复。")
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
                Spacer()
                if !items.isEmpty {
                    Text("\(checked)/\(items.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .glassEffect(.regular, in: Capsule())
                }
                Menu {
                    Button("编辑", systemImage: "pencil") { editingList = list }
                    Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = list }
                } label: {
                    Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("\(list.title) 的更多操作")
            }
            if items.isEmpty {
                Text("还没有物品，点「编辑」添加。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    itemRow(item)
                }
            }
        }
        .padding(16)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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
                    .foregroundStyle(item.isChecked ? .indigo : .secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.subheadline)
                    .strikethrough(item.isChecked, color: .secondary)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                if let category = item.category, !category.isEmpty {
                    Text(category).font(.caption2).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
        }
    }
}
