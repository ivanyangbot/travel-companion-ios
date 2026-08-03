import SwiftData
import SwiftUI

/// 编辑一条备忘清单：标题、图标与若干物品。新建用草稿承载，保存时写入；
/// 编辑既有清单时同样用草稿，保存时用草稿重建物品以保留勾选状态。
struct MemoListEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let list: LocalMemoList?
    let onSaved: (String, String) -> Void

    @State private var title: String
    @State private var symbol: String
    @State private var drafts: [ItemDraft]
    @State private var newItemName = ""
    @State private var errorMessage: String?

    private static let symbols: [(String, String)] = [
        ("checklist", "清单"), ("suitcase", "行李"), ("cart", "采购"),
        ("list.bullet", "待办"), ("airplane", "出行"), ("stethoscope", "医药"),
    ]

    init(list: LocalMemoList?, onSaved: @escaping (String, String) -> Void = { _, _ in }) {
        self.list = list
        self.onSaved = onSaved
        let sorted = (list?.items ?? []).sorted { $0.position < $1.position }
        _title = State(initialValue: list?.title ?? "")
        _symbol = State(initialValue: list?.symbol ?? "checklist")
        _drafts = State(initialValue: sorted.enumerated().map { index, item in
            ItemDraft(id: item.id, name: item.name, category: item.category, isChecked: item.isChecked, position: index)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("清单") {
                    TextField("标题，例如：行李清单", text: $title)
                    symbolPicker
                }
                Section("物品") {
                    if drafts.isEmpty {
                        Text("还没有物品，下面添加。").font(.subheadline).foregroundStyle(.secondary)
                    } else {
                        ForEach($drafts) { $draft in
                            HStack {
                                Button {
                                    $draft.isChecked.wrappedValue.toggle()
                                } label: {
                                    Image(systemName: draft.isChecked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(draft.isChecked ? .indigo : .secondary)
                                }
                                .buttonStyle(.plain)
                                TextField("物品名称", text: $draft.name)
                                    .textInputAutocapitalization(.sentences)
                            }
                        }
                        .onDelete { offsets in drafts.remove(atOffsets: offsets) }
                        .onMove { from, to in drafts.move(fromOffsets: from, toOffset: to) }
                    }
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        TextField("添加物品", text: $newItemName)
                            .textInputAutocapitalization(.sentences)
                            .onSubmit(addItem)
                    }
                }
                Section {
                    Label("清单与物品仅保存在本机，不与服务器同步。", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(list == nil ? "新建清单" : "编辑清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存", action: save).disabled(!canSave) }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton().disabled(drafts.isEmpty)
                }
            }
            .alert("无法保存", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private var symbolPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Self.symbols, id: \.0) { option in
                    Button {
                        symbol = option.0
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: option.0).font(.title3)
                            Text(option.1).font(.caption2)
                        }
                        .frame(width: 56, height: 56)
                        .foregroundStyle(symbol == option.0 ? Color.white : .primary)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(symbol == option.0 ? Color.indigo.opacity(0.85) : Color(.tertiarySystemBackground))
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.1)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var canSave: Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }
        return drafts.contains { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } || !newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func addItem() {
        let trimmed = newItemName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        drafts.append(ItemDraft(name: trimmed, position: drafts.count))
        newItemName = ""
    }

    private func save() {
        addItem()
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorMessage = "请填写清单标题。"
            return
        }
        let clean: [ItemDraft] = drafts
            .filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .enumerated()
            .map { index, draft in
                var updated = draft
                updated.position = index
                return updated
            }
        do {
            if let list {
                list.title = trimmedTitle
                list.symbol = symbol
                // Remove existing items and recreate from drafts so positions and names stay in sync.
                for item in list.items { modelContext.delete(item) }
                for draft in clean {
                    let item = LocalMemoItem(name: draft.name, position: draft.position, category: draft.category, notes: nil)
                    item.isChecked = draft.isChecked
                    list.items.append(item)
                }
                list.updatedAt = .now
            } else {
                let newList = LocalMemoList(title: trimmedTitle, symbol: symbol)
                for draft in clean {
                    let item = LocalMemoItem(name: draft.name, position: draft.position, category: draft.category, notes: nil)
                    item.isChecked = draft.isChecked
                    newList.items.append(item)
                }
                modelContext.insert(newList)
            }
            try modelContext.save()
            onSaved(trimmedTitle, symbol)
            dismiss()
        } catch {
            errorMessage = "无法保存清单：\(error.localizedDescription)"
        }
    }
}

private struct ItemDraft: Identifiable {
    let id: UUID
    var name: String
    var category: String?
    var isChecked: Bool
    var position: Int

    init(id: UUID = UUID(), name: String, category: String? = nil, isChecked: Bool = false, position: Int = 0) {
        self.id = id
        self.name = name
        self.category = category
        self.isChecked = isChecked
        self.position = position
    }
}
