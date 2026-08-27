import AuthenticationServices
import Foundation

/// Posted on `NotificationCenter` whenever the user signs in or signs out, so
/// non-UI subsystems (notably ``SyncEngine``) can react without holding a
/// direct reference. `userInfo` is empty; callers re-query the keychain.
extension Notification.Name {
    static let appleSignInStateChanged = Notification.Name("AppleSignInStateChanged")
}

@MainActor
final class AppleSignInStore: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isSigningIn = false
    @Published var errorMessage: String?
    /// Display name from the most recent successful sign-in; used by the
    /// Journey tab to greet the user and by views that need to know whether
    /// a name is available without re-querying the keychain.
    @Published private(set) var displayName: String?

    private let keychain: KeychainStore
    private var pending: CheckedContinuation<ASAuthorizationAppleIDCredential, Error>?

    init(keychain: KeychainStore = KeychainStore()) {
        self.keychain = keychain
        isAuthenticated = (try? keychain.accessToken()) != nil
    }

    /// Configures the authorization request issued by ``SignInWithAppleButton``.
    /// Apple only delivers the user's real name on the very first authorization,
    /// so the fullName scope is always requested and the server persists it then.
    nonisolated func configure(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    /// Entry point used by the SwiftUI ``SignInWithAppleButton``. It awaits the
    /// authorization result the button delivers through ``handle(result:)``.
    func signIn(apiClient: APIClient) async {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil
        defer { isSigningIn = false }
        do {
            let credential = try await awaitCredential()
            guard let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8)
            else { throw AppleSignInError.missingIdentityToken }
            let fullName = credential.fullName
                .map { PersonNameComponentsFormatter().string(from: $0) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            let result = try await apiClient.signInWithApple(identityToken: identityToken, fullName: (fullName?.isEmpty == false) ? fullName : nil)
            try keychain.saveAccessToken(result.accessToken)
            displayName = result.user.displayName ?? fullName
            isAuthenticated = true
            NotificationCenter.default.post(name: .appleSignInStateChanged, object: nil)
        } catch is CancellationError {
            // User dismissed the Apple sheet; no error banner needed.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func signOut() -> Bool {
        errorMessage = nil
        do {
            try keychain.deleteAccessToken()
            displayName = nil
            isAuthenticated = false
            NotificationCenter.default.post(name: .appleSignInStateChanged, object: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Bridge from ``SignInWithAppleButton``'s `onCompletion` into the async
    /// ``signIn(apiClient:)`` flow. Must be nonisolated to satisfy the button's
    /// closure signature; it hops to the main actor to resume the continuation.
    nonisolated func handle(result: Result<ASAuthorization, Error>) {
        Task { @MainActor in
            defer { pending = nil }
            switch result {
            case .success(let authorization):
                guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                    pending?.resume(throwing: AppleSignInError.invalidCredential)
                    return
                }
                pending?.resume(returning: credential)
            case .failure(let error):
                pending?.resume(throwing: error)
            }
        }
    }

    private func awaitCredential() async throws -> ASAuthorizationAppleIDCredential {
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
        }
    }
}

enum AppleSignInError: LocalizedError {
    case missingIdentityToken
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .missingIdentityToken: String(localized: "error.noIdentityToken")
        case .invalidCredential: String(localized: "error.invalidCredential")
        }
    }
}
