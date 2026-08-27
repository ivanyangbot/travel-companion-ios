import AuthenticationServices
import SwiftUI
import SwiftData
import UIKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var syncEngine: SyncEngine?
    @StateObject private var sharedLinkStore = PendingSharedLinkStore()
    @StateObject private var appleSignIn = AppleSignInStore()
    // 每次冷启动都从全新会话开始：上次对话归档进「历史对话」，不直接展示。
    @StateObject private var agentSessionStore = AgentV2SessionStore(startsFreshOnLaunch: true)
    @StateObject private var agentRunState = AgentV2RunState()
    @StateObject private var journalSync = JournalSyncCoordinator()
    @State private var showsAgent = false
    /// 首页 Agent 进入「拈签定缘」/展开输入条时收起底部悬浮导航（含 Agent
    /// 按钮），退出流程回到双方块入口后恢复。
    @State private var agentHomeHidesTabBar = false
    /// 首页当前展示的就是 AgentHomeView（无生效行程的欢迎页）时隐藏 tab 栏
    /// 右侧的 Agent 按钮——页面本身就是 Agent，入口重复；回到地图后恢复。
    @State private var agentHomeActive = false
    @State private var agentInitialMessage: String?
    @State private var selectedSection: MainSection = .journey
    @State private var navigationDragTranslation: CGFloat = 0
    @State private var navigationDragHasStarted = false
    @State private var navigationIsPressed = false

    private enum MainSection: CaseIterable {
        case journey
        case expenses
        case notes

        var title: String {
            switch self {
            case .journey: "旅程"
            case .expenses: "账本"
            case .notes: "手书"
            }
        }

        var icon: String {
            switch self {
            case .journey: "icon-trip-outline"
            case .expenses: "icon-money-outline"
            case .notes: "icon-note-outline"
            }
        }
    }

    var body: some View {
        // Phase 1: the user enters a custom floating navigation. When not signed in,
        // travel data stays local-only (SwiftData) and the Journey section hosts the
        // Apple Sign-In entry point. The sync engine skips all network calls
        // until a token appears in the keychain.
        mainTabs
            .environmentObject(agentSessionStore)
            .environmentObject(agentRunState)
    }

    private var mainTabs: some View {
        ZStack {
            activeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // 首页 Agent 进入「拈签定缘」/展开输入条时整体收起（下滑淡出），
            // 退出流程后恢复；其他 tab 的偏好默认值恒为 false，不受影响。
            if !agentHomeHidesTabBar {
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        customNavigation
                        Spacer(minLength: 0)
                        // 首页本身就是 Agent 页（AgentHomeView）时不再显示
                        // 这个重复入口；其余页面照常。
                        if !agentHomeActive {
                            agentButton
                                .transition(.opacity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .transition(.opacity)
            }
        }
        // 两个按钮在同一满屏坐标系中布局，底边均严格距离物理屏幕 32pt。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .onPreferenceChange(AgentHomeHidesTabBarKey.self) { hidden in
            withAnimation(.easeInOut(duration: 0.25)) { agentHomeHidesTabBar = hidden }
        }
        .onPreferenceChange(AgentHomeActiveKey.self) { active in
            withAnimation(.easeInOut(duration: 0.25)) { agentHomeActive = active }
        }
        .sheet(isPresented: $showsAgent, onDismiss: { agentInitialMessage = nil }) {
            Group {
                if let syncEngine {
                    AgentWorkbenchView(
                        syncEngine: syncEngine,
                        appleSignIn: appleSignIn,
                        initialMessage: agentInitialMessage,
                        onInitialMessageSubmitted: {
                            sharedLinkStore.markDelivered()
                            agentInitialMessage = nil
                        }
                    )
                } else {
                    ProgressView("豆奶正在赶来...")
                }
            }
            .presentationDetents([.fraction(0.8)])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(28)
            .presentationBackground(PrimaryTabPalette.background)
        }
        .task {
            guard syncEngine == nil else { return }
            let engine = SyncEngine(repository: SharedTripRepository(modelContext: modelContext))
            engine.observeAuthChanges()
            syncEngine = engine
            await engine.bootstrap()
            journalSync.updateSession(
                isAuthenticated: engine.isUserAuthenticated,
                tripID: engine.selectedTripID
            )
            presentSharedLinkInAgentIfPossible()
            if scenePhase == .active {
                engine.startForegroundSync()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let syncEngine else { return }
            if phase == .active {
                sharedLinkStore.consumeStoredURL()
                presentSharedLinkInAgentIfPossible()
                syncEngine.startForegroundSync()
                journalSync.updateSession(
                    isAuthenticated: syncEngine.isUserAuthenticated,
                    tripID: syncEngine.selectedTripID
                )
                Task { await syncEngine.retry() }
            } else {
                syncEngine.stopForegroundSync()
            }
        }
        .onOpenURL { url in
            sharedLinkStore.receiveHostURL(url)
            presentSharedLinkInAgentIfPossible()
        }
        .onChange(of: sharedLinkStore.pendingURL) { _, _ in
            presentSharedLinkInAgentIfPossible()
        }
        .onChange(of: syncEngine?.trip?.version) { _, _ in
            presentSharedLinkInAgentIfPossible()
        }
        .onChange(of: syncEngine?.isUserAuthenticated) { _, authenticated in
            journalSync.updateSession(
                isAuthenticated: authenticated == true,
                tripID: syncEngine?.selectedTripID
            )
        }
        .onChange(of: syncEngine?.selectedTripID) { _, tripID in
            journalSync.updateSession(
                isAuthenticated: syncEngine?.isUserAuthenticated == true,
                tripID: tripID
            )
        }
    }

    private var agentButton: some View {
        Button {
            agentInitialMessage = nil
            showsAgent = true
        } label: {
            AnimatedAgentIcon()
                .frame(width: 40, height: 40)
                .frame(width: 60, height: 60)
                .background(Color(red: 1, green: 110 / 255, blue: 0), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("唤起豆奶")
    }

    private func presentSharedLinkInAgentIfPossible() {
        guard let url = sharedLinkStore.pendingURL,
              syncEngine?.trip?.isConfigured == true else { return }
        agentInitialMessage = "请解析这篇小红书攻略，提取其中明确提到的地点并整理成可选择的行程卡：\n\(url.absoluteString)"
        showsAgent = true
    }

    @ViewBuilder
    private var activeContent: some View {
        switch selectedSection {
        case .journey:
            if let syncEngine {
                JourneyView(
                    syncEngine: syncEngine,
                    sharedLinkStore: sharedLinkStore,
                    appleSignIn: appleSignIn
                )
        } else {
            sectionLoadingPlaceholder("正在准备旅程…")
        }
        case .expenses:
            if let syncEngine {
                ExpenseListView(syncEngine: syncEngine)
        } else {
            sectionLoadingPlaceholder("正在准备账本…")
        }
        case .notes:
            if let syncEngine {
                NotesView(syncEngine: syncEngine, journalSync: journalSync)
        } else {
            sectionLoadingPlaceholder("正在准备手书…")
        }
        }
    }

    /// 与各主页面一致的暗色底、浅色文字的加载占位视图。
    private func sectionLoadingPlaceholder(_ title: String) -> some View {
        ZStack {
            PrimaryTabPalette.background.ignoresSafeArea()
            ProgressView {
                Text(title)
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            .tint(.white)
        }
    }

    private var customNavigation: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.white)
                .frame(width: navigationHighlightWidth, height: navigationItemSize)
                .offset(x: navigationHighlightOffset)
                // Keep the drag state tactile without changing the bar's
                // layout: the selected white tile gently breathes outward.
                .scaleEffect(x: 1, y: navigationHighlightVerticalScale)

            navigationIcons(tint: .white)

            // 黑色图标层只会透过白色块显示，因此图标会随白色块的覆盖比例逐步变黑。
            navigationIcons(tint: .black)
                .mask(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .frame(width: navigationHighlightWidth, height: navigationItemSize)
                        .offset(x: navigationHighlightOffset)
                        .scaleEffect(x: 1, y: navigationHighlightVerticalScale)
                }

        }
        .contentShape(Rectangle())
        .onLongPressGesture(
            minimumDuration: .infinity,
            maximumDistance: .infinity,
            pressing: { navigationIsPressed = $0 },
            perform: {}
        )
        .simultaneousGesture(navigationDragGesture)
        .accessibilityRepresentation {
            HStack {
                ForEach(MainSection.allCases, id: \.self) { section in
                    Button(section.title) {
                        selectSection(section)
                    }
                    .accessibilityValue(section == selectedSection ? "已选择" : "")
                }
            }
        }
        .padding(4)
        .frame(width: navigationContentWidth + 8, height: 60)
        .background {
            ZStack {
                AdjustableBackdropBlur(
                    style: .systemUltraThinMaterialDark,
                    intensity: 0.1
                )
                Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255)
                    .opacity(0.16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
        .scaleEffect(
            x: navigationBarHorizontalScale,
            y: navigationBarVerticalScale,
            anchor: .bottom
        )
        .animation(.snappy(duration: 0.2), value: navigationIsPressed)
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
            radius: 12,
            y: 12
        )
    }

    private func navigationIcons(tint: Color) -> some View {
        HStack(spacing: navigationItemSpacing) {
            ForEach(MainSection.allCases, id: \.self) { section in
                Image(section.icon)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(tint)
                    .frame(width: 25, height: 25)
                    .frame(width: navigationItemSize, height: navigationItemSize)
            }
        }
        .accessibilityHidden(true)
    }

    /// 由 TabBar 容器独占手势，避免起始 Tab 的 Button 在松手时覆盖落点选择。
    /// 从白色选中块开始时拖动；点按其他图标时直接切换到对应 Tab。
    private var navigationDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard navigationDragHasStarted || navigationSelectedItemFrame.contains(value.startLocation) else {
                    return
                }
                navigationDragHasStarted = true
                navigationDragTranslation = clampedNavigationTranslation(value.translation.width)
            }
            .onEnded { value in
                if navigationDragHasStarted {
                    let destination = navigationSection(forHighlightOffset: navigationHighlightOffset)
                    navigationDragHasStarted = false
                    selectSection(destination)
                    return
                }

                guard value.translation.width.magnitude < 10, value.translation.height.magnitude < 10 else { return }
                selectSection(at: value.startLocation.x)
            }
    }

    private func selectSection(_ section: MainSection) {
        withAnimation(.snappy(duration: 0.25)) {
            selectedSection = section
            navigationDragTranslation = 0
        }
    }

    private func selectSection(at horizontalPosition: CGFloat) {
        let index = min(
            max(Int((horizontalPosition / navigationItemStride).rounded(.down)), 0),
            MainSection.allCases.count - 1
        )
        selectSection(MainSection.allCases[index])
    }

    private var navigationItemSize: CGFloat { 52 }
    private var navigationItemSpacing: CGFloat { 4 }
    private var navigationItemStride: CGFloat { navigationItemSize + navigationItemSpacing }

    private var navigationSelectedIndex: Int {
        MainSection.allCases.firstIndex(of: selectedSection) ?? 0
    }

    private var navigationSelectedItemFrame: CGRect {
        CGRect(
            x: CGFloat(navigationSelectedIndex) * navigationItemStride,
            y: 0,
            width: navigationItemSize,
            height: navigationItemSize
        )
    }

    private var navigationHighlightOffset: CGFloat {
        let rawOffset = CGFloat(navigationSelectedIndex) * navigationItemStride
            + navigationDragTranslation
            - (navigationHighlightWidth - navigationItemSize) / 2
        return min(max(0, rawOffset), navigationContentWidth - navigationHighlightWidth)
    }

    /// Pressing the selected item immediately enters the enlarged state;
    /// enlargement does not depend on how far the user has dragged.
    private var navigationPressedProgress: CGFloat {
        navigationIsPressed ? 1 : 0
    }

    private var navigationHighlightWidth: CGFloat {
        navigationItemSize + 8 * navigationPressedProgress
    }

    private var navigationHighlightVerticalScale: CGFloat {
        1 + 0.035 * navigationPressedProgress
    }

    private var navigationBarHorizontalScale: CGFloat {
        1 + ((234.47 / 228) - 1) * navigationPressedProgress
    }

    private var navigationBarVerticalScale: CGFloat {
        1 + ((62.28 / 60) - 1) * navigationPressedProgress
    }

    private var navigationContentWidth: CGFloat {
        CGFloat(MainSection.allCases.count) * navigationItemSize
            + CGFloat(MainSection.allCases.count - 1) * navigationItemSpacing
    }

    private func clampedNavigationTranslation(_ translation: CGFloat) -> CGFloat {
        let lowerBound = -CGFloat(navigationSelectedIndex) * navigationItemStride
        let upperBound = CGFloat(MainSection.allCases.count - 1 - navigationSelectedIndex) * navigationItemStride
        return min(max(translation, lowerBound), upperBound)
    }

    private func navigationSection(forHighlightOffset offset: CGFloat) -> MainSection {
        let proposedIndex = offset / navigationItemStride
        let index = min(
            max(Int(proposedIndex.rounded()), 0),
            MainSection.allCases.count - 1
        )
        return MainSection.allCases[index]
    }
}

struct AdjustableBackdropBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style
    let intensity: CGFloat

    func makeUIView(context: Context) -> AdjustableBlurEffectView {
        AdjustableBlurEffectView(style: style, intensity: intensity)
    }

    func updateUIView(_ view: AdjustableBlurEffectView, context: Context) {
        view.setIntensity(intensity)
    }
}

final class AdjustableBlurEffectView: UIVisualEffectView {
    private let blurEffect: UIBlurEffect
    private var animator: UIViewPropertyAnimator?

    init(style: UIBlurEffect.Style, intensity: CGFloat) {
        blurEffect = UIBlurEffect(style: style)
        super.init(effect: nil)
        isUserInteractionEnabled = false

        let animator = UIViewPropertyAnimator(duration: 1, curve: .linear) { [weak self] in
            guard let self else { return }
            effect = blurEffect
        }
        animator.pausesOnCompletion = true
        animator.fractionComplete = min(1, max(0, intensity))
        self.animator = animator
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setIntensity(_ intensity: CGFloat) {
        animator?.fractionComplete = min(1, max(0, intensity))
    }

}

/// 原生雪碧图动画：没有 WebView，因此不会弹出图片长按菜单，也不会吞掉按钮点击。
private struct AnimatedAgentIcon: View {
    private static let frameInterval: TimeInterval = 0.1

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: false)) { context in
            if !Self.frames.isEmpty {
                let frameIndex = Int(context.date.timeIntervalSinceReferenceDate / Self.frameInterval) % Self.frames.count
                Image(uiImage: Self.frames[frameIndex])
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .accessibilityHidden(true)
            }
        }
    }

    private static let frames: [UIImage] = {
        guard
            let url = Bundle.main.url(forResource: "AgentIconSprite", withExtension: "png"),
            let sprite = UIImage(contentsOfFile: url.path),
            let cgImage = sprite.cgImage
        else {
            return []
        }

        let columns = 10
        let frameCount = 61
        let frameWidth = cgImage.width / columns
        let frameHeight = frameWidth
        return (0 ..< frameCount).compactMap { index in
            let x = (index % columns) * frameWidth
            let y = (index / columns) * frameHeight
            let rect = CGRect(x: x, y: y, width: frameWidth, height: frameHeight)
            guard let frame = cgImage.cropping(to: rect) else { return nil }
            return UIImage(cgImage: frame, scale: sprite.scale, orientation: .up)
        }
    }()
}

#Preview {
    ContentView()
}
