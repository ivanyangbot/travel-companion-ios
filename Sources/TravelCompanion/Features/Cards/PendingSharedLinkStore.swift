import Foundation

/// Public URLs arrive from the Share Extension through this App Group handoff.
/// The host only pre-fills a card editor; it never fetches or scrapes a third-party app.
@MainActor
final class PendingSharedLinkStore: ObservableObject {
    static let appGroup = "group.com.nuanxinban.indo"
    static let pendingURLKey = "pendingPublicTravelLink"
    static let hostScheme = "travelcompanion"

    @Published private(set) var pendingURL: URL?

    init() {
        consumeStoredURL()
    }

    func receiveHostURL(_ url: URL) {
        guard url.scheme?.lowercased() == Self.hostScheme,
              url.host?.lowercased() == "import",
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.isEmpty != false else { return }
        consumeStoredURL()
    }

    func consumeStoredURL() {
        guard let rawURL = UserDefaults(suiteName: Self.appGroup)?.string(forKey: Self.pendingURLKey),
              let url = ExternalLinkHandler.validatedHTTPSURL(rawURL) else { return }
        pendingURL = url
        clearStoredURL()
    }

    func markDelivered() {
        pendingURL = nil
    }

    private func clearStoredURL() {
        UserDefaults(suiteName: Self.appGroup)?.removeObject(forKey: Self.pendingURLKey)
    }
}
