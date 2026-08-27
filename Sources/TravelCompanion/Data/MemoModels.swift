import Foundation
import SwiftData

/// 本机物品清单：可承载多条清单（如「行李」「待办」「采购」），每条含若干可勾选项。
/// 仅保存在本设备，不与服务器同步，与卡包一致保持本机私有。
@Model
final class LocalMemoList {
    @Attribute(.unique) var id: UUID
    var title: String
    var symbol: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \LocalMemoItem.list) var items: [LocalMemoItem]

    init(id: UUID = UUID(), title: String, symbol: String = "checklist") {
        self.id = id
        self.title = title
        self.symbol = symbol
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
