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
        ("checklist", String(localized: "memolistsymbol.list")), ("suitcase", String(localized: "memolistsymbol.luggage")), ("cart", String(localized: "memolistsymbol.shopping")),
        ("list.bullet", String(localized: "memolistsymbol.todo")), ("airplane", String(localized: "memolistsymbol.travel")), ("stethoscope", String(localized: "memolistsymbol.medical")),
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
                Section("memolisteditor.listLabel") {
                    TextField("memolisteditor.titlePlaceholder", text: $title)
                    symbolPicker
                }
                Section("memolisteditor.itemsSection") {
                    if drafts.isEmpty {
                        Text("memolisteditor.itemsEmpty").font(.subheadline).foregroundStyle(.secondary)
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
                                TextField("memolisteditor.itemPlaceholder", text: $draft.name)
                                    .textInputAutocapitalization(.sentences)
                            }
                        }
                        .onDelete { offsets in drafts.remove(atOffsets: offsets) }
                        .onMove { from, to in drafts.move(fromOffsets: from, toOffset: to) }
                    }
                    HStack {
                        Image(systemName: "plus.circle").foregroundStyle(.secondary)
                        TextField("memolisteditor.addItemPlaceholder", text: $newItemName)
                            .textInputAutocapitalization(.sentences)
                            .onSubmit(addItem)
                    }
                }
                Section {
                    Label("memolisteditor.localNote", systemImage: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(list == nil ? "memolisteditor.addTitle" : "memolisteditor.editTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("common.save", action: save).disabled(!canSave) }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton().disabled(drafts.isEmpty)
                }
            }
            .alert("memolisteditor.cannotSave", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("common.ok", role: .cancel) { errorMessage = nil }
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
            errorMessage = String(localized: "memolisteditor.errorTitle")
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
            errorMessage = String(format: String(localized: "memolisteditor.saveFailed"), error.localizedDescription)
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
