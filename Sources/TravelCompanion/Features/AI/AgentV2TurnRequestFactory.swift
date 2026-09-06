import Foundation

/// 从会话与行程快照组装 v2 turn 请求。抽成无 UI 依赖的结构以便单测：
/// - 无生效旅程（或新建规划模式）：所有 agent 统一回退 plan_new（行程
///   agent），由服务端产出待确认的旅程提案。
/// - ledger：完整行程信封（含卡片实际价）+ 费用/备忘/卡包快照。
/// - journal：行程信封 + 手书快照（由调用方现拉）。
struct AgentV2TurnRequestFactory {
    let agent: AgentKind
    let session: AgentV2LocalSession
    let trip: SharedTripSnapshot?
    var journalContext: AgentV2TurnRequest.JournalContext? = nil
    var memoItems: [AgentV2TurnRequest.ReferenceItem] = []
    var walletItems: [AgentV2TurnRequest.ReferenceItem] = []
    var plansNewTrip: Bool = false

    /// 与服务端 schemas.py AGENT_LEDGER_EXPENSE_SNAPSHOT_MAXIMUM 对齐。
    static let expenseSnapshotLimit = 60
    /// 备忘/卡包各 50 条，与服务端 normalize_agent_reference_snapshot 上限一致。
    static let referenceSnapshotLimit = 50

    func makeRequest(message: String, includePendingAttachments: Bool = true) -> AgentV2TurnRequest {
        let attachments = includePendingAttachments ? session.attachments : []
        let history = AgentV2TurnRequest.trimmedHistory(session.messages)
        guard !plansNewTrip, let trip, trip.isConfigured else {
            return AgentV2TurnRequest(
                sessionId: session.id,
                turnId: UUID(),
                intent: "plan_new",
                message: message,
                trip: nil,
                preferences: session.preferences,
                history: history,
                activeDraft: session.draft,
                attachments: attachments
            )
        }
        var request = AgentV2TurnRequest(
            sessionId: session.id,
            turnId: UUID(),
            intent: agent == .itinerary ? "itinerary" : agent.rawValue,
            message: agent == .ledger ? Self.ledgerMessage(message) : message,
            trip: Self.tripEnvelope(for: trip, includeActualPrices: agent == .ledger),
            preferences: session.preferences,
            history: history,
            activeDraft: session.draft,
            attachments: attachments
        )
        request.agent = agent.wireValue
        switch agent {
        case .itinerary:
            break
        case .ledger:
            request.expenses = Self.expenseSnapshot(from: trip)
            if !memoItems.isEmpty { request.memos = memoItems }
            if !walletItems.isEmpty { request.walletCards = walletItems }
        case .journal:
            request.journal = journalContext
        }
        return request
    }

    /// 行程信封：与原 makeRequest 同构；账本 agent 额外携带卡片实际价，
    /// 行程 agent 的线上格式保持逐字节一致。
    static func tripEnvelope(for trip: SharedTripSnapshot, includeActualPrices: Bool) -> AgentV2TurnRequest.Trip {
        // ISO8601DateFormatter is mutable and non-Sendable. Keep it scoped to
        // this request instead of sharing one instance across actor contexts.
        let formatter = ISO8601DateFormatter()
        let days = trip.days.map { day in
            AgentV2TurnRequest.Day(date: day.date, cards: day.cards.map { card in
                AgentV2TurnRequest.Card(
                    id: card.serverID,
                    kind: card.kind.rawValue,
                    title: card.title,
                    startAt: formatter.string(from: card.startAt),
                    endAt: card.endAt.map { formatter.string(from: $0) },
                    place: card.place?.name,
                    notes: card.notes,
                    hotelVisits: card.hotelVisits,
                    roomType: card.roomType,
                    priceMinor: card.priceMinor,
                    priceCurrency: card.priceCurrency ?? trip.currency,
                    actualPriceMinor: includeActualPrices ? card.actualPriceMinor : nil,
                    timeZone: card.place?.timeZone
                )
            })
        }
        return AgentV2TurnRequest.Trip(
            destination: trip.destination,
            startDate: trip.startDate,
            endDate: trip.endDate,
            currency: trip.currency,
            timeZone: TimeZone.current.identifier,
            version: trip.version,
            days: days
        )
    }

    /// 费用快照：按发生日倒序取最近 60 条；离线创建（尚无服务端 ID）的
    /// 记录不下发；上下文备注按接口上限取 200 字符，不修改原始账目。
    static func expenseSnapshot(from trip: SharedTripSnapshot) -> [AgentV2TurnRequest.ExpenseSnapshotItem] {
        let formatter = ISO8601DateFormatter()
        return trip.expenses
            .sorted { $0.occurredOn > $1.occurredOn }
            .compactMap { expense in
                guard let id = expense.serverID else { return nil }
                return AgentV2TurnRequest.ExpenseSnapshotItem(
                    id: id,
                    amountMinor: expense.amountMinor,
                    currency: expense.currency,
                    category: expense.category.rawValue,
                    occurredOn: expense.occurredOn,
                    note: expense.note.map { String($0.prefix(200)) },
                    cardIds: expense.cardIDs,
                    settlementAmountMinor: expense.settlementAmountMinor,
                    spentAt: expense.spentAt.map { formatter.string(from: $0) },
                    paidAt: expense.paidAt.map { formatter.string(from: $0) },
                    purchaseChannel: expense.purchaseChannel,
                    paymentMethod: expense.paymentMethod,
                    consumerUserId: expense.consumerUserID,
                    consumerName: expense.consumerName,
                    createdAt: formatter.string(from: expense.createdAt)
                )
            }
            .prefix(expenseSnapshotLimit)
            .map { $0 }
    }

    private static func ledgerMessage(_ userMessage: String) -> String {
        """
        \(userMessage)

        [Ledger output rules]
        Keep expense notes strictly concise. Put transaction time, payment time, merchant/platform, payment method, consumer, linked itinerary cards, amount, currency, and category in their dedicated structured fields, never in notes. Notes may contain only a user-stated reconciliation detail that has no structured field; otherwise return notes as null. Do not copy booking descriptions, cancellation policies, exchange-rate disclaimers, confirmations, or generic advice into notes. Limit any note to 80 characters. When evidence is available, populate spentAt (ISO 8601), paidAt (actual payment time when already paid, expected payment time for pay-on-arrival, or empty when unpaid), purchaseChannel, paymentMethod, consumerUserId/consumerName, and cardIds (JSON array of itinerary card IDs; one expense may cover several cards). paymentMethod must be one of cash, credit_card, debit_card, alipay, wechat_pay, apple_pay, bank_transfer, or other.
        """
    }

    /// 备忘物品引用：id 为顺序编号（仅轮内引用），仅未勾选项对记账有意义，
    /// 已勾选（已购/已办）的物品也保留——补录历史开销同样需要。
    static func memoSnapshot(items: [(name: String, notes: String?)]) -> [AgentV2TurnRequest.ReferenceItem] {
        items.prefix(referenceSnapshotLimit).enumerated().map { index, item in
            AgentV2TurnRequest.ReferenceItem(
                id: index + 1,
                title: String(item.name.prefix(160)),
                note: item.notes.map { String($0.prefix(200)) }
            )
        }
    }

    /// 卡包条目引用：只送标签与类型，加密的号码/备注永不离开本机。
    static func walletSnapshot(items: [(label: String, cardType: String?)]) -> [AgentV2TurnRequest.ReferenceItem] {
        items.prefix(referenceSnapshotLimit).enumerated().map { index, item in
            AgentV2TurnRequest.ReferenceItem(
                id: index + 1,
                title: String(item.label.prefix(160)),
                kind: item.cardType.map { String($0.prefix(40)) }
            )
        }
    }
}
