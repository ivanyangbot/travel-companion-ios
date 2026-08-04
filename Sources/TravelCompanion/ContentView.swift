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
    @State private var showsAgent = false
    @State private var selectedSection: MainSection = .journey
    @Namespace private var navigationSelection

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
            case .journey: "JourneyTabIcon"
            case .expenses: "MoneyTabIcon"
            case .notes: "NoteTabIcon"
            }
        }
    }

    var body: some View {
        // Phase 1: the user enters a custom floating navigation. When not signed in,
        // travel data stays local-only (SwiftData) and the Journey section hosts the
        // Apple Sign-In entry point. The sync engine skips all network calls
        // until a token appears in the keychain.
        mainTabs
    }

    private var mainTabs: some View {
        ZStack {
            activeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    customNavigation
                    Spacer(minLength: 0)
                    agentButton
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        // 两个按钮在同一满屏坐标系中布局，底边均严格距离物理屏幕 32pt。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showsAgent) {
            Group {
                if let syncEngine {
                    AgentWorkbenchView(syncEngine: syncEngine)
                } else {
                    ProgressView("正在准备 Agent…")
                }
            }
        }
        .task {
            guard syncEngine == nil else { return }
            let engine = SyncEngine(repository: SharedTripRepository(modelContext: modelContext))
            engine.observeAuthChanges()
            syncEngine = engine
            await engine.bootstrap()
            if scenePhase == .active {
                engine.startForegroundSync()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard let syncEngine else { return }
            if phase == .active {
                sharedLinkStore.consumeStoredURL()
                syncEngine.startForegroundSync()
                Task { await syncEngine.retry() }
            } else {
                syncEngine.stopForegroundSync()
            }
        }
        .onOpenURL { url in
            sharedLinkStore.receiveHostURL(url)
        }
    }

    private var agentButton: some View {
        Button {
            showsAgent = true
        } label: {
            AnimatedAgentIcon()
                .frame(width: 40, height: 40)
                .frame(width: 60, height: 60)
                .background(Color(red: 1, green: 110 / 255, blue: 0), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("打开 Agent")
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
                ProgressView("正在准备旅程…")
            }
        case .expenses:
            if let syncEngine {
                ExpenseListView(syncEngine: syncEngine)
            } else {
                ProgressView("正在准备账本…")
            }
        case .notes:
            if let syncEngine {
                NotesView(syncEngine: syncEngine)
            } else {
                ProgressView("正在准备手书…")
            }
        }
    }

    private var customNavigation: some View {
        HStack(spacing: 4) {
            ForEach(MainSection.allCases, id: \.self) { section in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        selectedSection = section
                    }
                } label: {
                    Image(section.icon)
                        .resizable()
                        .renderingMode(.template)
                        .scaledToFit()
                        .foregroundStyle(selectedSection == section ? Color.black : Color.white)
                        .frame(width: 25, height: 25)
                        .frame(width: 52, height: 52)
                        .background {
                            if selectedSection == section {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.white)
                                    .matchedGeometryEffect(id: "navigation-selection", in: navigationSelection)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: 172, height: 60)
        .background {
            ZStack {
                AdjustableBackdropBlur(
                    style: .systemUltraThinMaterialDark,
                    intensity: 0.1
                )
                Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255)
                    .opacity(0.16)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
            radius: 12,
            y: 12
        )
    }
}

private struct AdjustableBackdropBlur: UIViewRepresentable {
    let style: UIBlurEffect.Style
    let intensity: CGFloat

    func makeUIView(context: Context) -> AdjustableBlurEffectView {
        AdjustableBlurEffectView(style: style, intensity: intensity)
    }

    func updateUIView(_ view: AdjustableBlurEffectView, context: Context) {
        view.setIntensity(intensity)
    }
}

private final class AdjustableBlurEffectView: UIVisualEffectView {
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
