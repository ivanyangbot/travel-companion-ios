import SwiftUI
import SwiftData

@main
struct TravelCompanionApp: App {
    private let modelContainer: ModelContainer = WalletProtectedModelContainer.make()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(modelContainer)
    }
}

/// SwiftData has no per-property encryption. This keeps its backing database in
/// a directory protected with `NSFileProtectionComplete`; wallet secrets are
/// additionally AES-GCM encrypted before being handed to SwiftData.
private enum WalletProtectedModelContainer {
    static func make() -> ModelContainer {
        let schema = Schema([SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self, LocalWalletItem.self, RouteCacheRecord.self, CardLegPreference.self, LocalMemoList.self, LocalMemoItem.self])
        let fileManager = FileManager.default
        let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TravelCompanion", isDirectory: true)
        let storeURL = directory.appendingPathComponent("TravelCompanion.store")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: directory.path)
            let configuration = ModelConfiguration("TravelCompanion", schema: schema, url: storeURL, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            // Protect a pre-existing store as well as a store created on first launch.
            if fileManager.fileExists(atPath: storeURL.path) {
                try? fileManager.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: storeURL.path)
            }
            return container
        } catch {
            fatalError(String(format: String(localized: "app.fatalStoreError"), error.localizedDescription))
        }
    }
}
