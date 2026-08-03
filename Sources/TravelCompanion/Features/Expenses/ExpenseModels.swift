import Foundation

enum ExpenseCategory: String, Codable, CaseIterable, Sendable, Identifiable {
    case transport, lodging, food, tickets, shopping, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .transport: "交通"
        case .lodging: "住宿"
        case .food: "餐饮"
        case .tickets: "门票"
        case .shopping: "购物"
        case .other: "其他"
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
    var title: String { self == .equal ? "平摊" : "自己承担" }
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
        if let value = request.amountMinor { updated.amountMinor = value }
        if let value = request.currency { updated.currency = value }
        if let value = request.category { updated.category = value }
        if let value = request.paidBy { updated.paidBy = value }
        if let value = request.splitMode { updated.splitMode = value }
        if let value = request.occurredOn { updated.occurredOn = value }
        updated.note = request.note ?? (request.fieldsToClear.contains("note") ? nil : updated.note)
        updated.cardID = request.cardID ?? (request.fieldsToClear.contains("cardId") ? nil : updated.cardID)
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
    static func calculate(_ expenses: [ExpenseSnapshot]) -> ExpenseSettlement {
        var total: Int64 = 0
        var byCategory: [ExpenseCategory: Int64] = [:]
        var paidA: Int64 = 0
        var paidB: Int64 = 0
        var owedA: Int64 = 0
        var owedB: Int64 = 0
        var overflowed = false
        for expense in expenses {
            total = safeAdd(total, expense.amountMinor, overflowed: &overflowed)
            byCategory[expense.category] = safeAdd(byCategory[expense.category, default: 0], expense.amountMinor, overflowed: &overflowed)
            if expense.paidBy == .personA { paidA = safeAdd(paidA, expense.amountMinor, overflowed: &overflowed) } else { paidB = safeAdd(paidB, expense.amountMinor, overflowed: &overflowed) }
            if expense.splitMode == .equal {
                // A single smallest-unit remainder is deterministically allocated to B.
                owedA = safeAdd(owedA, expense.amountMinor / 2, overflowed: &overflowed)
                owedB = safeAdd(owedB, expense.amountMinor - expense.amountMinor / 2, overflowed: &overflowed)
            } else if expense.paidBy == .personA {
                owedA = safeAdd(owedA, expense.amountMinor, overflowed: &overflowed)
            } else {
                owedB = safeAdd(owedB, expense.amountMinor, overflowed: &overflowed)
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

enum ExpenseMemberNames {
    static func name(for person: ExpensePaidBy) -> String {
        let key = person == .personA ? "expense.memberA.name" : "expense.memberB.name"
        let fallback = person == .personA ? "成员 A" : "成员 B"
        let saved = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? fallback : saved
    }

    static func save(_ name: String, for person: ExpensePaidBy) {
        let key = person == .personA ? "expense.memberA.name" : "expense.memberB.name"
        UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: key)
    }
}
