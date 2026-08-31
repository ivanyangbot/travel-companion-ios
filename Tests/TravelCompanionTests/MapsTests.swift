import XCTest
import CoreLocation
import SwiftData
@testable import TravelCompanion

final class MapsTests: XCTestCase {
    func testFlightArcIsCurvedAndKeepsExactEndpoints() throws {
        let origin = CLLocationCoordinate2D(latitude: 39.941, longitude: 116.455)
        let destination = CLLocationCoordinate2D(latitude: 35.549, longitude: 139.779)
        let coordinates = TodayFlightArcGeometry.coordinates(
            from: origin,
            to: destination
        )

        XCTAssertEqual(coordinates.count, 49)
        XCTAssertEqual(try XCTUnwrap(coordinates.first).latitude, origin.latitude, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(coordinates.first).longitude, origin.longitude, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(coordinates.last).latitude, destination.latitude, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(coordinates.last).longitude, destination.longitude, accuracy: 0.000_001)
        let midpoint = coordinates[coordinates.count / 2]
        XCTAssertGreaterThan(
            abs(midpoint.latitude - (origin.latitude + destination.latitude) / 2),
            0.5
        )
        XCTAssertNotNil(TodayFlightArcGeometry.midpointAndScreenAngle(for: coordinates))
    }

    func testFlightArcUsesShortAntimeridianPath() {
        let coordinates = TodayFlightArcGeometry.coordinates(
            from: CLLocationCoordinate2D(latitude: 35, longitude: 170),
            to: CLLocationCoordinate2D(latitude: 37, longitude: -170)
        )

        for (left, right) in zip(coordinates, coordinates.dropFirst()) {
            XCTAssertLessThan(abs(right.longitude - left.longitude), 2)
        }
        XCTAssertEqual(coordinates.last!.longitude, 190, accuracy: 0.000_001)
    }

    func testFlightRouteResolverIgnoresPOIsAndPreservesCardIdentity() async throws {
        let flight = TravelCardSnapshot(
            dayID: 1,
            kind: .flight,
            title: "CA181",
            startAt: .now,
            fromAirport: "北京首都国际机场 PEK",
            toAirport: "东京羽田机场 HND"
        )
        let poi = TravelCardSnapshot(
            dayID: 1,
            kind: .activity,
            title: "浅草寺",
            startAt: .now
        )

        let routes = await AppleMapService.resolveFlightRoutes(cards: [poi, flight]) { airport in
            if airport.contains("PEK") {
                return PlaceSearchResult(
                    id: "pek",
                    name: "Beijing Capital International Airport",
                    address: nil,
                    latitude: 40.0799,
                    longitude: 116.6031,
                    placeId: nil
                )
            }
            if airport.contains("HND") {
                return PlaceSearchResult(
                    id: "hnd",
                    name: "Haneda Airport",
                    address: nil,
                    latitude: 35.5494,
                    longitude: 139.7798,
                    placeId: nil
                )
            }
            return nil
        }

        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(route.cardID, flight.id)
        XCTAssertEqual(route.fromAirport, flight.fromAirport)
        XCTAssertEqual(route.toAirport, flight.toAirport)
        XCTAssertEqual(route.originLatitude, 40.0799, accuracy: 0.000_001)
        XCTAssertEqual(route.destinationLongitude, 139.7798, accuracy: 0.000_001)
    }

    func testFlightRouteResolverKeepsIncompleteFlightOffMap() async {
        let flight = TravelCardSnapshot(
            dayID: 1,
            kind: .flight,
            title: "待确认航班",
            startAt: .now,
            fromAirport: "PEK",
            toAirport: nil
        )

        let routes = await AppleMapService.resolveFlightRoutes(cards: [flight]) { _ in
            XCTFail("Incomplete flight must not start a map search")
            return nil
        }

        XCTAssertTrue(routes.isEmpty)
    }

    func testAirportSearchUsesIATACodeFirstWithoutChineseLocationBias() {
        let queries = AppleMapService.airportSearchQueries(
            for: "纽约约翰·肯尼迪国际机场（JFK）"
        )

        XCTAssertEqual(queries.first, "JFK airport")
        XCTAssertFalse(queries.first?.contains("机场") == true)
        XCTAssertFalse(queries.first?.contains("JFK JFK") == true)
    }

    func testAirportResolutionUsesReferenceAPIBeforeMapKit() async throws {
        let cgk = AirportReference(
            iata: "CGK",
            icao: "WIII",
            name: "Soekarno-Hatta International Airport",
            city: "Jakarta",
            country: "ID",
            latitude: -6.12557,
            longitude: 106.655998,
            elevationFt: 34,
            timeZone: nil
        )

        let location = await AppleMapService.resolveAirportLocation(
            "雅加达苏加诺-哈达国际机场 CGK",
            lookupByCode: { code in
                XCTAssertEqual(code, "CGK")
                return cgk
            },
            searchAPI: { _ in
                XCTFail("Exact IATA lookup should finish API resolution")
                return []
            },
            searchMap: { _, _ in
                XCTFail("MapKit must not run after an API hit")
                return []
            }
        )

        XCTAssertEqual(try XCTUnwrap(location).iata, "CGK")
        XCTAssertEqual(location?.country, "ID")
        XCTAssertEqual(location?.latitude ?? 0, -6.12557, accuracy: 0.000_001)
        XCTAssertEqual(location?.longitude ?? 0, 106.655998, accuracy: 0.000_001)
    }

    func testAirportResolutionFallsBackToMapKitAfterAPIMiss() async throws {
        let location = await AppleMapService.resolveAirportLocation(
            "东京羽田机场 HND",
            lookupByCode: { _ in nil },
            searchAPI: { _ in [] },
            searchMap: { query, _ in
                guard query == "HND airport" else { return [] }
                return [PlaceSearchResult(
                    id: "hnd",
                    name: "Tokyo International Airport (HND)",
                    address: "Tokyo, Japan",
                    latitude: 35.5494,
                    longitude: 139.7798,
                    placeId: nil
                )]
            }
        )

        XCTAssertEqual(try XCTUnwrap(location).iata, "HND")
        XCTAssertEqual(location?.latitude ?? 0, 35.5494, accuracy: 0.000_001)
        XCTAssertEqual(location?.longitude ?? 0, 139.7798, accuracy: 0.000_001)
    }

    func testFlightRouteUsesFreshCoordinatesStoredOnCard() async throws {
        let resolvedAt = Date()
        let origin = FlightAirportLocationSnapshot(
            query: "CGK",
            iata: "CGK",
            icao: "WIII",
            name: "Soekarno-Hatta International Airport",
            city: "Jakarta",
            country: "ID",
            latitude: -6.12557,
            longitude: 106.655998,
            resolvedAt: resolvedAt
        )
        let destination = FlightAirportLocationSnapshot(
            query: "DPS",
            iata: "DPS",
            icao: "WADD",
            name: "I Gusti Ngurah Rai International Airport",
            city: "Denpasar",
            country: "ID",
            latitude: -8.74817,
            longitude: 115.167,
            resolvedAt: resolvedAt
        )
        let card = TravelCardSnapshot(
            dayID: 1,
            kind: .flight,
            title: "GA402",
            startAt: .now,
            fromAirport: "CGK",
            toAirport: "DPS",
            fromAirportLocation: origin,
            toAirportLocation: destination
        )

        let routes = await AppleMapService.resolveFlightRoutes(cards: [card]) { _ in
            XCTFail("Fresh coordinates stored on the card must skip lookup")
            return nil
        }

        let route = try XCTUnwrap(routes.first)
        XCTAssertEqual(route.originLocation, origin)
        XCTAssertEqual(route.destinationLocation, destination)
    }

    func testAirportResultPrefersExactIATACodeOverDomesticFirstResult() throws {
        let domesticWrongResult = PlaceSearchResult(
            id: "wrong",
            name: "虹桥机场城市航站楼",
            address: "中国上海",
            latitude: 31.2304,
            longitude: 121.4737,
            placeId: nil
        )
        let jfk = PlaceSearchResult(
            id: "jfk",
            name: "John F. Kennedy International Airport (JFK)",
            address: "Queens, NY, United States",
            latitude: 40.6413,
            longitude: -73.7781,
            placeId: nil
        )

        let selected = AppleMapService.preferredAirportResult(
            in: [domesticWrongResult, jfk],
            airport: "纽约约翰·肯尼迪国际机场 JFK",
            code: "JFK",
            allowsCodeQueryFallback: true
        )

        XCTAssertEqual(try XCTUnwrap(selected).id, "jfk")
    }

    func testAirportResultAllowsLocalizedAirportForDedicatedIATAQuery() throws {
        let localized = PlaceSearchResult(
            id: "hnd",
            name: "東京国際空港",
            address: "東京都大田区",
            latitude: 35.5494,
            longitude: 139.7798,
            placeId: nil
        )

        let selected = AppleMapService.preferredAirportResult(
            in: [localized],
            airport: "东京羽田机场 HND",
            code: "HND",
            allowsCodeQueryFallback: true
        )

        XCTAssertEqual(try XCTUnwrap(selected).id, "hnd")
    }

    func testAirportResultRejectsUnrelatedFallbackForFullNameQuery() {
        let wrongResult = PlaceSearchResult(
            id: "wrong",
            name: "虹桥机场城市航站楼",
            address: "中国上海",
            latitude: 31.2304,
            longitude: 121.4737,
            placeId: nil
        )

        let selected = AppleMapService.preferredAirportResult(
            in: [wrongResult],
            airport: "纽约约翰·肯尼迪国际机场 JFK",
            code: "JFK",
            allowsCodeQueryFallback: false
        )

        XCTAssertNil(selected)
    }

    func testPlaceRankingRejectsLocalBrandMatchWhenDestinationTermsDoNotMatch() throws {
        let localWrongResult = PlaceSearchResult(
            id: "shijiazhuang",
            name: "Fairfield by Marriott Shijiazhuang High-Tech Zone",
            address: "Shijiazhuang, Hebei, China",
            latitude: 38.02,
            longitude: 114.60,
            placeId: nil
        )
        let intendedResult = PlaceSearchResult(
            id: "jakarta",
            name: "Fairfield by Marriott Jakarta Soekarno-Hatta Airport",
            address: "Tangerang, Jakarta, Indonesia",
            latitude: -6.13,
            longitude: 106.66,
            placeId: nil
        )

        let ranked = AppleMapService.rankedPlaceResults(
            query: "fairfield jakarta airport",
            city: nil,
            candidates: [localWrongResult, intendedResult]
        )

        XCTAssertEqual(ranked.map(\.id), ["jakarta"])
    }

    func testPlaceRankingUsesExplicitCityAndRemovesDuplicateCoordinates() throws {
        let wrongCity = PlaceSearchResult(
            id: "wrong-city",
            name: "Fairfield Hotel",
            address: "Shanghai, China",
            latitude: 31.23,
            longitude: 121.47,
            placeId: nil
        )
        let jakarta = PlaceSearchResult(
            id: "jakarta-a",
            name: "Fairfield Hotel",
            address: "Jakarta, Indonesia",
            latitude: -6.130001,
            longitude: 106.660001,
            placeId: nil
        )
        let duplicate = PlaceSearchResult(
            id: "jakarta-b",
            name: "Fairfield Hotel",
            address: "Jakarta, Indonesia",
            latitude: -6.130002,
            longitude: 106.660002,
            placeId: nil
        )

        let ranked = AppleMapService.rankedPlaceResults(
            query: "Fairfield",
            city: "Jakarta",
            candidates: [wrongCity, jakarta, duplicate]
        )

        XCTAssertEqual(ranked.first?.id, "jakarta-a")
        XCTAssertEqual(ranked.count, 2)
    }

    private func edgeMember(
        _ suffix: Int,
        order: Int,
        degrees: CGFloat,
        position: CGFloat,
        edge: MapLibreEdgePinEdge = .top,
        highlighted: Bool = false
    ) -> MapLibreEdgePinGroupMember {
        MapLibreEdgePinGroupMember(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
            displayOrder: order,
            edge: edge,
            directionAngle: degrees * .pi / 180,
            projectedPosition: position,
            isHighlighted: highlighted
        )
    }

    private func regularMember(
        _ suffix: Int,
        order: Int,
        center: CGPoint,
        highlighted: Bool = false
    ) -> MapLibreRegularPinMember {
        let labelSize = CGSize(width: 32, height: 32)
        return MapLibreRegularPinMember(
            id: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", suffix))!,
            displayOrder: order,
            numberCenter: center,
            renderedFrame: MapLibreEdgePinGeometry.renderedOuterFrame(
                numberCenter: center,
                labelSize: labelSize,
                topExtent: highlighted ? 50 : 16,
                bottomExtent: 16
            ),
            isHighlighted: highlighted
        )
    }

    private func projectedMember(
        _ suffix: Int,
        order: Int,
        degrees: CGFloat,
        screenCenter: CGPoint,
        distance: CGFloat = 1_000,
        highlighted: Bool = false
    ) -> MapLibreProjectedEdgePinMember {
        let angle = degrees * .pi / 180
        return MapLibreProjectedEdgePinMember(
            id: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", suffix))!,
            displayOrder: order,
            sourcePoint: CGPoint(
                x: screenCenter.x + cos(angle) * distance,
                y: screenCenter.y + sin(angle) * distance
            ),
            isHighlighted: highlighted
        )
    }

    func testEdgePinSafeRectUsesCompleteFrameMarginsAndMeasuredTimeline() {
        let rect = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
            timelineTop: 822
        )

        XCTAssertEqual(rect.minX, 20, accuracy: 0.001)
        XCTAssertEqual(rect.maxX, 410, accuracy: 0.001)
        XCTAssertEqual(rect.minY, 160, accuracy: 0.001)
        XCTAssertEqual(rect.maxY, 802, accuracy: 0.001)
    }

    func testCollapsedOverlayUsesTabBarTopAsBottomBoundary() {
        let screenBounds = CGRect(x: 0, y: 0, width: 430, height: 932)
        let rect = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: screenBounds,
            timelineTop: nil
        )

        XCTAssertEqual(
            screenBounds.maxY - rect.maxY,
            MapLibreEdgePinGeometry.bottomTabBarTopInset
                + MapLibreEdgePinGeometry.timelineGap,
            accuracy: 0.001
        )
        XCTAssertEqual(rect.maxY, 820, accuracy: 0.001)
    }

    func testSafeAreaPinTransitionStartsAtPreviousScreenPosition() {
        let oldCenter = CGPoint(x: 394, y: 600)
        let newCenter = CGPoint(x: 394, y: 786)
        let translation = MapLibrePinTransitionGeometry.translation(
            from: oldCenter,
            to: newCenter
        )

        XCTAssertEqual(newCenter.x + translation.tx, oldCenter.x, accuracy: 0.001)
        XCTAssertEqual(newCenter.y + translation.ty, oldCenter.y, accuracy: 0.001)
        XCTAssertEqual(MapLibrePinTransitionGeometry.duration, 0.28, accuracy: 0.001)
        XCTAssertTrue(MapLibrePinTransitionGeometry.shouldAnimateMovement(
            requested: false,
            wasEdgePinned: false,
            isEdgePinned: true
        ))
        XCTAssertTrue(MapLibrePinTransitionGeometry.shouldAnimateMovement(
            requested: false,
            wasEdgePinned: true,
            isEdgePinned: false
        ))
        XCTAssertFalse(MapLibrePinTransitionGeometry.shouldAnimateMovement(
            requested: false,
            wasEdgePinned: false,
            isEdgePinned: false
        ))
    }

    func testPinCategoryIconSourcesAreSharedAndDeterministic() {
        XCTAssertEqual(MapLibrePinCategoryIcon.sources(symbolName: "fork.knife"), [
            .asset("icon-camera-outline"),
            .asset("icon-camera"),
            .asset("icon-landscape-outline"),
            .system("fork.knife")
        ])
    }

    func testPointingCornerTransitionOnlySquaresTheDirectedCorner() {
        let rounded = MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: nil,
            radius: 16
        )
        XCTAssertEqual(
            rounded,
            MapLibrePinCornerRadii(
                topLeft: 16,
                topRight: 16,
                bottomLeft: 16,
                bottomRight: 16
            )
        )

        let topLeft = MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: .topLeft,
            radius: 16
        )
        XCTAssertEqual(
            topLeft,
            MapLibrePinCornerRadii(
                topLeft: 0,
                topRight: 16,
                bottomLeft: 16,
                bottomRight: 16
            )
        )

        let bottomRight = MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: .bottomRight,
            radius: 16
        )
        XCTAssertEqual(
            bottomRight,
            MapLibrePinCornerRadii(
                topLeft: 16,
                topRight: 16,
                bottomLeft: 16,
                bottomRight: 0
            )
        )
    }

    func testAutoFocusZoomContinuesUntilMaximumZoom() {
        XCTAssertEqual(
            MapLibreAutoFocusZoomPolicy.nextZoom(
                currentZoom: 13.8,
                maximumZoom: 20
            )!,
            14.8,
            accuracy: 0.001
        )
        XCTAssertEqual(
            MapLibreAutoFocusZoomPolicy.nextZoom(
                currentZoom: 19.7,
                maximumZoom: 20
            )!,
            20,
            accuracy: 0.001
        )
        XCTAssertNil(
            MapLibreAutoFocusZoomPolicy.nextZoom(
                currentZoom: 20,
                maximumZoom: 20
            )
        )
    }

    @MainActor
    func testCameraMutationDeferrerNeverRunsInsideSchedulingCallback() async {
        let deferrer = MapLibreCameraMutationDeferrer()
        let mutationRan = expectation(description: "deferred camera mutation ran")
        var events = ["delegate-entered"]

        XCTAssertTrue(deferrer.schedule {
            events.append("camera-mutated")
            mutationRan.fulfill()
        })
        XCTAssertTrue(deferrer.isPending)
        XCTAssertEqual(events, ["delegate-entered"])

        events.append("delegate-returned")
        await fulfillment(of: [mutationRan], timeout: 1)

        XCTAssertEqual(events, ["delegate-entered", "delegate-returned", "camera-mutated"])
        XCTAssertFalse(deferrer.isPending)
    }

    @MainActor
    func testCameraMutationDeferrerCoalescesAndCancelsPendingMutation() async {
        let deferrer = MapLibreCameraMutationDeferrer()
        var mutationCount = 0

        XCTAssertTrue(deferrer.schedule { mutationCount += 1 })
        XCTAssertFalse(deferrer.schedule { mutationCount += 1 })
        deferrer.cancel()
        await Task.yield()

        XCTAssertEqual(mutationCount, 0)
        XCTAssertFalse(deferrer.isPending)
    }

    func testEdgePinSafeRectRejectsInvalidHeightAndRespondsToResize() {
        let invalid = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
            timelineTop: 200
        )
        XCTAssertTrue(invalid.isNull)

        let portrait = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
            timelineTop: 822
        )
        let resized = MapLibreEdgePinGeometry.safeOuterRect(
            screenBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
            timelineTop: 734
        )
        XCTAssertEqual(portrait.width, 390, accuracy: 0.001)
        XCTAssertEqual(resized.width, 350, accuracy: 0.001)
        XCTAssertEqual(resized.maxY, 714, accuracy: 0.001)

        XCTAssertNotEqual(
            MapLibreEdgePinViewportGeometry(
                mapBounds: CGRect(x: 0, y: 0, width: 430, height: 932),
                windowBounds: CGRect(x: 0, y: 0, width: 430, height: 932)
            ),
            MapLibreEdgePinViewportGeometry(
                mapBounds: CGRect(x: 0, y: 0, width: 390, height: 844),
                windowBounds: CGRect(x: 0, y: 0, width: 390, height: 844)
            )
        )
    }

    func testEdgePinOuterFrameContainsLongLabelAndHighlightedPair() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        XCTAssertTrue(MapLibreEdgePinGeometry.containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.minX + 185, y: safeRect.minY + 16),
            labelSize: CGSize(width: 370, height: 32),
            topExtent: 16,
            bottomExtent: 16
        ))
        XCTAssertTrue(MapLibreEdgePinGeometry.containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.minX + 16, y: safeRect.minY + 50),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))
        XCTAssertFalse(MapLibreEdgePinGeometry.containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.minX + 16, y: safeRect.minY + 49),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))
    }

    func testEdgePinAttractionStartsOnlyAfterAnchorLeavesPhysicalScreen() {
        let screenBounds = CGRect(x: 0, y: 0, width: 430, height: 932)

        // These points have crossed the landing insets, but are still on the
        // physical screen and therefore must remain at their true positions.
        let insideLandingInsets = [
            CGPoint(x: 10, y: 466),
            CGPoint(x: 420, y: 466),
            CGPoint(x: 215, y: 150),
            CGPoint(x: 215, y: 850),
            CGPoint(x: 0, y: 466),
            CGPoint(x: 430, y: 466)
        ]
        for point in insideLandingInsets {
            XCTAssertFalse(MapLibreEdgePinTrigger.isOutsideScreen(
                point,
                screenBounds: screenBounds
            ))
        }

        let outsideScreen = [
            CGPoint(x: -0.1, y: 466),
            CGPoint(x: 430.1, y: 466),
            CGPoint(x: 215, y: -0.1),
            CGPoint(x: 215, y: 932.1)
        ]
        for point in outsideScreen {
            XCTAssertTrue(MapLibreEdgePinTrigger.isOutsideScreen(
                point,
                screenBounds: screenBounds
            ))
        }
    }

    func testOverflowProjectionIsNilWhileCompleteFrameFits() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let labelSize = CGSize(width: 32, height: 32)
        let fittingCenters = [
            CGPoint(x: 36, y: 496),
            CGPoint(x: 394, y: 496),
            CGPoint(x: 215, y: 206),
            CGPoint(x: 215, y: 786),
            CGPoint(x: safeRect.midX, y: safeRect.midY)
        ]

        for center in fittingCenters {
            XCTAssertNil(MapLibreEdgePinGeometry.overflowProjection(
                safeRect: safeRect,
                numberCenter: center,
                labelSize: labelSize,
                topExtent: 16,
                bottomExtent: 16
            ))
        }
    }

    func testOverflowProjectionUsesSelectedAndLongLabelOuterExtents() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let selected = try XCTUnwrap(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.midX, y: 239),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))
        XCTAssertEqual(selected.edge, .top)
        XCTAssertEqual(selected.point.y, 240, accuracy: 0.001)
        XCTAssertNil(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: safeRect.midX, y: 240),
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 50,
            bottomExtent: 16
        ))

        let longLabelSize = CGSize(width: 200, height: 32)
        let longLabel = try XCTUnwrap(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 119, y: safeRect.midY),
            labelSize: longLabelSize,
            topExtent: 16,
            bottomExtent: 16
        ))
        XCTAssertEqual(longLabel.edge, .left)
        XCTAssertEqual(longLabel.point.x, 120, accuracy: 0.001)
        XCTAssertNil(MapLibreEdgePinGeometry.overflowProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 120, y: safeRect.midY),
            labelSize: longLabelSize,
            topExtent: 16,
            bottomExtent: 16
        ))
    }

    func testEdgePinAttractionCornerChoiceIsStableAlongCenterRay() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        for center in [CGPoint(x: 35, y: 205), CGPoint(x: 35.1, y: 205.1)] {
            let projection = try XCTUnwrap(MapLibreEdgePinGeometry.overflowProjection(
                safeRect: safeRect,
                numberCenter: center,
                labelSize: CGSize(width: 32, height: 32),
                topExtent: 16,
                bottomExtent: 16
            ))
            XCTAssertEqual(projection.edge, .left)
        }
    }

    func testRegularPinsMergeOnRenderedOverlapButNotExactTouch() {
        let first = regularMember(1, order: 0, center: CGPoint(x: 100, y: 300))
        let touching = regularMember(2, order: 1, center: CGPoint(x: 132, y: 300))
        let overlapping = regularMember(3, order: 1, center: CGPoint(x: 131, y: 300))

        XCTAssertEqual(
            MapLibreRegularPinGrouping.clusters(members: [first, touching]).count,
            2
        )
        let merged = MapLibreRegularPinGrouping.clusters(members: [first, overlapping])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].members.map(\.id), [first.id, overlapping.id])
        XCTAssertEqual(merged[0].labelText, "1.2")
    }

    func testRegularPinOverlapClosureIsTransitiveOrderedAndDeduplicated() {
        let first = regularMember(1, order: 0, center: CGPoint(x: 100, y: 300))
        let second = regularMember(2, order: 1, center: CGPoint(x: 131, y: 300))
        let third = regularMember(3, order: 2, center: CGPoint(x: 162, y: 300))

        let clusters = MapLibreRegularPinGrouping.clusters(
            members: [third, first, second, first]
        )

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].members.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(clusters[0].representativeID, first.id)
        XCTAssertEqual(clusters[0].labelText, "1.2.3")
    }

    func testWidenedRegularPillCreatesSecondaryCollisionClosure() {
        let first = regularMember(1, order: 9_999, center: CGPoint(x: 100, y: 300))
        let second = regularMember(2, order: 10_000, center: CGPoint(x: 131, y: 300))
        // This pin does not overlap either original 32-point circle, but it is
        // absorbed after the long merged number label widens the first group.
        let third = regularMember(3, order: 10_001, center: CGPoint(x: 164, y: 300))

        let clusters = MapLibreRegularPinGrouping.clusters(
            members: [first, second, third]
        )

        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].members.map(\.id), [first.id, second.id, third.id])
    }

    func testHighlightedRegularPinMergesOnlyOnActualRenderedCollision() {
        let selected = regularMember(
            1,
            order: 0,
            center: CGPoint(x: 100, y: 300),
            highlighted: true
        )
        let overlapping = regularMember(2, order: 1, center: CGPoint(x: 131, y: 300))
        let separate = regularMember(3, order: 2, center: CGPoint(x: 220, y: 300))

        let collision = MapLibreRegularPinGrouping.clusters(members: [selected, overlapping])
        XCTAssertEqual(collision.count, 1)
        XCTAssertTrue(collision[0].isHighlighted)
        XCTAssertEqual(Set(collision[0].members.map(\.id)), Set([selected.id, overlapping.id]))
        XCTAssertEqual(collision[0].renderedFrame.height, 32, accuracy: 0.001)

        XCTAssertEqual(
            MapLibreRegularPinGrouping.clusters(members: [selected, separate]).count,
            2
        )
    }

    func testHighlightedRegularSingletonKeepsTrueNumericLabelSize() throws {
        let highlighted = regularMember(
            1,
            order: 0,
            center: CGPoint(x: 100, y: 300),
            highlighted: true
        )
        let cluster = try XCTUnwrap(
            MapLibreRegularPinGrouping.clusters(members: [highlighted]).first
        )

        XCTAssertEqual(cluster.labelSize, CGSize(width: 32, height: 32))
        XCTAssertEqual(cluster.renderedFrame.height, 66, accuracy: 0.001)
    }

    func testBoundaryProjectionUsesPhysicalScreenCenterWhenSafeRectCenterDiffers() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 185, y: 460)
        XCTAssertNotEqual(screenCenter, CGPoint(x: safeRect.midX, y: safeRect.midY))
        let source = CGPoint(x: -200, y: 40)

        let projection = try XCTUnwrap(MapLibreEdgePinGeometry.boundaryProjection(
            safeRect: safeRect,
            numberCenter: source,
            labelSize: CGSize(width: 32, height: 32),
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))

        let sourceVector = CGPoint(x: source.x - screenCenter.x, y: source.y - screenCenter.y)
        let landingVector = CGPoint(
            x: projection.point.x - screenCenter.x,
            y: projection.point.y - screenCenter.y
        )
        XCTAssertEqual(
            sourceVector.x * landingVector.y - sourceVector.y * landingVector.x,
            0,
            accuracy: 0.001
        )
    }

    func testBoundaryProjectionUsesFarEdgeWhenScreenCenterIsBelowSafeRect() throws {
        let safeRect = CGRect(x: 20, y: 160, width: 390, height: 100)
        let screenCenter = CGPoint(x: 215, y: 466)
        let labelSize = CGSize(width: 32, height: 32)

        let upward = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: -1_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        XCTAssertEqual(upward.edge, .top)
        XCTAssertEqual(upward.point, CGPoint(x: 394, y: 176))

        let downward = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: 2_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        XCTAssertEqual(downward.edge, .bottom)
        XCTAssertEqual(downward.point, CGPoint(x: 394, y: 244))
    }

    func testHorizontalEdgeLandingUsesOnlyEndpointSlotsAndSwitchesAtScreenCenter() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let labelSize = CGSize(width: 32, height: 32)
        let topLeft = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 214, y: -1_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        let topRight = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: -1_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        let bottomLeft = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 214, y: 2_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))
        let bottomRight = try XCTUnwrap(MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: CGPoint(x: 216, y: 2_000),
            labelSize: labelSize,
            topExtent: 16,
            bottomExtent: 16,
            rayOrigin: screenCenter
        ))

        XCTAssertEqual(topLeft, .init(point: CGPoint(x: 36, y: 206), edge: .top))
        XCTAssertEqual(topRight, .init(point: CGPoint(x: 394, y: 206), edge: .top))
        XCTAssertEqual(bottomLeft, .init(point: CGPoint(x: 36, y: 786), edge: .bottom))
        XCTAssertEqual(bottomRight, .init(point: CGPoint(x: 394, y: 786), edge: .bottom))
        XCTAssertEqual(
            MapLibreEdgePinGeometry.pointingCorner(for: topLeft, safeRect: safeRect),
            .topLeft
        )
        XCTAssertEqual(
            MapLibreEdgePinGeometry.pointingCorner(for: bottomRight, safeRect: safeRect),
            .bottomRight
        )
    }

    func testTopPinJumpsBetweenSlotsAndMergesAtDestination() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let movingLeft = projectedMember(1, order: 0, degrees: -100, screenCenter: screenCenter)
        let existingRight = projectedMember(2, order: 1, degrees: -80, screenCenter: screenCenter)
        let before = MapLibreProjectedEdgePinGrouping.clusters(
            members: [movingLeft, existingRight],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        XCTAssertEqual(before.count, 2)
        XCTAssertEqual(Set(before.compactMap(\.pointingCorner)), Set([.topLeft, .topRight]))

        let movingRight = projectedMember(1, order: 0, degrees: -79, screenCenter: screenCenter)
        let after = MapLibreProjectedEdgePinGrouping.clusters(
            members: [movingRight, existingRight],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: before.map { $0.members.map(\.id) }
        )

        let merged = try XCTUnwrap(after.first)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(Set(merged.members.map(\.id)), Set([movingRight.id, existingRight.id]))
        XCTAssertEqual(merged.pointingCorner, .topRight)
        XCTAssertEqual(merged.renderedFrame.maxX, safeRect.maxX, accuracy: 0.001)
    }

    func testProjectedEdgePositionDoesNotMoveWhenNonCollidingNeighborAppears() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let primary = projectedMember(1, order: 0, degrees: -90, screenCenter: screenCenter)
        let neighbor = projectedMember(2, order: 1, degrees: 0, screenCenter: screenCenter)

        let alone = try XCTUnwrap(MapLibreProjectedEdgePinGrouping.clusters(
            members: [primary],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).first)
        let withNeighbor = try XCTUnwrap(MapLibreProjectedEdgePinGrouping.clusters(
            members: [primary, neighbor],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).first(where: { $0.members.contains(where: { $0.id == primary.id }) }))

        XCTAssertEqual(alone.numberCenter.x, withNeighbor.numberCenter.x, accuracy: 0.001)
        XCTAssertEqual(alone.numberCenter.y, withNeighbor.numberCenter.y, accuracy: 0.001)
    }

    func testAnglePastSplitThresholdStillMergesWhenProjectedRectsOverlap() {
        let safeRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screenCenter = CGPoint(x: 100, y: 20)
        let first = projectedMember(1, order: 0, degrees: -135, screenCenter: screenCenter)
        let second = projectedMember(2, order: 1, degrees: -100, screenCenter: screenCenter)

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: [first, second],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: [[first.id, second.id]]
        )

        XCTAssertGreaterThan(
            MapLibreEdgePinGrouping.circularAngularDistance(-135 * .pi / 180, -100 * .pi / 180),
            MapLibreEdgePinGrouping.splitAngle
        )
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0].members.map(\.id)), Set([first.id, second.id]))
    }

    func testEdgeSplitOutputRectsDoNotOverlap() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 496)
        let first = projectedMember(1, order: 0, degrees: -110, screenCenter: screenCenter)
        let second = projectedMember(2, order: 1, degrees: -70, screenCenter: screenCenter)

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: [first, second],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: [[first.id, second.id]]
        )

        XCTAssertEqual(clusters.count, 2)
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(clusters.map(\.renderedFrame)))
    }

    func testMergedEdgeAnchorUsesCircularMeanRayAndOwnLabelBoundary() throws {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 230)
        let members = [
            projectedMember(1, order: 0, degrees: -120, screenCenter: screenCenter),
            projectedMember(2, order: 1, degrees: -110, screenCenter: screenCenter),
            projectedMember(3, order: 2, degrees: -100, screenCenter: screenCenter)
        ]

        let cluster = try XCTUnwrap(MapLibreProjectedEdgePinGrouping.clusters(
            members: members,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).first)

        XCTAssertEqual(cluster.members.count, 3)
        XCTAssertEqual(cluster.pointingCorner, .topLeft)
        XCTAssertEqual(cluster.renderedFrame.minX, safeRect.minX, accuracy: 0.001)
        XCTAssertEqual(cluster.renderedFrame.minY, safeRect.minY, accuracy: 0.001)
    }

    func testProjectedEdgeCollisionClosurePreservesEveryMemberAndNoFramesOverlap() {
        let safeRect = CGRect(x: 0, y: 0, width: 200, height: 100)
        let screenCenter = CGPoint(x: 100, y: 20)
        let members = [-140, -110, -90, -70, -40].enumerated().map {
            projectedMember($0.offset + 1, order: $0.offset, degrees: CGFloat($0.element), screenCenter: screenCenter)
        }

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: members,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        XCTAssertEqual(Set(clusters.flatMap { $0.members.map(\.id) }), Set(members.map(\.id)))
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(clusters.map(\.renderedFrame)))
    }

    func testOversizedEndpointGroupCompactsLabelWithoutLosingMembers() throws {
        let safeRect = CGRect(x: 20, y: 160, width: 100, height: 300)
        let screenCenter = CGPoint(x: 70, y: 300)
        let members = (0..<30).map { offset in
            projectedMember(
                offset + 1,
                order: 100_000 + offset,
                degrees: -110,
                screenCenter: screenCenter
            )
        }

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: members,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(cluster.members.map(\.id)), Set(members.map(\.id)))
        XCTAssertLessThanOrEqual(cluster.labelSize.width, safeRect.width)
        XCTAssertEqual(cluster.renderedFrame.minX, safeRect.minX, accuracy: 0.001)
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(clusters.map(\.renderedFrame)))
    }

    func testHighlightedEdgePinCollisionMergesButNoncollisionStaysIndependent() {
        let compactRect = CGRect(x: 0, y: 0, width: 200, height: 200)
        // Keep the physical center inside the highlighted pin's taller
        // center-safe rect while remaining close enough to the top boundary
        // that these angularly separate rays still render on top of each other.
        let compactCenter = CGPoint(x: 100, y: 55)
        let selected = projectedMember(
            1,
            order: 0,
            degrees: -135,
            screenCenter: compactCenter,
            highlighted: true
        )
        let overlapping = projectedMember(2, order: 1, degrees: -100, screenCenter: compactCenter)
        let collision = MapLibreProjectedEdgePinGrouping.clusters(
            members: [selected, overlapping],
            safeRect: compactRect,
            screenCenter: compactCenter,
            previousGroups: []
        )
        XCTAssertEqual(collision.count, 1)
        XCTAssertEqual(Set(collision[0].members.map(\.id)), Set([selected.id, overlapping.id]))
        XCTAssertTrue(collision[0].containsHighlighted)
        XCTAssertFalse(collision[0].rendersHighlighted)
        XCTAssertEqual(collision[0].renderedFrame.height, 32, accuracy: 0.001)

        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let separatedSelected = projectedMember(
            3,
            order: 0,
            degrees: -90,
            screenCenter: screenCenter,
            highlighted: true
        )
        let separatedRegular = projectedMember(4, order: 1, degrees: 0, screenCenter: screenCenter)
        XCTAssertEqual(MapLibreProjectedEdgePinGrouping.clusters(
            members: [separatedSelected, separatedRegular],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        ).count, 2)
    }

    func testHighlightedEdgePinDegradesToCompactWithoutLosingMemberWhenHeightIsTight() throws {
        let safeRect = CGRect(x: 20, y: 160, width: 390, height: 50)
        let screenCenter = CGPoint(x: 215, y: 466)
        let highlighted = projectedMember(
            1,
            order: 0,
            degrees: -90,
            screenCenter: screenCenter,
            highlighted: true
        )

        let clusters = MapLibreProjectedEdgePinGrouping.clusters(
            members: [highlighted],
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousGroups: []
        )

        let cluster = try XCTUnwrap(clusters.first)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(cluster.members.map(\.id), [highlighted.id])
        XCTAssertTrue(cluster.containsHighlighted)
        XCTAssertFalse(cluster.rendersHighlighted)
        XCTAssertEqual(cluster.renderedFrame.height, 32, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(cluster.renderedFrame.minY, safeRect.minY - 0.001)
        XCTAssertLessThanOrEqual(cluster.renderedFrame.maxY, safeRect.maxY + 0.001)
    }

    func testRegularEdgeSeamPromotesToFixedPointWithoutFinalOverlap() {
        let safeRect = CGRect(x: 20, y: 190, width: 390, height: 612)
        let screenCenter = CGPoint(x: 215, y: 466)
        let seamRegular = regularMember(1, order: 0, center: CGPoint(x: 379, y: 221))
        let farRegular = regularMember(3, order: 2, center: CGPoint(x: 320, y: 500))
        let initialEdge = projectedMember(2, order: 1, degrees: -90, screenCenter: screenCenter)
        let allMembers = [
            MapLibreProjectedEdgePinMember(
                id: seamRegular.id,
                displayOrder: seamRegular.displayOrder,
                sourcePoint: seamRegular.numberCenter,
                isHighlighted: false
            ),
            initialEdge,
            MapLibreProjectedEdgePinMember(
                id: farRegular.id,
                displayOrder: farRegular.displayOrder,
                sourcePoint: farRegular.numberCenter,
                isHighlighted: false
            )
        ]

        let resolved = MapLibreFinalPinGrouping.resolve(
            regularClusters: MapLibreRegularPinGrouping.clusters(
                members: [seamRegular, farRegular]
            ),
            initialEdgeMemberIDs: [initialEdge.id],
            allEdgeMembers: allMembers,
            safeRect: safeRect,
            screenCenter: screenCenter,
            previousEdgeGroups: []
        )

        XCTAssertEqual(resolved.regular.map(\.representativeID), [farRegular.id])
        XCTAssertEqual(resolved.edge.count, 1)
        XCTAssertEqual(
            Set(resolved.edge[0].members.map(\.id)),
            Set([seamRegular.id, initialEdge.id])
        )
        let finalFrames = resolved.regular.map(\.renderedFrame) + resolved.edge.map(\.renderedFrame)
        XCTAssertFalse(MapLibreFinalPinGrouping.hasPairwiseOverlap(finalFrames))
        XCTAssertEqual(
            Set(resolved.regular.flatMap { $0.members.map(\.id) }
                + resolved.edge.flatMap { $0.members.map(\.id) }),
            Set([seamRegular.id, initialEdge.id, farRegular.id])
        )
    }

    func testEdgePinGroupingUsesWrapSafeAngularDistance() {
        let members = [
            edgeMember(1, order: 0, degrees: 179, position: 20),
            edgeMember(2, order: 1, degrees: -179, position: 30)
        ]

        let groups = MapLibreEdgePinGrouping.groups(members: members, previousGroups: [])

        XCTAssertEqual(groups.map(\.mapID), [[members[0].id, members[1].id]])
        XCTAssertEqual(
            MapLibreEdgePinGrouping.circularAngularDistance(
                members[0].directionAngle,
                members[1].directionAngle
            ),
            2 * .pi / 180,
            accuracy: 0.0001
        )
    }

    func testEdgePinGroupingUsesCompleteLinkInsteadOfNeighborChain() {
        let members = [
            edgeMember(1, order: 0, degrees: 0, position: 0),
            edgeMember(2, order: 1, degrees: 20, position: 20),
            edgeMember(3, order: 2, degrees: 40, position: 40)
        ]

        let groups = MapLibreEdgePinGrouping.groups(members: members, previousGroups: [])

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(Set(groups.flatMap(\.mapID)), Set(members.map(\.id)))
    }

    func testEdgePinGroupingAppliesMergeAndSplitHysteresis() {
        let members = [
            edgeMember(1, order: 0, degrees: 0, position: 0),
            edgeMember(2, order: 1, degrees: 27, position: 50)
        ]

        XCTAssertEqual(
            MapLibreEdgePinGrouping.groups(members: members, previousGroups: []).count,
            2
        )
        XCTAssertEqual(
            MapLibreEdgePinGrouping.groups(
                members: members,
                previousGroups: [members.map(\.id)]
            ).count,
            1
        )
    }

    func testEdgePinGroupingDetachesFortyFiveDegreeOutlierWithoutLosingOrder() {
        let members = [
            edgeMember(2, order: 0, degrees: -136, position: 10),
            edgeMember(3, order: 1, degrees: -135, position: 16),
            edgeMember(6, order: 2, degrees: -134, position: 22),
            edgeMember(4, order: 3, degrees: -90, position: 25),
            edgeMember(1, order: 4, degrees: -133, position: 30)
        ]
        let previous = [members.map(\.id)]

        let groups = MapLibreEdgePinGrouping.groups(
            members: members,
            previousGroups: previous
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains { $0.mapID == [members[0].id, members[1].id, members[2].id, members[4].id] })
        XCTAssertTrue(groups.contains { $0.mapID == [members[3].id] })
        XCTAssertEqual(Set(groups.flatMap(\.mapID)), Set(members.map(\.id)))
    }

    func testHighlightedEdgePinAndDifferentEdgesStaySeparate() {
        let members = [
            edgeMember(1, order: 0, degrees: 1, position: 10),
            edgeMember(2, order: 1, degrees: 2, position: 12, highlighted: true),
            edgeMember(3, order: 2, degrees: 3, position: 14, edge: .left)
        ]

        let groups = MapLibreEdgePinGrouping.groups(
            members: members,
            previousGroups: [members.map(\.id)]
        )

        XCTAssertEqual(groups.count, 3)
    }

    func testMainlandAppleCoordinateIsNormalizedForMapLibre() {
        let appleCoordinate = CLLocationCoordinate2D(
            latitude: 27.8250397,
            longitude: 99.7036914
        )

        let displayCoordinate = MapLibreCoordinateTransform.displayCoordinate(for: appleCoordinate)

        XCTAssertEqual(displayCoordinate.latitude, 27.8285362177, accuracy: 0.0000001)
        XCTAssertEqual(displayCoordinate.longitude, 99.7025975337, accuracy: 0.0000001)
    }

    func testCoordinatesOutsideMainlandChinaAreNotChangedForMapLibre() {
        let overseasCoordinates = [
            CLLocationCoordinate2D(latitude: -7.25747, longitude: 112.75209),
            CLLocationCoordinate2D(latitude: 13.7563, longitude: 100.5018),
            CLLocationCoordinate2D(latitude: 34.6937, longitude: 135.5023),
            CLLocationCoordinate2D(latitude: 37.5665, longitude: 126.9780)
        ]

        for coordinate in overseasCoordinates {
            let displayCoordinate = MapLibreCoordinateTransform.displayCoordinate(for: coordinate)

            XCTAssertEqual(displayCoordinate.latitude, coordinate.latitude, accuracy: 0.0000001)
            XCTAssertEqual(displayCoordinate.longitude, coordinate.longitude, accuracy: 0.0000001)
        }
    }

    func testRouteCacheEntryExpiresAfterFifteenMinutes() {
        let estimate = RouteEstimate(distanceMeters: 1200, durationSeconds: 600, mode: .walking, updatedAt: .now, source: "Apple 地图")
        let cachedAt = Date(timeIntervalSince1970: 1_000)
        let entry = CachedRouteEstimate(estimate: estimate, cachedAt: cachedAt)

        XCTAssertTrue(entry.isFresh(now: cachedAt.addingTimeInterval(RouteCache.maxAge - 1)))
        XCTAssertFalse(entry.isFresh(now: cachedAt.addingTimeInterval(RouteCache.maxAge)))
    }

    func testRouteModeUsesAppleMapsDirectionValues() {
        XCTAssertEqual(RouteMode.driving.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeDriving")
        XCTAssertEqual(RouteMode.walking.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeWalking")
        XCTAssertEqual(RouteMode.transit.launchOptionsDirectionMode, "MKLaunchOptionsDirectionsModeTransit")
    }

    @MainActor
    func testExpiredCacheCanBeReadOnlyAsNetworkFallback() throws {
        let container = try ModelContainer(for: Schema([RouteCacheRecord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let cache = RouteCache(modelContext: container.mainContext)
        let origin = RoutePoint(latitude: 39.9, longitude: 116.3)
        let destination = RoutePoint(latitude: 39.8, longitude: 116.4)
        let estimate = RouteEstimate(distanceMeters: 1200, durationSeconds: 600, mode: .walking, updatedAt: .now, source: "Apple 地图")
        let staleAt = Date.now.addingTimeInterval(-RouteCache.maxAge)

        try cache.store(estimate, origin: origin, destination: destination, mode: .walking, cachedAt: staleAt)

        XCTAssertNil(cache.cached(origin: origin, destination: destination, mode: .walking))
        let fallback = try XCTUnwrap(cache.cached(origin: origin, destination: destination, mode: .walking, includeExpired: true)?.estimate)
        XCTAssertEqual(fallback.distanceMeters, estimate.distanceMeters)
        XCTAssertEqual(fallback.durationSeconds, estimate.durationSeconds)
        XCTAssertEqual(fallback.mode, estimate.mode)
        XCTAssertEqual(fallback.source, estimate.source)
    }

    @MainActor
    func testRouteCacheIsRemovedOnlyByExplicitInvalidation() throws {
        let container = try ModelContainer(for: Schema([RouteCacheRecord.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let cache = RouteCache(modelContext: container.mainContext)
        let origin = RoutePoint(latitude: -8.7482, longitude: 115.1672)
        let destination = RoutePoint(latitude: -8.708446, longitude: 115.439565)
        let estimate = RouteEstimate(distanceMeters: 31_200, durationSeconds: 3_900, mode: .driving, updatedAt: .now, source: "Apple 地图")
        let oldCacheDate = Date.now.addingTimeInterval(-30 * 24 * 60 * 60)

        try cache.store(estimate, origin: origin, destination: destination, mode: .driving, cachedAt: oldCacheDate)
        XCTAssertNotNil(cache.cached(origin: origin, destination: destination, mode: .driving, includeExpired: true))

        try cache.removeAll()

        XCTAssertNil(cache.cached(origin: origin, destination: destination, mode: .driving, includeExpired: true))
        XCTAssertTrue(try container.mainContext.fetch(FetchDescriptor<RouteCacheRecord>()).isEmpty)
    }

    @MainActor
    func testCardLegPreferenceDefaultsToDrivingAndPersistsAcrossLegs() throws {
        let container = try ModelContainer(for: Schema([CardLegPreference.self]), configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let store = CardLegStore(modelContext: container.mainContext)
        let origin = TravelCardSnapshot(dayID: 1, kind: .activity, title: "故宫", startAt: .now)
        let destination = TravelCardSnapshot(dayID: 1, kind: .activity, title: "天坛", startAt: .now)
        let key = CardLegStore.legKey(origin: origin, destination: destination)

        XCTAssertEqual(store.mode(for: key), .driving)

        store.setMode(.transit, for: key)
        XCTAssertEqual(store.mode(for: key), .transit)

        store.setMode(.walking, for: key)
        XCTAssertEqual(store.mode(for: key), .walking)

        let routeKey = "39.90000,116.30000->39.80000,116.40000@walking"
        XCTAssertFalse(store.hasEstimateFailure(routeKey: routeKey, for: key))
        store.markEstimateFailure(routeKey: routeKey, for: key)
        XCTAssertTrue(
            CardLegStore(modelContext: container.mainContext)
                .hasEstimateFailure(routeKey: routeKey, for: key)
        )

        store.clearAllEstimateFailures()
        XCTAssertFalse(store.hasEstimateFailure(routeKey: routeKey, for: key))
        XCTAssertEqual(try container.mainContext.fetch(FetchDescriptor<CardLegPreference>()).count, 1)
    }
}

private extension Array where Element == MapLibreEdgePinGroupMember {
    var mapID: [UUID] { map(\.id) }
}
