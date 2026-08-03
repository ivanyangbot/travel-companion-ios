import CryptoKit
import Foundation

enum WalletCryptoError: LocalizedError {
    case invalidCiphertext

    var errorDescription: String? { "卡包数据无法解密。" }
}

enum WalletCrypto {
    static func encrypt(_ secret: WalletSecret, using key: SymmetricKey) throws -> Data {
        let plaintext = try JSONEncoder().encode(secret)
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else { throw WalletCryptoError.invalidCiphertext }
        return combined
    }

    static func decrypt(_ ciphertext: Data, using key: SymmetricKey) throws -> WalletSecret {
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        return try JSONDecoder().decode(WalletSecret.self, from: plaintext)
    }
}
