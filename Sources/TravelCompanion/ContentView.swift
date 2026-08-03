import AuthenticationServices
import SwiftUI
import SwiftData
import WebKit

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
        }
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
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(.white)
                                    .matchedGeometryEffect(id: "navigation-selection", in: navigationSelection)
                            }
                        }
                }
                .accessibilityLabel(section.title)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(width: 172, height: 60)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255).opacity(0.4))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1.5)
        }
        .shadow(
            color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
            radius: 12,
            y: 12
        )
    }
}

/// 通过 WebKit 原样解码 GIF，确保透明帧的 disposal 语义正确，避免逐帧渲染产生残影。
private struct AnimatedAgentIcon: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.loadHTMLString(Self.html, baseURL: Bundle.main.resourceURL)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    private static let html = """
    <!doctype html>
    <html>
    <head>
      <meta name="viewport" content="width=device-width, height=device-height, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
      <style>
        * { box-sizing: border-box; }
        html, body { width: 100%; height: 100%; margin: 0; padding: 0; overflow: hidden; background: transparent; }
        body { display: flex; align-items: center; justify-content: center; }
        img { width: 100%; height: 100%; object-fit: contain; display: block; filter: brightness(0) invert(1); }
      </style>
    </head>
    <body><img src="AgentIcon.gif" alt=""></body>
    </html>
    """
}

#Preview {
    ContentView()
}
