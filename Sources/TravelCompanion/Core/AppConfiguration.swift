import Foundation

enum AppConfiguration {
    static let apiBaseURLKey = "TravelCompanionAPIBaseURL"

    static func apiBaseURL() -> URL? {
        let configuredValue = UserDefaults.standard.string(forKey: apiBaseURLKey)
            ?? Bundle.main.object(forInfoDictionaryKey: apiBaseURLKey) as? String
        return configuredValue.flatMap(validAPIBaseURL(from:))
    }

    static func validAPIBaseURL(from value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            return nil
        }
        if scheme == "https" { return url }
#if DEBUG
        if scheme == "http", isLoopbackHost(url.host) { return url }
#endif
        return nil
    }

    static func apiBaseURLValidationMessage(for value: String) -> String? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              url.host != nil else {
            return "请输入完整的 API 地址，例如 https://api.example.com。"
        }
        if scheme == "https" { return nil }
#if DEBUG
        if scheme == "http", isLoopbackHost(url.host) { return nil }
        return "DEBUG 仅允许 http://localhost、127.0.0.1 或 ::1；其他地址必须使用 HTTPS。"
#else
        return "发布版本只允许 HTTPS API 地址。"
#endif
    }

    static func saveAPIBaseURL(_ value: String) -> URL? {
        guard let url = validAPIBaseURL(from: value) else { return nil }
        UserDefaults.standard.set(url.absoluteString, forKey: apiBaseURLKey)
        return url
    }

    private static func isLoopbackHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
