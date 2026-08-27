import Foundation

/// 备忘智能助手请求体：把共享行程快照脱敏后发给后端 AI，让模型基于「明日」的安排给出
/// 起床闹钟、提醒事项和物品建议。和现有 AI 草案接口一致，原文不上传、不在服务端落库。
struct MemoAssistRequest: Encodable, Sendable {
    struct Itinerary: Encodable, Sendable {
        let destination: String?
        let startDate: String?
        let endDate: String?
        let currency: String?
        let days: [Day]
    }

    struct Day: Encodable, Sendable {
        let date: String
        let cards: [Card]
    }

    struct Card: Encodable, Sendable {
        let kind: String
        let title: String
        let startAt: Date?
        let endAt: Date?
        let place: String?
        let fromAirport: String?
        let toAirport: String?
        let notes: String?
    }

    let itinerary: Itinerary
    /// 关注的「明日」日期（yyyy-MM-dd），模型据此挑选需要闹钟/提醒的安排。
    let tomorrowDate: String
}

/// AI 返回的建议结果。客户端按需一键添加：闹钟走 AlarmKit，提醒走 EventKit，物品写入本机清单。
struct MemoAssistResult: Decodable, Sendable {
    struct Alarm: Decodable, Sendable, Identifiable {
        var id = UUID()
        let title: String
        /// HH:mm（设备本地时区）
        let time: String
        let reason: String?
        enum CodingKeys: String, CodingKey { case title, time, reason }
    }

    struct Reminder: Decodable, Sendable, Identifiable {
        var id = UUID()
        let title: String
        let notes: String?
        /// yyyy-MM-dd，可选
        let dueDate: String?
        /// HH:mm，可选
        let dueTime: String?
        enum CodingKeys: String, CodingKey { case title, notes, dueDate, dueTime }
    }

    struct Item: Decodable, Sendable, Identifiable {
        var id = UUID()
        let name: String
        let category: String?
        let notes: String?
        enum CodingKeys: String, CodingKey { case name, category, notes }
    }

    let alarms: [Alarm]
    let reminders: [Reminder]
    let items: [Item]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alarms = try container.decodeIfPresent([Alarm].self, forKey: .alarms) ?? []
        reminders = try container.decodeIfPresent([Reminder].self, forKey: .reminders) ?? []
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
    }

    enum CodingKeys: String, CodingKey { case alarms, reminders, items }

    static let empty = MemoAssistResult(alarms: [], reminders: [], items: [])

    private init(alarms: [Alarm], reminders: [Reminder], items: [Item]) {
        self.alarms = alarms
        self.reminders = reminders
        self.items = items
    }
}

enum MemoAssistError: LocalizedError {
    case tripNotConfigured

    var errorDescription: String? {
        switch self {
        case .tripNotConfigured: String(localized: "error.memoTripNotConfigured")
        }
    }
}
