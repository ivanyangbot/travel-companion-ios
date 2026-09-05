import AuthenticationServices
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

/// 首页正在展示 AgentHomeView（无生效行程的欢迎页）时向上声明；
/// ContentView 读取后隐藏悬浮 tab 栏右侧的 Agent 入口按钮——当前页面
/// 本身就是 Agent，再放一个入口是重复的。
struct AgentHomeActiveKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = nextValue() || value
    }
}

/// 同一套 Agent 交互在首页与悬浮弹窗中的展示方式。两者共享完整的对话、
/// 地球变形和弹窗状态机，只在欢迎态的入口内容上有所区别。
enum AgentHomePresentation {
    case home
    case workbench
}

/// 首页（无生效行程时）内嵌的 Agent 页：从 AgentWorkbenchView 复制而来，
/// 供首页场景独立调整，与 Agent 主页面互不影响。草稿同样保持在本地，
/// 用户明确选择并确认后才写入行程。
struct AgentHomeView: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var appleSignIn: AppleSignInStore
    let initialMessage: String?
    let onInitialMessageSubmitted: (() -> Void)?
    let plansNewTrip: Bool
    let onCancelNewTripPlanning: (() -> Void)?
    let onNewTripCreated: (() -> Void)?
    let presentation: AgentHomePresentation
    @EnvironmentObject private var store: AgentV2SessionStore
    @EnvironmentObject private var runState: AgentV2RunState
    /// 工作台模式下指向承载本视图的 sheet：清除行程选择后用它关掉整个工作台。
    /// 首页内嵌（.home）模式下不存在宿主 sheet，不会被调用。
    @Environment(\.dismiss) private var dismissWorkbench
    @FocusState private var isComposerFocused: Bool
    @State private var message = ""
    @State private var isShowingPhotoPicker = false
    @State private var photoPickerSelection: [PhotosPickerItem] = []
    @State private var isShowingCameraPicker = false
    @State private var isShowingDocumentPicker = false
    @State private var isProcessingAttachment = false
    @State private var isShowingContext = false
    @State private var isShowingHistory = false
    @State private var isShowingSignIn = false
    @State private var isShowingTripPicker = false
    @State private var isShowingTripSharing = false
    @State private var isShowingSettings = false
    /// The shared map-style menu expects the inverse “content expanded” state:
    /// true means the drawer is closed, false means its actions are revealed.
    @State private var isHomeMenuCollapsed = true
    @State private var activeHomeQuickAction: TodayQuickAction?
    @State private var isReloadingHome = false
    /// 工作台内「新建一段旅行」：清空当前行程后，等 picker 收起再关闭工作台，
    /// 让 Today 根视图稳定落到 Agent 首页，而不是短暂闪回地图。
    @State private var closeWorkbenchAfterNewTripPickerDismiss = false
    @State private var didConsumeInitialMessage = false
    @State private var didSubmitInitialMessage = false
    /// Coalesce the many scroll requests produced by a token stream. Without
    /// this, every published fragment queues another main-thread layout pass.
    @State private var streamingScrollTask: Task<Void, Never>?
    @State private var isCreatingTripFromProposal = false
    /// 成功提交后短暂保留候选区，并在页面中央播放确认反馈；动画落稳后再
    /// 清理草稿，避免服务器成功时卡片毫无解释地瞬间消失。
    @State private var commitSuccess: AgentCommitSuccess?
    /// Candidates stay unselected while the agent fills their schedule/place
    /// fields. They only become eligible for import after the repaired upsert
    /// passes the same validation used by commit.
    @State private var repairingCandidateIDs: Set<UUID> = []
    @State private var isReasoningExpanded = false
    /// 悬浮 Agent 欢迎态由服务端按当前行程生成的问题推荐。
    @State private var suggestedPrompts: [String] = []
    @State private var suggestedIcons: [String] = []
    @State private var suggestionsTripID: Int?
    /// 推荐问题逐条揭示；每次只插入一条，保证从左向右移入的阶梯节奏。
    @State private var revealedSuggestionCount = 0
    /// 底部输入区是否已展开：折叠态为左右两个等宽正方形入口，
    /// 点按右侧输入方块后才展开为完整输入条并弹出键盘。
    @State private var isComposerExpanded = false
    /// 附件预览条的实测高度：输入区渐变遮罩按它向上延伸，
    /// 避免写死数值与实际内容对不上。
    @State private var attachmentStripHeight: CGFloat = 0
    /// 输入区附件条两端的连续遮罩强度；由实际滚动距离计算，抵达边缘时
    /// 平滑衰减为零，不做布尔状态的突然切换。
    @State private var attachmentEdgeFade = AgentAttachmentEdgeFade.hidden
    /// 「拈签定缘」抽签流程：nil 表示未在流程中，否则为当前问题的下标。
    @State private var lotteryStepIndex: Int?
    /// 折叠方块与展开输入条之间做连续变形动画（matchedGeometryEffect）的命名空间。
    @Namespace private var composerMotion
    /// 抽签流程中已收集的选择（问题 key → 选项文案），最终作为上下文发给 Agent。
    @State private var lotteryAnswers: [(key: String, value: String)] = []
    /// 「打算旅行多久呢？」滑动条的当前天数（1~30，30 = 30 天以上）。
    @State private var lotteryDurationDays: Double = 5
    /// 「我们有多少预算？」滑动条的当前预算：范围随天数联动（低档
    /// max(¥300, ¥250/天)、高档 max(¥5,000, ¥3,000/天)），天数变化时
    /// 自动夹回新范围。
    @State private var lotteryBudgetAmount: Double = 10_000
    /// 「拈签定缘」的追问序列：逐步收窄范围，最后把所有选择交给 Agent 抽签。
    /// 前两问用双方块二选一作答，后两问（天数/预算）用滑动条作答。
    private let lotterySteps: [LotteryStep] = [
        LotteryStep(question: String(localized: "lottery.narrowQuestion"), key: String(localized: "lottery.key.scope"), kind: .choice(left: String(localized: "lottery.overseas"), right: String(localized: "lottery.domestic"))),
        LotteryStep(question: String(localized: "lottery.paceQuestion"), key: String(localized: "lottery.key.pace"), kind: .choice(left: String(localized: "lottery.slowTravel"), right: String(localized: "lottery.intenseTravel"))),
        LotteryStep(question: String(localized: "lottery.durationQuestion"), key: String(localized: "lottery.key.days"), kind: .duration),
        LotteryStep(question: String(localized: "lottery.budgetQuestion"), key: String(localized: "lottery.key.budget"), kind: .budget)
    ]

    /// 追问的作答形式：二选一方块，或滑动条（天数/预算）。
    enum LotteryStepKind {
        case choice(left: String, right: String)
        case duration
        case budget
    }

    struct LotteryStep {
        let question: String
        let key: String
        let kind: LotteryStepKind
    }
    /// 右侧输入入口底部滚动展示的目的地灵感（附对应国家的国旗 emoji 与
    /// 随包静态背景图的资源名），循环向上翻滚切换。
    private static let inspirationSuggestions: [(name: String, flag: String, image: String)] = [
        (String(localized: "inspiration.bali"), "🇮🇩", "dest-bali"), (String(localized: "inspiration.masaimara"), "🇰🇪", "dest-masai-mara"),
        (String(localized: "inspiration.kyoto"), "🇯🇵", "dest-kyoto"), (String(localized: "inspiration.iceland"), "🇮🇸", "dest-iceland"),
        (String(localized: "inspiration.santorini"), "🇬🇷", "dest-santorini"), (String(localized: "inspiration.chiangmai"), "🇹🇭", "dest-chiangmai"),
        (String(localized: "inspiration.newzealand"), "🇳🇿", "dest-newzealand"), (String(localized: "inspiration.morocco"), "🇲🇦", "dest-morocco"),
        (String(localized: "inspiration.switzerland"), "🇨🇭", "dest-switzerland"), (String(localized: "inspiration.norway"), "🇳🇴", "dest-norway"),
        (String(localized: "inspiration.cappadocia"), "🇹🇷", "dest-cappadocia"), (String(localized: "inspiration.machupicchu"), "🇵🇪", "dest-machupicchu"),
        (String(localized: "inspiration.sahara"), "🇩🇿", "dest-sahara"), (String(localized: "inspiration.hokkaido"), "🇯🇵", "dest-hokkaido"),
        (String(localized: "inspiration.dali"), "🇨🇳", "dest-dali"), (String(localized: "inspiration.kanas"), "🇨🇳", "dest-kanas"),
        (String(localized: "inspiration.palau"), "🇵🇼", "dest-palau"), (String(localized: "inspiration.komodo"), "🇮🇩", "dest-komodo"),
        (String(localized: "inspiration.tuscany"), "🇮🇹", "dest-tuscany"), (String(localized: "inspiration.amalfi"), "🇮🇹", "dest-amalfi")
    ]
    /// 目的地静态背景图（随包 jpg）的加载缓存：`UIImage(named:)` 对非 PNG
    /// 的松散包文件按名查不到（PNG 才可省扩展名），改用 Bundle URL 读入。
    /// UIImage 首次绘制才解码位图，全量持有 20 个引用的常驻内存可忽略。
    private static let destinationArtwork: [String: UIImage] = {
        var images: [String: UIImage] = [:]
        for entry in inspirationSuggestions {
            guard let url = Bundle.main.url(forResource: entry.image, withExtension: "jpg"),
                  let image = UIImage(contentsOfFile: url.path) else { continue }
            images[entry.image] = image
        }
        return images
    }()
    /// 当前滚动到的灵感序号（只增不减，渲染时取模循环）。
    @State private var inspirationIndex = 0
    /// 欢迎标题是否折成两行（抽签第二问文案较长）：按实际渲染高度检测
    /// （与字号/屏宽无关），折行时该文案单独上移约一行行高，把多占的高度
    /// 还给下方与入口方块之间的间距。
    @State private var isWelcomeTitleWrapped = false
    /// 对话页地球是否已「泊入」：用户下滑后顶部地球折叠，由状态行的白色
    /// 思考 icon 接管；上滑回顶后地球恢复常驻顶部。
    @State private var isGlobeDocked = false
    /// 本轮生成内是否发生过「泊入」（下滑，或生成开始时视图已在下方）：
    /// 一旦为真，本轮内上滑只在顶部恢复地球——状态行的思考 icon 不再上移。
    @State private var didDockDuringGeneration = false
    /// 一次泊入飞行（图标从顶部英雄位飞往状态行泊位）的参数快照；非 nil
    /// 时覆盖层正在播飞行动画，落地后由回调清空并把泊位 icon 淡入。
    @State private var dockFlight: AgentGlobeDockFlight?
    /// 英雄位与状态行泊位在页面坐标系（agent-home-page）下的最新矩形，
    /// 泊入瞬间捕获为飞行起终点；仅在生成期间更新，避免平时滚动重渲染。
    @State private var heroFrame: CGRect = .zero
    @State private var orbSlotFrame: CGRect = .zero
    /// 欢迎页大地球与对话页顶部地球/思考 orb 之间做连续变形动画
    /// （matchedGeometryEffect）的命名空间。
    @Namespace private var heroMotion
    /// 地球自转/拖动状态：欢迎页大地球与对话页英雄位共用同一实例，
    /// 沿赤道拖动的相位跨视图连续（变形时旋转不跳变）。
    @State private var globeSpin = AgentGlobeSpin()
    /// 两个入口方块的宽高比（宽/高）：略高于正方形，视觉更稳。
    private let entryTileAspectRatio: CGFloat = 0.88
    /// 对话页常驻地球的直径：发送首条消息后，欢迎页大地球经
    /// matchedGeometryEffect 连续缩小到该尺寸，之后不随对话消失。
    private static let conversationGlobeDiameter: CGFloat = 120
    /// 下滑超过该偏移量后地球泊入状态行 icon 位；滚回该值以内再展开。
    /// 两个阈值之间留出滞回区间，避免在边界反复抖动。
    private static let globeDockOffset: Double = 64
    private static let globeUndockOffset: Double = 12
    /// 对话页顶部下拉（overscroll）露出首页观感的进度：0 = 对话常态，
    /// 1 = 大地球 + 橙色光晕 + ASCII 底纹的完整首页视觉。由下拉距离直接
    /// 驱动（跟手）；拉满后进入锁定态（见 isWelcomePeekLocked），松手
    /// 不再回弹。
    @State private var welcomePeek: Double = 0
    /// 首页观感是否已「锁定」：下拉拉满后保持完整首页视觉（icon 与首页
    /// 初始状态同尺寸），不随松手回弹；上滑（滚动偏移转正并越过阈值）
    /// 才解除并回落回对话常态。
    @State private var isWelcomePeekLocked = false
    /// 拉满首页观感所需的顶部过滚距离（pt）。
    private static let welcomePeekDistance: Double = 90
    /// 对话滚动区的内容宽度（屏幕宽 − 32pt 边距）：计算下拉 peek 的首页
    /// 尺寸目标用（首页地球 = 内容宽 × 0.7、方形区块边长 = 内容宽）。
    @State private var contentWidth: CGFloat = 0
    /// 豆奶工作台滚动区的实时可用高度。Sheet 在 80% 与全屏间切换时，
    /// 欢迎页地球据此同步缩放，给标题、行程卡与建议保留足够空间。
    @State private var workbenchViewportHeight: CGFloat = 0
    /// 锁定态下解除所需的向上滚动偏移（pt）。
    private static let welcomePeekUnlockOffset: Double = 24
    private static let maximumAttachmentCount = 9

    init(
        syncEngine: SyncEngine,
        appleSignIn: AppleSignInStore,
        initialMessage: String? = nil,
        onInitialMessageSubmitted: (() -> Void)? = nil,
        plansNewTrip: Bool = false,
        onCancelNewTripPlanning: (() -> Void)? = nil,
        onNewTripCreated: (() -> Void)? = nil,
        presentation: AgentHomePresentation = .home
    ) {
        self.syncEngine = syncEngine
        self.appleSignIn = appleSignIn
        self.initialMessage = initialMessage
        self.onInitialMessageSubmitted = onInitialMessageSubmitted
        self.plansNewTrip = plansNewTrip
        self.onCancelNewTripPlanning = onCancelNewTripPlanning
        self.onNewTripCreated = onNewTripCreated
        self.presentation = presentation
    }

    var body: some View {
        NavigationStack {
            ZStack {
                PrimaryTabPalette.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    if presentation == .workbench, isWelcomeState {
                        workbenchHeader
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    ZStack {
                        // ASCII 底纹与暗角：欢迎页常驻（延伸到输入区下方，让玻璃
                        // 方块能模糊到底部内容）；对话页顶部下拉（overscroll）时
                        // 按下拉进度淡入，恢复首页观感。
                        AgentIntroASCIIBackgroundView()
                            .ignoresSafeArea(edges: .bottom)
                            .opacity(isWelcomeState ? 1 : welcomePeek)
                        RadialGradient(
                            colors: [.clear, PrimaryTabPalette.background.opacity(0.74)],
                            center: .center,
                            startRadius: 100,
                            endRadius: 330
                        )
                        .allowsHitTesting(false)
                        .ignoresSafeArea(edges: .bottom)
                        .opacity(isWelcomeState ? 1 : welcomePeek)

                        ScrollViewReader { proxy in
                            conversationScroll(proxy: proxy)
                        }
                    }
                }
            }
            .coordinateSpace(name: "agent-home-page")
            // 泊入飞行覆盖层：思考 icon 从顶部英雄位飞往状态行泊位，
            // 落地后交接给泊位里的常驻 icon。
            .overlay {
                if let flight = dockFlight {
                    AgentGlobeDockFlightView(flight: flight) {
                        withAnimation(.snappy(duration: 0.3)) { dockFlight = nil }
                    }
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if let success = commitSuccess {
                    AgentCommitSuccessHUD(success: success)
                        .transition(.scale(scale: 0.78).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                // Agent 首页根欢迎态与地图模式共用下拉菜单。进入输入、抽签、
                // 新建行程子流程或对话后，左上角恢复为有明确返回语义的按钮。
                if showsHomeDropdownMenu {
                    TodayHomeDropdownMenu(
                        isPOIOverlayExpanded: $isHomeMenuCollapsed,
                        activeAction: activeHomeQuickAction,
                        isReloading: isReloadingHome,
                        actions: TodayQuickAction.agentHomeActions(isAuthenticated: appleSignIn.isAuthenticated),
                        onAction: handleHomeQuickAction,
                        onOverlayExpansionChanged: { _ in }
                    )
                    .padding(.leading, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
                } else if showsBackButton {
                    Button {
                        if let onCancelNewTripPlanning,
                           lotteryStepIndex == nil,
                           !isComposerExpanded,
                           isWelcomeState {
                            onCancelNewTripPlanning()
                        } else if lotteryStepIndex != nil {
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
                    .accessibilityLabel(Text("agent.backA11y"))
                }
            }
            .overlay(alignment: .topTrailing) {
                // 未登录的 Agent 首页始终保留一个无需展开菜单即可触达的登录入口。
                if presentation == .home, !appleSignIn.isAuthenticated {
                    Button(action: presentSignIn) {
                        Label("agent.signInButton", systemImage: "person.crop.circle")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(height: 36)
                            .background(PrimaryTabPalette.surface, in: Capsule())
                            .overlay {
                                Capsule()
                                    .stroke(.white.opacity(0.14), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    .accessibilityHint(Text("agent.signInHint"))
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            // 直接使用系统 presentation，而不是把跨进程 Photos 内容嵌进
            // 自定义 overlay。系统由此完整管理半屏、Face ID 重建、触摸命中
            // 与取消/完成按钮，宿主页面也不会再插入一层灰色 SwiftUI sheet。
            .photosPicker(
                isPresented: $isShowingPhotoPicker,
                selection: $photoPickerSelection,
                maxSelectionCount: max(1, remainingAttachmentSlots),
                selectionBehavior: .ordered,
                matching: .images,
                preferredItemEncoding: .current
            )
            .onChange(of: photoPickerSelection) { _, selection in
                guard !selection.isEmpty else { return }
                loadPhotosPickerItems(selection)
                photoPickerSelection = []
            }
            .sheet(isPresented: Binding(
                get: { isShowingTripSharing },
                set: {
                    isShowingTripSharing = $0
                    if !$0 { clearHomeQuickAction(.addCompanion) }
                }
            )) {
                TripSharingSheet(syncEngine: syncEngine)
            }
            .sheet(isPresented: Binding(
                get: { isShowingSettings },
                set: {
                    isShowingSettings = $0
                    if !$0 { clearHomeQuickAction(.settings) }
                }
            )) {
                TodaySettingsSheet(
                    appleSignIn: appleSignIn,
                    onDismiss: { isShowingSettings = false }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(PrimaryTabPalette.background)
                .presentationContentInteraction(.scrolls)
            }
            .sheet(isPresented: Binding(
                get: { isShowingSignIn },
                set: {
                    isShowingSignIn = $0
                    if !$0 { clearHomeQuickAction(.signIn) }
                }
            )) {
                AgentHomeSignInSheet(appleSignIn: appleSignIn)
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingContext) {
                AgentContextSheet(syncEngine: syncEngine, store: store)
                    // 展开高度与 AgentWorkbenchView 的初始 detent（0.8）一致
                    .presentationDetents([.fraction(0.8)])
            }
            .sheet(isPresented: $isShowingHistory) {
                AgentHistorySheet(store: store) {
                    runState.clearTransientState()
                }
            }
            .sheet(isPresented: $isShowingTripPicker, onDismiss: {
                clearHomeQuickAction(.tripSelection)
                // 工作台内新建旅行时，关闭整个工作台并落到 Agent 首页。
                if closeWorkbenchAfterNewTripPickerDismiss {
                    closeWorkbenchAfterNewTripPickerDismiss = false
                    dismissWorkbench()
                }
            }) {
                // 与主页左上角的「切换旅行」共用同一弹窗；Agent 语境下副标题
                // 换文案。左滑编辑由弹窗内建的「旅行与偏好」处理。
                TodayTripPickerSheet(
                    syncEngine: syncEngine,
                    trips: syncEngine.trips,
                    selectedTripID: syncEngine.selectedTripID,
                    tripBeingSelectedID: nil,
                    isStartingNewTrip: false,
                    subtitle: String(localized: "agent.selectTripSheetSubtitle"),
                    onSelect: { summary in
                        guard summary.id != syncEngine.selectedTripID else { return }
                        startNewConversation()
                        resetSuggestions()
                        Task { await syncEngine.selectTrip(summary.id) }
                        isShowingTripPicker = false
                    },
                    onCreate: {
                        // 两种宿主都回到 Agent 首页开新对话；工作台需先清空当前
                        // 行程，再关闭工作台 sheet，避免 Today 根视图闪回地图。
                        startNewConversation()
                        resetSuggestions()
                        if presentation == .workbench {
                            Task {
                                await syncEngine.clearSelectedTrip()
                                closeWorkbenchAfterNewTripPickerDismiss = true
                                isShowingTripPicker = false
                            }
                        } else {
                            isShowingTripPicker = false
                        }
                    },
                    onDelete: { summary in
                        if summary.id == syncEngine.selectedTripID {
                            startNewConversation()
                            resetSuggestions()
                        }
                        Task { await syncEngine.deleteTrip(summary) }
                    },
                    onDismiss: { isShowingTripPicker = false }
                )
                // 弹窗外观与主页入口完全一致。
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
                .presentationCornerRadius(28)
                .presentationBackground(PrimaryTabPalette.background)
                .presentationContentInteraction(.scrolls)
            }
            .sheet(isPresented: $isShowingCameraPicker) {
                AgentCameraSheet(isPresented: $isShowingCameraPicker) { image in
                    loadCapturedImage(image)
                }
                .presentationDetents([.fraction(0.68)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationBackground(.black)
            }
            .sheet(isPresented: $isShowingDocumentPicker) {
                AgentDocumentPicker(isPresented: $isShowingDocumentPicker) { urls in
                    loadDocuments(urls)
                }
                .preferredColorScheme(.dark)
                .presentationDetents([.fraction(0.9)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationBackground(.black)
            }
            .alert("agent.cannotCompleteTitle", isPresented: Binding(get: { runState.error != nil }, set: { if !$0 { runState.error = nil } })) {
                Button("agent.gotIt", role: .cancel) {}
            } message: { Text(runState.error ?? "") }
            .onAppear {
                store.activateTripPreferences(forTripID: syncEngine.selectedTripID)
                consumeInitialMessageIfNeeded()
                loadSuggestionsIfNeeded()
                Task { @MainActor in repairIncompleteActionableCandidatesIfNeeded() }
            }
            // 「旅行与偏好」的规划条件按旅程隔离：切换生效旅程时把当前偏好
            // 存回原旅程的槽位，载入新旅程自己的槽位（无行程用独立槽位）。
            .onChange(of: syncEngine.selectedTripID) { _, newTripID in
                store.activateTripPreferences(forTripID: newTripID)
            }
            .onChange(of: syncEngine.trip?.id) { _, _ in loadSuggestionsIfNeeded() }
            .onChange(of: syncEngine.trip?.isConfigured) { _, _ in
                loadSuggestionsIfNeeded()
                repairIncompleteActionableCandidatesIfNeeded()
            }
            .onChange(of: runState.isGenerating) { _, isGenerating in
                // 新一轮生成从折叠状态开始；生成结束后思考摘要整体隐藏。
                if !isGenerating { isReasoningExpanded = false }
                // 生成开始时若视图已在下方（泊入态），本轮顶部不再出现思考
                // orb——上滑恢复的只有地球，icon 停在状态行。
                if isGenerating { didDockDuringGeneration = isGlobeDocked }
            }
            .onChange(of: showsHomeDropdownMenu) { _, isVisible in
                guard !isVisible else { return }
                isHomeMenuCollapsed = true
                activeHomeQuickAction = nil
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
            value: presentation == .home && hidesTabBar
        )
        // 只要本视图在场就声明「首页即 Agent 页」，ContentView 据此收起
        // tab 栏右侧的 Agent 按钮视图；离开（有生效行程回到地图）后偏好
        // 回落默认值 false，按钮自动恢复。
        .preference(key: AgentHomeActiveKey.self, value: presentation == .home)
        // tab 栏在场（欢迎页双方块）时为其预留整块高度（栏高 60pt + 底边距
        // 32pt），双方块悬浮其上；tab 栏隐藏（展开输入条/抽签/对话页）时不
        // 预留，输入区随 safeAreaInset 贴到屏幕底部安全区之上。
        .padding(.bottom, presentation == .workbench || anchorsComposerToBottom ? 0 : 92)
    }

    private var tripTitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return String(localized: "agent.noTripTitle") }
        return trip.destination ?? String(localized: "agent.currentTripTitle")
    }

    private var showsHomeDropdownMenu: Bool {
        presentation == .home
            && lotteryStepIndex == nil
            && !isComposerExpanded
            && isWelcomeState
            && onCancelNewTripPlanning == nil
    }

    private var showsBackButton: Bool {
        lotteryStepIndex != nil
            || isComposerExpanded
            || !isWelcomeState
            || onCancelNewTripPlanning != nil
    }

    private func handleHomeQuickAction(_ action: TodayQuickAction) {
        switch action {
        case .addCompanion:
            activeHomeQuickAction = .addCompanion
            isShowingTripSharing = true
        case .tripSelection:
            activeHomeQuickAction = .tripSelection
            isShowingTripPicker = true
        case .reload:
            guard !isReloadingHome else { return }
            activeHomeQuickAction = .reload
            isReloadingHome = true
            Task {
                async let retry: Void = syncEngine.retry()
                try? await Task.sleep(for: .seconds(0.75))
                await retry
                isReloadingHome = false
                clearHomeQuickAction(.reload)
            }
        case .settings:
            activeHomeQuickAction = .settings
            isShowingSettings = true
        case .signIn:
            activeHomeQuickAction = .signIn
            presentSignIn()
        }
    }

    private func presentSignIn() {
        appleSignIn.errorMessage = nil
        isShowingSignIn = true
    }

    private func clearHomeQuickAction(_ action: TodayQuickAction) {
        guard activeHomeQuickAction == action else { return }
        activeHomeQuickAction = nil
    }

    /// 悬浮 Agent 的欢迎态头部保留行程切换、历史和新建入口；发送首条消息后
    /// 它随欢迎态退场，后续界面与 AgentHomeView 的对话态完全一致。
    private var workbenchHeader: some View {
        GeometryReader { proxy in
        ZStack {
            HStack(spacing: 12) {
                Button { isShowingTripPicker = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PrimaryTabPalette.accent)
                        Text(tripTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(minWidth: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    }
                }
                .buttonStyle(.glass)
                .frame(maxWidth: proxy.size.width * 0.5, alignment: .leading)
                .accessibilityLabel(Text("agent.switchTripA11y"))

                Spacer(minLength: 0)

                Button { isShowingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.glass)
                .accessibilityLabel(Text("agent.historyA11y"))

                Button { startNewConversation() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .disabled(isWelcomeState)
                .accessibilityLabel(Text("agent.newConversationA11y"))
            }
        }
        }
        .frame(height: 48)
        .padding(.horizontal, 20)
        .padding(.top, presentation == .workbench ? 18 : 2)
    }

    /// 欢迎页/对话页共用的滚动区：承载地球、消息与流式内容；从 body 拆出
    /// 以控制表达式复杂度（修饰符链条过长会触发类型检查超时）。负责滚动
    /// 到底、键盘收起与地球泊入的滚动监听。
    private func conversationScroll(proxy: ScrollViewProxy) -> some View {
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
            .padding(.top, usesCompactWorkbenchWelcomeLayout ? 8 : 12)
            .padding(.bottom, 16)
            // 欢迎页 ↔ 对话页切换时驱动地球的连续变形（缩小/复原）。
            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: isWelcomeState)
        }
        .scrollIndicators(.hidden)
        // 对话一开始滚动就收起键盘，避免交互式收起仍占着半屏、遮挡用户
        // 查看上方消息；程序触发的自动滚动不会经过 tracking/interacting。
        .scrollDismissesKeyboard(.immediately)
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting:
                if isComposerFocused { isComposerFocused = false }
            default:
                break
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { _, height in
            guard presentation == .workbench,
                  abs(height - workbenchViewportHeight) > 0.5 else { return }
            workbenchViewportHeight = height
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            TapGesture().onEnded {
                if isComposerFocused { isComposerFocused = false }
            }
        )
        // 欢迎态由固定高度的英雄区、行程卡与三条建议组成；无论入口来自
        // 首页还是工作台都不允许滚动，进入对话后才恢复滚动。
        .scrollDisabled(isWelcomeState)
        // 下滑/回顶驱动地球在「顶部常驻」与「状态行泊位」之间切换；
        // 顶部下拉（overscroll，偏移为负）则随距离恢复首页观感。
        .onScrollGeometryChange(
            for: Double.self,
            of: { geometry in geometry.contentOffset.y + geometry.contentInsets.top },
            action: { _, offset in
                updateGlobeDocking(for: offset)
                updateWelcomePeek(for: offset)
            }
        )
        // 点按页面空白处：收起键盘并收回为双方块入口，与左上角
        // 返回键一致；方块内的按钮仍优先响应各自的点按。
        .contentShape(Rectangle())
        .onTapGesture { if isComposerExpanded { collapseComposer() } }
        .onChange(of: store.session.messages.count) { _, _ in scrollToBottom(proxy) }
        .onChange(of: runState.streamingReply) { _, _ in scheduleStreamingScroll(proxy) }
        .onChange(of: runState.liveCards.count) { _, _ in scrollToBottom(proxy) }
        .onChange(of: store.session.draft?.candidates.count ?? 0) { _, _ in scrollToBottom(proxy) }
        .onDisappear {
            streamingScrollTask?.cancel()
            streamingScrollTask = nil
        }
    }

    private var isWelcomeState: Bool {
        store.session.messages.isEmpty && store.session.draft == nil
    }

    /// 底部悬浮 tab 栏是否处于隐藏状态（进入抽签、展开输入条或已在对话中）。
    /// 与上报给 ContentView 的偏好值一致。
    private var hidesTabBar: Bool {
        lotteryStepIndex != nil || isComposerExpanded || !isWelcomeState
    }

    /// 工作台欢迎态需要同时容纳标题、行程摘要和三条建议，因此使用较紧凑的
    /// 地球与间距；首页入口仍保留原先的沉浸式大地球布局。
    private var usesCompactWorkbenchWelcomeLayout: Bool {
        presentation == .workbench
    }

    /// 输入区是否贴底（同时不再为悬浮 tab 栏预留空间）：展开输入条或已进入
    /// 对话时贴底。抽签流程虽然也隐藏 tab 栏，但双方块（选项）保持在原位
    /// 不下移，避免点按「拈签定缘」后按钮突然掉下去。
    private var anchorsComposerToBottom: Bool {
        isComposerExpanded || !isWelcomeState
    }

    /// 欢迎页主标题：抽签流程中显示当前问题，否则显示默认引导文案。
    private var welcomeTitle: String {
        lotteryStepIndex.map { lotterySteps[$0].question } ?? String(localized: "agent.welcomeTitle")
    }

    /// Sheet 为 80% 高度时让欢迎页保持紧凑；扩展到全屏时逐步放大地球。
    /// 上限避免地球挤掉下方的行程摘要和三条建议。
    private var workbenchGlobeAreaHeight: CGFloat {
        min(250, max(150, workbenchViewportHeight * 0.32))
    }

    private var welcomeView: some View {
        // 工作台欢迎态地球与标题之间多留一点呼吸空间；首页保持沉浸式原间距。
        VStack(alignment: .leading, spacing: usesCompactWorkbenchWelcomeLayout ? 20 : 24) {
            welcomeGlobe

            VStack(alignment: .leading, spacing: usesCompactWorkbenchWelcomeLayout ? 0 : 12) {
                // 抽签流程中标题切换为当前问题，文案渐入渐出。滚动区边距为
                // 16pt，补 4pt 后标题左缘（20pt）与底部双方块入口对齐。
                ZStack(alignment: .leading) {
                    Text(welcomeTitle)
                        .font(.title.weight(.bold))
                        .foregroundStyle(.white)
                        .id(welcomeTitle)
                        .transition(.opacity)
                        // 占两行的追问（如「想要躺平慢游，还是特种兵打卡？」）
                        // 会向下生长、贴到下方按钮——按实际渲染高度检测折行
                        // （不依赖文案字数，换文案/换字号/窄屏都成立），
                        // 折行的文案单独上移一行，单行文案保持原位。
                        .onGeometryChange(for: Bool.self) { proxy in
                            // .title 单行高约 36pt，折行后翻倍，以 50pt 为界。
                            proxy.size.height > 50
                        } action: { _, wrapped in
                            guard wrapped != isWelcomeTitleWrapped else { return }
                            withAnimation(.easeInOut(duration: 0.3)) { isWelcomeTitleWrapped = wrapped }
                        }
                }
                .padding(.leading, 4)
                .offset(y: isWelcomeTitleWrapped ? -32 : 0)
            }

            if presentation == .workbench {
                tripContextCard
                suggestedQuestions
            }
        }
        // 键盘唤起/收起时，地球压扁与标题上移/回落作为同一整体参与动画，
        // 标题不会瞬移。
        .animation(.easeInOut(duration: 0.3), value: isComposerFocused)
    }

    @ViewBuilder
    private var welcomeGlobe: some View {
        if usesCompactWorkbenchWelcomeLayout {
            welcomeGlobeCanvas
                .frame(height: workbenchGlobeAreaHeight)
        } else {
            welcomeGlobeCanvas
                // 键盘唤起时整体压扁（宽高比变宽），把下方的标题完整让出到
                // 键盘/输入框之上；收起键盘后恢复正方形地球。
                .aspectRatio(isComposerFocused ? 2.4 : 1, contentMode: .fit)
        }
    }

    private var welcomeGlobeCanvas: some View {
        GeometryReader { proxy in
            let globe = usesCompactWorkbenchWelcomeLayout
                ? min(proxy.size.width * 0.74, proxy.size.height * 0.98)
                : min(proxy.size.width, proxy.size.height) * 0.7

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
                AgentIntroGlobeView(diameter: globe, spin: globeSpin)
                    .matchedGeometryEffect(id: "hero-globe", in: heroMotion)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.top, usesCompactWorkbenchWelcomeLayout ? 6 : 12)
    }

    private var tripContextCard: some View {
        Button { isShowingContext = true } label: {
            HStack(spacing: 12) {
                Image(systemName: syncEngine.trip?.isConfigured == true ? "map.fill" : "calendar.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(width: usesCompactWorkbenchWelcomeLayout ? 30 : 36, height: usesCompactWorkbenchWelcomeLayout ? 30 : 36)
                    .background(PrimaryTabPalette.accent.opacity(0.15), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(tripTitle).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                    Text(tripContextSubtitle).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText).lineLimit(usesCompactWorkbenchWelcomeLayout ? 1 : 2)
                }
                Spacer()
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            .padding(usesCompactWorkbenchWelcomeLayout ? 10 : 14)
            .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 18)
        }
        .buttonStyle(.plain)
    }

    private var tripContextSubtitle: String {
        guard let trip = syncEngine.trip, trip.isConfigured else { return String(localized: "agent.welcomeSubtitle") }
        var details = ["\(trip.startDate ?? "") – \(trip.endDate ?? "")"]
        let preferences = preferenceLabels
        if !preferences.isEmpty { details.append(preferences.joined(separator: " · ")) }
        return details.joined(separator: "  ·  ")
    }

    private var preferenceLabels: [String] {
        let preferences = store.session.preferences
        return [
            preferenceTitle(preferences.pace, values: ["relaxed": String(localized: "agent.preference.relaxed"), "balanced": String(localized: "agent.preference.balanced"), "packed": String(localized: "agent.preference.intense")]),
            preferenceTitle(preferences.companions, values: ["solo": String(localized: "agent.preference.solo"), "couple": String(localized: "agent.preference.couple"), "parents": String(localized: "agent.preference.parents"), "children": String(localized: "agent.preference.kids"), "friends": String(localized: "agent.preference.friends")]),
            preferenceTitle(preferences.budget, values: ["value": String(localized: "agent.preference.budget"), "balanced": String(localized: "agent.preference.mid"), "premium": String(localized: "agent.preference.premium")])
        ].compactMap { $0 }
    }

    private func preferenceTitle(_ value: String?, values: [String: String]) -> String? {
        guard let value else { return nil }
        return values[value]
    }

    @ViewBuilder
    private var suggestedQuestions: some View {
        if revealedSuggestionCount > 0 {
            VStack(alignment: .leading, spacing: usesCompactWorkbenchWelcomeLayout ? 8 : 12) {
                Text("agent.examplesTitle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)

                ForEach(
                    Array(suggestedPrompts.prefix(revealedSuggestionCount).enumerated()),
                    id: \.element
                ) { index, prompt in
                    Button { useSuggestedPrompt(prompt) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: suggestionIcon(at: index, fallback: prompt))
                                .frame(width: 24)
                                .foregroundStyle(PrimaryTabPalette.accent)
                            Text(prompt)
                                .foregroundStyle(.white)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "arrow.up.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(PrimaryTabPalette.tertiaryText)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, usesCompactWorkbenchWelcomeLayout ? 9 : 15)
                        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 18)
                    }
                    .buttonStyle(.plain)
                    // 每条从左侧向右移入，同时由透明变为不透明；数组按节拍
                    // 一次只增加一项，因此不会出现三条同时淡入。
                    .transition(.offset(x: -32).combined(with: .opacity))
                }
            }
            .transition(.opacity)
        }
    }

    private func promptIcon(_ prompt: String) -> String {
        if prompt.contains("粘贴小红书") { return "link" }
        if prompt.contains("去小红书找") { return "magnifyingglass" }
        if prompt.contains("父母") { return "figure.2.and.child.holdinghands" }
        if prompt.contains("室内") { return "cloud.rain" }
        if prompt.contains("500") { return "banknote" }
        return "sparkles"
    }

    private func suggestionIcon(at index: Int, fallback prompt: String) -> String {
        guard index < suggestedIcons.count else { return promptIcon(prompt) }
        return suggestedIcons[index]
    }

    private func useSuggestedPrompt(_ prompt: String) {
        message = prompt
        expandComposer()
    }

    private func resetSuggestions() {
        withAnimation(.easeOut(duration: 0.18)) {
            revealedSuggestionCount = 0
            suggestedPrompts = []
            suggestedIcons = []
        }
    }

    /// 拉取当前行程的三条动态建议。返回后以独立插入的方式逐条播放，确保
    /// 每条问题都完整走完“左侧进入 + 渐显”，而不是整组一起淡入。
    private func loadSuggestionsIfNeeded() {
        guard presentation == .workbench, isWelcomeState else { return }
        let trip = syncEngine.trip
        let hasActiveTrip = trip?.isConfigured == true
        let suggestionKey = hasActiveTrip ? (trip?.id ?? -1) : -1
        guard suggestionsTripID != suggestionKey else { return }
        suggestionsTripID = suggestionKey
        resetSuggestions()

        let preferences = store.session.preferences
        let request = AITripSuggestionsRequest(
            mode: hasActiveTrip ? nil : "journey",
            destination: trip?.destination,
            startDate: trip?.startDate,
            endDate: trip?.endDate,
            currency: trip?.currency,
            preferences: AITripSuggestionsRequest.Preferences(
                pace: preferences.pace,
                companions: preferences.companions,
                budget: preferences.budget,
                interests: preferences.interests.isEmpty ? nil : AgentInterest.displayNames(for: preferences.interests)
            ),
            existingItinerary: hasActiveTrip ? syncEngine.existingItinerarySnapshot() : nil
        )

        Task { @MainActor in
            guard let result = try? await APIClient().fetchTripSuggestions(
                request,
                tripID: hasActiveTrip ? trip?.id : nil
            ), !result.suggestions.isEmpty,
               suggestionsTripID == suggestionKey,
               isWelcomeState else { return }

            suggestedPrompts = result.suggestions
            suggestedIcons = result.icons ?? []
            revealedSuggestionCount = 0
            for count in 1...result.suggestions.count {
                guard suggestionsTripID == suggestionKey, isWelcomeState else { return }
                withAnimation(.easeOut(duration: 0.34)) {
                    revealedSuggestionCount = count
                }
                try? await Task.sleep(for: .milliseconds(110))
            }
        }
    }

    private var conversationView: some View {
        VStack(alignment: .leading, spacing: 22) {
            conversationGlobeHeader

            // 消息列表：用户消息为右侧橙色气泡，助手消息通栏靠左展示。
            ForEach(Array(store.session.messages.enumerated()), id: \.element.id) { _, item in
                ChatMessageView(
                    message: item,
                    attachments: store.session.sentAttachments(for: item.id)
                )
            }

            // 思考指示只在思考进行中（status 非空）可见：正文开始流出即整体
            // 隐藏（含摘要），新的思考事件到来再原样重现，而非等到生成结束。
            // 状态行本身承载展开/收起（箭头也在这一行）：有摘要时点按
            // 状态行切换，摘要就地展开在状态行下方、回复上方。
            if let status = runState.status {
                // 状态行顶到左边缘显示：icon 在屏幕上方（未泊入）时摘要左侧
                // 无缩进；泊入后泊位展开 20pt、摘要随之右移（与泊入弹簧、图
                // 标飞行同步进行），飞行落地后泊位 icon 淡入。
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { isReasoningExpanded.toggle() }
                    } label: {
                        HStack(spacing: 0) {
                            ZStack {
                                if showsDockedThinkingOrb {
                                    ThinkingOrb(state: agentThinkingOrbState(for: status), size: .px20, theme: .dark)
                                        .transition(.opacity)
                                }
                            }
                            .frame(width: orbSlotOccupied ? 20 : 0, height: 20)
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named("agent-home-page"))
                            } action: { _, frame in
                                if runState.isGenerating { orbSlotFrame = frame }
                            }
                            // 思考状态限定单行，过长时尾部省略，避免状态行被长文案撑高。
                            Text(status)
                                .lineLimit(1)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .padding(.leading, orbSlotOccupied ? 10 : 0)
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
            }

            if !runState.streamingReply.isEmpty {
                AssistantMessageContainer {
                    Text(runState.streamingReply)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // The completed message is exposed immediately after `.done`.
                // Hiding the per-token intermediate value avoids rebuilding a
                // very large accessibility label dozens of times per second.
                .accessibilityHidden(true)
            }

            if let fliggy = runState.fliggyProgress {
                AssistantMessageContainer {
                    FliggySearchStatusChip(progress: fliggy)
                }
            }

            if !runState.liveCards.isEmpty {
                AssistantMessageContainer {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("agent.generatingCandidates")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        ForEach(runState.liveCards) { card in
                            AgentV2LiveCandidateCard(card: card)
                        }
                    }
                }
            }

            if let proposal = store.session.pendingProposal,
               plansNewTrip || syncEngine.trip?.isConfigured != true {
                AssistantMessageContainer {
                    tripProposalCard(proposal)
                }
            }

            if store.session.summary != nil || store.session.draft != nil {
                AssistantMessageContainer {
                    workbenchView
                }
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
    }

    /// 对话页顶部的地球区：发送首条消息后，欢迎页大地球经 matchedGeometry
    /// 连续缩小到这里常驻，不随对话消失；消息在其下方展示。生成期间（本轮
    /// 尚未泊入过）地球在同一画布内交叉溶解为对应状态的 ASCII 思考 orb——
    /// 颜色、字符与字号都对齐地球语言，无切换感。用户下滑后整体折叠（高度
    /// 照常预留，消息不上跳）；本轮内上滑恢复的只有地球，思考 icon 停泊在
    /// 状态行不再上移。
    /// 下拉 peek 的当前地球直径：从对话常态的 120pt 插值到欢迎页的内容宽
    /// × 0.7。直径真实传入渲染器（而非 scaleEffect 视觉放大）——地球内的
    /// 字符保持欢迎页同款 12pt，不会随放大一起变大。
    private var peekGlobeDiameter: CGFloat {
        let welcome = contentWidth > 0 ? contentWidth * 0.7 : Self.conversationGlobeDiameter * 2.1
        return Self.conversationGlobeDiameter + (welcome - Self.conversationGlobeDiameter) * CGFloat(welcomePeek)
    }

    /// 下拉 peek 的头部区块边长：常态 120pt，锁定时与欢迎页的方形地球
    /// 区块同尺寸（内容宽），地球居中其中——地球位置与首页初始状态一致，
    /// 消息随区块长高被推到地球下方。
    private var peekBlockSide: CGFloat {
        let target = contentWidth > 0 ? contentWidth : Self.conversationGlobeDiameter * 2.98
        return Self.conversationGlobeDiameter + (target - Self.conversationGlobeDiameter) * CGFloat(welcomePeek)
    }

    private var conversationGlobeHeader: some View {
        ZStack {
            // 顶部下拉恢复首页观感时的橙色光晕（与欢迎页同配方、同比例），
            // 随下拉进度淡入，尺寸跟随当前地球直径。
            Circle()
                .fill(
                    RadialGradient(
                        colors: [PrimaryTabPalette.accent.opacity(0.5), PrimaryTabPalette.accent.opacity(0)],
                        center: .center,
                        startRadius: peekGlobeDiameter * 0.14,
                        endRadius: peekGlobeDiameter * 0.62
                    )
                )
                .frame(width: peekGlobeDiameter * 1.25, height: peekGlobeDiameter * 1.25)
                .blur(radius: peekGlobeDiameter * 0.12)
                .opacity(welcomePeek)
                .allowsHitTesting(false)
            if !isGlobeDocked {
                AgentHeroGlobeView(thinkingState: heroThinkingState, diameter: peekGlobeDiameter, spin: globeSpin)
                    .matchedGeometryEffect(id: "hero-globe", in: heroMotion)
                    .transition(.scale(scale: 0.86).combined(with: .opacity))
                    // 上报地球本体矩形：泊入飞行的起飞点。挂在地球自身尺寸
                    // 之后（挂到区块/外层 frame 上会把测量矩形放大到整行宽），
                    // 仅在生成期间更新，平时滚动不触发整页重渲染。
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("agent-home-page"))
                    } action: { _, frame in
                        if runState.isGenerating { heroFrame = frame }
                    }
            }
        }
        .frame(width: peekBlockSide, height: peekBlockSide)
        .frame(maxWidth: .infinity)
        // 捕获内容宽度：首页尺寸目标（地球 0.7×、区块 1×）随布局宽度走。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { _, width in
            if abs(width - contentWidth) > 0.5 { contentWidth = width }
        }
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    /// 英雄位当前呈现的思考状态：仅在本轮生成中、尚未泊入过、且正在思考
    /// （status 非空）时变形为思考 orb——正文开始流出即回到地球，新的思考
    /// 到来再变回。泊入过之后，本轮内上滑出现在顶部的只有地球。
    private var heroThinkingState: OrbState? {
        guard runState.isGenerating, !didDockDuringGeneration, let status = runState.status else { return nil }
        return agentThinkingOrbState(for: status)
    }

    /// 思考状态行的泊位是否展开（本轮生成内已泊入过）：控制泊位宽度与
    /// 摘要的左缩进；图标本体要等泊入飞行落地后才淡入。
    private var orbSlotOccupied: Bool {
        runState.isGenerating && didDockDuringGeneration
    }

    /// 泊位中是否显示图标本体：泊位已展开且没有正在进行的泊入飞行
    /// （飞行覆盖层落地后才交接给泊位里的常驻 icon）。
    private var showsDockedThinkingOrb: Bool {
        orbSlotOccupied && dockFlight == nil
    }

    /// 滚动偏移驱动地球泊入/展开：只在跨越阈值时切换（带滞回），切换包在
    /// withAnimation 里驱动顶部英雄位的折叠/展开、泊位展开与摘要右移。
    private func updateGlobeDocking(for offset: Double) {
        if !isGlobeDocked, offset > Self.globeDockOffset {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                isGlobeDocked = true
                // 生成期间发生泊入：状态行泊位就此常驻到本轮结束。
                if runState.isGenerating { didDockDuringGeneration = true }
            }
            startDockFlightIfNeeded()
        } else if isGlobeDocked, offset < Self.globeUndockOffset {
            // 展开只影响顶部英雄位（本轮泊入过时恢复为地球）；状态行的
            // icon 是否保留由 didDockDuringGeneration 决定，不随这里变化。
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { isGlobeDocked = false }
        }
    }

    /// 顶部下拉（overscroll，偏移为负）随距离恢复首页观感。进度直接跟手
    /// （不另加动画）；拉满即锁定——完整首页视觉保持住，松手的回弹不再把
    /// 视觉带回对话常态，上滑越过阈值才解除。未锁定时进度随偏移连续变化
    /// （松手回弹自然回落），变化小于 0.1% 不写入，避免平时滚动整页重渲染。
    private func updateWelcomePeek(for offset: Double) {
        if isWelcomePeekLocked {
            // 锁定中：保持完整首页视觉；上滑越过阈值后解除并回落。
            if offset > Self.welcomePeekUnlockOffset {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                    isWelcomePeekLocked = false
                    welcomePeek = 0
                }
            }
            return
        }
        let progress = min(1, max(0, -offset) / Self.welcomePeekDistance)
        if progress >= 1 {
            // 拉满即锁定在首页观感（此刻进度本就为 1，无缝进入锁定态）。
            isWelcomePeekLocked = true
            welcomePeek = 1
            return
        }
        if abs(progress - welcomePeek) > 0.001 {
            welcomePeek = progress
        }
    }

    /// 思考中（状态行在场）发生泊入时，播放图标从英雄位飞往泊位的动画，
    /// 让「移到摘要左侧」的移动看得见；无思考状态或矩形尚未上报时跳过，
    /// 泊位 icon 直接淡入兜底。
    private func startDockFlightIfNeeded() {
        guard runState.isGenerating,
              let status = runState.status,
              heroFrame.width > 0,
              orbSlotFrame != .zero else { return }
        // 泊位此刻正从 0 宽展开到 20pt（向右生长），按最终占位构造降落点。
        let target = CGRect(x: orbSlotFrame.minX, y: orbSlotFrame.minY, width: 20, height: 20)
        dockFlight = AgentGlobeDockFlight(
            from: heroFrame,
            to: target,
            heroState: heroThinkingState,
            orbState: agentThinkingOrbState(for: status)
        )
    }

    @ViewBuilder private var workbenchView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = store.session.summary {
                VStack(alignment: .leading, spacing: 8) {
                    Label("agent.roundLabel", systemImage: "sparkles")
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
                            candidateGroup(title: carried.isEmpty ? String(localized: "agent.candidatesGroup") : String(format: String(localized: "agent.newThisRound"), current.count), candidates: current, actionableIDs: draft.actionableCandidateIDs)
                        }
                        if !carried.isEmpty {
                            candidateGroup(title: String(format: String(localized: "agent.carriedOver"), carried.count), candidates: carried, actionableIDs: draft.actionableCandidateIDs)
                        }
                    }
                }

                if !draft.unresolvedCandidateChanges.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("agent.incompleteCandidates")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.orange)
                        ForEach(draft.unresolvedCandidateChanges) { change in
                            AgentMissingCandidateCard(change: change)
                        }
                    }
                }

                if !draft.changes.isEmpty {
                    DisclosureGroup(String(format: String(localized: "agent.changeList"), draft.changes.count)) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.changes) { change in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: change.operation.symbol)
                                        .foregroundStyle(change.operation.tint)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(String(format: String(localized: "agent.titleChip"), change.operationTitle, change.summary))
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

                let actionableCandidates = draft.candidates.filter { draft.actionableCandidateIDs.contains($0.id) }
                let selected = actionableCandidates.filter(\.selected)
                let allCandidatesSelected = !actionableCandidates.isEmpty && actionableCandidates.allSatisfy(\.selected)
                // 变更清单中待确认的“移除行程卡”提案：无选中候选时也可单独提交。
                let pendingRemovals = draft.changes.filter { $0.operation == .remove && $0.targetCardId != nil }
                let hasInvalidSelection = selected.contains(where: { !$0.isCommitReady })
                let canCommit = !runState.isCommitting
                    && repairingCandidateIDs.isEmpty
                    && !hasInvalidSelection
                    && (!selected.isEmpty || !pendingRemovals.isEmpty)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(String(format: String(localized: "agent.candidateCount"), draft.candidates.count) + (pendingRemovals.isEmpty ? "" : " " + String(format: String(localized: "agent.pendingRemovalCount"), pendingRemovals.count)))
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                        Spacer()
                        Button(allCandidatesSelected ? String(localized: "agent.deselectAll") : String(localized: "agent.selectAll")) {
                            selectAllCandidates(actionableCandidates, selected: !allCandidatesSelected)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                        .disabled(actionableCandidates.isEmpty || runState.isCommitting)
                    }

                    Button { commit() } label: {
                        HStack {
                            if runState.isCommitting { ProgressView().tint(.white) }
                            Text(selected.isEmpty && !pendingRemovals.isEmpty ? String(format: String(localized: "agent.confirmRemove"), pendingRemovals.count) : String(format: String(localized: "agent.confirmAdd"), selected.count))
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

                    if hasInvalidSelection {
                        Text("agent.captionVerify")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else if selected.isEmpty && !pendingRemovals.isEmpty {
                        Text("agent.captionRemove")
                            .font(.caption)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                    } else {
                        Text("agent.captionKeep")
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
            Label("agent.proposalLabel", systemImage: "map")
                .font(.headline)
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 6) {
                Label(proposal.destination, systemImage: "location.fill")
                Label(String(format: String(localized: "agent.proposalRange"), proposal.startDate, proposal.endDate), systemImage: "calendar")
                Label(String(format: String(localized: "agent.proposalCurrency"), proposal.currency), systemImage: "creditcard")
            }
            .font(.subheadline)
            .foregroundStyle(.white.opacity(0.85))

            Button { confirmTripProposal(proposal) } label: {
                HStack {
                    if isCreatingTripFromProposal { ProgressView().tint(.white) }
                    Text("agent.createTripButton")
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

            Text("agent.captionCreate")
                .font(.caption)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
        }
        .padding(14)
        .primaryTabCardStyle(color: PrimaryTabPalette.surface, cornerRadius: 20)
    }

    @ViewBuilder
    private func candidateGroup(title: String, candidates: [AgentV2Candidate], actionableIDs: Set<UUID>) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(PrimaryTabPalette.secondaryText)
        ForEach(candidates) { candidate in
            VStack(alignment: .trailing, spacing: 7) {
                AgentV2CandidateCard(
                    candidate: candidate,
                    isSelectable: candidate.isCommitReady
                        && !repairingCandidateIDs.contains(candidate.id)
                        && (actionableIDs.contains(candidate.id) || !(store.session.draft?.changes.contains { $0.candidateId == candidate.id && $0.targetCardId != nil } ?? false))
                ) { value in
                    store.selectForImport(value, id: candidate.id)
                }
                Button(role: .destructive) {
                    withAnimation(.snappy(duration: 0.25)) {
                        store.rejectCandidate(id: candidate.id)
                    }
                } label: {
                    Label("agent.rejectSuggestion", systemImage: "xmark.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red.opacity(0.88))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if !store.session.attachments.isEmpty {
                attachmentPreviewStrip
            }

            // 双方块入口只在欢迎页（尚无对话）出现；进入对话后输入条常驻，
            // 键盘收起也不再收回为方块形态。
            if presentation == .workbench || isComposerExpanded || !isWelcomeState {
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
        .padding(.bottom, presentation == .workbench || anchorsComposerToBottom ? 8 : 36)
        // 聊天框所在区域的渐变遮罩：盖住从输入控件（加号、文本框、发送键）
        // 之间缝隙透出的滚动内容，向下延伸覆盖到屏幕底；顶缘留少量透明
        // 过渡避免生硬的横切线。欢迎页玻璃方块需透出 ASCII 底纹，不加遮罩。
        // 遮罩条件与展开输入条的出现条件保持一致：工作台欢迎态键盘收起时
        // 输入条常驻，遮罩也不消失。
        // 无附件时也向输入框上方延伸一段，避免消息从控件缝隙透出；附件条
        // 出现后再按实测高度扩展。遮罩只负责绘制，绝不拦截滚动手势。
        .background {
            Group {
                if presentation == .workbench || isComposerExpanded || !isWelcomeState {
                    LinearGradient(
                        stops: [
                            .init(color: PrimaryTabPalette.background.opacity(0), location: 0),
                            .init(color: PrimaryTabPalette.background.opacity(0.72), location: 0.26),
                            .init(color: PrimaryTabPalette.background.opacity(0.95), location: 0.55),
                            .init(color: PrimaryTabPalette.background, location: 0.82)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .padding(.top, -composerBackdropTopExtension)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .animation(.easeInOut(duration: 0.3), value: isWelcomeState)
            .animation(.easeInOut(duration: 0.25), value: store.session.attachments.isEmpty)
        }
        .onChange(of: isComposerFocused) { _, focused in
            // 键盘收起且没有草稿文本时收回为双方块入口；有内容或已在对话页
            // （输入条常驻）时保持展开。
            if presentation == .home,
               !focused,
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               isWelcomeState {
                withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = false }
            }
        }
        .onChange(of: lotteryDurationDays) { _, days in
            // 预算范围随天数联动：天数变化时把当前预算夹回新的取值范围，
            // 避免确认时把超范围的天价/低价记录进上下文。
            let range = budgetRange(forDays: Int(days))
            lotteryBudgetAmount = min(max(lotteryBudgetAmount, range.lowerBound), range.upperBound)
        }
    }

    /// The backdrop always starts above the text field. Attachments raise its
    /// fade origin further so both the tray and the empty composer receive the
    /// same readable, touch-through treatment.
    private var composerBackdropTopExtension: CGFloat {
        let emptyComposerExtension: CGFloat = 54
        guard !store.session.attachments.isEmpty else { return emptyComposerExtension }
        return max(emptyComposerExtension, attachmentStripHeight + 24)
    }

    /// ChatGPT-style attachment tray: selected images/files sit directly
    /// above the text field and can be removed before sending.
    private var attachmentPreviewStrip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(store.session.attachments) { attachment in
                    AgentAttachmentPreviewCard(attachment: attachment) {
                        store.removeAttachment(id: attachment.id)
                    }
                }

                if isProcessingAttachment {
                    ProgressView()
                        .tint(PrimaryTabPalette.accent)
                        .frame(width: 72, height: 72)
                        .background(
                            PrimaryTabPalette.surface,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
            }
            .padding(.horizontal, 2)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
        .onScrollGeometryChange(for: AgentAttachmentEdgeFade.self) { geometry in
            AgentAttachmentEdgeFade.resolve(
                offset: geometry.contentOffset.x + geometry.contentInsets.leading,
                contentWidth: geometry.contentSize.width,
                containerWidth: geometry.containerSize.width
            )
        } action: { _, fade in
            attachmentEdgeFade = fade
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            attachmentEdgeGradient(startPoint: .leading, endPoint: .trailing)
                .opacity(attachmentEdgeFade.leading)
        }
        .overlay(alignment: .trailing) {
            attachmentEdgeGradient(startPoint: .trailing, endPoint: .leading)
                .opacity(attachmentEdgeFade.trailing)
        }
        // 实测附件条高度（含顶部内边距），供渐变遮罩按需向上延伸。
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { _, height in
            attachmentStripHeight = height
        }
    }

    private func attachmentEdgeGradient(startPoint: UnitPoint, endPoint: UnitPoint) -> some View {
        LinearGradient(
            colors: [PrimaryTabPalette.background, PrimaryTabPalette.background.opacity(0)],
            startPoint: startPoint,
            endPoint: endPoint
        )
        .frame(width: AgentAttachmentEdgeFade.maskWidth)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 展开态：完整输入条（图片、文本框、发送键）。背景与「+」控件和折叠态
    /// 右侧方块共享 matchedGeometryEffect，点按后连续变形为扁平输入条。
    private var expandedComposer: some View {
        // 「+」、输入框、发送键垂直居中对齐（多行输入时两侧按钮随行高中点）。
        HStack(alignment: .center, spacing: 8) {
            addPhotoButton

            TextField("agent.inputPlaceholder", text: $message, axis: .vertical)
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
            .accessibilityLabel(runState.isGenerating ? Text("agent.stopA11y") : Text("agent.sendA11y"))
        }
    }

    /// 折叠态：左右两个宽度各占一半的正方形入口，材质与主界面悬浮 tab 栏
    /// 一致（玻璃底 + 白描边）。默认左侧“拈签定缘”、右侧输入入口（含添加
    /// 图片控件）；抽签的二选一问题中两个方块变为选项，天数/预算两问则
    /// 换成滑动条作答面板。
    private var collapsedComposer: some View {
        VStack(spacing: 8) {
            if lotteryStepIndex != nil {
                // 跳过：跳过当前这一问（不记录选择）；已是最后一问则直接抽签。
                HStack {
                    Spacer()
                    Button { skipLottery() } label: {
                        HStack(spacing: 2) {
                            Text("lottery.skip")
                            Image(systemName: "chevron.right")
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimaryTabPalette.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("lottery.skipQuestionA11y"))
                }
                .transition(.opacity)
            }

            if let index = lotteryStepIndex {
                switch lotterySteps[index].kind {
                case .choice:
                    HStack(spacing: 12) {
                        leftEntrySquare
                        rightEntrySquare
                    }
                    .id("lottery-choices-\(index)")
                    .transition(.opacity)
                case .duration:
                    AgentLotterySliderPanel(
                        range: 1...30,
                        step: 1,
                        value: $lotteryDurationDays,
                        minLabel: String(localized: "lottery.daysMin"),
                        maxLabel: String(localized: "lottery.daysMax"),
                        buttonTitle: String(localized: "lottery.nextStep"),
                        accessibilityLabel: String(localized: "lottery.daysA11y"),
                        onConfirm: { confirmLotteryDuration() },
                        format: { days in
                            (number: "\(Int(days))", unit: days >= 30 ? String(localized: "lottery.daysPlus") : String(localized: "lottery.daysUnit"))
                        }
                    )
                    .id("lottery-slider-duration")
                    .transition(.opacity)
                case .budget:
                    AgentLotterySliderPanel(
                        range: lotteryBudgetRange,
                        step: lotteryBudgetStep,
                        value: $lotteryBudgetAmount,
                        minLabel: String(format: String(localized: "lottery.budgetMin"), Int(lotteryBudgetRange.lowerBound).formatted()),
                        maxLabel: String(format: String(localized: "lottery.budgetMax"), Int(lotteryBudgetRange.upperBound).formatted()),
                        buttonTitle: String(localized: "lottery.drawButton"),
                        accessibilityLabel: String(localized: "lottery.budgetA11y"),
                        onConfirm: { confirmLotteryBudget() },
                        format: { amount in
                            (number: String(format: String(localized: "lottery.answerBudget"), Int(amount).formatted()), unit: amount >= lotteryBudgetRange.upperBound ? String(localized: "lottery.above") : "")
                        }
                    )
                    .id("lottery-slider-budget")
                    .transition(.opacity)
                }
            } else {
                HStack(spacing: 12) {
                    leftEntrySquare
                    rightEntrySquare
                }
                .transition(.opacity)
            }
        }
    }

    /// 当前追问是否为二选一形式（返回左右选项文案与下标）；滑动条两问返回 nil。
    private var currentChoiceStep: (index: Int, left: String, right: String)? {
        guard let index = lotteryStepIndex,
              case .choice(let left, let right) = lotterySteps[index].kind else { return nil }
        return (index, left, right)
    }

    /// 左侧方块：默认是「拈签定缘」入口；抽签二选一问题中是当前问题的左选项。
    private var leftEntrySquare: some View {
        Button {
            if let choice = currentChoiceStep {
                answerLottery(value: choice.left)
            } else {
                drawLot()
            }
        } label: {
            ZStack {
                if let choice = currentChoiceStep {
                    lotteryChoiceLabel(choice.left)
                        .id("lottery-left-\(choice.index)")
                        .transition(.opacity)
                } else {
                    // 白图标 + 短标签整体靠左对齐，贴齐方块左内边距（20pt）。
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: "dice.fill")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("lottery.entryTitle")
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
        .accessibilityLabel(currentChoiceStep.map { Text(String(format: String(localized: "lottery.selectA11y"), $0.left)) } ?? Text("lottery.entryA11y"))
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
    /// 抽签二选一问题中是当前问题的右选项。
    private var rightEntrySquare: some View {
        Group {
            if let choice = currentChoiceStep {
                Button {
                    answerLottery(value: choice.right)
                } label: {
                    ZStack {
                        lotteryChoiceLabel(choice.right)
                            .id("lottery-right-\(choice.index)")
                            .transition(.opacity)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background { AgentEntryGlassTile() }
                }
                .buttonStyle(.plain)
            } else {
                // 输入入口：目的地静态图片做背景（随包资源，跟随底部 roller
                // 的目的地切换），下半部分压渐变遮罩，「下个目的地 / 我们去」
                // 与目的地小字一起沉底；折叠态不显示「+」控件（易被误解为
                // 添加入口），展开输入条后再添加图片。玻璃底与展开态 TextField
                // 共享 matchedGeometryEffect，点按后连续变形为完整输入条。
                ZStack {
                    AgentEntryGlassTile()
                        .matchedGeometryEffect(id: "composer-field", in: composerMotion)
                    // 照片盖在玻璃底上；随 roller 切换做淡入淡出，与底部文案
                    // 的翻滚节奏一致。Color.clear 占位承接方块尺寸，图片画在
                    // overlay 里不参与布局——scaledToFill 的溢出只被 clipShape
                    // 裁掉，不会撑大方块。
                    Color.clear
                        .overlay {
                            if let artwork = Self.destinationArtwork[currentInspiration.image] {
                                Image(uiImage: artwork)
                                    .resizable()
                                    .scaledToFill()
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .id(inspirationIndex)
                        .transition(.opacity)
                    // 下半部分渐变遮罩：从方块中部起向下压暗，保证底部
                    // 标题与 roller 文字在照片上可读。
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black.opacity(0.45), location: 0.55),
                            .init(color: .black.opacity(0.78), location: 1)
                        ],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 10) {
                        Spacer(minLength: 0)
                        Text("lottery.tileTitle")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)
                            .lineSpacing(4)
                            .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        suggestionRoller
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(20)
                    // 右上角 ↗ 箭头（SF Symbol arrow.up.right）：提示点按后
                    // 会展开为输入条。
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(14)
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .onTapGesture { expandComposer() }
            }
        }
        .accessibilityLabel(currentChoiceStep.map { Text(String(format: String(localized: "lottery.selectA11y"), $0.right)) } ?? Text("lottery.expandInputA11y"))
        // 两个入口等宽，略高于正方形。
        .frame(maxWidth: .infinity)
        .aspectRatio(entryTileAspectRatio, contentMode: .fit)
    }

    /// 「+」附件菜单：使用原生 Menu，保持与系统的键盘、VoiceOver 和
    /// pointer 交互一致。具体选择器在照片/拍摄/文件入口中分别呈现。
    private var addPhotoButton: some View {
        Menu {
            Button {
                presentCameraPicker()
            } label: {
                Label("lottery.menuCamera", systemImage: "camera")
            }

            Button {
                presentPhotoPicker()
            } label: {
                Label("lottery.menuPhoto", systemImage: "photo.on.rectangle")
            }

            Button {
                presentDocumentPicker()
            } label: {
                Label("lottery.menuFile", systemImage: "paperclip")
            }
        } label: {
            Image(systemName: "plus")
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(PrimaryTabPalette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
        .disabled(isProcessingAttachment)
        .accessibilityLabel(Text("lottery.menuA11y"))
        .matchedGeometryEffect(id: "composer-plus", in: composerMotion)
    }

    private func lotteryChoiceLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.white)
    }

    /// 「拈签定缘」入口的弥散光晕：在 Canvas 里绘制多个暖色（橙-琥珀-珊瑚）
    /// 光斑，各自沿李萨如曲线游走、彼此交叠成一片流动的暖光场。所有绘制
    /// 都光栅化在画布（= 方块）自身边界内，结构上杜绝溢出按钮——不依赖
    /// 任何裁剪修饰符。不参与命中测试，纯视觉提示可点按抽签。
    private var lotteryGlow: some View {
        TimelineView(.periodic(from: .now, by: 1 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let rect = CGRect(origin: .zero, size: size)
                let tile = Path(roundedRect: rect, cornerRadius: 20, style: .continuous)
                context.clip(to: tile)

                // 静态暖色底：中心向边缘弥散淡出，保证光场始终铺满方块。
                context.fill(
                    tile,
                    with: .radialGradient(
                        Gradient(colors: [PrimaryTabPalette.accent.opacity(0.3), .clear]),
                        center: CGPoint(x: rect.midX, y: rect.midY),
                        startRadius: 0,
                        endRadius: max(rect.width, rect.height) * 0.7
                    )
                )

                // 游走光斑（李萨如轨迹）：振幅相对方块尺寸且超过半宽/半高——
                // 亮度中心可以走出方块边界，光像从一侧扫入、另一侧掠出；但
                // 一切绘制都在画布内完成，越界部分不会被显示。色取橙的暖色
                // 近邻，模糊后成弥散光。
                let blobs: [(scale: CGFloat, ax: CGFloat, fx: Double, ay: CGFloat, fy: Double, phase: Double, color: Color)] = [
                    (0.95, 0.55, 0.6, 0.52, 0.42, 0, PrimaryTabPalette.accent),
                    (1.15, 0.6, 0.35, 0.45, 0.53, 2.1, Color(hex: 0xFFAA46)),
                    (0.75, 0.5, 0.71, 0.58, 0.30, 4.2, Color(hex: 0xFF785F))
                ]
                for blob in blobs {
                    let diameter = blob.scale * min(rect.width, rect.height)
                    let center = CGPoint(
                        x: rect.midX + blob.ax * rect.width * sin(t * blob.fx + blob.phase),
                        y: rect.midY + blob.ay * rect.height * sin(t * blob.fy + blob.phase * 1.7)
                    )
                    var blobContext = context
                    blobContext.addFilter(.blur(radius: diameter * 0.3))
                    blobContext.opacity = 0.4 + 0.15 * sin(t * 0.9 + blob.phase)
                    blobContext.fill(
                        Path(ellipseIn: CGRect(
                            x: center.x - diameter / 2,
                            y: center.y - diameter / 2,
                            width: diameter,
                            height: diameter
                        )),
                        with: .color(blob.color)
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .accessibilityHidden(true)
    }

    /// 底部灵感滚动条：定位图标固定不动，目的地小字和国旗一起像翻牌一样
    /// 向上滚动（每 1.8 秒切换一次）；旧文案向上滑出淡去、新文案自下滑入，
    /// 超出区域被裁剪。
    private var suggestionRoller: some View {
        HStack(spacing: 6) {
            Image(systemName: "mappin.and.ellipse")
                .font(.footnote.weight(.semibold))
            ZStack(alignment: .bottomLeading) {
                let entry = Self.inspirationSuggestions[inspirationIndex % Self.inspirationSuggestions.count]
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

    /// roller 当前停留的灵感条目：方块背景静态图片与它保持一致。
    private var currentInspiration: (name: String, flag: String, image: String) {
        Self.inspirationSuggestions[inspirationIndex % Self.inspirationSuggestions.count]
    }

    private func expandComposer() {
        if presentation == .home {
            withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = true }
        }
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
        lotteryDurationDays = 5
        lotteryBudgetAmount = 10_000
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

    /// 天数滑动条确认：记录所选天数并推进（30 天记为「30天以上」）。
    /// 预算范围随天数联动：若此前记录的预算落在新范围之外，重置为按
    /// 每人每天 ¥1,500 的默认档。
    private func confirmLotteryDuration() {
        let days = Int(lotteryDurationDays)
        let range = budgetRange(forDays: days)
        if !range.contains(lotteryBudgetAmount) {
            let step = budgetStep(forDays: days)
            let fallback = ((Double(days) * 1_500) / step).rounded() * step
            lotteryBudgetAmount = min(max(fallback, range.lowerBound), range.upperBound)
        }
        answerLottery(value: days >= 30 ? String(localized: "lottery.answer30plus") : String(format: String(localized: "lottery.answerDays"), days))
    }

    /// 预算滑动条确认：记录所选预算并推进（拉满记为「以上」）。
    private func confirmLotteryBudget() {
        let amount = Int(lotteryBudgetAmount)
        answerLottery(value: String(format: String(localized: "lottery.answerBudget"), amount.formatted()) + (amount >= Int(lotteryBudgetRange.upperBound) ? String(localized: "lottery.above") : ""))
    }

    /// 预算滑动条的取值范围随天数联动：1 天 ¥300~¥5,000、30 天
    /// ¥7,500~¥90,000（低档 max(¥300, ¥250/天)，高档 max(¥5,000, ¥3,000/天)）。
    private func budgetRange(forDays days: Int) -> ClosedRange<Double> {
        let days = Double(max(1, days))
        return max(300, days * 250)...max(5_000, days * 3_000)
    }

    private var lotteryBudgetRange: ClosedRange<Double> {
        budgetRange(forDays: Int(lotteryDurationDays))
    }

    /// 步长取「量程 ÷ 30」并吸附到 1/2/2.5/5×10ⁿ，任何天数下刻度都保持好看。
    private func budgetStep(forDays days: Int) -> Double {
        let range = budgetRange(forDays: days)
        let rawStep = (range.upperBound - range.lowerBound) / 30
        let magnitude = pow(10, floor(log10(rawStep)))
        let multiples = [1.0, 2.0, 2.5, 3.0, 5.0, 10.0].map { $0 * magnitude }
        return multiples.first(where: { $0 >= rawStep }) ?? 10 * magnitude
    }

    private var lotteryBudgetStep: Double {
        budgetStep(forDays: Int(lotteryDurationDays))
    }

    /// 结束抽签流程（回答完最后一问，或在最后一问点「跳过」）：把已收集的选择
    /// 作为上下文组成一条消息直接发给 Agent 对话接口，并恢复默认双方块入口。
    private func finishLottery() {
        let answers = lotteryAnswers
        withAnimation(.easeInOut(duration: 0.3)) {
            lotteryStepIndex = nil
            lotteryAnswers = []
        }
        let context = answers.map { String(format: String(localized: "lottery.contextFormat"), $0.key, $0.value) }.joined(separator: String(localized: "lottery.contextSeparator"))
        message = context.isEmpty
            ? String(localized: "lottery.randomMessage")
            : String(format: String(localized: "lottery.composedMessage"), context)
        send()
    }

    private var canSend: Bool {
        (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.session.attachments.isEmpty)
            && !runState.isGenerating
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

    private func scheduleStreamingScroll(_ proxy: ScrollViewProxy) {
        guard streamingScrollTask == nil else { return }
        streamingScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            proxy.scrollTo("conversation-bottom", anchor: .bottom)
            streamingScrollTask = nil
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
        // 回到欢迎页/新会话时地球恢复展开常驻，下一轮对话从顶部地球开始。
        isGlobeDocked = false
        didDockDuringGeneration = false
        welcomePeek = 0
        isWelcomePeekLocked = false
    }

    private func cancelGeneration() {
        runState.cancelGeneration()
        store.discardTurn()
    }

    private var remainingAttachmentSlots: Int {
        max(0, Self.maximumAttachmentCount - store.session.attachments.count)
    }

    private func presentCameraPicker() {
        guard reserveAttachmentSlot() else { return }
        guard AgentCameraController.isCameraAvailable else {
            runState.error = String(localized: "lottery.cameraUnavailable")
            return
        }
        isComposerFocused = false
        isShowingCameraPicker = true
    }

    private func presentPhotoPicker() {
        guard reserveAttachmentSlot() else { return }
        isComposerFocused = false
        isShowingPhotoPicker = true
    }

    private func presentDocumentPicker() {
        guard reserveAttachmentSlot() else { return }
        isComposerFocused = false
        isShowingDocumentPicker = true
    }

    private func reserveAttachmentSlot() -> Bool {
        guard remainingAttachmentSlots > 0 else {
            runState.error = String(format: String(localized: "lottery.maxAttachments"), Self.maximumAttachmentCount)
            return false
        }
        return true
    }

    private func loadPhotosPickerItems(_ items: [PhotosPickerItem]) {
        let accepted = Array(items.prefix(remainingAttachmentSlots))
        guard !accepted.isEmpty else { return }
        isProcessingAttachment = true
        Task {
            defer { isProcessingAttachment = false }
            for (index, item) in accepted.enumerated() {
                do {
                    guard let sourceData = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: sourceData) else {
                        throw AgentAttachmentError.unreadable
                    }
                    guard let data = image.jpegData(compressionQuality: 0.92) else {
                        throw AgentAttachmentError.unreadable
                    }
                    try await addImageAttachment(data, fileName: String(format: String(localized: "lottery.photoName"), index + 1))
                } catch {
                    runState.error = error.localizedDescription
                }
            }
            restoreComposerAfterPicking()
        }
    }

    private func loadCapturedImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.92) else {
            runState.error = AgentAttachmentError.unreadable.localizedDescription
            return
        }
        isProcessingAttachment = true
        Task {
            defer { isProcessingAttachment = false }
            do {
                try await addImageAttachment(data, fileName: String(localized: "lottery.capturedName"))
                restoreComposerAfterPicking()
            } catch {
                runState.error = error.localizedDescription
            }
        }
    }

    private func loadDocuments(_ urls: [URL]) {
        let accepted = Array(urls.prefix(remainingAttachmentSlots))
        guard !accepted.isEmpty else { return }
        isProcessingAttachment = true
        Task {
            defer { isProcessingAttachment = false }
            for url in accepted {
                do {
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        try AgentFileAttachmentProcessor.prepare(url)
                    }.value
                    store.addAttachment(.init(
                        id: UUID(),
                        mediaType: prepared.mediaType,
                        dataURI: prepared.dataURI,
                        fileName: prepared.fileName
                    ))
                } catch {
                    runState.error = error.localizedDescription
                }
            }
            restoreComposerAfterPicking()
        }
    }

    private func addImageAttachment(_ data: Data, fileName: String) async throws {
        let prepared = try await Task.detached(priority: .userInitiated) {
            try AgentImageAttachmentProcessor.prepare(data)
        }.value
        store.addAttachment(.init(
            id: UUID(),
            mediaType: prepared.mediaType,
            dataURI: prepared.dataURI,
            fileName: fileName
        ))
    }

    private func restoreComposerAfterPicking() {
        if presentation == .home {
            withAnimation(.snappy(duration: 0.25)) { isComposerExpanded = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isComposerFocused = true
        }
    }

    private func send(
        messageOverride: String? = nil,
        includePendingAttachments: Bool = true,
        appendUserMessage: Bool = true,
        automaticallyRepairIncompleteCandidates: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        let submittedMessage = messageOverride ?? (
            message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? String(localized: "lottery.analyzeMessage")
                : message
        )
        guard let request = makeRequest(
            message: submittedMessage,
            includePendingAttachments: includePendingAttachments
        ) else {
            runState.error = String(localized: "agent.errorSetup")
            completion?(false)
            return
        }
        // plan_new（无生效旅程或「暂不选择行程」）时 tripID 为 nil，服务端不强制本接口的旅程鉴权。
        let tripID = syncEngine.trip?.id
        let userMessage = AgentV2TurnRequest.Message(id: UUID(), role: "user", content: submittedMessage, createdAt: .now)
        store.beginTurn()
        if appendUserMessage {
            store.append(userMessage, consumingAttachments: request.attachments)
            acknowledgeInitialMessageSubmissionIfNeeded(userMessage.content)
            message = ""
        }
        runState.prepareForTurn()
        isComposerFocused = false
        let state = runState
        let sessionStore = store
        let client = APIClient()
        let generationID = runState.beginGeneration()
        let task = Task {
            var reconnectAttempt = 0
            var didComplete = false
            var lastEventID = 0
            var pendingQuestions: [String] = []

            while !Task.isCancelled, !didComplete {
                if reconnectAttempt > 0 {
                    state.prepareForReconnect(
                        attempt: reconnectAttempt,
                        maximumAttempts: AgentV2StreamRetryPolicy.maximumReconnectAttempts
                    )
                    do {
                        try await Task.sleep(for: .milliseconds(Int64(500 * reconnectAttempt)))
                    } catch {
                        break
                    }
                }

                do {
                    let stream = try await client.agentV2Stream(
                        request,
                        tripID: tripID,
                        afterEventID: lastEventID
                    )
                    for try await envelope in stream {
                        // A successful replay proves the connection recovered;
                        // only consecutive failures should consume the retry
                        // budget for this durable turn.
                        reconnectAttempt = 0
                        if let eventID = envelope.eventID {
                            lastEventID = max(lastEventID, eventID)
                        }
                        let event = envelope.event
                        switch event {
                        case .status(let text): state.status = text
                        case .reasoningSummary(let text): state.appendReasoningSummary(text)
                        case .assistantDelta(let text):
                            state.status = nil
                            state.appendStreamingReply(text)
                        case .cardBegin(let id, let index):
                            if !state.liveCards.contains(where: { $0.id == id }) { state.liveCards.append(.init(id: id, index: index)) }
                        case .cardFieldDelta(let id, let field, let value):
                            guard let index = state.liveCards.firstIndex(where: { $0.id == id }) else { break }
                            state.liveCards[index].fields[field] = value
                        case .question(let text):
                            pendingQuestions.append(text)
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
                            state.flushReasoningSummary()
                            state.flushStreamingReply()
                            for question in pendingQuestions {
                                sessionStore.append(.init(id: UUID(), role: "assistant", content: question, createdAt: .now))
                            }
                            let completedReply = state.streamingReply.isEmpty ? state.stagedSummaryText : state.streamingReply
                            if !completedReply.isEmpty {
                                sessionStore.append(.init(id: UUID(), role: "assistant", content: completedReply, createdAt: .now))
                                state.streamingReply = ""
                            }
                            sessionStore.completeTurn()
                            state.liveCards = []
                            didComplete = true
                        default: sessionStore.apply(event)
                        }
                        if didComplete { break }
                    }

                    if !didComplete, !Task.isCancelled {
                        throw AgentV2IncompleteStreamError()
                    }
                } catch is CancellationError {
                    break
                } catch {
                    guard AgentV2StreamRetryPolicy.shouldRetry(error),
                          reconnectAttempt < AgentV2StreamRetryPolicy.maximumReconnectAttempts else {
                        state.discardPartialResponse()
                        state.error = AgentV2StreamRetryPolicy.userMessage(for: error)
                        break
                    }
                    reconnectAttempt += 1
                }
            }
            sessionStore.discardTurn()
            state.liveCards = []
            state.stagedSummaryText = ""
            state.finishGeneration(id: generationID)
            if didComplete && automaticallyRepairIncompleteCandidates {
                repairIncompleteActionableCandidatesIfNeeded()
            }
            completion?(didComplete)
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

    private func makeRequest(
        message requestMessage: String,
        includePendingAttachments: Bool = true
    ) -> AgentV2TurnRequest? {
        let requestAttachments = includePendingAttachments ? store.session.attachments : []
        if plansNewTrip {
            return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "plan_new", message: requestMessage, trip: nil, preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: requestAttachments)
        }
        guard let trip = syncEngine.trip, trip.isConfigured else {
            // 无生效旅程：从零规划模式（plan_new）。服务端会产出待用户确认的
            // 旅程提案（trip_proposal），确认前不落库创建旅程。
            return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "plan_new", message: requestMessage, trip: nil, preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: requestAttachments)
        }
        let days = trip.days.map { day in
            AgentV2TurnRequest.Day(date: day.date, cards: day.cards.map { card in
                AgentV2TurnRequest.Card(id: card.serverID, kind: card.kind.rawValue, title: card.title, startAt: ISO8601DateFormatter().string(from: card.startAt), endAt: card.endAt.map { ISO8601DateFormatter().string(from: $0) }, place: card.place?.name, notes: card.notes)
            })
        }
        return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "itinerary", message: requestMessage, trip: .init(destination: trip.destination, startDate: trip.startDate, endDate: trip.endDate, currency: trip.currency, timeZone: TimeZone.current.identifier, version: trip.version, days: days), preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: requestAttachments)
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
            runState.error = String(localized: "agent.errorProposalDate")
            return
        }
        isCreatingTripFromProposal = true
        Task {
            let previousTripID = syncEngine.selectedTripID
            await syncEngine.createTrip(destination: proposal.destination, startDate: startDate, endDate: endDate, currency: proposal.currency)
            if let selectedTripID = syncEngine.selectedTripID,
               selectedTripID != previousTripID {
                store.clearPendingProposal()
                onNewTripCreated?()
            } else {
                runState.error = String(localized: "agent.errorCreateFailed")
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
            runState.error = String(localized: "agent.errorNoCandidates")
            return
        }
        guard snapshot.selected.allSatisfy(\.isCommitReady) else {
            // Defensive fallback for an old locally persisted draft. New and
            // repaired candidates cannot be selected until they are ready.
            let invalidIDs = Set(snapshot.selected.filter { !$0.isCommitReady }.map(\.id))
            store.setSelected(false, ids: invalidIDs)
            runState.status = String(localized: "agent.repairBeforeSelection")
            return
        }
        runState.isCommitting = true
        let client = APIClient()
        Task {
            do {
                let result = try await client.commitAgentV2(
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
                let removalCount = snapshot.draft.changes.filter {
                    $0.operation == .remove && $0.targetCardId != nil
                }.count
                let success = AgentCommitSuccess(
                    addedCount: result.committedCandidateIds.count,
                    removedCount: removalCount
                )
                if success.addedCount > 0 || success.removedCount > 0 {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) {
                        commitSuccess = success
                    }
                    UIAccessibility.post(notification: .announcement, argument: success.accessibilityText)
                    try? await Task.sleep(for: .milliseconds(720))
                }
                withAnimation(.snappy(duration: 0.42)) {
                    store.completeCommit(committedCandidateIDs: Set(result.committedCandidateIds))
                }
                if !(result.retryCandidateIds ?? []).isEmpty {
                    runState.status = String(localized: "agent.commitRetryRetained")
                }
                await syncEngine.refresh()
                if commitSuccess != nil {
                    try? await Task.sleep(for: .milliseconds(900))
                    withAnimation(.easeOut(duration: 0.24)) {
                        commitSuccess = nil
                    }
                }
            } catch {
                runState.error = error.localizedDescription
            }
            runState.isCommitting = false
        }
    }

    private func selectAllCandidates(_ candidates: [AgentV2Candidate], selected: Bool) {
        let readyIDs = Set(candidates.filter(\.isCommitReady).map(\.id))
        store.setSelected(selected, ids: readyIDs)
    }

    private func repairIncompleteActionableCandidatesIfNeeded() {
        guard syncEngine.trip?.isConfigured == true,
              !runState.isGenerating,
              repairingCandidateIDs.isEmpty,
              let draft = store.session.draft else { return }
        let actionableIDs = draft.actionableCandidateIDs
        let candidates = draft.candidates.filter {
            actionableIDs.contains($0.id) && !$0.isCommitReady
        }
        guard !candidates.isEmpty else { return }
        let repairIDs = Set(candidates.map(\.id))
        repairingCandidateIDs = repairIDs
        send(
            messageOverride: AgentV2CommitRepairRequest.message(for: candidates),
            includePendingAttachments: false,
            appendUserMessage: false,
            automaticallyRepairIncompleteCandidates: false
        ) { completed in
            defer { repairingCandidateIDs = [] }
            guard completed, let draft = store.session.draft else {
                runState.error = String(localized: "agent.errorRepairFailed")
                return
            }
            var replacementsByTarget: [UUID: UUID] = [:]
            for change in draft.changes {
                guard let targetID = change.targetDraftId,
                      repairIDs.contains(targetID),
                      let candidateID = change.candidateId else { continue }
                replacementsByTarget[targetID] = candidateID
            }
            let candidatesByID = Dictionary(uniqueKeysWithValues: draft.candidates.map { ($0.id, $0) })
            let repairedIDs = Set(repairIDs.compactMap { originalID -> UUID? in
                let resultingID = replacementsByTarget[originalID] ?? originalID
                return candidatesByID[resultingID]?.isCommitReady == true ? resultingID : nil
            })
            guard repairedIDs.count == repairIDs.count else {
                runState.error = String(localized: "agent.errorRepairFailed")
                return
            }
            runState.status = String(localized: "agent.repairComplete")
        }
        // send() seeds the ordinary “understanding” status while preparing a
        // turn; replace it with the more precise repair state for this flow.
        runState.status = String(localized: "agent.repairingSelection")
    }
}

private struct AgentCommitSuccess: Equatable {
    let addedCount: Int
    let removedCount: Int

    var title: String {
        addedCount > 0 ? String(localized: "agent.commitAdded") : String(localized: "agent.commitUpdated")
    }

    var detail: String {
        if addedCount > 0 {
            return String(format: String(localized: "agent.commitSuccessCount"), addedCount)
        }
        return String(localized: "agent.commitRemovalSuccess")
    }

    var accessibilityText: String { "\(title)，\(detail)" }
}

private struct AgentCommitSuccessHUD: View {
    let success: AgentCommitSuccess
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(PrimaryTabPalette.accent.opacity(0.14))
                    .frame(width: 72, height: 72)
                    .scaleEffect(revealed ? 1 : 0.55)
                Circle()
                    .stroke(PrimaryTabPalette.accent.opacity(0.45), lineWidth: 1.5)
                    .frame(width: 58, height: 58)
                    .scaleEffect(revealed ? 1 : 1.35)
                    .opacity(revealed ? 1 : 0)
                Image(systemName: "checkmark")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: 46, height: 46)
                    .background(PrimaryTabPalette.accent, in: Circle())
                    .scaleEffect(revealed ? 1 : 0.35)
            }

            VStack(spacing: 4) {
                Text(success.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(success.detail)
                    .font(.caption)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.42), radius: 28, y: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(success.accessibilityText)
        .onAppear {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.66).delay(0.05)) {
                revealed = true
            }
        }
    }
}

/// 一次泊入飞行的起终点（页面坐标系矩形）与两端状态快照：heroState 是
/// 起飞瞬间英雄位上的内容（思考 orb，或再次泊入时的地球），orbState 是
/// 降落端思考 icon 对应的状态。
private struct AgentGlobeDockFlight: Equatable {
    let from: CGRect
    let to: CGRect
    let heroState: OrbState?
    let orbState: OrbState
}

/// 泊入飞行动画：一枚图标从顶部英雄位飞往状态行泊位。起飞时是英雄位上
/// 的橙色 ASCII 思考 orb/地球（同一渲染器，无缝接棒），飞行途中与白色
/// ThinkingOrb 交叉淡变（呼应「移动并变白」），并按起终点尺寸等比缩放；
/// 落地后回调，由泊位里的常驻 icon 淡入接管。
private struct AgentGlobeDockFlightView: View {
    let flight: AgentGlobeDockFlight
    let onFinished: () -> Void

    @State private var landed = false

    var body: some View {
        ZStack {
            AgentHeroGlobeView(thinkingState: flight.heroState, diameter: flight.from.width)
                .opacity(landed ? 0 : 1)
            ThinkingOrb(state: flight.orbState, size: .px64, theme: .dark, displaySize: flight.from.width)
                .opacity(landed ? 1 : 0)
        }
        .scaleEffect(landed ? flight.to.width / flight.from.width : 1)
        .position(x: landed ? flight.to.midX : flight.from.midX, y: landed ? flight.to.midY : flight.from.midY)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { landed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { onFinished() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 底部两个入口方块的玻璃底：iOS 26 原生 Liquid Glass（``glassEffect``）。
/// 用 `.clear` 变体（大面积背景玻璃，边缘镜面比 `.regular` 弱很多），
/// 折射边缘、高光与模糊全部由系统渲染，实时折射底下的 ASCII 底纹和光晕。
private struct AgentEntryGlassTile: View {
    var body: some View {
        Color.clear
            .glassEffect(.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// 「拈签定缘」滑动条作答面板（天数/预算两问）：大号数值 + 自定义滑动条 +
/// 确认按钮，玻璃底与入口方块一致；整体宽高比也对齐双方块入口的高度节奏。
private struct AgentLotterySliderPanel: View {
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double
    let minLabel: String
    let maxLabel: String
    let buttonTitle: String
    let accessibilityLabel: String
    let onConfirm: () -> Void
    let format: (Double) -> (number: String, unit: String)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(format(value).number)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(format(value).unit)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 6)

            AgentLotterySlider(
                range: range,
                step: step,
                value: $value,
                accessibilityLabel: accessibilityLabel,
                format: { format($0).number + format($0).unit }
            )

            HStack {
                Text(minLabel)
                Spacer()
                Text(maxLabel)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(PrimaryTabPalette.tertiaryText)
            .padding(.top, 6)

            HStack {
                Spacer()
                Button(action: onConfirm) {
                    Text(buttonTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 18)
                        .frame(height: 36)
                        .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(buttonTitle)
            }
            .padding(.top, 10)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .aspectRatio(1.78, contentMode: .fit)
        .background { AgentEntryGlassTile() }
    }
}

/// 自定义滑动条：纯色已选轨道 + 白色圆形拇指，按步长吸附；数值变化时
/// 触发轻微触感反馈，支持 VoiceOver 增减调节。
private struct AgentLotterySlider: View {
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double
    let accessibilityLabel: String
    let format: (Double) -> String

    @State private var haptic: UIImpactFeedbackGenerator?

    private static let trackHeight: CGFloat = 6
    private static let thumbSize: CGFloat = 24

    var body: some View {
        GeometryReader { proxy in
            let thumbSize = Self.thumbSize
            let usableWidth = max(1, proxy.size.width - thumbSize)
            let span = range.upperBound - range.lowerBound
            let fraction = min(1, max(0, (value - range.lowerBound) / span))
            let thumbCenter = thumbSize / 2 + usableWidth * CGFloat(fraction)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: Self.trackHeight)
                Capsule()
                    .fill(PrimaryTabPalette.accent)
                    .frame(width: thumbCenter, height: Self.trackHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.38), radius: 4, y: 2)
                    .overlay(Circle().stroke(PrimaryTabPalette.accent.opacity(0.3), lineWidth: 1))
                    .offset(x: thumbCenter - thumbSize / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let raw = (gesture.location.x - thumbSize / 2) / usableWidth
                        let clamped = min(1, max(0, raw))
                        let snapped = ((range.lowerBound + Double(clamped) * span) / step)
                            .rounded() * step
                        let newValue = min(range.upperBound, max(range.lowerBound, snapped))
                        guard abs(newValue - value) > 0.001 else { return }
                        value = newValue
                        haptic?.impactOccurred()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(format(value))
            .accessibilityAdjustableAction { direction in
                let delta: Double = direction == .increment ? step : -step
                let adjusted = min(range.upperBound, max(range.lowerBound, value + delta))
                guard adjusted != value else { return }
                value = adjusted
                haptic?.impactOccurred()
            }
        }
        .frame(height: 34)
        .onAppear {
            if haptic == nil { haptic = UIImpactFeedbackGenerator(style: .light) }
        }
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
                        "agent.historyEmptyTitle",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("agent.historyEmptyDesc")
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
                                        Text(AgentHistoryRelativeTime.display(for: archived.updatedAt))
                                        Text(String(format: String(localized: "agent.messageCount"), archived.messages.count))
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
                                    Label("common.delete", systemImage: "trash")
                                }
                            }
                            .accessibilityLabel(Text(String(format: String(localized: "agent.restoreConversationA11y"), title(for: archived))))
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("agent.historyTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("common.done") { dismiss() }
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
        return trimmed.isEmpty ? String(localized: "common.unnamedConversation") : String(trimmed.prefix(40))
    }
}

/// 历史会话只展示一个中文时间层级，避免系统相对时间显示「18 hr 22 min」这类组合文案。
enum AgentHistoryRelativeTime {
    static func display(for date: Date, now: Date = .now) -> String {
        let elapsedSeconds = max(0, now.timeIntervalSince(date))
        let elapsedMinutes = Int(elapsedSeconds / 60)

        guard elapsedMinutes >= 1 else { return String(localized: "agent.justNow") }
        if elapsedMinutes < 60 { return String(format: String(localized: "agent.minutesAgo"), elapsedMinutes) }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 { return String(format: String(localized: "agent.hoursAgo"), elapsedHours) }

        let elapsedDays = elapsedHours / 24
        if elapsedDays < 7 { return String(format: String(localized: "agent.daysAgo"), chineseCount(elapsedDays)) }

        let elapsedWeeks = elapsedDays / 7
        if elapsedDays < 30 { return String(format: String(localized: "agent.weeksAgo"), chineseCount(elapsedWeeks)) }

        let elapsedMonths = elapsedDays / 30
        if elapsedMonths < 12 { return String(format: String(localized: "agent.monthsAgo"), chineseCount(elapsedMonths)) }

        return String(format: String(localized: "agent.yearsAgo"), chineseCount(elapsedDays / 365))
    }

    private static func chineseCount(_ value: Int) -> String {
        if value == 2 { return String(localized: "agent.numberWordTwo") }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct ChatMessageView: View {
    let message: AgentV2TurnRequest.Message
    let attachments: [AgentV2TurnRequest.Attachment]

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 54)
                VStack(alignment: .trailing, spacing: 8) {
                    if !attachments.isEmpty {
                        AgentSentAttachmentStrip(attachments: attachments)
                    }
                    if !message.content.isEmpty {
                        Text(message.content)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 11)
                            .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    }
                }
            }
        } else {
            AssistantMessageContainer {
                Text(message.content)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Continuous edge-mask state for the composer attachment scroller. The
/// smoothstep curve gives both ends zero velocity, so masks ease in/out during
/// the final few points of a drag instead of popping at an edge threshold.
struct AgentAttachmentEdgeFade: Equatable {
    static let maskWidth: CGFloat = 34
    static let hidden = AgentAttachmentEdgeFade(leading: 0, trailing: 0)

    let leading: CGFloat
    let trailing: CGFloat

    static func resolve(
        offset: CGFloat,
        contentWidth: CGFloat,
        containerWidth: CGFloat,
        easingDistance: CGFloat = maskWidth
    ) -> AgentAttachmentEdgeFade {
        let maximumOffset = max(0, contentWidth - containerWidth)
        guard maximumOffset > 0.5, easingDistance > 0 else { return .hidden }

        return AgentAttachmentEdgeFade(
            leading: smoothstep(max(0, offset) / easingDistance),
            trailing: smoothstep(max(0, maximumOffset - offset) / easingDistance)
        )
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }
}

/// 助手消息容器：左侧不再显示橘色 Agent 头像，内容通栏靠左展示。
private struct AssistantMessageContainer<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
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
            return String(format: String(localized: "agent.titleChip"), title, term)
        case .completed(let ok, let count):
            if ok, let count {
                return String(format: String(localized: "agent.flightResults"), count)
            }
            return String(localized: "agent.flightUnavailable")
        }
    }
}

struct AgentV2LiveCandidateCard: View {
    let card: AgentV2LiveCard

    @ViewBuilder
    var body: some View {
        if card.kind == .flight {
            AgentLiveFlightCandidateCard(card: card)
        } else {
            AgentLivePlaceCandidateCard(card: card)
        }
    }
}

private struct AgentLivePlaceCandidateCard: View {
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
            Text("agent.verifyingBadge").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
        }
        .padding(12)
        .primaryTabCardStyle(color: PrimaryTabPalette.elevatedSurface, cornerRadius: 15)
    }
}

private struct AgentLiveFlightCandidateCard: View {
    let card: AgentV2LiveCard

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            route

            Label("agent.organizingFlightBadge", systemImage: "clock.arrow.circlepath")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(PrimaryTabPalette.accent)
        }
        .padding(16)
        .background {
            LinearGradient(
                colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.065, green: 0.095, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            AirlineLogoBadge(logoURL: card.airlineLogoImageURL)

            VStack(alignment: .leading, spacing: 3) {
                Text(card.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(nonEmpty(card.fields["bookingCode"]) ?? String(localized: "agent.flightNumberPending"))
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }

            Spacer(minLength: 8)
            ProgressView()
                .controlSize(.mini)
                .tint(PrimaryTabPalette.secondaryText)
        }
    }

    private var route: some View {
        HStack(alignment: .center, spacing: 12) {
            airportBlock(
                code: airportCode(card.fields["fromAirport"]),
                name: card.fields["fromAirport"],
                time: card.fields["startAt"],
                alignment: .leading
            )

            VStack(spacing: 7) {
                Image(systemName: "airplane")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PrimaryTabPalette.accent)
                HStack(spacing: 4) {
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                }
                Text(nonEmpty(card.fields["date"]) ?? String(localized: "agent.datePending"))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            airportBlock(
                code: airportCode(card.fields["toAirport"]),
                name: card.fields["toAirport"],
                time: card.fields["endAt"],
                alignment: .trailing
            )
        }
    }

    private func airportBlock(code: String, name: String?, time: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(code)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(nonEmpty(name) ?? String(localized: "agent.airportPending"))
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(nonEmpty(time) ?? String(localized: "agent.timePending"))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func airportCode(_ value: String?) -> String {
        AgentFlightDisplay.airportCode(value)
    }
}

struct AgentMissingCandidateCard: View {
    let change: AgentV2Change

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 38, height: 38)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 5) {
                Text(change.summary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text("agent.missingCandidateMessage")
                    .font(.caption)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.orange.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.orange.opacity(0.28), lineWidth: 1) }
        .accessibilityElement(children: .combine)
    }
}

struct AgentV2CandidateCard: View {
    let candidate: AgentV2Candidate
    var isSelectable = true
    let selection: (Bool) -> Void
    @State private var imageIndex = 0
    @State private var isShowingDetails = false

    @ViewBuilder
    var body: some View {
        if candidate.kind == .flight {
            AgentFlightCandidateCard(candidate: candidate, isSelectable: isSelectable, selection: selection)
        } else {
            standardCard
        }
    }

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !imageURLs.isEmpty {
                AgentCandidateImagePager(
                    urls: imageURLs,
                    selection: $imageIndex,
                    height: candidate.showLargeImage ? 248 : 174
                )
                    .overlay(alignment: .topLeading) {
                        Label(candidate.kind.agentTitle, systemImage: candidate.kind.agentSymbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(12)
                    }
            }

            VStack(alignment: .leading, spacing: 11) {
                if imageURLs.isEmpty {
                    HStack(alignment: .firstTextBaseline) {
                        Label(candidate.kind.agentTitle, systemImage: candidate.kind.agentSymbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(PrimaryTabPalette.accent)
                        Spacer()
                        if !candidate.startAt.isEmpty {
                            Text(candidate.startAt)
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                        }
                    }
                }

                Text(candidate.title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                if !scheduleLine.isEmpty {
                    Label(scheduleLine, systemImage: "calendar")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                }

                if let reason = candidate.reason, !reason.isEmpty {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 8) {
                    statusBadge
                    if let priceText {
                        Label(priceText, systemImage: isRealtimePrice ? "clock.arrow.circlepath" : "banknote")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(Color.orange.opacity(0.12), in: Capsule())
                    }
                }

                if let risk = candidate.risks.first, !risk.isEmpty {
                    Label(risk, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }

                if !candidate.missingFields.isEmpty {
                    Label(candidate.missingFields.joined(separator: " · "), systemImage: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(3)
                }

                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 10) {
                    if isSelectable {
                        Button {
                            selection(!candidate.selected)
                        } label: {
                            Label(candidate.selected ? String(localized: "agent.selectedButton") : String(localized: "agent.joinTrip"), systemImage: candidate.selected ? "checkmark.circle.fill" : "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(candidate.selected ? .black : .white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(
                                    candidate.selected ? PrimaryTabPalette.accent : Color.white.opacity(0.10),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    Button { isShowingDetails = true } label: {
                        HStack(spacing: 5) {
                            Text("agent.viewDetails")
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .background(candidate.selected ? PrimaryTabPalette.accent.opacity(0.12) : PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(candidate.selected ? PrimaryTabPalette.accent.opacity(0.72) : Color.white.opacity(0.07), lineWidth: candidate.selected ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
        .sheet(isPresented: $isShowingDetails) {
            AgentCandidatePOIDetailSheet(candidate: candidate, isSelectable: isSelectable, selection: selection)
                .presentationDetents([.fraction(0.78), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
                .presentationBackground(PrimaryTabPalette.background)
        }
        .accessibilityElement(children: .contain)
    }

    private var imageURLs: [URL] {
        candidate.images.compactMap(CardImageURL.resolve)
    }

    private var scheduleLine: String {
        [candidate.date, candidate.startAt, candidate.place?.name]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " · ")
    }

    private var statusBadge: some View {
        HStack(spacing: 5) {
            Image(systemName: candidate.placeStatus == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
            Text(candidate.placeStatus.title)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(candidate.placeStatus == .verified ? Color.green : Color.orange)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background((candidate.placeStatus == .verified ? Color.green : Color.orange).opacity(0.12), in: Capsule())
    }

    private var priceText: String? {
        candidate.agentPriceText
    }

    private var isRealtimePrice: Bool {
        candidate.priceMinor == nil && priceText != nil
    }
}

private struct AgentFlightCandidateCard: View {
    let candidate: AgentV2Candidate
    let isSelectable: Bool
    let selection: (Bool) -> Void
    @State private var isShowingDetails = false

    var body: some View {
        VStack(spacing: 0) {
            Button { isShowingDetails = true } label: {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    route

                    if !candidate.missingFields.isEmpty {
                        Label(candidate.missingFields.joined(separator: " · "), systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .lineLimit(3)
                    }
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            ticketDivider

            HStack(spacing: 10) {
                if isSelectable {
                    Button {
                        selection(!candidate.selected)
                    } label: {
                        Label(
                            candidate.selected ? String(localized: "agent.selectedButton") : String(localized: "agent.joinTrip"),
                            systemImage: candidate.selected ? "checkmark.circle.fill" : "plus.circle.fill"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(candidate.selected ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(
                            candidate.selected ? PrimaryTabPalette.accent : Color.white.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }

                Button { isShowingDetails = true } label: {
                    Label("agent.flightDetails", systemImage: "arrow.up.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .background {
            LinearGradient(
                colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.065, green: 0.095, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(candidate.selected ? PrimaryTabPalette.accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: candidate.selected ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, y: 9)
        .animation(.snappy(duration: 0.28), value: candidate.selected)
        .sheet(isPresented: $isShowingDetails) {
            AgentFlightDetailSheet(candidate: candidate, isSelectable: isSelectable, selection: selection)
                .presentationDetents([.fraction(0.72), .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(30)
                .presentationBackground(PrimaryTabPalette.background)
        }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 10) {
                AirlineLogoBadge(logoURL: candidate.airlineLogoImageURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(candidate.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(nonEmpty(candidate.bookingCode) ?? String(localized: "agent.flightNumberPending"))
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
            }
            Spacer(minLength: 8)
            if let price = candidate.agentPriceText {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("agent.ticketPrice")
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    Text(price)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var route: some View {
        HStack(alignment: .center, spacing: 12) {
            airportBlock(code: airportCode(candidate.fromAirport), name: candidate.fromAirport, alignment: .leading)
            VStack(spacing: 7) {
                Image(systemName: "airplane")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PrimaryTabPalette.accent)
                HStack(spacing: 4) {
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                }
                Text(candidate.date.isEmpty ? String(localized: "agent.datePending") : candidate.date)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            airportBlock(code: airportCode(candidate.toAirport), name: candidate.toAirport, alignment: .trailing)
        }
    }

    private func airportBlock(code: String, name: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(code)
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(nonEmpty(name) ?? String(localized: "agent.airportPending"))
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(alignment == .leading ? departureTime : arrivalTime)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.86))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var ticketDivider: some View {
        HStack(spacing: 6) {
            ForEach(0..<20, id: \.self) { _ in
                Capsule().fill(Color.white.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) {
            Circle().fill(PrimaryTabPalette.background).frame(width: 18, height: 18).offset(x: -9)
        }
        .overlay(alignment: .trailing) {
            Circle().fill(PrimaryTabPalette.background).frame(width: 18, height: 18).offset(x: 9)
        }
    }

    private var departureTime: String { candidate.startAt.isEmpty ? String(localized: "agent.timePending") : candidate.startAt }
    private var arrivalTime: String { nonEmpty(candidate.endAt) ?? String(localized: "agent.timePending") }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func airportCode(_ value: String?) -> String {
        AgentFlightDisplay.airportCode(value)
    }
}

private struct AgentFlightDetailSheet: View {
    let candidate: AgentV2Candidate
    let isSelectable: Bool
    let selection: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                flightHero
                infoGrid

                if !candidate.tips.isEmpty {
                    section(title: String(localized: "agent.sectionTips"), icon: "lightbulb.fill") {
                        bulletList(candidate.tips, tint: PrimaryTabPalette.accent)
                    }
                }
                if !candidate.risks.isEmpty {
                    section(title: String(localized: "agent.sectionNotice"), icon: "exclamationmark.triangle.fill", tint: .orange) {
                        bulletList(candidate.risks, tint: .orange)
                    }
                }
                if !candidate.missingFields.isEmpty {
                    section(title: String(localized: "agent.needsConfirmation"), icon: "questionmark.circle.fill", tint: .orange) {
                        bulletList(candidate.missingFields, tint: .orange)
                    }
                }
                if let notes = candidate.notes, !notes.isEmpty {
                    section(title: String(localized: "agent.sectionExtra"), icon: "note.text") { Text(notes) }
                }
                if !displaySources.isEmpty {
                    section(title: String(localized: "agent.sectionSources"), icon: "link") {
                        VStack(spacing: 0) {
                            ForEach(Array(displaySources.enumerated()), id: \.element.id) { index, source in
                                if let url = URL(string: source.url) {
                                    Link(destination: url) {
                                        HStack(spacing: 12) {
                                            Image(systemName: sourceIcon(source))
                                                .foregroundStyle(PrimaryTabPalette.accent)
                                                .frame(width: 28)
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(sourceTitle(source))
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                if let author = source.author, !author.isEmpty {
                                                    Text(author)
                                                        .font(.caption)
                                                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                        }
                                        .padding(.vertical, 10)
                                        .contentShape(Rectangle())
                                    }
                                    if index < displaySources.count - 1 {
                                        Divider().overlay(Color.white.opacity(0.08))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 108)
        }
        .scrollIndicators(.hidden)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectable {
                VStack(spacing: 0) {
                    Divider().overlay(Color.white.opacity(0.08))
                    Button { selection(!candidate.selected) } label: {
                        Label(
                            candidate.selected ? String(localized: "agent.selectedTapToCancel") : String(localized: "agent.selectForTrip"),
                            systemImage: candidate.selected ? "checkmark.circle.fill" : "plus.circle.fill"
                        )
                        .font(.headline)
                        .foregroundStyle(candidate.selected ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                        .background(candidate.selected ? Color.white : PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                }
                .background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(18)
        }
        .preferredColorScheme(.dark)
    }

    private var flightHero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label("agent.kind.flight", systemImage: "airplane")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(PrimaryTabPalette.accent, in: Capsule())
                Spacer()
                if let logoURL = candidate.airlineLogoImageURL {
                    AirlineLogoBadge(logoURL: logoURL)
                }
                if let price = candidate.agentPriceText {
                    Text(price).font(.headline.monospacedDigit()).foregroundStyle(.white)
                }
            }
            Text(candidate.title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            HStack {
                endpoint(candidate.fromAirport, icon: "airplane.departure", alignment: .leading)
                Image(systemName: "arrow.right")
                    .foregroundStyle(PrimaryTabPalette.accent)
                    .frame(maxWidth: .infinity)
                endpoint(candidate.toAirport, icon: "airplane.arrival", alignment: .trailing)
            }
        }
        .padding(18)
        .background(
            LinearGradient(colors: [PrimaryTabPalette.accent.opacity(0.24), PrimaryTabPalette.elevatedSurface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay { RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1) }
    }

    private func endpoint(_ value: String?, icon: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Image(systemName: icon).foregroundStyle(PrimaryTabPalette.secondaryText)
            Text(nonEmpty(value) ?? String(localized: "agent.airportPending"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var infoGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            infoCell(String(localized: "agent.flightNumber"), candidate.bookingCode ?? String(localized: "agent.valueUnset"), "number")
            infoCell(String(localized: "agent.flightDate"), candidate.date.isEmpty ? String(localized: "agent.valueUnset") : candidate.date, "calendar")
            infoCell(String(localized: "agent.departureTime"), candidate.startAt.isEmpty ? String(localized: "agent.valueUnset") : candidate.startAt, "airplane.departure")
            infoCell(String(localized: "agent.arrivalTime"), nonEmpty(candidate.endAt) ?? String(localized: "agent.valueUnset"), "airplane.arrival")
        }
    }

    private func infoCell(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(PrimaryTabPalette.secondaryText)
            Text(value).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func section<Content: View>(title: String, icon: String, tint: Color = PrimaryTabPalette.accent, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(tint)
            content().font(.body).foregroundStyle(.white.opacity(0.84)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func bulletList(_ values: [String], tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(values, id: \.self) { value in
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(tint).frame(width: 5, height: 5).padding(.top, 7)
                    Text(value)
                }
            }
        }
    }

    private var displaySources: [AgentV2Source] {
        var seen = Set<String>()
        let sources = candidate.sources.filter { source in
            guard let url = URL(string: source.url),
                  url.scheme?.lowercased() == "https",
                  seen.insert(source.url).inserted else { return false }
            return true
        }
        if !sources.isEmpty { return sources }
        guard let value = candidate.url,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https" else { return [] }
        return [AgentV2Source(provider: sourceProvider(url), url: value, title: nil, author: nil, sourceProof: candidate.sourceProof)]
    }

    private func sourceTitle(_ source: AgentV2Source) -> String {
        if let title = source.title, !title.isEmpty { return title }
        switch source.provider.lowercased() {
        case "xiaohongshu": return String(localized: "agent.viewXhsNote")
        case "fliggy": return String(localized: "agent.viewBookingFliggy")
        default: return String(localized: "agent.openReference")
        }
    }

    private func sourceIcon(_ source: AgentV2Source) -> String {
        switch source.provider.lowercased() {
        case "xiaohongshu": return "book.pages"
        case "fliggy": return "airplane"
        default: return "safari"
        }
    }

    private func sourceProvider(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "xiaohongshu" }
        if host.contains("fliggy") || host.contains("alitrip") { return "fliggy" }
        return "web"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct AgentCandidateImagePager: View {
    let urls: [URL]
    @Binding var selection: Int
    let height: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            TabView(selection: $selection) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        case .failure:
                            placeholder(icon: "photo.badge.exclamationmark")
                        case .empty:
                            ZStack {
                                placeholder(icon: "photo")
                                ProgressView().tint(.white.opacity(0.8))
                            }
                        @unknown default:
                            placeholder(icon: "photo")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: height)

            LinearGradient(colors: [.clear, .black.opacity(0.48)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            if urls.count > 1 {
                Text(String(format: String(localized: "agent.pagerFormat"), selection + 1, urls.count))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(12)
                    .accessibilityLabel(Text(String(format: String(localized: "agent.pagerA11y"), selection + 1, urls.count)))
            }
        }
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [PrimaryTabPalette.accent.opacity(0.34), PrimaryTabPalette.elevatedSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.52))
        }
    }
}

private struct AgentCandidatePOIDetailSheet: View {
    let candidate: AgentV2Candidate
    let isSelectable: Bool
    let selection: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var imageIndex = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                hero
                titleBlock

                if let description = candidate.description, !description.isEmpty {
                    detailSection(title: String(localized: "agent.sectionIntro"), icon: "text.alignleft") {
                        Text(description)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let place = candidate.place {
                    locationSection(place)
                }

                if let reason = candidate.reason, !reason.isEmpty {
                    detailSection(title: String(localized: "agent.sectionReason"), icon: "sparkles") {
                        Text(reason)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !candidate.risks.isEmpty {
                    detailSection(title: String(localized: "agent.sectionNotice"), icon: "exclamationmark.triangle.fill", tint: .orange) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(candidate.risks, id: \.self) { risk in
                                bullet(risk, color: .orange)
                            }
                        }
                    }
                }

                if !candidate.tips.isEmpty {
                    detailSection(title: String(localized: "agent.sectionTips"), icon: "lightbulb.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(candidate.tips, id: \.self) { tip in
                                bullet(tip, color: PrimaryTabPalette.accent)
                            }
                        }
                    }
                }

                if let notes = candidate.notes, !notes.isEmpty {
                    detailSection(title: String(localized: "agent.sectionExtra"), icon: "note.text") {
                        Text(notes)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !displaySources.isEmpty {
                    detailSection(title: String(localized: "agent.sectionSources"), icon: "link") {
                        VStack(spacing: 0) {
                            ForEach(Array(displaySources.enumerated()), id: \.element.id) { index, source in
                                if let url = URL(string: source.url) {
                                    Link(destination: url) {
                                        HStack(spacing: 12) {
                                            Image(systemName: sourceIcon(for: url))
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(PrimaryTabPalette.accent)
                                                .frame(width: 36, height: 36)
                                                .background(PrimaryTabPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(sourceTitle(source, url: url))
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .lineLimit(2)
                                                if let author = source.author, !author.isEmpty {
                                                    Text(author)
                                                        .font(.caption)
                                                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                                                        .lineLimit(1)
                                                }
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                        }
                                        .padding(.vertical, 11)
                                        .contentShape(Rectangle())
                                    }
                                    if index < displaySources.count - 1 {
                                        Divider().overlay(Color.white.opacity(0.08))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 112)
        }
        .scrollIndicators(.hidden)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelectable {
                selectionBar
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.62), in: Circle())
                    .overlay { Circle().stroke(Color.white.opacity(0.12), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .padding(.trailing, 18)
            .accessibilityLabel(Text("agent.closeDetailsA11y"))
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var hero: some View {
        if imageURLs.isEmpty {
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [PrimaryTabPalette.accent.opacity(0.38), PrimaryTabPalette.elevatedSurface],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: candidate.kind.agentSymbol)
                    .font(.system(size: 62, weight: .thin))
                    .foregroundStyle(.white.opacity(0.22))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(24)
                Label(candidate.kind.agentTitle, systemImage: candidate.kind.agentSymbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.42), in: Capsule())
                    .padding(16)
            }
            .frame(height: 144)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        } else {
            AgentCandidateImagePager(urls: imageURLs, selection: $imageIndex, height: 252)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(candidate.title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            if !scheduleLine.isEmpty {
                Label(scheduleLine, systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }

            HStack(spacing: 8) {
                Label(candidate.placeStatus.title, systemImage: candidate.placeStatus == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(candidate.placeStatus == .verified ? Color.green : Color.orange)
                if let price = candidate.agentPriceText {
                    Label(price, systemImage: "banknote")
                        .foregroundStyle(.orange)
                }
                if let duration = candidate.stayDurationMinutes {
                    Label(String(format: String(localized: "agent.durationMinutes"), duration), systemImage: "clock")
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func locationSection(_ place: AIChatPlace) -> some View {
        detailSection(title: String(localized: "agent.sectionPlace"), icon: "mappin.and.ellipse") {
            Button {
                if let mapsURL { openURL(mapsURL) }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "map.fill")
                        .font(.title3)
                        .foregroundStyle(PrimaryTabPalette.accent)
                        .frame(width: 42, height: 42)
                        .background(PrimaryTabPalette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if let address = place.address, !address.isEmpty {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                .padding(14)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(mapsURL == nil)
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.white.opacity(0.08))
            Button {
                selection(!candidate.selected)
            } label: {
                HStack {
                    Image(systemName: candidate.selected ? "checkmark.circle.fill" : "plus.circle.fill")
                    Text(candidate.selected ? String(localized: "agent.selectedTapToCancel") : String(localized: "agent.selectForTrip"))
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .foregroundStyle(candidate.selected ? .black : .white)
                .padding(.horizontal, 18)
                .frame(height: 56)
                .background(candidate.selected ? Color.white : PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .background(.ultraThinMaterial)
    }

    private func detailSection<Content: View>(
        title: String,
        icon: String,
        tint: Color = PrimaryTabPalette.accent,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
                .foregroundStyle(tint)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.055), lineWidth: 1) }
    }

    private func bullet(_ text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .padding(.top, 7)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var imageURLs: [URL] {
        candidate.images.compactMap(CardImageURL.resolve)
    }

    private var scheduleLine: String {
        let time = [candidate.startAt, candidate.endAt ?? ""].filter { !$0.isEmpty }.joined(separator: "–")
        return [candidate.date, time].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var displaySources: [AgentV2Source] {
        var seen = Set<String>()
        let sources = candidate.sources.filter { source in
            guard let url = URL(string: source.url),
                  url.scheme?.lowercased() == "https",
                  seen.insert(source.url).inserted else { return false }
            return true
        }
        if !sources.isEmpty { return sources }
        guard let value = candidate.url,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https" else { return [] }
        return [AgentV2Source(provider: sourceProvider(for: url), url: value, title: nil, author: nil, sourceProof: candidate.sourceProof)]
    }

    private func sourceTitle(_ source: AgentV2Source, url: URL) -> String {
        if let title = source.title, !title.isEmpty { return title }
        return sourceLabel(for: url)
    }

    private func sourceLabel(for url: URL) -> String {
        guard let host = url.host?.lowercased() else { return String(localized: "agent.openReference") }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return String(localized: "agent.viewXhsNote") }
        if host.contains("fliggy") || host.contains("alitrip") { return String(localized: "agent.viewBookingFliggy") }
        return String(localized: "agent.openReference")
    }

    private func sourceIcon(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "book.pages" }
        if host.contains("fliggy") || host.contains("alitrip") { return "airplane" }
        return "safari"
    }

    private func sourceProvider(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "xiaohongshu" }
        if host.contains("fliggy") || host.contains("alitrip") { return "fliggy" }
        return "web"
    }

    private var mapsURL: URL? {
        guard let place = candidate.place else { return nil }
        var components = URLComponents(string: "https://maps.apple.com/")
        var items = [URLQueryItem(name: "q", value: place.name)]
        if let latitude = place.latitude, let longitude = place.longitude {
            items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
        } else if let address = place.address, !address.isEmpty {
            items.append(URLQueryItem(name: "address", value: address))
        }
        components?.queryItems = items
        return components?.url
    }
}

private extension AgentV2Candidate {
    var agentPriceText: String? {
        if let minor = kind == .flight ? (ticketPriceMinor ?? priceMinor) : priceMinor {
            if let priceCurrency, !priceCurrency.isEmpty {
                return CardPrice.format(minor: minor, currency: priceCurrency)
            }
            let major = Double(minor) / 100
            let amount = major.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", major)
                : String(format: "%.2f", major)
            // Legacy candidates may have an amount but no source currency.
            // Showing a bare amount is safer than falsely labelling it CNY.
            return amount
        }
        if notes?.contains("实时价格见预订链接") == true { return String(localized: "agent.priceLive") }
        return nil
    }
}

struct AgentContextSheet: View {
    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var store: AgentV2SessionStore
    /// 非 nil 时编辑该行程——「切换旅行」弹窗左滑编辑任意行（可能不是当前
    /// 选中行程）；nil 时维持原行为，编辑当前选中行程。行程切换弹窗与旅程
    /// 列表的编辑入口共用本弹窗。
    var targetSummary: TripSummary? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var customInterest = ""
    /// 本次旅行的可编辑字段：进入弹窗或切换行程时从快照载入，离开时如有改动则保存。
    @State private var destination = ""
    @State private var startDate = Date()
    @State private var endDate = Date()
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if canShowTripFields {
                        if isTripEditable {
                            TextField("agent.destinationPlaceholder", text: $destination)
                                .textInputAutocapitalization(.words)
                            // 原生日期组件（Apple 文档：DatePicker(_:selection:displayedComponents:in:)），
                            // 仅显示日期；返程用 in: startDate... 约束不得早于出发。
                            DatePicker("agent.departure", selection: $startDate, displayedComponents: .date)
                            DatePicker("agent.return", selection: $endDate, in: startDate..., displayedComponents: .date)
                                .onChange(of: startDate) { _, newStartDate in
                                    if endDate < newStartDate { endDate = newStartDate }
                                }
                        } else {
                            LabeledContent("agent.destinationLabel", value: displayedDestination ?? String(localized: "agent.valueUnset"))
                            LabeledContent(
                                "agent.dateLabel",
                                value: String(format: String(localized: "agent.dateRange"), displayedStartDate ?? "", displayedEndDate ?? "")
                            )
                        }
                    } else {
                        ContentUnavailableView("agent.setupEmptyTitle", systemImage: "calendar.badge.exclamationmark", description: Text("agent.setupEmptyDesc"))
                    }
                } header: {
                    Text("agent.tripSection")
                } footer: {
                    if isTripEditable {
                        Text("agent.tripFooter")
                    }
                }

                Section("agent.conditionsSection") {
                    Picker("agent.paceLabel", selection: binding(\.pace)) {
                        Text("agent.preference.unset").tag(""); Text("agent.preference.relaxed").tag("relaxed"); Text("agent.preference.balanced").tag("balanced"); Text("agent.preference.intense").tag("packed")
                    }
                    Picker("agent.companyLabel", selection: binding(\.companions)) {
                        Text("agent.preference.unset").tag(""); Text("agent.preference.solo").tag("solo"); Text("agent.preference.couple").tag("couple"); Text("agent.preference.parents").tag("parents"); Text("agent.preference.kids").tag("children"); Text("agent.preference.friends").tag("friends")
                    }
                    Picker("agent.budgetLabel", selection: binding(\.budget)) {
                        Text("agent.preference.unset").tag(""); Text("agent.preference.budget").tag("value"); Text("agent.preference.mid").tag("balanced"); Text("agent.preference.premium").tag("premium")
                    }
                }

                Section {
                    FlowLayout(spacing: 8) {
                        ForEach(displayInterestOptions, id: \.code) { option in
                            Button { toggleInterest(option.code) } label: {
                                HStack(spacing: 5) {
                                    if store.session.preferences.interests.contains(option.code) { Image(systemName: "checkmark") }
                                    Text(option.displayName)
                                }
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(store.session.preferences.interests.contains(option.code) ? .white : PrimaryTabPalette.secondaryText)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(store.session.preferences.interests.contains(option.code) ? PrimaryTabPalette.accent : PrimaryTabPalette.elevatedSurface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)

                    HStack(spacing: 10) {
                        TextField("agent.customInterestPlaceholder", text: $customInterest)
                            .font(.subheadline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(PrimaryTabPalette.elevatedSurface, in: Capsule())
                            .onSubmit { addCustomInterest() }
                        Button {
                            addCustomInterest()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                                .foregroundStyle(PrimaryTabPalette.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(customInterest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel(Text("agent.customInterestA11y"))
                    }
                } header: {
                    Text("agent.preferencesSection")
                }
            }
            .scrollContentBackground(.hidden)
            .background(PrimaryTabPalette.background)
            .tint(PrimaryTabPalette.accent)
            .preferredColorScheme(.dark)
            .onAppear { loadTripFields() }
            // 编辑入口可能先切行程再打开本弹窗；选中行程异步落定后刷新一次字段。
            .onChange(of: syncEngine.trip?.id) { _, _ in loadTripFields() }
            .onDisappear { persistTripChanges() }
            .navigationTitle("agent.preferencesTitle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("common.done") { dismiss() } }
            }
        }
    }

    /// 当前编辑目标行程的摘要；保存目的地与日期时需要它定位行程。指定了
    /// targetSummary 时以它为准（编辑非选中行程），否则取当前选中行程。
    private var currentSummary: TripSummary? {
        targetSummary ?? syncEngine.trips.first { $0.id == syncEngine.selectedTripID }
    }

    /// 行程区能否展示字段：编辑指定行程时目标一定来自行程列表，直接展示；
    /// 编辑选中行程时沿用手上的快照，且要求已完成设置。
    private var canShowTripFields: Bool {
        if targetSummary != nil { return true }
        guard let trip = syncEngine.trip else { return false }
        return trip.isConfigured
    }

    /// 只读展示用的目的地/日期：优先目标行程，其次当前选中行程。
    private var displayedDestination: String? {
        targetSummary?.destination ?? syncEngine.trip?.destination
    }

    private var displayedStartDate: String? {
        targetSummary?.startDate ?? syncEngine.trip?.startDate
    }

    private var displayedEndDate: String? {
        targetSummary?.endDate ?? syncEngine.trip?.endDate
    }

    /// 与「切换旅行」弹窗的「编辑」入口一致：只有 owner 能改行程信息。
    private var isTripEditable: Bool {
        currentSummary?.role == "owner"
    }

    /// 进入弹窗或切换行程时，把行程快照载入可编辑字段。
    private func loadTripFields() {
        if let targetSummary {
            destination = targetSummary.destination ?? ""
            let start = targetSummary.startDate.flatMap(Self.formatter.date(from:)) ?? Date()
            startDate = start
            endDate = max(start, targetSummary.endDate.flatMap(Self.formatter.date(from:)) ?? start)
            return
        }
        guard let trip = syncEngine.trip else { return }
        destination = trip.destination ?? ""
        let start = trip.startDate.flatMap(Self.formatter.date(from:)) ?? Date()
        startDate = start
        endDate = max(start, trip.endDate.flatMap(Self.formatter.date(from:)) ?? start)
    }

    /// 离开弹窗时保存改动（点「完成」或下拉关闭都会触发）。
    /// 目的地为空视作未完成编辑，不落库；无改动时不发请求。
    private func persistTripChanges() {
        guard isTripEditable, let summary = currentSummary else { return }
        // 编辑非选中行程时以目标行程的快照做变更对比与货币回填；
        // syncEngine.trip 此时可能是另一段行程，不能拿来当参照。
        let reference: (destination: String?, startDate: String?, endDate: String?, currency: String?)
        if let targetSummary {
            reference = (targetSummary.destination, targetSummary.startDate, targetSummary.endDate, targetSummary.currency)
        } else if let trip = syncEngine.trip {
            reference = (trip.destination, trip.startDate, trip.endDate, trip.currency)
        } else {
            return
        }
        let newDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newDestination.isEmpty else { return }
        let newStart = Self.formatter.string(from: startDate)
        let newEnd = Self.formatter.string(from: endDate)
        guard newDestination != (reference.destination ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            || newStart != (reference.startDate ?? "")
            || newEnd != (reference.endDate ?? "") else { return }
        Task {
            await syncEngine.updateTrip(
                summary,
                destination: newDestination,
                startDate: startDate,
                endDate: endDate,
                currency: reference.currency ?? "CNY"
            )
        }
    }

    /// 日期以 "yyyy-MM-dd"（GMT/POSIX）字符串存储，与服务端行程快照一致。
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func binding(_ keyPath: WritableKeyPath<AgentV2TurnRequest.Preferences, String?>) -> Binding<String> {
        Binding(
            get: { store.session.preferences[keyPath: keyPath] ?? "" },
            set: { value in store.updatePreference(keyPath, value: value.isEmpty ? nil : value) }
        )
    }

    private func toggleInterest(_ interest: String) {
        store.toggleInterest(interest)
    }

    /// 兴趣标签展示模型：预置项携带稳定 code 与本地化名称；自定义项两者相同。
    private struct InterestOption {
        let code: String
        let displayName: String
    }

    /// 预置兴趣（稳定 code）+ 已保存的自定义偏好；自定义项取消勾选后即从列表移除。
    private var displayInterestOptions: [InterestOption] {
        let saved = store.session.preferences.interests
        let customs = saved.filter { !AgentInterest.presets.contains($0) }
        return AgentInterest.presets.map { InterestOption(code: $0, displayName: AgentInterest.displayName(for: $0)) }
            + customs.map { InterestOption(code: $0, displayName: $0) }
    }

    /// 添加自定义偏好：去空白、去重后直接勾选加入。
    private func addCustomInterest() {
        let name = customInterest.trimmingCharacters(in: .whitespacesAndNewlines)
        customInterest = ""
        guard !name.isEmpty else { return }
        if !store.session.preferences.interests.contains(name) {
            store.toggleInterest(name)
        }
    }
}

/// 首页设置中的轻量登录弹窗。原生 Apple 登录按钮在授权期间
/// 始终保留在视图层级中，确保系统凭证能正常回传给 AppleSignInStore。
struct AgentHomeSignInSheet: View {
    @ObservedObject var appleSignIn: AppleSignInStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.accent)

            VStack(spacing: 6) {
                Text("agent.signInTitle")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("agent.signInDesc")
                    .font(.subheadline)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .multilineTextAlignment(.center)
            }

            ZStack {
                SignInWithAppleButton(
                    .signIn,
                    onRequest: { request in
                        appleSignIn.configure(request)
                        Task { await appleSignIn.signIn(apiClient: APIClient()) }
                    },
                    onCompletion: { appleSignIn.handle(result: $0) }
                )
                .signInWithAppleButtonStyle(.white)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .allowsHitTesting(!appleSignIn.isSigningIn)

                if appleSignIn.isSigningIn {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                        Text("agent.signingIn")
                            .font(.body.weight(.semibold))
                    }
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
                }
            }

            if let errorMessage = appleSignIn.errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onChange(of: appleSignIn.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated { dismiss() }
        }
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
        case .verified: String(localized: "agent.verifiedBadge")
        case .pending: String(localized: "agent.verifyingBadge")
        case .failed: String(localized: "agent.pendingBadge")
        case .notRequired: String(localized: "agent.noPlaceNeededBadge")
        }
    }
}

private extension AgentV2Change {
    var operationTitle: String {
        switch operation {
        case .add: String(localized: "agent.change.new")
        // 区分作用于已确认行程卡片与仅作用于未确认草稿候选的操作，
        // 避免“替换/移除”让用户误以为已确认的行程被改动。
        case .replace: targetDraftId != nil ? String(localized: "agent.change.updateCandidate") : String(localized: "agent.change.replaceTrip")
        case .remove: targetDraftId != nil ? String(localized: "agent.change.removeCandidate") : String(localized: "agent.change.removeTrip")
        case .move: String(localized: "agent.change.move")
        case .keep: String(localized: "agent.change.keep")
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
        case .activity: String(localized: "agent.kind.activity")
        case .hotel: String(localized: "agent.kind.hotel")
        case .flight: String(localized: "agent.kind.flight")
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
