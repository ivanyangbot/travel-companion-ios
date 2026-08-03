import Foundation

/// Public URLs arrive from the Share Extension through this App Group handoff.
/// The host only pre-fills a card editor; it never fetches or scrapes a third-party app.
@MainActor
final class PendingSharedLinkStore: ObservableObject {
    static let appGroup = "group.com.nuanxinban.indo"
    static let pendingURLKey = "pendingPublicTravelLink"
    static let hostScheme = "travelcompanion"

    @Published private(set) var pendingURL: URL?
    @Published private(set) var pendingInviteToken: String?

    init() {
        consumeStoredURL()
    }

    func receiveHostURL(_ url: URL) {
        guard url.scheme?.lowercased() == Self.hostScheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if url.host?.lowercased() == "import", components?.queryItems?.isEmpty != false {
            consumeStoredURL()
        } else if url.host?.lowercased() == "join",
                  let token = components?.queryItems?.first(where: { $0.name == "token" })?.value,
                  !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pendingInviteToken = token
        }
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

    func markInviteDelivered() {
        pendingInviteToken = nil
    }

    private func clearStoredURL() {
        UserDefaults(suiteName: Self.appGroup)?.removeObject(forKey: Self.pendingURLKey)
    }
}
