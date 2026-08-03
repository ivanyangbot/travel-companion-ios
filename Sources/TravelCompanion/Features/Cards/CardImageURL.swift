import Foundation

/// Resolves a card's hosted image path to an absolute URL.
///
/// The backend stores a server-relative path (e.g. ``/v1/files/<name>``) so the
/// stored value is host-agnostic and works against whichever API base URL the
/// user configured. ``AsyncImage`` needs an absolute URL, so this prepends the
/// configured base URL. Absolute URLs are returned unchanged.
enum CardImageURL {
    static func resolve(_ value: String?) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return url
        }
        guard let base = AppConfiguration.apiBaseURL(),
              trimmed.hasPrefix("/") else { return nil }
        return URL(string: base.absoluteString + trimmed)
    }
}
