import Foundation
import SwiftData

/// 本机记录某两段卡片之间用户偏好的默认出行方式。仅保存在本设备，不与服务器同步，
/// 与卡包/路线缓存一致保持本机私有。`legKey` 用相邻两张卡片的本地 UUID 拼接，
/// 卡片重排后若再次相邻即可复用同一偏好。
@Model
final class CardLegPreference {
    @Attribute(.unique) var legKey: String
    var travelMode: String
    var createdAt: Date
    var updatedAt: Date

    init(legKey: String, travelMode: RouteMode = .driving) {
        self.legKey = legKey
        self.travelMode = travelMode.rawValue
        self.createdAt = .now
        self.updatedAt = .now
    }
}

@MainActor
final class CardLegStore {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) { self.modelContext = modelContext }

    static func legKey(origin: TravelCardSnapshot, destination: TravelCardSnapshot) -> String {
        "\(origin.id.uuidString)->\(destination.id.uuidString)"
    }

    func mode(for legKey: String) -> RouteMode {
        guard let record = try? modelContext.fetch(FetchDescriptor<CardLegPreference>()).first(where: { $0.legKey == legKey }),
              let mode = RouteMode(rawValue: record.travelMode) else { return .driving }
        return mode
    }

    func setMode(_ mode: RouteMode, for legKey: String) {
        if let record = try? modelContext.fetch(FetchDescriptor<CardLegPreference>()).first(where: { $0.legKey == legKey }) {
            record.travelMode = mode.rawValue
            record.updatedAt = .now
        } else {
            modelContext.insert(CardLegPreference(legKey: legKey, travelMode: mode))
        }
        try? modelContext.save()
    }
}
