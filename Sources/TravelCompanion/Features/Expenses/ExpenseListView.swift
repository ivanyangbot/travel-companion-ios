import SwiftUI

struct ExpenseListView: View {
    @ObservedObject var syncEngine: SyncEngine
    @State private var editorTarget: ExpenseSnapshot?
    @State private var addingExpense = false
    @State private var addingWalletItem = false
    @State private var creatingMemoList = false
    @State private var pendingDeletion: ExpenseSnapshot?
    @State private var section: ExpenseSection = .expenses
    @State private var members: [TripMemberSummary] = []
    @State private var currencyBeingUpdated: String?
    @State private var listFilter = ExpenseListFilter()

    var body: some View {
        NavigationStack {
            ZStack {
                PrimaryTabPalette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    expenseHeader
                    expenseSectionPicker
                        .padding(.top, 10)
                        .padding(.bottom, 8)

                    switch section {
                    case .expenses:
                        expenseContent
                    case .wallet:
                        WalletSection(syncEngine: syncEngine, isAddingItem: $addingWalletItem)
                    case .memo:
                        MemoSection(creatingList: $creatingMemoList)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $addingExpense) {
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip, members: members) { request in
                        Task { await syncEngine.addExpense(request) }
                    }
                }
            }
            .sheet(item: $editorTarget) { expense in
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip, existingExpense: expense, members: members) { request in
                        Task { await syncEngine.updateExpense(expense, request: request) }
                    }
                }
            }
            .alert(
                "expense.deleteTitle",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { expense in
                Button("common.delete", role: .destructive) {
                    Task { await syncEngine.deleteExpense(expense) }
                    pendingDeletion = nil
                }
                Button("common.cancel", role: .cancel) { pendingDeletion = nil }
            } message: { _ in
                Text("expense.deleteSharedNote")
            }
            .task(id: syncEngine.selectedTripID) {
                guard syncEngine.isUserAuthenticated else {
                    members = []
                    return
                }
                members = (try? await syncEngine.fetchTripMembers()) ?? []
            }
        }
    }

    private var expenseHeader: some View {
        ZStack {
            Text("expense.ledgerTitle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack { 
                Spacer(minLength: 0)

                Button(action: addManualEntry) {
                    Image(systemName: "plus")
                        .font(.system(size: 21, weight: .medium))
                        .frame(width: 40, height: 40)
                }
                .primaryTabHeaderButtonStyle()
                .disabled(section == .expenses && syncEngine.trip?.currency == nil)
                .accessibilityLabel(Text(LocalizedStringKey(section.addAccessibilityKey)))
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
        .padding(.top, 2)
    }

    private var expenseSectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(ExpenseSection.allCases) { option in
                Button {
                    withAnimation(.snappy(duration: 0.24)) {
                        section = option
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(option == section ? .white : PrimaryTabPalette.secondaryText)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if option == section {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(PrimaryTabPalette.elevatedSurface)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if option == section {
                                Capsule()
                                    .fill(PrimaryTabPalette.accent)
                                    .frame(width: 18, height: 3)
                                    .padding(.bottom, 4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityValue(option == section ? Text("common.selected") : Text(""))
            }
        }
        .padding(4)
        .background(
            PrimaryTabPalette.surface,
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var expenseContent: some View {
        if let trip = syncEngine.trip, let currency = trip.currency {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    // 同步状态不再展示提示条：本地先落库，登录后由前台
                    // 轮询/场景回前台静默重试上传（SyncEngine.startForegroundSync）。
                    ExpenseSummaryView(trip: trip, currency: currency, members: members) { newCurrency in
                        guard currencyBeingUpdated == nil else { return }
                        currencyBeingUpdated = newCurrency
                        Task {
                            await syncEngine.updatePrimaryCurrency(newCurrency)
                            currencyBeingUpdated = nil
                        }
                    }

                    HStack {
                        Text("expense.section")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text(String(format: String(localized: "expense.filteredCountFormat"), visibleExpenses(in: trip).count, trip.expenses.count))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                    .padding(.top, 4)

                    if !trip.expenses.isEmpty {
                        filterBar(trip: trip)
                    }

                    if trip.expenses.isEmpty {
                        ContentUnavailableView(
                            "expense.emptyTitle",
                            systemImage: "receipt",
                            description: Text("expense.emptyDesc")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else if visibleExpenses(in: trip).isEmpty {
                        ContentUnavailableView(
                            "expense.noMatchTitle",
                            systemImage: "line.3.horizontal.decrease.circle",
                            description: Text("expense.noMatchDesc")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(visibleExpenses(in: trip)) { expense in
                            expenseRow(expense, currency: currency)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 128)
            }
            .scrollIndicators(.hidden)
            .disabled(currencyBeingUpdated != nil)
            .overlay {
                if let target = currencyBeingUpdated {
                    ZStack {
                        PrimaryTabPalette.background.opacity(0.96)
                        VStack(spacing: 14) {
                            ProgressView().tint(PrimaryTabPalette.accent)
                            Text(String(format: String(localized: "expensesummary.convertingCurrency"), target))
                                .font(.headline)
                            Text("expensesummary.convertingCurrencyNote")
                                .font(.subheadline)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        } else {
            ContentUnavailableView(
                "expense.needTripTitle",
                systemImage: "calendar.badge.exclamationmark",
                description: Text("expense.needTripDesc")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 112)
        }
    }

    private func visibleExpenses(in trip: SharedTripSnapshot) -> [ExpenseSnapshot] {
        listFilter.apply(to: trip.expenses)
    }

    private func filterBar(trip: SharedTripSnapshot) -> some View {
        let consumerOptions = ExpenseListFilter.consumerOptions(from: trip.expenses, members: members)
        return HStack(spacing: 8) {
            Menu {
                Button("expense.filter.all") { listFilter.consumer = nil }
                ForEach(consumerOptions) { option in
                    Button {
                        listFilter.consumer = option
                    } label: {
                        if listFilter.consumer == option {
                            Label(option.name, systemImage: "checkmark")
                        } else {
                            Text(option.name)
                        }
                    }
                }
            } label: {
                filterChipLabel(
                    title: listFilter.consumer?.name ?? String(localized: "expense.filter.consumer"),
                    active: listFilter.consumer != nil
                )
            }

            Menu {
                Button("expense.filter.all") { listFilter.paymentStatus = .all }
                Button("expense.filter.paid") { listFilter.paymentStatus = .paid }
                Button("expense.filter.unpaid") { listFilter.paymentStatus = .unpaid }
            } label: {
                filterChipLabel(
                    title: paymentFilterTitle,
                    active: listFilter.paymentStatus != .all
                )
            }

            Menu {
                Button("expense.filter.all") { listFilter.category = nil }
                ForEach(ExpenseCategory.allCases) { category in
                    Button {
                        listFilter.category = category
                    } label: {
                        if listFilter.category == category {
                            Label(category.title, systemImage: "checkmark")
                        } else {
                            Label(category.title, systemImage: category.systemImage)
                        }
                    }
                }
            } label: {
                filterChipLabel(
                    title: listFilter.category?.title ?? String(localized: "expense.filter.category"),
                    active: listFilter.category != nil
                )
            }

            Menu {
                ForEach(ExpenseListFilter.SortOrder.allCases) { order in
                    Button {
                        listFilter.sortOrder = order
                    } label: {
                        if listFilter.sortOrder == order {
                            Label(sortTitle(order), systemImage: "checkmark")
                        } else {
                            Text(sortTitle(order))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text(sortTitle(listFilter.sortOrder))
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .background(PrimaryTabPalette.surface, in: Capsule())
            }

            if listFilter.isActive {
                Button("expense.filter.clear") {
                    listFilter.consumer = nil
                    listFilter.paymentStatus = .all
                    listFilter.category = nil
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.accent)
            }

            Spacer(minLength: 0)
        }
    }

    private var paymentFilterTitle: String {
        switch listFilter.paymentStatus {
        case .all: String(localized: "expense.filter.status")
        case .paid: String(localized: "expense.filter.paid")
        case .unpaid: String(localized: "expense.filter.unpaid")
        }
    }

    private func sortTitle(_ order: ExpenseListFilter.SortOrder) -> String {
        switch order {
        case .timeDesc: String(localized: "expense.sort.timeDesc")
        case .timeAsc: String(localized: "expense.sort.timeAsc")
        case .amountDesc: String(localized: "expense.sort.amountDesc")
        case .amountAsc: String(localized: "expense.sort.amountAsc")
        }
    }

    private func filterChipLabel(title: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .foregroundStyle(active ? .black : PrimaryTabPalette.secondaryText)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(
            active ? PrimaryTabPalette.accent.opacity(0.85) : PrimaryTabPalette.surface,
            in: Capsule()
        )
    }

    private func expenseRow(_ expense: ExpenseSnapshot, currency: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: expense.category.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white.opacity(0.82))
                .frame(width: 38, height: 38)
                .background(
                    PrimaryTabPalette.surface,
                    in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(expense.category.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                    if !expense.isPaid() {
                        Text(expense.paidAt.map { String(format: String(localized: "expense.unpaidWithDateBadge"), Self.badgeDateFormatter.string(from: $0)) }
                            ?? String(localized: "expense.unpaidBadge"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.16), in: Capsule())
                    }
                }

                Text(expenseTimeText(expense))
                    .font(.caption)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)

                if !expenseMetadata(expense).isEmpty {
                    Text(expenseMetadata(expense))
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(2)
                }

                let cards = linkedCards(for: expense)
                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(cards, id: \.serverID) { card in
                            Label {
                                Text(card.title).lineLimit(1)
                            } icon: {
                                Image(systemName: card.kind.systemImage)
                            }
                            .font(.caption.weight(.medium))
                            .foregroundStyle(PrimaryTabPalette.accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(PrimaryTabPalette.accent.opacity(0.11), in: Capsule())
                        }
                    }
                }

                if let note = expense.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(ExpenseMoney.formatted(expense.amountMinor, currency: expense.currency))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if expense.currency != currency, let settled = expense.amountForSettlement {
                    Text("≈ " + ExpenseMoney.formatted(settled, currency: currency))
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .monospacedDigit()
                }
            }
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        .contentShape(Rectangle())
        .onTapGesture { editorTarget = expense }
        .contextMenu {
            Button("common.edit", systemImage: "pencil") { editorTarget = expense }
            Button("common.delete", systemImage: "trash", role: .destructive) { pendingDeletion = expense }
        }
    }

    private func linkedCards(for expense: ExpenseSnapshot) -> [TravelCardSnapshot] {
        let cards = syncEngine.trip?.days.flatMap(\.cards) ?? []
        return expense.cardIDs.compactMap { id in cards.first { $0.serverID == id } }
    }

    private func expenseTimeText(_ expense: ExpenseSnapshot) -> String {
        guard let spentAt = expense.spentAt else { return expense.occurredOn }
        return spentAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func expenseMetadata(_ expense: ExpenseSnapshot) -> String {
        let payment = expense.paymentMethod.map { rawValue in
            ExpensePaymentMethod(rawValue: rawValue)?.title ?? rawValue
        }
        return [expense.purchaseChannel, payment, expense.consumerName]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
            .joined(separator: " · ")
    }

    private static let badgeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private func addManualEntry() {
        switch section {
        case .expenses: addingExpense = true
        case .wallet: addingWalletItem = true
        case .memo: creatingMemoList = true
        }
    }
}

private enum ExpenseSection: CaseIterable, Identifiable {
    case expenses
    case wallet
    case memo

    var title: String {
        switch self {
        case .expenses: String(localized: "expense.tab.expenses")
        case .wallet: String(localized: "expense.tab.wallet")
        case .memo: String(localized: "expense.tab.memo")
        }
    }

    var addAccessibilityKey: String {
        switch self {
        case .expenses: "expense.addA11y"
        case .wallet: "wallet.addA11y"
        case .memo: "memo.addListA11y"
        }
    }

    var id: Self { self }
}
