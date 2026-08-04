import MapKit
@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// Experimental vector-map renderer for the Today screen. Apple services still
/// provide POI resolution and route geometry; MapLibre only draws the basemap.
struct MapLibreTodayMapCanvas: UIViewRepresentable {
    let points: [TodayMapPoint]
    let selectedIndex: Int
    let cameraFocus: CLLocationCoordinate2D?
    let cameraRequestID: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MLNMapView {
        let styleURL = Bundle.main.url(forResource: "TodayMapStyle", withExtension: "json")
        let mapView = MLNMapView(frame: .zero, styleURL: styleURL)
        mapView.delegate = context.coordinator
        mapView.backgroundColor = UIColor(red: 25 / 255, green: 25 / 255, blue: 25 / 255, alpha: 1)
        mapView.minimumZoomLevel = 3
        mapView.maximumZoomLevel = 19
        mapView.allowsTilting = false
        mapView.allowsRotating = false
        mapView.showsUserLocation = false
        mapView.showsLogoView = false
        mapView.attributionButtonPosition = .bottomLeft
        mapView.attributionButtonMargins = CGPoint(x: 12, y: 136)

        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex
        )
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
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
    final class Coordinator: NSObject, @MainActor MLNMapViewDelegate {
        private var pointAnnotations: [MapLibreNumberedAnnotation] = []
        private var routeAnnotations: [MLNPolyline] = []
        private var routeTask: Task<Void, Never>?
        private var activeDirections: MKDirections?
        private var routeGeneration = 0
        private var resolvedMapItems: [UUID: MKMapItem] = [:]
        private var renderedPoints: [TodayMapPoint] = []
        private var renderedSelection = -1
        private var handledCameraRequestID = -1

        fileprivate func updateContent(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            selectedIndex: Int
        ) {
            guard points != renderedPoints || selectedIndex != renderedSelection else { return }
            let pointsChanged = points != renderedPoints

            if !pointAnnotations.isEmpty {
                mapView.removeAnnotations(pointAnnotations)
            }
            pointAnnotations = points.enumerated().map { index, point in
                MapLibreNumberedAnnotation(
                    point: point,
                    index: index,
                    isHighlighted: index == selectedIndex
                )
            }
            mapView.addAnnotations(pointAnnotations)

            if pointsChanged {
                rebuildNavigationRoute(on: mapView, points: points)
            }

            renderedPoints = points
            renderedSelection = selectedIndex
        }

        private func rebuildNavigationRoute(on mapView: MLNMapView, points: [TodayMapPoint]) {
            routeTask?.cancel()
            activeDirections?.cancel()
            routeGeneration &+= 1
            let generation = routeGeneration

            if !routeAnnotations.isEmpty {
                mapView.removeAnnotations(routeAnnotations)
                routeAnnotations.removeAll()
            }
            guard points.count > 1 else { return }

            let routeCache = TodayRouteGeometryCache.shared
            var missingLegs: [(origin: TodayMapPoint, destination: TodayMapPoint)] = []
            for (origin, destination) in zip(points, points.dropFirst()) {
                if let coordinates = routeCache.coordinates(from: origin, to: destination) {
                    routeAnnotations.append(routeAnnotation(for: coordinates))
                } else {
                    missingLegs.append((origin, destination))
                }
            }
            if !routeAnnotations.isEmpty {
                mapView.addAnnotations(routeAnnotations)
            }
            guard !missingLegs.isEmpty else { return }

            routeTask = Task { [weak self, weak mapView] in
                guard let self, let mapView else { return }

                for (origin, destination) in missingLegs {
                    guard !Task.isCancelled, generation == routeGeneration else { return }
                    var coordinates = await navigationCoordinates(
                        from: origin,
                        to: destination,
                        transportType: .automobile
                    )
                    if coordinates == nil {
                        coordinates = await navigationCoordinates(
                            from: origin,
                            to: destination,
                            transportType: .walking
                        )
                    }
                    if coordinates == nil {
                        coordinates = await serverNavigationCoordinates(from: origin, to: destination)
                    }
                    if let coordinates, coordinates.count > 1 {
                        routeCache.store(coordinates, from: origin, to: destination)
                        let annotation = routeAnnotation(for: coordinates)
                        routeAnnotations.append(annotation)
                        mapView.addAnnotation(annotation)
                    }
                }
            }
        }

        private func routeAnnotation(for routeCoordinates: [CLLocationCoordinate2D]) -> MLNPolyline {
            var coordinates = routeCoordinates
            return MLNPolyline(coordinates: &coordinates, count: UInt(coordinates.count))
        }

        private func navigationCoordinates(
            from origin: TodayMapPoint,
            to destination: TodayMapPoint,
            transportType: MKDirectionsTransportType
        ) async -> [CLLocationCoordinate2D]? {
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
            requestID: Int
        ) {
            guard requestID != handledCameraRequestID, !points.isEmpty else { return }
            handledCameraRequestID = requestID
            let animated = requestID > 0

            if let focus {
                mapView.setCenter(focus, zoomLevel: points.count == 1 ? 12 : 16, animated: animated)
                return
            }

            var coordinates = points.map(\.coordinate)
            if coordinates.count == 1, let coordinate = coordinates.first {
                mapView.setCenter(coordinate, zoomLevel: 12, animated: animated)
                return
            }
            mapView.setVisibleCoordinates(
                &coordinates,
                count: UInt(coordinates.count),
                edgePadding: UIEdgeInsets(top: 150, left: 60, bottom: 240, right: 60),
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

    init(point: TodayMapPoint, index: Int, isHighlighted: Bool) {
        pointID = point.id
        self.index = index
        self.isHighlighted = isHighlighted
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

    private let numberLabel = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        centerOffset = CGVector(dx: 0, dy: -4)
        scalesWithViewingDistance = false

        layer.cornerRadius = 17
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.2
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)

        numberLabel.frame = bounds
        numberLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        numberLabel.textAlignment = .center
        numberLabel.textColor = .white
        numberLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        addSubview(numberLabel)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with annotation: MapLibreNumberedAnnotation) {
        backgroundColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        numberLabel.text = String(annotation.index + 1)
        transform = annotation.isHighlighted
            ? CGAffineTransform(scaleX: 1.08, y: 1.08)
            : .identity
    }
}
