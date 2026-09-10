import Foundation

enum ExpenseCurrency {
    static let supported = [
        "CNY", "HKD", "IDR", "USD", "EUR", "GBP", "JPY", "SGD", "MYR", "THB", "KRW", "AUD", "CAD", "TWD", "VND",
    ]
}

enum ExpensePaymentMethod: String, Codable, CaseIterable, Sendable, Identifiable {
    case cash
    case creditCard = "credit_card"
    case debitCard = "debit_card"
    case alipay
    case wechatPay = "wechat_pay"
    case applePay = "apple_pay"
    case bankTransfer = "bank_transfer"
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: String(localized: "expense.payment.cash")
        case .creditCard: String(localized: "expense.payment.creditCard")
        case .debitCard: String(localized: "expense.payment.debitCard")
        case .alipay: String(localized: "expense.payment.alipay")
        case .wechatPay: String(localized: "expense.payment.wechatPay")
        case .applePay: String(localized: "expense.payment.applePay")
        case .bankTransfer: String(localized: "expense.payment.bankTransfer")
        case .other: String(localized: "expense.payment.other")
        }
    }
}

enum ExpenseCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case transport, lodging, food, tickets, shopping, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .transport: String(localized: "expense.category.transport")
        case .lodging: String(localized: "expense.category.lodging")
        case .food: String(localized: "expense.category.food")
        case .tickets: String(localized: "expense.category.tickets")
        case .shopping: String(localized: "expense.category.shopping")
        case .other: String(localized: "expense.category.other")
        }
    }
    var systemImage: String {
        switch self {
        case .transport: "tram"
        case .lodging: "bed.double"
        case .food: "fork.knife"
        case .tickets: "ticket"
        case .shopping: "bag"
        case .other: "ellipsis.circle"
        }
    }
}

enum ExpensePaidBy: String, Codable, CaseIterable, Sendable, Identifiable {
    case personA, personB
    var id: String { rawValue }
}

enum ExpenseSplitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case equal, `self`
    var id: String { rawValue }
    var title: String { self == .equal ? String(localized: "expense.split.equal") : String(localized: "expense.split.self") }
}

enum ExpenseMoney {
    static func fractionDigits(for currency: String) -> Int {
        // ISO 4217 currencies used most frequently in this MVP. Unknown codes use cents.
        switch currency.uppercased() {
        case "JPY", "KRW", "VND", "CLP", "ISK": 0
        case "BHD", "JOD", "KWD", "OMR", "TND": 3
        default: 2
        }
    }

    static func amountMinor(from input: String, currency: String) -> Int64? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let decimal = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")), decimal > 0 else { return nil }
        var scaled = decimal
        var source = decimal
        NSDecimalMultiplyByPowerOf10(&scaled, &source, Int16(fractionDigits(for: currency)), .plain)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled,
              rounded <= Decimal(Int64.max),
              rounded >= Decimal(1) else { return nil }
        return NSDecimalNumber(decimal: rounded).int64Value
    }

    static func formatted(_ amountMinor: Int64, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        formatter.maximumFractionDigits = fractionDigits(for: currency)
        formatter.minimumFractionDigits = fractionDigits(for: currency)
        return formatter.string(from: NSDecimalNumber(decimal: decimalAmount(amountMinor, currency: currency))) ?? "\(amountMinor) \(currency)"
    }

    static func inputString(_ amountMinor: Int64, currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        // Keep editor text canonical: `amountMinor(from:)` deliberately parses this exact format.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = fractionDigits(for: currency)
        formatter.maximumFractionDigits = fractionDigits(for: currency)
        return formatter.string(from: NSDecimalNumber(decimal: decimalAmount(amountMinor, currency: currency))) ?? ""
    }

    private static func decimalAmount(_ amountMinor: Int64, currency: String) -> Decimal {
        var source = Decimal(amountMinor)
        var result = Decimal()
        NSDecimalMultiplyByPowerOf10(&result, &source, -Int16(fractionDigits(for: currency)), .plain)
        return result
    }
}

enum ExpenseOptimisticMutation {
    static func applying(_ request: ExpenseRequest, to expense: ExpenseSnapshot) -> ExpenseSnapshot {
        var updated = expense
        if let value = request.amountMinor { updated.amountMinor = value; updated.settlementAmountMinor = nil }
        if let value = request.isEstimate { updated.isEstimate = value }
        if let value = request.currency { updated.currency = value; updated.settlementAmountMinor = nil }
        if let value = request.category { updated.category = value }
        if let value = request.paidBy { updated.paidBy = value }
        if let value = request.splitMode { updated.splitMode = value }
        if let value = request.occurredOn { updated.occurredOn = value }
        if let value = request.spentAt { updated.spentAt = value }
        updated.paidAt = request.paidAt ?? (request.fieldsToClear.contains("paidAt") ? nil : updated.paidAt)
        updated.purchaseChannel = request.purchaseChannel ?? (request.fieldsToClear.contains("purchaseChannel") ? nil : updated.purchaseChannel)
        updated.paymentMethod = request.paymentMethod ?? (request.fieldsToClear.contains("paymentMethod") ? nil : updated.paymentMethod)
        updated.consumerUserID = request.consumerUserID ?? (request.fieldsToClear.contains("consumerUserId") ? nil : updated.consumerUserID)
        updated.consumerName = request.consumerName ?? (request.fieldsToClear.contains("consumerName") ? nil : updated.consumerName)
        updated.note = request.note ?? (request.fieldsToClear.contains("note") ? nil : updated.note)
        updated.cardIDs = request.cardIDs ?? (request.fieldsToClear.contains("cardIds") ? [] : updated.cardIDs)
        updated.updatedAt = .now
        return updated
    }

    static func removing(_ expense: ExpenseSnapshot, from expenses: [ExpenseSnapshot]) -> [ExpenseSnapshot] {
        expenses.filter { $0.id != expense.id }
    }
}

struct ExpenseSettlement: Equatable {
    let total: Int64
    let byCategory: [ExpenseCategory: Int64]
    let paidByA: Int64
    let paidByB: Int64
    let owedByA: Int64
    let owedByB: Int64
    let overflowed: Bool

    var netA: Int64 { ExpenseSettlementCalculator.safeSubtract(paidByA, owedByA) }
    var netB: Int64 { ExpenseSettlementCalculator.safeSubtract(paidByB, owedByB) }
}

enum ExpenseSettlementCalculator {
    /// 结算（谁垫付/谁欠谁）只看已支付的账；未支出（如到店付）还没发生
    /// 资金往来，由汇总区单独展示，不进入欠款计算。
    static func calculate(_ expenses: [ExpenseSnapshot]) -> ExpenseSettlement {
        var total: Int64 = 0
        var byCategory: [ExpenseCategory: Int64] = [:]
        var paidA: Int64 = 0
        var paidB: Int64 = 0
        var owedA: Int64 = 0
        var owedB: Int64 = 0
        var overflowed = false
        for expense in expenses where !expense.isEstimate && expense.isPaid(at: .now) {
            guard let settled = expense.amountForSettlement else { continue }
            total = safeAdd(total, settled, overflowed: &overflowed)
            byCategory[expense.category] = safeAdd(byCategory[expense.category, default: 0], settled, overflowed: &overflowed)
            if expense.paidBy == .personA { paidA = safeAdd(paidA, settled, overflowed: &overflowed) } else { paidB = safeAdd(paidB, settled, overflowed: &overflowed) }
            if expense.splitMode == .equal {
                // A single smallest-unit remainder is deterministically allocated to B.
                owedA = safeAdd(owedA, settled / 2, overflowed: &overflowed)
                owedB = safeAdd(owedB, settled - settled / 2, overflowed: &overflowed)
            } else if expense.paidBy == .personA {
                owedA = safeAdd(owedA, settled, overflowed: &overflowed)
            } else {
                owedB = safeAdd(owedB, settled, overflowed: &overflowed)
            }
        }
        let result = ExpenseSettlement(total: total, byCategory: byCategory, paidByA: paidA, paidByB: paidB, owedByA: owedA, owedByB: owedB, overflowed: overflowed)
        return result
    }

    fileprivate static func safeSubtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.subtractingReportingOverflow(rhs)
        if !result.overflow { return result.partialValue }
        return lhs >= 0 ? Int64.max : -Int64.max
    }

    private static func safeAdd(_ lhs: Int64, _ rhs: Int64, overflowed: inout Bool) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        guard result.overflow else { return result.partialValue }
        overflowed = true
        return rhs >= 0 ? Int64.max : -Int64.max
    }
}

extension ExpenseSnapshot {
    /// Legacy same-currency snapshots predate settlement fields. A pending
    /// cross-currency mutation has a settlement currency but no converted
    /// amount yet and is deliberately excluded until the server responds.
    var amountForSettlement: Int64? {
        if let settlementAmountMinor { return settlementAmountMinor }
        if settlementCurrency == nil || settlementCurrency == currency { return amountMinor }
        return nil
    }

    /// 已支出/未支出由支付发生时间判定：paidAt 已过即已支出；为空（尚未
    /// 约定支付时间）或在未来（到店付）均为未支出。跨过支付时刻后自动翻转。
    func isPaid(at reference: Date = .now) -> Bool {
        guard !isEstimate else { return false }
        guard let paidAt else { return false }
        return paidAt <= reference
    }
}

// MARK: - 账单列表筛选与排序

/// 账单页的筛选/排序条件。纯值类型：输入全量支出，输出展示顺序，
/// 与视图解耦以便单测。
struct ExpenseListFilter: Equatable, Sendable {
    enum PaymentStatus: String, CaseIterable, Sendable, Identifiable {
        case all, paid, unpaid
        var id: String { rawValue }
    }

    enum SortOrder: String, CaseIterable, Sendable, Identifiable {
        case none, timeDesc, timeAsc, amountDesc, amountAsc
        var id: String { rawValue }
    }

    /// 消费人筛选的稳定标识：成员 ID、自由文本姓名或未指定。
    struct ConsumerOption: Equatable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
        static let unspecified = ConsumerOption(id: "unspecified", name: String(localized: "expensesummary.unspecifiedConsumer"))
    }

    var consumer: ConsumerOption?
    var paymentStatus: PaymentStatus = .all
    var category: ExpenseCategory?
    var sortOrder: SortOrder = .none

    var isActive: Bool {
        consumer != nil || paymentStatus != .all || category != nil
    }

    /// “按消费人”概览卡使用同一操作切换筛选：首次选中，重复点击取消。
    mutating func toggleConsumer(_ option: ConsumerOption, paymentStatus status: PaymentStatus) {
        if consumer == option && paymentStatus == status {
            consumer = nil
            paymentStatus = .all
        } else {
            consumer = option
            paymentStatus = status
        }
        category = nil
    }

    /// 概览卡中的支付状态与消费人保持同一“再次点击取消”语义。
    mutating func togglePaymentStatus(_ status: PaymentStatus) {
        paymentStatus = paymentStatus == status ? .all : status
        consumer = nil
        category = nil
    }

    /// “实际分类”列表直接驱动明细筛选，再次点击同一分类取消。
    mutating func toggleCategory(_ value: ExpenseCategory) {
        category = category == value ? nil : value
        consumer = nil
        paymentStatus = .all
    }

    mutating func clearFilters() {
        consumer = nil
        paymentStatus = .all
        category = nil
    }

    /// 两个独立排序按钮各自按倒序 → 正序 → 清除循环。
    mutating func toggleTimeSort() {
        switch sortOrder {
        case .timeDesc: sortOrder = .timeAsc
        case .timeAsc: sortOrder = .none
        default: sortOrder = .timeDesc
        }
    }

    mutating func toggleAmountSort() {
        switch sortOrder {
        case .amountDesc: sortOrder = .amountAsc
        case .amountAsc: sortOrder = .none
        default: sortOrder = .amountDesc
        }
    }

    func apply(to expenses: [ExpenseSnapshot], members: [TripMemberSummary] = []) -> [ExpenseSnapshot] {
        let filtered = expenses.filter { expense in
            if let consumer,
               ConsumerOption.key(of: expense, members: members) != consumer.id { return false }
            switch paymentStatus {
            case .all: break
            case .paid: if !expense.isPaid() { return false }
            case .unpaid: if expense.isPaid() { return false }
            }
            if let category, expense.category != category { return false }
            return true
        }
        switch sortOrder {
        case .none:
            return filtered
        case .timeDesc:
            return filtered.sorted { ($0.occurredOn, $0.updatedAt) > ($1.occurredOn, $1.updatedAt) }
        case .timeAsc:
            return filtered.sorted { ($0.occurredOn, $0.updatedAt) < ($1.occurredOn, $1.updatedAt) }
        case .amountDesc, .amountAsc:
            let ascending = sortOrder == .amountAsc
            return filtered.sorted {
                let lhs = $0.amountForSettlement ?? $0.amountMinor
                let rhs = $1.amountForSettlement ?? $1.amountMinor
                if lhs != rhs { return ascending ? lhs < rhs : lhs > rhs }
                // 金额相同的按时间稳定排序。
                return ($0.occurredOn, $0.updatedAt) > ($1.occurredOn, $1.updatedAt)
            }
        }
    }

    /// 与汇总区 byConsumer 同一套 key 规则，保证筛选与统计口径一致。
    func consumerID(of expense: ExpenseSnapshot) -> String {
        ConsumerOption.key(of: expense)
    }

    /// 从支出与成员名单推导可选的消费人选项（成员优先，按出现顺序稳定）。
    static func consumerOptions(from expenses: [ExpenseSnapshot], members: [TripMemberSummary]) -> [ConsumerOption] {
        var byID: [String: ConsumerOption] = [:]
        var order: [String] = []
        func record(_ option: ConsumerOption) {
            if byID[option.id] == nil {
                byID[option.id] = option
                order.append(option.id)
            }
        }
        for member in members {
            record(ConsumerOption(id: "member:\(member.userId)", name: member.visibleName))
        }
        for expense in expenses {
            let id = ConsumerOption.key(of: expense, members: members)
            if byID[id] != nil { continue }
            if let userID = expense.consumerUserID {
                let name = members.first { $0.userId == userID }?.visibleName
                    ?? expense.consumerName
                    ?? String(localized: "expensesummary.formerMember")
                record(ConsumerOption(id: id, name: name))
            } else if let name = expense.consumerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                record(ConsumerOption(id: id, name: name))
            } else {
                record(.unspecified)
            }
        }
        return order.compactMap { byID[$0] }
    }
}

extension ExpenseListFilter.ConsumerOption {
    /// 成员用 "member:<id>"，自由姓名用 "name:<名>"，其余归「未指定」。
    static func key(of expense: ExpenseSnapshot) -> String {
        if let userID = expense.consumerUserID { return "member:\(userID)" }
        if let name = expense.consumerName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "name:\(name)"
        }
        return ExpenseListFilter.ConsumerOption.unspecified.id
    }

    /// Old records can contain a member name without its user ID. Resolve an
    /// unambiguous name match to the member key so summaries do not split one
    /// traveler into an ID row and a legacy free-text row.
    static func key(of expense: ExpenseSnapshot, members: [TripMemberSummary]) -> String {
        if let userID = expense.consumerUserID { return "member:\(userID)" }
        guard let name = expense.consumerName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else { return unspecified.id }
        let matches = members.filter {
            $0.visibleName.trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        if matches.count == 1, let member = matches.first {
            return "member:\(member.userId)"
        }
        return "name:\(name)"
    }
}

enum ExpenseMemberNames {
    static func name(for person: ExpensePaidBy) -> String {
        let key = person == .personA ? "expense.memberA.name" : "expense.memberB.name"
        let fallback = person == .personA ? String(localized: "expense.memberA") : String(localized: "expense.memberB")
        let saved = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? fallback : saved
    }

    static func save(_ name: String, for person: ExpensePaidBy) {
        let key = person == .personA ? "expense.memberA.name" : "expense.memberB.name"
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
}
