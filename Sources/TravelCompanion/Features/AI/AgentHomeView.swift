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
    @FocusState private var isComposerFocused: Bool
    @State private var message = ""
    @State private var isShowingPhotoPicker = false
    @State private var isShowingCameraPicker = false
    @State private var isShowingDocumentPicker = false
    @State private var isProcessingAttachment = false
    @State private var isShowingContext = false
    @State private var isShowingHistory = false
    @State private var isShowingSignIn = false
    @State private var isShowingTripPicker = false
    @State private var didConsumeInitialMessage = false
    @State private var didSubmitInitialMessage = false
    /// Coalesce the many scroll requests produced by a token stream. Without
    /// this, every published fragment queues another main-thread layout pass.
    @State private var streamingScrollTask: Task<Void, Never>?
    @State private var isCreatingTripFromProposal = false
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
    /// 「拈签定缘」抽签流程：nil 表示未在流程中，否则为当前问题的下标。
    @State private var lotteryStepIndex: Int?
    /// 折叠方块与展开输入条之间做连续变形动画（matchedGeometryEffect）的命名空间。
    @Namespace private var composerMotion
    /// 抽签流程中已收集的选择（问题 key → 选项文案），最终作为上下文发给 Agent。
    @State private var lotteryAnswers: [(key: String, value: String)] = []
    /// 「打算旅行多久呢？」滑动条的当前天数（1~30，30 = 30 天以上）。
    @State private var lotteryDurationDays: Double = 5
    /// 「我们有多少预算？」滑动条的当前预算（¥1,000~¥30,000，上限记为「以上」）。
    @State private var lotteryBudgetAmount: Double = 10_000
    /// 「拈签定缘」的追问序列：逐步收窄范围，最后把所有选择交给 Agent 抽签。
    /// 前两问用双方块二选一作答，后两问（天数/预算）用滑动条作答。
    private let lotterySteps: [LotteryStep] = [
        LotteryStep(question: "或许我们可以缩小一下范围？", key: "范围", kind: .choice(left: "海外", right: "国内")),
        LotteryStep(question: "想要躺平慢游，还是特种兵打卡？", key: "节奏", kind: .choice(left: "躺平慢游", right: "特种兵打卡")),
        LotteryStep(question: "打算旅行多久呢？", key: "天数", kind: .duration),
        LotteryStep(question: "我们有多少预算？", key: "预算", kind: .budget)
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
        ("巴厘岛", "🇮🇩", "dest-bali"), ("马赛马拉", "🇰🇪", "dest-masai-mara"),
        ("京都", "🇯🇵", "dest-kyoto"), ("冰岛", "🇮🇸", "dest-iceland"),
        ("圣托里尼", "🇬🇷", "dest-santorini"), ("清迈", "🇹🇭", "dest-chiangmai"),
        ("新西兰", "🇳🇿", "dest-newzealand"), ("摩洛哥", "🇲🇦", "dest-morocco"),
        ("瑞士", "🇨🇭", "dest-switzerland"), ("挪威", "🇳🇴", "dest-norway"),
        ("卡帕多奇亚", "🇹🇷", "dest-cappadocia"), ("马丘比丘", "🇵🇪", "dest-machupicchu"),
        ("撒哈拉", "🇩🇿", "dest-sahara"), ("北海道", "🇯🇵", "dest-hokkaido"),
        ("大理", "🇨🇳", "dest-dali"), ("喀纳斯", "🇨🇳", "dest-kanas"),
        ("帕劳", "🇵🇼", "dest-palau"), ("科莫多", "🇮🇩", "dest-komodo"),
        ("托斯卡纳", "🇮🇹", "dest-tuscany"), ("阿马尔菲", "🇮🇹", "dest-amalfi")
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
            .overlay(alignment: .topLeading) {
                // 左上角共用返回键：抽签流程中返回上一步（第一问时退出流程）；
                // 欢迎页输入条展开时收起，回到双方块入口；对话页返回则归档
                // 当前对话并完全复位到首页初始状态（双方块入口）。
                if lotteryStepIndex != nil || isComposerExpanded || !isWelcomeState || onCancelNewTripPlanning != nil {
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
                    .accessibilityLabel("返回")
                }
            }
            .overlay(alignment: .topTrailing) {
                if presentation == .home, !appleSignIn.isAuthenticated {
                    Button {
                        appleSignIn.errorMessage = nil
                        isShowingSignIn = true
                    } label: {
                        Label("登录", systemImage: "person.crop.circle")
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
                    .accessibilityHint("打开 Sign in with Apple")
                }
            }
            .overlay {
                if isShowingPhotoPicker {
                    // PHPicker may invoke Face ID for protected albums. Let the
                    // presenting view remain live while the scene resigns and
                    // becomes active again; a local scrim provides stable
                    // dimming without UIKit replacing the upper sheet backdrop
                    // with an opaque black view after authentication.
                    Color.black.opacity(0.24)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {}
                        .accessibilityHidden(true)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
            .sheet(isPresented: $isShowingSignIn) {
                AgentHomeSignInSheet(appleSignIn: appleSignIn)
                    .presentationDetents([.height(300)])
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingContext) {
                AgentContextSheet(syncEngine: syncEngine, store: store)
            }
            .sheet(isPresented: $isShowingHistory) {
                AgentHistorySheet(store: store) {
                    runState.clearTransientState()
                }
            }
            .sheet(isPresented: $isShowingTripPicker) {
                AgentTripPickerSheet(
                    selectedTripID: syncEngine.selectedTripID,
                    trips: syncEngine.trips,
                    onClear: {
                        resetSuggestions()
                        Task { await syncEngine.clearSelectedTrip() }
                    },
                    onSelect: { summary in
                        guard summary.id != syncEngine.selectedTripID else { return }
                        startNewConversation()
                        resetSuggestions()
                        Task { await syncEngine.selectTrip(summary.id) }
                    },
                    onEdit: { summary, destination, startDate, endDate, currency in
                        Task {
                            await syncEngine.updateTrip(
                                summary,
                                destination: destination,
                                startDate: startDate,
                                endDate: endDate,
                                currency: currency
                            )
                        }
                    },
                    onDelete: { summary in
                        if summary.id == syncEngine.selectedTripID {
                            startNewConversation()
                            resetSuggestions()
                        }
                        Task { await syncEngine.deleteTrip(summary) }
                    }
                )
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $isShowingPhotoPicker) {
                AgentPhotoPickerSheet(
                    maximumSelectionCount: max(1, remainingAttachmentSlots)
                ) { results in
                    isShowingPhotoPicker = false
                    loadPHPickerResults(results)
                }
                .presentationDetents([.fraction(0.58)])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(32)
                .presentationBackground(Color(uiColor: .secondarySystemBackground))
                .presentationBackgroundInteraction(.enabled)
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
            .alert("无法完成操作", isPresented: Binding(get: { runState.error != nil }, set: { if !$0 { runState.error = nil } })) {
                Button("知道了", role: .cancel) {}
            } message: { Text(runState.error ?? "") }
            .onAppear {
                consumeInitialMessageIfNeeded()
                loadSuggestionsIfNeeded()
            }
            .onChange(of: syncEngine.trip?.id) { _, _ in loadSuggestionsIfNeeded() }
            .onChange(of: syncEngine.trip?.isConfigured) { _, _ in loadSuggestionsIfNeeded() }
            .onChange(of: runState.isGenerating) { _, isGenerating in
                // 新一轮生成从折叠状态开始；生成结束后思考摘要整体隐藏。
                if !isGenerating { isReasoningExpanded = false }
                // 生成开始时若视图已在下方（泊入态），本轮顶部不再出现思考
                // orb——上滑恢复的只有地球，icon 停在状态行。
                if isGenerating { didDockDuringGeneration = isGlobeDocked }
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
        guard let trip = syncEngine.trip, trip.isConfigured else { return "未设置旅行" }
        return trip.destination ?? "本次旅行"
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
                .accessibilityLabel("切换行程")

                Spacer(minLength: 0)

                Button { isShowingHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.glass)
                .accessibilityLabel("历史对话")

                Button { startNewConversation() } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.glass)
                .disabled(isWelcomeState)
                .accessibilityLabel("新建对话")
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
        .scrollDismissesKeyboard(.interactively)
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
        lotteryStepIndex.map { lotterySteps[$0].question } ?? "告诉豆奶你想去哪里。"
    }

    /// Sheet 为 80% 高度时让欢迎页保持紧凑；扩展到全屏时逐步放大地球。
    /// 上限避免地球挤掉下方的行程摘要和三条建议。
    private var workbenchGlobeAreaHeight: CGFloat {
        min(250, max(150, workbenchViewportHeight * 0.32))
    }

    private var welcomeView: some View {
        VStack(alignment: .leading, spacing: usesCompactWorkbenchWelcomeLayout ? 14 : 24) {
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

    @ViewBuilder
    private var suggestedQuestions: some View {
        if revealedSuggestionCount > 0 {
            VStack(alignment: .leading, spacing: usesCompactWorkbenchWelcomeLayout ? 8 : 12) {
                Text("可以这样问")
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
                interests: preferences.interests.isEmpty ? nil : preferences.interests
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
                ChatMessageView(message: item)
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
                        Text("正在生成候选")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        ForEach(runState.liveCards) { card in
                            LiveCandidateCard(card: card)
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
        // 附件条出现时渐变向上延伸一段（渐变上延），让图片缩略图背后同样
        // 有遮罩过渡，而不是直接压在滚动内容上。
        .background {
            Group {
                if !isWelcomeState || isComposerExpanded || isComposerFocused {
                    LinearGradient(
                        stops: [
                            .init(
                                color: PrimaryTabPalette.background.opacity(isComposerFocused ? 0.82 : 0),
                                location: 0
                            ),
                            .init(color: PrimaryTabPalette.background.opacity(0.96), location: 0.24),
                            .init(color: PrimaryTabPalette.background, location: 0.56)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    // 附件条（约 8pt 内边距 + 76pt 预览卡 + 间距）出现时向上延伸。
                    .padding(.top, store.session.attachments.isEmpty ? 0 : -112)
                    .ignoresSafeArea(edges: .bottom)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isWelcomeState)
            .animation(.easeInOut(duration: 0.2), value: isComposerFocused)
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 展开态：完整输入条（图片、文本框、发送键）。背景与「+」控件和折叠态
    /// 右侧方块共享 matchedGeometryEffect，点按后连续变形为扁平输入条。
    private var expandedComposer: some View {
        // 「+」、输入框、发送键垂直居中对齐（多行输入时两侧按钮随行高中点）。
        HStack(alignment: .center, spacing: 8) {
            addPhotoButton

            TextField("告诉豆奶你的旅游灵感", text: $message, axis: .vertical)
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
                        minLabel: "1 天",
                        maxLabel: "30 天+",
                        buttonTitle: "下一步",
                        accessibilityLabel: "旅行天数",
                        onConfirm: { confirmLotteryDuration() },
                        format: { days in
                            (number: "\(Int(days))", unit: days >= 30 ? "天以上" : "天")
                        }
                    )
                    .id("lottery-slider-duration")
                    .transition(.opacity)
                case .budget:
                    AgentLotterySliderPanel(
                        range: 1_000...30_000,
                        step: 500,
                        value: $lotteryBudgetAmount,
                        minLabel: "¥1,000",
                        maxLabel: "¥30,000+",
                        buttonTitle: "开始抽签",
                        accessibilityLabel: "预算金额",
                        onConfirm: { confirmLotteryBudget() },
                        format: { amount in
                            (number: "¥\(Int(amount).formatted())", unit: amount >= 30_000 ? "以上" : "")
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
        .accessibilityLabel(currentChoiceStep.map { "选择 \($0.left)" } ?? "拈签定缘，随机抽一个旅行灵感")
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
                        Text("下个目的地\n我们去")
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
        .accessibilityLabel(currentChoiceStep.map { "选择 \($0.right)" } ?? "展开输入框")
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
                Label("拍摄", systemImage: "camera")
            }

            Button {
                presentPhotoPicker()
            } label: {
                Label("照片", systemImage: "photo.on.rectangle")
            }

            Button {
                presentDocumentPicker()
            } label: {
                Label("文件", systemImage: "paperclip")
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
        .accessibilityLabel("添加照片或文件")
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
    private func confirmLotteryDuration() {
        let days = Int(lotteryDurationDays)
        answerLottery(value: days >= 30 ? "30天以上" : "\(days)天")
    }

    /// 预算滑动条确认：记录所选预算并推进（拉满记为「以上」）。
    private func confirmLotteryBudget() {
        let amount = Int(lotteryBudgetAmount)
        answerLottery(value: "¥\(amount.formatted())" + (amount >= 30_000 ? "以上" : ""))
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
            ? "请完全随机帮我定一个目的地，规划一次说走就走的旅行。"
            : "「拈签定缘」：已选择\(context)。请据此帮我定一个目的地并规划行程。"
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
            runState.error = "当前设备无法使用相机。"
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
            runState.error = "每轮最多添加 \(Self.maximumAttachmentCount) 个附件，请先移除一个。"
            return false
        }
        return true
    }

    private func loadPHPickerResults(_ results: [PHPickerResult]) {
        let accepted = Array(results.prefix(remainingAttachmentSlots))
        guard !accepted.isEmpty else { return }
        isProcessingAttachment = true
        Task {
            defer { isProcessingAttachment = false }
            for (index, result) in accepted.enumerated() {
                do {
                    let image = try await loadPickedImage(result.itemProvider)
                    guard let data = image.jpegData(compressionQuality: 0.92) else {
                        throw AgentAttachmentError.unreadable
                    }
                    try await addImageAttachment(data, fileName: "照片-\(index + 1).jpg")
                } catch {
                    runState.error = error.localizedDescription
                }
            }
            restoreComposerAfterPicking()
        }
    }

    private func loadPickedImage(_ provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? AgentAttachmentError.unreadable)
                }
            }
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
                try await addImageAttachment(data, fileName: "拍摄照片.jpg")
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

    private func send() {
        let submittedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "请分析这些附件，并结合当前旅行给出建议。"
            : message
        guard let request = makeRequest(message: submittedMessage) else { runState.error = "请先完成旅行设置。"; return }
        // plan_new（无生效旅程或「暂不选择行程」）时 tripID 为 nil，服务端不强制本接口的旅程鉴权。
        let tripID = syncEngine.trip?.id
        let userMessage = AgentV2TurnRequest.Message(id: UUID(), role: "user", content: submittedMessage, createdAt: .now)
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
            var reconnectAttempt = 0
            var didComplete = false

            while !Task.isCancelled, !didComplete {
                if reconnectAttempt > 0 {
                    sessionStore.discardTurn()
                    sessionStore.beginTurn()
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

                var pendingQuestions: [String] = []
                do {
                    let stream = try await client.agentV2Stream(request, tripID: tripID)
                    for try await event in stream {
                        switch event {
                        case .status(let text): state.status = text
                        case .reasoningSummary(let text): state.reasoningSummary += text
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
                            sessionStore.clearAttachments()
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

    private func makeRequest(message requestMessage: String) -> AgentV2TurnRequest? {
        if plansNewTrip {
            return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "plan_new", message: requestMessage, trip: nil, preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
        }
        guard let trip = syncEngine.trip, trip.isConfigured else {
            // 无生效旅程：从零规划模式（plan_new）。服务端会产出待用户确认的
            // 旅程提案（trip_proposal），确认前不落库创建旅程。
            return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "plan_new", message: requestMessage, trip: nil, preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
        }
        let days = trip.days.map { day in
            AgentV2TurnRequest.Day(date: day.date, cards: day.cards.map { card in
                AgentV2TurnRequest.Card(id: card.serverID, kind: card.kind.rawValue, title: card.title, startAt: ISO8601DateFormatter().string(from: card.startAt), endAt: card.endAt.map { ISO8601DateFormatter().string(from: $0) }, place: card.place?.name, notes: card.notes)
            })
        }
        return AgentV2TurnRequest(sessionId: store.session.id, turnId: UUID(), intent: "itinerary", message: requestMessage, trip: .init(destination: trip.destination, startDate: trip.startDate, endDate: trip.endDate, currency: trip.currency, timeZone: TimeZone.current.identifier, version: trip.version, days: days), preferences: store.session.preferences, history: AgentV2TurnRequest.trimmedHistory(store.session.messages), activeDraft: store.session.draft, attachments: store.session.attachments)
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
            runState.error = "旅程提案的日期无法识别，请让豆奶重新生成提案。"
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

private struct AgentTripPickerSheet: View {
    let selectedTripID: Int?
    let trips: [TripSummary]
    let onClear: () -> Void
    let onSelect: (TripSummary) -> Void
    let onEdit: (TripSummary, String, Date, Date, String) -> Void
    let onDelete: (TripSummary) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editingTrip: TripSummary?
    @State private var tripPendingDeletion: TripSummary?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onClear()
                        dismiss()
                    } label: {
                        tripRow(
                            title: "暂不选择行程",
                            subtitle: "让豆奶按你的描述开始规划",
                            isSelected: selectedTripID == nil
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selectedTripID == nil ? .isSelected : [])
                }

                Section("我的旅行") {
                    if trips.isEmpty {
                        ContentUnavailableView(
                            "还没有旅行",
                            systemImage: "airplane.departure",
                            description: Text("创建旅行后会显示在这里。")
                        )
                    } else {
                        ForEach(trips) { summary in
                            Button {
                                guard summary.id != selectedTripID else { return }
                                onSelect(summary)
                                dismiss()
                            } label: {
                                tripRow(
                                    title: summary.displayName,
                                    subtitle: dateRange(for: summary),
                                    isSelected: summary.id == selectedTripID
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(summary.id == selectedTripID ? .isSelected : [])
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if summary.role == "owner" {
                                    Button(role: .destructive) {
                                        tripPendingDeletion = summary
                                    } label: {
                                        Label("删除", systemImage: "trash")
                                    }
                                }

                                Button {
                                    editingTrip = summary
                                } label: {
                                    Label("编辑", systemImage: "pencil")
                                }
                                .tint(PrimaryTabPalette.accent)
                            }
                            .accessibilityHint(summary.role == "owner" ? "向左轻扫可编辑或删除" : "向左轻扫可编辑")
                        }
                    }
                }
            }
            .navigationTitle("切换旅行")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .tint(PrimaryTabPalette.accent)
        .sheet(item: $editingTrip) { summary in
            TripSetupSheet(initialTrip: summary) { destination, startDate, endDate, currency in
                editingTrip = nil
                onEdit(summary, destination, startDate, endDate, currency)
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .alert(
            "删除旅行？",
            isPresented: Binding(
                get: { tripPendingDeletion != nil },
                set: { if !$0 { tripPendingDeletion = nil } }
            ),
            presenting: tripPendingDeletion
        ) { summary in
            Button("取消", role: .cancel) {
                tripPendingDeletion = nil
            }
            Button("删除", role: .destructive) {
                tripPendingDeletion = nil
                onDelete(summary)
            }
        } message: { summary in
            Text("“\(summary.displayName)”中的行程、支出和手书内容都会永久删除，此操作无法撤销。")
        }
    }

    private func tripRow(title: String, subtitle: String, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "location.fill")
                .foregroundStyle(PrimaryTabPalette.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.accent)
            }
        }
        .contentShape(Rectangle())
    }

    private func dateRange(for summary: TripSummary) -> String {
        let dates = [summary.startDate, summary.endDate].compactMap { $0 }
        return dates.count == 2 ? dates.joined(separator: " – ") : "日期待设置"
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

            Button(action: onConfirm) {
                Text(buttonTitle)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(PrimaryTabPalette.accent, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 12)
            .accessibilityLabel(buttonTitle)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .aspectRatio(1.78, contentMode: .fit)
        .background { AgentEntryGlassTile() }
    }
}

/// 自定义滑动条：暖色渐变已选轨道 + 白色圆形拇指，按步长吸附；数值变化时
/// 触发轻微触感反馈，支持 VoiceOver 增减调节。暖色渐变与「拈签定缘」
/// 光晕同色系。
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
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: 0xFFAA46).opacity(0.85), PrimaryTabPalette.accent],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: thumbCenter, height: Self.trackHeight)
                    .shadow(color: PrimaryTabPalette.accent.opacity(0.4), radius: 4)
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
                                        Text(AgentHistoryRelativeTime.display(for: archived.updatedAt))
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

/// 历史会话只展示一个中文时间层级，避免系统相对时间显示「18 hr 22 min」这类组合文案。
enum AgentHistoryRelativeTime {
    static func display(for date: Date, now: Date = .now) -> String {
        let elapsedSeconds = max(0, now.timeIntervalSince(date))
        let elapsedMinutes = Int(elapsedSeconds / 60)

        guard elapsedMinutes >= 1 else { return "刚刚" }
        if elapsedMinutes < 60 { return "\(elapsedMinutes)分钟" }

        let elapsedHours = elapsedMinutes / 60
        if elapsedHours < 24 { return "\(elapsedHours)小时" }

        let elapsedDays = elapsedHours / 24
        if elapsedDays < 7 { return "\(chineseCount(elapsedDays))天前" }

        let elapsedWeeks = elapsedDays / 7
        if elapsedDays < 30 { return "\(chineseCount(elapsedWeeks))周前" }

        let elapsedMonths = elapsedDays / 30
        if elapsedMonths < 12 { return "\(chineseCount(elapsedMonths))个月前" }

        return "\(chineseCount(elapsedDays / 365))年前"
    }

    private static func chineseCount(_ value: Int) -> String {
        if value == 2 { return "两" }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.numberStyle = .spellOut
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

private struct ChatMessageView: View {
    let message: AgentV2TurnRequest.Message

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
            AssistantMessageContainer {
                Text(message.content)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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

struct AgentV2CandidateCard: View {
    let candidate: AgentV2Candidate
    let selection: (Bool) -> Void
    @State private var imageIndex = 0
    @State private var isShowingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !imageURLs.isEmpty {
                AgentCandidateImagePager(urls: imageURLs, selection: $imageIndex, height: 174)
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

                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 10) {
                    Button {
                        if candidate.isCommitReady { selection(!candidate.selected) }
                    } label: {
                        Label(candidate.selected ? "已选择" : "加入行程", systemImage: candidate.selected ? "checkmark.circle.fill" : "plus.circle.fill")
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
                    .disabled(!candidate.isCommitReady)
                    .opacity(candidate.isCommitReady ? 1 : 0.45)

                    Button { isShowingDetails = true } label: {
                        HStack(spacing: 5) {
                            Text("查看详情")
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
            AgentCandidatePOIDetailSheet(candidate: candidate, selection: selection)
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
                Text("\(selection + 1) / \(urls.count)")
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(12)
                    .accessibilityLabel("第 \(selection + 1) 张，共 \(urls.count) 张")
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
                    detailSection(title: "地点介绍", icon: "text.alignleft") {
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
                    detailSection(title: "推荐理由", icon: "sparkles") {
                        Text(reason)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.86))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !candidate.risks.isEmpty {
                    detailSection(title: "出发前留意", icon: "exclamationmark.triangle.fill", tint: .orange) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(candidate.risks, id: \.self) { risk in
                                bullet(risk, color: .orange)
                            }
                        }
                    }
                }

                if !candidate.tips.isEmpty {
                    detailSection(title: "实用贴士", icon: "lightbulb.fill") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(candidate.tips, id: \.self) { tip in
                                bullet(tip, color: PrimaryTabPalette.accent)
                            }
                        }
                    }
                }

                if let notes = candidate.notes, !notes.isEmpty {
                    detailSection(title: "补充信息", icon: "note.text") {
                        Text(notes)
                            .font(.body)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let sourceURL {
                    Link(destination: sourceURL) {
                        HStack {
                            Label(sourceLabel, systemImage: sourceIcon)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(16)
                        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 112)
        }
        .scrollIndicators(.hidden)
        .background(PrimaryTabPalette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionBar
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
            .accessibilityLabel("关闭详情")
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
                    Label("\(duration) 分钟", systemImage: "clock")
                        .foregroundStyle(.white.opacity(0.72))
                }
            }
            .font(.caption.weight(.semibold))
        }
    }

    private func locationSection(_ place: AIChatPlace) -> some View {
        detailSection(title: "地点", icon: "mappin.and.ellipse") {
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
                guard candidate.isCommitReady else { return }
                selection(!candidate.selected)
            } label: {
                HStack {
                    Image(systemName: candidate.selected ? "checkmark.circle.fill" : "plus.circle.fill")
                    Text(candidate.selected ? "已选择，轻点取消" : "选择加入本轮行程")
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
            .disabled(!candidate.isCommitReady)
            .opacity(candidate.isCommitReady ? 1 : 0.45)
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

    private var sourceURL: URL? {
        guard let value = candidate.url,
              let url = URL(string: value),
              url.scheme?.lowercased() == "https" else { return nil }
        return url
    }

    private var sourceLabel: String {
        guard let host = sourceURL?.host?.lowercased() else { return "打开参考链接" }
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "查看小红书原笔记" }
        if host.contains("fliggy") || host.contains("alitrip") { return "前往飞猪查看预订" }
        return "打开参考链接"
    }

    private var sourceIcon: String {
        sourceLabel.contains("预订") ? "airplane" : "arrow.up.right.square"
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
        if let priceMinor {
            let major = Double(priceMinor) / 100
            let amount = major.truncatingRemainder(dividingBy: 1) == 0
                ? String(format: "%.0f", major)
                : String(format: "%.2f", major)
            return "¥\(amount)"
        }
        if notes?.contains("实时价格见预订链接") == true { return "实时价" }
        return nil
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
                    } else {
                        ContentUnavailableView("请先完成旅行设置", systemImage: "calendar.badge.exclamationmark", description: Text("豆奶需要目的地、日期等信息来检查地点与冲突。"))
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

    private func toggleInterest(_ interest: String) {
        store.toggleInterest(interest)
    }
}

/// 首页 Agent 右上角登录入口的轻量弹窗。原生 Apple 登录按钮在授权期间
/// 始终保留在视图层级中，确保系统凭证能正常回传给 AppleSignInStore。
private struct AgentHomeSignInSheet: View {
    @ObservedObject var appleSignIn: AppleSignInStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 38, weight: .medium))
                .foregroundStyle(PrimaryTabPalette.accent)

            VStack(spacing: 6) {
                Text("登录豆奶旅行")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Text("登录后开启云端同步，并在你的设备间保留行程与 Agent 对话。")
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
                        Text("正在登录…")
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
