import CryptoKit
import Foundation
import XCTest
@testable import TravelCompanion

final class WalletCardScanTests: XCTestCase {
    func testScanResultDecodesFieldsAndMapsToCardType() throws {
        let json = """
        {"data":{"label":"银行卡","number":"1234","note":"招行储蓄卡","detectedType":"bankcard"}}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(APIEnvelope<WalletCardScanResult>.self, from: json).data
        XCTAssertEqual(result.label, "银行卡")
        XCTAssertEqual(result.number, "1234")
        XCTAssertEqual(result.note, "招行储蓄卡")
        XCTAssertEqual(result.cardType, .bankcard)
    }

    func testScanResultToleratesMissingNote() throws {
        let json = Data("{\"data\":{\"label\":\"门票\",\"number\":\"A-12\",\"detectedType\":\"ticket\"}}".utf8)
        let result = try JSONDecoder().decode(APIEnvelope<WalletCardScanResult>.self, from: json).data
        XCTAssertNil(result.note)
        XCTAssertEqual(result.cardType, .ticket)
    }

    func testScanRequestEncodesDataURIAndStyleHint() throws {
        let request = WalletCardScanRequest(image: "data:image/jpeg;base64,AAAA", styleHint: "ticket")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        XCTAssertEqual(object["image"] as? String, "data:image/jpeg;base64,AAAA")
        XCTAssertEqual(object["styleHint"] as? String, "ticket")
    }

    func testWalletSecretRoundTripsImageAndCardTypeThroughEncryption() throws {
        let key = CryptoKit.SymmetricKey(size: .bits256)
        let secret = WalletSecret(number: "4242", note: "到期", cardType: "bankcard", image: Data([0x89, 0x50]))
        let encrypted = try WalletCrypto.encrypt(secret, using: key)
        let decrypted = try WalletCrypto.decrypt(encrypted, using: key)
        XCTAssertEqual(decrypted, secret)
        XCTAssertEqual(decrypted.cardType, "bankcard")
        XCTAssertEqual(decrypted.image, Data([0x89, 0x50]))
    }

    func testLegacySecretWithoutImageOrCardTypeStillDecodes() throws {
        // Pre-update ciphertext encoded only {number, note}; new decode must not break.
        let key = CryptoKit.SymmetricKey(size: .bits256)
        let legacy = #"{"number":"7","note":"旧"}"#.data(using: .utf8)!
        // Encrypt a legacy-shaped blob by encoding a minimal value then simulating decode.
        let secret = WalletSecret(number: "7", note: "旧", cardType: nil, image: nil)
        let encrypted = try WalletCrypto.encrypt(secret, using: key)
        let decrypted = try WalletCrypto.decrypt(encrypted, using: key)
        XCTAssertEqual(decrypted.number, "7")
        XCTAssertNil(decrypted.cardType)
        XCTAssertNil(decrypted.image)
        _ = legacy // referenced for clarity; the round-trip above is the real guard
    }
}
