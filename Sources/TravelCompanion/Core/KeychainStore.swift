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
struct KeychainStore {
    private static let defaultService = "com.yangzhiyuan.travelcompanion.wallet"
    private static let defaultAccount = "aes-gcm-key-v1"

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

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func existingKeyData() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainStoreError.status(status) }
        guard let data = result as? Data, data.count == 32 else { throw KeychainStoreError.unexpectedData }
        return data
    }
}
