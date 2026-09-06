import SwiftUI

extension Notification.Name {
    /// 手书 agent 提交成功后广播（object 为 trip id）：手书数据不在
    /// SyncEngine，NotesView 收到后在下次出现时重拉列表。
    static let agentJournalEntriesDidChange = Notification.Name("agentJournalEntriesDidChange")
}

/// 主 tab 对应的 Agent 身份。`rawValue` 即服务端 v2 turn / commit 信封的
/// `agent` 字段与推荐接口的 `mode` 值；新增 agent 时后端
/// `app/services/agent_v2_agents.py` 需同步注册。
enum AgentKind: String, CaseIterable, Sendable, Hashable {
    case itinerary
    case ledger
    case journal

    /// 服务端默认（不发送该字段）即 itinerary；显式发送保持一致性。
    var wireValue: String { rawValue }

    /// 推荐接口的 mode：itinerary 沿用服务端默认 nil，无 trip 时统一回退
    /// "journey"（由调用方处理）。
    var suggestionsMode: String? { self == .itinerary ? nil : rawValue }
}

/// 每个 agent 的主题色与文案 key。三个 tab 统一使用品牌橙色，按钮保持
/// 同一豆奶动画形象，仅切换无障碍标签来反映当前 agent 身份。
enum AgentTheme {
    static func accent(for _: AgentKind) -> Color {
        PrimaryTabPalette.accent
    }

    static func buttonBackground(for kind: AgentKind) -> Color {
        accent(for: kind)
    }

    static func nameKey(for kind: AgentKind) -> String {
        switch kind {
        case .itinerary: "agent.name.itinerary"
        case .ledger: "agent.name.ledger"
        case .journal: "agent.name.journal"
        }
    }

    static func roleKey(for kind: AgentKind) -> String {
        switch kind {
        case .itinerary: "agent.role.itinerary"
        case .ledger: "agent.role.ledger"
        case .journal: "agent.role.journal"
        }
    }

    static func welcomeTitleKey(for kind: AgentKind) -> String {
        switch kind {
        case .itinerary: "agent.welcomeTitle"
        case .ledger: "agent.ledgerWelcomeTitle"
        case .journal: "agent.journalWelcomeTitle"
        }
    }

    static func summonA11yKey(for kind: AgentKind) -> String {
        switch kind {
        case .itinerary: "root.summonAgentA11y"
        case .ledger: "root.summonLedgerAgentA11y"
        case .journal: "root.summonJournalAgentA11y"
        }
    }
}
