import CryptoKit
import Foundation
import Security

enum KeychainStoreError: LocalizedError {
    case unexpectedData
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unexpectedData:
            "无法读取本机加密密钥。"
        case let .status(status):
            SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串错误（\(status)）。"
        }
    }
}

/// Stores the wallet encryption key in the device-only keychain. The key cannot
/// migrate to another device or be restored from a backup.
struct KeychainStore: Sendable {
    private static let defaultService = "com.yangzhiyuan.travelcompanion.wallet"
    private static let defaultAccount = "aes-gcm-key-v1"
    private static let accessTokenAccount = "apple-access-token-v1"

    let service: String
    let account: String

    init(service: String = KeychainStore.defaultService, account: String = KeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    func walletKey() throws -> SymmetricKey {
        if let data = try existingKeyData() {
            return SymmetricKey(data: data)
        }

        var keyData = Data(repeating: 0, count: 32)
        let keyLength = keyData.count
        let randomStatus = keyData.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, keyLength, bytes.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw KeychainStoreError.status(randomStatus) }

        let addQuery = baseQuery.merging([
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]) { $1 }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecDuplicateItem, let existing = try existingKeyData() {
            return SymmetricKey(data: existing)
        }
        guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
        return SymmetricKey(data: keyData)
    }

    func deleteWalletKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.status(status) }
    }

    func accessToken() throws -> String? {
        guard let data = try data(for: Self.accessTokenAccount, expectedLength: nil) else { return nil }
        guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { throw KeychainStoreError.unexpectedData }
        return token
    }

    func saveAccessToken(_ token: String) throws {
        let data = Data(token.utf8)
        let query = query(for: Self.accessTokenAccount)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            let addStatus = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainStoreError.status(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw KeychainStoreError.status(updateStatus)
        }
    }

    func deleteAccessToken() throws {
        let status = SecItemDelete(query(for: Self.accessTokenAccount) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainStoreError.status(status) }
    }

    private var baseQuery: [String: Any] { query(for: account) }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func existingKeyData() throws -> Data? { try data(for: account, expectedLength: 32) }

    /// Reads raw keychain data for the given account. The wallet key is always
    /// 32 bytes; the access token is a variable-length string, so
    /// `expectedLength` is `nil` for it and any non-empty data is accepted.
    private func data(for account: String, expectedLength: Int?) throws -> Data? {
        var query = query(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = result as? Data, !data.isEmpty else { throw KeychainStoreError.unexpectedData }
        if let expectedLength, data.count != expectedLength { throw KeychainStoreError.unexpectedData }
        return data
    }
}
