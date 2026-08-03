import PhotosUI
import SwiftUI
import UIKit

struct NotesView: View {
    let syncEngine: SyncEngine

    @State private var snapshot = JournalSnapshot(groups: [], entries: [])
    @State private var selectedGroupID: Int?
    @State private var editor: JournalEntry?
    @State private var showsGroupEditor = false
    @State private var errorMessage: String?
    @State private var isLoading = false
    private let api = APIClient()

    private var visibleEntries: [JournalEntry] {
        snapshot.entries.filter { selectedGroupID == nil || $0.groupId == selectedGroupID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && snapshot.entries.isEmpty { ProgressView("正在加载手书…") }
                else if visibleEntries.isEmpty { ContentUnavailableView("记录这一刻", systemImage: "book.closed", description: Text("拍下旅途片段，写成属于你的手书。")) }
                else { List { ForEach(visibleEntries) { entry in journalCard(entry) } .onDelete(perform: deleteEntries) } .listStyle(.plain) }
            }
            .navigationTitle("手书")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Menu { Button("全部手书") { selectedGroupID = nil }; Divider(); ForEach(snapshot.groups) { group in Button(group.name) { selectedGroupID = group.id } }; Divider(); Button("管理分组", systemImage: "folder.badge.plus") { showsGroupEditor = true } } label: { Label(selectedGroupTitle, systemImage: "folder") } }
                ToolbarItem(placement: .topBarTrailing) { Button { editor = JournalEntry(id: 0, groupId: selectedGroupID, title: "", content: nil, images: [], createdAt: .now, updatedAt: .now) } label: { Image(systemName: "square.and.pencil") } }
            }
            .task { await reload() }
            .refreshable { await reload() }
            .sheet(item: $editor) { entry in JournalEditor(entry: entry.id == 0 ? nil : entry, groups: snapshot.groups, defaultGroupID: entry.groupId) { request, attachments in await save(entry: entry, request: request, attachments: attachments) } }
            .sheet(isPresented: $showsGroupEditor) { JournalGroupsEditor(groups: snapshot.groups) { await saveGroup($0) } onDelete: { group in await deleteGroup(group) } }
            .alert("操作未完成", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) { Button("好", role: .cancel) {} } message: { Text(errorMessage ?? "") }
        }
    }

    private var selectedGroupTitle: String { snapshot.groups.first(where: { $0.id == selectedGroupID })?.name ?? "全部" }

    private func journalCard(_ entry: JournalEntry) -> some View {
        Button { editor = entry } label: { VStack(alignment: .leading, spacing: 10) { if let first = entry.images.first?.url, let url = URL(string: first) { AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Rectangle().fill(.quaternary) }.frame(height: 180).clipShape(RoundedRectangle(cornerRadius: 14)); if entry.images.count > 1 { Text("\(entry.images.count) 张照片").font(.caption).foregroundStyle(.secondary) } }; Text(entry.title).font(.headline); if let content = entry.content, !content.isEmpty { Text(content).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }; HStack { if let group = snapshot.groups.first(where: { $0.id == entry.groupId }) { Label(group.name, systemImage: "folder.fill").foregroundStyle(.indigo) }; Spacer(); Text(entry.updatedAt, style: .date) }.font(.caption) } .padding(.vertical, 6) }.buttonStyle(.plain)
    }

    private var canUseCloudJournal: Bool { syncEngine.isUserAuthenticated }

    private func requireSignIn() {
        errorMessage = "手书同步需要先在“旅程”中登录 Apple 账户。"
    }

    private func reload() async {
        guard canUseCloudJournal else { return }
        isLoading = true
        defer { isLoading = false }
        do { snapshot = try await api.fetchJournal() } catch { errorMessage = error.localizedDescription }
    }

    private func save(entry: JournalEntry, request: JournalEntryRequest, attachments: [JournalAttachment]) async {
        guard canUseCloudJournal else { requireSignIn(); return }
        do { let keys = try await withThrowingTaskGroup(of: String.self) { group in for attachment in attachments { group.addTask { try await api.uploadJournalImage(data: attachment.data, contentType: "image/jpeg") } }; var all = request.imageKeys; for try await key in group { all.append(key) }; return all }; let request = JournalEntryRequest(groupId: request.groupId, title: request.title, content: request.content, imageKeys: keys); _ = entry.id == 0 ? try await api.createJournalEntry(request) : try await api.updateJournalEntry(id: entry.id, request); self.editor = nil; await reload() } catch { errorMessage = error.localizedDescription }
    }

    private func deleteEntries(at offsets: IndexSet) {
        guard canUseCloudJournal else { requireSignIn(); return }
        for index in offsets { let entry = visibleEntries[index]; Task { do { try await api.deleteJournalEntry(id: entry.id); await reload() } catch { errorMessage = error.localizedDescription } } }
    }

    private func saveGroup(_ request: JournalGroupRequest) async {
        guard canUseCloudJournal else { requireSignIn(); return }
        do { _ = try await api.createJournalGroup(request); await reload() } catch { errorMessage = error.localizedDescription }
    }

    private func deleteGroup(_ group: JournalGroup) async {
        guard canUseCloudJournal else { requireSignIn(); return }
        do { try await api.deleteJournalGroup(id: group.id); if selectedGroupID == group.id { selectedGroupID = nil }; await reload() } catch { errorMessage = error.localizedDescription }
    }
}

private struct JournalAttachment: Identifiable { let id = UUID(); let data: Data; let image: UIImage
    init?(_ image: UIImage) { let maxDimension: CGFloat = 1600; let scale = min(maxDimension / max(image.size.width, image.size.height), 1); let size = CGSize(width: image.size.width * scale, height: image.size.height * scale); let rendered = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }; guard let data = rendered.jpegData(compressionQuality: 0.78), data.count <= 12 * 1024 * 1024 else { return nil }; self.image = rendered; self.data = data }
}

private struct JournalEditor: View {
    let entry: JournalEntry?; let groups: [JournalGroup]; let defaultGroupID: Int?; let onSave: (JournalEntryRequest, [JournalAttachment]) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""; @State private var content = ""; @State private var groupID: Int?; @State private var attachments: [JournalAttachment] = []; @State private var pickerItems: [PhotosPickerItem] = []; @State private var showsCamera = false; @State private var isSaving = false
    var body: some View {
        NavigationStack {
            Form {
                Section("这一页") {
                    TextField("标题", text: $title)
                    Picker("归档分组", selection: $groupID) {
                        Text("未分组").tag(Int?.none)
                        ForEach(groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    TextEditor(text: $content).frame(minHeight: 150)
                }
                Section("照片") {
                    if !attachments.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(attachments) { item in
                                    ZStack(alignment: .topTrailing) {
                                        Image(uiImage: item.image).resizable().scaledToFill().frame(width: 100, height: 100).clipShape(RoundedRectangle(cornerRadius: 10))
                                        Button { attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill").symbolRenderingMode(.hierarchical) }.padding(4)
                                    }
                                }
                            }
                        }
                    }
                    PhotosPicker(selection: $pickerItems, maxSelectionCount: max(0, 9 - attachments.count), matching: .images) { Label("从相册添加", systemImage: "photo.on.rectangle") }
                    if CameraPicker.isAvailable { Button("拍照", systemImage: "camera") { showsCamera = true } }
                }
            }
            .navigationTitle(entry == nil ? "新建手书" : "编辑手书")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中…" : "保存") {
                        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                        isSaving = true
                        Task {
                            await onSave(JournalEntryRequest(groupId: groupID, title: title.trimmingCharacters(in: .whitespacesAndNewlines), content: content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : content, imageKeys: entry?.images.map(\.key) ?? []), attachments)
                            isSaving = false
                        }
                    }.disabled(isSaving)
                }
            }
            .onAppear { title = entry?.title ?? ""; content = entry?.content ?? ""; groupID = entry?.groupId ?? defaultGroupID }
            .onChange(of: pickerItems) { _, values in
                Task {
                    for item in values {
                        if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data), let attachment = JournalAttachment(image), attachments.count < 9 { attachments.append(attachment) }
                    }
                    pickerItems = []
                }
            }
            .sheet(isPresented: $showsCamera) { CameraPicker { if let attachment = JournalAttachment($0), attachments.count < 9 { attachments.append(attachment) } } }
        }
    }
}

private struct JournalGroupsEditor: View {
    let groups: [JournalGroup]; let onCreate: (JournalGroupRequest) async -> Void; let onDelete: (JournalGroup) async -> Void
    @Environment(\.dismiss) private var dismiss; @State private var name = ""; @State private var color = "indigo"
    var body: some View { NavigationStack { List { Section("新建分组") { TextField("如：东京 Day 1", text: $name); Picker("颜色", selection: $color) { ForEach(["indigo", "pink", "orange", "teal"], id: \.self) { Text($0).tag($0) } }; Button("创建分组") { let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty else { return }; Task { await onCreate(JournalGroupRequest(name: trimmed, color: color, position: groups.count)); name = "" } } }; Section("已有分组") { ForEach(groups) { group in HStack { Image(systemName: "folder.fill").foregroundStyle(.indigo); Text(group.name); Spacer(); Button(role: .destructive) { Task { await onDelete(group) } } label: { Image(systemName: "trash") } } } } }.navigationTitle("手书分组").toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } } } }
}
