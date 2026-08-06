import MapKit
@preconcurrency import MapLibre
import SwiftUI
import UIKit

/// OpenFreeMap renders WGS-84 geometry. Apple road geometry in mainland China
/// is GCJ-02 aligned, so normalize only at the MapLibre display boundary while
/// keeping persisted POIs and Apple routing requests in their original space.
enum MapLibreCoordinateTransform {
    private static let semiMajorAxis = 6_378_245.0
    private static let eccentricitySquared = 0.00669342162296594323

    static func displayCoordinate(
        for appleCoordinate: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        guard CLLocationCoordinate2DIsValid(appleCoordinate),
              isInsideMainlandChina(appleCoordinate) else {
            return appleCoordinate
        }

        // Iteratively invert WGS-84 -> GCJ-02. Six passes converge well below
        // MapLibre's pixel precision without relying on a city-specific offset.
        var estimate = appleCoordinate
        for _ in 0..<6 {
            let projected = gcj02Coordinate(forWGS84: estimate)
            estimate.latitude -= projected.latitude - appleCoordinate.latitude
            estimate.longitude -= projected.longitude - appleCoordinate.longitude
        }
        return estimate
    }

    static func displayCoordinates(
        for appleCoordinates: [CLLocationCoordinate2D]
    ) -> [CLLocationCoordinate2D] {
        appleCoordinates.map(displayCoordinate(for:))
    }

    private static func isInsideMainlandChina(_ coordinate: CLLocationCoordinate2D) -> Bool {
        mainlandChinaBoundary.containsCoordinate(coordinate)
            || hainanBoundary.containsCoordinate(coordinate)
    }

    private static let hainanBoundary: [CLLocationCoordinate2D] = [
        .init(latitude: 18.197701, longitude: 109.47521),
        .init(latitude: 18.507682, longitude: 108.655208),
        .init(latitude: 19.367888, longitude: 108.626217),
        .init(latitude: 19.821039, longitude: 109.119056),
        .init(latitude: 20.101254, longitude: 110.211599),
        .init(latitude: 20.077534, longitude: 110.786551),
        .init(latitude: 19.69593, longitude: 111.010051),
        .init(latitude: 19.255879, longitude: 110.570647),
        .init(latitude: 18.678395, longitude: 110.339188),
        .init(latitude: 18.197701, longitude: 109.47521)
    ]

    private static let mainlandChinaBoundary: [CLLocationCoordinate2D] = [
        .init(latitude: 42.349999, longitude: 80.25999),
        .init(latitude: 42.920068, longitude: 80.18015),
        .init(latitude: 43.180362, longitude: 80.866206),
        .init(latitude: 44.917517, longitude: 79.966106),
        .init(latitude: 45.317027, longitude: 81.947071),
        .init(latitude: 45.53965, longitude: 82.458926),
        .init(latitude: 47.330031, longitude: 83.180484),
        .init(latitude: 47.000956, longitude: 85.16429),
        .init(latitude: 47.452969, longitude: 85.720484),
        .init(latitude: 48.455751, longitude: 85.768233),
        .init(latitude: 48.549182, longitude: 86.598776),
        .init(latitude: 49.214981, longitude: 87.35997),
        .init(latitude: 49.297198, longitude: 87.751264),
        .init(latitude: 48.599463, longitude: 88.013832),
        .init(latitude: 48.069082, longitude: 88.854298),
        .init(latitude: 47.693549, longitude: 90.280826),
        .init(latitude: 46.888146, longitude: 90.970809),
        .init(latitude: 45.719716, longitude: 90.585768),
        .init(latitude: 45.286073, longitude: 90.94554),
        .init(latitude: 45.115076, longitude: 92.133891),
        .init(latitude: 44.975472, longitude: 93.480734),
        .init(latitude: 44.352332, longitude: 94.688929),
        .init(latitude: 44.241331, longitude: 95.306875),
        .init(latitude: 43.319449, longitude: 95.762455),
        .init(latitude: 42.725635, longitude: 96.349396),
        .init(latitude: 42.74889, longitude: 97.451757),
        .init(latitude: 42.524691, longitude: 99.515817),
        .init(latitude: 42.663804, longitude: 100.845866),
        .init(latitude: 42.514873, longitude: 101.83304),
        .init(latitude: 41.907468, longitude: 103.312278),
        .init(latitude: 41.908347, longitude: 104.522282),
        .init(latitude: 41.59741, longitude: 104.964994),
        .init(latitude: 42.134328, longitude: 106.129316),
        .init(latitude: 42.481516, longitude: 107.744773),
        .init(latitude: 42.519446, longitude: 109.243596),
        .init(latitude: 42.871234, longitude: 110.412103),
        .init(latitude: 43.406834, longitude: 111.129682),
        .init(latitude: 43.743118, longitude: 111.829588),
        .init(latitude: 44.073176, longitude: 111.667737),
        .init(latitude: 44.457442, longitude: 111.348377),
        .init(latitude: 45.102079, longitude: 111.873306),
        .init(latitude: 45.011646, longitude: 112.436062),
        .init(latitude: 44.808893, longitude: 113.463907),
        .init(latitude: 45.339817, longitude: 114.460332),
        .init(latitude: 45.727235, longitude: 115.985096),
        .init(latitude: 46.388202, longitude: 116.717868),
        .init(latitude: 46.672733, longitude: 117.421701),
        .init(latitude: 46.805412, longitude: 118.874326),
        .init(latitude: 46.69268, longitude: 119.66327),
        .init(latitude: 47.048059, longitude: 119.772824),
        .init(latitude: 47.74706, longitude: 118.866574),
        .init(latitude: 48.06673, longitude: 118.064143),
        .init(latitude: 47.697709, longitude: 117.295507),
        .init(latitude: 47.85341, longitude: 116.308953),
        .init(latitude: 47.726545, longitude: 115.742837),
        .init(latitude: 48.135383, longitude: 115.485282),
        .init(latitude: 49.134598, longitude: 116.191802),
        .init(latitude: 49.888531, longitude: 116.678801),
        .init(latitude: 49.510983, longitude: 117.879244),
        .init(latitude: 50.142883, longitude: 119.288461),
        .init(latitude: 50.58292, longitude: 119.27939),
        .init(latitude: 51.64355, longitude: 120.18208),
        .init(latitude: 51.96411, longitude: 120.7382),
        .init(latitude: 52.516226, longitude: 120.725789),
        .init(latitude: 52.753886, longitude: 120.177089),
        .init(latitude: 53.251401, longitude: 121.003085),
        .init(latitude: 53.431726, longitude: 122.245748),
        .init(latitude: 53.4588, longitude: 123.57147),
        .init(latitude: 53.161045, longitude: 125.068211),
        .init(latitude: 52.792799, longitude: 125.946349),
        .init(latitude: 51.784255, longitude: 126.564399),
        .init(latitude: 51.353894, longitude: 126.939157),
        .init(latitude: 50.739797, longitude: 127.287456),
        .init(latitude: 49.76027, longitude: 127.6574),
        .init(latitude: 49.4406, longitude: 129.397818),
        .init(latitude: 48.729687, longitude: 130.582293),
        .init(latitude: 47.79013, longitude: 130.98726),
        .init(latitude: 47.78896, longitude: 132.50669),
        .init(latitude: 48.183442, longitude: 133.373596),
        .init(latitude: 48.47823, longitude: 135.026311),
        .init(latitude: 47.57845, longitude: 134.50081),
        .init(latitude: 47.21248, longitude: 134.11235),
        .init(latitude: 46.116927, longitude: 133.769644),
        .init(latitude: 45.14409, longitude: 133.09712),
        .init(latitude: 45.321162, longitude: 131.883454),
        .init(latitude: 44.96796, longitude: 131.02519),
        .init(latitude: 44.11152, longitude: 131.288555),
        .init(latitude: 42.92999, longitude: 131.144688),
        .init(latitude: 42.903015, longitude: 130.633866),
        .init(latitude: 42.395024, longitude: 130.64),
        .init(latitude: 42.985387, longitude: 129.994267),
        .init(latitude: 42.424982, longitude: 129.596669),
        .init(latitude: 41.994285, longitude: 128.052215),
        .init(latitude: 41.466772, longitude: 128.208433),
        .init(latitude: 41.503152, longitude: 127.343783),
        .init(latitude: 41.816569, longitude: 126.869083),
        .init(latitude: 41.107336, longitude: 126.182045),
        .init(latitude: 40.569824, longitude: 125.079942),
        .init(latitude: 39.928493, longitude: 124.265625),
        .init(latitude: 39.637788, longitude: 122.86757),
        .init(latitude: 39.170452, longitude: 122.131388),
        .init(latitude: 38.897471, longitude: 121.054554),
        .init(latitude: 39.360854, longitude: 121.585995),
        .init(latitude: 39.750261, longitude: 121.376757),
        .init(latitude: 40.422443, longitude: 122.168595),
        .init(latitude: 40.94639, longitude: 121.640359),
        .init(latitude: 40.593388, longitude: 120.768629),
        .init(latitude: 39.898056, longitude: 119.639602),
        .init(latitude: 39.252333, longitude: 119.023464),
        .init(latitude: 39.204274, longitude: 118.042749),
        .init(latitude: 38.737636, longitude: 117.532702),
        .init(latitude: 38.061476, longitude: 118.059699),
        .init(latitude: 37.897325, longitude: 118.87815),
        .init(latitude: 37.448464, longitude: 118.911636),
        .init(latitude: 37.156389, longitude: 119.702802),
        .init(latitude: 37.870428, longitude: 120.823457),
        .init(latitude: 37.481123, longitude: 121.711259),
        .init(latitude: 37.454484, longitude: 122.357937),
        .init(latitude: 36.930614, longitude: 122.519995),
        .init(latitude: 36.651329, longitude: 121.104164),
        .init(latitude: 36.11144, longitude: 120.637009),
        .init(latitude: 35.609791, longitude: 119.664562),
        .init(latitude: 34.909859, longitude: 119.151208),
        .init(latitude: 34.360332, longitude: 120.227525),
        .init(latitude: 33.376723, longitude: 120.620369),
        .init(latitude: 32.460319, longitude: 121.229014),
        .init(latitude: 31.692174, longitude: 121.908146),
        .init(latitude: 30.949352, longitude: 121.891919),
        .init(latitude: 30.676267, longitude: 121.264257),
        .init(latitude: 30.142915, longitude: 121.503519),
        .init(latitude: 29.83252, longitude: 122.092114),
        .init(latitude: 29.018022, longitude: 121.938428),
        .init(latitude: 28.225513, longitude: 121.684439),
        .init(latitude: 28.135673, longitude: 121.125661),
        .init(latitude: 27.053207, longitude: 120.395473),
        .init(latitude: 25.740781, longitude: 119.585497),
        .init(latitude: 24.547391, longitude: 118.656871),
        .init(latitude: 23.624501, longitude: 117.281606),
        .init(latitude: 22.782873, longitude: 115.890735),
        .init(latitude: 22.668074, longitude: 114.763827),
        .init(latitude: 22.22376, longitude: 114.152547),
        .init(latitude: 22.54834, longitude: 113.80678),
        .init(latitude: 22.051367, longitude: 113.241078),
        .init(latitude: 21.550494, longitude: 111.843592),
        .init(latitude: 21.397144, longitude: 110.785466),
        .init(latitude: 20.341033, longitude: 110.444039),
        .init(latitude: 20.282457, longitude: 109.889861),
        .init(latitude: 21.008227, longitude: 109.627655),
        .init(latitude: 21.395051, longitude: 109.864488),
        .init(latitude: 21.715212, longitude: 108.522813),
        .init(latitude: 21.55238, longitude: 108.05018),
        .init(latitude: 21.811899, longitude: 107.04342),
        .init(latitude: 22.218205, longitude: 106.567273),
        .init(latitude: 22.794268, longitude: 106.725403),
        .init(latitude: 22.976892, longitude: 105.811247),
        .init(latitude: 23.352063, longitude: 105.329209),
        .init(latitude: 22.81915, longitude: 104.476858),
        .init(latitude: 22.703757, longitude: 103.504515),
        .init(latitude: 22.708795, longitude: 102.706992),
        .init(latitude: 22.464753, longitude: 102.170436),
        .init(latitude: 22.318199, longitude: 101.652018),
        .init(latitude: 21.174367, longitude: 101.80312),
        .init(latitude: 21.201652, longitude: 101.270026),
        .init(latitude: 21.436573, longitude: 101.180005),
        .init(latitude: 21.849984, longitude: 101.150033),
        .init(latitude: 21.558839, longitude: 100.416538),
        .init(latitude: 21.742937, longitude: 99.983489),
        .init(latitude: 22.118314, longitude: 99.240899),
        .init(latitude: 22.949039, longitude: 99.531992),
        .init(latitude: 23.142722, longitude: 98.898749),
        .init(latitude: 24.063286, longitude: 98.660262),
        .init(latitude: 23.897405, longitude: 97.60472),
        .init(latitude: 25.083637, longitude: 97.724609),
        .init(latitude: 25.918703, longitude: 98.671838),
        .init(latitude: 26.743536, longitude: 98.712094),
        .init(latitude: 27.508812, longitude: 98.68269),
        .init(latitude: 27.747221, longitude: 98.246231),
        .init(latitude: 28.335945, longitude: 97.911988),
        .init(latitude: 28.261583, longitude: 97.327114),
        .init(latitude: 28.411031, longitude: 96.248833),
        .init(latitude: 28.83098, longitude: 96.586591),
        .init(latitude: 29.452802, longitude: 96.117679),
        .init(latitude: 29.031717, longitude: 95.404802),
        .init(latitude: 29.277438, longitude: 94.56599),
        .init(latitude: 28.640629, longitude: 93.413348),
        .init(latitude: 27.896876, longitude: 92.503119),
        .init(latitude: 27.771742, longitude: 91.696657),
        .init(latitude: 28.040614, longitude: 91.258854),
        .init(latitude: 28.064954, longitude: 90.730514),
        .init(latitude: 28.296439, longitude: 90.015829),
        .init(latitude: 28.042759, longitude: 89.47581),
        .init(latitude: 27.299316, longitude: 88.814248),
        .init(latitude: 28.086865, longitude: 88.730326),
        .init(latitude: 27.876542, longitude: 88.120441),
        .init(latitude: 27.974262, longitude: 86.954517),
        .init(latitude: 28.203576, longitude: 85.82332),
        .init(latitude: 28.642774, longitude: 85.011638),
        .init(latitude: 28.839894, longitude: 84.23458),
        .init(latitude: 29.320226, longitude: 83.898993),
        .init(latitude: 29.463732, longitude: 83.337115),
        .init(latitude: 30.115268, longitude: 82.327513),
        .init(latitude: 30.422717, longitude: 81.525804),
        .init(latitude: 30.183481, longitude: 81.111256),
        .init(latitude: 30.882715, longitude: 79.721367),
        .init(latitude: 31.515906, longitude: 78.738894),
        .init(latitude: 32.618164, longitude: 78.458446),
        .init(latitude: 32.48378, longitude: 79.176129),
        .init(latitude: 32.994395, longitude: 79.208892),
        .init(latitude: 33.506198, longitude: 78.811086),
        .init(latitude: 34.321936, longitude: 78.912269),
        .init(latitude: 35.49401, longitude: 77.837451),
        .init(latitude: 35.898403, longitude: 76.192848),
        .init(latitude: 36.666806, longitude: 75.896897),
        .init(latitude: 37.133031, longitude: 75.158028),
        .init(latitude: 37.41999, longitude: 74.980002),
        .init(latitude: 37.990007, longitude: 74.829986),
        .init(latitude: 38.378846, longitude: 74.864816),
        .init(latitude: 38.606507, longitude: 74.257514),
        .init(latitude: 38.505815, longitude: 73.928852),
        .init(latitude: 39.431237, longitude: 73.675379),
        .init(latitude: 39.660008, longitude: 73.960013),
        .init(latitude: 39.893973, longitude: 73.822244),
        .init(latitude: 40.366425, longitude: 74.776862),
        .init(latitude: 40.562072, longitude: 75.467828),
        .init(latitude: 40.427946, longitude: 76.526368),
        .init(latitude: 41.066486, longitude: 76.904484),
        .init(latitude: 41.185316, longitude: 78.187197),
        .init(latitude: 41.582243, longitude: 78.543661),
        .init(latitude: 42.123941, longitude: 80.11943),
        .init(latitude: 42.349999, longitude: 80.25999)
    ]

    private static func gcj02Coordinate(
        forWGS84 coordinate: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let latitudeRadians = latitude * .pi / 180
        let sine = sin(latitudeRadians)
        let magic = 1 - eccentricitySquared * sine * sine
        let squareRootMagic = sqrt(magic)

        var latitudeDelta = transformedLatitude(
            longitude: longitude - 105,
            latitude: latitude - 35
        )
        var longitudeDelta = transformedLongitude(
            longitude: longitude - 105,
            latitude: latitude - 35
        )
        latitudeDelta = latitudeDelta * 180
            / ((semiMajorAxis * (1 - eccentricitySquared)) / (magic * squareRootMagic) * .pi)
        longitudeDelta = longitudeDelta * 180
            / (semiMajorAxis / squareRootMagic * cos(latitudeRadians) * .pi)

        return CLLocationCoordinate2D(
            latitude: latitude + latitudeDelta,
            longitude: longitude + longitudeDelta
        )
    }

    private static func transformedLatitude(longitude x: Double, latitude y: Double) -> Double {
        var result = -100 + 2 * x + 3 * y + 0.2 * y * y
            + 0.1 * x * y + 0.2 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(y * .pi) + 40 * sin(y / 3 * .pi)) * 2 / 3
        result += (160 * sin(y / 12 * .pi) + 320 * sin(y * .pi / 30)) * 2 / 3
        return result
    }

    private static func transformedLongitude(longitude x: Double, latitude y: Double) -> Double {
        var result = 300 + x + 2 * y + 0.1 * x * x
            + 0.1 * x * y + 0.1 * sqrt(abs(x))
        result += (20 * sin(6 * x * .pi) + 20 * sin(2 * x * .pi)) * 2 / 3
        result += (20 * sin(x * .pi) + 40 * sin(x / 3 * .pi)) * 2 / 3
        result += (150 * sin(x / 12 * .pi) + 300 * sin(x / 30 * .pi)) * 2 / 3
        return result
    }
}

private extension Array where Element == CLLocationCoordinate2D {
    func containsCoordinate(_ coordinate: CLLocationCoordinate2D) -> Bool {
        guard count > 2, var previous = last else { return false }
        var isInside = false

        for current in self {
            let crossesLatitude = (current.latitude > coordinate.latitude)
                != (previous.latitude > coordinate.latitude)
            if crossesLatitude {
                let boundaryLongitude = (previous.longitude - current.longitude)
                    * (coordinate.latitude - current.latitude)
                    / (previous.latitude - current.latitude)
                    + current.longitude
                if coordinate.longitude < boundaryLongitude {
                    isInside.toggle()
                }
            }
            previous = current
        }

        return isInside
    }
}

/// Experimental vector-map renderer for the Today screen. Apple services still
/// provide POI resolution and route geometry; MapLibre only draws the basemap.
struct MapLibreTodayMapCanvas: UIViewRepresentable {
    let points: [TodayMapPoint]
    /// `nil` renders all POIs as compact number pins, for example while the
    /// action drawer is open and the POI swiper is hidden.
    let selectedIndex: Int?
    let cameraFocus: CLLocationCoordinate2D?
    let cameraRequestID: Int
    /// POI 聚焦时，顶部与底部浮层所占据的屏幕空间。
    let focusTopInset: CGFloat
    let focusBottomInset: CGFloat
    /// The card occupies the lower map area only while the POI swiper is visible.
    let overviewBottomInset: CGFloat
    let routeRefreshID: Int
    let onRouteLoadingChanged: (Bool) -> Void
    /// Reports whether the viewport is actively moving and whether a real
    /// itinerary POI (not an edge proxy) is currently visible in it.
    let onViewportStateChanged: (Bool, Bool) -> Void

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
            onRouteLoadingChanged: onRouteLoadingChanged,
            onViewportStateChanged: onViewportStateChanged
        )
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex,
            routeRefreshID: routeRefreshID,
            onRouteLoadingChanged: onRouteLoadingChanged,
            onViewportStateChanged: onViewportStateChanged
        )
        context.coordinator.updateCamera(
            on: mapView,
            points: points,
            focus: cameraFocus,
            requestID: cameraRequestID,
            focusTopInset: focusTopInset,
            focusBottomInset: focusBottomInset,
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
        private var isMapRegionChanging = false
        /// Set before our own camera animations. Those movements should not
        /// dismiss the swiper; only a direct map gesture does that.
        private var isProgrammaticCameraChange = false
        private var onViewportStateChanged: ((Bool, Bool) -> Void)?
        private var lastReportedViewportIsMoving: Bool?
        private var lastReportedHasVisiblePOI: Bool?
        /// POIs that currently need an edge proxy while the user is dragging.
        /// This is deliberately separate from `pinPlacements`: when a POI
        /// comes back onscreen, its old bubble is allowed to follow the map
        /// until the gesture ends, but it is not fully laid out again yet.
        private var draggingEdgePinIDs: Set<UUID> = []
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
            onRouteLoadingChanged: @escaping (Bool) -> Void,
            onViewportStateChanged: @escaping (Bool, Bool) -> Void
        ) {
            self.onViewportStateChanged = onViewportStateChanged
            let refreshRequested = routeRefreshID != handledRouteRefreshID
            guard points != renderedPoints || selectedIndex != renderedSelection || refreshRequested else {
                reportViewportState(on: mapView, isMoving: isMapRegionChanging)
                return
            }
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
            reportViewportState(on: mapView, isMoving: isMapRegionChanging)
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
                    displayedRouteCoordinates.append(
                        contentsOf: MapLibreCoordinateTransform.displayCoordinates(for: route.coordinates)
                    )
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
                        displayedRouteCoordinates.append(
                            contentsOf: MapLibreCoordinateTransform.displayCoordinates(for: route.coordinates)
                        )
                        annotations.forEach(mapView.addAnnotation)
                    }
                }
                if self.isMapRegionChanging {
                    self.updateEdgePinPlacementsDuringGesture(on: mapView)
                } else {
                    self.updatePinPlacements(on: mapView)
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
            let routeCoordinates = MapLibreCoordinateTransform.displayCoordinates(for: route.coordinates)
            var annotations: [MLNPolyline]
            if route.isWalking {
                annotations = dashedRouteAnnotations(for: routeCoordinates)
            } else {
                annotations = [routeAnnotation(for: routeCoordinates)]
            }

            // MapKit may snap a coordinate to the nearest routable road. Make
            // that final off-road distance explicit instead of leaving the
            // orange route visually detached from the POI pin.
            if let first = routeCoordinates.first {
                annotations.append(contentsOf: dashedConnector(
                    from: MapLibreCoordinateTransform.displayCoordinate(for: origin.coordinate),
                    to: first
                ))
            }
            if let last = routeCoordinates.last {
                annotations.append(contentsOf: dashedConnector(
                    from: last,
                    to: MapLibreCoordinateTransform.displayCoordinate(for: destination.coordinate)
                ))
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
            focusTopInset: CGFloat,
            focusBottomInset: CGFloat,
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
                if animated { isProgrammaticCameraChange = true }
                mapView.setCenter(
                    MapLibreCoordinateTransform.displayCoordinate(for: focus),
                    zoomLevel: points.count == 1 ? 12 : poiSwiperFocusZoomLevel,
                    direction: mapView.direction,
                    animated: false,
                    completionHandler: nil
                )
                // `setCenter` puts the marker at the physical viewport center.
                // Translate by the overlay imbalance so it is centered in the
                // usable area between the top controls and POI card instead.
                let verticalOffset = (focusBottomInset - focusTopInset) / 2
                guard abs(verticalOffset) > 0.5 else { return }
                let screenCenter = CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
                let adjustedCenter = mapView.convert(
                    CGPoint(x: screenCenter.x, y: screenCenter.y - verticalOffset),
                    toCoordinateFrom: mapView
                )
                mapView.setCenter(
                    adjustedCenter,
                    zoomLevel: mapView.zoomLevel,
                    direction: mapView.direction,
                    animated: animated,
                    completionHandler: nil
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
            var coordinates = points.map {
                MapLibreCoordinateTransform.displayCoordinate(for: $0.coordinate)
            }
            coordinates.append(contentsOf: displayedRouteCoordinates)
            if coordinates.count == 1, let coordinate = coordinates.first {
                if animated { isProgrammaticCameraChange = true }
                mapView.setCenter(coordinate, zoomLevel: 12, animated: animated)
                return
            }
            if animated { isProgrammaticCameraChange = true }
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
            isMapRegionChanging = false
            updatePinPlacements(on: mapView)
            reportViewportState(on: mapView, isMoving: false)
            isProgrammaticCameraChange = false
        }

        /// `regionDidChangeAnimated` only fires after a pan/zoom settles. Keep
        /// edge proxies recomputed during the gesture as well, otherwise their
        /// temporary map coordinates drift with the map until the user's
        /// finger lifts.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            isMapRegionChanging = true
            if !isProgrammaticCameraChange {
                reportViewportState(on: mapView, isMoving: true)
            }
            updateEdgePinPlacementsDuringGesture(on: mapView)
        }

        private func reportViewportState(on mapView: MLNMapView, isMoving: Bool) {
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return }
            let hasVisiblePOI = pointAnnotations.contains { annotation in
                mapView.bounds.contains(
                    mapView.convert(annotation.sourceCoordinate, toPointTo: mapView)
                )
            }
            guard lastReportedViewportIsMoving != isMoving
                    || lastReportedHasVisiblePOI != hasVisiblePOI else {
                return
            }
            lastReportedViewportIsMoving = isMoving
            lastReportedHasVisiblePOI = hasVisiblePOI
            onViewportStateChanged?(isMoving, hasVisiblePOI)
        }

        private func updatePinPlacements(on mapView: MLNMapView) {
            let placements = calculatedPinPlacements(on: mapView)
            applyPinPlacements(
                placements,
                on: mapView,
                refreshing: Set(pointAnnotations.map(\.pointID))
            )
            draggingEdgePinIDs.removeAll()
        }

        /// During a pan/zoom, only edge proxies are recomputed. On-screen
        /// pins remain at their POI coordinates until the gesture ends.
        private func updateEdgePinPlacementsDuringGesture(on mapView: MLNMapView) {
            guard !pointAnnotations.isEmpty else { return }
            guard !pinPlacements.isEmpty else {
                updatePinPlacements(on: mapView)
                return
            }

            let edgeRect = edgePinBounds(on: mapView)
            for annotation in pointAnnotations {
                let sourcePoint = mapView.convert(annotation.sourceCoordinate, toPointTo: mapView)
                if edgeRect.contains(sourcePoint) {
                    draggingEdgePinIDs.remove(annotation.pointID)

                    // Let a proxy return to the real POI as soon as the POI
                    // enters the viewport, but do not re-layout its bubble
                    // until the user releases the gesture.
                    if annotation.coordinate.latitude != annotation.sourceCoordinate.latitude
                        || annotation.coordinate.longitude != annotation.sourceCoordinate.longitude {
                        annotation.coordinate = annotation.sourceCoordinate
                    }
                } else {
                    draggingEdgePinIDs.insert(annotation.pointID)
                }
            }

            let edgeAnnotations = pointAnnotations.filter {
                draggingEdgePinIDs.contains($0.pointID)
            }
            guard !edgeAnnotations.isEmpty else { return }

            let sourcePoints = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, mapView.convert($0.sourceCoordinate, toPointTo: mapView))
            })
            let edgePlacements = arrangedEdgePinPlacements(
                annotations: edgeAnnotations,
                sourcePoints: sourcePoints,
                safeRect: edgeRect
            )
            var placements = pinPlacements
            // A previously visible edge proxy can become the farthest point
            // while panning. Remove its old placement before adding the new
            // queue so it really disappears instead of remaining at a stale
            // screen-edge coordinate.
            edgeAnnotations.forEach { placements.removeValue(forKey: $0.pointID) }
            let refreshedIDs = Set(edgeAnnotations.map(\.pointID))
            for annotation in edgeAnnotations {
                guard let edgePlacement = edgePlacements[annotation.pointID] else { continue }
                placements[annotation.pointID] = edgePlacement
            }
            applyPinPlacements(placements, on: mapView, refreshing: refreshedIDs)
        }

        private func applyPinPlacements(
            _ placements: [UUID: MapLibrePinPlacement],
            on mapView: MLNMapView,
            refreshing refreshedIDs: Set<UUID>
        ) {
            pinPlacements = placements

            for annotation in pointAnnotations {
                guard let placement = placements[annotation.pointID] else {
                    // The queue on this screen edge is full. Restore the real
                    // (off-screen) coordinate and hide any old proxy view.
                    // This keeps an evicted POI from flashing at its prior
                    // edge location until MapLibre has culled it.
                    if annotation.coordinate.latitude != annotation.sourceCoordinate.latitude
                        || annotation.coordinate.longitude != annotation.sourceCoordinate.longitude {
                        annotation.coordinate = annotation.sourceCoordinate
                    }
                    if refreshedIDs.contains(annotation.pointID) {
                        mapView.view(for: annotation)?.isHidden = true
                    }
                    continue
                }

                // MapLibre does not create an annotation view for a coordinate
                // outside its viewport. Edge pins therefore use a temporary
                // map coordinate under their screen-space number bubble while
                // retaining `sourceCoordinate` as the real itinerary POI.
                let displayedCoordinate = placement.isEdgePinned
                    && (!isMapRegionChanging || draggingEdgePinIDs.contains(annotation.pointID))
                    ? mapView.convert(placement.anchorPoint, toCoordinateFrom: mapView)
                    : annotation.sourceCoordinate
                if annotation.coordinate.latitude != displayedCoordinate.latitude
                    || annotation.coordinate.longitude != displayedCoordinate.longitude {
                    annotation.coordinate = displayedCoordinate
                }

                guard refreshedIDs.contains(annotation.pointID),
                      let view = mapView.view(for: annotation) as? MapLibreNumberedAnnotationView else {
                    continue
                }
                view.isHidden = false
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
            let edgeRect = edgePinBounds(on: mapView)
            let sourcePoints = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, mapView.convert($0.sourceCoordinate, toPointTo: mapView))
            })
            let regularPlacements: [UUID: MapLibrePinPlacement] = Dictionary(
                uniqueKeysWithValues: pointAnnotations.map { annotation in
                    let target = sourcePoints[annotation.pointID]!
                    return (
                        annotation.pointID,
                        regularPinPlacement(
                            for: annotation,
                            target: target
                        )
                    )
                }
            )
            let edgeAnnotations = pointAnnotations.filter {
                guard let point = sourcePoints[$0.pointID] else { return false }
                // Only a POI outside the actual map viewport gets an edge
                // proxy. A label being under the SwiftUI card/tab bar is not
                // an offscreen POI and must not force its pin to the edge.
                return !edgeRect.contains(point)
            }
            let edgePlacements = arrangedEdgePinPlacements(
                annotations: edgeAnnotations,
                sourcePoints: sourcePoints,
                safeRect: edgeRect
            )

            var result: [UUID: MapLibrePinPlacement] = [:]
            for annotation in pointAnnotations {
                if let edgePlacement = edgePlacements[annotation.pointID] {
                    result[annotation.pointID] = edgePlacement
                } else if !edgeAnnotations.contains(where: { $0.pointID == annotation.pointID }) {
                    result[annotation.pointID] = regularPlacements[annotation.pointID]
                }
            }
            return result
        }

        /// The outer bounds for an edge bubble. The 3pt inset is measured
        /// from the map/screen edge; the arrangement helper then accounts for
        /// the bubble radius (and the highlighted category bubble) so the
        /// rendered white pin never clips.
        private func edgePinBounds(on mapView: MLNMapView) -> CGRect {
            mapView.bounds.insetBy(dx: 3, dy: 3)
        }

        /// On-screen pins are centered directly on their POI coordinate.
        private func regularPinPlacement(
            for annotation: MapLibreNumberedAnnotation,
            on mapView: MLNMapView
        ) -> MapLibrePinPlacement {
            regularPinPlacement(
                for: annotation,
                target: mapView.convert(annotation.sourceCoordinate, toPointTo: mapView)
            )
        }

        private func regularPinPlacement(
            for annotation: MapLibreNumberedAnnotation,
            target: CGPoint
        ) -> MapLibrePinPlacement {
            return MapLibrePinPlacement.regular(
                target: target,
                isHighlighted: annotation.isHighlighted
            )
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
            /// Screen-space distance from the POI to the edge queue. When an
            /// edge is full, retain nearby POIs and evict the farthest ones.
            let distanceToEdge: CGFloat
        }

        /// One visible edge pill may represent multiple POIs that project to
        /// nearly the same point on the screen boundary.
        private struct EdgePinGroupCandidate {
            let annotations: [MapLibreNumberedAnnotation]
            let edge: EdgePinCandidate.Edge
            let desiredCenter: CGPoint
            let axisMinimum: CGFloat
            let axisMaximum: CGFloat
            let extentBefore: CGFloat
            let extentAfter: CGFloat
            let distanceToEdge: CGFloat
            let labelText: String
            let labelSize: CGSize

            var displayAnnotation: MapLibreNumberedAnnotation {
                annotations.min {
                    $0.index < $1.index
                } ?? annotations[0]
            }
        }

        /// Projects each unavailable POI onto the usable map boundary, then
        /// spaces pins that share an edge so their white bubbles do not stack.
        private func arrangedEdgePinPlacements(
            annotations: [MapLibreNumberedAnnotation],
            sourcePoints: [UUID: CGPoint],
            safeRect: CGRect
        ) -> [UUID: MapLibrePinPlacement] {
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
                        extentAfter: MapLibrePinPlacement.bubbleSize / 2,
                        distanceToEdge: hypot(source.x - projection.point.x, source.y - projection.point.y)
                    )
                }
                return EdgePinCandidate(
                    annotation: annotation,
                    edge: projection.edge,
                    desiredCenter: projection.point,
                    axisMinimum: centerRect.minY,
                    axisMaximum: centerRect.maxY,
                    extentBefore: topExtent,
                    extentAfter: bottomExtent,
                    distanceToEdge: hypot(source.x - projection.point.x, source.y - projection.point.y)
                )
            }

            var result: [UUID: MapLibrePinPlacement] = [:]
            for edge in [EdgePinCandidate.Edge.top, .right, .bottom, .left] {
                let edgeCandidates = candidates
                    .filter { $0.edge == edge }
                    .sorted {
                        let lhs = edge.isHorizontal ? $0.desiredCenter.x : $0.desiredCenter.y
                        let rhs = edge.isHorizontal ? $1.desiredCenter.x : $1.desiredCenter.y
                        return lhs == rhs ? $0.annotation.index < $1.annotation.index : lhs < rhs
                    }
                guard !edgeCandidates.isEmpty else { continue }
                // Keep one queue on the physical edge. Adding inward lanes
                // made the top of the map increasingly crowded; instead,
                // retain the nearest POIs and hide the farthest overflow.
                let visible = edgeQueueCandidates(
                    from: mergedEdgeCandidates(edgeCandidates, horizontal: edge.isHorizontal)
                )
                let positions = spacedEdgePositions(for: visible, horizontal: edge.isHorizontal)
                for (candidate, position) in zip(visible, positions) {
                    var center = candidate.desiredCenter
                    if edge.isHorizontal {
                        center.x = position
                    } else {
                        center.y = position
                        // A merged pill is wider than the original round
                        // number pin. Anchor its nearest side to the physical
                        // map edge, so the extra width always grows inward.
                        switch edge {
                        case .left:
                            center.x = safeRect.minX + candidate.labelSize.width / 2
                        case .right:
                            center.x = safeRect.maxX - candidate.labelSize.width / 2
                        case .top, .bottom:
                            break
                        }
                    }
                    let annotation = candidate.displayAnnotation
                    result[annotation.pointID] = edgePinPlacement(
                        for: annotation,
                        numberCenter: center,
                        labelText: candidate.labelText,
                        labelSize: candidate.labelSize
                    )
                }
            }
            return result
        }

        /// Neighboring off-screen POIs are visually one cluster, not several
        /// competing bubbles. Do not merge the selected POI: it keeps its
        /// category icon and enlarged treatment while the swiper is visible.
        private func mergedEdgeCandidates(
            _ candidates: [EdgePinCandidate],
            horizontal: Bool
        ) -> [EdgePinGroupCandidate] {
            let mergeDistance = MapLibrePinPlacement.bubbleSize + 10
            var clusters: [[EdgePinCandidate]] = []

            for candidate in candidates {
                let axis = horizontal ? candidate.desiredCenter.x : candidate.desiredCenter.y
                guard let last = clusters.indices.last,
                      let previous = clusters[last].last else {
                    clusters.append([candidate])
                    continue
                }
                let previousAxis = horizontal ? previous.desiredCenter.x : previous.desiredCenter.y
                let canMerge = !candidate.annotation.isHighlighted
                    && !previous.annotation.isHighlighted
                    && axis - previousAxis <= mergeDistance
                if canMerge {
                    clusters[last].append(candidate)
                } else {
                    clusters.append([candidate])
                }
            }

            return clusters.map { cluster in
                let first = cluster[0]
                let indexes = cluster.map { String($0.annotation.index + 1) }
                let labelText = indexes.joined(separator: ".")
                let labelSize = MapLibrePinPlacement.edgeLabelSize(for: labelText)
                let axis = cluster.map { horizontal ? $0.desiredCenter.x : $0.desiredCenter.y }
                    .sorted()
                let medianAxis = axis[axis.count / 2]
                var desiredCenter = first.desiredCenter
                if horizontal {
                    desiredCenter.x = medianAxis
                } else {
                    desiredCenter.y = medianAxis
                }
                let annotations = cluster.map(\.annotation)
                let isHighlighted = annotations.contains(where: \.isHighlighted)
                let extentBefore = horizontal
                    ? labelSize.width / 2
                    : (isHighlighted ? MapLibrePinPlacement.highlightedTopExtent : labelSize.height / 2)
                let extentAfter = horizontal ? labelSize.width / 2 : labelSize.height / 2
                // For top/bottom pins, the pill grows along the edge's queue
                // axis. Replace the old circular-pin bounds with its actual
                // width before arranging and clamping that queue.
                let axisMinimum = horizontal
                    ? first.axisMinimum - MapLibrePinPlacement.bubbleSize / 2 + labelSize.width / 2
                    : first.axisMinimum
                let axisMaximum = horizontal
                    ? first.axisMaximum + MapLibrePinPlacement.bubbleSize / 2 - labelSize.width / 2
                    : first.axisMaximum
                return EdgePinGroupCandidate(
                    annotations: annotations,
                    edge: first.edge,
                    desiredCenter: desiredCenter,
                    axisMinimum: axisMinimum,
                    axisMaximum: axisMaximum,
                    extentBefore: extentBefore,
                    extentAfter: extentAfter,
                    distanceToEdge: cluster.map(\.distanceToEdge).min() ?? 0,
                    labelText: labelText,
                    labelSize: labelSize
                )
            }
        }

        /// Fits as many pins as one edge can hold without overlap. Candidates
        /// are chosen by their distance outside the viewport, then returned in
        /// map order so their final positions still follow the edge naturally.
        private func edgeQueueCandidates(
            from candidates: [EdgePinGroupCandidate]
        ) -> [EdgePinGroupCandidate] {
            guard let first = candidates.first else { return [] }
            let availableLength = first.axisMaximum - first.axisMinimum
            let gap: CGFloat = 6
            var visible: [EdgePinGroupCandidate] = []
            var occupied: CGFloat = 0

            for candidate in candidates.sorted(by: {
                $0.distanceToEdge == $1.distanceToEdge
                    ? $0.displayAnnotation.index < $1.displayAnnotation.index
                    : $0.distanceToEdge < $1.distanceToEdge
            }) {
                let length = candidate.extentBefore + candidate.extentAfter
                let proposed = visible.isEmpty
                    ? length
                    : occupied + gap + length
                guard proposed <= availableLength else { continue }
                visible.append(candidate)
                occupied = proposed
            }
            return visible.sorted {
                let lhs = first.edge.isHorizontal ? $0.desiredCenter.x : $0.desiredCenter.y
                let rhs = first.edge.isHorizontal ? $1.desiredCenter.x : $1.desiredCenter.y
                return lhs == rhs ? $0.displayAnnotation.index < $1.displayAnnotation.index : lhs < rhs
            }
        }

        private func spacedEdgePositions(
            for candidates: [EdgePinGroupCandidate],
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
            numberCenter: CGPoint,
            labelText: String? = nil,
            labelSize: CGSize = CGSize(
                width: MapLibrePinPlacement.bubbleSize,
                height: MapLibrePinPlacement.bubbleSize
            )
        ) -> MapLibrePinPlacement {
            return MapLibrePinPlacement(
                anchorPoint: numberCenter,
                numberCenter: numberCenter,
                isHighlighted: annotation.isHighlighted,
                isEdgePinned: true,
                labelText: labelText,
                labelSize: labelSize
            )
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
        sourceCoordinate = MapLibreCoordinateTransform.displayCoordinate(for: point.coordinate)
        super.init()
        coordinate = sourceCoordinate
        title = point.title
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private struct MapLibrePinPlacement {
    static let bubbleSize: CGFloat = 32
    static let categoryGap: CGFloat = 2
    static let highlightedTopExtent = bubbleSize * 1.5 + categoryGap

    /// Screen point backed by the annotation's temporary map coordinate. For
    /// regular pins this is the POI itself; for edge pins it is the white
    /// number bubble, which keeps MapLibre from culling an off-screen POI.
    let anchorPoint: CGPoint
    let numberCenter: CGPoint
    let isHighlighted: Bool
    let isEdgePinned: Bool
    /// `nil` for a standard single-number pin. Edge clusters supply a joined
    /// value such as "2.4.9" and widen only that one pill.
    let labelText: String?
    let labelSize: CGSize

    var labelRect: CGRect {
        Self.labelRect(
            numberCenter: numberCenter,
            labelSize: labelSize,
            isHighlighted: isHighlighted
        )
    }

    static func labelRect(
        numberCenter: CGPoint,
        labelSize: CGSize,
        isHighlighted: Bool
    ) -> CGRect {
        let numberRect = CGRect(
            x: numberCenter.x - labelSize.width / 2,
            y: numberCenter.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        guard isHighlighted else { return numberRect }
        let categoryRect = numberRect.offsetBy(
            dx: 0,
            dy: -(Self.bubbleSize + Self.categoryGap)
        )
        return numberRect.union(categoryRect)
    }

    static func edgeLabelSize(for text: String) -> CGSize {
        let font = UIFont.systemFont(ofSize: 16, weight: .medium)
        let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(
            width: max(bubbleSize, measuredWidth + 20),
            height: bubbleSize
        )
    }

    static func regular(
        target: CGPoint,
        isHighlighted: Bool
    ) -> Self {
        return Self(
            anchorPoint: target,
            numberCenter: target,
            isHighlighted: isHighlighted,
            isEdgePinned: false,
            labelText: nil,
            labelSize: CGSize(width: bubbleSize, height: bubbleSize)
        )
    }
}

private final class MapLibreNumberedAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "MapLibreTodayNumberedPOI"

    private let numberBackground = UIView()
    private let categoryBackground = UIView()
    private let numberLabel = UILabel()
    private let categoryImageView = UIImageView()
    private let gooeyBackgroundLayer = CAShapeLayer()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        backgroundColor = .clear

        numberBackground.backgroundColor = .white
        categoryBackground.backgroundColor = .white
        numberBackground.layer.cornerRadius = MapLibrePinPlacement.bubbleSize / 2
        categoryBackground.layer.cornerRadius = MapLibrePinPlacement.bubbleSize / 2

        gooeyBackgroundLayer.fillColor = UIColor.white.cgColor
        gooeyBackgroundLayer.strokeColor = UIColor(
            red: 1,
            green: 110 / 255,
            blue: 0,
            alpha: 1
        ).cgColor
        gooeyBackgroundLayer.lineWidth = 2
        gooeyBackgroundLayer.lineJoin = .round
        layer.insertSublayer(gooeyBackgroundLayer, at: 1)

        numberLabel.textAlignment = .center
        numberLabel.textColor = .black
        numberLabel.font = .systemFont(ofSize: 16, weight: .medium)
        categoryImageView.tintColor = .black
        categoryImageView.contentMode = .scaleAspectFit

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
        let labelSize = placement.labelSize
        let padding: CGFloat = 4
        var screenFrame = placement.labelRect
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
            x: localNumberCenter.x - labelSize.width / 2,
            y: localNumberCenter.y - labelSize.height / 2,
            width: labelSize.width,
            height: labelSize.height
        )
        numberBackground.frame = numberFrame
        numberBackground.layer.cornerRadius = labelSize.height / 2
        numberLabel.frame = numberFrame
        numberLabel.text = placement.labelText ?? String(annotation.index + 1)

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
