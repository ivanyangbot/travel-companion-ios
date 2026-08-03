import MapKit
import SwiftUI
import UIKit

/// Map data that is independent from the SwiftData snapshots used by TodayView.
struct TodayMapPoint: Identifiable, Equatable {
    let id: UUID
    let title: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// Persists resolved road geometry by adjacent itinerary points. A changed
/// coordinate or order naturally produces a different key, so only affected
/// legs are requested again after the user edits the itinerary.
@MainActor
private final class TodayRouteGeometryCache {
    static let shared = TodayRouteGeometryCache()

    private struct Coordinate: Codable {
        let latitude: Double
        let longitude: Double
    }

    private struct Entry: Codable {
        let coordinates: [Coordinate]
        let storedAt: Date
    }

    private static let storageKey = "todayRouteGeometryCache.v1"
    private static let maximumEntryCount = 128
    private var entries: [String: Entry]

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            entries = [:]
            return
        }
        // v1 originally included TravelCardSnapshot.id, but that UUID is
        // regenerated whenever a server snapshot decodes. Strip it from old
        // keys so already downloaded routes remain usable after this fix.
        entries = decoded.reduce(into: [:]) { migrated, item in
            let key = Self.coordinateOnlyKey(fromStoredKey: item.key) ?? item.key
            if let existing = migrated[key], existing.storedAt >= item.value.storedAt {
                return
            }
            migrated[key] = item.value
        }
        persist()
    }

    func polyline(from origin: TodayMapPoint, to destination: TodayMapPoint) -> MKPolyline? {
        guard let entry = entries[Self.key(from: origin, to: destination)],
              entry.coordinates.count > 1 else { return nil }
        var coordinates = entry.coordinates.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        }
        return MKPolyline(coordinates: &coordinates, count: coordinates.count)
    }

    func store(_ polyline: MKPolyline, from origin: TodayMapPoint, to destination: TodayMapPoint) {
        guard polyline.pointCount > 1 else { return }
        var coordinates = [CLLocationCoordinate2D](
            repeating: CLLocationCoordinate2D(),
            count: polyline.pointCount
        )
        polyline.getCoordinates(
            &coordinates,
            range: NSRange(location: 0, length: polyline.pointCount)
        )
        entries[Self.key(from: origin, to: destination)] = Entry(
            coordinates: coordinates.map {
                Coordinate(latitude: $0.latitude, longitude: $0.longitude)
            },
            storedAt: .now
        )
        trimIfNeeded()
        persist()
    }

    private static func key(from origin: TodayMapPoint, to destination: TodayMapPoint) -> String {
        "\(pointKey(origin))->\(pointKey(destination))"
    }

    private static func pointKey(_ point: TodayMapPoint) -> String {
        "\(String(point.latitude.bitPattern, radix: 16)):\(String(point.longitude.bitPattern, radix: 16))"
    }

    private static func coordinateOnlyKey(fromStoredKey key: String) -> String? {
        let legs = key.components(separatedBy: "->")
        guard legs.count == 2 else { return nil }
        let normalized = legs.compactMap { point -> String? in
            let components = point.split(separator: ":", omittingEmptySubsequences: false)
            if components.count == 2 {
                return point
            }
            guard components.count == 3 else { return nil }
            return "\(components[1]):\(components[2])"
        }
        guard normalized.count == 2 else { return nil }
        return normalized.joined(separator: "->")
    }

    private func trimIfNeeded() {
        guard entries.count > Self.maximumEntryCount else { return }
        let overflow = entries.count - Self.maximumEntryCount
        for key in entries.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(overflow).map(\.key) {
            entries.removeValue(forKey: key)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// A tiny charcoal tile. The renderer blends it over Apple Maps to create the
/// near-black, low-detail cartography used by the Today screen.
final class DarkMapTileOverlay: MKTileOverlay {
    static let tintAlpha: CGFloat = 0.60

    /// A deeper #101010 tile lets us reduce opacity and preserve brighter road
    /// contrast without lifting the overall background.
    private static let tileData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGMQEBD4DwABlAEwLpWcygAAAABJRU5ErkJggg=="
    )!

    override init(urlTemplate: String? = nil) {
        super.init(urlTemplate: urlTemplate)
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 0
        maximumZ = 22

        // Apple cartography remains underneath so its road linework is visible.
        canReplaceMapContent = false
    }

    override func loadTile(
        at path: MKTileOverlayPath,
        result: @escaping (Data?, (any Error)?) -> Void
    ) {
        result(Self.tileData, nil)
    }
}

/// MKTileOverlay isn't exposed by SwiftUI.Map, so the Today screen uses this
/// small bridge while keeping the rest of the screen in SwiftUI.
struct TodayMapCanvas: UIViewRepresentable {
    let points: [TodayMapPoint]
    let selectedIndex: Int
    let cameraFocus: CLLocationCoordinate2D?
    let cameraRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.overrideUserInterfaceStyle = .dark

        let configuration = MKStandardMapConfiguration()
        configuration.elevationStyle = .flat
        configuration.emphasisStyle = .default
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        mapView.preferredConfiguration = configuration

        let colorOverlay = DarkMapTileOverlay()
        mapView.addOverlay(colorOverlay, level: .aboveLabels)
        context.coordinator.colorOverlay = colorOverlay
        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex
        )

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex
        )
        context.coordinator.updateCamera(
            on: mapView,
            points: points,
            focus: cameraFocus,
            requestID: cameraRequestID
        )
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        fileprivate var colorOverlay: DarkMapTileOverlay?
        private var routeOverlays: [MKPolyline] = []
        private var routeTask: Task<Void, Never>?
        private var activeDirections: MKDirections?
        private var routeGeneration = 0
        private var resolvedMapItems: [UUID: MKMapItem] = [:]
        private var renderedPoints: [TodayMapPoint] = []
        private var renderedSelection = -1
        private var handledCameraRequestID = -1

        fileprivate func updateContent(
            on mapView: MKMapView,
            points: [TodayMapPoint],
            selectedIndex: Int
        ) {
            guard points != renderedPoints || selectedIndex != renderedSelection else { return }
            let pointsChanged = points != renderedPoints

            let oldAnnotations = mapView.annotations.compactMap { $0 as? NumberedPOIAnnotation }
            mapView.removeAnnotations(oldAnnotations)

            let annotations = points.enumerated().map { index, point in
                NumberedPOIAnnotation(
                    point: point,
                    index: index,
                    isHighlighted: index == selectedIndex
                )
            }
            mapView.addAnnotations(annotations)

            if pointsChanged {
                rebuildNavigationRoute(on: mapView, points: points)
            }

            renderedPoints = points
            renderedSelection = selectedIndex
        }

        /// Requests a real driving route for every adjacent pair of POIs. Each
        /// MKRoute.polyline follows the road geometry returned by Apple Maps.
        private func rebuildNavigationRoute(on mapView: MKMapView, points: [TodayMapPoint]) {
            routeTask?.cancel()
            activeDirections?.cancel()
            routeGeneration &+= 1
            let generation = routeGeneration

            mapView.removeOverlays(routeOverlays)
            routeOverlays.removeAll()
            let routeCache = TodayRouteGeometryCache.shared
            guard points.count > 1 else { return }

            var missingLegs: [(origin: TodayMapPoint, destination: TodayMapPoint)] = []
            for (origin, destination) in zip(points, points.dropFirst()) {
                if let cached = routeCache.polyline(
                    from: origin,
                    to: destination
                ) {
                    routeOverlays.append(cached)
                } else {
                    missingLegs.append((origin, destination))
                }
            }

            // Cache hits are attached before makeUIView/updateUIView returns,
            // so opening Today never waits for an asynchronous routing task.
            if !routeOverlays.isEmpty {
                mapView.addOverlays(routeOverlays, level: .aboveLabels)
            }
            guard !missingLegs.isEmpty else { return }

            routeTask = Task { [weak self, weak mapView] in
                guard let self, let mapView else { return }

                for (origin, destination) in missingLegs {
                    guard !Task.isCancelled, generation == routeGeneration else { return }
                    var polyline = await navigationPolyline(
                        from: origin,
                        to: destination,
                        transportType: .automobile
                    )
                    if polyline == nil {
                        polyline = await navigationPolyline(
                            from: origin,
                            to: destination,
                            transportType: .walking
                        )
                    }
                    if polyline == nil {
                        polyline = await serverNavigationPolyline(from: origin, to: destination)
                    }
                    if let polyline {
                        routeCache.store(
                            polyline,
                            from: origin,
                            to: destination
                        )
                        routeOverlays.append(polyline)
                        // Show each newly resolved leg immediately instead of
                        // waiting for the rest of the itinerary to finish.
                        mapView.addOverlay(polyline, level: .aboveLabels)
                    }
                }
            }
        }

        private func navigationPolyline(
            from origin: TodayMapPoint,
            to destination: TodayMapPoint,
            transportType: MKDirectionsTransportType
        ) async -> MKPolyline? {
            let request = MKDirections.Request()
            request.source = await routingMapItem(for: origin)
            request.destination = await routingMapItem(for: destination)
            request.transportType = transportType
            request.requestsAlternateRoutes = false

            let directions = MKDirections(request: request)
            activeDirections = directions
            defer {
                if activeDirections === directions {
                    activeDirections = nil
                }
            }

            do {
                return try await directions.calculate().routes.first?.polyline
            } catch {
                #if DEBUG
                let nsError = error as NSError
                print(
                    "Today route failed [\(transportType.rawValue)] "
                    + "\(origin.title) -> \(destination.title): "
                    + "\(nsError.domain) \(nsError.code) \(nsError.localizedDescription)"
                )
                #endif
                return nil
            }
        }

        /// Resolves a coordinate to Apple's canonical POI before routing. This
        /// gives MKDirections a routable entrance instead of an arbitrary pin.
        private func routingMapItem(for point: TodayMapPoint) async -> MKMapItem {
            if let cached = resolvedMapItems[point.id] {
                return cached
            }

            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = point.title
            request.region = MKCoordinateRegion(
                center: point.coordinate,
                latitudinalMeters: 20_000,
                longitudinalMeters: 20_000
            )
            request.resultTypes = [.pointOfInterest, .address]

            if let response = try? await MKLocalSearch(request: request).start(),
               let nearest = response.mapItems.min(by: { lhs, rhs in
                   lhs.location.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
                       < rhs.location.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
               }),
               nearest.location.distance(
                   from: CLLocation(latitude: point.latitude, longitude: point.longitude)
               ) < 20_000 {
                resolvedMapItems[point.id] = nearest
                return nearest
            }

            let fallback = AppleMapService.mapItem(
                for: RoutePoint(latitude: point.latitude, longitude: point.longitude),
                name: point.title
            )
            resolvedMapItems[point.id] = fallback
            return fallback
        }

        /// Native MKDirections can return directionsNotFound in regions where
        /// Apple Maps Server API still provides stepPaths. Keep the server-only
        /// credential behind the app backend and decode only its coordinates.
        private func serverNavigationPolyline(
            from origin: TodayMapPoint,
            to destination: TodayMapPoint
        ) async -> MKPolyline? {
            let request = RouteDirectionsRequest(
                origin: RoutePoint(latitude: origin.latitude, longitude: origin.longitude),
                destination: RoutePoint(latitude: destination.latitude, longitude: destination.longitude),
                mode: .driving
            )
            guard let route = try? await APIClient().routeDirections(request),
                  route.coordinates.count > 1 else {
                return nil
            }
            var coordinates = route.coordinates.map {
                CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
            }
            return MKPolyline(coordinates: &coordinates, count: coordinates.count)
        }

        fileprivate func updateCamera(
            on mapView: MKMapView,
            points: [TodayMapPoint],
            focus: CLLocationCoordinate2D?,
            requestID: Int
        ) {
            guard requestID != handledCameraRequestID, !points.isEmpty else { return }
            handledCameraRequestID = requestID

            if let focus {
                mapView.setRegion(
                    MKCoordinateRegion(
                        center: focus,
                        latitudinalMeters: points.count == 1 ? 15_000 : 800,
                        longitudinalMeters: points.count == 1 ? 15_000 : 800
                    ),
                    animated: requestID > 0
                )
                return
            }

            var mapRect = MKMapRect.null
            for point in points {
                let mapPoint = MKMapPoint(point.coordinate)
                let pointRect = MKMapRect(x: mapPoint.x, y: mapPoint.y, width: 1, height: 1)
                mapRect = mapRect.union(pointRect)
            }

            mapView.setVisibleMapRect(
                mapRect,
                edgePadding: UIEdgeInsets(top: 150, left: 60, bottom: 240, right: 60),
                animated: requestID > 0
            )
        }

        func mapView(
            _ mapView: MKMapView,
            rendererFor overlay: any MKOverlay
        ) -> MKOverlayRenderer {
            if let colorOverlay = overlay as? DarkMapTileOverlay {
                let renderer = MKTileOverlayRenderer(tileOverlay: colorOverlay)
                renderer.alpha = DarkMapTileOverlay.tintAlpha
                return renderer
            }

            if let route = overlay as? MKPolyline {
                let renderer = MKPolylineRenderer(polyline: route)
                renderer.strokeColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
                renderer.lineWidth = 4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }

            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(
            _ mapView: MKMapView,
            viewFor annotation: any MKAnnotation
        ) -> MKAnnotationView? {
            guard let annotation = annotation as? NumberedPOIAnnotation else { return nil }

            let reuseIdentifier = NumberedPOIAnnotationView.reuseIdentifier
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseIdentifier)
                as? NumberedPOIAnnotationView
                ?? NumberedPOIAnnotationView(annotation: annotation, reuseIdentifier: reuseIdentifier)
            view.annotation = annotation
            view.configure(with: annotation)
            return view
        }
    }
}

private final class NumberedPOIAnnotation: NSObject, MKAnnotation {
    let pointID: UUID
    let index: Int
    let isHighlighted: Bool
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String?

    init(point: TodayMapPoint, index: Int, isHighlighted: Bool) {
        pointID = point.id
        self.index = index
        self.isHighlighted = isHighlighted
        coordinate = point.coordinate
        title = point.title
        super.init()
    }
}

private final class NumberedPOIAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "TodayNumberedPOI"

    private let numberLabel = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        centerOffset = CGPoint(x: 0, y: -4)
        collisionMode = .circle
        displayPriority = .required
        canShowCallout = false

        layer.cornerRadius = 17
        layer.borderWidth = 0
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = .zero

        numberLabel.frame = bounds
        numberLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        numberLabel.textAlignment = .center
        numberLabel.font = .preferredFont(forTextStyle: .caption1).withTraits(.traitBold)
        addSubview(numberLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with annotation: NumberedPOIAnnotation) {
        numberLabel.text = "\(annotation.index + 1)"
        backgroundColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        numberLabel.textColor = .white
        transform = .identity
        accessibilityLabel = annotation.title
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(traits) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
