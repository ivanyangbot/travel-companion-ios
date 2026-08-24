import PhotosUI
import SwiftUI
import UIKit

/// 首页 Agent 进入「拈签定缘」追问或展开输入条（即点按了第一步的两个方块
/// 入口）时，向上声明隐藏底部悬浮 tab 栏；ContentView 通过 onPreferenceChange
/// 读取并收起底部导航，退出流程回到双方块入口后自动恢复。
struct AgentHomeHidesTabBarKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

/// 首页（无生效行程时）内嵌的 Agent 页：从 AgentWorkbenchView 复制而来，
/// 供首页场景独立调整，与 Agent 主页面互不影响。草稿同样保持在本地，
/// 用户明确选择并确认后才写入行程。
struct AgentHomeView: View {
    @ObservedObject var syncEngine: SyncEngine
    let initialMessage: String?
    let onInitialMessageSubmitted: (() -> Void)?
    @EnvironmentObject private var store: AgentV2SessionStore
    @EnvironmentObject private var runState: AgentV2RunState
    @FocusState private var isComposerFocused: Bool
    @State private var message = ""
    @State private var photo: PhotosPickerItem?
    @State private var isShowingContext = false
    @State private var isShowingHistory = false
    @State private var didConsumeInitialMessage = false
    @State private var didSubmitInitialMessage = false
    @State private var isCreatingTripFromProposal = false
    @State private var isReasoningExpanded = false
    /// 底部输入区是否已展开：折叠态为左右两个等宽正方形入口，
    /// 点按右侧输入方块后才展开为完整输入条并弹出键盘。
    @State private var isComposerExpanded = false
    /// 「拈签定缘」抽签流程：nil 表示未在流程中，否则为当前问题的下标。
    @State private var lotteryStepIndex: Int?
    /// 折叠方块与展开输入条之间做连续变形动画（matchedGeometryEffect）的命名空间。
    @Namespace private var composerMotion
    /// 抽签流程中已收集的选择（问题 key → 选项文案），最终作为上下文发给 Agent。
    @State private var lotteryAnswers: [(key: String, value: String)] = []
    /// 「拈签定缘」的追问序列：逐步收窄范围，最后把所有选择交给 Agent 抽签。
    private let lotterySteps: [(question: String, key: String, left: String, right: String)] = [
        ("或许我们可以缩小一下范围？", "范围", "海外", "国内"),
        ("想要躺平慢游，还是特种兵打卡？", "节奏", "躺平慢游", "特种兵打卡"),
        ("预算上更偏向哪一边？", "预算", "精打细算", "品质优先")
    ]
    /// 右侧输入入口底部滚动展示的目的地灵感（附对应国家的国旗 emoji），
    /// 循环向上翻滚切换。
    private let inspirationSuggestions: [(name: String, flag: String)] = [
        ("巴厘岛", "🇮🇩"), ("马赛马拉", "🇰🇪"), ("京都", "🇯🇵"), ("冰岛", "🇮🇸"),
        ("圣托里尼", "🇬🇷"), ("清迈", "🇹🇭"), ("新西兰", "🇳🇿"), ("摩洛哥", "🇲🇦"),
        ("瑞士", "🇨🇭"), ("挪威", "🇳🇴"), ("卡帕多奇亚", "🇹🇷"), ("马丘比丘", "🇵🇪"),
        ("撒哈拉", "🇩🇿"), ("北海道", "🇯🇵"), ("大理", "🇨🇳"), ("喀纳斯", "🇨🇳"),
        ("帕劳", "🇵🇼"), ("科莫多", "🇮🇩"), ("托斯卡纳", "🇮🇹"), ("阿马尔菲", "🇮🇹")
    ]
    /// 当前滚动到的灵感序号（只增不减，渲染时取模循环）。
    @State private var inspirationIndex = 0
    /// 两个入口方块的宽高比（宽/高）：略高于正方形，视觉更稳。
    private let entryTileAspectRatio: CGFloat = 0.88

    init(
        syncEngine: SyncEngine,
        initialMessage: String? = nil,
        onInitialMessageSubmitted: (() -> Void)? = nil
    ) {
        self.syncEngine = syncEngine
        self.initialMessage = initialMessage
        self.onInitialMessageSubmitted = onInitialMessageSubmitted
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PrimaryTabPalette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    ZStack {
                        if isWelcomeState {
                            // 底纹与光晕延伸到输入区下方，让玻璃方块能模糊到底部内容，
                            // 与主界面悬浮导航栏的材质效果一致。
                            AgentIntroASCIIBackgroundView()
                                .ignoresSafeArea(edges: .bottom)
                            RadialGradient(
                                colors: [.clear, PrimaryTabPalette.background.opacity(0.74)],
                                center: .center,
                                startRadius: 100,
                                endRadius: 330
                            )
                            .allowsHitTesting(false)
                            .ignoresSafeArea(edges: .bottom)
                        }

                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 22) {
                                    if isWelcomeState {
                                        welcomeView
                                    } else {
                                        conversationView
                                    }
                                    Color.clear.frame(height: 1).id("conversation-bottom")
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 16)
                            }
                            .scrollIndicators(.hidden)
                            .scrollDismissesKeyboard(.interactively)
                            // 初始页（ASCII 地球欢迎态）固定不可滑动；进入对话后恢复滚动。
                            .scrollDisabled(isWelcomeState)
                            // 点按页面空白处：收起键盘并收回为双方块入口，与左上角
                            // 返回键一致；方块内的按钮仍优先响应各自的点按。
                            .contentShape(Rectangle())
                            .onTapGesture { if isComposerExpanded { collapseComposer() } }
                            .onChange(of: store.session.messages.count) { _, _ in scrollToBottom(proxy) }
                            .onChange(of: runState.streamingReply) { _, _ in scrollToBottom(proxy, animated: false) }
                            .onChange(of: runState.liveCards.count) { _, _ in scrollToBottom(proxy) }
                            .onChange(of: store.session.draft?.candidates.count ?? 0) { _, _ in scrollToBottom(proxy) }
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                // 左上角共用返回键：抽签流程中返回上一步（第一问时退出流程）；
                // 欢迎页输入条展开时收起，回到双方块入口；对话页返回则归档
                // 当前对话并完全复位到首页初始状态（双方块入口）。
                if lotteryStepIndex != nil || isComposerExpanded || !isWelcomeState {
                    Button {
                        if lotteryStepIndex != nil {
                            backLottery()
                        } else if isWelcomeState {
                            collapseComposer()
                        } else {
                            exitConversation()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(PrimaryTabPalette.surface, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
                    .accessibilityLabel("返回")
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .sheet(isPresented: $isShowingContext) {
                AgentContextSheet(syncEngine: syncEngine, store: store)
            }
            .sheet(isPresented: $isShowingHistory) {
                AgentHistorySheet(store: store) {
                    runState.clearTransientState()
                }
            }
            .alert("无法完成操作", isPresented: Binding(get: { runState.error != nil }, set: { if !$0 { runState.error = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(runState.error ?? "") }
            .onAppear {
                consumeInitialMessageIfNeeded()
            }
            .onChange(of: runState.isGenerating) { _, isGenerating in
                // 新一轮生成从折叠状态开始；生成结束后思考摘要整体隐藏。
                if !isGenerating { isReasoningExpanded = false }
            }
            .onChange(of: initialMessage) { _, newValue in
                guard newValue != nil else { return }
                didConsumeInitialMessage = false
                didSubmitInitialMessage = false
                consumeInitialMessageIfNeeded()
            }
        }
        // 进入抽签追问、展开输入条或已进入对话（点按了第一步的两个方块之后
        // 的所有状态）时，通知 ContentView 收起底部悬浮 tab 栏；退出回到
        // 欢迎入口后恢复。
        .preference(
            key: AgentHomeHidesTabBarKey.self,
            value: hidesTabBar
        )
        // tab 栏在场（欢迎页双方块）时为其预留整块高度（栏高 60pt + 底边距
        // 32pt），双方块悬浮其上；tab 栏隐藏（展开输入条/抽签/对话页）时不
        // 预留，输入区随 safeAreaInset 贴到屏幕底部安全区之上。
        .padding(.bottom, hidesTabBar ? 0 : 92)
    }

    private var tripTitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "未设置旅行" }
        return trip.destination ?? "本次旅行"
    }

    private var isWelcomeState: Bool {
        store.session.messages.isEmpty && store.session.draft == nil
    }

    /// 底部悬浮 tab 栏是否处于隐藏状态（进入抽签、展开输入条或已在对话中）。
    /// 与上报给 ContentView 的偏好值一致；隐藏时输入区整体贴底，不再为
    /// 悬浮栏预留空间。
    private var hidesTabBar: Bool {
        lotteryStepIndex != nil || isComposerExpanded || !isWelcomeState
    }

    /// 欢迎页主标题：抽签流程中显示当前问题，否则显示默认引导文案。
    private var welcomeTitle: String {
        lotteryStepIndex.map { lotterySteps[$0].question } ?? "告诉豆奶你想去哪里。"
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: 24) {
        // 地球与同心光晕放大到内容区宽度的 70%。
        GeometryReader { proxy in
        let globe = proxy.size.width * 0.7
        ZStack {
        // 与地球同心的圆形橙色光晕，位于下层：字符叠在光晕之上，不会被糊住。
        Circle()
        .fill(
            RadialGradient(
                colors: [PrimaryTabPalette.accent.opacity(0.5), PrimaryTabPalette.accent.opacity(0)],
                center: .center,
                startRadius: globe * 0.14,
                endRadius: globe * 0.62
            )
        )
        .frame(width: globe * 1.25, height: globe * 1.25)
        .blur(radius: globe * 0.12)
        .allowsHitTesting(false)
        AgentIntroGlobeView(diameter: globe)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(.top, 12)

            VStack(alignment: .leading, spacing: 12) {
                // 抽签流程中标题切换为当前问题，文案渐入渐出。滚动区边距为
                // 16pt，补 4pt 后标题左缘（20pt）与底部双方块入口对齐。
                ZStack(alignment: .leading) {
                    Text(welcomeTitle)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .id(welcomeTitle)
                        .transition(.opacity)
                }
                .padding(.leading, 4)
            }

            // tripContextCard
        }
    }

    private var tripContextCard: some View {
        Button { isShowingContext = true } label: {
            HStack(spacing: 12) {
                Image(systemName: syncEngine.trip?.isConfigured == true ? "map.fill" : "calendar.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(width: 36, height: 36)
                    .background(PrimaryTabPalette.accent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(tripTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(tripContextSubtitle).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText).lineLimit(2)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            .padding(14)
            .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var tripContextSubtitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return "先设置目的地、日期，再开始规划" }
        var details = ["\(trip.startDate ?? "") – \(trip.endDate ?? "")"]
        let preferences = preferenceLabels
        if !preferences.isEmpty { details.append(preferences.joined(separator: " · ")) }
        return details.joined(separator: "  ·  ")
    }

    private var preferenceLabels: [String] {
        let preferences = store.session.preferences
        return [
            preferenceTitle(preferences.pace, values: ["relaxed": "轻松", "balanced": "均衡", "packed": "特种兵"]),
            preferenceTitle(preferences.companions, values: ["solo": "独自", "couple": "情侣", "parents": "带父母", "children": "带儿童"]),
            preferenceTitle(preferences.budget, values: ["value": "省钱", "balanced": "适中", "premium": "品质优先"])
        ].compactMap { $0 }
    }

    private func preferenceTitle(_ value: String?, values: [String: String]) -> String? {
        guard let value else { return nil }
        return values[value]
    }

    private var conversationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 橘色头像每个助手回合只显示一次（该回合第一条消息）；其余
            // 助手区块保留同样的缩进对齐，但不再重复头像。
            ForEach(Array(store.session.messages.enumerated()), id: \.element.id) { index, item in
                ChatMessageView(
                    message: item,
                    showsAvatar: item.role == "user" || index == 0 || store.session.messages[index - 1].role == "user"
                )
            }

            // 思考摘要只在本轮生成期间可见，且始终位于当轮回复上方。
            // 状态行本身承载展开/收起（箭头也在这一行）：有摘要时点按
            // 状态行切换，摘要就地展开在状态行下方、回复上方。
            if let status = runState.status {
                // 状态行不使用 AssistantMessageContainer：头像占位会让 orb
                // 右移，这一行需要顶着左边缘显示（orb 本身就是行首图标）。
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isReasoningExpanded.toggle() }
                    } label: {
                        HStack(spacing: 10) {
                            ThinkingOrb(state: agentThinkingOrbState(for: status), size: .px20, theme: .dark)
                            // 思考状态限定单行，过长时尾部省略，避免状态行被长文案撑高。
                            Text(status)
                                .lineLimit(1)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                            Spacer(minLength: 8)
                            if !runState.reasoningSummary.isEmpty {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(PrimaryTabPalette.tertiaryText)
                                    .rotationEffect(.degrees(isReasoningExpanded ? 90 : 0))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(runState.reasoningSummary.isEmpty)

                    if isReasoningExpanded, !runState.reasoningSummary.isEmpty {
                        Text(runState.reasoningSummary)
                            .font(.footnote)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if runState.isGenerating, !runState.reasoningSummary.isEmpty {
                // 回复开始流出后状态行消失，此时直接把摘要内容展示在回复上方。
                AssistantMessageContainer(showsAvatar: false) {
                    Text(runState.reasoningSummary)
                        .font(.footnote)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !runState.streamingReply.isEmpty {
                AssistantMessageContainer(showsAvatar: false) {
                    Text(runState.streamingReply)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let fliggy = runState.fliggyProgress {
                AssistantMessageContainer(showsAvatar: false) {
                    FliggySearchStatusChip(progress: fliggy)
                }
            }

            if !runState.liveCards.isEmpty {
                AssistantMessageContainer(showsAvatar: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("正在生成候选")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        ForEach(runState.liveCards) { card in
                            LiveCandidateCard(card: card)
                        }
                    }
                }
            }

            if let proposal = store.session.pendingProposal, syncEngine.trip?.isConfigured != true {
                AssistantMessageContainer(showsAvatar: false) {
                    tripProposalCard(proposal)
                }
            }

            if store.session.summary != nil || store.session.draft != nil {
                AssistantMessageContainer(showsAvatar: false) {
                    workbenchView
                }
            }
        }
    }

    @ViewBuilder private var workbenchView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = store.session.summary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("本轮建议", systemImage: "sparkles")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(summary.text)
                        .foregroundStyle(.white.opacity(0.85))
                    if !summary.pending.isEmpty {
                        Label(summary.pending.joined(separator: "、"), systemImage: "questionmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let draft = store.session.draft {
                if !draft.candidates.isEmpty {
                    // 草稿随对话跨轮延续：区分本轮新产出与前几轮未确认的候选，
                    // 避免列表越滚越长时用户分不清来源。旧版本会话没有
                    // lastTurnCandidateIDs 时全部视为本轮。
                    let lastTurnIDs = Set(store.session.lastTurnCandidateIDs ?? draft.candidates.map(\.id))
                    let current = draft.candidates.filter { lastTurnIDs.contains($0.id) }
                    let carried = draft.candidates.filter { !lastTurnIDs.contains($0.id) }
                    VStack(alignment: .leading, spacing: 10) {
                        if !current.isEmpty {
                            candidateGroup(title: carried.isEmpty ? "候选行程" : "本轮新增（\(current.count)）", candidates: current)
                        }
                        if !carried.isEmpty {
                            candidateGroup(title: "前几轮待确认（\(carried.count)）", candidates: carried)
                        }
                    }
                }

                if !draft.changes.isEmpty {
                    DisclosureGroup("查看变更清单（\(draft.changes.count)）") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.changes) { change in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: change.operation.symbol)
                                        .foregroundStyle(change.operation.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(change.operationTitle + " · " + change.summary)
                                            .font(.subheadline)
                                            .foregroundStyle(.white)
                                        if let impact = change.impact {
                                            Text(impact).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText)
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 10)
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(PrimaryTabPalette.secondaryText)
                }

                let selected = draft.candidates.filter(\.selected)
                let commitReady = draft.candidates.filter(\.isCommitReady)
                let allCommitReadySelected = !commitReady.isEmpty && commitReady.allSatisfy(\.selected)
                // 变更清单中待确认的“移除行程卡”提案：无选中候选时也可单独提交。
                let pendingRemovals = draft.changes.filter { $0.operation == .remove && $0.targetCardId != nil }
                let hasBlockingSelection = selected.contains(where: { !$0.isCommitReady })
                let canCommit = !runState.isCommitting && !hasBlockingSelection && (!selected.isEmpty || !pendingRemovals.isEmpty)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("可导入 \(commitReady.count) 项" + (pendingRemovals.isEmpty ? "" : " · 待移除 \(pendingRemovals.count) 项"))
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                        Spacer()
                        Button(allCommitReadySelected ? "取消全选" : "全选可导入项") {
                            store.setSelected(!allCommitReadySelected, ids: Set(commitReady.map(\.id)))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                        .disabled(commitReady.isEmpty || runState.isCommitting)
                    }

                    Button { commit() } label: {
                        HStack {
                            if runState.isCommitting { ProgressView().tint(.white) }
                            Text(selected.isEmpty ? "确认移除（\(pendingRemovals.count)）" : "确认加入行程（\(selected.count)）")
                            Spacer()
                            Image(systemName: "arrow.right")
                        }
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: 50)
                        .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canCommit)
                    .opacity(canCommit || runState.isCommitting ? 1 : 0.45)

                    if hasBlockingSelection {
                        Text("仍在验证的地点暂不可加入；“地点待确认”的用户原文项目可以直接加入，稍后再补地图点位。")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else if selected.isEmpty && !pendingRemovals.isEmpty {
                        Text("确认后只会从行程中移除变更清单里列出的卡片，其他内容不变。")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else {
                        Text("确认前不会改动当前行程，未选择的候选仍留在本机草稿中。")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
            }
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 20)
    }

    /// plan_new 产出的旅程提案确认卡：仅在仍无生效旅程时展示。
    private func tripProposalCard(_ proposal: AgentV2TripProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("旅程提案", systemImage: "map")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Label(proposal.destination, systemImage: "location.fill")
                Label("\(proposal.startDate) 至 \(proposal.endDate)", systemImage: "calendar")
                Label("币种 \(proposal.currency)", systemImage: "creditcard")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))

            Button { confirmTripProposal(proposal) } label: {
                HStack {
                    if isCreatingTripFromProposal { ProgressView().tint(.white) }
                    Text("确认创建旅程")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: 50)
                .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isCreatingTripFromProposal)
            .opacity(isCreatingTripFromProposal ? 0.7 : 1)

            Text("确认后才会创建旅程；候选仍需在下方选择后加入行程。")
                .font(.caption)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 20)
    }

    @ViewBuilder
    private func candidateGroup(title: String, candidates: [AgentV2Candidate]) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PrimaryTabPalette.secondaryText)
        ForEach(candidates) { candidate in
            AgentV2CandidateCard(candidate: candidate) { value in
                store.setSelected(value, id: candidate.id)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !store.session.attachments.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .foregroundStyle(PrimaryTabPalette.accent)
                    Text("已附 \(store.session.attachments.count) 张图片")
                        .foregroundStyle(.white)
                    Text("· 发送失败后仍可重试").foregroundStyle(PrimaryTabPalette.secondaryText)
                    Spacer()
                }
                .font(.caption)
                .padding(.horizontal, 4)
            }

            // 双方块入口只在欢迎页（尚无对话）出现；进入对话后输入条常驻，
            // 键盘收起也不再收回为方块形态。
            if isComposerExpanded || !isWelcomeState {
                expandedComposer
            } else {
                collapsedComposer
            }
        }
        // 水平边距与底部悬浮 tab 栏（ContentView 的 20pt）对齐。tab 栏在场
        // （欢迎页双方块）底部留 36pt 与其拉开距离、悬浮在内容之上；tab 栏
        // 隐藏（展开输入条/抽签/对话页）输入区贴近屏幕底部，只留 8pt。
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, hidesTabBar ? 8 : 36)
        .onChange(of: isComposerFocused) { _, focused in
            // 键盘收起且没有草稿文本时收回为双方块入口；有内容或已在对话页
            // （输入条常驻）时保持展开。
            if !focused,
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               isWelcomeState {
                withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = false }
            }
        }
    }

    /// 展开态：完整输入条（图片、文本框、发送键）。背景与「+」控件和折叠态
    /// 右侧方块共享 matchedGeometryEffect，点按后连续变形为扁平输入条。
    private var expandedComposer: some View {
        // 「+」、输入框、发送键垂直居中对齐（多行输入时两侧按钮随行高中点）。
        HStack(alignment: .center, spacing: 8) {
            addPhotoButton

            TextField("告诉 Agent 你的想法", text: $message, axis: .vertical)
                .lineLimit(1...6)
                .focused($isComposerFocused)
                .foregroundStyle(.white)
                .padding(.horizontal, 13)
                .padding(.vertical, 10)
                .background {
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(PrimaryTabPalette.elevatedSurface)
                        .matchedGeometryEffect(id: "composer-field", in: composerMotion)
                }
                .onSubmit { if canSend { send() } }

            Button { runState.isGenerating ? cancelGeneration() : send() } label: {
                Image(systemName: runState.isGenerating ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(canSend || runState.isGenerating ? .white : PrimaryTabPalette.tertiaryText)
                    .frame(width: 36, height: 36)
                    .background(canSend || runState.isGenerating ? PrimaryTabPalette.accent : PrimaryTabPalette.elevatedSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!runState.isGenerating && !canSend)
            .accessibilityLabel(runState.isGenerating ? "停止生成" : "发送")
        }
    }

    /// 折叠态：左右两个宽度各占一半的正方形入口，材质与主界面悬浮 tab 栏
    /// 一致（玻璃底 + 白描边）。默认左侧“拈签定缘”、右侧输入入口（含添加
    /// 图片控件）；进入抽签流程后两个方块变为当前问题的两个选项。
    private var collapsedComposer: some View {
        VStack(spacing: 8) {
            if lotteryStepIndex != nil {
                // 跳过：跳过当前这一问（不记录选择）；已是最后一问则直接抽签。
                HStack {
                    Spacer()
                    Button { skipLottery() } label: {
                        HStack(spacing: 2) {
                            Text("跳过")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimaryTabPalette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("跳过本题")
                }
                .transition(.opacity)
            }

            HStack(spacing: 12) {
                leftEntrySquare
                rightEntrySquare
            }
        }
    }

    /// 左侧方块：默认是「拈签定缘」入口；抽签流程中是当前问题的左选项。
    private var leftEntrySquare: some View {
        Button {
            if let index = lotteryStepIndex {
                answerLottery(value: lotterySteps[index].left)
            } else {
                drawLot()
            }
        } label: {
            ZStack {
                if let index = lotteryStepIndex {
                    lotteryChoiceLabel(lotterySteps[index].left)
                        .id("lottery-left-\(index)")
                        .transition(.opacity)
                } else {
                    // 白图标 + 短标签整体靠左对齐，贴齐方块左内边距（20pt）。
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "dice.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("拈签定缘。")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                    .id("dice")
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { AgentEntryGlassTile() }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(lotteryStepIndex.map { "选择 \(lotterySteps[$0].left)" } ?? "拈签定缘，随机抽一个旅行灵感")
        // 两个入口等宽，略高于正方形。
        .frame(maxWidth: .infinity)
        .aspectRatio(entryTileAspectRatio, contentMode: .fit)
        // 光晕背景必须放在最终尺寸修饰符（aspectRatio）之后：这样背景拿到
        // 的尺寸提案才是方块的最终大小；放在之前会拿到贪婪未定形的尺寸，
        // 内部裁剪框随之外扩，光晕就溢出按钮了。进入抽签流程后光晕消失。
        .background {
            if lotteryStepIndex == nil { lotteryGlow }
        }
    }

    /// 右侧方块：默认是输入入口（含添加图片控件），点按展开为完整输入条；
    /// 抽签流程中是当前问题的右选项。
    private var rightEntrySquare: some View {
        Group {
            if let index = lotteryStepIndex {
                Button {
                    answerLottery(value: lotterySteps[index].right)
                } label: {
                    ZStack {
                        lotteryChoiceLabel(lotterySteps[index].right)
                            .id("lottery-right-\(index)")
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { AgentEntryGlassTile() }
                }
                .buttonStyle(.plain)
            } else {
                // 输入入口：与左侧同款的玻璃方块，上方大号白字引导、底部灰色
                // 小字循环滚动目的地灵感；折叠态不显示「+」控件（易被误解为
                // 添加入口），展开输入条后再添加图片。背景与展开态 TextField
                // 共享 matchedGeometryEffect，点按后连续变形为完整输入条。
                ZStack {
                    AgentEntryGlassTile()
                        .matchedGeometryEffect(id: "composer-field", in: composerMotion)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("告诉\nAgent\n你的想法")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineSpacing(4)
                        Spacer(minLength: 0)
                        suggestionRoller
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(20)
                    // 右上角 ↗ 箭头（SF Symbol arrow.up.right）：提示点按后
                    // 会展开为输入条。
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(14)
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { expandComposer() }
            }
        }
        .accessibilityLabel(lotteryStepIndex.map { "选择 \(lotterySteps[$0].right)" } ?? "展开输入框")
        // 两个入口等宽，略高于正方形。
        .frame(maxWidth: .infinity)
        .aspectRatio(entryTileAspectRatio, contentMode: .fit)
    }

    /// 「+」添加图片控件：折叠方块与展开输入条共用，随布局切换连续移动。
    private var addPhotoButton: some View {
        PhotosPicker(selection: $photo, matching: .images) {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(PrimaryTabPalette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: photo) { _, item in load(item) }
        .accessibilityLabel("添加攻略图片")
        .matchedGeometryEffect(id: "composer-plus", in: composerMotion)
    }

    private func lotteryChoiceLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
    }

    /// 「拈签定缘」入口的弥散光晕：多个远大于方块的暖色（橙-琥珀-珊瑚）
    /// 光斑重度弥散、彼此交叠，合成一整片缓慢流动的暖光场，亮度中心各自
    /// 沿李萨如曲线游走、路径不重复；色相在暖色窄区间内漂移。整体裁剪在
    /// 方块圆角内，不会溢出按钮。不参与命中测试，纯视觉提示可点按抽签。
    private var lotteryGlow: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                // 静态底色：淡暖色角向渐变兜底，保证光场始终铺满方块。
                AngularGradient(colors: Self.glowColors, center: .center)
                    .opacity(0.2)
                glowBlob(diameter: 260, ampX: 30, freqX: 0.6, ampY: 36, freqY: 0.42, phase: 0, hueShift: 0, t: t)
                glowBlob(diameter: 320, ampX: 40, freqX: 0.35, ampY: 26, freqY: 0.53, phase: 2.1, hueShift: 12, t: t)
                glowBlob(diameter: 200, ampX: 24, freqX: 0.71, ampY: 42, freqY: 0.3, phase: 4.2, hueShift: -8, t: t)
            }
            // 弹性 frame 把布局尺寸（也是裁剪区域）锁定为背景提案的方块
            // 大小——否则远大于方块的光斑会把 ZStack 撑大，裁剪框随之外扩，
            // 光晕就溢出按钮了。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    /// 单个游走光斑：直径远大于方块本身，重度模糊 + 长径向衰减，只呈现为
    /// 大范围弥散的亮度起伏而非独立圆点；按李萨如轨迹偏移游走。
    private func glowBlob(
        diameter: CGFloat,
        ampX: CGFloat,
        freqX: Double,
        ampY: CGFloat,
        freqY: Double,
        phase: Double,
        hueShift: Double,
        t: Double
    ) -> some View {
        Circle()
            .fill(AngularGradient(colors: Self.glowColors, center: .center))
            .frame(width: diameter, height: diameter)
            .scaleEffect(1 + 0.07 * sin(t * 0.9 + phase))
            .hueRotation(.degrees(hueShift + 18 * sin(t * 0.21 + phase)))
            .blur(radius: diameter * 0.45)
            .mask(
                Circle().fill(
                    RadialGradient(
                        colors: [.white, .clear],
                        center: .center,
                        startRadius: diameter * 0.15,
                        endRadius: diameter * 0.5
                    )
                )
            )
            .opacity(0.55)
            .offset(x: ampX * sin(t * freqX + phase), y: ampY * sin(t * freqY + phase * 1.7))
    }

    /// 光晕的循环色环（首尾同色保证角向渐变无缝）：全部取橙色的暖色近邻，
    /// 避免与主题橙形成过强对比。
    private static let glowColors: [Color] = [
        PrimaryTabPalette.accent,
        Color(red: 1, green: 170 / 255, blue: 70 / 255),
        Color(red: 1, green: 120 / 255, blue: 95 / 255),
        Color(red: 1, green: 195 / 255, blue: 120 / 255),
        PrimaryTabPalette.accent
    ]

    /// 底部灵感滚动条：定位图标固定不动，目的地小字和国旗一起像翻牌一样
    /// 向上滚动（每 1.8 秒切换一次）；旧文案向上滑出淡去、新文案自下滑入，
    /// 超出区域被裁剪。
    private var suggestionRoller: some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.footnote.weight(.semibold))
            ZStack(alignment: .bottomLeading) {
                let entry = inspirationSuggestions[inspirationIndex % inspirationSuggestions.count]
                HStack(spacing: 4) {
                    Text(entry.name)
                        .font(.footnote.weight(.medium))
                    Text(entry.flag)
                }
                .id(inspirationIndex)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
            }
            .clipped()
        }
        .foregroundStyle(PrimaryTabPalette.secondaryText)
        .task {
            // 循环滚动；方块被展开输入条替换或进入抽签流程时，task 随视图
            // 生命周期自动取消，收回后从当前灵感继续。
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.8))
                guard !Task.isCancelled else { break }
                withAnimation(.easeInOut(duration: 0.35)) { inspirationIndex += 1 }
            }
        }
    }

    private func expandComposer() {
        withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = true }
        // 等展开后的布局提交再弹键盘，避免焦点在视图切换瞬间被丢弃。
        DispatchQueue.main.async { isComposerFocused = true }
    }

    /// 手动收起输入条：收回键盘并返回双方块入口，已输入的草稿文本保留。
    private func collapseComposer() {
        isComposerFocused = false
        withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = false }
    }

    /// 「拈签定缘」：进入抽签追问流程，逐步收窄范围后把所有选择交给 Agent。
    private func drawLot() {
        lotteryAnswers = []
        withAnimation(.easeInOut(duration: 0.3)) { lotteryStepIndex = 0 }
    }

    /// 抽签流程返回上一步：撤销上一次选择；已在第一问时退出整个流程。
    private func backLottery() {
        guard let index = lotteryStepIndex else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            if index > 0 {
                lotteryStepIndex = index - 1
                if !lotteryAnswers.isEmpty { lotteryAnswers.removeLast() }
            } else {
                lotteryStepIndex = nil
                lotteryAnswers = []
            }
        }
    }

    /// 记录当前问题的选择并推进；回答完最后一问后自动把上下文发给 Agent。
    private func answerLottery(value: String) {
        guard let index = lotteryStepIndex else { return }
        lotteryAnswers.append((lotterySteps[index].key, value))
        if index + 1 < lotterySteps.count {
            withAnimation(.easeInOut(duration: 0.3)) { lotteryStepIndex = index + 1 }
        } else {
            finishLottery()
        }
    }

    /// 跳过当前问题：不记录选择，直接进入下一问；在最后一问跳过则直接抽签。
    private func skipLottery() {
        guard let index = lotteryStepIndex else { return }
        if index + 1 < lotterySteps.count {
            withAnimation(.easeInOut(duration: 0.3)) { lotteryStepIndex = index + 1 }
        } else {
            finishLottery()
        }
    }

    /// 结束抽签流程（回答完最后一问，或在最后一问点「跳过」）：把已收集的选择
    /// 作为上下文组成一条消息直接发给 Agent 对话接口，并恢复默认双方块入口。
    private func finishLottery() {
        let answers = lotteryAnswers
        withAnimation(.easeInOut(duration: 0.3)) {
            lotteryStepIndex = nil
            lotteryAnswers = []
        }
        let context = answers.map { "\($0.key)「\($0.value)」" }.joined(separator: "，")
        message = context.isEmpty
            ? "我在玩「拈签定缘」：请完全随机帮我定一个目的地，规划一次说走就走的旅行。"
            : "我在玩「拈签定缘」：已选择\(context)。请据此随机帮我定一个目的地并直接规划行程。"
        send()
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !runState.isGenerating
    }

    private func consumeInitialMessageIfNeeded() {
        guard !didConsumeInitialMessage,
              message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let initialMessage,
              !initialMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        didConsumeInitialMessage = true
        message = initialMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        expandComposer()
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("conversation-bottom", anchor: .bottom) }
            } else {
                proxy.scrollTo("conversation-bottom", anchor: .bottom)
            }
        }
    }

    private func clearSession() {
        store.discardTurn()
        runState.clearTransientState()
        store.clear()
    }

    /// 会话页返回：归档当前对话（可在「历史对话」恢复）并完全复位到首页
    /// 初始状态——双方块入口重现、草稿清空、键盘收起。
    private func exitConversation() {
        startNewConversation()
        message = ""
        isComposerFocused = false
        isComposerExpanded = false
    }

    /// 归档当前对话（可从「历史」恢复）并开启一个全新的本地会话。
    private func startNewConversation() {
        runState.clearTransientState()
        store.startNewSession()
    }

    private func cancelGeneration() {
        runState.cancelGeneration()
        store.discardTurn()
    }

    private func load(_ item: PhotosPickerItem?) {
        guard let item else { return }
        // 服务端每轮最多接受 3 张附件；超出会在整轮校验时 400，提前拦截。
        guard store.session.attachments.count < 3 else {
            photo = nil
            runState.error = "每轮最多附带 3 张图片，请先清除对话与草稿后再添加。"
            return
        }
        Task {
            defer { photo = nil }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw AgentImageAttachmentError.unreadable
                }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try AgentImageAttachmentProcessor.prepare(data)
                }.value
                store.addAttachment(.init(
                    id: UUID(),
                    mediaType: prepared.mediaType,
                    dataURI: prepared.dataURI
                ))
                // 折叠态下从「+」添加图片后直接展开输入条，便于继续输入说明文字。
                withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = true }
            } catch {
                runState.error = error.localizedDescription
            }
        }
    }

    private func send() {
        guard let request = makeRequest() else { runState.error = "请先完成旅行设置。"; return }
        // plan_new（无生效旅程或「暂不选择行程」）时 tripID 为 nil，服务端不强制本接口的旅程鉴权。
        let tripID = syncEngine.trip?.id
        let userMessage = AgentV2TurnRequest.Message(id: UUID(), role: "user", content: message, createdAt: .now)
        store.beginTurn()
        store.append(userMessage)
        acknowledgeInitialMessageSubmissionIfNeeded(userMessage.content)
        message = ""
        runState.prepareForTurn()
        isComposerFocused = false
        let state = runState
        let sessionStore = store
        let client = APIClient()
        let generationID = runState.beginGeneration()
        let task = Task {
            do {
                let stream = try await client.agentV2Stream(request, tripID: tripID)
                for try await event in stream {
                    switch event {
                    case .status(let text): state.status = text
                    case .reasoningSummary(let text): state.reasoningSummary += text
                    case .assistantDelta(let text):
                        state.status = nil
                        state.streamingReply += text
                    case .cardBegin(let id, let index):
                        if !state.liveCards.contains(where: { $0.id == id }) { state.liveCards.append(.init(id: id, index: index)) }
                    case .cardFieldDelta(let id, let field, let value):
                        guard let index = state.liveCards.firstIndex(where: { $0.id == id }) else { break }
                        state.liveCards[index].fields[field] = value
                    case .question(let text): sessionStore.append(.init(id: UUID(), role: "assistant", content: text, createdAt: .now))
                    case .summary(let summary):
                        state.stagedSummaryText = summary.text
                        sessionStore.apply(event)
                    case .candidateUpsert:
                        sessionStore.apply(event)
                    case .fliggySearchStarted(let start):
                        state.fliggySearchStarted(start)
                    case .fliggySearchCompleted(let completion):
                        state.fliggySearchCompleted(completion)
                    case .done:
                        let completedReply = state.streamingReply.isEmpty ? state.stagedSummaryText : state.streamingReply
                        if !completedReply.isEmpty {
                            sessionStore.append(.init(id: UUID(), role: "assistant", content: completedReply, createdAt: .now))
                            state.streamingReply = ""
                        }
                        sessionStore.completeTurn()
                        state.liveCards = []
                    default: sessionStore.apply(event)
                    }
                }
            } catch is CancellationError {
                // The persisted draft, input context and attachments remain retryable.
            } catch {
                state.error = error.localizedDescription
            }
            sessionStore.discardTurn()
            state.liveCards = []
            state.stagedSummaryText = ""
            state.finishGeneration(id: generationID)
        }
        runState.attach(task, id: generationID)
    }

    private func acknowledgeInitialMessageSubmissionIfNeeded(_ submittedMessage: String) {
        guard !didSubmitInitialMessage,
              let initialURL = initialMessage?
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .first(where: { $0.hasPrefix("https://") }),
              submittedMessage.contains(initialURL) else { return }
        didSubmitInitialMessage = true
        onInitialMessageSubmitted?()
    }

    private func makeRequest() -> AgentV2TurnRequest? {
        guard let trip = syncEngine.trip, trip.isConfigured else {
            // 无生效旅程：从零规划模式（plan_new）。服务端会产出待用户确认的
            // 旅程提案（trip_proposal），确认前不落库创建旅程。
            return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "plan_new", message: message, trip: nil, preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
        }
        let days = trip.days.map { day in
            AgentV2TurnRequest.Day(date: day.date, cards: day.cards.map { card in
                AgentV2TurnRequest.Card(id: card.serverID, kind: card.kind.rawValue, title: card.title, startAt: ISO8601DateFormatter().string(from: card.startAt), endAt: card.endAt.map { ISO8601DateFormatter().string(from: $0) }, place: card.place?.name, notes: card.notes)
            })
        }
        return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "itinerary", message: message, trip: .init(destination: trip.destination, startDate: trip.startDate, endDate: trip.endDate, currency: trip.currency, timeZone: TimeZone.current.identifier, version: trip.version, days: days), preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
    }

    /// 用户确认旅程提案：复用既有建旅程链路创建旅程，随后清除提案。
    /// 候选不自动写入——创建成功后仍由用户在下方的草稿区选择并确认加入行程。
    private func confirmTripProposal(_ proposal: AgentV2TripProposal) {
        guard !isCreatingTripFromProposal else { return }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: proposal.startDate),
              let endDate = formatter.date(from: proposal.endDate) else {
            runState.error = "旅程提案的日期无法识别，请让 Agent 重新生成提案。"
            return
        }
        isCreatingTripFromProposal = true
        Task {
            await syncEngine.createTrip(destination: proposal.destination, startDate: startDate, endDate: endDate, currency: proposal.currency)
            if syncEngine.trip != nil {
                store.clearPendingProposal()
            } else {
                runState.error = "旅程创建失败，请稍后重试。"
            }
            isCreatingTripFromProposal = false
        }
    }

    private func commit() {
        guard let trip = syncEngine.trip else { return }
        // Obtain draft and selected IDs atomically from the current published
        // session. The button's `draft`/`selected` values belong to an earlier
        // SwiftUI render and can be stale after a streaming turn completes.
        guard let snapshot = store.commitSnapshot() else {
            runState.error = "当前没有可确认的候选，请重新选择后确认。"
            return
        }
        guard snapshot.selected.allSatisfy(\.isCommitReady) else {
            runState.error = "选中的候选仍在生成或缺少必要时间信息，请稍后再确认。"
            return
        }

        runState.isCommitting = true
        let client = APIClient()
        Task {
            do {
                _ = try await client.commitAgentV2(
                    .init(
                        sessionId: store.session.id,
                        expectedTripVersion: trip.version,
                        timeZone: TimeZone.current.identifier,
                        selectedCandidateIds: snapshot.selected.map(\.id),
                        draft: snapshot.draft
                    ),
                    tripID: trip.id,
                    idempotencyKey: UUID()
                )
                store.clearCommittedDraft()
                await syncEngine.refresh()
            } catch {
                runState.error = error.localizedDescription
            }
            runState.isCommitting = false
        }
    }
}

/// 底部两个入口方块的玻璃底：复刻主界面悬浮导航栏（ContentView）的材质
/// 配方——0.1 强度的暗色背景模糊、深色薄纱、0.6 白描边与轻投影。
private struct AgentEntryGlassTile: View {
    var body: some View {
        ZStack {
            AdjustableBackdropBlur(style: .systemUltraThinMaterialDark, intensity: 0.1)
            Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255)
                .opacity(0.16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
        }
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
            radius: 12,
            y: 12
        )
    }
}

/// 景点名后的小国旗（18×12pt）：用色条、圆点、十字、星、月牙等基本图形
/// 极简渲染各目的地对应的国家旗帜（不用 emoji 字符，随系统主题渲染）。
private struct MiniFlag: View {
    enum Country {
        case indonesia, kenya, japan, iceland, greece, thailand, newZealand,
             morocco, switzerland, norway, turkey, peru, algeria, china, palau, italy
    }

    let country: Country

    private let size = CGSize(width: 18, height: 12)

    var body: some View {
        ZStack {
            switch country {
            case .indonesia:
                hStripes([Color(hex: 0xE11B22), .white])
            case .kenya:
                hStripes([.black, Color(hex: 0xB61D28), Color(hex: 0x006633)])
            case .japan:
                base(.white)
                disc(Color(hex: 0xBC002D), diameter: size.height * 0.55)
            case .iceland:
                base(Color(hex: 0x02529C))
                cross(.white, thickness: size.height * 0.3)
                cross(Color(hex: 0xDC1E35), thickness: size.height * 0.16)
            case .greece:
                // 简化为蓝白条带；18pt 宽画不下左上角十字州徽。
                hStripes([Color(hex: 0x0D5EAF), .white, Color(hex: 0x0D5EAF), .white, Color(hex: 0x0D5EAF)])
            case .thailand:
                hStripes([Color(hex: 0xA51931), .white, Color(hex: 0x2D2A4A), .white, Color(hex: 0xA51931)])
            case .newZealand:
                base(Color(hex: 0x012169))
                star(.white)
            case .morocco:
                base(Color(hex: 0xC1272D))
                star(Color(hex: 0x006233))
            case .switzerland:
                base(Color(hex: 0xDA291C))
                cross(.white, thickness: size.height * 0.28)
            case .norway:
                base(Color(hex: 0xBA0C2F))
                cross(.white, thickness: size.height * 0.32)
                cross(Color(hex: 0x00205B), thickness: size.height * 0.16)
            case .turkey:
                base(Color(hex: 0xE30A17))
                crescent(.white, on: Color(hex: 0xE30A17))
                star(.white, offset: CGSize(width: 4, height: 0))
            case .peru:
                vStripes([Color(hex: 0xD91023), .white, Color(hex: 0xD91023)])
            case .algeria:
                vStripes([Color(hex: 0x006233), .white])
                crescent(Color(hex: 0xD21034), on: .white, offset: CGSize(width: 2, height: 0))
            case .china:
                base(Color(hex: 0xDE2910))
                star(Color(hex: 0xFFDE00))
            case .palau:
                base(Color(hex: 0x4AADD6))
                disc(Color(hex: 0xF5D418), diameter: size.height * 0.5, offset: CGSize(width: -size.width * 0.14, height: 0))
            case .italy:
                vStripes([Color(hex: 0x009246), .white, Color(hex: 0xCE2B37)])
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(.white.opacity(0.22), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
    }

    private func base(_ color: Color) -> some View {
        Rectangle().fill(color)
    }

    private func hStripes(_ colors: [Color]) -> some View {
        VStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { index in
                Rectangle().fill(colors[index])
            }
        }
    }

    private func vStripes(_ colors: [Color]) -> some View {
        HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { index in
                Rectangle().fill(colors[index])
            }
        }
    }

    private func disc(_ color: Color, diameter: CGFloat, offset: CGSize = .zero) -> some View {
        Circle().fill(color)
            .frame(width: diameter, height: diameter)
            .offset(x: offset.width, y: offset.height)
    }

    private func cross(_ color: Color, thickness: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(color).frame(height: thickness)
            Rectangle().fill(color).frame(width: thickness * 1.2)
        }
    }

    private func star(_ color: Color, offset: CGSize = .zero) -> some View {
        Image(systemName: "star.fill")
            .font(.system(size: 6))
            .foregroundStyle(color)
            .offset(x: offset.width, y: offset.height)
    }

    /// 月牙：实心圆叠一枚底色圆错位而成（国旗过小，省略伴星）。
    private func crescent(_ color: Color, on background: Color, offset: CGSize = .zero) -> some View {
        ZStack {
            Circle().fill(color).frame(width: 7, height: 7)
            Circle().fill(background).frame(width: 6, height: 6).offset(x: 1.5)
        }
        .offset(x: offset.width, y: offset.height)
    }
}

/// 历史对话列表：展示「新建对话」归档的本地会话，点按恢复、左滑删除。
/// 全部使用原生控件（List / swipeActions / ContentUnavailableView）。
private struct AgentHistorySheet: View {
    @ObservedObject var store: AgentV2SessionStore
    /// Called after a conversation is restored so the workbench can drop any
    /// in-flight generation UI for the previous conversation.
    let onRestore: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.archives.isEmpty {
                    ContentUnavailableView(
                        "暂无历史对话",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("点击「新建对话」后，当前对话会自动保存在这里。")
                    )
                } else {
                    List {
                        ForEach(store.archives) { archived in
                            Button {
                                store.restoreSession(id: archived.id)
                                onRestore()
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(title(for: archived))
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(archived.updatedAt, style: .relative)
                                        Text("· \(archived.messages.count) 条消息")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    store.deleteArchivedSession(id: archived.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                            .accessibilityLabel("恢复对话：\(title(for: archived))")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("历史对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    /// First user message as the conversation title, falling back to the
    /// assistant's opening or a placeholder.
    private func title(for session: AgentV2LocalSession) -> String {
        let text = session.messages.first(where: { $0.role == "user" })?.content
            ?? session.messages.first?.content
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未命名对话" : String(trimmed.prefix(40))
    }
}

private struct ChatMessageView: View {
    let message: AgentV2TurnRequest.Message
    /// 是否在这条助手消息旁显示橘色头像（每个助手回合只显示一次）。
    var showsAvatar: Bool = true

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 54)
                Text(message.content)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            }
        } else {
            AssistantMessageContainer(showsAvatar: showsAvatar) {
                Text(message.content)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct AssistantMessageContainer<Content: View>: View {
    @ViewBuilder let content: Content
    let showsAvatar: Bool

    init(showsAvatar: Bool = true, @ViewBuilder content: () -> Content) {
        self.showsAvatar = showsAvatar
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsAvatar {
                ZStack {
                    Circle().fill(PrimaryTabPalette.accent.gradient).frame(width: 28, height: 28)
                    Image(systemName: "sparkles").font(.caption2.weight(.bold)).foregroundStyle(.white)
                }
            } else {
                // 占位对齐：不显示头像时内容仍与其他助手区块左对齐。
                Color.clear.frame(width: 28, height: 28)
            }
            content
                .padding(.top, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Branded progress chip for Fliggy realtime-search tool calls. Renders in
/// the same status area as the plain text status line; pure UI progress that
/// never persists anywhere.
private struct FliggySearchStatusChip: View {
    let progress: AgentV2FliggyProgress

    var body: some View {
        HStack(spacing: 8) {
            switch progress.phase {
            case .running:
                HStack(spacing: 6) {
                    Image(systemName: "airplane")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(PrimaryTabPalette.accent, in: Capsule())
            case .completed(let ok, _):
                Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ok ? .green : .orange)
            }
            Text(displayText)
                .font(.footnote)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(1)
        }
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(displayText)
    }

    private var displayText: String {
        switch progress.phase {
        case .running:
            let title = progress.kind.progressTitle
            guard let term = progress.term, !term.isEmpty else { return title }
            return "\(title) · \(term)"
        case .completed(let ok, let count):
            if ok, let count {
                return "飞猪已返回 \(count) 个结果"
            }
            return "飞猪实时数据暂不可用，已用其他来源继续"
        }
    }
}

private struct LiveCandidateCard: View {
    let card: AgentV2LiveCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(card.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                Spacer()
                ProgressView().controlSize(.mini).tint(PrimaryTabPalette.secondaryText)
            }
            if !card.timing.isEmpty { Label(card.timing, systemImage: "clock").font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText) }
            if let place = card.place { Label(place, systemImage: "mappin.and.ellipse").font(.caption).foregroundStyle(.white.opacity(0.85)) }
            if let reason = card.reason { Text(reason).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText) }
            Text("地点验证中").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
        .padding(12)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
    }
}

private struct AgentV2CandidateCard: View {
    let candidate: AgentV2Candidate
    let selection: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { if candidate.isCommitReady { selection(!candidate.selected) } } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: candidate.selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(candidate.selected ? PrimaryTabPalette.accent : PrimaryTabPalette.tertiaryText)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Label(candidate.kind.agentTitle, systemImage: candidate.kind.agentSymbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimaryTabPalette.accent)
                            Spacer()
                            Text(candidate.startAt).font(.caption.monospacedDigit()).foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        Text(candidate.title).font(.headline).foregroundStyle(.white)
                        Text(candidate.date + (candidate.place.map { " · \($0.name)" } ?? ""))
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.85))
                        if let address = candidate.place?.address, !address.isEmpty {
                            Text(address).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        if let reason = candidate.reason {
                            Text(reason).font(.footnote).foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                        if !candidate.risks.isEmpty {
                            Label(candidate.risks.joined(separator: "、"), systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        HStack(spacing: 5) {
                            Image(systemName: candidate.placeStatus == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            Text(candidate.placeStatus.title)
                        }
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(candidate.placeStatus == .verified ? .green : .orange)
                        if let priceText {
                            Label(priceText, systemImage: isRealtimePrice ? "clock.arrow.circlepath" : "banknote")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityValue(candidate.selected ? "已选择" : "未选择")
            .accessibilityHint(candidate.isCommitReady ? "轻点切换选择" : "信息完整后才可选择")

            if let xiaohongshuURL {
                Link(destination: xiaohongshuURL) {
                    Label("小红书来源 · 打开原笔记", systemImage: "arrow.up.right.square")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                }
                .padding(.leading, 34)
            }

            if let fliggyBookingURL {
                // Fliggy candidates carry a real booking URL. The exact price
                // lives behind the link (or degrades to a “实时价” placeholder),
                // so send the user to Safari rather than inventing a number.
                Link(destination: fliggyBookingURL) {
                    HStack(spacing: 5) {
                        Image(systemName: "airplane")
                        Text("查看预订")
                        Image(systemName: "arrow.up.right")
                            .font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(PrimaryTabPalette.accent, in: Capsule())
                }
                .padding(.leading, 34)
                .accessibilityLabel("在飞猪查看预订")
            }
        }
        .padding(13)
        .background(candidate.selected ? PrimaryTabPalette.accent.opacity(0.14) : PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(candidate.selected ? PrimaryTabPalette.accent.opacity(0.5) : Color.white.opacity(0.035), lineWidth: 1)
        }
        .opacity(candidate.isCommitReady ? 1 : 0.72)
    }

    private var xiaohongshuURL: URL? {
        guard let value = candidate.url,
              let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "xiaohongshu.com" || host.hasSuffix(".xiaohongshu.com") ||
              host == "xhslink.com" || host.hasSuffix(".xhslink.com") else { return nil }
        return url
    }

    /// Fliggy realtime candidates link to a real booking page rather than a
    /// note; only trust the known Fliggy hosts so arbitrary model URLs never
    /// render as a branded booking button.
    private var fliggyBookingURL: URL? {
        guard let value = candidate.url,
              let url = URL(string: value),
              let host = url.host?.lowercased(),
              host == "fliggy.com" || host.hasSuffix(".fliggy.com") ||
              host == "alitrip.com" || host.hasSuffix(".alitrip.com") else { return nil }
        return url
    }

    /// Price line: a concrete minor-unit amount when present, otherwise a
    /// “实时价” placeholder exactly when the server flagged that the live
    /// price lives behind the booking link. Never fabricates a number.
    private var priceText: String? {
        if let priceMinor = candidate.priceMinor {
            let major = Double(priceMinor) / 100
            let amount = major.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", major)
                : String(format: "%.2f", major)
            return "¥\(amount)"
        }
        if candidate.notes?.contains("实时价格见预订链接") == true { return "实时价" }
        return nil
    }

    private var isRealtimePrice: Bool {
        candidate.priceMinor == nil && priceText != nil
    }
}

private struct AgentContextSheet: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var store: AgentV2SessionStore
    @Environment(\.dismiss) private var dismiss

    private let interests = ["美食", "文化", "自然", "购物", "拍照", "夜生活"]

    var body: some View {
        NavigationStack {
            Form {
                Section("本次旅行") {
                    if let trip = syncEngine.trip, trip.isConfigured {
                        LabeledContent("目的地", value: trip.destination ?? "待设置")
                        LabeledContent("日期", value: "\(trip.startDate ?? "") – \(trip.endDate ?? "")")
                        LabeledContent("时区", value: TimeZone.current.identifier)
                    } else {
                        ContentUnavailableView("请先完成旅行设置", systemImage: "calendar.badge.exclamationmark", description: Text("Agent 需要目的地、日期和币种来检查地点与冲突。"))
                    }
                }

                Section("规划条件") {
                    Picker("节奏", selection: binding(\.pace)) {
                        Text("未设置").tag(""); Text("轻松").tag("relaxed"); Text("均衡").tag("balanced"); Text("特种兵").tag("packed")
                    }
                    Picker("同行人", selection: binding(\.companions)) {
                        Text("未设置").tag(""); Text("独自").tag("solo"); Text("情侣").tag("couple"); Text("带父母").tag("parents"); Text("带儿童").tag("children")
                    }
                    Picker("预算", selection: binding(\.budget)) {
                        Text("未设置").tag(""); Text("省钱").tag("value"); Text("适中").tag("balanced"); Text("品质优先").tag("premium")
                    }
                    TextField("本轮范围，例如第二天下午", text: binding(\.scope))
                }

                Section {
                    Toggle("保留未验证的模型推荐", isOn: allowUnverifiedRecommendationsBinding)
                } header: {
                    Text("地图点位")
                } footer: {
                    Text("开启后，Apple Maps 未命中的模型推荐仍会作为“地点待确认”候选，由你决定是否添加；不会伪造坐标。你原文明确写出的地点始终保留。")
                }

                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(interests, id: \.self) { interest in
                            Button { toggleInterest(interest) } label: {
                                HStack(spacing: 5) {
                                    if store.session.preferences.interests.contains(interest) { Image(systemName: "checkmark") }
                                    Text(interest)
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(store.session.preferences.interests.contains(interest) ? .white : PrimaryTabPalette.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(store.session.preferences.interests.contains(interest) ? PrimaryTabPalette.accent : PrimaryTabPalette.elevatedSurface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("偏好")
                } footer: {
                    Text("条件会保存在本机，并作为每轮对话的规划前提。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(PrimaryTabPalette.background)
            .tint(PrimaryTabPalette.accent)
            .preferredColorScheme(.dark)
            .navigationTitle("旅行与偏好")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<AgentV2TurnRequest.Preferences, String?>) -> Binding<String> {
        Binding(
            get: { store.session.preferences[keyPath: keyPath] ?? "" },
            set: { value in store.updatePreference(keyPath, value: value.isEmpty ? nil : value) }
        )
    }

    private var allowUnverifiedRecommendationsBinding: Binding<Bool> {
        Binding(
            get: { store.session.preferences.retainsUnverifiedRecommendations },
            set: { store.setAllowUnverifiedRecommendations($0) }
        )
    }

    private func toggleInterest(_ interest: String) {
        store.toggleInterest(interest)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: ProposedViewSize(width: bounds.width, height: proposal.height), subviews: subviews)
        for (index, point) in result.points.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var points: [CGPoint] = []

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight), points)
    }
}

private extension AgentV2Candidate.PlaceStatus {
    var title: String {
        switch self {
        case .verified: "地点已验证"
        case .pending: "地点验证中"
        case .failed: "地点待确认"
        case .notRequired: "无需地点"
        }
    }
}

private extension AgentV2Change {
    var operationTitle: String {
        switch operation {
        case .add: "新增"
        // 区分作用于已确认行程卡片与仅作用于未确认草稿候选的操作，
        // 避免“替换/移除”让用户误以为已确认的行程被改动。
        case .replace: targetDraftId != nil ? "更新候选" : "替换行程"
        case .remove: targetDraftId != nil ? "移除候选" : "移除行程"
        case .move: "移动"
        case .keep: "保留"
        }
    }
}

private extension AgentV2Change.Operation {
    var symbol: String {
        switch self {
        case .add: "plus.circle.fill"
        case .replace: "arrow.triangle.2.circlepath.circle.fill"
        case .remove: "minus.circle.fill"
        case .move: "arrow.up.arrow.down.circle.fill"
        case .keep: "pin.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .add: .green
        case .replace, .move: .orange
        case .remove: .red
        case .keep: PrimaryTabPalette.accent
        }
    }
}

private extension TravelCardSnapshot.Kind {
    var agentTitle: String {
        switch self {
        case .activity: "活动"
        case .hotel: "酒店"
        case .flight: "航班"
        }
    }

    var agentSymbol: String {
        switch self {
        case .activity: "figure.walk"
        case .hotel: "bed.double.fill"
        case .flight: "airplane"
        }
    }
}
