import MapKit
@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// Experimental vector-map renderer for the Today screen. Apple services still
/// provide POI resolution and route geometry; MapLibre only draws the basemap.
struct MapLibreTodayMapCanvas: UIViewRepresentable {
    let points: [TodayMapPoint]
    /// `nil` renders all POIs as compact number pins, for example while the
    /// action drawer is open and the POI swiper is hidden.
    let selectedIndex: Int?
    let cameraFocus: CLLocationCoordinate2D?
    let cameraRequestID: Int
    /// The card occupies the lower map area only while the POI swiper is visible.
    let overviewBottomInset: CGFloat
    let routeRefreshID: Int
    let onRouteLoadingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Bundle.main.url(forResource: "TodayMapStyle", withExtension: "json")
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.backgroundColor = UIColor(red: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1)
        mapView.minimumZoomLevel = 1
        mapView.maximumZoomLevel = 20
        mapView.allowsTilting = false
        mapView.allowsRotating = false
        mapView.showsUserLocation = false
        mapView.showsLogoView = false
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 12, y: 136)

        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex,
            routeRefreshID: routeRefreshID,
            onRouteLoadingChanged: onRouteLoadingChanged
        )
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex,
            routeRefreshID: routeRefreshID,
            onRouteLoadingChanged: onRouteLoadingChanged
        )
        context.coordinator.updateCamera(
            on: mapView,
            points: points,
            focus: cameraFocus,
            requestID: cameraRequestID,
            bottomInset: overviewBottomInset
        )
    }

    @MainActor
    final class Coordinator: NSObject, @MainActor MLNMapViewDelegate {
        private var pointAnnotations: [MapLibreNumberedAnnotation] = []
        private var routeAnnotations: [MLNPolyline] = []
        private var displayedRouteCoordinates: [CLLocationCoordinate2D] = []
        private var routeTask: Task<Void, Never>?
        private var activeDirections: MKDirections?
        private var routeGeneration = 0
        private var renderedPoints: [TodayMapPoint] = []
        private var renderedSelection: Int?
        private var handledCameraRequestID = -1
        private var handledRouteRefreshID = -1
        private var isFollowingUserLocation = false
        private var isRouting = false
        private var isShowingRouteOverview = false
        private var overviewBottomInset: CGFloat = 240
        private var pinPlacements: [UUID: MapLibrePinPlacement] = [:]
        /// Keep enough surrounding roads and nearby POIs in view while a
        /// bottom swiper card is selected; 16 was too close for this screen.
        private let poiSwiperFocusZoomLevel: Double = 13.8

        fileprivate func updateContent(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            selectedIndex: Int?,
            routeRefreshID: Int,
            onRouteLoadingChanged: @escaping (Bool) -> Void
        ) {
            let refreshRequested = routeRefreshID != handledRouteRefreshID
            guard points != renderedPoints || selectedIndex != renderedSelection || refreshRequested else { return }
            let pointsChanged = points != renderedPoints
            let forceRouteRefresh = refreshRequested && routeRefreshID > 0

            if !pointAnnotations.isEmpty {
                mapView.removeAnnotations(pointAnnotations)
            }
            pointAnnotations = points.enumerated().map { index, point in
                MapLibreNumberedAnnotation(
                    point: point,
                    index: index,
                    isHighlighted: selectedIndex == index
                )
            }
            mapView.addAnnotations(pointAnnotations)

            if pointsChanged || refreshRequested {
                rebuildNavigationRoute(
                    on: mapView,
                    points: points,
                    forceRefresh: forceRouteRefresh,
                    onRouteLoadingChanged: onRouteLoadingChanged
                )
                handledRouteRefreshID = routeRefreshID
            }

            renderedPoints = points
            renderedSelection = selectedIndex
            updatePinPlacements(on: mapView)
        }

        private func rebuildNavigationRoute(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            forceRefresh: Bool,
            onRouteLoadingChanged: @escaping (Bool) -> Void
        ) {
            routeTask?.cancel()
            activeDirections?.cancel()
            routeGeneration &+= 1
            let generation = routeGeneration

            if !routeAnnotations.isEmpty {
                mapView.removeAnnotations(routeAnnotations)
                routeAnnotations.removeAll()
            }
            displayedRouteCoordinates.removeAll()
            guard points.count > 1 else {
                setRouteLoading(false, notify: onRouteLoadingChanged)
                return
            }

            let routeCache = TodayRouteGeometryCache.shared
            var missingLegs: [(origin: TodayMapPoint, destination: TodayMapPoint)] = []
            for (origin, destination) in zip(points, points.dropFirst()) {
                if !forceRefresh, let route = routeCache.route(from: origin, to: destination) {
                    routeAnnotations.append(
                        contentsOf: routeAnnotations(for: route, origin: origin, destination: destination)
                    )
                    displayedRouteCoordinates.append(contentsOf: route.coordinates)
                } else {
                    missingLegs.append((origin, destination))
                }
            }
            if !routeAnnotations.isEmpty {
                mapView.addAnnotations(routeAnnotations)
            }
            guard !missingLegs.isEmpty else {
                setRouteLoading(false, notify: onRouteLoadingChanged)
                return
            }

            setRouteLoading(true, notify: onRouteLoadingChanged)

            routeTask = Task { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                defer {
                    if generation == self.routeGeneration {
                        self.routeTask = nil
                        self.setRouteLoading(false, notify: onRouteLoadingChanged)
                        self.fitRouteOverviewIfNeeded(on: mapView, points: points, animated: true)
                    }
                }

                for (origin, destination) in missingLegs {
                    guard !Task.isCancelled, generation == routeGeneration else { return }
                    var route: TodayRouteGeometry?
                    if let coordinates = await navigationCoordinates(
                        from: origin,
                        to: destination,
                        transportType: .automobile
                    ) {
                        route = TodayRouteGeometry(coordinates: coordinates, isWalking: false)
                    } else if let coordinates = await navigationCoordinates(
                            from: origin,
                            to: destination,
                            transportType: .walking
                        ) {
                        // Apple returns no driving leg for this pair. Ask it
                        // again for a standalone pedestrian route and show
                        // that segment as an intentional dashed connection.
                        route = TodayRouteGeometry(coordinates: coordinates, isWalking: true)
                    } else if let coordinates = await serverNavigationCoordinates(from: origin, to: destination) {
                        route = TodayRouteGeometry(coordinates: coordinates, isWalking: false)
                    } else {
                        // Keep the itinerary visually continuous even when
                        // neither routing service recognizes the two points.
                        route = TodayRouteGeometry(
                            coordinates: [origin.coordinate, destination.coordinate],
                            isWalking: true
                        )
                    }
                    if let route, route.coordinates.count > 1 {
                        routeCache.store(
                            route.coordinates,
                            from: origin,
                            to: destination,
                            isWalking: route.isWalking
                        )
                        let annotations = routeAnnotations(
                            for: route,
                            origin: origin,
                            destination: destination
                        )
                        routeAnnotations.append(contentsOf: annotations)
                        displayedRouteCoordinates.append(contentsOf: route.coordinates)
                        annotations.forEach(mapView.addAnnotation)
                    }
                }
                updatePinPlacements(on: mapView)
            }
        }

        private func setRouteLoading(_ isLoading: Bool, notify: (Bool) -> Void) {
            guard isRouting != isLoading else { return }
            isRouting = isLoading
            notify(isLoading)
        }

        private func routeAnnotation(for routeCoordinates: [CLLocationCoordinate2D]) -> MLNPolyline {
            var coordinates = routeCoordinates
            return MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
        }

        private func routeAnnotations(
            for route: TodayRouteGeometry,
            origin: TodayMapPoint,
            destination: TodayMapPoint
        ) -> [MLNPolyline] {
            var annotations: [MLNPolyline]
            if route.isWalking {
                annotations = dashedRouteAnnotations(for: route.coordinates)
            } else {
                annotations = [routeAnnotation(for: route.coordinates)]
            }

            // MapKit may snap a coordinate to the nearest routable road. Make
            // that final off-road distance explicit instead of leaving the
            // orange route visually detached from the POI pin.
            if let first = route.coordinates.first {
                annotations.append(contentsOf: dashedConnector(from: origin.coordinate, to: first))
            }
            if let last = route.coordinates.last {
                annotations.append(contentsOf: dashedConnector(from: last, to: destination.coordinate))
            }
            return annotations
        }

        private func dashedConnector(
            from start: CLLocationCoordinate2D,
            to end: CLLocationCoordinate2D
        ) -> [MLNPolyline] {
            let distance = CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
            guard distance > 4 else { return [] }
            return dashedRouteAnnotations(for: [start, end])
        }

        /// MapLibre's annotation delegate exposes one shared stroke style, so
        /// a walking leg is drawn as short polyline pieces with real gaps.
        /// The dynamic length caps the number of annotations for long trips.
        private func dashedRouteAnnotations(
            for coordinates: [CLLocationCoordinate2D]
        ) -> [MLNPolyline] {
            guard coordinates.count > 1 else { return [] }

            let totalDistance = zip(coordinates, coordinates.dropFirst()).reduce(0.0) { partial, pair in
                partial + CLLocation(latitude: pair.0.latitude, longitude: pair.0.longitude)
                    .distance(from: CLLocation(latitude: pair.1.latitude, longitude: pair.1.longitude))
            }
            let dashLength = max(70, totalDistance / 120)
            let gapLength = max(40, dashLength * 0.6)
            var isDrawingDash = true
            var remainingPhaseLength = dashLength
            var dashCoordinates: [CLLocationCoordinate2D] = []
            var annotations: [MLNPolyline] = []

            for (start, end) in zip(coordinates, coordinates.dropFirst()) {
                let segmentLength = CLLocation(latitude: start.latitude, longitude: start.longitude)
                    .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
                guard segmentLength > 0 else { continue }
                var coveredLength = 0.0

                while coveredLength < segmentLength {
                    let pieceLength = min(remainingPhaseLength, segmentLength - coveredLength)
                    let pieceStart = interpolatedCoordinate(
                        from: start,
                        to: end,
                        progress: coveredLength / segmentLength
                    )
                    let pieceEnd = interpolatedCoordinate(
                        from: start,
                        to: end,
                        progress: (coveredLength + pieceLength) / segmentLength
                    )
                    if isDrawingDash {
                        if dashCoordinates.isEmpty {
                            dashCoordinates.append(pieceStart)
                        }
                        dashCoordinates.append(pieceEnd)
                    }
                    coveredLength += pieceLength
                    remainingPhaseLength -= pieceLength

                    if remainingPhaseLength <= 0.001 {
                        if isDrawingDash, dashCoordinates.count > 1 {
                            annotations.append(routeAnnotation(for: dashCoordinates))
                        }
                        dashCoordinates.removeAll(keepingCapacity: true)
                        isDrawingDash.toggle()
                        remainingPhaseLength = isDrawingDash ? dashLength : gapLength
                    }
                }
            }

            if isDrawingDash, dashCoordinates.count > 1 {
                annotations.append(routeAnnotation(for: dashCoordinates))
            }
            return annotations
        }

        private func interpolatedCoordinate(
            from start: CLLocationCoordinate2D,
            to end: CLLocationCoordinate2D,
            progress: Double
        ) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * progress,
                longitude: start.longitude + (end.longitude - start.longitude) * progress
            )
        }

        private func navigationCoordinates(
            from origin: TodayMapPoint,
            to destination: TodayMapPoint,
            transportType: MKDirectionsTransportType
        ) async -> [CLLocationCoordinate2D]? {
            let request = MKDirections.Request()
            // Do not replace the itinerary coordinate with a nearby text
            // search result. That can produce a route that visibly terminates
            // beside a pin, especially for accommodations and trailheads.
            request.source = routingMapItem(for: origin)
            request.destination = routingMapItem(for: destination)
            request.transportType = transportType
            request.requestsAlternateRoutes = false

            let directions = MKDirections(request: request)
            activeDirections = directions
            defer {
                if activeDirections === directions {
                    activeDirections = nil
                }
            }

            guard let route = try? await directions.calculate().routes.first else { return nil }
            var coordinates = [CLLocationCoordinate2D](
                repeating: CLLocationCoordinate2D(),
                count: route.polyline.pointCount
            )
            route.polyline.getCoordinates(
                &coordinates,
                range: NSRange(location: 0, length: route.polyline.pointCount)
            )
            return coordinates
        }

        private func routingMapItem(for point: TodayMapPoint) -> MKMapItem {
            AppleMapService.mapItem(
                for: RoutePoint(latitude: point.latitude, longitude: point.longitude),
                name: point.title
            )
        }

        private func serverNavigationCoordinates(
            from origin: TodayMapPoint,
            to destination: TodayMapPoint
        ) async -> [CLLocationCoordinate2D]? {
            let request = RouteDirectionsRequest(
                origin: RoutePoint(latitude: origin.latitude, longitude: origin.longitude),
                destination: RoutePoint(latitude: destination.latitude, longitude: destination.longitude),
                mode: .driving
            )
            guard let route = try? await APIClient().routeDirections(request),
                  route.coordinates.count > 1 else {
                return nil
            }
            return route.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
        }

        fileprivate func updateCamera(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            focus: CLLocationCoordinate2D?,
            requestID: Int,
            bottomInset: CGFloat
        ) {
            if points.isEmpty {
                guard !isFollowingUserLocation else { return }
                isFollowingUserLocation = true
                mapView.showsUserLocation = true
                mapView.setUserTrackingMode(
                    .follow,
                    animated: true,
                    completionHandler: nil
                )
                return
            }

            if isFollowingUserLocation {
                isFollowingUserLocation = false
                mapView.setUserTrackingMode(
                    .none,
                    animated: false,
                    completionHandler: nil
                )
                mapView.showsUserLocation = false
            }

            guard requestID != handledCameraRequestID else { return }
            handledCameraRequestID = requestID
            let animated = requestID > 0
            overviewBottomInset = bottomInset

            if let focus {
                isShowingRouteOverview = false
                mapView.setCenter(
                    focus,
                    zoomLevel: points.count == 1 ? 12 : poiSwiperFocusZoomLevel,
                    animated: animated
                )
                return
            }

            isShowingRouteOverview = true
            fitRouteOverview(on: mapView, points: points, animated: animated)
        }

        private func fitRouteOverviewIfNeeded(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            animated: Bool
        ) {
            guard isShowingRouteOverview else { return }
            fitRouteOverview(on: mapView, points: points, animated: animated)
        }

        /// The driving geometry can bend well outside the bounding box of its
        /// endpoints. Fit the line coordinates too, then run this again once
        /// asynchronous Apple route resolution has finished.
        private func fitRouteOverview(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            animated: Bool
        ) {
            var coordinates = points.map(\.coordinate)
            coordinates.append(contentsOf: displayedRouteCoordinates)
            if coordinates.count == 1, let coordinate = coordinates.first {
                mapView.setCenter(coordinate, zoomLevel: 12, animated: animated)
                return
            }
            mapView.setVisibleCoordinates(
                &coordinates,
                count: UInt(coordinates.count),
                edgePadding: UIEdgeInsets(
                    top: 150,
                    left: 60,
                    bottom: overviewBottomInset,
                    // The selected POI expands to the right of its map
                    // coordinate. Reserve that visual footprint so an
                    // overview never pins its action buttons to the edge.
                    right: 132
                ),
                direction: -1,
                duration: animated ? 0.35 : 0,
                animationTimingFunction: nil,
                completionHandler: nil
            )
        }

        func mapView(
            _ mapView: MLNMapView,
            viewFor annotation: any MLNAnnotation
        ) -> MLNAnnotationView? {
            guard let annotation = annotation as? MapLibreNumberedAnnotation else { return nil }
            let identifier = MapLibreNumberedAnnotationView.reuseIdentifier
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? MapLibreNumberedAnnotationView
                ?? MapLibreNumberedAnnotationView(reuseIdentifier: identifier)
            view.configure(
                with: annotation,
                placement: pinPlacements[annotation.pointID]
                    ?? regularPinPlacement(for: annotation, on: mapView)
            )
            return view
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            updatePinPlacements(on: mapView)
        }

        /// `regionDidChangeAnimated` only fires after a pan/zoom settles. Keep
        /// edge proxies recomputed during the gesture as well, otherwise their
        /// temporary map coordinates drift with the map until the user's
        /// finger lifts.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            updatePinPlacements(on: mapView)
        }

        private func updatePinPlacements(on mapView: MLNMapView) {
            let placements = calculatedPinPlacements(on: mapView)
            pinPlacements = placements

            for annotation in pointAnnotations {
                guard let placement = placements[annotation.pointID] else { continue }

                // MapLibre does not create an annotation view for a coordinate
                // outside its viewport. Edge pins therefore use a temporary
                // map coordinate under their screen-space number bubble while
                // retaining `sourceCoordinate` as the real itinerary POI.
                let displayedCoordinate = placement.isEdgePinned
                    ? mapView.convert(placement.anchorPoint, toCoordinateFrom: mapView)
                    : annotation.sourceCoordinate
                if annotation.coordinate.latitude != displayedCoordinate.latitude
                    || annotation.coordinate.longitude != displayedCoordinate.longitude {
                    annotation.coordinate = displayedCoordinate
                }

                guard let view = mapView.view(for: annotation) as? MapLibreNumberedAnnotationView else { continue }
                view.configure(
                    with: annotation,
                    placement: placement
                )
            }
        }

        private func calculatedPinPlacements(
            on mapView: MLNMapView
        ) -> [UUID: MapLibrePinPlacement] {
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return [:] }
            let safeRect = pinSafeRect(on: mapView)
            let sourcePoints = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, mapView.convert($0.sourceCoordinate, toPointTo: mapView))
            })
            let routePoints = sampledRouteScreenPoints(on: mapView)
            let regularPlacements: [UUID: MapLibrePinPlacement] = Dictionary(
                uniqueKeysWithValues: pointAnnotations.map { annotation in
                    let target = sourcePoints[annotation.pointID]!
                    return (
                        annotation.pointID,
                        regularPinPlacement(
                            for: annotation,
                            target: target,
                            safeRect: safeRect,
                            routePoints: routePoints,
                            otherPinPoints: sourcePoints
                                .filter { $0.key != annotation.pointID }
                                .map(\.value),
                            mapMidX: mapView.bounds.midX
                        )
                    )
                }
            )
            let edgeAnnotations = pointAnnotations.filter {
                guard let point = sourcePoints[$0.pointID],
                      let regularPlacement = regularPlacements[$0.pointID] else { return false }
                // Stay attached to the edge until both the real POI and its
                // complete white label can transition into the usable map
                // without clipping under the header/card.
                return !safeRect.contains(point) || !safeRect.contains(regularPlacement.labelRect)
            }
            let edgeCenters = arrangedEdgePinCenters(
                annotations: edgeAnnotations,
                sourcePoints: sourcePoints,
                safeRect: safeRect
            )

            var result: [UUID: MapLibrePinPlacement] = [:]
            for annotation in pointAnnotations {
                if let edgeCenter = edgeCenters[annotation.pointID] {
                    result[annotation.pointID] = edgePinPlacement(
                        for: annotation,
                        numberCenter: edgeCenter
                    )
                } else {
                    result[annotation.pointID] = regularPlacements[annotation.pointID]
                }
            }
            return result
        }

        private func pinSafeRect(on mapView: MLNMapView) -> CGRect {
            // Camera padding is intentionally smaller than the visible swiper
            // footprint. Edge pins need the full card + tab-bar exclusion or a
            // bottom proxy remains alive but hidden underneath the SwiftUI UI.
            let bottomExclusion = overviewBottomInset > 180
                ? overviewBottomInset + 120
                : overviewBottomInset
            return CGRect(
                x: 16,
                y: 108,
                // Keep the edge queue left of the always-visible action rail.
                width: max(1, mapView.bounds.width - 16 - 76),
                height: max(1, mapView.bounds.height - 108 - bottomExclusion)
            )
        }

        /// Selects a side and leader length that keeps an on-screen label clear
        /// of the orange route. Off-screen POIs are handled separately by edge
        /// pins because MapLibre culls their original annotation coordinates.
        private func regularPinPlacement(
            for annotation: MapLibreNumberedAnnotation,
            on mapView: MLNMapView
        ) -> MapLibrePinPlacement {
            regularPinPlacement(
                for: annotation,
                target: mapView.convert(annotation.sourceCoordinate, toPointTo: mapView),
                safeRect: pinSafeRect(on: mapView),
                routePoints: sampledRouteScreenPoints(on: mapView),
                otherPinPoints: pointAnnotations
                    .filter { $0 !== annotation }
                    .map { mapView.convert($0.sourceCoordinate, toPointTo: mapView) },
                mapMidX: mapView.bounds.midX
            )
        }

        private func regularPinPlacement(
            for annotation: MapLibreNumberedAnnotation,
            target: CGPoint,
            safeRect: CGRect,
            routePoints: [CGPoint],
            otherPinPoints: [CGPoint],
            mapMidX: CGFloat
        ) -> MapLibrePinPlacement {
            let preferredSide: MapLibrePinPlacement.Side = target.x < mapMidX ? .right : .left
            let sides: [MapLibrePinPlacement.Side] = [preferredSide, preferredSide.opposite]
            let reaches: [CGFloat] = [42, 50, 58, 66]
            var best = MapLibrePinPlacement.regular(
                target: target,
                side: preferredSide,
                horizontalReach: 50,
                isHighlighted: annotation.isHighlighted
            )
            var bestScore = CGFloat.greatestFiniteMagnitude

            for side in sides {
                for reach in reaches {
                    let candidate = MapLibrePinPlacement.regular(
                        target: target,
                        side: side,
                        horizontalReach: reach,
                        isHighlighted: annotation.isHighlighted
                    )
                    let labelRect = candidate.labelRect
                    let elbow = candidate.connectorPoints[1]
                    var score = overflowPenalty(for: labelRect, outside: safeRect) * 80
                    score += abs(reach - 50) * 0.35

                    // Do not place either white circle over an orange segment.
                    let expandedLabelRect = labelRect.insetBy(dx: -8, dy: -8)
                    score += CGFloat(routePoints.filter { expandedLabelRect.contains($0) }.count) * 150
                    score += CGFloat(otherPinPoints.filter { expandedLabelRect.contains($0) }.count) * 500

                    // Sample the diagonal itself. Ignore the immediate target
                    // neighborhood because every valid leader meets the route
                    // at its orange endpoint there.
                    for step in 2...9 {
                        let progress = CGFloat(step) / 10
                        let sample = CGPoint(
                            x: target.x + (elbow.x - target.x) * progress,
                            y: target.y + (elbow.y - target.y) * progress
                        )
                        let nearestRouteDistance = routePoints
                            .filter { hypot($0.x - target.x, $0.y - target.y) > 24 }
                            .map { hypot($0.x - sample.x, $0.y - sample.y) }
                            .min() ?? 100
                        if nearestRouteDistance < 18 {
                            let overlap = 18 - nearestRouteDistance
                            score += overlap * overlap * 2.5
                        }
                    }

                    if score < bestScore {
                        best = candidate
                        bestScore = score
                    }
                }
            }
            return best
        }

        private struct EdgePinCandidate {
            enum Edge {
                case top
                case right
                case bottom
                case left

                var isHorizontal: Bool { self == .top || self == .bottom }
            }

            let annotation: MapLibreNumberedAnnotation
            let edge: Edge
            let desiredCenter: CGPoint
            let axisMinimum: CGFloat
            let axisMaximum: CGFloat
            let extentBefore: CGFloat
            let extentAfter: CGFloat
        }

        /// Projects each unavailable POI onto the usable map boundary, then
        /// spaces pins that share an edge so their white bubbles do not stack.
        private func arrangedEdgePinCenters(
            annotations: [MapLibreNumberedAnnotation],
            sourcePoints: [UUID: CGPoint],
            safeRect: CGRect
        ) -> [UUID: CGPoint] {
            let candidates: [EdgePinCandidate] = annotations.compactMap { annotation in
                guard let source = sourcePoints[annotation.pointID] else { return nil }
                let topExtent = annotation.isHighlighted
                    ? MapLibrePinPlacement.highlightedTopExtent
                    : MapLibrePinPlacement.bubbleSize / 2
                let bottomExtent = MapLibrePinPlacement.bubbleSize / 2
                let centerRect = CGRect(
                    x: safeRect.minX + MapLibrePinPlacement.bubbleSize / 2,
                    y: safeRect.minY + topExtent,
                    width: max(1, safeRect.width - MapLibrePinPlacement.bubbleSize),
                    height: max(1, safeRect.height - topExtent - bottomExtent)
                )
                let projection = projectedToBoundary(
                    source,
                    from: CGPoint(x: safeRect.midX, y: safeRect.midY),
                    inside: centerRect
                )
                if projection.edge.isHorizontal {
                    return EdgePinCandidate(
                        annotation: annotation,
                        edge: projection.edge,
                        desiredCenter: projection.point,
                        axisMinimum: centerRect.minX,
                        axisMaximum: centerRect.maxX,
                        extentBefore: MapLibrePinPlacement.bubbleSize / 2,
                        extentAfter: MapLibrePinPlacement.bubbleSize / 2
                    )
                }
                return EdgePinCandidate(
                    annotation: annotation,
                    edge: projection.edge,
                    desiredCenter: projection.point,
                    axisMinimum: centerRect.minY,
                    axisMaximum: centerRect.maxY,
                    extentBefore: topExtent,
                    extentAfter: bottomExtent
                )
            }

            var result: [UUID: CGPoint] = [:]
            for edge in [EdgePinCandidate.Edge.top, .right, .bottom, .left] {
                let group = candidates
                    .filter { $0.edge == edge }
                    .sorted {
                        let lhs = edge.isHorizontal ? $0.desiredCenter.x : $0.desiredCenter.y
                        let rhs = edge.isHorizontal ? $1.desiredCenter.x : $1.desiredCenter.y
                        return lhs == rhs ? $0.annotation.index < $1.annotation.index : lhs < rhs
                    }
                guard !group.isEmpty else { continue }
                let lanes = edgeLanes(for: group)
                let laneStride = edge.isHorizontal
                    && group.contains(where: { $0.annotation.isHighlighted })
                    ? MapLibrePinPlacement.highlightedTopExtent
                        + MapLibrePinPlacement.bubbleSize / 2 + 6
                    : MapLibrePinPlacement.bubbleSize + 6

                for (laneIndex, lane) in lanes.enumerated() {
                    let positions = spacedEdgePositions(for: lane, horizontal: edge.isHorizontal)
                    for (candidate, position) in zip(lane, positions) {
                        var center = candidate.desiredCenter
                        if edge.isHorizontal {
                            center.x = position
                            center.y += (edge == .top ? 1 : -1) * CGFloat(laneIndex) * laneStride
                        } else {
                            center.y = position
                            center.x += (edge == .left ? 1 : -1) * CGFloat(laneIndex) * laneStride
                        }
                        result[candidate.annotation.pointID] = center
                    }
                }
            }
            return result
        }

        /// Splits an overcrowded edge into inward lanes instead of allowing
        /// bubbles to overlap and hide one another. Most trips need one lane;
        /// dense days can use a second compact row/column near the same edge.
        private func edgeLanes(for candidates: [EdgePinCandidate]) -> [[EdgePinCandidate]] {
            guard let first = candidates.first else { return [] }
            let availableLength = first.axisMaximum - first.axisMinimum
            let gap: CGFloat = 6
            var lanes: [[EdgePinCandidate]] = [[]]
            var occupied: CGFloat = 0

            for candidate in candidates {
                let length = candidate.extentBefore + candidate.extentAfter
                let proposed = lanes[lanes.count - 1].isEmpty
                    ? length
                    : occupied + gap + length
                if proposed > availableLength, !lanes[lanes.count - 1].isEmpty {
                    lanes.append([candidate])
                    occupied = length
                } else {
                    lanes[lanes.count - 1].append(candidate)
                    occupied = proposed
                }
            }
            return lanes
        }

        private func spacedEdgePositions(
            for candidates: [EdgePinCandidate],
            horizontal: Bool
        ) -> [CGFloat] {
            let gap: CGFloat = 6
            var positions = candidates.map {
                let desired = horizontal ? $0.desiredCenter.x : $0.desiredCenter.y
                return min($0.axisMaximum, max($0.axisMinimum, desired))
            }
            guard positions.count > 1 else { return positions }

            for index in 1..<positions.count {
                let separation = candidates[index - 1].extentAfter + gap + candidates[index].extentBefore
                positions[index] = max(positions[index], positions[index - 1] + separation)
            }
            if let last = positions.indices.last {
                positions[last] = min(positions[last], candidates[last].axisMaximum)
                for index in stride(from: last - 1, through: 0, by: -1) {
                    let separation = candidates[index].extentAfter + gap + candidates[index + 1].extentBefore
                    positions[index] = min(positions[index], positions[index + 1] - separation)
                    positions[index] = max(positions[index], candidates[index].axisMinimum)
                }
            }
            return positions
        }

        private func projectedToBoundary(
            _ point: CGPoint,
            from center: CGPoint,
            inside rect: CGRect
        ) -> (point: CGPoint, edge: EdgePinCandidate.Edge) {
            let dx = point.x - center.x
            let dy = point.y - center.y
            var scale = CGFloat.greatestFiniteMagnitude
            var edge = EdgePinCandidate.Edge.top

            if dx > 0 {
                let candidate = (rect.maxX - center.x) / dx
                if candidate < scale { scale = candidate; edge = .right }
            } else if dx < 0 {
                let candidate = (rect.minX - center.x) / dx
                if candidate < scale { scale = candidate; edge = .left }
            }
            if dy > 0 {
                let candidate = (rect.maxY - center.y) / dy
                if candidate < scale { scale = candidate; edge = .bottom }
            } else if dy < 0 {
                let candidate = (rect.minY - center.y) / dy
                if candidate < scale { scale = candidate; edge = .top }
            }

            if !scale.isFinite {
                return (CGPoint(x: rect.midX, y: rect.minY), .top)
            }
            return (
                CGPoint(x: center.x + dx * scale, y: center.y + dy * scale),
                edge
            )
        }

        private func edgePinPlacement(
            for annotation: MapLibreNumberedAnnotation,
            numberCenter: CGPoint
        ) -> MapLibrePinPlacement {
            return MapLibrePinPlacement(
                anchorPoint: numberCenter,
                numberCenter: numberCenter,
                connectorPoints: [],
                targetCenter: nil,
                isHighlighted: annotation.isHighlighted,
                isEdgePinned: true
            )
        }

        private func sampledRouteScreenPoints(on mapView: MLNMapView) -> [CGPoint] {
            guard !displayedRouteCoordinates.isEmpty else { return [] }
            let step = max(1, displayedRouteCoordinates.count / 400)
            var points = stride(from: 0, to: displayedRouteCoordinates.count, by: step).map {
                mapView.convert(displayedRouteCoordinates[$0], toPointTo: mapView)
            }
            if let last = displayedRouteCoordinates.last {
                points.append(mapView.convert(last, toPointTo: mapView))
            }
            return points
        }

        private func overflowPenalty(for rect: CGRect, outside safeRect: CGRect) -> CGFloat {
            max(0, safeRect.minX - rect.minX)
                + max(0, rect.maxX - safeRect.maxX)
                + max(0, safeRect.minY - rect.minY)
                + max(0, rect.maxY - safeRect.maxY)
        }

        func mapView(
            _ mapView: MLNMapView,
            strokeColorForShapeAnnotation annotation: MLNShape
        ) -> UIColor {
            UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        }

        func mapView(
            _ mapView: MLNMapView,
            lineWidthForPolylineAnnotation annotation: MLNPolyline
        ) -> CGFloat {
            4
        }

        func mapView(
            _ mapView: MLNMapView,
            alphaForShapeAnnotation annotation: MLNShape
        ) -> CGFloat {
            1
        }

        func mapView(_ mapView: MLNMapView, didFailToLoadImage imageName: String) -> UIImage? {
            MapLibrePOIIcon.image(named: imageName)
        }

        func mapViewDidFailLoadingMap(_ mapView: MLNMapView, withError error: any Error) {
            #if DEBUG
            print("MapLibre Today map failed: \(error.localizedDescription)")
            #endif
        }

    }
}

private enum MapLibrePOIIcon {
    static func image(named name: String) -> UIImage? {
        let symbolName: String
        switch name {
        case "indo-poi-hospital":
            symbolName = "cross.case.fill"
        case "indo-poi-park":
            symbolName = "leaf.fill"
        case "indo-poi-worship":
            symbolName = "building.columns.fill"
        case "indo-poi-transit":
            symbolName = "tram.fill"
        case "indo-poi-education":
            symbolName = "graduationcap.fill"
        case "indo-poi-civic":
            symbolName = "building.2.fill"
        case "indo-poi-food":
            symbolName = "fork.knife"
        case "indo-poi-shop":
            symbolName = "bag.fill"
        case "indo-poi-culture":
            symbolName = "building.columns"
        case "indo-poi-attraction":
            symbolName = "star.fill"
        case "indo-poi-place":
            symbolName = "mappin.circle.fill"
        case "indo-poi-airport":
            symbolName = "airplane"
        default:
            return nil
        }

        let configuration = UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        guard let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
            .withTintColor(UIColor(white: 189 / 255, alpha: 1), renderingMode: .alwaysOriginal) else {
            return nil
        }

        let canvas = CGSize(width: 16, height: 16)
        let renderer = UIGraphicsImageRenderer(size: canvas)
        return renderer.image { _ in
            let origin = CGPoint(
                x: (canvas.width - symbol.size.width) / 2,
                y: (canvas.height - symbol.size.height) / 2
            )
            symbol.draw(at: origin)
        }
    }
}

private final class MapLibreNumberedAnnotation: MLNPointAnnotation {
    let pointID: UUID
    let index: Int
    let isHighlighted: Bool
    let categorySymbolName: String
    let sourceCoordinate: CLLocationCoordinate2D

    init(point: TodayMapPoint, index: Int, isHighlighted: Bool) {
        pointID = point.id
        self.index = index
        self.isHighlighted = isHighlighted
        categorySymbolName = point.categorySymbolName
        sourceCoordinate = point.coordinate
        super.init()
        coordinate = point.coordinate
        title = point.title
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private struct MapLibrePinPlacement {
    enum Side {
        case left
        case right

        var direction: CGFloat { self == .left ? -1 : 1 }
        var opposite: Side { self == .left ? .right : .left }
    }

    static let bubbleSize: CGFloat = 32
    static let bubbleGap: CGFloat = 4
    static let categoryGap: CGFloat = 2
    static let stemLength: CGFloat = 16
    static let targetSize: CGFloat = 10
    static let highlightedTopExtent = bubbleSize * 1.5 + categoryGap

    /// Screen point backed by the annotation's temporary map coordinate. For
    /// regular pins this is the orange POI dot; for edge pins it is the white
    /// number bubble, which keeps MapLibre from culling an off-screen POI.
    let anchorPoint: CGPoint
    let numberCenter: CGPoint
    let connectorPoints: [CGPoint]
    let targetCenter: CGPoint?
    let isHighlighted: Bool
    let isEdgePinned: Bool

    var labelRect: CGRect {
        Self.labelRect(numberCenter: numberCenter, isHighlighted: isHighlighted)
    }

    static func labelRect(numberCenter: CGPoint, isHighlighted: Bool) -> CGRect {
        let numberRect = CGRect(
            x: numberCenter.x - Self.bubbleSize / 2,
            y: numberCenter.y - Self.bubbleSize / 2,
            width: Self.bubbleSize,
            height: Self.bubbleSize
        )
        guard isHighlighted else { return numberRect }
        let categoryRect = numberRect.offsetBy(
            dx: 0,
            dy: -(Self.bubbleSize + Self.categoryGap)
        )
        return numberRect.union(categoryRect)
    }

    static func regular(
        target: CGPoint,
        side: Side,
        horizontalReach: CGFloat,
        isHighlighted: Bool
    ) -> Self {
        let diagonalRise = min(62, max(40, horizontalReach * 0.9))
        let numberCenter = CGPoint(
            x: target.x + side.direction * horizontalReach,
            y: target.y - diagonalRise - stemLength - bubbleGap - bubbleSize / 2
        )
        let lineStart = CGPoint(
            x: numberCenter.x,
            y: numberCenter.y + bubbleSize / 2 + bubbleGap
        )
        let elbow = CGPoint(
            x: numberCenter.x,
            y: lineStart.y + stemLength
        )
        return Self(
            anchorPoint: target,
            numberCenter: numberCenter,
            connectorPoints: [lineStart, elbow, target],
            targetCenter: target,
            isHighlighted: isHighlighted,
            isEdgePinned: false
        )
    }
}

private final class MapLibreNumberedAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "MapLibreTodayNumberedPOI"

    private let numberBackground = UIView()
    private let categoryBackground = UIView()
    private let numberLabel = UILabel()
    private let categoryImageView = UIImageView()
    private let connectorLayer = CAShapeLayer()
    private let gooeyBackgroundLayer = CAShapeLayer()
    private let targetDot = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        backgroundColor = .clear

        numberBackground.backgroundColor = .white
        categoryBackground.backgroundColor = .white
        numberBackground.layer.cornerRadius = MapLibrePinPlacement.bubbleSize / 2
        categoryBackground.layer.cornerRadius = MapLibrePinPlacement.bubbleSize / 2

        connectorLayer.strokeColor = UIColor.white.cgColor
        connectorLayer.fillColor = UIColor.clear.cgColor
        connectorLayer.lineWidth = 2
        connectorLayer.lineCap = .round
        connectorLayer.lineJoin = .round
        layer.insertSublayer(connectorLayer, at: 0)

        gooeyBackgroundLayer.fillColor = UIColor.white.cgColor
        gooeyBackgroundLayer.strokeColor = nil
        layer.insertSublayer(gooeyBackgroundLayer, at: 1)

        targetDot.backgroundColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        targetDot.layer.borderColor = UIColor.white.cgColor
        targetDot.layer.borderWidth = 2
        targetDot.layer.cornerRadius = MapLibrePinPlacement.targetSize / 2

        numberLabel.textAlignment = .center
        numberLabel.textColor = .black
        numberLabel.font = .systemFont(ofSize: 16, weight: .medium)
        categoryImageView.tintColor = .black
        categoryImageView.contentMode = .scaleAspectFit

        addSubview(targetDot)
        addSubview(numberBackground)
        addSubview(categoryBackground)
        addSubview(numberLabel)
        addSubview(categoryImageView)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(
        with annotation: MapLibreNumberedAnnotation,
        placement: MapLibrePinPlacement
    ) {
        let bubbleSize = MapLibrePinPlacement.bubbleSize
        let targetSize = MapLibrePinPlacement.targetSize
        let padding: CGFloat = 4
        var screenFrame = placement.labelRect
        for point in placement.connectorPoints {
            screenFrame = screenFrame.union(
                CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
            )
        }
        if let targetCenter = placement.targetCenter {
            screenFrame = screenFrame.union(
                CGRect(
                    x: targetCenter.x - targetSize / 2,
                    y: targetCenter.y - targetSize / 2,
                    width: targetSize,
                    height: targetSize
                )
            )
        }
        screenFrame = screenFrame.insetBy(dx: -padding, dy: -padding)
        bounds = CGRect(origin: .zero, size: screenFrame.size)
        centerOffset = CGVector(
            dx: screenFrame.midX - placement.anchorPoint.x,
            dy: screenFrame.midY - placement.anchorPoint.y
        )

        func local(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x - screenFrame.minX, y: point.y - screenFrame.minY)
        }

        let localNumberCenter = local(placement.numberCenter)
        let numberFrame = CGRect(
            x: localNumberCenter.x - bubbleSize / 2,
            y: localNumberCenter.y - bubbleSize / 2,
            width: bubbleSize,
            height: bubbleSize
        )
        numberBackground.frame = numberFrame
        numberLabel.frame = numberFrame
        numberLabel.text = String(annotation.index + 1)

        if annotation.isHighlighted {
            let categoryFrame = numberFrame.offsetBy(
                dx: 0,
                dy: -(bubbleSize + MapLibrePinPlacement.categoryGap)
            )
            categoryBackground.frame = categoryFrame
            categoryImageView.frame = categoryFrame.insetBy(dx: 8, dy: 8)
            categoryImageView.image = (
                UIImage(named: "icon-camera-outline")
                    ?? UIImage(named: "icon-camera")
                    ?? UIImage(named: "icon-landscape-outline")
            )?.withRenderingMode(.alwaysTemplate)
                ?? UIImage(
                    systemName: annotation.categorySymbolName,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                )
            // The highlighted pair is drawn by one continuous metaball path;
            // hiding the two independent circles avoids visible layer seams.
            numberBackground.isHidden = true
            categoryBackground.isHidden = true
            categoryImageView.isHidden = false
            gooeyBackgroundLayer.frame = bounds
            gooeyBackgroundLayer.path = gooeyPath(
                categoryFrame: categoryFrame,
                numberFrame: numberFrame
            ).cgPath
            gooeyBackgroundLayer.isHidden = false
        } else {
            numberBackground.isHidden = false
            categoryBackground.isHidden = true
            categoryImageView.isHidden = true
            gooeyBackgroundLayer.isHidden = true
        }

        let leader = UIBezierPath()
        if let first = placement.connectorPoints.first {
            leader.move(to: local(first))
            for point in placement.connectorPoints.dropFirst() {
                leader.addLine(to: local(point))
            }
        }
        connectorLayer.frame = bounds
        connectorLayer.path = leader.cgPath

        if let targetCenter = placement.targetCenter {
            let localTarget = local(targetCenter)
            targetDot.frame = CGRect(
                x: localTarget.x - targetSize / 2,
                y: localTarget.y - targetSize / 2,
                width: targetSize,
                height: targetSize
            )
            targetDot.isHidden = false
        } else {
            targetDot.isHidden = true
        }

        let title = annotation.title ?? "地点"
        accessibilityLabel = annotation.isHighlighted ? "正在查看，\(title)" : title
        transform = .identity
    }

    /// Cuberto's gooey effect derives its joints from circle tangents. Use the
    /// same geometry here: both bridge cubics enter the circles along their
    /// exact tangent vectors, making the full contour C1-continuous.
    private func gooeyPath(categoryFrame: CGRect, numberFrame: CGRect) -> UIBezierPath {
        let centerX = categoryFrame.midX
        let radius = categoryFrame.width / 2
        let upperCenter = CGPoint(x: centerX, y: categoryFrame.midY)
        let lowerCenter = CGPoint(x: centerX, y: numberFrame.midY)
        let joinAngle = 55 * CGFloat.pi / 180
        let handleLength = radius * 0.38

        func point(on circle: CGPoint, angle: CGFloat) -> CGPoint {
            CGPoint(
                x: circle.x + cos(angle) * radius,
                y: circle.y + sin(angle) * radius
            )
        }

        func clockwiseTangent(at angle: CGFloat) -> CGVector {
            CGVector(dx: -sin(angle), dy: cos(angle))
        }

        func offset(_ point: CGPoint, along vector: CGVector, by distance: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + vector.dx * distance,
                y: point.y + vector.dy * distance
            )
        }

        let upperRightAngle = joinAngle
        let lowerRightAngle = -joinAngle
        let lowerLeftAngle = CGFloat.pi + joinAngle
        let upperLeftAngle = CGFloat.pi - joinAngle
        let upperRight = point(on: upperCenter, angle: upperRightAngle)
        let lowerRight = point(on: lowerCenter, angle: lowerRightAngle)
        let lowerLeft = point(on: lowerCenter, angle: lowerLeftAngle)
        let upperLeft = point(on: upperCenter, angle: upperLeftAngle)

        let path = UIBezierPath()
        path.move(to: upperRight)
        path.addCurve(
            to: lowerRight,
            controlPoint1: offset(
                upperRight,
                along: clockwiseTangent(at: upperRightAngle),
                by: handleLength
            ),
            controlPoint2: offset(
                lowerRight,
                along: clockwiseTangent(at: lowerRightAngle),
                by: -handleLength
            )
        )
        path.addArc(
            withCenter: lowerCenter,
            radius: radius,
            startAngle: lowerRightAngle,
            endAngle: lowerLeftAngle,
            clockwise: true
        )
        path.addCurve(
            to: upperLeft,
            controlPoint1: offset(
                lowerLeft,
                along: clockwiseTangent(at: lowerLeftAngle),
                by: handleLength
            ),
            controlPoint2: offset(
                upperLeft,
                along: clockwiseTangent(at: upperLeftAngle),
                by: -handleLength
            )
        )
        path.addArc(
            withCenter: upperCenter,
            radius: radius,
            startAngle: upperLeftAngle,
            endAngle: 2 * CGFloat.pi + upperRightAngle,
            clockwise: true
        )
        path.close()
        return path
    }
}
