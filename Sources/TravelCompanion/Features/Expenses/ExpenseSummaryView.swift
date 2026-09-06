import SwiftUI

struct ExpenseSummaryView: View {
    let trip: SharedTripSnapshot
    let currency: String
    let members: [TripMemberSummary]
    let onCurrencyChange: (String) -> Void

    private var expenses: [ExpenseSnapshot] { trip.expenses }
    private var cards: [TravelCardSnapshot] { trip.days.flatMap(\.cards) }

    /// Sum of all recorded actual prices (card-linked and standalone spends).
    private var actualTotal: Int64 { expenses.compactMap(\.amountForSettlement).reduce(0, +) }

    /// Cards whose estimate still counts: those with no linked actual expense.
    private var estimatedTotal: Int64 {
        let linked = Set(expenses.compactMap(\.cardID))
        return cards.reduce(Int64(0)) { acc, card in
            guard let serverID = card.serverID, !linked.contains(serverID),
                  card.priceCurrency == nil || card.priceCurrency == currency,
                  let minor = card.actualPriceMinor ?? card.priceMinor else { return acc }
            return acc + minor
        }
    }

    /// Full-trip total: every card contributes either its actual expense (if
    /// recorded) or its estimate, plus standalone spends. Avoids double
    /// counting a card that has both an estimate and a linked actual.
    private var grandTotal: Int64 { actualTotal + estimatedTotal }

    private var byCategory: [ExpenseCategory: Int64] {
        expenses.reduce(into: [ExpenseCategory: Int64]()) { result, expense in
            if let amount = expense.amountForSettlement { result[expense.category, default: 0] += amount }
        }
    }

    private var showsConsumerTotals: Bool {
        members.count > 1 || expenses.contains { $0.consumerUserID != nil || $0.consumerName?.isEmpty == false }
    }

    private var consumerTotals: [ExpenseConsumerTotal] {
        let knownIDs = Set(members.map(\.userId))
        var totals: [String: Int64] = [:]
        var names: [String: String] = [:]

        for member in members {
            let key = "member:\(member.userId)"
            names[key] = member.visibleName
            totals[key] = 0
        }

        for expense in expenses {
            guard let amount = expense.amountForSettlement else { continue }
            let key: String
            let name: String
            if let userID = expense.consumerUserID {
                key = "member:\(userID)"
                name = members.first { $0.userId == userID }?.visibleName
                    ?? expense.consumerName
                    ?? String(localized: "expensesummary.formerMember")
            } else if let savedName = expense.consumerName, !savedName.isEmpty {
                key = "name:\(savedName)"
                name = savedName
            } else {
                key = "unspecified"
                name = String(localized: "expensesummary.unspecifiedConsumer")
            }
            names[key] = name
            totals[key, default: 0] += amount
        }

        return totals.map { key, amount in
            ExpenseConsumerTotal(id: key, name: names[key] ?? key, amount: amount)
        }
        .filter { $0.amount > 0 || ($0.id.hasPrefix("member:") && knownIDs.contains(Int(String($0.id.dropFirst(7))) ?? -1)) }
        .sorted { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("expensesummary.title")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(String(format: String(localized: "expensesummary.count"), expenses.count))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            HStack {
                Text("expensesummary.primaryCurrency")
                    .font(.subheadline)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                Spacer()
                Menu {
                    ForEach(ExpenseCurrency.supported, id: \.self) { code in
                        Button {
                            onCurrencyChange(code)
                        } label: {
                            if code == currency {
                                Label(code, systemImage: "checkmark")
                            } else {
                                Text(code)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(currency)
                            .font(.subheadline.weight(.semibold).monospaced())
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .background(PrimaryTabPalette.accent.opacity(0.12), in: Capsule())
                }
                .accessibilityLabel(Text("expensesummary.changePrimaryCurrencyA11y"))
                .accessibilityValue(Text(currency))
            }
            totalRow(label: String(localized: "expensesummary.actual"), amount: actualTotal, prominent: false)
            totalRow(label: String(localized: "expensesummary.estimated"), amount: estimatedTotal, prominent: false)
            Divider().overlay(PrimaryTabPalette.divider)
            totalRow(label: String(localized: "expensesummary.total"), amount: grandTotal, prominent: true)
            if showsConsumerTotals {
                Divider().overlay(PrimaryTabPalette.divider)
                VStack(alignment: .leading, spacing: 10) {
                    Text("expensesummary.byConsumer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    ForEach(consumerTotals) { item in
                        HStack(spacing: 10) {
                            Text(String(item.name.prefix(1)).uppercased())
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.black)
                                .frame(width: 26, height: 26)
                                .background(PrimaryTabPalette.accent, in: Circle())
                            Text(item.name)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.86))
                                .lineLimit(1)
                            Spacer()
                            Text(ExpenseMoney.formatted(item.amount, currency: currency))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                        }
                    }
                }
            }
            Divider().overlay(PrimaryTabPalette.divider)
            VStack(alignment: .leading, spacing: 8) {
                Text("expensesummary.byCategory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                ForEach(ExpenseCategory.allCases) { category in
                    if let amount = byCategory[category], amount > 0 {
                        HStack {
                            Label(category.title, systemImage: category.systemImage)
                            Spacer()
                            Text(ExpenseMoney.formatted(amount, currency: currency)).monospacedDigit()
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                    }
                }
            }
        }
        .padding(18)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 18)
        .overlay(alignment: .leading) {
            Capsule()
                .fill(PrimaryTabPalette.accent)
                .frame(width: 4)
                .padding(.vertical, 16)
                .padding(.leading, 2)
        }
    }

    private func totalRow(label: String, amount: Int64, prominent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(prominent ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(prominent ? .white : PrimaryTabPalette.secondaryText)
            Spacer()
            Text(ExpenseMoney.formatted(amount, currency: currency))
                .font(prominent ? .title2.bold() : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }
}

private struct ExpenseConsumerTotal: Identifiable {
    let id: String
    let name: String
    let amount: Int64
}
