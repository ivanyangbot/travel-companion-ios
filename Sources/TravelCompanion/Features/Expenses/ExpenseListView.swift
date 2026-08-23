import SwiftUI

struct ExpenseListView: View {
    @ObservedObject var syncEngine: SyncEngine
    @State private var editorTarget: ExpenseSnapshot?
    @State private var addingExpense = false
    @State private var showingAIScan = false
    @State private var pendingDeletion: ExpenseSnapshot?
    @State private var section: ExpenseSection = .expenses

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
                        WalletSection(syncEngine: syncEngine)
                    case .memo:
                        MemoSection(syncEngine: syncEngine)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $addingExpense) {
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip) { request in
                        Task { await syncEngine.addExpense(request) }
                    }
                }
            }
            .sheet(isPresented: $showingAIScan) {
                if let trip = syncEngine.trip {
                    AIExpenseConversationSheet(syncEngine: syncEngine, trip: trip) { request in
                        Task { await syncEngine.addExpense(request) }
                    }
                }
            }
            .sheet(item: $editorTarget) { expense in
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip, existingExpense: expense) { request in
                        Task { await syncEngine.updateExpense(expense, request: request) }
                    }
                }
            }
            .alert(
                "删除这笔支出？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                presenting: pendingDeletion
            ) { expense in
                Button("删除", role: .destructive) {
                    Task { await syncEngine.deleteExpense(expense) }
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { _ in
                Text("删除后会同步移除这笔公开共享支出。")
            }
        }
    }

    private var expenseHeader: some View {
        ZStack {
            Text("账本")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack {
                Spacer(minLength: 0)

                if section == .expenses {
                    Menu {
                        Button("手动添加", systemImage: "plus") { addingExpense = true }
                        Button("扫小票 / 对话", systemImage: "doc.viewfinder") { showingAIScan = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 21, weight: .medium))
                            .frame(width: 40, height: 40)
                    }
                    .primaryTabHeaderButtonStyle()
                    .disabled(syncEngine.trip?.currency == nil)
                    .accessibilityLabel("添加支出")
                } else {
                    Color.clear.frame(width: 48, height: 48)
                }
            }
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .overlay(alignment: .bottom) {
            Rectangle().fill(PrimaryTabPalette.divider).frame(height: 1)
        }
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
                .accessibilityValue(option == section ? "已选择" : "")
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
                    syncFeedback
                    ExpenseSummaryView(trip: trip, currency: currency)

                    HStack {
                        Text("支出明细")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("\(trip.expenses.count) 笔")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                    .padding(.top, 4)

                    if trip.expenses.isEmpty {
                        ContentUnavailableView(
                            "还没有实际价",
                            systemImage: "receipt",
                            description: Text("手动添加或扫小票记录交通、住宿和餐饮的实际花费。")
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    } else {
                        ForEach(
                            trip.expenses.sorted {
                                ($0.occurredOn, $0.updatedAt) > ($1.occurredOn, $1.updatedAt)
                            }
                        ) { expense in
                            expenseRow(expense, currency: currency)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 128)
            }
            .scrollIndicators(.hidden)
        } else {
            ContentUnavailableView(
                "请先设置行程",
                systemImage: "calendar.badge.exclamationmark",
                description: Text("在行程页填写目的地、日期和币种后即可记录支出。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 112)
        }
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
                Text(expense.category.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Text(expense.occurredOn)
                    if let card = linkedCard(for: expense) {
                        Text("·").foregroundStyle(PrimaryTabPalette.tertiaryText)
                        Image(systemName: "link")
                        Text(card.title).lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(PrimaryTabPalette.secondaryText)

                if let note = expense.note, !note.isEmpty {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
            }

            Spacer(minLength: 8)

            Text(ExpenseMoney.formatted(expense.amountMinor, currency: currency))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
        .contentShape(Rectangle())
        .onTapGesture { editorTarget = expense }
        .contextMenu {
            Button("编辑", systemImage: "pencil") { editorTarget = expense }
            Button("删除", systemImage: "trash", role: .destructive) { pendingDeletion = expense }
        }
    }

    private func linkedCard(for expense: ExpenseSnapshot) -> TravelCardSnapshot? {
        guard let cardID = expense.cardID else { return nil }
        return syncEngine.trip?.days.flatMap(\.cards).first { $0.serverID == cardID }
    }

    @ViewBuilder
    private var syncFeedback: some View {
        switch syncEngine.status {
        case .synced:
            EmptyView()
        case .loading, .syncing:
            EmptyView()
        case .pending(let count):
            HStack {
                Label("有 \(count) 项修改待同步", systemImage: "clock.arrow.circlepath")
                Spacer()
                Button("重试") { Task { await syncEngine.retry() } }
                    .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.orange)
        case .conflict:
            HStack {
                Label("检测到协作覆盖，已显示服务器最新结果", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                Spacer()
                Button("刷新") { Task { await syncEngine.retry() } }
                    .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.orange)
        case .localOnly:
            EmptyView()
        case .offline(let message), .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "wifi.exclamationmark")
                Spacer()
                Button("重试") { Task { await syncEngine.retry() } }
                    .font(.caption.weight(.semibold))
            }
            .font(.caption)
            .foregroundStyle(.red)
        }
    }
}

private enum ExpenseSection: CaseIterable, Identifiable {
    case expenses
    case wallet
    case memo

    var title: String {
        switch self {
        case .expenses: "支出"
        case .wallet: "卡包"
        case .memo: "备忘"
        }
    }

    var id: Self { self }
}
