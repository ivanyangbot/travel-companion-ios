import Foundation

/// Public URLs arrive from the Share Extension through this App Group handoff.
/// The host pre-fills the Agent; the backend reads only explicitly shared public pages.
@MainActor
final class PendingSharedLinkStore: ObservableObject {
    static let appGroup = "group.com.nuanxinban.indo"
    static let pendingURLKey = "pendingPublicTravelLink"
    static let pendingInviteTokenKey = "pendingTripInviteToken"
    static let hostScheme = "travelcompanion"

    @Published private(set) var pendingURL: URL?
    @Published private(set) var pendingInviteToken: String?

    init() {
        consumeStoredURL()
        consumeStoredInviteToken()
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
            UserDefaults(suiteName: Self.appGroup)?.set(token, forKey: Self.pendingInviteTokenKey)
        }
    }

    func consumeStoredURL() {
        guard let rawURL = UserDefaults(suiteName: Self.appGroup)?.string(forKey: Self.pendingURLKey) else { return }
        guard let url = ExternalLinkHandler.validatedHTTPSURL(rawURL) else {
            clearStoredURL()
            return
        }
        pendingURL = url
    }

    func markDelivered() {
        pendingURL = nil
        clearStoredURL()
    }

    func markInviteDelivered() {
        pendingInviteToken = nil
        UserDefaults(suiteName: Self.appGroup)?.removeObject(forKey: Self.pendingInviteTokenKey)
    }

    private func clearStoredURL() {
        UserDefaults(suiteName: Self.appGroup)?.removeObject(forKey: Self.pendingURLKey)
    }

    private func consumeStoredInviteToken() {
        guard let token = UserDefaults(suiteName: Self.appGroup)?.string(forKey: Self.pendingInviteTokenKey),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingInviteToken = token
    }
}
