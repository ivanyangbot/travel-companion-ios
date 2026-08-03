import CryptoKit
import SwiftData
import XCTest
@testable import TravelCompanion

final class WalletTests: XCTestCase {
    func testAESGCMRoundTripAndTamperDetection() throws {
        let key = SymmetricKey(size: .bits256)
        let secret = WalletSecret(number: "E12345678", note: "2029 年到期")
        let encrypted = try WalletCrypto.encrypt(secret, using: key)

        XCTAssertNotEqual(encrypted, try JSONEncoder().encode(secret))
        XCTAssertEqual(try WalletCrypto.decrypt(encrypted, using: key), secret)

        var tampered = encrypted
        tampered[tampered.startIndex] ^= 0x01
        XCTAssertThrowsError(try WalletCrypto.decrypt(tampered, using: key))
    }

    func testMaskingKeepsOnlyLastFourCharacters() {
        XCTAssertEqual(WalletMasker.masked("E12345678"), "•••••5678")
        XCTAssertEqual(WalletMasker.masked("1234"), "••••")
        XCTAssertEqual(WalletMasker.masked("12"), "••••")
    }

    func testKeychainKeyCanBeReadAgainWithinTheSameDevice() throws {
        let store = KeychainStore(service: "com.yangzhiyuan.travelcompanion.tests.\(UUID().uuidString)")
        defer { try? store.deleteWalletKey() }

        let firstKey = try store.walletKey()
        let ciphertext = try WalletCrypto.encrypt(WalletSecret(number: "P9876543", note: nil), using: firstKey)
        let keyAfterRestart = try store.walletKey()

        XCTAssertEqual(try WalletCrypto.decrypt(ciphertext, using: keyAfterRestart).number, "P9876543")
    }

    @MainActor
    func testSwiftDataOnlyStoresCiphertextAndWalletModelIsNotANetworkDTO() throws {
        let schema = Schema([LocalWalletItem.self])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let number = "G1234567890"
        let encrypted = try WalletCrypto.encrypt(WalletSecret(number: number, note: "私人备注"), using: SymmetricKey(size: .bits256))
        context.insert(LocalWalletItem(label: "护照", encryptedSecret: encrypted))
        try context.save()

        let persisted = try XCTUnwrap(context.fetch(FetchDescriptor<LocalWalletItem>()).first)
        XCTAssertFalse(persisted.encryptedSecret.contains(Data(number.utf8)))
        XCTAssertFalse(LocalWalletItem.self is any Encodable.Type)
        XCTAssertFalse(LocalWalletItem.self is any Decodable.Type)
    }
}
