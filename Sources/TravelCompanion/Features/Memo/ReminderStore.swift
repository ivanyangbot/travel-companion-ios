import EventKit
import Foundation
import SwiftUI

/// 用 EventKit 创建系统「提醒事项」。提醒事项只在本机提醒事项 App 中可见，
/// 与行程数据互不同步，由用户决定是否写入。
@MainActor
final class ReminderStore: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var errorMessage: String?

    private let store = EKEventStore()

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
    }

    /// 请求提醒事项写权限（full access 是提醒事项的最低可用档）。已授权时直接返回。
    func ensureAuthorization() async -> Bool {
        switch authorizationStatus {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            do {
                let granted = try await store.requestFullAccessToReminders()
                authorizationStatus = EKEventStore.authorizationStatus(for: .reminder)
                return granted
            } catch {
                errorMessage = "无法获取提醒事项授权：\(error.localizedDescription)"
                return false
            }
        default:
            errorMessage = "请在系统设置中开启「同行」的提醒事项权限。"
            return false
        }
    }

    /// 创建一条提醒事项；due 为可选的具体触发时刻。
    func createReminder(title: String, notes: String?, due: Date?) async -> Bool {
        let granted = await ensureAuthorization()
        guard granted else { return false }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        do {
            try store.save(reminder, commit: true)
            return true
        } catch {
            errorMessage = "无法创建提醒事项：\(error.localizedDescription)"
            return false
        }
    }
}
