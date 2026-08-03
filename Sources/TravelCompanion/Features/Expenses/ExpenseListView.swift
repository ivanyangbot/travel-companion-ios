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
            VStack(spacing: 0) {
                Picker("本分区", selection: $section) {
                    Text("支出").tag(ExpenseSection.expenses)
                    Text("卡包").tag(ExpenseSection.wallet)
                    Text("备忘").tag(ExpenseSection.memo)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 4)

                switch section {
                case .expenses:
                    expenseContent
                case .wallet:
                    WalletSection(syncEngine: syncEngine)
                case .memo:
                    MemoSection(syncEngine: syncEngine)
                }
            }
            .navigationTitle(section.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if section == .expenses {
                        Menu {
                            Button("手动添加", systemImage: "plus") { addingExpense = true }
                            Button("扫小票 / 对话", systemImage: "doc.viewfinder") { showingAIScan = true }
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.glass)
                        .disabled(syncEngine.trip?.currency == nil)
                    }
                }
            }
            .sheet(isPresented: $addingExpense) {
                if let trip = syncEngine.trip {
                    ExpenseEditorView(trip: trip) { request in Task { await syncEngine.addExpense(request) } }
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
                    ExpenseEditorView(trip: trip, existingExpense: expense) { request in Task { await syncEngine.updateExpense(expense, request: request) } }
                }
            }
            .alert("删除这笔支出？", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), presenting: pendingDeletion) { expense in
                Button("删除", role: .destructive) { Task { await syncEngine.deleteExpense(expense) }; pendingDeletion = nil }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: { _ in Text("删除后会同步移除这笔公开共享支出。") }
        }
    }

    @ViewBuilder
    private var expenseContent: some View {
        if let trip = syncEngine.trip, let currency = trip.currency {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    syncFeedback
                    ExpenseSummaryView(trip: trip, currency: currency)
                    Text("明细").font(.title3.bold())
                    if trip.expenses.isEmpty {
                        ContentUnavailableView("还没有实际价", systemImage: "receipt", description: Text("手动添加或扫小票记录交通、住宿和餐饮的实际花费。"))
                    } else {
                        ForEach(trip.expenses.sorted { ($0.occurredOn, $0.updatedAt) > ($1.occurredOn, $1.updatedAt) }) { expense in
                            expenseRow(expense, currency: currency)
                        }
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView("请先设置行程", systemImage: "calendar.badge.exclamationmark", description: Text("在行程页填写目的地、日期和币种后即可记录支出。"))
        }
    }

    private func expenseRow(_ expense: ExpenseSnapshot, currency: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: expense.category.systemImage)
                .frame(width: 34, height: 34)
                .glassEffect(.regular.tint(.indigo), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(expense.category.title).font(.headline)
                HStack(spacing: 6) {
                    Text(expense.occurredOn)
                    if let card = linkedCard(for: expense) {
                        Text("·").foregroundStyle(.tertiary)
                        Image(systemName: "link")
                        Text(card.title).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let note = expense.note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Text(ExpenseMoney.formatted(expense.amountMinor, currency: currency)).font(.headline).monospacedDigit()
        }
        .padding(14)
        .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
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

    @ViewBuilder private var syncFeedback: some View {
        switch syncEngine.status {
        case .synced:
            EmptyView()
        case .loading, .syncing:
            Label("正在同步共享支出…", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption).foregroundStyle(.secondary)
        case .pending(let count):
            HStack {
                Label("有 \(count) 项修改待同步", systemImage: "clock.arrow.circlepath")
                Spacer()
                Button("重试") { Task { await syncEngine.retry() } }.font(.caption.weight(.semibold))
            }
            .font(.caption).foregroundStyle(.orange)
        case .conflict:
            HStack {
                Label("检测到协作覆盖，已显示服务器最新结果", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90")
                Spacer()
                Button("刷新") { Task { await syncEngine.retry() } }.font(.caption.weight(.semibold))
            }
            .font(.caption).foregroundStyle(.orange)
        case .localOnly:
            Label("本地模式·登录后可同步", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption).foregroundStyle(.secondary)
        case .offline(let message), .failed(let message):
            HStack(alignment: .top) {
                Label(message, systemImage: "wifi.exclamationmark")
                Spacer()
                Button("重试") { Task { await syncEngine.retry() } }.font(.caption.weight(.semibold))
            }
            .font(.caption).foregroundStyle(.red)
        }
    }
}

private enum ExpenseSection {
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
}
