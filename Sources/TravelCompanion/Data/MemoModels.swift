import Foundation
import SwiftData

/// Shared memo cache. Signed-in trips synchronize these stable UUIDs with the server;
/// SwiftData keeps the checklist usable while offline.
@Model
final class LocalMemoList {
    @Attribute(.unique) var id: UUID
    var title: String
    var symbol: String
    var tripID: Int?
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \LocalMemoItem.list) var items: [LocalMemoItem]

    init(id: UUID = UUID(), title: String, symbol: String = "checklist", tripID: Int? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.tripID = tripID
        self.createdAt = .now
        self.updatedAt = .now
        self.items = []
    }
}

@Model
final class LocalMemoItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var isChecked: Bool
    var position: Int
    var category: String?
    var notes: String?
    var createdAt: Date
    var updatedAt: Date
    var list: LocalMemoList?

    init(id: UUID = UUID(), name: String, position: Int = 0, category: String? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.isChecked = false
        self.position = position
        self.category = category
        self.notes = notes
        self.createdAt = .now
        self.updatedAt = .now
    }
}

enum MemoListSeed {
    /// 预置一条「行李清单」，让首次进入备忘的用户有可见的起点，也可被 AI 物品建议补全。
    static func ensureDefaultList(context: ModelContext) {
        let descriptor = FetchDescriptor<LocalMemoList>()
        if let existing = try? context.fetch(descriptor), !existing.isEmpty { return }
        let list = LocalMemoList(title: String(localized: "preset.listTitle"), symbol: "suitcase")
        let presets = [String(localized: "preset.item.passport"), String(localized: "preset.item.idCard"), String(localized: "preset.item.cashCards"), String(localized: "preset.item.powerBank"), String(localized: "preset.item.adapter"), String(localized: "preset.item.medicine")]
        for (index, name) in presets.enumerated() {
            list.items.append(LocalMemoItem(name: name, position: index))
        }
        context.insert(list)
        try? context.save()
    }
}

struct SharedMemoListSnapshot: Codable, Sendable {
    let id: UUID
    let title: String
    let symbol: String
    let createdAt: Date
    let updatedAt: Date
    let items: [SharedMemoItemSnapshot]
}

struct SharedMemoItemSnapshot: Codable, Sendable {
    let id: UUID
    let name: String
    let isChecked: Bool
    let position: Int
    let category: String?
    let notes: String?
    let createdAt: Date
    let updatedAt: Date
}

struct SharedMemoListRequest: Codable, Sendable {
    let title: String
    let symbol: String
    let items: [SharedMemoItemRequest]

    init(_ list: LocalMemoList) {
        title = list.title
        symbol = list.symbol
        items = list.items.sorted { $0.position < $1.position }.map(SharedMemoItemRequest.init)
    }
}

struct SharedMemoItemRequest: Codable, Sendable {
    let id: UUID
    let name: String
    let isChecked: Bool
    let position: Int
    let category: String?
    let notes: String?

    init(_ item: LocalMemoItem) {
        id = item.id
        name = item.name
        isChecked = item.isChecked
        position = item.position
        category = item.category
        notes = item.notes
    }
}

struct DeletedMemoItem: Decodable, Sendable {
    let deleted: Bool
    let id: UUID
}

@MainActor
enum SharedMemoCache {
    static func replace(with remote: [SharedMemoListSnapshot], tripID: Int, context: ModelContext) throws {
        let local = try context.fetch(FetchDescriptor<LocalMemoList>())
        let remoteIDs = Set(remote.map(\.id))
        for stale in local where stale.tripID == tripID && !remoteIDs.contains(stale.id) { context.delete(stale) }
        for snapshot in remote {
            let list = local.first { $0.id == snapshot.id } ?? LocalMemoList(id: snapshot.id, title: snapshot.title, symbol: snapshot.symbol, tripID: tripID)
            if list.modelContext == nil { context.insert(list) }
            list.tripID = tripID
            list.title = snapshot.title
            list.symbol = snapshot.symbol
            list.createdAt = snapshot.createdAt
            list.updatedAt = snapshot.updatedAt
            let existing = Dictionary(uniqueKeysWithValues: list.items.map { ($0.id, $0) })
            let itemIDs = Set(snapshot.items.map(\.id))
            for stale in list.items where !itemIDs.contains(stale.id) { context.delete(stale) }
            for value in snapshot.items {
                let item = existing[value.id] ?? LocalMemoItem(id: value.id, name: value.name)
                item.name = value.name
                item.isChecked = value.isChecked
                item.position = value.position
                item.category = value.category
                item.notes = value.notes
                item.createdAt = value.createdAt
                item.updatedAt = value.updatedAt
                if item.list == nil { list.items.append(item) }
            }
        }
        try context.save()
    }
}

@MainActor
enum AgentChecklistPersistence {
    enum SaveError: LocalizedError {
        case invalid, missingList
        var errorDescription: String? {
            switch self {
            case .invalid: "请填写清单标题和事项，每份清单最多 50 项。"
            case .missingList: "目标清单已被删除，请重新选择保存位置。"
            }
        }
    }

    static func key(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Merge only the proposed items; never delete unrelated existing memo entries.
    static func save(_ draft: AgentV2Checklist, to targetID: UUID?, context: ModelContext) throws -> AgentV2Checklist {
        guard draft.isValid else { throw SaveError.invalid }
        let lists = try context.fetch(FetchDescriptor<LocalMemoList>())
        let list: LocalMemoList
        if let targetID {
            guard let existing = lists.first(where: { $0.id == targetID }) else { throw SaveError.missingList }
            list = existing
        } else if let existing = lists.first(where: { $0.id == draft.id }) {
            list = existing
        } else {
            list = LocalMemoList(id: draft.id, title: draft.title.trimmingCharacters(in: .whitespacesAndNewlines))
            context.insert(list)
        }
        var result = draft
        var byName: [String: LocalMemoItem] = [:]
        for item in list.items.sorted(by: { $0.position < $1.position }) where byName[key(item.name)] == nil {
            byName[key(item.name)] = item
        }
        var nextPosition = (list.items.map(\.position).max() ?? -1) + 1
        var seen = Set<String>()
        result.items = []
        for var item in draft.items {
            let name = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = key(name)
            guard seen.insert(normalized).inserted else { continue }
            let linked = draft.savedListID == list.id ? list.items.first(where: { $0.id == item.memoItemID }) : nil
            let stored: LocalMemoItem
            if let existing = byName[normalized] ?? linked {
                stored = existing
                if linked?.id == stored.id {
                    byName.removeValue(forKey: key(stored.name))
                    stored.name = name
                    stored.isChecked = item.isChecked
                    stored.notes = item.note
                } else {
                    stored.isChecked = stored.isChecked || item.isChecked
                    if let note = item.note, !note.isEmpty { stored.notes = note }
                }
            } else {
                stored = LocalMemoItem(name: name, position: nextPosition, notes: item.note)
                stored.isChecked = item.isChecked
                nextPosition += 1
                list.items.append(stored)
            }
            stored.updatedAt = .now
            byName[normalized] = stored
            item.memoItemID = stored.id
            item.isChecked = stored.isChecked
            item.note = stored.notes
            result.items.append(item)
        }
        if list.id == draft.id { list.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines) }
        list.updatedAt = .now
        do { try context.save() } catch { context.rollback(); throw error }
        result.savedListID = list.id
        result.savedContent = result.contentSignature
        return result
    }
}
