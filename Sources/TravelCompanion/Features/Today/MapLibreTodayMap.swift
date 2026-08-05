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
            view.configure(with: annotation)
            return view
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

    init(point: TodayMapPoint, index: Int, isHighlighted: Bool) {
        pointID = point.id
        self.index = index
        self.isHighlighted = isHighlighted
        categorySymbolName = point.categorySymbolName
        super.init()
        coordinate = point.coordinate
        title = point.title
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class MapLibreNumberedAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "MapLibreTodayNumberedPOI"

    private let numberBackground = UIView()
    private let categoryBackground = UIView()
    private let numberLabel = UILabel()
    private let categoryImageView = UIImageView()
    private let connectorLayer = CAShapeLayer()
    private let targetDot = UIView()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
        centerOffset = CGVector(dx: 0, dy: -2)
        scalesWithViewingDistance = false

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        numberBackground.backgroundColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        categoryBackground.backgroundColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        connectorLayer.strokeColor = UIColor.white.cgColor
        connectorLayer.fillColor = UIColor.clear.cgColor
        connectorLayer.lineWidth = 2
        connectorLayer.lineCap = .round
        connectorLayer.lineJoin = .round
        layer.insertSublayer(connectorLayer, at: 0)

        targetDot.backgroundColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        targetDot.layer.borderColor = UIColor.white.cgColor
        targetDot.layer.borderWidth = 2
        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        categoryImageView.tintColor = .white
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

    func configure(with annotation: MapLibreNumberedAnnotation) {
        numberLabel.text = String(annotation.index + 1)
        let title = annotation.title ?? "地点"
        accessibilityLabel = annotation.isHighlighted ? "正在查看，\(title)" : title

        if annotation.isHighlighted {
            // Keep the white leader short and leave a small rightward visual
            // footprint for POIs that sit near the map's right edge.
            bounds = CGRect(x: 0, y: 0, width: 80, height: 136)
            centerOffset = CGVector(dx: 32, dy: -64)

            categoryBackground.frame = CGRect(x: 42, y: 0, width: 36, height: 36)
            categoryBackground.layer.cornerRadius = 18
            categoryImageView.frame = CGRect(x: 50, y: 8, width: 20, height: 20)
            categoryImageView.image = (
                UIImage(named: "icon-camera-outline")
                    ?? UIImage(named: "icon-camera")
                    ?? UIImage(named: "icon-landscape-outline")
            )?.withRenderingMode(.alwaysTemplate)
                ?? UIImage(
                    systemName: annotation.categorySymbolName,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                )
            categoryBackground.isHidden = false
            categoryImageView.isHidden = false

            numberBackground.frame = CGRect(x: 38, y: 40, width: 42, height: 42)
            numberBackground.layer.cornerRadius = 21
            numberLabel.frame = numberBackground.frame
            numberLabel.font = .systemFont(ofSize: 20, weight: .bold)

            let leader = UIBezierPath()
            leader.move(to: CGPoint(x: 59, y: 82))
            leader.addLine(to: CGPoint(x: 59, y: 90))
            leader.addCurve(
                to: CGPoint(x: 12, y: 128),
                controlPoint1: CGPoint(x: 59, y: 96),
                controlPoint2: CGPoint(x: 20, y: 123)
            )
            leader.addLine(to: CGPoint(x: 8, y: 132))
            connectorLayer.frame = bounds
            connectorLayer.path = leader.cgPath
            connectorLayer.isHidden = false

            targetDot.frame = CGRect(x: 4, y: 128, width: 8, height: 8)
            targetDot.layer.cornerRadius = 4
            targetDot.isHidden = false
        } else {
            bounds = CGRect(x: 0, y: 0, width: 32, height: 32)
            centerOffset = CGVector(dx: 0, dy: -2)
            numberBackground.frame = bounds
            numberBackground.layer.cornerRadius = 16
            numberLabel.frame = bounds
            numberLabel.font = .systemFont(ofSize: 14, weight: .semibold)
            categoryBackground.isHidden = true
            categoryImageView.isHidden = true
            connectorLayer.isHidden = true
            targetDot.isHidden = true
        }

        backgroundColor = .clear
        transform = .identity
    }
}
