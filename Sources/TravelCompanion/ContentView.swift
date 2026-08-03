import AuthenticationServices
import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var syncEngine: SyncEngine?
    @StateObject private var sharedLinkStore = PendingSharedLinkStore()
    @StateObject private var appleSignIn = AppleSignInStore()

    var body: some View {
        // Phase 1: the user always enters the main TabView. When not signed in,
        // travel data stays local-only (SwiftData) and the Journey tab hosts the
        // Apple Sign-In entry point. The sync engine skips all network calls
        // until a token appears in the keychain.
        mainTabs
    }

    private var mainTabs: some View {
        TabView {
            Tab("今日", systemImage: "map") {
                Group {
                    if let syncEngine {
                        TodayView(syncEngine: syncEngine)
                    } else {
                        ProgressView("正在准备今日…")
                    }
                }
            }

            Tab("旅程", systemImage: "calendar") {
                Group {
                    if let syncEngine {
                        ItineraryView(syncEngine: syncEngine, sharedLinkStore: sharedLinkStore, appleSignIn: appleSignIn)
                    } else {
                        ProgressView("正在准备行程…")
                    }
                }
            }

            Tab("Agent", systemImage: "sparkles") {
                Group {
                    if let syncEngine {
                        AgentWorkbenchView(syncEngine: syncEngine)
                    } else {
                        ProgressView("正在准备 Agent…")
                    }
                }
            }

            Tab("本", systemImage: "notebook") {
                Group {
                    if let syncEngine {
                        ExpenseListView(syncEngine: syncEngine)
                    } else {
                        ProgressView("正在准备本…")
                    }
                }
            }

            Tab("手书", systemImage: "book") {
                Group {
                    if let syncEngine {
                        NotesView(syncEngine: syncEngine)
                    } else {
                        ProgressView("正在准备手书…")
                    }
                }
            }
        }
        .tint(.indigo)
        .tabViewStyle(.sidebarAdaptable)
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
}

#Preview {
    ContentView()
}
