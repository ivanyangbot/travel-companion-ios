import UIKit
import UniformTypeIdentifiers
import Network

/// Receives one public web URL, persists it in the shared App Group, and asks
/// iOS to open the host's registered `travelcompanion://import` scheme.
/// `NSExtensionContext.open` is public API; the persisted value is the safe
/// fallback if iOS declines the open request or the host is not running.
final class ShareViewController: UIViewController {
    private let appGroup = "group.com.nuanxinban.indo"
    private let pendingURLKey = "pendingPublicTravelLink"
    private let hostScheme = "travelcompanion"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        loadSharedURL()
    }

    private func loadSharedURL() {
        guard let item = extensionContext?.inputItems.first as? NSExtensionItem,
              let provider = item.attachments?.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) else {
            cancel(with: "未找到可添加的网页链接。")
            return
        }
        provider.loadObject(ofClass: NSURL.self) { [weak self] object, _ in
            let rawURL = (object as? NSURL)?.absoluteString
            DispatchQueue.main.async {
                guard let self,
                      let rawURL,
                      let url = URL(string: rawURL),
                      self.isPublicHTTPSURL(url) else {
                    self?.cancel(with: "只能添加有效的 HTTPS 网页链接。")
                    return
                }
                self.handoff(url)
            }
        }
    }

    private func handoff(_ url: URL) {
        UserDefaults(suiteName: appGroup)?.set(url.absoluteString, forKey: pendingURLKey)
        guard let hostURL = URL(string: "\(hostScheme)://import") else {
            extensionContext?.completeRequest(returningItems: nil)
            return
        }
        extensionContext?.open(hostURL) { [weak self] _ in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func isPublicHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false,
              url.user == nil,
              url.password == nil,
              let host = url.host else { return false }
        return isPublicHost(host)
    }

    private func isPublicHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        guard normalized != "localhost", !normalized.hasSuffix(".localhost") else { return false }
        if let ipv4 = IPv4Address(normalized) {
            let bytes = Array(ipv4.rawValue)
            return !(bytes[0] == 0 || bytes[0] == 10 || bytes[0] == 127 ||
                (bytes[0] == 169 && bytes[1] == 254) ||
                (bytes[0] == 172 && (16 ... 31).contains(bytes[1])) ||
                (bytes[0] == 192 && bytes[1] == 168))
        }
        if let ipv6 = IPv6Address(normalized) {
            let bytes = Array(ipv6.rawValue)
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

    private func cancel(with message: String) {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "TravelCompanionShareExtension",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
