import XCTest
@testable import TravelCompanion

final class TravelCardsTests: XCTestCase {
    @MainActor
    func testOnlyPublicHTTPSURLsAreAccepted() {
        XCTAssertEqual(ExternalLinkHandler.validatedHTTPSURL("https://example.com/share")?.host, "example.com")
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("http://example.com"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https:///missing-host"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("not a url"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://user:pass@example.com"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://localhost"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://127.0.0.1"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://10.1.2.3"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://169.254.1.1"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://[::1]"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://[fe80::1]"))
        XCTAssertNil(ExternalLinkHandler.validatedHTTPSURL("https://[fc00::1]"))
    }

    func testCardKindsHaveExplicitTextAndSymbols() {
        XCTAssertEqual(TravelCardSnapshot.Kind.flight.title, "机票")
        XCTAssertEqual(TravelCardSnapshot.Kind.hotel.systemImage, "bed.double")
        XCTAssertEqual(TravelCardSnapshot.Kind.activity.title, "活动")
    }

    func testCardPatchEncodesExplicitPlaceClearOnly() throws {
        let request = CardRequest(position: 1, fieldsToClear: ["place"])
        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["position"] as? Int, 1)
        XCTAssertTrue(object["place"] is NSNull)
        XCTAssertNil(object["title"])
    }

    func testCardPatchEncodesImagesValueAndExplicitClear() throws {
        let withValue = CardRequest(images: ["/v1/files/abc.jpg"])
        let withObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(withValue)) as? [String: Any])
        XCTAssertEqual(withObject["images"] as? [String], ["/v1/files/abc.jpg"])

        let cleared = CardRequest(fieldsToClear: ["images"])
        let clearedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(cleared)) as? [String: Any])
        XCTAssertTrue(clearedObject["images"] is NSNull)
    }

    func testCardSnapshotDecodesImagesAndFoldsLegacyImageURL() throws {
        UserDefaults.standard.set("https://api.example.com", forKey: AppConfiguration.apiBaseURLKey)
        defer { UserDefaults.standard.removeObject(forKey: AppConfiguration.apiBaseURLKey) }

        let json = """
        {"id":7,"dayId":1,"kind":"activity","title":"西湖","startAt":"2026-10-01T09:00:00Z",
         "imageUrl":"/v1/files/abc.jpg","position":0,"updatedAt":"2026-10-01T08:00:00Z"}
        """.data(using: .utf8)!
        let card = try JSONDecoder.sharedTrip.decode(TravelCardSnapshot.self, from: json)
        XCTAssertEqual(card.images, ["/v1/files/abc.jpg"])
        XCTAssertEqual(CardImageURL.resolve(card.images?.first)?.absoluteString, "https://api.example.com/v1/files/abc.jpg")
        // An absolute URL is returned unchanged.
        XCTAssertEqual(CardImageURL.resolve("https://cdn.example.com/x.png")?.absoluteString, "https://cdn.example.com/x.png")
        XCTAssertNil(CardImageURL.resolve(nil))
    }

    func testCardPriceFormatsMinorUnitsByCurrency() {
        XCTAssertEqual(CardPrice.format(minor: 6000, currency: "CNY")?.contains("60"), true)
        XCTAssertEqual(CardPrice.minorUnits(from: "60", currency: "CNY"), 6000)
        XCTAssertEqual(CardPrice.minorUnits(from: "60", currency: "JPY"), 60)
        XCTAssertEqual(CardPrice.format(minor: 600, currency: "JPY")?.contains("600"), true)
        XCTAssertNil(CardPrice.minorUnits(from: "abc", currency: "CNY"))
        XCTAssertNil(CardPrice.minorUnits(from: "", currency: "CNY"))
    }
}
