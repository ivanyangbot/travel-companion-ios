import SwiftUI

struct ExpenseSummaryView: View {
    let trip: SharedTripSnapshot
    let currency: String
    let members: [TripMemberSummary]
    let onCurrencyChange: (String) -> Void

    private var expenses: [ExpenseSnapshot] { trip.expenses }
    private var cards: [TravelCardSnapshot] { trip.days.flatMap(\.cards) }

    /// 已支出合计：只统计支付发生时间已过的账（card-linked 与卡外支出）。
    private var paidTotal: Int64 {
        expenses.filter { $0.isPaid() }.compactMap(\.amountForSettlement).reduce(0, +)
    }

    /// 待支付合计：到店付等尚未支付的账，单独展示不混入已支出。
    private var unpaidTotal: Int64 {
        expenses.filter { !$0.isPaid() }.compactMap(\.amountForSettlement).reduce(0, +)
    }

    /// Cards whose estimate still counts: those with no linked actual expense.
    private var estimatedTotal: Int64 {
        let linked = Set(expenses.flatMap(\.cardIDs))
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
    private var grandTotal: Int64 { paidTotal + unpaidTotal + estimatedTotal }

    private var byCategory: [ExpenseCategory: Int64] {
        expenses.reduce(into: [ExpenseCategory: Int64]()) { result, expense in
            if let amount = expense.amountForSettlement { result[expense.category, default: 0] += amount }
        }
    }

    private var showsConsumerTotals: Bool {
        !consumerTotals.isEmpty
    }

    private var consumerTotals: [ExpenseConsumerTotal] {
        var totals: [String: Int64] = [:]
        var names: [String: String] = [:]

        for member in members {
            let key = "member:\(member.userId)"
            names[key] = member.visibleName
            totals[key] = 0
        }

        for expense in expenses {
            guard let amount = expense.amountForSettlement else { continue }
            let key = ExpenseListFilter.ConsumerOption.key(of: expense, members: members)
            let name: String
            if key.hasPrefix("member:"),
               let member = members.first(where: { key == "member:\($0.userId)" }) {
                name = member.visibleName
            } else if expense.consumerUserID != nil {
                name = expense.consumerName ?? String(localized: "expensesummary.formerMember")
            } else if let savedName = expense.consumerName, !savedName.isEmpty {
                name = savedName
            } else {
                name = String(localized: "expensesummary.unspecifiedConsumer")
            }
            names[key] = name
            totals[key, default: 0] += amount
        }

        return totals.map { key, amount in
            ExpenseConsumerTotal(id: key, name: names[key] ?? key, amount: amount)
        }
        .filter { $0.amount > 0 }
        .sorted { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            return lhs.name.localizedCompare(rhs.name) == .orderedAscending
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var totalFontSize = 44
    @State private var showsTravelers = false
    @State private var selectedCategory: ExpenseCategory?

    private let paidColor = Color(red: 1, green: 0.46, blue: 0.20)
    private let pendingColor = Color(red: 0.95, green: 0.74, blue: 0.48)
    private let estimateColor = Color(red: 0.38, green: 0.39, blue: 0.43)
    private let ink = Color(red: 0.97, green: 0.95, blue: 0.91)
    /// 首页同款层级：列表 23、卡片 34、内嵌内容 26。
    private let overviewSurface = PrimaryTabPalette.elevatedSurface
    private let metricSurface = PrimaryTabPalette.insetSurface
    private var actualTotal: Int64 { paidTotal + unpaidTotal }
    private var sortedCategories: [ExpenseCategory] {
        ExpenseCategory.allCases.filter { (byCategory[$0] ?? 0) > 0 }
            .sorted {
                let left = byCategory[$0] ?? 0
                let right = byCategory[$1] ?? 0
                return left == right ? $0.rawValue < $1.rawValue : left > right
            }
    }
    private var focusedCategory: ExpenseCategory? {
        if let selectedCategory, sortedCategories.contains(selectedCategory) { return selectedCategory }
        return sortedCategories.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            overviewCard
            if showsConsumerTotals || !sortedCategories.isEmpty {
                insightsCard
            }
        }
    }

    private var overviewCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: 10) {
                    Image(systemName: "chart.pie.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(paidColor)
                    Text("expensesummary.title")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(ink)
                }
                Spacer(minLength: 8)
                currencyMenu
            }

            ZStack {
                if !dynamicTypeSize.isAccessibilitySize {
                    paymentArc
                        .padding(.horizontal, 10)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 9) {
                    Text("expensesummary.tripTotalShort")
                        .font(.subheadline)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    Text(amountNumber(grandTotal))
                        .font(.system(size: totalFontSize, weight: .semibold, design: .rounded))
                        .tracking(-1.8)
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .contentTransition(.numericText())
                    Text("expensesummary.includesEstimates")
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    Text(String(format: String(localized: "expensesummary.count"), expenses.count))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(ink.opacity(0.8))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.055), in: Capsule())
                        .padding(.top, 4)
                }
                .padding(.horizontal, 18)
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 24 : 48)
                .padding(.bottom, 12)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("expensesummary.total"))
                .accessibilityValue(Text(ExpenseMoney.formatted(grandTotal, currency: currency)))
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 232)

            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                .padding(.top, 8)
                .padding(.bottom, 18)

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
            layout {
                statusMetric("expensesummary.paid", amount: paidTotal, color: paidColor)
                statusMetric("expensesummary.unpaid", amount: unpaidTotal, color: pendingColor)
                statusMetric("expensesummary.estimateShort", amount: estimatedTotal, color: estimateColor)
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(overviewSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        }
    }

    private var currencyMenu: some View {
        Menu {
            ForEach(ExpenseCurrency.supported, id: \.self) { code in
                Button {
                    onCurrencyChange(code)
                } label: {
                    if code == currency { Label(code, systemImage: "checkmark") }
                    else { Text(code) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(currency).font(.caption.weight(.semibold).monospaced())
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(ink.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.black.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
        }
        .accessibilityLabel(Text("expensesummary.changePrimaryCurrencyA11y"))
        .accessibilityValue(Text(currency))
    }

    private var paymentArc: some View {
        ZStack {
            ExpenseSummaryArc(start: 0, end: 1)
                .stroke(.white.opacity(0.045), style: StrokeStyle(lineWidth: 9, lineCap: .butt))
            arcSegment(start: 0, amount: paidTotal, color: paidColor)
            arcSegment(start: fraction(paidTotal, of: grandTotal), amount: unpaidTotal, color: pendingColor)
            arcSegment(start: fraction(paidTotal + unpaidTotal, of: grandTotal), amount: estimatedTotal, color: estimateColor)
            ExpenseSummaryArc(start: 0, end: 1)
                .stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: [1, 7]))
                .padding(15)
        }
    }

    @ViewBuilder
    private func arcSegment(start: Double, amount: Int64, color: Color) -> some View {
        let share = fraction(amount, of: grandTotal)
        if share > 0 {
            let gap = min(0.009, share * 0.2)
            ExpenseSummaryArc(start: start + gap, end: start + share - gap)
                .stroke(color, style: StrokeStyle(lineWidth: 9, lineCap: .butt))
        }
    }

    private func statusMetric(_ key: LocalizedStringKey, amount: Int64, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(key).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            Text(amountNumber(amount))
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .foregroundStyle(ink)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(fraction(amount, of: grandTotal), format: .percent.precision(.fractionLength(0)))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(12)
        .frame(minHeight: 86, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(metricSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(.white.opacity(0.045), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(key))
        .accessibilityValue(Text(ExpenseMoney.formatted(amount, currency: currency)))
    }

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("expensesummary.distribution", selection: $showsTravelers) {
                Text("expensesummary.byCategory").tag(false)
                Text("expensesummary.byConsumer").tag(true)
            }
            .pickerStyle(.segmented)

            if showsTravelers {
                VStack(spacing: 18) {
                    ForEach(consumerTotals) { item in
                        consumerRow(item)
                    }
                }
            } else {
                let layout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
                layout {
                    categoryRing
                        .frame(width: dynamicTypeSize.isAccessibilitySize ? 180 : 124,
                               height: dynamicTypeSize.isAccessibilitySize ? 180 : 124)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : nil)
                    VStack(spacing: 2) {
                        ForEach(sortedCategories) { category in
                            categoryButton(category)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            HStack(spacing: 5) {
                Image(systemName: "info.circle").accessibilityHidden(true)
                Text("expensesummary.actualBasis")
                Spacer(minLength: 0)
                Text(currency).monospaced()
            }
            .font(.caption2)
            .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(18)
        .background(PrimaryTabPalette.elevatedSurface,
                    in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: showsTravelers)
    }

    private var categoryRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.04), lineWidth: 12)
            ForEach(sortedCategories) { category in
                let start = categoryStart(category)
                let share = fraction(byCategory[category] ?? 0, of: actualTotal)
                let gap = min(0.008, share * 0.18)
                Circle()
                    .trim(from: start + gap, to: start + share - gap)
                    .stroke(categoryColor(category).opacity(category == focusedCategory ? 1 : 0.4),
                            style: StrokeStyle(lineWidth: category == focusedCategory ? 13 : 9, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            Circle().stroke(.white.opacity(0.05), lineWidth: 1).padding(14)
            if let category = focusedCategory {
                VStack(spacing: 5) {
                    Image(systemName: category.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(categoryColor(category))
                    Text(fraction(byCategory[category] ?? 0, of: actualTotal),
                         format: .percent.precision(.fractionLength(0)))
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .foregroundStyle(ink)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(category.title)
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(1)
                }
                .padding(20)
            }
        }
        .padding(7)
        // The adjacent category buttons expose each amount and share to VoiceOver.
        .accessibilityHidden(true)
    }

    private func categoryButton(_ category: ExpenseCategory) -> some View {
        let amount = byCategory[category] ?? 0
        return Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                selectedCategory = category
            }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                Circle().fill(categoryColor(category)).frame(width: 5, height: 5).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title)
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    Text(amountNumber(amount))
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .background(category == focusedCategory ? .white.opacity(0.045) : .clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(category.title))
        .accessibilityValue(Text(ExpenseMoney.formatted(amount, currency: currency) + ", " +
                                fraction(amount, of: actualTotal).formatted(.percent.precision(.fractionLength(0)))))
        .accessibilityAddTraits(category == focusedCategory ? .isSelected : [])
    }

    private func consumerRow(_ item: ExpenseConsumerTotal) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.06), lineWidth: 2)
                Circle().trim(from: 0, to: fraction(item.amount, of: actualTotal))
                    .stroke(pendingColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(pendingColor)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                Text(item.name)
                    .font(.subheadline)
                    .foregroundStyle(ink.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(amountNumber(item.amount))
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .foregroundStyle(ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(fraction(item.amount, of: actualTotal), format: .percent.precision(.fractionLength(0)))
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func categoryStart(_ category: ExpenseCategory) -> Double {
        sortedCategories.prefix { $0 != category }.reduce(0) {
            $0 + fraction(byCategory[$1] ?? 0, of: actualTotal)
        }
    }

    private func fraction(_ amount: Int64, of total: Int64) -> Double {
        guard total > 0 else { return 0 }
        return min(max(Double(amount) / Double(total), 0), 1)
    }

    /// The currency is displayed once per card; retain locale grouping and ISO precision.
    private func amountNumber(_ minor: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let digits = ExpenseMoney.fractionDigits(for: currency)
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        var source = Decimal(minor)
        var amount = Decimal()
        NSDecimalMultiplyByPowerOf10(&amount, &source, -Int16(digits), .plain)
        return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? ExpenseMoney.formatted(minor, currency: currency)
    }

    private func categoryColor(_ category: ExpenseCategory) -> Color {
        switch category {
        case .lodging: paidColor
        case .transport: pendingColor
        case .food: Color(red: 0.77, green: 0.80, blue: 0.58)
        case .tickets: Color(red: 0.63, green: 0.71, blue: 0.77)
        case .shopping: Color(red: 0.77, green: 0.63, blue: 0.65)
        case .other: Color(red: 0.59, green: 0.58, blue: 0.56)
        }
    }
}

/// A 240° composition arc, with an open lower edge for the summary's legend.
private struct ExpenseSummaryArc: Shape {
    let start: Double
    let end: Double

    func path(in rect: CGRect) -> Path {
        let radius = max(0, min(rect.width / 2 - 6, rect.height / 1.6 - 6))
        let center = CGPoint(x: rect.midX, y: radius + 6)
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .degrees(150 + 240 * start),
                    endAngle: .degrees(150 + 240 * end), clockwise: false)
        return path
    }
}

private struct ExpenseConsumerTotal: Identifiable {
    let id: String
    let name: String
    let amount: Int64
}
