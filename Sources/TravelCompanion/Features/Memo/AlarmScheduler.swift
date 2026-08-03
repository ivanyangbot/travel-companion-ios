import AlarmKit
import ActivityKit
import Foundation
import SwiftUI

/// 通过 AlarmKit 安排「明日闹钟」。AlarmKit 在 iOS 26 提供系统级显著闹钟，
/// 会以 Live Activity 形式响铃，比本地通知更接近系统时钟闹钟的体验。
@MainActor
final class AlarmScheduler: ObservableObject {
    @Published private(set) var authorizationState: AlarmManager.AuthorizationState = .notDetermined
    @Published var errorMessage: String?

    init() {
        authorizationState = AlarmManager.shared.authorizationState
    }

    /// 确保已获得闹钟授权；未授权时弹出系统请求。返回是否可用。
    func ensureAuthorization() async -> Bool {
        if authorizationState == .authorized { return true }
        do {
            let state = try await AlarmManager.shared.requestAuthorization()
            authorizationState = state
            return state == .authorized
        } catch {
            errorMessage = "无法获取闹钟授权：\(error.localizedDescription)"
            return false
        }
    }

    /// 安排一次固定时间的闹钟（fireDate 为具体触发时刻，建议落在「明日」）。
    /// 返回是否成功；失败信息写入 errorMessage。
    func scheduleAlarm(title: String, fireDate: Date) async -> Bool {
        let granted = await ensureAuthorization()
        guard granted else { return false }
        guard fireDate > .now else {
            errorMessage = "建议的闹钟时间 \(Self.timeFormatter.string(from: fireDate)) 已经过去，请手动选择一个时间。"
            return false
        }
        let stopButton = AlarmButton(text: "停止", textColor: .white, systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: title),
            stopButton: stopButton,
            secondaryButton: nil,
            secondaryButtonBehavior: nil
        )
        let presentation = AlarmPresentation(alert: alert, countdown: nil, paused: nil)
        let attributes = AlarmAttributes(presentation: presentation, metadata: MemoAlarmMetadata(), tintColor: .indigo)
        let configuration = AlarmManager.AlarmConfiguration<MemoAlarmMetadata>.alarm(
            schedule: .fixed(fireDate),
            attributes: attributes
        )
        do {
            _ = try await AlarmManager.shared.schedule(id: UUID(), configuration: configuration)
            return true
        } catch {
            errorMessage = "无法添加闹钟：\(error.localizedDescription)"
            return false
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter
    }()
}

/// 空实现：AlarmKit 的 AlarmAttributes 需要一个 Metadata 类型承载自定义内容，
/// 这里不需要附加信息，留空即可。
struct MemoAlarmMetadata: AlarmMetadata {}
