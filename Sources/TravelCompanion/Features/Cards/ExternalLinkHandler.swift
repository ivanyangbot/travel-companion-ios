import SafariServices
import SwiftUI
import UIKit
import Network

@MainActor
final class ExternalLinkHandler: ObservableObject {
    @Published var browserURL: URL?
    @Published var alertMessage: String?

    static func validatedHTTPSURL(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              let host = url.host,
              isPublicHost(host) else { return nil }
        return url
    }

    static func isPublicHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        guard normalized != "localhost", !normalized.hasSuffix(".localhost") else { return false }
        if let ipv4 = IPv4Address(normalized) {
            let octets = Array(ipv4.rawValue)
            guard octets.count == 4 else { return false }
            let privateOrLocal = octets[0] == 0 || octets[0] == 10 || octets[0] == 127 ||
                (octets[0] == 169 && octets[1] == 254) ||
                (octets[0] == 172 && (16 ... 31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168)
            return !privateOrLocal
        }
        if let ipv6 = IPv6Address(normalized) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16 else { return false }
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            let isUniqueLocal = (bytes[0] & 0xfe) == 0xfc
            let isIPv4Mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            if isUnspecified || isLoopback || isLinkLocal || isUniqueLocal { return false }
            if isIPv4Mapped {
                return isPublicHost("\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])")
            }
        }
        return true
    }

    func openPublicLink(_ value: String) {
        guard let url = Self.validatedHTTPSURL(value) else {
            alertMessage = String(localized: "link.httpsOnly")
            return
        }
        UIApplication.shared.open(url, options: [:]) { [weak self] opened in
            if !opened { self?.browserURL = url }
        }
    }

    func openInMaps(for place: PlaceSnapshot) {
        guard let item = AppleMapService.mapItem(for: place) else {
            alertMessage = String(localized: "link.noCoords")
            return
        }
        item.openInMaps()
    }
}

struct SafariBrowserView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
