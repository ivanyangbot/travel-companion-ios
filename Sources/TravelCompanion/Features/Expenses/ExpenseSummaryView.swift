import SwiftUI

struct ExpenseSummaryView: View {
    let trip: SharedTripSnapshot
    let currency: String

    private var expenses: [ExpenseSnapshot] { trip.expenses }
    private var cards: [TravelCardSnapshot] { trip.days.flatMap(\.cards) }

    /// Sum of all recorded actual prices (card-linked and standalone spends).
    private var actualTotal: Int64 { expenses.reduce(Int64(0)) { $0 + $1.amountMinor } }

    /// Cards whose estimate still counts: those with no linked actual expense.
    private var estimatedTotal: Int64 {
        let linked = Set(expenses.compactMap(\.cardID))
        return cards.reduce(Int64(0)) { acc, card in
            guard let serverID = card.serverID, !linked.contains(serverID), let minor = card.actualPriceMinor ?? card.priceMinor else { return acc }
            return acc + minor
        }
    }

    /// Full-trip total: every card contributes either its actual expense (if
    /// recorded) or its estimate, plus standalone spends. Avoids double
    /// counting a card that has both an estimate and a linked actual.
    private var grandTotal: Int64 { actualTotal + estimatedTotal }

    private var byCategory: [ExpenseCategory: Int64] {
        expenses.reduce(into: [ExpenseCategory: Int64]()) { result, expense in
            result[expense.category, default: 0] += expense.amountMinor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("支出概览").font(.title3.bold())
                Spacer()
                Text("实际 \(expenses.count) 笔")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            totalRow(label: "实际已支出", amount: actualTotal, prominent: false)
            totalRow(label: "预估（待记实际）", amount: estimatedTotal, prominent: false)
            Divider()
            totalRow(label: "全行程合计（实际 + 预估）", amount: grandTotal, prominent: true)
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("实际分类").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(ExpenseCategory.allCases) { category in
                    if let amount = byCategory[category], amount > 0 {
                        HStack {
                            Label(category.title, systemImage: category.systemImage)
                            Spacer()
                            Text(ExpenseMoney.formatted(amount, currency: currency)).monospacedDigit()
                        }
                        .font(.subheadline)
                    }
                }
            }
        }
        .padding(18)
        .glassEffect(.regular.tint(.indigo), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func totalRow(label: String, amount: Int64, prominent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(prominent ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(prominent ? .primary : .secondary)
            Spacer()
            Text(ExpenseMoney.formatted(amount, currency: currency))
                .font(prominent ? .title2.bold() : .subheadline.weight(.semibold))
                .monospacedDigit()
        }
    }
}
