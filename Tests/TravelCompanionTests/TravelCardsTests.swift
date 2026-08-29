import Combine
import Foundation
import SwiftData
import UIKit
import XCTest
@testable import TravelCompanion

final class TravelCardsTests: XCTestCase {
    func testFlightRouteTitleOnlyKeepsDepartureAndDestination() {
        XCTAssertEqual(
            AgentFlightDisplay.routeTitle(
                from: "丽江三义国际机场 (LJG)",
                to: "北京首都国际机场 T2(PEK)",
                fallback: "中国国航 CA9634 丽江 → 北京"
            ),
            "丽江三义 → 北京首都 T2"
        )
        XCTAssertEqual(
            AgentFlightDisplay.routeTitle(
                from: "Los Angeles International Airport (LAX)",
                to: "Heathrow Airport T5 (LHR)",
                fallback: "Fallback"
            ),
            "Los Angeles → Heathrow T5"
        )
        XCTAssertEqual(
            AgentFlightDisplay.routeTitle(from: nil, to: "PEK", fallback: "原始标题"),
            "原始标题"
        )
    }

    func testTodayQuickActionsSwapSharingForSignInWhenSignedOut() {
        XCTAssertEqual(
            TodayQuickAction.visibleActions(isAuthenticated: false),
            [.tripSelection, .reload, .settings, .signIn]
        )
        XCTAssertEqual(
            TodayQuickAction.visibleActions(isAuthenticated: true),
            [.addCompanion, .tripSelection, .reload, .settings]
        )
    }

    func testAgentHomeQuickActionsNeverContainSharingOrReload() {
        XCTAssertEqual(
            TodayQuickAction.agentHomeActions(isAuthenticated: false),
            [.tripSelection, .settings, .signIn]
        )
        XCTAssertEqual(
            TodayQuickAction.agentHomeActions(isAuthenticated: true),
            [.tripSelection, .settings]
        )
    }

    func testItineraryListFormatsDateRailAndDayHeaderConsistently() {
        let day = TripDaySnapshot(date: "2026-09-12", position: 0)

        XCTAssertEqual(ItineraryListPresentation.timelineLabel(day, false), "09.12 六")
        XCTAssertEqual(ItineraryListPresentation.timelineLabel(day, true), "今日 六")
        XCTAssertEqual(ItineraryListPresentation.monthDay(for: day), "09.12")
        XCTAssertEqual(ItineraryListPresentation.weekday(for: day), "六")
    }

    func testItineraryListFormatsRouteDistanceAndDurationLikeReference() {
        XCTAssertEqual(CardLegEstimateView.itineraryListDistanceText(218), "218m")
        XCTAssertEqual(CardLegEstimateView.itineraryListDistanceText(2_828_003), "2828km")
        XCTAssertEqual(CardLegEstimateView.itineraryListDistanceText(27_740), "27.7km")
        XCTAssertEqual(CardLegEstimateView.itineraryListDurationText(1), "1min")
        XCTAssertEqual(CardLegEstimateView.itineraryListDurationText(4_020), "67min")
    }

    func testItineraryListDerivesEightCharacterSummaryInPersistedOrder() {
        let later = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "古城夜游",
            startAt: Date(timeIntervalSince1970: 20),
            position: 1
        )
        let earlier = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "抵达丽江",
            startAt: Date(timeIntervalSince1970: 10),
            position: 0
        )
        let day = TripDaySnapshot(date: "2026-09-12", position: 0, cards: [later, earlier])

        XCTAssertEqual(ItineraryListPresentation.daySummary(for: day), "抵达丽江，古城夜")
    }

    func testItineraryListFallsBackToFirstDayAndFindsToday() {
        let days = [
            TripDaySnapshot(date: "2026-09-12", position: 0),
            TripDaySnapshot(date: "2026-09-13", position: 1)
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13))!

        XCTAssertEqual(ItineraryListPresentation.selectedIndex(date: nil, in: days), 0)
        XCTAssertEqual(ItineraryListPresentation.selectedIndex(date: "2026-09-13", in: days), 1)
        XCTAssertEqual(ItineraryListPresentation.todayIndex(in: days, today: today), 1)
    }

    func testItineraryListMarksOnlyCurrentOrImmediatelyUpcomingCard() throws {
        let formatter = ISO8601DateFormatter()
        let current = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "当前活动",
            startAt: try XCTUnwrap(formatter.date(from: "2026-09-12T09:00:00Z")),
            endAt: try XCTUnwrap(formatter.date(from: "2026-09-12T10:00:00Z")),
            position: 0
        )
        let next = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "下一活动",
            startAt: try XCTUnwrap(formatter.date(from: "2026-09-12T11:00:00Z")),
            position: 1
        )
        let day = TripDaySnapshot(date: "2026-09-12", position: 0, cards: [next, current])

        XCTAssertEqual(
            ItineraryListPresentation.currentOrNextCardID(
                in: [day],
                now: try XCTUnwrap(formatter.date(from: "2026-09-12T09:30:00Z"))
            ),
            current.id
        )
        XCTAssertEqual(
            ItineraryListPresentation.currentOrNextCardID(
                in: [day],
                now: try XCTUnwrap(formatter.date(from: "2026-09-12T10:30:00Z"))
            ),
            next.id
        )
        XCTAssertNil(
            ItineraryListPresentation.currentOrNextCardID(
                in: [day],
                now: try XCTUnwrap(formatter.date(from: "2026-09-12T14:00:01Z"))
            )
        )
    }

    func testLargeImageCardUsesReferenceImageGeometry() {
        XCTAssertEqual(ItineraryLargeImageCardLayout.outerPadding, 12)
        XCTAssertEqual(ItineraryLargeImageCardLayout.contentSpacing, 12)
        XCTAssertEqual(ItineraryLargeImageCardLayout.imageAspectRatio, 38.0 / 21.0)
        XCTAssertEqual(
            ItineraryLargeImageCardLayout.imageHeight(cardWidth: 366),
            189,
            accuracy: 0.001
        )
    }

    @MainActor
    func testItineraryListManualPositionControlsOrderAndRouteAdjacencyKey() {
        let first = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "手动第一站",
            startAt: Date(timeIntervalSince1970: 200),
            position: 0
        )
        let second = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "手动第二站",
            startAt: Date(timeIntervalSince1970: 100),
            position: 1
        )

        XCTAssertEqual(ItineraryListPresentation.orderedCards([second, first]).map(\.id), [first.id, second.id])
        XCTAssertNotEqual(
            CardLegStore.legKey(origin: first, destination: second),
            CardLegStore.legKey(origin: second, destination: first)
        )
    }

    func testItineraryListMovesDraggedCardAroundTarget() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            ItineraryListPresentation.movingCard(first, onto: third, in: [first, second, third]),
            [second, third, first]
        )
        XCTAssertEqual(
            ItineraryListPresentation.movingCard(first, to: 1, in: [first, second, third]),
            [second, first, third]
        )
        XCTAssertEqual(
            ItineraryListPresentation.movingCard(third, onto: first, in: [first, second, third]),
            [third, first, second]
        )
        XCTAssertEqual(
            ItineraryListPresentation.movingCard(second, onto: second, in: [first, second, third]),
            [first, second, third]
        )
    }

    func testItineraryDragUsesVariableEdgeSpeedAndReleasePosition() {
        let viewport = CGRect(x: 0, y: 100, width: 390, height: 500)
        XCTAssertEqual(ItineraryDragInteraction.autoScrollVelocity(fingerY: viewport.midY, viewport: viewport), 0)
        let upperSlow = ItineraryDragInteraction.autoScrollVelocity(fingerY: 190, viewport: viewport)
        let upperFast = ItineraryDragInteraction.autoScrollVelocity(fingerY: 110, viewport: viewport)
        let lowerSlow = ItineraryDragInteraction.autoScrollVelocity(fingerY: 510, viewport: viewport)
        let lowerFast = ItineraryDragInteraction.autoScrollVelocity(fingerY: 590, viewport: viewport)
        XCTAssertLessThan(upperFast, upperSlow)
        XCTAssertLessThan(upperSlow, 0)
        XCTAssertGreaterThan(lowerFast, lowerSlow)
        XCTAssertGreaterThan(lowerSlow, 0)
        XCTAssertLessThanOrEqual(abs(upperFast), 720)
        XCTAssertLessThanOrEqual(lowerFast, 720)

        XCTAssertEqual(
            ItineraryDragInteraction.releaseCenter(
                startFrame: CGRect(x: 20, y: 40, width: 100, height: 60),
                translation: CGSize(width: 15, height: 90)
            ),
            CGPoint(x: 85, y: 160)
        )
    }

    @MainActor
    func testItineraryAutoScrollControllerScrollsWhileManualPanIsLocked() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 500))
        scrollView.contentSize = CGSize(width: 390, height: 2_000)
        let controller = ItineraryListScrollController()
        controller.connect(to: scrollView)

        controller.setDragLocked(true)
        XCTAssertFalse(scrollView.panGestureRecognizer.isEnabled)
        XCTAssertEqual(controller.scroll(by: 120), 120)
        XCTAssertEqual(scrollView.contentOffset.y, 120)
        XCTAssertEqual(controller.scroll(by: 5_000), 1_500)
        XCTAssertEqual(scrollView.contentOffset.y, 1_500)
        XCTAssertEqual(controller.scroll(by: -5_000), 0)
        XCTAssertEqual(scrollView.contentOffset.y, 0)

        controller.setDragLocked(false)
        XCTAssertTrue(scrollView.panGestureRecognizer.isEnabled)
    }

    func testItineraryCardSwipeDistinguishesHorizontalIntentAndSnapsActions() {
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionWidth, 68)
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionCount, 3)
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionsWidth, 204)

        XCTAssertTrue(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                CGSize(width: -40, height: 8),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertFalse(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                CGSize(width: 40, height: 8),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertTrue(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                CGSize(width: 40, height: 8),
                actionsAlreadyRevealed: true
            )
        )
        XCTAssertFalse(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                CGSize(width: -8, height: 40),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertFalse(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                CGSize(width: -9, height: 1),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertTrue(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: -420, y: 80),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertFalse(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: -80, y: 420),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertFalse(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: 420, y: 80),
                actionsAlreadyRevealed: false
            )
        )
        XCTAssertTrue(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: 420, y: 80),
                actionsAlreadyRevealed: true
            )
        )
        XCTAssertFalse(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: 420, y: 80),
                actionsAlreadyRevealed: true,
                touchLocationX: 396,
                viewWidth: 391
            )
        )
        XCTAssertTrue(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: 420, y: 80),
                actionsAlreadyRevealed: true,
                touchLocationX: 120,
                viewWidth: 391
            )
        )
        XCTAssertTrue(
            ItineraryCardSwipeInteraction.shouldBeginSwipe(
                velocity: CGPoint(x: -420, y: 80),
                actionsAlreadyRevealed: false,
                touchLocationX: 396,
                viewWidth: 391
            )
        )

        XCTAssertEqual(
            ItineraryCardSwipeInteraction.clampedOffset(baseOffset: 0, translation: -300),
            -ItineraryCardSwipeInteraction.actionsWidth
        )
        XCTAssertEqual(
            ItineraryCardSwipeInteraction.clampedOffset(
                baseOffset: -ItineraryCardSwipeInteraction.actionsWidth,
                translation: 300
            ),
            0
        )
        XCTAssertTrue(ItineraryCardSwipeInteraction.shouldRevealActions(currentOffset: -52, projectedOffset: -90))
        XCTAssertFalse(ItineraryCardSwipeInteraction.shouldRevealActions(currentOffset: -12, projectedOffset: -100))
        XCTAssertFalse(ItineraryCardSwipeInteraction.shouldRevealActions(currentOffset: -40, projectedOffset: -40))

        XCTAssertEqual(ItineraryCardSwipeInteraction.drawerOffset(slotFromTrailing: 1, revealedWidth: 30), -10)
        XCTAssertEqual(ItineraryCardSwipeInteraction.drawerOffset(slotFromTrailing: 2, revealedWidth: 30), -20)
        XCTAssertEqual(ItineraryCardSwipeInteraction.drawerOffset(slotFromTrailing: 1, revealedWidth: 102), -34)
        XCTAssertEqual(ItineraryCardSwipeInteraction.drawerOffset(slotFromTrailing: 2, revealedWidth: 102), -68)
        XCTAssertEqual(ItineraryCardSwipeInteraction.drawerOffset(slotFromTrailing: 1, revealedWidth: 204), -68)
        XCTAssertEqual(ItineraryCardSwipeInteraction.drawerOffset(slotFromTrailing: 2, revealedWidth: 204), -136)
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionVisibility(revealedWidth: 0), 0)
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionVisibility(revealedWidth: 12), 0.5)
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionVisibility(revealedWidth: 24), 1)
        XCTAssertEqual(ItineraryCardSwipeInteraction.actionVisibility(revealedWidth: 204), 1)

        XCTAssertEqual(
            ItineraryCardSwipeInteraction.projectedOffset(
                baseOffset: 0,
                translation: -30,
                predictedTranslation: -300
            ),
            -67.4,
            accuracy: 0.001
        )
    }

    func testItineraryCardAgentPromptIncludesSelectedCardContext() {
        let card = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "上海公安局（第二航厦）",
            startAt: Date(timeIntervalSince1970: 1_725_600_600),
            endAt: Date(timeIntervalSince1970: 1_725_602_400),
            place: PlaceSnapshot(
                id: 9,
                name: "上海浦东机场",
                address: nil,
                latitude: nil,
                longitude: nil,
                placeId: nil,
                cityCode: nil,
                updatedAt: .now
            )
        )

        let prompt = ItineraryListPresentation.agentPrompt(for: card, date: "2026-09-12")
        XCTAssertTrue(prompt.contains("上海公安局（第二航厦）"))
        XCTAssertTrue(prompt.contains("2026-09-12"))
        XCTAssertTrue(prompt.contains("上海浦东机场"))
        XCTAssertTrue(prompt.contains("时间："))
    }

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

    func testInviteUsesHTTPSLandingPageAndPreservesToken() async throws {
        let client = APIClient(baseURL: try XCTUnwrap(URL(string: "https://indo.example.test")))
        let url = try await client.inviteLandingURL(token: "invite_token-123")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "indo.example.test")
        XCTAssertEqual(components.path, "/join")
        XCTAssertEqual(components.queryItems?.first(where: { $0.name == "token" })?.value, "invite_token-123")
    }

    @MainActor
    func testBrowserDeepLinkTokenIsRecognizedByApp() throws {
        let store = PendingSharedLinkStore()
        store.receiveHostURL(try XCTUnwrap(URL(string: "travelcompanion://join?token=invite_token-123")))
        XCTAssertEqual(store.pendingInviteToken, "invite_token-123")
        let restoredStore = PendingSharedLinkStore()
        XCTAssertEqual(restoredStore.pendingInviteToken, "invite_token-123")
        restoredStore.markInviteDelivered()
        XCTAssertNil(restoredStore.pendingInviteToken)
    }

    @MainActor
    func testSharedLinkRemainsPersistedUntilAgentSubmissionIsAcknowledged() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: PendingSharedLinkStore.appGroup))
        let url = "https://xhslink.com/a/test-share"
        defaults.set(url, forKey: PendingSharedLinkStore.pendingURLKey)
        defer { defaults.removeObject(forKey: PendingSharedLinkStore.pendingURLKey) }

        let firstStore = PendingSharedLinkStore()
        XCTAssertEqual(firstStore.pendingURL?.absoluteString, url)
        XCTAssertEqual(defaults.string(forKey: PendingSharedLinkStore.pendingURLKey), url)

        let restoredBeforeDelivery = PendingSharedLinkStore()
        XCTAssertEqual(restoredBeforeDelivery.pendingURL?.absoluteString, url)
        restoredBeforeDelivery.markDelivered()

        XCTAssertNil(restoredBeforeDelivery.pendingURL)
        XCTAssertNil(defaults.string(forKey: PendingSharedLinkStore.pendingURLKey))
    }

    func testTripMembersDecodeForSharingSheet() throws {
        let data = Data("""
        {"userId":1,"displayName":"创建者","email":null,"role":"owner","joinedAt":"2026-10-01T00:00:00Z"}
        """.utf8)
        let member = try JSONDecoder.sharedTrip.decode(TripMemberSummary.self, from: data)
        XCTAssertEqual(member.visibleName, "创建者")
        XCTAssertTrue(member.isOwner)
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

    func testCardSnapshotDecodesOrderedSourceLinks() throws {
        let json = Data("""
        {"id":10,"dayId":1,"kind":"hotel","title":"海景酒店","startAt":"2026-10-01T09:00:00Z",
         "url":"https://www.xiaohongshu.com/explore/one",
         "sources":[{"provider":"xiaohongshu","url":"https://www.xiaohongshu.com/explore/one","title":"第一篇攻略","author":"作者甲"},{"provider":"xiaohongshu","url":"https://www.xiaohongshu.com/explore/two","title":"第二篇攻略","author":"作者乙"}],
         "position":0,"updatedAt":"2026-10-01T08:00:00Z"}
        """.utf8)

        let card = try JSONDecoder.sharedTrip.decode(TravelCardSnapshot.self, from: json)

        XCTAssertEqual(card.sources?.map(\.url), [
            "https://www.xiaohongshu.com/explore/one",
            "https://www.xiaohongshu.com/explore/two",
        ])
        XCTAssertEqual(card.sources?.compactMap(\.title), ["第一篇攻略", "第二篇攻略"])
    }

    func testFlightSnapshotDecodesServerAirlineMetadata() throws {
        let json = Data("""
        {"id":11,"dayId":1,"kind":"flight","title":"ID6331 努拉莱伊至科莫多","startAt":"2026-09-26T03:45:00Z",
         "bookingCode":"ID6331","airlineCode":"ID","airlineName":"Batik Air","airlineLogoURL":"/v1/airlines/logos/ID.png",
         "position":0,"updatedAt":"2026-09-20T08:00:00Z"}
        """.utf8)

        let card = try JSONDecoder.sharedTrip.decode(TravelCardSnapshot.self, from: json)

        XCTAssertEqual(card.airlineCode, "ID")
        XCTAssertEqual(card.airlineName, "Batik Air")
        XCTAssertEqual(card.airlineLogoURL, "/v1/airlines/logos/ID.png")
    }

    func testCardSnapshotDecodesServerLargeImageDecisionAndKeepsOldSnapshotsCompact() throws {
        let immersiveJSON = Data("""
        {"id":8,"dayId":1,"kind":"activity","title":"丽江古城","startAt":"2026-10-01T09:00:00Z",
         "images":["/v1/files/lijiang.jpg"],"imageScore":94,"showLargeImage":true,
         "position":0,"updatedAt":"2026-10-01T08:00:00Z"}
        """.utf8)
        let immersive = try JSONDecoder.sharedTrip.decode(TravelCardSnapshot.self, from: immersiveJSON)
        XCTAssertEqual(immersive.imageScore, 94)
        XCTAssertTrue(immersive.showLargeImage)

        let legacyJSON = Data("""
        {"id":9,"dayId":1,"kind":"activity","title":"上海公安局","startAt":"2026-10-01T10:00:00Z",
         "images":["/v1/files/office.jpg"],"position":1,"updatedAt":"2026-10-01T08:00:00Z"}
        """.utf8)
        let legacy = try JSONDecoder.sharedTrip.decode(TravelCardSnapshot.self, from: legacyJSON)
        XCTAssertEqual(legacy.imageScore, 0)
        XCTAssertFalse(legacy.showLargeImage)
    }

    func testCardPriceFormatsMinorUnitsByCurrency() {
        XCTAssertEqual(CardPrice.format(minor: 6000, currency: "CNY")?.contains("60"), true)
        XCTAssertEqual(CardPrice.minorUnits(from: "60", currency: "CNY"), 6000)
        XCTAssertEqual(CardPrice.minorUnits(from: "60", currency: "JPY"), 60)
        XCTAssertEqual(CardPrice.format(minor: 600, currency: "JPY")?.contains("600"), true)
        XCTAssertNil(CardPrice.minorUnits(from: "abc", currency: "CNY"))
        XCTAssertNil(CardPrice.minorUnits(from: "", currency: "CNY"))
    }

    @MainActor
    func testSignedOutUserCanCreateAndFullyEditLocalTrips() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: false
        )

        await engine.bootstrap()
        XCTAssertEqual(engine.status, .localOnly)
        XCTAssertNotNil(engine.trip)
        XCTAssertEqual(engine.trips.count, 1)

        let start = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 1)))
        let end = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 3)))
        await engine.saveSetup(destination: "杭州", startDate: start, endDate: end, currency: "CNY")
        XCTAssertEqual(engine.trip?.destination, "杭州")

        await engine.addDay(start)
        let day = try XCTUnwrap(engine.trip?.days.first)
        XCTAssertNil(day.serverID)

        await engine.addCard(
            to: day,
            request: CardRequest(kind: .activity, title: "西湖", startAt: "2026-10-01T09:00:00Z", notes: "本地")
        )
        var card = try XCTUnwrap(engine.trip?.days.first?.cards.first)
        XCTAssertNil(card.serverID)
        XCTAssertEqual(card.title, "西湖")

        await engine.updateCard(card, request: CardRequest(title: "西湖漫步", notes: "已编辑"))
        card = try XCTUnwrap(engine.trip?.days.first?.cards.first)
        XCTAssertEqual(card.title, "西湖漫步")

        await engine.deleteCard(card)
        XCTAssertTrue(engine.trip?.days.first?.cards.isEmpty == true)
        await engine.deleteDay(try XCTUnwrap(engine.trip?.days.first))
        XCTAssertTrue(engine.trip?.days.isEmpty == true)

        await engine.createTrip(destination: "上海", startDate: start, endDate: end, currency: "CNY")
        XCTAssertEqual(engine.trips.count, 2)
        XCTAssertEqual(engine.trip?.destination, "上海")

        let hangzhou = try XCTUnwrap(engine.trips.first { $0.displayName == "杭州" })
        await engine.updateTrip(
            hangzhou,
            destination: "苏州",
            startDate: start,
            endDate: end,
            currency: "CNY"
        )
        XCTAssertEqual(try repository.cachedTrip(id: hangzhou.id)?.destination, "苏州")

        let shanghai = try XCTUnwrap(engine.trips.first { $0.displayName == "上海" })
        await engine.deleteTrip(shanghai)
        XCTAssertEqual(engine.trips.map(\.displayName), ["苏州"])
        XCTAssertEqual(engine.trip?.destination, "苏州")
        XCTAssertEqual(engine.selectedTripID, hangzhou.id)
        XCTAssertTrue(try repository.pendingOperations().isEmpty)
    }

    @MainActor
    func testDraggedCardOrderPersistsAndRenumbersEveryPosition() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let cards = [
            TravelCardSnapshot(
                dayID: 1,
                kind: .activity,
                title: "第一站",
                startAt: Date(timeIntervalSince1970: 100),
                position: 0
            ),
            TravelCardSnapshot(
                dayID: 1,
                kind: .activity,
                title: "第二站",
                startAt: Date(timeIntervalSince1970: 200),
                position: 1
            ),
            TravelCardSnapshot(
                dayID: 1,
                kind: .activity,
                title: "第三站",
                startAt: Date(timeIntervalSince1970: 300),
                position: 2
            ),
        ]
        let trip = SharedTripSnapshot(
            id: -1,
            destination: "丽江",
            startDate: "2026-09-12",
            endDate: "2026-09-12",
            currency: "CNY",
            version: 0,
            updatedAt: .now,
            days: [TripDaySnapshot(date: "2026-09-12", position: 0, cards: cards)]
        )
        try repository.save(trip)
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: false
        )
        await engine.bootstrap()

        let loadedDay = try XCTUnwrap(engine.trip?.days.first)
        await engine.reorderCards(
            in: loadedDay,
            orderedCardIDs: loadedDay.cards.reversed().map(\.id)
        )

        XCTAssertEqual(engine.trip?.days.first?.cards.map(\.title), ["第三站", "第二站", "第一站"])
        XCTAssertEqual(engine.trip?.days.first?.cards.map(\.position), [0, 1, 2])
        let reloadedTrip = try XCTUnwrap(repository.cachedTrip(id: -1))
        XCTAssertEqual(reloadedTrip.days.first?.cards.map(\.title), ["第三站", "第二站", "第一站"])
        XCTAssertEqual(reloadedTrip.days.first?.cards.map(\.position), [0, 1, 2])
        XCTAssertTrue(try repository.pendingOperations().isEmpty)
    }

    @MainActor
    func testCrossDayDragUpdatesDatesAndQueuesBackendDayAndPositionPatches() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let formatter = ISO8601DateFormatter()
        let movedStart = try XCTUnwrap(formatter.date(from: "2026-09-12T09:30:00Z"))
        let movedEnd = try XCTUnwrap(formatter.date(from: "2026-09-12T10:30:00Z"))
        let movedCard = TravelCardSnapshot(
            serverID: 101,
            dayID: 11,
            kind: .activity,
            title: "跨日移动",
            startAt: movedStart,
            endAt: movedEnd,
            position: 0
        )
        let sourceRemainder = TravelCardSnapshot(
            serverID: 102,
            dayID: 11,
            kind: .activity,
            title: "源日保留",
            startAt: try XCTUnwrap(formatter.date(from: "2026-09-12T11:00:00Z")),
            position: 1
        )
        let destinationExisting = TravelCardSnapshot(
            serverID: 201,
            dayID: 22,
            kind: .activity,
            title: "目标已有",
            startAt: try XCTUnwrap(formatter.date(from: "2026-09-13T08:00:00Z")),
            position: 0
        )
        try repository.save(SharedTripSnapshot(
            id: 42,
            destination: "丽江",
            startDate: "2026-09-12",
            endDate: "2026-09-13",
            currency: "CNY",
            version: 7,
            updatedAt: .now,
            days: [
                TripDaySnapshot(serverID: 11, date: "2026-09-12", position: 0, cards: [movedCard, sourceRemainder]),
                TripDaySnapshot(serverID: 22, date: "2026-09-13", position: 1, cards: [destinationExisting]),
            ]
        ))
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: true
        )
        await engine.bootstrap()

        let sourceDay = try XCTUnwrap(engine.trip?.days.first(where: { $0.serverID == 11 }))
        let destinationDay = try XCTUnwrap(engine.trip?.days.first(where: { $0.serverID == 22 }))
        let loadedMovedCard = try XCTUnwrap(sourceDay.cards.first(where: { $0.serverID == 101 }))
        await engine.moveCard(
            loadedMovedCard,
            from: sourceDay,
            to: destinationDay,
            destinationIndex: 1
        )

        let updatedSource = try XCTUnwrap(engine.trip?.days.first(where: { $0.serverID == 11 }))
        let updatedDestination = try XCTUnwrap(engine.trip?.days.first(where: { $0.serverID == 22 }))
        XCTAssertEqual(updatedSource.cards.map(\.serverID), [102])
        XCTAssertEqual(updatedSource.cards.map(\.position), [0])
        XCTAssertEqual(updatedDestination.cards.map(\.serverID), [201, 101])
        XCTAssertEqual(updatedDestination.cards.map(\.position), [0, 1])
        let updatedMovedCard = try XCTUnwrap(updatedDestination.cards.last)
        XCTAssertEqual(updatedMovedCard.dayID, 22)
        XCTAssertEqual(updatedMovedCard.startAt.timeIntervalSince(movedStart), 86_400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(updatedMovedCard.endAt).timeIntervalSince(movedEnd), 86_400, accuracy: 0.001)

        let operations = try repository.pendingOperations()
        XCTAssertEqual(operations.count, 2)
        let movedOperation = try XCTUnwrap(operations.first(where: { $0.path == "/v1/cards/101" }))
        let movedBody = try XCTUnwrap(JSONSerialization.jsonObject(with: movedOperation.body) as? [String: Any])
        XCTAssertEqual(movedBody["dayId"] as? Int, 22)
        XCTAssertEqual(movedBody["position"] as? Int, 1)
        XCTAssertEqual(movedBody["startAt"] as? String, "2026-09-13T09:30:00.000Z")
        XCTAssertEqual(movedBody["endAt"] as? String, "2026-09-13T10:30:00.000Z")

        let sourceOperation = try XCTUnwrap(operations.first(where: { $0.path == "/v1/cards/102" }))
        let sourceBody = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceOperation.body) as? [String: Any])
        XCTAssertNil(sourceBody["dayId"])
        XCTAssertEqual(sourceBody["position"] as? Int, 0)
    }

    @MainActor
    func testSignedOutBootstrapHidesAccountBackedTripsFromEditableLocalMode() async throws {
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        try repository.save(SharedTripSnapshot(
            id: 42,
            destination: "云端行程",
            startDate: "2026-10-01",
            endDate: "2026-10-02",
            currency: "CNY",
            version: 7,
            updatedAt: .now,
            days: []
        ))
        let engine = SyncEngine(
            repository: repository,
            apiClient: APIClient(baseURL: nil),
            authenticatedOverride: false
        )

        await engine.bootstrap()

        XCTAssertEqual(engine.status, .localOnly)
        XCTAssertNotNil(engine.trip)
        XCTAssertTrue(try XCTUnwrap(engine.trip?.id) < 0)
        XCTAssertTrue(engine.trips.allSatisfy { $0.id < 0 })
        XCTAssertTrue(try repository.cachedTrips().contains { $0.id == 42 })
    }

    @MainActor
    func testFirstLoginImportsLocalSharedDataAndLeavesWalletOnDevice() async throws {
        FirstLoginMigrationURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: sessionConfiguration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self, LocalWalletItem.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let repository = SharedTripRepository(modelContext: context)
        let card = TravelCardSnapshot(
            serverID: 20,
            dayID: 10,
            kind: .activity,
            title: "西湖",
            startAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")),
            place: PlaceSnapshot(
                id: 30,
                name: "西湖风景名胜区",
                address: "杭州",
                latitude: 30.25,
                longitude: 120.15,
                placeId: "old-place",
                cityCode: "0571",
                updatedAt: .now
            ),
            notes: "本地卡片",
            position: 0
        )
        let day = TripDaySnapshot(serverID: 10, date: "2026-10-01", position: 0, cards: [card])
        let expense = ExpenseSnapshot(
            serverID: 40,
            amountMinor: 12_500,
            currency: "CNY",
            category: .tickets,
            occurredOn: "2026-10-01",
            note: "本地支出",
            cardID: 20
        )
        let localTrip = SharedTripSnapshot(
            id: -1,
            destination: "杭州",
            startDate: "2026-10-01",
            endDate: "2026-10-02",
            currency: "CNY",
            version: 7,
            updatedAt: .now,
            days: [day],
            expenses: [expense]
        )
        try repository.save(localTrip)
        try repository.enqueue(method: "PATCH", path: "/v1/trip", tripID: -1, body: Data("{}".utf8), baseVersion: 7)

        let wallet = LocalWalletItem(label: "只留本地", encryptedSecret: Data("wallet-ciphertext".utf8))
        context.insert(wallet)
        try context.save()

        let suiteName = "FirstLoginMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = SyncEngine(
            repository: repository,
            apiClient: client,
            localMigrationStore: LocalTripMigrationStore(defaults: defaults),
            authenticatedOverride: true
        )

        await engine.bootstrap()

        XCTAssertEqual(engine.trip?.id, 42)
        XCTAssertEqual(engine.trip?.days.first?.cards.first?.title, "西湖")
        XCTAssertEqual(engine.trip?.expenses.first?.amountMinor, 12_500)
        XCTAssertEqual(engine.trip?.expenses.first?.cardID, 201)
        XCTAssertTrue(try repository.pendingOperations().isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<LocalWalletItem>()).first?.encryptedSecret, wallet.encryptedSecret)
        XCTAssertEqual(
            FirstLoginMigrationURLProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            [
                "GET /v1/trips", "POST /v1/trips", "GET /v1/trip",
                "POST /v1/days", "GET /v1/trip", "POST /v1/cards",
                "GET /v1/trip", "POST /v1/expenses", "GET /v1/trip",
                "GET /v1/trips", "GET /v1/trip",
            ]
        )
        let outboundBodies = FirstLoginMigrationURLProtocol.requests.compactMap(\.httpBody)
        XCTAssertFalse(outboundBodies.contains { String(decoding: $0, as: UTF8.self).contains("wallet-ciphertext") })
    }

    @MainActor
    func testFirstLoginDoesNotMigratePositiveIDAccountCacheOrLegacyPendingState() async throws {
        FirstLoginMigrationURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let positiveAccountCache = SharedTripSnapshot(
            id: 99,
            destination: "其他账号的缓存",
            startDate: "2026-11-01",
            endDate: "2026-11-02",
            currency: "CNY",
            version: 4,
            updatedAt: .now,
            days: []
        )
        try repository.save(positiveAccountCache)
        let suiteName = "PositiveAccountCacheTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrationStore = LocalTripMigrationStore(defaults: defaults)
        try migrationStore.save(PendingLocalTripMigration(source: positiveAccountCache))
        let engine = SyncEngine(
            repository: repository,
            apiClient: client,
            localMigrationStore: migrationStore,
            authenticatedOverride: true
        )

        await engine.bootstrap()

        XCTAssertEqual(FirstLoginMigrationURLProtocol.requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["GET /v1/trips"])
        XCTAssertNil(engine.trip)
        XCTAssertTrue(try repository.cachedTrips().contains { $0.id == 99 })
        XCTAssertFalse(migrationStore.hasPendingMigration)
    }

    @MainActor
    func testInvalidLegacyPendingCannotKeepMigrationBatchActiveForExistingAccount() async throws {
        FirstLoginMigrationURLProtocol.reset()
        FirstLoginMigrationURLProtocol.tripVersion = 3
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let repository = SharedTripRepository(modelContext: ModelContext(container))
        let localTrip = SharedTripSnapshot(
            id: -1, destination: "本地旅程", startDate: "2026-12-01", endDate: "2026-12-02",
            currency: "CNY", version: 0, updatedAt: .now, days: []
        )
        try repository.save(localTrip)
        let legacyAccountCache = SharedTripSnapshot(
            id: 99, destination: "旧账号缓存", startDate: "2026-11-01", endDate: "2026-11-02",
            currency: "CNY", version: 4, updatedAt: .now, days: []
        )
        let suiteName = "LegacyMigrationBatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrationStore = LocalTripMigrationStore(defaults: defaults)
        try migrationStore.save(PendingLocalTripMigration(source: legacyAccountCache))
        migrationStore.beginInitialImportBatch()
        let engine = SyncEngine(
            repository: repository,
            apiClient: client,
            localMigrationStore: migrationStore,
            authenticatedOverride: true
        )

        await engine.bootstrap()

        XCTAssertFalse(FirstLoginMigrationURLProtocol.requests.contains { $0.httpMethod == "POST" })
        XCTAssertEqual(engine.trip?.id, 42)
        XCTAssertTrue(try repository.cachedTrips().contains { $0.id == -1 })
        XCTAssertFalse(migrationStore.hasPendingMigration)
        XCTAssertFalse(migrationStore.isInitialImportBatchActive)
    }

    @MainActor
    func testExplicitTripDeselectionKeepsForegroundRefreshSilent() async throws {
        FirstLoginMigrationURLProtocol.reset()
        FirstLoginMigrationURLProtocol.tripVersion = 3
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FirstLoginMigrationURLProtocol.self]
        let client = APIClient(
            baseURL: try XCTUnwrap(URL(string: "https://api.example.test")),
            session: URLSession(configuration: configuration),
            tokenProvider: { "test-token" }
        )
        let container = try ModelContainer(
            for: SharedTripMirror.self, PendingOperation.self, ConfirmedAIDraftCard.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let suiteName = "ExplicitTripDeselectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let engine = SyncEngine(
            repository: SharedTripRepository(modelContext: ModelContext(container)),
            apiClient: client,
            localMigrationStore: LocalTripMigrationStore(defaults: defaults),
            authenticatedOverride: true
        )

        await engine.bootstrap()
        XCTAssertEqual(engine.selectedTripID, 42)

        await engine.clearSelectedTrip()
        var publishedStatuses: [SyncEngine.Status] = []
        let observation = engine.$status.dropFirst().sink { publishedStatuses.append($0) }

        await engine.refresh()
        withExtendedLifetime(observation) {}

        XCTAssertTrue(engine.hasExplicitlyDeselectedTrip)
        XCTAssertNil(engine.selectedTripID)
        XCTAssertNil(engine.trip)
        XCTAssertEqual(engine.status, .synced)
        XCTAssertFalse(publishedStatuses.contains(.syncing))
    }
}

private final class FirstLoginMigrationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var tripVersion = 0

    static func reset() {
        requests = []
        tripVersion = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        let statusCode: Int
        let body: Data

        switch (method, path) {
        case ("GET", "/v1/trips"):
            statusCode = 200
            body = Data((Self.tripVersion == 0 ? "{\"data\":[]}" : Self.tripSummaryListEnvelope).utf8)
        case ("POST", "/v1/trips"):
            statusCode = 200
            body = Data(Self.tripSummaryEnvelope.utf8)
        case ("GET", "/v1/trip") where request.url?.query?.contains("afterVersion=3") == true:
            statusCode = 204
            body = Data()
        case ("GET", "/v1/trip"):
            statusCode = 200
            body = Data(Self.tripEnvelope(version: Self.tripVersion).utf8)
        case ("POST", "/v1/days"):
            Self.tripVersion = 1
            statusCode = 200
            body = Data(Self.metaEnvelope(version: 1).utf8)
        case ("POST", "/v1/cards"):
            Self.tripVersion = 2
            statusCode = 200
            body = Data(Self.metaEnvelope(version: 2).utf8)
        case ("POST", "/v1/expenses"):
            Self.tripVersion = 3
            statusCode = 200
            body = Data(Self.metaEnvelope(version: 3).utf8)
        default:
            statusCode = 404
            body = Data("{\"error\":{\"code\":\"not_found\",\"message\":\"unexpected request\",\"requestId\":\"test\"}}".utf8)
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static let tripSummaryEnvelope = """
    {"data":{"id":42,"destination":"杭州","startDate":"2026-10-01","endDate":"2026-10-02","currency":"CNY","version":3,"updatedAt":"2026-10-01T00:00:00Z","role":"owner","joinedAt":"2026-10-01T00:00:00Z"}}
    """

    private static let tripSummaryListEnvelope = """
    {"data":[{"id":42,"destination":"杭州","startDate":"2026-10-01","endDate":"2026-10-02","currency":"CNY","version":3,"updatedAt":"2026-10-01T00:00:00Z","role":"owner","joinedAt":"2026-10-01T00:00:00Z"}]}
    """

    private static func metaEnvelope(version: Int) -> String {
        "{\"meta\":{\"tripVersion\":\(version),\"operationId\":null,\"conflict\":false,\"serverUpdatedAt\":\"2026-10-01T00:00:00Z\"}}"
    }

    private static func tripEnvelope(version: Int) -> String {
        let day = """
        {"id":101,"date":"2026-10-01","position":0,"updatedAt":"2026-10-01T00:00:00Z","cards":\(version >= 2 ? "[\(cardJSON)]" : "[]")}
        """
        let expenses = version >= 3 ? "[\(expenseJSON)]" : "[]"
        let days = version >= 1 ? "[\(day)]" : "[]"
        return """
        {"data":{"id":42,"destination":"杭州","startDate":"2026-10-01","endDate":"2026-10-02","currency":"CNY","version":\(version),"updatedAt":"2026-10-01T00:00:00Z","days":\(days),"expenses":\(expenses)}}
        """
    }

    private static let cardJSON = """
    {"id":201,"dayId":101,"kind":"activity","title":"西湖","startAt":"2026-10-01T09:00:00Z","place":{"id":301,"name":"西湖风景名胜区","address":"杭州","latitude":30.25,"longitude":120.15,"placeId":"old-place","cityCode":"0571","updatedAt":"2026-10-01T00:00:00Z"},"notes":"本地卡片","position":0,"updatedAt":"2026-10-01T00:00:00Z"}
    """

    private static let expenseJSON = """
    {"id":401,"amountMinor":12500,"currency":"CNY","category":"tickets","occurredOn":"2026-10-01","note":"本地支出","cardId":201,"updatedAt":"2026-10-01T00:00:00Z"}
    """
}
