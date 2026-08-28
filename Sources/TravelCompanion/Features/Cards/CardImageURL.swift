import Foundation
import SwiftUI

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

/// Consistent airline mark used by live Agent cards, confirmed candidates and
/// persisted itinerary cards. A failed/missing image always falls back to the
/// branded airplane tile instead of leaving a blank white square.
struct AirlineLogoBadge: View {
    let logoURL: URL?
    var size: CGFloat = 32
    var cornerRadius: CGFloat = 10

    var body: some View {
        Group {
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(size * 0.15)
                    case .empty:
                        ProgressView().controlSize(.mini).tint(.secondary)
                    case .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .background(logoURL == nil ? PrimaryTabPalette.accent : Color.white, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private var fallback: some View {
        Image(systemName: "airplane")
            .font(.system(size: size * 0.43, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PrimaryTabPalette.accent)
    }
}
