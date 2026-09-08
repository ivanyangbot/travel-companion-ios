import SwiftUI

struct ExpenseListView: View {
    @ObservedObject var syncEngine: SyncEngine
    @State private var editorTarget: ExpenseSnapshot?
    @State private var addingExpense = false
    @State private var addingEstimate = false
    @State private var addingWalletItem = false
    @State private var creatingMemoList = false
    @State private var pendingDeletion: ExpenseSnapshot?
    @State private var section: ExpenseSection = .expenses
    @State private var members: [TripMemberSummary] = []
    @State private var listFilter = ExpenseListFilter()
    @State private var linkedCardDetail: TravelCardSnapshot?
    @State private var linkedFlightDetail: TravelCardSnapshot?
    @AppStorage("ledger.showsEstimatedExpenseDetails") private var showsEstimatedDetails = false

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
                        MemoSection(syncEngine: syncEngine, creatingList: $creatingMemoList)
                    }
                }
            }
            .overlay {
                if let card = linkedFlightDetail {
                    FlightTicketPopup(
                        card: card,
                        currency: syncEngine.trip?.currency,
                        showsPassengers: syncEngine.isUserAuthenticated && members.count > 1,
                        onDismiss: {
                            withAnimation(.snappy(duration: 0.24)) { linkedFlightDetail = nil }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(10_000)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $addingExpense) {
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip, members: members) { request, key in
                        await syncEngine.saveExpenseFromEditor(request, existing: nil, idempotencyKey: key)
                    }
                }
            }
            .sheet(isPresented: $addingEstimate) {
                if let trip = syncEngine.trip {
                    ExpenseEstimateEditorView(trip: trip) { card, amount, currency in
                        await syncEngine.updateCard(
                            card,
                            request: CardRequest(
                                priceMinor: amount,
                                priceCurrency: currency,
                                fieldsToClear: []
                            )
                        )
                        showsEstimatedDetails = true
                    }
                }
            }
            .sheet(item: $editorTarget) { expense in
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip, existingExpense: expense, members: members) { request, key in
                        await syncEngine.saveExpenseFromEditor(request, existing: expense, idempotencyKey: key)
                    }
                }
            }
            .sheet(item: $linkedCardDetail) { card in
                CardDetailView(
                    card: card,
                    currency: syncEngine.trip?.currency,
                    showsPassengers: syncEngine.isUserAuthenticated && members.count > 1
                )
                .presentationDetents([.fraction(0.82), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
                .presentationBackground(PrimaryTabPalette.background)
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

                if section == .expenses {
                    Menu {
                        Button {
                            addingExpense = true
                        } label: {
                            Label("expenseeditor.addTitle", systemImage: "receipt")
                        }
                        Button {
                            addingEstimate = true
                        } label: {
                            Label("expenseestimate.addTitle", systemImage: "tag")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 21, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .menuOrder(.fixed)
                    .primaryTabHeaderButtonStyle()
                    .disabled(syncEngine.trip?.currency == nil)
                    .accessibilityLabel(Text("expense.addA11y"))
                } else {
                    Button(action: addManualEntry) {
                        Image(systemName: "plus")
                            .font(.system(size: 21, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .primaryTabHeaderButtonStyle()
                    .accessibilityLabel(Text(LocalizedStringKey(section.addAccessibilityKey)))
                }
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
            List {
                // 同步状态不再展示提示条：本地先落库，登录后由前台
                // 轮询/场景回前台静默重试上传（SyncEngine.startForegroundSync）。
                ExpenseSummaryView(
                    trip: trip,
                    currency: currency,
                    members: members,
                    selectedConsumerID: listFilter.consumer?.id,
                    selectedPaymentStatus: listFilter.paymentStatus
                ) { consumer, status in
                    withAnimation(.snappy(duration: 0.22)) {
                        listFilter.toggleConsumer(consumer, paymentStatus: status)
                    }
                }
                .expenseLedgerListRow(top: 4)

                HStack {
                    Text("expense.section")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(String(format: String(localized: "expense.filteredCountFormat"), visibleExpenses(in: trip).count, trip.expenses.count))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                .expenseLedgerListRow(top: 10, bottom: 4)

                filterBar(trip: trip)
                    .expenseLedgerListRow(top: 4, bottom: 6)

                if trip.expenses.isEmpty && (!showsEstimatedDetails || visibleEstimateCards(in: trip).isEmpty) {
                    ContentUnavailableView(
                        "expense.emptyTitle",
                        systemImage: "receipt",
                        description: Text("expense.emptyDesc")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .expenseLedgerListRow()
                } else if visibleExpenses(in: trip).isEmpty && (!showsEstimatedDetails || visibleEstimateCards(in: trip).isEmpty) {
                    ContentUnavailableView(
                        "expense.noMatchTitle",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("expense.noMatchDesc")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .expenseLedgerListRow()
                } else {
                    ForEach(visibleExpenses(in: trip)) { expense in
                        expenseRow(expense, currency: currency)
                            .expenseLedgerListRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    pendingDeletion = expense
                                } label: {
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                    }
                }
                if showsEstimatedDetails {
                    ForEach(visibleEstimateCards(in: trip)) { card in
                        estimateRow(card, currency: currency)
                            .expenseLedgerListRow()
                    }
                }

                Color.clear
                    .frame(height: 116)
                    .expenseLedgerListRow(top: 0, bottom: 0)
                    .accessibilityHidden(true)
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 0)
            .scrollContentBackground(.hidden)
            .background(PrimaryTabPalette.background)
            .scrollIndicators(.hidden)
            .refreshable { await syncEngine.refresh() }
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
        listFilter.apply(to: trip.expenses, members: members)
    }

    private func filterBar(trip: SharedTripSnapshot) -> some View {
        let consumerOptions = ExpenseListFilter.consumerOptions(from: trip.expenses, members: members)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
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

            Button {
                withAnimation(.snappy(duration: 0.2)) { showsEstimatedDetails.toggle() }
            } label: {
                toggleFilterChipLabel(
                    title: String(localized: "expensesummary.estimateShort"),
                    active: showsEstimatedDetails
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(
                showsEstimatedDetails
                    ? String(localized: "expense.hideEstimates")
                    : String(localized: "expense.showEstimates")
            ))

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

            if listFilter.isActive || showsEstimatedDetails {
                Button("expense.filter.clear") {
                    listFilter.consumer = nil
                    listFilter.paymentStatus = .all
                    listFilter.category = nil
                    showsEstimatedDetails = false
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.accent)
            }
            }
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

    private func toggleFilterChipLabel(title: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Image(systemName: active ? "checkmark" : "eye")
                .font(.system(size: 10, weight: .bold))
        }
        .foregroundStyle(active ? .black : PrimaryTabPalette.secondaryText)
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .background(
            active ? PrimaryTabPalette.accent.opacity(0.85) : PrimaryTabPalette.surface,
            in: Capsule()
        )
    }

    // MARK: - 支出卡片

    /// 卡片文案拆解：agent 记账会把项目名并入 note 首行，取之作标题，
    /// 其余行作为备注展示；无 note 时退回分类名，保证卡片始终有主标题。
    private struct ExpenseCopy {
        let title: String
        let noteRemainder: String?

        init(_ expense: ExpenseSnapshot) {
            let lines = (expense.note ?? "")
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = lines.first, !first.isEmpty {
                title = String(first)
                let rest = lines.dropFirst().filter { !$0.isEmpty }
                noteRemainder = rest.isEmpty ? nil : rest.joined(separator: "\n")
            } else {
                title = expense.category.title
                noteRemainder = nil
            }
        }
    }

    private func expenseRow(_ expense: ExpenseSnapshot, currency: String) -> some View {
        let copy = ExpenseCopy(expense)
        let cards = linkedCards(for: expense)
        return HStack(alignment: .top, spacing: 11) {
            // 分类图标：着色底衬，仅作快速识别锚点。
            Image(systemName: expense.category.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PrimaryTabPalette.accent)
                .frame(width: 34, height: 34)
                .background(
                    PrimaryTabPalette.accent.opacity(0.13),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        // 标题最多占两行，避免在仍有纵向空间时过早省略。
                        Text(copy.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)

                        HStack(spacing: 5) {
                            Text(expense.category.title)
                            Text("·")
                            Text(expenseTimeText(expense))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    // 金额只占顶部右侧，让下面的属性标签尽量吃满整行宽度。
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(ExpenseMoney.formatted(expense.amountMinor, currency: expense.currency))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .fixedSize(horizontal: false, vertical: true)
                        if !expense.isPaid() {
                            Text(expense.paidAt.map { String(format: String(localized: "expense.unpaidWithDateBadge"), Self.badgeDateFormatter.string(from: $0)) }
                                ?? String(localized: "expense.unpaidBadge"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.16), in: Capsule())
                                .fixedSize()
                        } else if expense.currency != currency, let settled = expense.amountForSettlement {
                            Text("≈ " + ExpenseMoney.formatted(settled, currency: currency))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.82)
                        }
                    }
                }

                // 属性 chips：金额块不再占整列宽度后，这里会先尽量排成一行；
                // 只有真的放不下时才换行。绑定行程 tag 仍单独占一行。
                let attributeChips = attributeChipModels(expense)
                if !attributeChips.isEmpty {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(attributeChips) { chip in
                            attributeChip(chip)
                        }
                    }
                }

                // 每个关联活动各自占一行：不能折叠为「+n」，以免遗漏支出归属。
                if !cards.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(cards) { linked in
                            Button { presentLinkedCardDetail(linked) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: linked.kind.systemImage)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(linked.title)
                                        .lineLimit(1)
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(PrimaryTabPalette.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(PrimaryTabPalette.accent.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(String(
                                format: String(localized: "expense.a11y.linkedCard"),
                                linked.title
                            )))
                        }
                    }
                }

                // 备注：仅显示未被标题占用的剩余内容。
                if let remainder = copy.noteRemainder {
                    Text(remainder)
                        .font(.system(size: 12))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        .contentShape(Rectangle())
        .onTapGesture { editorTarget = expense }
        .contextMenu {
            Button("common.edit", systemImage: "pencil") { editorTarget = expense }
            Button("common.delete", systemImage: "trash", role: .destructive) { pendingDeletion = expense }
        }
    }

    private struct AttributeChip: Identifiable {
        let id: String
        let systemImage: String
        let text: String
        let a11yKey: String
    }

    /// 消费人优先取成员名（更即时），渠道/支付方式取结构化字段。
    private func attributeChipModels(_ expense: ExpenseSnapshot) -> [AttributeChip] {
        var chips: [AttributeChip] = []
        let consumerName = expense.consumerUserID.flatMap { id in
            members.first { $0.userId == id }?.visibleName
        } ?? expense.consumerName
        if let consumer = consumerName?.trimmingCharacters(in: .whitespacesAndNewlines), !consumer.isEmpty {
            chips.append(AttributeChip(id: "consumer", systemImage: "person.fill", text: consumer, a11yKey: "expense.a11y.consumer"))
        }
        if let channel = expense.purchaseChannel?.trimmingCharacters(in: .whitespacesAndNewlines), !channel.isEmpty {
            chips.append(AttributeChip(id: "channel", systemImage: "storefront", text: channel, a11yKey: "expense.a11y.channel"))
        }
        if let method = expense.paymentMethod {
            let title = ExpensePaymentMethod(rawValue: method)?.title ?? method
            chips.append(AttributeChip(id: "payment", systemImage: "creditcard", text: title, a11yKey: "expense.a11y.paymentMethod"))
        }
        return chips
    }

    private func attributeChip(_ chip: AttributeChip) -> some View {
        HStack(spacing: 4) {
            Image(systemName: chip.systemImage)
                .font(.system(size: 9, weight: .semibold))
            Text(chip.text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(PrimaryTabPalette.secondaryText)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(PrimaryTabPalette.surface, in: Capsule())
        .fixedSize()
        .accessibilityLabel(Text(String(format: String(localized: String.LocalizationValue(chip.a11yKey)), chip.text)))
    }

    private func linkedCards(for expense: ExpenseSnapshot) -> [TravelCardSnapshot] {
        let cards = syncEngine.trip?.days.flatMap(\.cards) ?? []
        return expense.cardIDs.compactMap { id in cards.first { $0.serverID == id } }
    }

    /// 与首页列表卡保持同一详情层级：普通活动/酒店使用底部 sheet，
    /// 航班保留专用票券弹层。
    private func presentLinkedCardDetail(_ card: TravelCardSnapshot) {
        if card.kind == .flight {
            linkedFlightDetail = card
        } else {
            linkedCardDetail = card
        }
    }

    /// 消费时间优先；否则把发生日 ISO 串转成本地化短日期，不再裸奔 yyyy-MM-dd。
    private func expenseTimeText(_ expense: ExpenseSnapshot) -> String {
        if let spentAt = expense.spentAt {
            return spentAt.formatted(.dateTime.month().day().hour().minute())
        }
        if let date = Self.cardDayFormatter.date(from: expense.occurredOn) {
            return date.formatted(.dateTime.month().day())
        }
        return expense.occurredOn
    }

    private static let badgeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let cardDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func visibleEstimateCards(in trip: SharedTripSnapshot) -> [TravelCardSnapshot] {
        let linked = Set(trip.expenses.flatMap(\.cardIDs))
        return trip.days.flatMap(\.cards).filter { card in
            guard let id = card.serverID, !linked.contains(id), card.actualPriceMinor == nil,
                  card.priceMinor != nil else { return false }
            return card.priceCurrency == nil || card.priceCurrency == trip.currency
        }
        .sorted { $0.startAt < $1.startAt }
    }

    private func estimateRow(_ card: TravelCardSnapshot, currency: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: card.kind.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .frame(width: 34, height: 34)
                .background(PrimaryTabPalette.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(card.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                Text("expensesummary.estimateShort")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            Spacer(minLength: 8)
            if let amount = card.priceMinor {
                Text(ExpenseMoney.formatted(amount, currency: card.priceCurrency ?? currency))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        .contentShape(Rectangle())
        .onTapGesture { presentLinkedCardDetail(card) }
    }

    private func addManualEntry() {
        switch section {
        case .expenses: addingExpense = true
        case .wallet: addingWalletItem = true
        case .memo: creatingMemoList = true
        }
    }
}

private extension View {
    /// Keeps native List behavior while preserving the ledger's card spacing and black canvas.
    func expenseLedgerListRow(top: CGFloat = 6, bottom: CGFloat = 6) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: 16, bottom: bottom, trailing: 16))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

/// 简易流式布局：属性 chips 超出可用宽度时自动换行，保持卡片紧凑。
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = Self.rows(subviews: subviews, maxWidth: proposal.width, spacing: spacing)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: max(width, 0), height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = Self.rows(subviews: subviews, maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private static func rows(subviews: Subviews, maxWidth: CGFloat?, spacing: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        var x: CGFloat = 0
        let limit = maxWidth ?? .infinity
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit {
                rows.append(Row())
                x = 0
            }
            let isFirstInRow = x == 0
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += size.width + (isFirstInRow ? 0 : spacing)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            x += size.width + spacing
        }
        return rows
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
