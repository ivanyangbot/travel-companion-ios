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

enum MapLibreEdgePinEdge: Int, CaseIterable {
    case top
    case right
    case bottom
    case left

    var isHorizontal: Bool { self == .top || self == .bottom }
}

enum MapLibreEdgePinPointingCorner: Hashable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

struct MapLibreEdgePinGroupMember: Equatable {
    let id: UUID
    /// Stable relative label order inherited from the current edge queue.
    let displayOrder: Int
    let edge: MapLibreEdgePinEdge
    /// Direction from the physical screen center to the original POI point.
    let directionAngle: CGFloat
    let projectedPosition: CGFloat
    let isHighlighted: Bool
}

/// Pure complete-link clustering used by both the renderer and geometry tests.
/// Pairwise maxima prevent the classic 0°/20°/40° chain from becoming one
/// group merely because every neighboring pair is close.
enum MapLibreEdgePinGrouping {
    static let mergeAngle = 24 * CGFloat.pi / 180
    static let splitAngle = 30 * CGFloat.pi / 180
    static let mergeProjectedSpan: CGFloat = 42
    static let splitProjectedSpan: CGFloat = 56

    static func circularAngularDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let fullTurn = 2 * CGFloat.pi
        var delta = abs(lhs - rhs).truncatingRemainder(dividingBy: fullTurn)
        if delta > CGFloat.pi { delta = fullTurn - delta }
        return delta
    }

    static func maximumAngularSpan(_ members: [MapLibreEdgePinGroupMember]) -> CGFloat {
        guard members.count > 1 else { return 0 }
        var maximum: CGFloat = 0
        for first in members.indices {
            for second in members.indices where second > first {
                maximum = max(
                    maximum,
                    circularAngularDistance(
                        members[first].directionAngle,
                        members[second].directionAngle
                    )
                )
            }
        }
        return maximum
    }

    static func maximumProjectedSpan(_ members: [MapLibreEdgePinGroupMember]) -> CGFloat {
        guard let minimum = members.map(\.projectedPosition).min(),
              let maximum = members.map(\.projectedPosition).max() else {
            return 0
        }
        return maximum - minimum
    }

    static func groups(
        members input: [MapLibreEdgePinGroupMember],
        previousGroups: [[UUID]]
    ) -> [[MapLibreEdgePinGroupMember]] {
        var seen: Set<UUID> = []
        let members = input.filter { seen.insert($0.id).inserted }
        let previousMembership: [UUID: Set<UUID>] = previousGroups.reduce(into: [:]) {
            result, group in
            let set = Set(group)
            guard set.count > 1 else { return }
            for id in set { result[id] = set }
        }

        var clusters = members.map { [$0] }
        while clusters.count > 1 {
            var best: (first: Int, second: Int, score: CGFloat)?
            for first in clusters.indices {
                for second in clusters.indices where second > first {
                    let combined = clusters[first] + clusters[second]
                    guard let edge = combined.first?.edge,
                          combined.allSatisfy({ $0.edge == edge && !$0.isHighlighted }) else {
                        continue
                    }

                    let priorSet = previousMembership[combined[0].id]
                    let staysInPreviousGroup = priorSet != nil
                        && combined.allSatisfy { previousMembership[$0.id] == priorSet }
                    let angleLimit = staysInPreviousGroup ? splitAngle : mergeAngle
                    let spanLimit = staysInPreviousGroup
                        ? splitProjectedSpan
                        : mergeProjectedSpan
                    let angle = maximumAngularSpan(combined)
                    let span = maximumProjectedSpan(combined)
                    guard angle <= angleLimit, span <= spanLimit else { continue }

                    let score = max(angle / max(angleLimit, 0.0001), span / max(spanLimit, 0.0001))
                    if best == nil || score < best!.score - 0.0001
                        || (abs(score - best!.score) <= 0.0001
                            && deterministicOrder(clusters[first])
                                < deterministicOrder(clusters[best!.first])) {
                        best = (first, second, score)
                    }
                }
            }
            guard let best else { break }
            clusters[best.first].append(contentsOf: clusters[best.second])
            clusters.remove(at: best.second)
        }

        return clusters
            .map { $0.sorted { $0.displayOrder < $1.displayOrder } }
            .sorted {
                guard let lhs = $0.first, let rhs = $1.first else { return !$0.isEmpty }
                if lhs.edge.rawValue != rhs.edge.rawValue {
                    return lhs.edge.rawValue < rhs.edge.rawValue
                }
                let lhsPosition = $0.map(\.projectedPosition).min() ?? 0
                let rhsPosition = $1.map(\.projectedPosition).min() ?? 0
                if lhsPosition != rhsPosition { return lhsPosition < rhsPosition }
                return deterministicOrder($0) < deterministicOrder($1)
            }
    }

    private static func deterministicOrder(_ members: [MapLibreEdgePinGroupMember]) -> Int {
        members.map(\.displayOrder).min() ?? .max
    }
}

enum MapLibrePinLabelGeometry {
    static let bubbleSize: CGFloat = 32

    static func size(for text: String) -> CGSize {
        let font = UIFont.systemFont(ofSize: 16, weight: .medium)
        let measuredWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return CGSize(width: max(bubbleSize, measuredWidth + 20), height: bubbleSize)
    }

    /// Preserve every represented member while keeping the visible edge pill
    /// inside the available width. Large groups use a stable prefix plus a
    /// `+N` remainder instead of producing an unprojectable, disappearing pin.
    static func fittingText(displayOrders: [Int], maximumWidth: CGFloat) -> String {
        let labels = displayOrders.map { String($0 + 1) }
        guard !labels.isEmpty else { return "" }
        let fullText = labels.joined(separator: ".")
        guard size(for: fullText).width > maximumWidth else { return fullText }

        if labels.count > 1 {
            for prefixCount in stride(from: labels.count - 1, through: 1, by: -1) {
                let candidate = labels.prefix(prefixCount).joined(separator: ".")
                    + ".+\(labels.count - prefixCount)"
                if size(for: candidate).width <= maximumWidth { return candidate }
            }
        }
        return "+\(labels.count)"
    }
}

struct MapLibreRegularPinMember: Equatable {
    let id: UUID
    let displayOrder: Int
    let numberCenter: CGPoint
    let renderedFrame: CGRect
    let isHighlighted: Bool
}

struct MapLibreRegularPinCluster: Equatable {
    let members: [MapLibreRegularPinMember]
    let numberCenter: CGPoint
    let labelText: String?
    let labelSize: CGSize
    let renderedFrame: CGRect

    var representativeID: UUID { members[0].id }
    var isHighlighted: Bool { members.contains(where: \.isHighlighted) }
}

/// Stable collision closure for ordinary on-map pins. Original member-frame
/// overlap is transitive, and every newly widened numeric pill is checked
/// again so it can absorb another nearby cluster.
enum MapLibreRegularPinGrouping {
    static func clusters(
        members input: [MapLibreRegularPinMember]
    ) -> [MapLibreRegularPinCluster] {
        var seen: Set<UUID> = []
        var groups = input
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayOrder < $1.displayOrder }
            .map { [$0] }

        while groups.count > 1 {
            var pairToMerge: (Int, Int)?
            for first in groups.indices {
                for second in groups.indices where second > first {
                    guard groupsOverlap(groups[first], groups[second]) else {
                        continue
                    }
                    pairToMerge = (first, second)
                    break
                }
                if pairToMerge != nil { break }
            }
            guard let pairToMerge else { break }
            groups[pairToMerge.0].append(contentsOf: groups[pairToMerge.1])
            groups[pairToMerge.0].sort { $0.displayOrder < $1.displayOrder }
            groups.remove(at: pairToMerge.1)
            groups.sort {
                ($0.first?.displayOrder ?? .max) < ($1.first?.displayOrder ?? .max)
            }
        }
        return groups.map(cluster(for:))
    }

    private static func groupsOverlap(
        _ first: [MapLibreRegularPinMember],
        _ second: [MapLibreRegularPinMember]
    ) -> Bool {
        let originalOverlap = first.contains { lhs in
            second.contains { rhs in strictlyOverlaps(lhs.renderedFrame, rhs.renderedFrame) }
        }
        return originalOverlap
            || strictlyOverlaps(cluster(for: first).renderedFrame, cluster(for: second).renderedFrame)
    }

    private static func cluster(
        for unsortedMembers: [MapLibreRegularPinMember]
    ) -> MapLibreRegularPinCluster {
        let members = unsortedMembers.sorted { $0.displayOrder < $1.displayOrder }
        let center = CGPoint(
            x: (members.map(\.numberCenter.x).min()! + members.map(\.numberCenter.x).max()!) / 2,
            y: (members.map(\.numberCenter.y).min()! + members.map(\.numberCenter.y).max()!) / 2
        )
        let labelText = members.count > 1
            ? members.map { String($0.displayOrder + 1) }.joined(separator: ".")
            : nil
        let labelSize = labelText.map(MapLibrePinLabelGeometry.size(for:))
            ?? CGSize(
                width: members[0].renderedFrame.width,
                height: MapLibrePinLabelGeometry.bubbleSize
            )
        let renderedFrame: CGRect
        if members.count == 1 {
            renderedFrame = members[0].renderedFrame
        } else {
            renderedFrame = MapLibreEdgePinGeometry.renderedOuterFrame(
                numberCenter: center,
                labelSize: labelSize,
                // A merged pill keeps the orange selected border but does not
                // render the separate category bubble above it.
                topExtent: labelSize.height / 2,
                bottomExtent: labelSize.height / 2
            )
        }
        return MapLibreRegularPinCluster(
            members: members,
            numberCenter: center,
            labelText: labelText,
            labelSize: labelSize,
            renderedFrame: renderedFrame
        )
    }

    private static func strictlyOverlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

enum MapLibreEdgePinGeometry {
    static let horizontalMargin: CGFloat = 20
    static let topMargin: CGFloat = 160
    static let timelineGap: CGFloat = 20
    /// The floating bottom navigation is 60pt tall and 32pt above the screen.
    static let bottomTabBarTopInset: CGFloat = 92

    /// Returns the complete-rendered-frame safe rect in the same coordinate
    /// space as `screenBounds`. `.null` means even a compact pin cannot fit.
    static func safeOuterRect(
        screenBounds: CGRect,
        timelineTop: CGFloat?,
        minimumSize: CGSize = CGSize(width: 32, height: 32)
    ) -> CGRect {
        let minimumX = screenBounds.minX + horizontalMargin
        let maximumX = screenBounds.maxX - horizontalMargin
        let minimumY = screenBounds.minY + topMargin
        let currentObstructionTop = timelineTop
            ?? (screenBounds.maxY - bottomTabBarTopInset)
        let measuredBottom = currentObstructionTop - timelineGap
        let maximumY = min(screenBounds.maxY - timelineGap, measuredBottom)
        guard maximumX - minimumX >= minimumSize.width,
              maximumY - minimumY >= minimumSize.height else {
            return .null
        }
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    static func nearlyEqual(_ lhs: CGFloat?, _ rhs: CGFloat?, accuracy: CGFloat = 0.5) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return abs(lhs - rhs) <= accuracy
        default:
            return false
        }
    }

    static func renderedOuterFrame(
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat
    ) -> CGRect {
        CGRect(
            x: numberCenter.x - labelSize.width / 2,
            y: numberCenter.y - topExtent,
            width: labelSize.width,
            height: topExtent + bottomExtent
        )
    }

    static func containsRenderedOuterFrame(
        safeRect: CGRect,
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        let frame = renderedOuterFrame(
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        )
        return frame.minX >= safeRect.minX - tolerance
            && frame.maxX <= safeRect.maxX + tolerance
            && frame.minY >= safeRect.minY - tolerance
            && frame.maxY <= safeRect.maxY + tolerance
    }

    struct BoundaryProjection: Equatable {
        let point: CGPoint
        let edge: MapLibreEdgePinEdge
    }

    /// The landing safe rect is also the attraction trigger. A POI remains a
    /// regular pin only while its complete rendered frame fits; the POI center
    /// itself may still be well inside both the map viewport and `safeRect`.
    static func overflowProjection(
        safeRect: CGRect,
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat,
        rayOrigin: CGPoint? = nil
    ) -> BoundaryProjection? {
        guard !safeRect.isNull,
              safeRect.width > 0,
              safeRect.height > 0 else {
            return nil
        }
        let outerFrame = renderedOuterFrame(
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        )
        guard !containsRenderedOuterFrame(
            safeRect: safeRect,
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        ) else {
            return nil
        }

        let projection = boundaryProjection(
            safeRect: safeRect,
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent,
            rayOrigin: rayOrigin
        ) ?? dominantOverflowProjection(
            outerFrame: outerFrame,
            safeRect: safeRect,
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        )
        guard let projection else { return nil }
        let centerRect = centerSafeRect(
            safeRect: safeRect,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        )
        guard !centerRect.isNull else { return nil }
        return snapHorizontalProjectionToEndpoint(
            projection,
            centerRect: centerRect,
            sourcePoint: numberCenter,
            screenCenter: rayOrigin ?? CGPoint(x: centerRect.midX, y: centerRect.midY)
        )
    }

    /// Intersects the ray from the physical screen center through the source
    /// point with the center-safe boundary for this pin's actual rendered
    /// size. Unlike `overflowProjection`, this also projects a source whose
    /// own compact frame fits, which is needed after a widened regular cluster
    /// is promoted into edge layout.
    static func boundaryProjection(
        safeRect: CGRect,
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat,
        rayOrigin: CGPoint
    ) -> BoundaryProjection? {
        guard !safeRect.isNull,
              safeRect.width > 0,
              safeRect.height > 0 else {
            return nil
        }
        let centerRect = CGRect(
            x: safeRect.minX + labelSize.width / 2,
            y: safeRect.minY + topExtent,
            width: safeRect.width - labelSize.width,
            height: safeRect.height - topExtent - bottomExtent
        )
        guard centerRect.width >= 0, centerRect.height >= 0 else { return nil }

        let dx = numberCenter.x - rayOrigin.x
        let dy = numberCenter.y - rayOrigin.y
        guard abs(dx) > 0.000_001 || abs(dy) > 0.000_001 else { return nil }

        let tolerance: CGFloat = 0.001
        var intersections: [(scale: CGFloat, edge: MapLibreEdgePinEdge, point: CGPoint)] = []
        func appendVertical(x: CGFloat, edge: MapLibreEdgePinEdge) {
            guard abs(dx) > 0.000_001 else { return }
            let scale = (x - rayOrigin.x) / dx
            let y = rayOrigin.y + dy * scale
            guard scale >= 0,
                  y >= centerRect.minY - tolerance,
                  y <= centerRect.maxY + tolerance else { return }
            intersections.append((scale, edge, CGPoint(x: x, y: y)))
        }
        func appendHorizontal(y: CGFloat, edge: MapLibreEdgePinEdge) {
            guard abs(dy) > 0.000_001 else { return }
            let scale = (y - rayOrigin.y) / dy
            let x = rayOrigin.x + dx * scale
            guard scale >= 0,
                  x >= centerRect.minX - tolerance,
                  x <= centerRect.maxX + tolerance else { return }
            intersections.append((scale, edge, CGPoint(x: x, y: y)))
        }
        appendVertical(x: centerRect.minX, edge: .left)
        appendVertical(x: centerRect.maxX, edge: .right)
        appendHorizontal(y: centerRect.minY, edge: .top)
        appendHorizontal(y: centerRect.maxY, edge: .bottom)

        guard let farthest = intersections.max(by: {
            if abs($0.scale - $1.scale) > 0.000_001 { return $0.scale < $1.scale }
            let lhsPriority = $0.edge.isHorizontal ? 1 : 0
            let rhsPriority = $1.edge.isHorizontal ? 1 : 0
            return lhsPriority == rhsPriority
                ? $0.edge.rawValue > $1.edge.rawValue
                : lhsPriority > rhsPriority
        }) else {
            // A dynamically raised timeline can put the whole center-safe
            // rect above the physical screen center. Rays pointing farther
            // away then never cross the rect, so choose the semantically
            // matching directional edge instead of dropping the member.
            let horizontalScore = abs(dx) / max(centerRect.width, 1)
            let verticalScore = abs(dy) / max(centerRect.height, 1)
            let edge: MapLibreEdgePinEdge
            if horizontalScore > verticalScore {
                edge = dx < 0 ? .left : .right
            } else {
                edge = dy < 0 ? .top : .bottom
            }
            let point: CGPoint
            switch edge {
            case .left:
                point = CGPoint(
                    x: centerRect.minX,
                    y: min(centerRect.maxY, max(centerRect.minY, numberCenter.y))
                )
            case .right:
                point = CGPoint(
                    x: centerRect.maxX,
                    y: min(centerRect.maxY, max(centerRect.minY, numberCenter.y))
                )
            case .top:
                point = CGPoint(
                    x: min(centerRect.maxX, max(centerRect.minX, numberCenter.x)),
                    y: centerRect.minY
                )
            case .bottom:
                point = CGPoint(
                    x: min(centerRect.maxX, max(centerRect.minX, numberCenter.x)),
                    y: centerRect.maxY
                )
            }
            return BoundaryProjection(point: point, edge: edge)
        }
        return BoundaryProjection(point: farthest.point, edge: farthest.edge)
    }

    /// Top and bottom pins intentionally have only two stable positions. The
    /// source's horizontal side of the physical screen center chooses the
    /// left or right endpoint; left/right-edge pins keep their true ray
    /// intersection. This prevents a top/bottom pill from drifting through
    /// misleading intermediate positions.
    static func landingProjection(
        safeRect: CGRect,
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat,
        rayOrigin: CGPoint
    ) -> BoundaryProjection? {
        guard let projection = boundaryProjection(
            safeRect: safeRect,
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent,
            rayOrigin: rayOrigin
        ) else { return nil }
        let centerRect = centerSafeRect(
            safeRect: safeRect,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent
        )
        guard !centerRect.isNull else { return nil }
        return snapHorizontalProjectionToEndpoint(
            projection,
            centerRect: centerRect,
            sourcePoint: numberCenter,
            screenCenter: rayOrigin
        )
    }

    static func pointingCorner(
        for projection: BoundaryProjection,
        safeRect: CGRect
    ) -> MapLibreEdgePinPointingCorner? {
        switch projection.edge {
        case .top:
            return projection.point.x <= safeRect.midX ? .topLeft : .topRight
        case .bottom:
            return projection.point.x <= safeRect.midX ? .bottomLeft : .bottomRight
        case .left, .right:
            return nil
        }
    }

    private static func boundaryProjection(
        safeRect: CGRect,
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat,
        rayOrigin: CGPoint?
    ) -> BoundaryProjection? {
        let centerRect = CGRect(
            x: safeRect.minX + labelSize.width / 2,
            y: safeRect.minY + topExtent,
            width: safeRect.width - labelSize.width,
            height: safeRect.height - topExtent - bottomExtent
        )
        guard centerRect.width >= 0, centerRect.height >= 0 else { return nil }
        return boundaryProjection(
            safeRect: safeRect,
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent,
            rayOrigin: rayOrigin ?? CGPoint(x: centerRect.midX, y: centerRect.midY)
        )
    }

    private static func centerSafeRect(
        safeRect: CGRect,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat
    ) -> CGRect {
        let rect = CGRect(
            x: safeRect.minX + labelSize.width / 2,
            y: safeRect.minY + topExtent,
            width: safeRect.width - labelSize.width,
            height: safeRect.height - topExtent - bottomExtent
        )
        return rect.width >= 0 && rect.height >= 0 ? rect : .null
    }

    private static func snapHorizontalProjectionToEndpoint(
        _ projection: BoundaryProjection,
        centerRect: CGRect,
        sourcePoint: CGPoint,
        screenCenter: CGPoint
    ) -> BoundaryProjection {
        guard projection.edge.isHorizontal else { return projection }
        let endpointX = sourcePoint.x < screenCenter.x
            ? centerRect.minX
            : centerRect.maxX
        let endpointY = projection.edge == .top
            ? centerRect.minY
            : centerRect.maxY
        return BoundaryProjection(
            point: CGPoint(x: endpointX, y: endpointY),
            edge: projection.edge
        )
    }

    private static func dominantOverflowProjection(
        outerFrame: CGRect,
        safeRect: CGRect,
        numberCenter: CGPoint,
        labelSize: CGSize,
        topExtent: CGFloat,
        bottomExtent: CGFloat
    ) -> BoundaryProjection? {
        let overflows: [(MapLibreEdgePinEdge, CGFloat)] = [
            (.left, max(0, safeRect.minX - outerFrame.minX) / max(1, labelSize.width / 2)),
            (.right, max(0, outerFrame.maxX - safeRect.maxX) / max(1, labelSize.width / 2)),
            (.top, max(0, safeRect.minY - outerFrame.minY) / max(1, topExtent)),
            (.bottom, max(0, outerFrame.maxY - safeRect.maxY) / max(1, bottomExtent))
        ]
        guard let dominant = overflows
            .filter({ $0.1 > 0 })
            .max(by: {
                $0.1 == $1.1 ? $0.0.rawValue > $1.0.rawValue : $0.1 < $1.1
            }) else {
            return nil
        }
        let point: CGPoint
        switch dominant.0 {
        case .left:
            point = CGPoint(
                x: safeRect.minX + labelSize.width / 2,
                y: min(safeRect.maxY - bottomExtent, max(safeRect.minY + topExtent, numberCenter.y))
            )
        case .right:
            point = CGPoint(
                x: safeRect.maxX - labelSize.width / 2,
                y: min(safeRect.maxY - bottomExtent, max(safeRect.minY + topExtent, numberCenter.y))
            )
        case .top:
            point = CGPoint(
                x: min(safeRect.maxX - labelSize.width / 2, max(safeRect.minX + labelSize.width / 2, numberCenter.x)),
                y: safeRect.minY + topExtent
            )
        case .bottom:
            point = CGPoint(
                x: min(safeRect.maxX - labelSize.width / 2, max(safeRect.minX + labelSize.width / 2, numberCenter.x)),
                y: safeRect.maxY - bottomExtent
            )
        }
        return BoundaryProjection(point: point, edge: dominant.0)
    }
}

enum MapLibreEdgePinTrigger {
    /// Edge attraction starts only after the POI anchor has genuinely crossed
    /// the physical screen. The 20/160/timeline insets are landing positions,
    /// not an inner trigger zone.
    static func isOutsideScreen(_ point: CGPoint, screenBounds: CGRect) -> Bool {
        point.x < screenBounds.minX
            || point.x > screenBounds.maxX
            || point.y < screenBounds.minY
            || point.y > screenBounds.maxY
    }
}

struct MapLibreProjectedEdgePinMember: Equatable {
    let id: UUID
    let displayOrder: Int
    let sourcePoint: CGPoint
    let isHighlighted: Bool
}

struct MapLibreProjectedEdgePinCluster: Equatable {
    let members: [MapLibreProjectedEdgePinMember]
    let edge: MapLibreEdgePinEdge
    let pointingCorner: MapLibreEdgePinPointingCorner?
    /// Whether the cluster contains the active POI. This always drives the
    /// orange border, including for merged numeric pills.
    let containsHighlighted: Bool
    /// Only an unmerged active POI adds the category bubble above the number.
    /// A tight dynamic obstruction may also suppress that bubble.
    let rendersHighlighted: Bool
    let directionAngle: CGFloat
    let numberCenter: CGPoint
    let labelText: String
    let labelSize: CGSize
    let renderedFrame: CGRect

    var representativeID: UUID { members[0].id }
}

/// Left/right clusters project on their own center ray; top/bottom clusters
/// snap to one of two endpoint slots. Threshold clustering provides
/// merge/split hysteresis, while rendered-frame collision closure is the final
/// authority: pins are merged rather than displaced along the boundary.
enum MapLibreProjectedEdgePinGrouping {
    static func clusters(
        members input: [MapLibreProjectedEdgePinMember],
        safeRect: CGRect,
        screenCenter: CGPoint,
        previousGroups: [[UUID]]
    ) -> [MapLibreProjectedEdgePinCluster] {
        var seen: Set<UUID> = []
        let members = input
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayOrder < $1.displayOrder }
        guard !members.isEmpty else { return [] }

        let memberByID = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0) })
        let thresholdMembers = members.compactMap { member -> MapLibreEdgePinGroupMember? in
            let angle = directionAngle(for: member.sourcePoint, from: screenCenter)
            let target = rayTarget(angle: angle, origin: screenCenter, safeRect: safeRect)
            let labelText = MapLibrePinLabelGeometry.fittingText(
                displayOrders: [member.displayOrder],
                maximumWidth: safeRect.width
            )
            let measuredLabelSize = MapLibrePinLabelGeometry.size(for: labelText)
            let labelSize = CGSize(
                width: min(measuredLabelSize.width, safeRect.width),
                height: measuredLabelSize.height
            )
            let topExtent = member.isHighlighted && canRenderHighlighted(in: safeRect)
                ? MapLibrePinPlacement.highlightedTopExtent
                : labelSize.height / 2
            guard let projection = MapLibreEdgePinGeometry.landingProjection(
                safeRect: safeRect,
                numberCenter: target,
                labelSize: labelSize,
                topExtent: topExtent,
                bottomExtent: labelSize.height / 2,
                rayOrigin: screenCenter
            ) else { return nil }
            return MapLibreEdgePinGroupMember(
                id: member.id,
                displayOrder: member.displayOrder,
                edge: projection.edge,
                directionAngle: angle,
                projectedPosition: projection.edge.isHorizontal
                    ? projection.point.x
                    : projection.point.y,
                isHighlighted: member.isHighlighted
            )
        }
        let thresholdGroups = MapLibreEdgePinGrouping.groups(
            members: thresholdMembers,
            previousGroups: previousGroups
        )
        var clusters = thresholdGroups.compactMap { group in
            projectedCluster(
                members: group.compactMap { memberByID[$0.id] },
                safeRect: safeRect,
                screenCenter: screenCenter
            )
        }

        // A threshold split is accepted only when the resulting rendered
        // rectangles are disjoint. Widening a merged pill can create another
        // collision, so repeat until the geometry reaches a fixed point.
        while clusters.count > 1 {
            var pair: (Int, Int)?
            for first in clusters.indices {
                for second in clusters.indices where second > first {
                    guard strictlyOverlaps(
                            clusters[first].renderedFrame,
                            clusters[second].renderedFrame
                          ) else { continue }
                    pair = (first, second)
                    break
                }
                if pair != nil { break }
            }
            guard let pair else { break }
            let mergedMembers = clusters[pair.0].members + clusters[pair.1].members
            guard let merged = projectedCluster(
                members: mergedMembers,
                safeRect: safeRect,
                screenCenter: screenCenter
            ) else { break }
            clusters[pair.0] = merged
            clusters.remove(at: pair.1)
            clusters.sort { minimumOrder($0.members) < minimumOrder($1.members) }
        }

        return clusters.sorted { minimumOrder($0.members) < minimumOrder($1.members) }
    }

    private static func projectedCluster(
        members unsortedMembers: [MapLibreProjectedEdgePinMember],
        safeRect: CGRect,
        screenCenter: CGPoint
    ) -> MapLibreProjectedEdgePinCluster? {
        guard !unsortedMembers.isEmpty else { return nil }
        let members = unsortedMembers.sorted { $0.displayOrder < $1.displayOrder }
        let labelText = MapLibrePinLabelGeometry.fittingText(
            displayOrders: members.map(\.displayOrder),
            maximumWidth: safeRect.width
        )
        let measuredLabelSize = MapLibrePinLabelGeometry.size(for: labelText)
        let labelSize = CGSize(
            width: min(measuredLabelSize.width, safeRect.width),
            height: measuredLabelSize.height
        )
        let directionAngle = circularMeanDirection(of: members, from: screenCenter)
        let target = rayTarget(angle: directionAngle, origin: screenCenter, safeRect: safeRect)
        let containsHighlighted = members.contains(where: \.isHighlighted)
        let rendersHighlighted = members.count == 1
            && containsHighlighted
            && canRenderHighlighted(in: safeRect)
        let topExtent = rendersHighlighted
            ? MapLibrePinPlacement.highlightedTopExtent
            : labelSize.height / 2
        let bottomExtent = labelSize.height / 2
        guard let projection = MapLibreEdgePinGeometry.landingProjection(
            safeRect: safeRect,
            numberCenter: target,
            labelSize: labelSize,
            topExtent: topExtent,
            bottomExtent: bottomExtent,
            rayOrigin: screenCenter
        ) else { return nil }
        return MapLibreProjectedEdgePinCluster(
            members: members,
            edge: projection.edge,
            pointingCorner: MapLibreEdgePinGeometry.pointingCorner(
                for: projection,
                safeRect: safeRect
            ),
            containsHighlighted: containsHighlighted,
            rendersHighlighted: rendersHighlighted,
            directionAngle: directionAngle,
            numberCenter: projection.point,
            labelText: labelText,
            labelSize: labelSize,
            renderedFrame: MapLibreEdgePinGeometry.renderedOuterFrame(
                numberCenter: projection.point,
                labelSize: labelSize,
                topExtent: topExtent,
                bottomExtent: bottomExtent
            )
        )
    }

    private static func circularMeanDirection(
        of members: [MapLibreProjectedEdgePinMember],
        from origin: CGPoint
    ) -> CGFloat {
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for member in members {
            let dx = member.sourcePoint.x - origin.x
            let dy = member.sourcePoint.y - origin.y
            let length = hypot(dx, dy)
            guard length > 0.000_001 else { continue }
            sumX += dx / length
            sumY += dy / length
        }
        if hypot(sumX, sumY) > 0.000_001 {
            return atan2(sumY, sumX)
        }
        let fallback = members.min { $0.displayOrder < $1.displayOrder }?.sourcePoint ?? origin
        return directionAngle(for: fallback, from: origin)
    }

    private static func directionAngle(for point: CGPoint, from origin: CGPoint) -> CGFloat {
        let dx = point.x - origin.x
        let dy = point.y - origin.y
        guard abs(dx) > 0.000_001 || abs(dy) > 0.000_001 else { return -.pi / 2 }
        return atan2(dy, dx)
    }

    private static func rayTarget(
        angle: CGFloat,
        origin: CGPoint,
        safeRect: CGRect
    ) -> CGPoint {
        let distance = max(10_000, hypot(safeRect.width, safeRect.height) * 4)
        return CGPoint(
            x: origin.x + cos(angle) * distance,
            y: origin.y + sin(angle) * distance
        )
    }

    private static func minimumOrder(_ members: [MapLibreProjectedEdgePinMember]) -> Int {
        members.map(\.displayOrder).min() ?? .max
    }

    private static func canRenderHighlighted(in safeRect: CGRect) -> Bool {
        safeRect.height >= MapLibrePinPlacement.highlightedTopExtent
            + MapLibrePinPlacement.bubbleSize / 2
    }

    private static func strictlyOverlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

struct MapLibreResolvedPinClusters: Equatable {
    let regular: [MapLibreRegularPinCluster]
    let edge: [MapLibreProjectedEdgePinCluster]
}

/// Resolves the seam between on-map clusters and edge clusters. A regular
/// pill can fit exactly within the safe rect yet overlap an edge pill that is
/// anchored on that same boundary. Promote every member of such a pill into
/// edge grouping and repeat because the widened edge result may collide with
/// another remaining regular cluster.
enum MapLibreFinalPinGrouping {
    static func resolve(
        regularClusters: [MapLibreRegularPinCluster],
        initialEdgeMemberIDs: Set<UUID>,
        allEdgeMembers: [MapLibreProjectedEdgePinMember],
        safeRect: CGRect,
        screenCenter: CGPoint,
        previousEdgeGroups: [[UUID]]
    ) -> MapLibreResolvedPinClusters {
        var regular = regularClusters
        var edgeMemberIDs = initialEdgeMemberIDs

        while true {
            let edge = MapLibreProjectedEdgePinGrouping.clusters(
                members: allEdgeMembers.filter { edgeMemberIDs.contains($0.id) },
                safeRect: safeRect,
                screenCenter: screenCenter,
                previousGroups: previousEdgeGroups
            )
            let promotedRepresentativeIDs = Set(regular.compactMap { cluster -> UUID? in
                edge.contains(where: {
                    strictlyOverlaps(cluster.renderedFrame, $0.renderedFrame)
                }) ? cluster.representativeID : nil
            })
            guard !promotedRepresentativeIDs.isEmpty else {
                return MapLibreResolvedPinClusters(regular: regular, edge: edge)
            }

            var didPromote = false
            regular.removeAll { cluster in
                guard promotedRepresentativeIDs.contains(cluster.representativeID) else {
                    return false
                }
                for member in cluster.members {
                    didPromote = edgeMemberIDs.insert(member.id).inserted || didPromote
                }
                return true
            }
            guard didPromote else {
                return MapLibreResolvedPinClusters(regular: regular, edge: edge)
            }
        }
    }

    static func hasPairwiseOverlap(_ frames: [CGRect]) -> Bool {
        guard frames.count > 1 else { return false }
        for first in frames.indices {
            for second in frames.indices where second > first {
                if strictlyOverlaps(frames[first], frames[second]) { return true }
            }
        }
        return false
    }

    private static func strictlyOverlaps(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let intersection = lhs.intersection(rhs)
        return !intersection.isNull && intersection.width > 0 && intersection.height > 0
    }
}

struct MapLibreEdgePinViewportGeometry: Equatable {
    let mapBounds: CGRect
    let windowBounds: CGRect
}

enum MapLibrePinPlacementUpdateReason: Equatable {
    case initial
    case dataMutation
    case selection
    case viewport
    case safeArea
    case autoFocus

    var allowsGooeyTransition: Bool {
        switch self {
        case .viewport, .safeArea, .autoFocus:
            true
        case .initial, .dataMutation, .selection:
            false
        }
    }

    static func resolve(
        hasPresentedInitialState: Bool,
        pointsChanged: Bool,
        safeAreaChanged: Bool,
        selectionChanged: Bool
    ) -> Self {
        if !hasPresentedInitialState { return .initial }
        if pointsChanged { return .dataMutation }
        if safeAreaChanged { return .safeArea }
        if selectionChanged { return .selection }
        return .viewport
    }
}

struct MapLibrePinVisualSnapshot: Equatable {
    let representativeID: UUID
    let orderedMemberIDs: [UUID]
    let numberFrame: CGRect
    let labelText: String
    let isHighlighted: Bool
    let showsCategoryBubble: Bool
    let pointingCorner: MapLibreEdgePinPointingCorner?
}

struct MapLibrePinPartitionSnapshot: Equatable {
    let updateGeneration: Int
    let placements: [MapLibrePinVisualSnapshot]
}

enum MapLibrePinGooeyTransitionKind: Equatable {
    case merge
    case split
}

struct MapLibrePinGooeyTransitionKey: Hashable {
    let orderedMemberIDs: [UUID]
}

struct MapLibrePinGooeyBranch: Equatable {
    let orderedMemberIDs: [UUID]
    let sourceFrame: CGRect
    let targetFrame: CGRect
    let sourcePointingCorner: MapLibreEdgePinPointingCorner?
    let targetPointingCorner: MapLibreEdgePinPointingCorner?
}

struct MapLibrePinGooeyTransitionDescriptor: Equatable {
    let key: MapLibrePinGooeyTransitionKey
    let kind: MapLibrePinGooeyTransitionKind
    let branches: [MapLibrePinGooeyBranch]
    let localBounds: CGRect
    let showsAccent: Bool
}

enum MapLibrePinGooeyOuterFillRole: Equatable {
    case white
    case accent
}

enum MapLibrePinGooeyStyle {
    static func outerFillRole(showsAccent: Bool) -> MapLibrePinGooeyOuterFillRole {
        showsAccent ? .accent : .white
    }
}

enum MapLibrePinGooeyTransitionResolver {
    static func hasSameCanonicalPartition(
        _ lhs: MapLibrePinPartitionSnapshot,
        _ rhs: MapLibrePinPartitionSnapshot
    ) -> Bool {
        guard let lhsPlacements = validated(lhs.placements),
              let rhsPlacements = validated(rhs.placements) else {
            return false
        }
        return canonicalPartition(lhsPlacements) == canonicalPartition(rhsPlacements)
    }

    static func transitions(
        previous: MapLibrePinPartitionSnapshot?,
        current: MapLibrePinPartitionSnapshot,
        reason: MapLibrePinPlacementUpdateReason,
        hasPresentedInitialState: Bool
    ) -> [MapLibrePinGooeyTransitionDescriptor] {
        guard reason.allowsGooeyTransition,
              hasPresentedInitialState,
              let previous,
              let old = validated(previous.placements),
              let new = validated(current.placements) else {
            return []
        }
        let oldMembers = Set(old.flatMap(\.orderedMemberIDs))
        let newMembers = Set(new.flatMap(\.orderedMemberIDs))
        guard oldMembers == newMembers,
              canonicalPartition(old) != canonicalPartition(new) else {
            return []
        }

        let oldSets = old.map { Set($0.orderedMemberIDs) }
        let newSets = new.map { Set($0.orderedMemberIDs) }
        var visitedOld = Set<Int>()
        var visitedNew = Set<Int>()
        var result: [MapLibrePinGooeyTransitionDescriptor] = []

        for start in old.indices where !visitedOld.contains(start) {
            var pendingOld = [start]
            var pendingNew: [Int] = []
            var componentOld = Set<Int>()
            var componentNew = Set<Int>()
            while !pendingOld.isEmpty || !pendingNew.isEmpty {
                while let index = pendingOld.popLast() {
                    guard componentOld.insert(index).inserted else { continue }
                    visitedOld.insert(index)
                    for candidate in new.indices
                    where !oldSets[index].isDisjoint(with: newSets[candidate]) {
                        pendingNew.append(candidate)
                    }
                }
                while let index = pendingNew.popLast() {
                    guard componentNew.insert(index).inserted else { continue }
                    visitedNew.insert(index)
                    for candidate in old.indices
                    where !newSets[index].isDisjoint(with: oldSets[candidate]) {
                        pendingOld.append(candidate)
                    }
                }
            }

            let oldIndices = componentOld.sorted()
            let newIndices = componentNew.sorted()
            let componentMembers = Set(oldIndices.flatMap { old[$0].orderedMemberIDs })
            let key = MapLibrePinGooeyTransitionKey(
                orderedMemberIDs: componentMembers.sorted(by: uuidLessThan)
            )
            let kind: MapLibrePinGooeyTransitionKind
            let branches: [MapLibrePinGooeyBranch]
            if oldIndices.count > 1, newIndices.count == 1,
               let target = newIndices.first.map({ new[$0] }) {
                kind = .merge
                branches = oldIndices.map { index in
                    MapLibrePinGooeyBranch(
                        orderedMemberIDs: old[index].orderedMemberIDs,
                        sourceFrame: old[index].numberFrame,
                        targetFrame: target.numberFrame,
                        sourcePointingCorner: old[index].pointingCorner,
                        targetPointingCorner: target.pointingCorner
                    )
                }
            } else if oldIndices.count == 1, newIndices.count > 1,
                      let source = oldIndices.first.map({ old[$0] }) {
                kind = .split
                branches = newIndices.map { index in
                    MapLibrePinGooeyBranch(
                        orderedMemberIDs: new[index].orderedMemberIDs,
                        sourceFrame: source.numberFrame,
                        targetFrame: new[index].numberFrame,
                        sourcePointingCorner: source.pointingCorner,
                        targetPointingCorner: new[index].pointingCorner
                    )
                }
            } else {
                continue
            }
            let frames = branches.flatMap { [$0.sourceFrame, $0.targetFrame] }
            guard let union = frames.reduce(nil as CGRect?, { partial, frame in
                partial.map { $0.union(frame) } ?? frame
            }) else { continue }
            result.append(MapLibrePinGooeyTransitionDescriptor(
                key: key,
                kind: kind,
                branches: branches,
                // 40pt contains Bézier control handles plus the optional
                // 32pt category bubble above a numeric capsule.
                localBounds: union.insetBy(dx: -40, dy: -40),
                showsAccent: (oldIndices.map { old[$0] } + newIndices.map { new[$0] })
                    .contains(where: \.isHighlighted)
            ))
        }

        // A current placement without an old neighbor means malformed input,
        // which must never be animated into existence.
        guard visitedNew.count == new.count else { return [] }
        return result.sorted { lhs, rhs in
            lhs.key.orderedMemberIDs.map(\.uuidString).joined()
                < rhs.key.orderedMemberIDs.map(\.uuidString).joined()
        }
    }

    private static func validated(
        _ placements: [MapLibrePinVisualSnapshot]
    ) -> [MapLibrePinVisualSnapshot]? {
        var seen = Set<UUID>()
        for placement in placements {
            let members = Set(placement.orderedMemberIDs)
            guard !members.isEmpty,
                  members.count == placement.orderedMemberIDs.count,
                  members.isDisjoint(with: seen),
                  MapLibrePinGooeyGeometry.isFinite(placement.numberFrame) else {
                return nil
            }
            seen.formUnion(members)
        }
        return placements
    }

    private static func canonicalPartition(
        _ placements: [MapLibrePinVisualSnapshot]
    ) -> [String] {
        placements.map {
            $0.orderedMemberIDs.map(\.uuidString).sorted().joined(separator: "|")
        }.sorted()
    }

    private static func uuidLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
        lhs.uuidString < rhs.uuidString
    }
}

struct MapLibrePinClarityItem: Equatable {
    let memberIDs: [UUID]
    let frame: CGRect
    let text: String
}

struct MapLibrePinMetaballSample: Equatable {
    let outerPath: CGPath
    let innerPath: CGPath
    let clarityItems: [MapLibrePinClarityItem]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.outerPath == rhs.outerPath
            && lhs.innerPath == rhs.innerPath
            && lhs.clarityItems == rhs.clarityItems
    }
}

struct MapLibrePinGooeyEndpointCornerRadii: Equatable {
    let source: MapLibrePinCornerRadii
    let target: MapLibrePinCornerRadii
}

enum MapLibrePinGooeyGeometry {
    static let maximumBridgeLength: CGFloat = 96
    static let bridgeInset: CGFloat = 2

    static func surfaceGap(from sourceFrame: CGRect, to targetFrame: CGRect) -> CGFloat {
        guard isFinite(sourceFrame), isFinite(targetFrame) else { return .infinity }
        let sourceRadius = min(sourceFrame.width, sourceFrame.height) / 2
        let targetRadius = min(targetFrame.width, targetFrame.height) / 2
        let sourceInterval = (
            min: sourceFrame.minX + sourceRadius,
            max: sourceFrame.maxX - sourceRadius
        )
        let targetInterval = (
            min: targetFrame.minX + targetRadius,
            max: targetFrame.maxX - targetRadius
        )
        let horizontalGap = max(
            0,
            max(sourceInterval.min, targetInterval.min)
                - min(sourceInterval.max, targetInterval.max)
        )
        let centerLineDistance = hypot(
            horizontalGap,
            targetFrame.midY - sourceFrame.midY
        )
        return max(0, centerLineDistance - sourceRadius - targetRadius)
    }

    static func isRenderable(_ descriptor: MapLibrePinGooeyTransitionDescriptor) -> Bool {
        !descriptor.branches.isEmpty
            && isFinite(descriptor.localBounds)
            && descriptor.localBounds.width > 0
            && descriptor.localBounds.height > 0
            && descriptor.branches.allSatisfy {
                isFinite($0.sourceFrame)
                    && isFinite($0.targetFrame)
                    && surfaceGap(from: $0.sourceFrame, to: $0.targetFrame)
                        <= maximumBridgeLength
            }
    }

    static func isFinite(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.width >= 0 && rect.height >= 0
    }

    fileprivate static func supportDistance(of frame: CGRect, direction: CGVector) -> CGFloat {
        let radius = frame.height / 2
        let halfSegment = max(0, (frame.width - frame.height) / 2)
        return radius + abs(direction.dx) * halfSegment
    }
}

enum MapLibrePinMetaballPath {
    static func endpointCornerRadii(
        branch: MapLibrePinGooeyBranch,
        progress: CGFloat
    ) -> MapLibrePinGooeyEndpointCornerRadii {
        let frames = endpointFrames(branch: branch, progress: progress)
        return MapLibrePinGooeyEndpointCornerRadii(
            source: cornerRadii(in: frames.source, pointingCorner: branch.sourcePointingCorner),
            target: cornerRadii(in: frames.target, pointingCorner: branch.targetPointingCorner)
        )
    }

    static func sample(
        descriptor: MapLibrePinGooeyTransitionDescriptor,
        progress: CGFloat,
        previousDirection: CGVector? = nil
    ) -> MapLibrePinMetaballSample? {
        guard MapLibrePinGooeyGeometry.isRenderable(descriptor) else { return nil }
        let progress = min(1, max(0, progress))
        let eased = smoothstep(progress)
        let outer = CGMutablePath()
        let inner = CGMutablePath()
        for branch in descriptor.branches {
            appendBranch(
                branch,
                progress: progress,
                eased: eased,
                inset: -MapLibrePinGooeyGeometry.bridgeInset,
                localOrigin: descriptor.localBounds.origin,
                previousDirection: previousDirection,
                to: outer
            )
            appendBranch(
                branch,
                progress: progress,
                eased: eased,
                inset: 0,
                localOrigin: descriptor.localBounds.origin,
                previousDirection: previousDirection,
                to: inner
            )
        }
        return MapLibrePinMetaballSample(
            outerPath: outer,
            innerPath: inner,
            clarityItems: []
        )
    }

    private static func appendBranch(
        _ branch: MapLibrePinGooeyBranch,
        progress: CGFloat,
        eased: CGFloat,
        inset: CGFloat,
        localOrigin: CGPoint,
        previousDirection: CGVector?,
        to path: CGMutablePath
    ) {
        let endpointFrames = endpointFrames(branch: branch, progress: progress, eased: eased)
        let source = endpointFrames.source.insetBy(dx: inset, dy: inset)
        let target = endpointFrames.target.insetBy(dx: inset, dy: inset)
        let localSource = source.offsetBy(dx: -localOrigin.x, dy: -localOrigin.y)
        let localTarget = target.offsetBy(dx: -localOrigin.x, dy: -localOrigin.y)
        appendPinShape(
            localSource,
            pointingCorner: branch.sourcePointingCorner,
            to: path
        )
        appendPinShape(
            localTarget,
            pointingCorner: branch.targetPointingCorner,
            to: path
        )

        let delta = CGVector(dx: localTarget.midX - localSource.midX, dy: localTarget.midY - localSource.midY)
        let distance = hypot(delta.dx, delta.dy)
        let fallback = finiteDirection(previousDirection) ?? CGVector(dx: 1, dy: 0)
        let direction = distance > 0.0001
            ? CGVector(dx: delta.dx / distance, dy: delta.dy / distance)
            : fallback
        let normal = CGVector(dx: -direction.dy, dy: direction.dx)
        let defaultSourceAnchor = CGPoint(
            x: localSource.midX + direction.dx * MapLibrePinGooeyGeometry.supportDistance(of: localSource, direction: direction),
            y: localSource.midY + direction.dy * MapLibrePinGooeyGeometry.supportDistance(of: localSource, direction: direction)
        )
        let defaultTargetAnchor = CGPoint(
            x: localTarget.midX - direction.dx * MapLibrePinGooeyGeometry.supportDistance(of: localTarget, direction: direction),
            y: localTarget.midY - direction.dy * MapLibrePinGooeyGeometry.supportDistance(of: localTarget, direction: direction)
        )
        let sourceAnchor = bridgeAnchor(
            frame: localSource,
            pointingCorner: branch.sourcePointingCorner,
            outwardDirection: direction,
            defaultAnchor: defaultSourceAnchor
        )
        let targetAnchor = bridgeAnchor(
            frame: localTarget,
            pointingCorner: branch.targetPointingCorner,
            outwardDirection: CGVector(dx: -direction.dx, dy: -direction.dy),
            defaultAnchor: defaultTargetAnchor
        )
        let gap = hypot(targetAnchor.x - sourceAnchor.x, targetAnchor.y - sourceAnchor.y)
        let proximity = 1 - smoothstep(min(1, gap / MapLibrePinGooeyGeometry.maximumBridgeLength))
        let maximumHalfWidth = max(0, min(localSource.height, localTarget.height) / 2)
        let halfWidth = min(16, maximumHalfWidth * sin(.pi * progress) * (0.35 + 0.65 * proximity))
        let handle = min(gap / 2, 24)
        let sourcePlus = offset(sourceAnchor, normal, halfWidth)
        let sourceMinus = offset(sourceAnchor, normal, -halfWidth)
        let targetPlus = offset(targetAnchor, normal, halfWidth)
        let targetMinus = offset(targetAnchor, normal, -halfWidth)
        path.move(to: sourcePlus)
        path.addCurve(
            to: targetPlus,
            control1: offset(sourcePlus, direction, handle),
            control2: offset(targetPlus, direction, -handle)
        )
        path.addLine(to: targetMinus)
        path.addCurve(
            to: sourceMinus,
            control1: offset(targetMinus, direction, -handle),
            control2: offset(sourceMinus, direction, handle)
        )
        path.addLine(to: sourcePlus)
        path.closeSubpath()
    }

    private static func appendPinShape(
        _ frame: CGRect,
        pointingCorner: MapLibreEdgePinPointingCorner?,
        to path: CGMutablePath
    ) {
        let radii = cornerRadii(in: frame, pointingCorner: pointingCorner)
        path.move(to: CGPoint(x: frame.minX + radii.topLeft, y: frame.minY))
        path.addLine(to: CGPoint(x: frame.maxX - radii.topRight, y: frame.minY))
        path.addQuadCurve(
            to: CGPoint(x: frame.maxX, y: frame.minY + radii.topRight),
            control: CGPoint(x: frame.maxX, y: frame.minY)
        )
        path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY - radii.bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: frame.maxX - radii.bottomRight, y: frame.maxY),
            control: CGPoint(x: frame.maxX, y: frame.maxY)
        )
        path.addLine(to: CGPoint(x: frame.minX + radii.bottomLeft, y: frame.maxY))
        path.addQuadCurve(
            to: CGPoint(x: frame.minX, y: frame.maxY - radii.bottomLeft),
            control: CGPoint(x: frame.minX, y: frame.maxY)
        )
        path.addLine(to: CGPoint(x: frame.minX, y: frame.minY + radii.topLeft))
        path.addQuadCurve(
            to: CGPoint(x: frame.minX + radii.topLeft, y: frame.minY),
            control: CGPoint(x: frame.minX, y: frame.minY)
        )
        path.closeSubpath()
    }

    private static func cornerRadii(
        in frame: CGRect,
        pointingCorner: MapLibreEdgePinPointingCorner?
    ) -> MapLibrePinCornerRadii {
        MapLibrePinCornerTransitionGeometry.radii(
            pointingCorner: pointingCorner,
            radius: max(0, min(frame.height / 2, frame.width / 2))
        )
    }

    private static func bridgeAnchor(
        frame: CGRect,
        pointingCorner: MapLibreEdgePinPointingCorner?,
        outwardDirection: CGVector,
        defaultAnchor: CGPoint
    ) -> CGPoint {
        switch pointingCorner {
        case .topLeft where outwardDirection.dx < 0 && outwardDirection.dy < 0,
             .topRight where outwardDirection.dx > 0 && outwardDirection.dy < 0:
            return CGPoint(x: frame.midX, y: frame.minY)
        case .bottomLeft where outwardDirection.dx < 0 && outwardDirection.dy > 0,
             .bottomRight where outwardDirection.dx > 0 && outwardDirection.dy > 0:
            return CGPoint(x: frame.midX, y: frame.maxY)
        default:
            return defaultAnchor
        }
    }

    private static func endpointFrames(
        branch: MapLibrePinGooeyBranch,
        progress: CGFloat,
        eased suppliedEased: CGFloat? = nil
    ) -> (source: CGRect, target: CGRect) {
        let progress = min(1, max(0, progress))
        let eased = suppliedEased ?? smoothstep(progress)
        let movingSource = interpolated(branch.sourceFrame, branch.targetFrame, eased)
        let sourceScale = max(
            0.001,
            1 - smoothstep(min(1, max(0, (progress - 0.55) / 0.45)))
        )
        let targetScale = max(
            0.001,
            smoothstep(min(1, max(0, (progress - 0.08) / 0.84)))
        )
        return (
            source: scaled(movingSource, by: sourceScale),
            target: scaled(branch.targetFrame, by: targetScale)
        )
    }

    private static func interpolated(_ lhs: CGRect, _ rhs: CGRect, _ progress: CGFloat) -> CGRect {
        CGRect(
            x: lhs.minX + (rhs.minX - lhs.minX) * progress,
            y: lhs.minY + (rhs.minY - lhs.minY) * progress,
            width: lhs.width + (rhs.width - lhs.width) * progress,
            height: lhs.height + (rhs.height - lhs.height) * progress
        )
    }

    private static func scaled(_ frame: CGRect, by scale: CGFloat) -> CGRect {
        CGRect(
            x: frame.midX - frame.width * scale / 2,
            y: frame.midY - frame.height * scale / 2,
            width: frame.width * scale,
            height: frame.height * scale
        )
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }

    private static func finiteDirection(_ direction: CGVector?) -> CGVector? {
        guard let direction,
              direction.dx.isFinite,
              direction.dy.isFinite else { return nil }
        let length = hypot(direction.dx, direction.dy)
        guard length > 0.0001 else { return nil }
        return CGVector(dx: direction.dx / length, dy: direction.dy / length)
    }

    private static func offset(_ point: CGPoint, _ vector: CGVector, _ amount: CGFloat) -> CGPoint {
        CGPoint(x: point.x + vector.dx * amount, y: point.y + vector.dy * amount)
    }
}

struct MapLibrePinGooeyLifecycleState: Equatable {
    static let maximumActiveComponents = 4
    private(set) var nextGeneration = 0
    private(set) var activeGenerations: [MapLibrePinGooeyTransitionKey: Int] = [:]

    mutating func begin(_ key: MapLibrePinGooeyTransitionKey) -> Int? {
        guard activeGenerations[key] != nil
                || activeGenerations.count < Self.maximumActiveComponents else {
            return nil
        }
        nextGeneration &+= 1
        activeGenerations[key] = nextGeneration
        return nextGeneration
    }

    func isCurrent(_ key: MapLibrePinGooeyTransitionKey, generation: Int) -> Bool {
        activeGenerations[key] == generation
    }

    mutating func finish(_ key: MapLibrePinGooeyTransitionKey, generation: Int) {
        guard isCurrent(key, generation: generation) else { return }
        activeGenerations[key] = nil
    }

    mutating func cancelAll() {
        activeGenerations.removeAll()
    }

    mutating func cancel(_ key: MapLibrePinGooeyTransitionKey) {
        activeGenerations[key] = nil
    }
}

struct MapLibrePinGooeyTranslation: Equatable {
    let dx: CGFloat
    let dy: CGFloat
}

enum MapLibrePinGooeyRetargetDecision: Equatable {
    case unchanged
    case translate(MapLibrePinGooeyTranslation)
    case cancel
}

enum MapLibrePinGooeyRetargetPolicy {
    static func relevantPlacements(
        in snapshot: MapLibrePinPartitionSnapshot,
        for key: MapLibrePinGooeyTransitionKey
    ) -> [MapLibrePinVisualSnapshot] {
        let members = Set(key.orderedMemberIDs)
        return snapshot.placements.filter {
            !members.isDisjoint(with: Set($0.orderedMemberIDs))
        }.sorted { canonicalKey($0) < canonicalKey($1) }
    }

    static func decision(
        reference: [MapLibrePinVisualSnapshot],
        current: [MapLibrePinVisualSnapshot]
    ) -> MapLibrePinGooeyRetargetDecision {
        guard !reference.isEmpty, reference.count == current.count else { return .cancel }
        let old = reference.sorted { canonicalKey($0) < canonicalKey($1) }
        let new = current.sorted { canonicalKey($0) < canonicalKey($1) }
        var commonTranslation: MapLibrePinGooeyTranslation?
        for (lhs, rhs) in zip(old, new) {
            guard canonicalKey(lhs) == canonicalKey(rhs),
                  lhs.representativeID == rhs.representativeID,
                  abs(lhs.numberFrame.width - rhs.numberFrame.width) <= 0.5,
                  abs(lhs.numberFrame.height - rhs.numberFrame.height) <= 0.5,
                  lhs.labelText == rhs.labelText,
                  lhs.isHighlighted == rhs.isHighlighted,
                  lhs.showsCategoryBubble == rhs.showsCategoryBubble,
                  lhs.pointingCorner == rhs.pointingCorner else {
                return .cancel
            }
            let translation = MapLibrePinGooeyTranslation(
                dx: rhs.numberFrame.midX - lhs.numberFrame.midX,
                dy: rhs.numberFrame.midY - lhs.numberFrame.midY
            )
            if let commonTranslation {
                guard abs(commonTranslation.dx - translation.dx) <= 0.5,
                      abs(commonTranslation.dy - translation.dy) <= 0.5 else {
                    return .cancel
                }
            } else {
                commonTranslation = translation
            }
        }
        guard let commonTranslation else { return .cancel }
        if abs(commonTranslation.dx) <= 0.25, abs(commonTranslation.dy) <= 0.25 {
            return .unchanged
        }
        return .translate(commonTranslation)
    }

    private static func canonicalKey(_ placement: MapLibrePinVisualSnapshot) -> String {
        placement.orderedMemberIDs.map(\.uuidString).sorted().joined(separator: "|")
    }
}

enum MapLibrePinGooeyBounds {
    static func clippedLocalBounds(
        _ localBounds: CGRect,
        mapBounds: CGRect,
        safeBounds: CGRect
    ) -> CGRect? {
        guard MapLibrePinGooeyGeometry.isFinite(localBounds),
              MapLibrePinGooeyGeometry.isFinite(mapBounds),
              MapLibrePinGooeyGeometry.isFinite(safeBounds),
              !safeBounds.isNull else {
            return nil
        }
        let clipped = localBounds.intersection(mapBounds).intersection(safeBounds)
        guard !clipped.isNull, clipped.width > 1, clipped.height > 1 else { return nil }
        return clipped
    }
}

@MainActor
private final class MapLibreGeometryTrackingMapView: MLNMapView {
    var onViewportGeometryChanged: ((MapLibreEdgePinViewportGeometry) -> Void)?
    private var lastViewportGeometry: MapLibreEdgePinViewportGeometry?

    override func layoutSubviews() {
        super.layoutSubviews()
        let geometry = MapLibreEdgePinViewportGeometry(
            mapBounds: bounds,
            windowBounds: window?.bounds ?? .zero
        )
        guard geometry != lastViewportGeometry else { return }
        lastViewportGeometry = geometry
        onViewportGeometryChanged?(geometry)
    }
}

@MainActor
private final class MapLibrePinGooeyOverlayView: UIView {
    private struct VisiblePaths {
        let outer: CGPath?
        let inner: CGPath?
        let localBounds: CGRect
    }

    private final class ActiveComponent {
        let container: CALayer
        let outer: CAShapeLayer
        let inner: CAShapeLayer
        var rawLocalBounds: CGRect
        var localBounds: CGRect
        var referencePlacements: [MapLibrePinVisualSnapshot]
        let showsAccent: Bool
        let annotationViews: [MapLibreNumberedAnnotationView]

        init(
            container: CALayer,
            outer: CAShapeLayer,
            inner: CAShapeLayer,
            rawLocalBounds: CGRect,
            localBounds: CGRect,
            referencePlacements: [MapLibrePinVisualSnapshot],
            showsAccent: Bool,
            annotationViews: [MapLibreNumberedAnnotationView]
        ) {
            self.container = container
            self.outer = outer
            self.inner = inner
            self.rawLocalBounds = rawLocalBounds
            self.localBounds = localBounds
            self.referencePlacements = referencePlacements
            self.showsAccent = showsAccent
            self.annotationViews = annotationViews
        }
    }

    private var lifecycle = MapLibrePinGooeyLifecycleState()
    private var active: [MapLibrePinGooeyTransitionKey: ActiveComponent] = [:]
    private let accentColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    func play(
        _ descriptors: [MapLibrePinGooeyTransitionDescriptor],
        previous: MapLibrePinPartitionSnapshot,
        current: MapLibrePinPartitionSnapshot,
        safeBounds: CGRect,
        symbolName: ([UUID]) -> String?,
        finalViews: (MapLibrePinGooeyTransitionDescriptor) -> [MapLibreNumberedAnnotationView]
    ) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            cancelAll()
            return
        }
        let descriptors = Array(descriptors.prefix(MapLibrePinGooeyLifecycleState.maximumActiveComponents))
        let visiblePaths = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            active[descriptor.key].map { component in
                (descriptor.key, VisiblePaths(
                    outer: component.outer.presentation()?.path,
                    inner: component.inner.presentation()?.path,
                    localBounds: component.localBounds
                ))
            }
        })
        cancelAll()

        for descriptor in descriptors where MapLibrePinGooeyGeometry.isRenderable(descriptor) {
            guard let clippedBounds = MapLibrePinGooeyBounds.clippedLocalBounds(
                descriptor.localBounds,
                mapBounds: bounds,
                safeBounds: safeBounds
            ) else { continue }
            let renderDescriptor = MapLibrePinGooeyTransitionDescriptor(
                key: descriptor.key,
                kind: descriptor.kind,
                branches: descriptor.branches,
                localBounds: clippedBounds,
                showsAccent: descriptor.showsAccent
            )
            let samples = stride(from: 0, through: 8, by: 1).compactMap { index in
                MapLibrePinMetaballPath.sample(
                    descriptor: renderDescriptor,
                    progress: CGFloat(index) / 8
                )
            }
            guard samples.count == 9,
                  let first = samples.first,
                  let last = samples.last,
                  let generation = lifecycle.begin(descriptor.key) else {
                continue
            }

            let componentLayer = CALayer()
            componentLayer.frame = clippedBounds
            componentLayer.masksToBounds = true
            let outerLayer = CAShapeLayer()
            let innerLayer = CAShapeLayer()
            [outerLayer, innerLayer].forEach {
                $0.frame = componentLayer.bounds
                $0.fillRule = .nonZero
            }
            outerLayer.fillColor = outerFillColor(for: descriptor.showsAccent).cgColor
            innerLayer.fillColor = UIColor.white.cgColor
            outerLayer.path = last.outerPath
            innerLayer.path = last.innerPath
            componentLayer.addSublayer(outerLayer)
            componentLayer.addSublayer(innerLayer)

            let affectedViews = finalViews(descriptor)
            affectedViews.forEach { $0.setGooeyContentHidden(true) }
            active[descriptor.key] = ActiveComponent(
                container: componentLayer,
                outer: outerLayer,
                inner: innerLayer,
                rawLocalBounds: descriptor.localBounds,
                localBounds: clippedBounds,
                referencePlacements: MapLibrePinGooeyRetargetPolicy.relevantPlacements(
                    in: current,
                    for: descriptor.key
                ),
                showsAccent: descriptor.showsAccent,
                annotationViews: affectedViews
            )
            layer.addSublayer(componentLayer)

            addClarityLayers(
                to: componentLayer,
                descriptor: descriptor,
                previous: previous,
                current: current,
                symbolName: symbolName,
                localOrigin: clippedBounds.origin
            )

            var outerValues = samples.map(\.outerPath)
            var innerValues = samples.map(\.innerPath)
            if let visible = visiblePaths[descriptor.key] {
                if let path = translated(
                    visible.outer,
                    from: visible.localBounds.origin,
                    to: clippedBounds.origin
                ), hasSameTopology(path, first.outerPath) {
                    outerValues[0] = path
                }
                if let path = translated(
                    visible.inner,
                    from: visible.localBounds.origin,
                    to: clippedBounds.origin
                ), hasSameTopology(path, first.innerPath) {
                    innerValues[0] = path
                }
            } else {
                outerValues[0] = first.outerPath
                innerValues[0] = first.innerPath
            }
            let outerAnimation = pathAnimation(values: outerValues)
            let innerAnimation = pathAnimation(values: innerValues)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                self?.finish(descriptor.key, generation: generation)
            }
            outerLayer.add(outerAnimation, forKey: "gooey.outer")
            innerLayer.add(innerAnimation, forKey: "gooey.inner")
            CATransaction.commit()
        }
    }

    func updateActiveComponents(
        current: MapLibrePinPartitionSnapshot,
        safeBounds: CGRect
    ) {
        for key in Array(active.keys) {
            guard let component = active[key] else { continue }
            let currentPlacements = MapLibrePinGooeyRetargetPolicy.relevantPlacements(
                in: current,
                for: key
            )
            let decision = MapLibrePinGooeyRetargetPolicy.decision(
                reference: component.referencePlacements,
                current: currentPlacements
            )
            switch decision {
            case .unchanged:
                guard let clipped = MapLibrePinGooeyBounds.clippedLocalBounds(
                    component.rawLocalBounds,
                    mapBounds: bounds,
                    safeBounds: safeBounds
                ), nearlyEqual(clipped, component.localBounds) else {
                    cancel(key)
                    continue
                }
                component.referencePlacements = currentPlacements
            case let .translate(translation):
                let translatedRaw = component.rawLocalBounds.offsetBy(
                    dx: translation.dx,
                    dy: translation.dy
                )
                guard let clipped = MapLibrePinGooeyBounds.clippedLocalBounds(
                    translatedRaw,
                    mapBounds: bounds,
                    safeBounds: safeBounds
                ), nearlyEqual(
                    clipped,
                    component.localBounds.offsetBy(dx: translation.dx, dy: translation.dy)
                ) else {
                    cancel(key)
                    continue
                }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                component.container.frame = clipped
                CATransaction.commit()
                component.rawLocalBounds = translatedRaw
                component.localBounds = clipped
                component.referencePlacements = currentPlacements
            case .cancel:
                cancel(key)
            }
        }
    }

    func cancelAll() {
        lifecycle.cancelAll()
        for component in active.values {
            component.container.removeAllAnimations()
            component.container.removeFromSuperlayer()
            component.annotationViews.forEach { $0.setGooeyContentHidden(false) }
        }
        active.removeAll()
    }

    private func cancel(_ key: MapLibrePinGooeyTransitionKey) {
        lifecycle.cancel(key)
        guard let component = active.removeValue(forKey: key) else { return }
        component.container.removeAllAnimations()
        component.container.removeFromSuperlayer()
        component.annotationViews.forEach { $0.setGooeyContentHidden(false) }
    }

    private func finish(_ key: MapLibrePinGooeyTransitionKey, generation: Int) {
        guard lifecycle.isCurrent(key, generation: generation),
              let component = active.removeValue(forKey: key) else { return }
        lifecycle.finish(key, generation: generation)
        component.container.removeAllAnimations()
        component.container.removeFromSuperlayer()
        component.annotationViews.forEach { $0.setGooeyContentHidden(false) }
    }

    private func outerFillColor(for showsAccent: Bool) -> UIColor {
        switch MapLibrePinGooeyStyle.outerFillRole(showsAccent: showsAccent) {
        case .white: UIColor.white
        case .accent: accentColor
        }
    }

    private func nearlyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 0.5
            && abs(lhs.minY - rhs.minY) <= 0.5
            && abs(lhs.width - rhs.width) <= 0.5
            && abs(lhs.height - rhs.height) <= 0.5
    }

    private func pathAnimation(values: [CGPath]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "path")
        animation.values = values
        animation.keyTimes = (0..<values.count).map {
            NSNumber(value: Double($0) / Double(max(1, values.count - 1)))
        }
        animation.calculationMode = .linear
        animation.duration = MapLibrePinTransitionGeometry.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.isRemovedOnCompletion = true
        return animation
    }

    private func addClarityLayers(
        to container: CALayer,
        descriptor: MapLibrePinGooeyTransitionDescriptor,
        previous: MapLibrePinPartitionSnapshot,
        current: MapLibrePinPartitionSnapshot,
        symbolName: ([UUID]) -> String?,
        localOrigin: CGPoint
    ) {
        let members = Set(descriptor.key.orderedMemberIDs)
        let sources = previous.placements.filter {
            !members.isDisjoint(with: Set($0.orderedMemberIDs))
        }
        let targets = current.placements.filter {
            !members.isDisjoint(with: Set($0.orderedMemberIDs))
        }
        for source in sources {
            addClarity(
                source,
                to: container,
                symbolName: symbolName(source.orderedMemberIDs),
                localOrigin: localOrigin,
                appearing: false
            )
        }
        for target in targets {
            addClarity(
                target,
                to: container,
                symbolName: symbolName(target.orderedMemberIDs),
                localOrigin: localOrigin,
                appearing: true
            )
        }
    }

    private func addClarity(
        _ snapshot: MapLibrePinVisualSnapshot,
        to container: CALayer,
        symbolName: String?,
        localOrigin: CGPoint,
        appearing: Bool
    ) {
        let localFrame = snapshot.numberFrame.offsetBy(dx: -localOrigin.x, dy: -localOrigin.y)
        let font = UIFont.systemFont(ofSize: 16, weight: .medium)
        let textLayer = CATextLayer()
        textLayer.frame = CGRect(
            x: localFrame.minX,
            y: localFrame.midY - ceil(font.lineHeight) / 2,
            width: localFrame.width,
            height: ceil(font.lineHeight)
        )
        textLayer.string = snapshot.labelText
        textLayer.alignmentMode = .center
        textLayer.foregroundColor = UIColor.black.cgColor
        textLayer.font = font
        textLayer.fontSize = 16
        textLayer.contentsScale = traitCollection.displayScale
        textLayer.truncationMode = .end
        container.addSublayer(textLayer)
        addOpacityAnimation(to: textLayer, appearing: appearing)

        guard snapshot.showsCategoryBubble else { return }
        let categoryFrame = CGRect(
            x: snapshot.numberFrame.midX - MapLibrePinPlacement.bubbleSize / 2,
            y: snapshot.numberFrame.minY - MapLibrePinPlacement.categoryGap
                - MapLibrePinPlacement.bubbleSize,
            width: MapLibrePinPlacement.bubbleSize,
            height: MapLibrePinPlacement.bubbleSize
        ).offsetBy(dx: -localOrigin.x, dy: -localOrigin.y)
        let background = CAShapeLayer()
        background.frame = container.bounds
        background.fillColor = UIColor.white.cgColor
        background.strokeColor = accentColor.cgColor
        background.lineWidth = snapshot.isHighlighted ? 2 : 0
        let categoryCorner = snapshot.pointingCorner == .topLeft
                || snapshot.pointingCorner == .topRight
            ? snapshot.pointingCorner
            : nil
        background.path = MapLibrePinCornerTransitionGeometry.path(
            in: categoryFrame.insetBy(dx: 1, dy: 1),
            pointingCorner: categoryCorner
        )
        container.addSublayer(background)
        addOpacityAnimation(to: background, appearing: appearing)

        let iconLayer = CALayer()
        iconLayer.frame = categoryFrame.insetBy(dx: 8, dy: 8)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.contentsScale = traitCollection.displayScale
        let image = MapLibrePinCategoryIcon.image(
            symbolName: symbolName ?? "mappin"
        )?.withTintColor(.black, renderingMode: .alwaysOriginal)
        iconLayer.contents = rasterized(image, size: iconLayer.bounds.size)?.cgImage
        container.addSublayer(iconLayer)
        addOpacityAnimation(to: iconLayer, appearing: appearing)
    }

    private func addOpacityAnimation(to layer: CALayer, appearing: Bool) {
        layer.opacity = appearing ? 1 : 0
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = appearing ? [0, 0, 1] : [1, 0, 0]
        animation.keyTimes = [0, 0.55, 1]
        animation.duration = MapLibrePinTransitionGeometry.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: "gooey.clarity")
    }

    private func translated(
        _ path: CGPath?,
        from oldOrigin: CGPoint,
        to newOrigin: CGPoint
    ) -> CGPath? {
        guard let path else { return nil }
        var transform = CGAffineTransform(
            translationX: oldOrigin.x - newOrigin.x,
            y: oldOrigin.y - newOrigin.y
        )
        return path.copy(using: &transform)
    }

    private func hasSameTopology(_ lhs: CGPath, _ rhs: CGPath) -> Bool {
        pathElementTypes(lhs) == pathElementTypes(rhs)
    }

    private func pathElementTypes(_ path: CGPath) -> [CGPathElementType] {
        var result: [CGPathElementType] = []
        path.applyWithBlock { result.append($0.pointee.type) }
        return result
    }

    private func rasterized(_ image: UIImage?, size: CGSize) -> UIImage? {
        guard let image,
              image.size.width > 0,
              image.size.height > 0,
              size.width > 0,
              size.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let scale = min(size.width / image.size.width, size.height / image.size.height)
            let fittedSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let fitted = CGRect(
                x: (size.width - fittedSize.width) / 2,
                y: (size.height - fittedSize.height) / 2,
                width: fittedSize.width,
                height: fittedSize.height
            )
            image.draw(in: fitted)
        }
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
    /// Stable identity for auto-focus refinement. Coordinates alone are
    /// ambiguous when two itinerary POIs share the same location.
    let cameraFocusPointID: UUID?
    let cameraRequestID: Int
    /// SwiftUI's global/window coordinate for the live timeline upper edge.
    /// `nil` means the overlay is hidden and the floating tab bar is the live
    /// bottom obstruction instead.
    let timelineTopInGlobal: CGFloat?
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
        let mapView = MapLibreGeometryTrackingMapView(frame: .zero, styleURL: styleURL)
        mapView.onViewportGeometryChanged = {
            [weak coordinator = context.coordinator, weak mapView] geometry in
            guard let coordinator, let mapView else { return }
            coordinator.viewportGeometryDidChange(geometry, on: mapView)
        }
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
        context.coordinator.installGooeyOverlay(on: mapView)

        context.coordinator.updateContent(
            on: mapView,
            points: points,
            selectedIndex: selectedIndex,
            timelineTopInGlobal: timelineTopInGlobal,
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
            timelineTopInGlobal: timelineTopInGlobal,
            routeRefreshID: routeRefreshID,
            onRouteLoadingChanged: onRouteLoadingChanged,
            onViewportStateChanged: onViewportStateChanged
        )
        context.coordinator.updateCamera(
            on: mapView,
            points: points,
            focus: cameraFocus,
            focusPointID: cameraFocusPointID,
            requestID: cameraRequestID,
            bottomInset: overviewBottomInset
        )
    }

    static func dismantleUIView(_ uiView: MLNMapView, coordinator: Coordinator) {
        coordinator.tearDownGooeyOverlay()
        uiView.delegate = nil
        (uiView as? MapLibreGeometryTrackingMapView)?.onViewportGeometryChanged = nil
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
        private var hasAppliedPinPlacements = false
        private var pinSnapshotGeneration = 0
        private var pinPartitionSnapshot: MapLibrePinPartitionSnapshot?
        private weak var gooeyOverlay: MapLibrePinGooeyOverlayView?
        private var reduceMotionObserver: NSObjectProtocol?
        private var timelineTopInGlobal: CGFloat?
        private var lastPlacementGeometry: MapLibreEdgePinViewportGeometry?
        private var previousEdgeGroups: [[UUID]] = []
        private var pendingAutoFocusPointID: UUID?
        private var pendingAutoFocusCoordinate: CLLocationCoordinate2D?
        /// Keep enough surrounding roads and nearby POIs in view while a
        /// bottom swiper card is selected; 16 was too close for this screen.
        private let poiSwiperFocusZoomLevel: Double = 13.8

        fileprivate func installGooeyOverlay(on mapView: MLNMapView) {
            if let overlay = gooeyOverlay, overlay.superview === mapView {
                mapView.bringSubviewToFront(overlay)
                return
            }
            let overlay = MapLibrePinGooeyOverlayView(frame: mapView.bounds)
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            mapView.addSubview(overlay)
            mapView.bringSubviewToFront(overlay)
            gooeyOverlay = overlay
            reduceMotionObserver = NotificationCenter.default.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard UIAccessibility.isReduceMotionEnabled else { return }
                    self?.gooeyOverlay?.cancelAll()
                }
            }
        }

        fileprivate func tearDownGooeyOverlay() {
            if let reduceMotionObserver {
                NotificationCenter.default.removeObserver(reduceMotionObserver)
                self.reduceMotionObserver = nil
            }
            gooeyOverlay?.cancelAll()
            gooeyOverlay?.removeFromSuperview()
            gooeyOverlay = nil
            pinPartitionSnapshot = nil
        }

        fileprivate func viewportGeometryDidChange(
            _ geometry: MapLibreEdgePinViewportGeometry,
            on mapView: MLNMapView
        ) {
            guard geometry != lastPlacementGeometry else { return }
            lastPlacementGeometry = geometry
            guard geometry.mapBounds.width > 1, geometry.mapBounds.height > 1 else { return }
            // Avoid changing annotation coordinates inside UIKit's active
            // layout pass. The signature check also coalesces duplicate
            // SwiftUI/updateUIView and layoutSubviews notifications.
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView,
                      geometry == self.lastPlacementGeometry else { return }
                self.updatePinPlacements(on: mapView, reason: .viewport)
                self.reportViewportState(on: mapView, isMoving: self.isMapRegionChanging)
            }
        }

        fileprivate func updateContent(
            on mapView: MLNMapView,
            points: [TodayMapPoint],
            selectedIndex: Int?,
            timelineTopInGlobal: CGFloat?,
            routeRefreshID: Int,
            onRouteLoadingChanged: @escaping (Bool) -> Void,
            onViewportStateChanged: @escaping (Bool, Bool) -> Void
        ) {
            self.onViewportStateChanged = onViewportStateChanged
            let refreshRequested = routeRefreshID != handledRouteRefreshID
            let pointsChanged = points != renderedPoints
            let selectionChanged = selectedIndex != renderedSelection
            let contentChanged = pointsChanged || selectionChanged
            let safeAreaChanged = !MapLibreEdgePinGeometry.nearlyEqual(
                self.timelineTopInGlobal,
                timelineTopInGlobal
            )
            let placementGeometry = MapLibreEdgePinViewportGeometry(
                mapBounds: mapView.bounds,
                windowBounds: mapView.window?.bounds ?? .zero
            )
            let placementGeometryChanged = placementGeometry != lastPlacementGeometry
            self.timelineTopInGlobal = timelineTopInGlobal
            lastPlacementGeometry = placementGeometry
            guard contentChanged
                    || refreshRequested
                    || safeAreaChanged
                    || placementGeometryChanged else {
                reportViewportState(on: mapView, isMoving: isMapRegionChanging)
                return
            }
            let forceRouteRefresh = refreshRequested && routeRefreshID > 0

            if pointsChanged || (selectionChanged && !safeAreaChanged) {
                // Restore any temporarily hidden annotation content before
                // MapLibre removes or reuses those views.
                gooeyOverlay?.cancelAll()
            }
            if pointsChanged {
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
            } else if selectionChanged {
                for annotation in pointAnnotations {
                    annotation.isHighlighted = selectedIndex == annotation.index
                }
            }

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
            let updateReason = MapLibrePinPlacementUpdateReason.resolve(
                hasPresentedInitialState: hasAppliedPinPlacements,
                pointsChanged: pointsChanged,
                safeAreaChanged: safeAreaChanged,
                selectionChanged: selectionChanged
            )
            updatePinPlacements(
                on: mapView,
                reason: updateReason,
                animated: safeAreaChanged && !pointsChanged,
                animatePointingCorner: !pointsChanged
            )
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
                    self.updatePinPlacements(on: mapView, reason: .viewport)
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
            focusPointID: UUID?,
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
            cancelAutoFocusRefinement()
            let animated = requestID > 0
            overviewBottomInset = bottomInset

            if let focus {
                isShowingRouteOverview = false
                let displayFocus = MapLibreCoordinateTransform.displayCoordinate(for: focus)
                let targetZoom = points.count == 1 ? 12 : poiSwiperFocusZoomLevel
                let cameraWillChange = abs(mapView.centerCoordinate.latitude - displayFocus.latitude)
                        > 0.000_000_1
                    || abs(mapView.centerCoordinate.longitude - displayFocus.longitude)
                        > 0.000_000_1
                    || abs(mapView.zoomLevel - targetZoom) > 0.001
                if let focusPointID,
                   points.contains(where: { $0.id == focusPointID }) {
                    pendingAutoFocusPointID = focusPointID
                    pendingAutoFocusCoordinate = displayFocus
                }
                if animated { isProgrammaticCameraChange = true }
                mapView.setCenter(
                    displayFocus,
                    zoomLevel: targetZoom,
                    animated: animated
                )
                // MapLibre may skip `regionDidChange` for a no-op camera
                // request (for example tapping the already centered card).
                // The current placement is already valid, so refine now.
                if !cameraWillChange {
                    updatePinPlacements(on: mapView, reason: .autoFocus)
                    if !continueAutoFocusRefinementIfNeeded(on: mapView) {
                        isProgrammaticCameraChange = false
                    }
                }
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
            let placement = pinPlacements[annotation.pointID]
                ?? regularPinPlacement(for: annotation, on: mapView)
            view.configure(
                with: annotation,
                placement: placement
            )
            view.isHidden = hasAppliedPinPlacements && pinPlacements[annotation.pointID] == nil
            return view
        }

        func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            isMapRegionChanging = false
            updatePinPlacements(
                on: mapView,
                reason: pendingAutoFocusPointID == nil ? .viewport : .autoFocus
            )
            reportViewportState(on: mapView, isMoving: false)
            if !continueAutoFocusRefinementIfNeeded(on: mapView) {
                isProgrammaticCameraChange = false
            }
        }

        /// `regionDidChangeAnimated` only fires after a pan/zoom settles. Keep
        /// edge proxies recomputed during the gesture as well, otherwise their
        /// temporary map coordinates drift with the map until the user's
        /// finger lifts.
        func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            isMapRegionChanging = true
            let userIsInteracting = mapView.gestureRecognizers?.contains {
                $0.state == .began || $0.state == .changed
            } == true
            if userIsInteracting {
                cancelAutoFocusRefinement()
                isProgrammaticCameraChange = false
            }
            if !isProgrammaticCameraChange {
                reportViewportState(on: mapView, isMoving: true)
            }
            updateEdgePinPlacementsDuringGesture(on: mapView)
        }

        /// A selected POI can still be represented by a merged numeric pill
        /// at the normal swiper zoom. Keep the same POI centered and step in
        /// until its represented placement becomes a singleton. Exact
        /// duplicate coordinates stop safely at MapLibre's maximum zoom.
        private func continueAutoFocusRefinementIfNeeded(on mapView: MLNMapView) -> Bool {
            guard let pointID = pendingAutoFocusPointID,
                  let coordinate = pendingAutoFocusCoordinate else {
                return false
            }
            guard let placement = pinPlacements.values.first(where: {
                $0.representedMemberIDs.contains(pointID)
            }) else {
                cancelAutoFocusRefinement()
                return false
            }
            guard placement.representedMemberIDs.count > 1,
                  let nextZoom = MapLibreAutoFocusZoomPolicy.nextZoom(
                    currentZoom: mapView.zoomLevel,
                    maximumZoom: mapView.maximumZoomLevel
                  ) else {
                cancelAutoFocusRefinement()
                return false
            }

            isProgrammaticCameraChange = true
            mapView.setCenter(
                coordinate,
                zoomLevel: nextZoom,
                animated: true
            )
            return true
        }

        private func cancelAutoFocusRefinement() {
            pendingAutoFocusPointID = nil
            pendingAutoFocusCoordinate = nil
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

        private func updatePinPlacements(
            on mapView: MLNMapView,
            reason: MapLibrePinPlacementUpdateReason,
            animated: Bool = false,
            animatePointingCorner: Bool = true
        ) {
            let placements = calculatedPinPlacements(on: mapView)
            applyPinPlacements(
                placements,
                on: mapView,
                refreshing: Set(pointAnnotations.map(\.pointID)),
                reason: reason,
                animated: animated,
                animatePointingCorner: animatePointingCorner
            )
            draggingEdgePinIDs.removeAll()
        }

        /// Recompute both edge and ordinary collision clusters during a
        /// gesture. Source points always come from `sourceCoordinate`, never
        /// from proxy annotation coordinates, so this cannot feed back drift.
        private func updateEdgePinPlacementsDuringGesture(on mapView: MLNMapView) {
            guard !pointAnnotations.isEmpty else { return }
            let placements = calculatedPinPlacements(on: mapView)
            draggingEdgePinIDs = Set(placements.values
                .filter(\.isEdgePinned)
                .flatMap(\.representedMemberIDs))
            applyPinPlacements(
                placements,
                on: mapView,
                refreshing: Set(pointAnnotations.map(\.pointID)),
                reason: .viewport,
                animated: false,
                animatePointingCorner: true
            )
        }

        private func applyPinPlacements(
            _ placements: [UUID: MapLibrePinPlacement],
            on mapView: MLNMapView,
            refreshing refreshedIDs: Set<UUID>,
            reason: MapLibrePinPlacementUpdateReason,
            animated: Bool,
            animatePointingCorner: Bool
        ) {
            let previousPlacements = pinPlacements
            let hadPresentedInitialState = hasAppliedPinPlacements
            let previousSnapshot = pinPartitionSnapshot
            pinSnapshotGeneration &+= 1
            let currentSnapshot = partitionSnapshot(
                placements: placements,
                generation: pinSnapshotGeneration
            )
            let gooeyTransitions = MapLibrePinGooeyTransitionResolver.transitions(
                previous: previousSnapshot,
                current: currentSnapshot,
                reason: reason,
                hasPresentedInitialState: hadPresentedInitialState
            )
            pinPartitionSnapshot = currentSnapshot
            let previousPlacementByMemberID = Dictionary(
                uniqueKeysWithValues: previousPlacements.values.flatMap { placement in
                    placement.representedMemberIDs.map { ($0, placement) }
                }
            )
            pinPlacements = placements
            hasAppliedPinPlacements = true

            for annotation in pointAnnotations {
                guard let placement = placements[annotation.pointID] else {
                    // A merged member is rendered only by its stable
                    // representative. Restore its immutable source coordinate
                    // and hide any old proxy view left from a prior layout.
                    if annotation.coordinate.latitude != annotation.sourceCoordinate.latitude
                        || annotation.coordinate.longitude != annotation.sourceCoordinate.longitude {
                        annotation.coordinate = annotation.sourceCoordinate
                    }
                    if refreshedIDs.contains(annotation.pointID) {
                        mapView.view(for: annotation)?.isHidden = true
                    }
                    continue
                }

                // Both edge pins and ordinary merged pills need a temporary
                // coordinate under their layout anchor. Geometry calculations
                // still use the immutable `sourceCoordinate` above.
                let usesProxyCoordinate = placement.representedMemberIDs.count > 1
                    || (placement.isEdgePinned
                        && (!isMapRegionChanging
                            || draggingEdgePinIDs.contains(annotation.pointID)))
                let displayedCoordinate = usesProxyCoordinate
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
                if let previousPlacement = previousPlacements[annotation.pointID]
                    ?? previousPlacementByMemberID[annotation.pointID] {
                    view.animateTransition(
                        from: previousPlacement,
                        to: placement,
                        animateMovement: MapLibrePinTransitionGeometry.shouldAnimateMovement(
                            requested: animated,
                            wasEdgePinned: previousPlacement.isEdgePinned,
                            isEdgePinned: placement.isEdgePinned
                        ),
                        animatePointingCorner: animatePointingCorner
                    )
                }
            }

            guard let overlay = gooeyOverlay else { return }
            overlay.frame = mapView.bounds
            mapView.bringSubviewToFront(overlay)
            let safeBounds = edgePinBounds(on: mapView)
            guard let previousSnapshot,
                  !UIAccessibility.isReduceMotionEnabled else {
                overlay.cancelAll()
                return
            }
            guard !gooeyTransitions.isEmpty else {
                if reason.allowsGooeyTransition,
                   MapLibrePinGooeyTransitionResolver.hasSameCanonicalPartition(
                        previousSnapshot,
                        currentSnapshot
                   ) {
                    overlay.updateActiveComponents(
                        current: currentSnapshot,
                        safeBounds: safeBounds
                    )
                } else {
                    overlay.cancelAll()
                }
                return
            }
            let annotationByID = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, $0)
            })
            overlay.play(
                gooeyTransitions,
                previous: previousSnapshot,
                current: currentSnapshot,
                safeBounds: safeBounds,
                symbolName: { memberIDs in
                    let annotations = memberIDs.compactMap { annotationByID[$0] }
                    return annotations.first(where: \.isHighlighted)?.categorySymbolName
                        ?? annotations.first?.categorySymbolName
                },
                finalViews: { descriptor in
                    let members = Set(descriptor.key.orderedMemberIDs)
                    return currentSnapshot.placements.compactMap { snapshot in
                        guard !members.isDisjoint(with: Set(snapshot.orderedMemberIDs)),
                              let annotation = annotationByID[snapshot.representativeID] else {
                            return nil
                        }
                        return mapView.view(for: annotation) as? MapLibreNumberedAnnotationView
                    }
                }
            )
        }

        private func partitionSnapshot(
            placements: [UUID: MapLibrePinPlacement],
            generation: Int
        ) -> MapLibrePinPartitionSnapshot {
            let annotationByID = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, $0)
            })
            let snapshots = placements.map { representativeID, placement in
                let numberFrame = CGRect(
                    x: placement.numberCenter.x - placement.labelSize.width / 2,
                    y: placement.numberCenter.y - placement.labelSize.height / 2,
                    width: placement.labelSize.width,
                    height: placement.labelSize.height
                )
                return MapLibrePinVisualSnapshot(
                    representativeID: representativeID,
                    orderedMemberIDs: placement.representedMemberIDs,
                    numberFrame: numberFrame,
                    labelText: placement.labelText
                        ?? annotationByID[representativeID].map { String($0.index + 1) }
                        ?? "",
                    isHighlighted: placement.isHighlighted,
                    showsCategoryBubble: placement.showsCategoryBubble,
                    pointingCorner: placement.pointingCorner
                )
            }.sorted { lhs, rhs in
                let lhsOrder = lhs.orderedMemberIDs.compactMap { annotationByID[$0]?.index }.min()
                    ?? .max
                let rhsOrder = rhs.orderedMemberIDs.compactMap { annotationByID[$0]?.index }.min()
                    ?? .max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return lhs.representativeID.uuidString < rhs.representativeID.uuidString
            }
            return MapLibrePinPartitionSnapshot(
                updateGeneration: generation,
                placements: snapshots
            )
        }

        private func calculatedPinPlacements(
            on mapView: MLNMapView
        ) -> [UUID: MapLibrePinPlacement] {
            guard mapView.bounds.width > 1, mapView.bounds.height > 1 else { return [:] }
            let edgeRect = edgePinBounds(on: mapView)
            let screenBounds = physicalScreenBounds(on: mapView)
            let screenCenter = physicalScreenCenter(on: mapView)
            let sourcePoints = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, mapView.convert($0.sourceCoordinate, toPointTo: mapView))
            })
            let regularPlacements: [UUID: MapLibrePinPlacement] = Dictionary(
                uniqueKeysWithValues: pointAnnotations.map { annotation in
                    let target = sourcePoints[annotation.pointID]!
                    return (
                        annotation.pointID,
                        regularPinPlacement(for: annotation, target: target)
                    )
                }
            )

            let edgeAnnotationIDs = Set(sourcePoints.compactMap { id, sourcePoint in
                MapLibreEdgePinTrigger.isOutsideScreen(
                    sourcePoint,
                    screenBounds: screenBounds
                ) ? id : nil
            })
            let regularMembers = pointAnnotations.compactMap { annotation -> MapLibreRegularPinMember? in
                guard !edgeAnnotationIDs.contains(annotation.pointID),
                      let placement = regularPlacements[annotation.pointID] else { return nil }
                return MapLibreRegularPinMember(
                    id: annotation.pointID,
                    displayOrder: annotation.index,
                    numberCenter: placement.numberCenter,
                    renderedFrame: placement.labelRect,
                    isHighlighted: annotation.isHighlighted
                )
            }
            let fittingRegularClusters = MapLibreRegularPinGrouping.clusters(
                members: regularMembers
            )

            let allEdgeMembers = pointAnnotations.compactMap { annotation -> MapLibreProjectedEdgePinMember? in
                guard let sourcePoint = sourcePoints[annotation.pointID] else { return nil }
                return MapLibreProjectedEdgePinMember(
                    id: annotation.pointID,
                    displayOrder: annotation.index,
                    sourcePoint: sourcePoint,
                    isHighlighted: annotation.isHighlighted
                )
            }
            let resolved = MapLibreFinalPinGrouping.resolve(
                regularClusters: fittingRegularClusters,
                initialEdgeMemberIDs: edgeAnnotationIDs,
                allEdgeMembers: allEdgeMembers,
                safeRect: edgeRect,
                screenCenter: screenCenter,
                previousEdgeGroups: previousEdgeGroups
            )
            previousEdgeGroups = resolved.edge.map { $0.members.map(\.id) }
            let annotationByID = Dictionary(uniqueKeysWithValues: pointAnnotations.map {
                ($0.pointID, $0)
            })

            var result: [UUID: MapLibrePinPlacement] = [:]
            for cluster in resolved.regular {
                guard let representative = cluster.members.first,
                      let originalPlacement = regularPlacements[representative.id] else { continue }
                if cluster.members.count == 1 {
                    result[representative.id] = originalPlacement
                } else {
                    let highlightedSymbol = cluster.members
                        .first(where: \.isHighlighted)
                        .flatMap { annotationByID[$0.id]?.categorySymbolName }
                    result[representative.id] = MapLibrePinPlacement(
                        anchorPoint: cluster.numberCenter,
                        numberCenter: cluster.numberCenter,
                        isHighlighted: cluster.isHighlighted,
                        showsCategoryBubble: false,
                        isEdgePinned: false,
                        pointingCorner: nil,
                        highlightedCategorySymbolName: highlightedSymbol,
                        labelText: cluster.labelText,
                        labelSize: cluster.labelSize,
                        representedMemberIDs: cluster.members.map(\.id)
                    )
                }
            }
            for cluster in resolved.edge {
                guard let annotation = annotationByID[cluster.representativeID] else { continue }
                let highlightedSymbol = cluster.members
                    .first(where: \.isHighlighted)
                    .flatMap { annotationByID[$0.id]?.categorySymbolName }
                result[annotation.pointID] = edgePinPlacement(
                    for: annotation,
                    numberCenter: cluster.numberCenter,
                    pointingCorner: cluster.pointingCorner,
                    isHighlighted: cluster.containsHighlighted,
                    showsCategoryBubble: cluster.rendersHighlighted,
                    highlightedCategorySymbolName: highlightedSymbol,
                    labelText: cluster.labelText,
                    labelSize: cluster.labelSize,
                    representedMemberIDs: cluster.members.map(\.id)
                )
            }
            return result
        }

        /// Safe bounds for the complete rendered outer frame. SwiftUI's
        /// `.global` frame is in the hosting window coordinate space. Convert
        /// that window rect into MapLibre local coordinates instead of
        /// assuming the map's origin is the window origin.
        private func edgePinBounds(on mapView: MLNMapView) -> CGRect {
            guard let window = mapView.window else {
                return MapLibreEdgePinGeometry.safeOuterRect(
                    screenBounds: mapView.bounds,
                    timelineTop: nil
                )
            }
            let safeWindowRect = MapLibreEdgePinGeometry.safeOuterRect(
                screenBounds: window.bounds,
                timelineTop: timelineTopInGlobal
            )
            guard !safeWindowRect.isNull else { return .null }
            let localRect = mapView.convert(safeWindowRect, from: window)
            let clipped = localRect.intersection(mapView.bounds)
            guard !clipped.isNull,
                  clipped.width >= MapLibrePinPlacement.bubbleSize,
                  clipped.height >= MapLibrePinPlacement.bubbleSize else {
                return .null
            }
            return clipped
        }

        private func physicalScreenCenter(on mapView: MLNMapView) -> CGPoint {
            guard let window = mapView.window else {
                return CGPoint(x: mapView.bounds.midX, y: mapView.bounds.midY)
            }
            return mapView.convert(
                CGPoint(x: window.bounds.midX, y: window.bounds.midY),
                from: window
            )
        }

        private func physicalScreenBounds(on mapView: MLNMapView) -> CGRect {
            guard let window = mapView.window else { return mapView.bounds }
            return mapView.convert(window.bounds, from: window)
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
                isHighlighted: annotation.isHighlighted,
                memberID: annotation.pointID
            )
        }

        private func edgePinPlacement(
            for annotation: MapLibreNumberedAnnotation,
            numberCenter: CGPoint,
            pointingCorner: MapLibreEdgePinPointingCorner?,
            isHighlighted: Bool,
            showsCategoryBubble: Bool,
            highlightedCategorySymbolName: String?,
            labelText: String? = nil,
            labelSize: CGSize = CGSize(
                width: MapLibrePinPlacement.bubbleSize,
                height: MapLibrePinPlacement.bubbleSize
            ),
            representedMemberIDs: [UUID]
        ) -> MapLibrePinPlacement {
            return MapLibrePinPlacement(
                anchorPoint: numberCenter,
                numberCenter: numberCenter,
                isHighlighted: isHighlighted,
                showsCategoryBubble: showsCategoryBubble,
                isEdgePinned: true,
                pointingCorner: pointingCorner,
                highlightedCategorySymbolName: highlightedCategorySymbolName,
                labelText: labelText,
                labelSize: labelSize,
                representedMemberIDs: representedMemberIDs
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

enum MapLibrePinCategoryIconSource: Equatable {
    case asset(String)
    case system(String)
}

enum MapLibrePinCategoryIcon {
    static func sources(symbolName: String) -> [MapLibrePinCategoryIconSource] {
        [
            .asset("icon-camera-outline"),
            .asset("icon-camera"),
            .asset("icon-landscape-outline"),
            .system(symbolName)
        ]
    }

    static func image(symbolName: String) -> UIImage? {
        for source in sources(symbolName: symbolName) {
            switch source {
            case let .asset(name):
                if let image = UIImage(named: name) { return image }
            case let .system(name):
                if let image = UIImage(
                    systemName: name,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
                ) {
                    return image
                }
            }
        }
        return nil
    }
}

private final class MapLibreNumberedAnnotation: MLNPointAnnotation {
    let pointID: UUID
    let index: Int
    var isHighlighted: Bool
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

enum MapLibrePinTransitionGeometry {
    static let duration: TimeInterval = 0.28

    /// After MapLibre snaps the annotation to its new proxy coordinate, this
    /// translation puts the view back over its previous screen position. The
    /// view then animates to identity, so only obstruction-driven movement is
    /// eased while direct map gestures remain frame-accurate.
    static func translation(from oldCenter: CGPoint, to newCenter: CGPoint) -> CGAffineTransform {
        CGAffineTransform(
            translationX: oldCenter.x - newCenter.x,
            y: oldCenter.y - newCenter.y
        )
    }

    static func shouldAnimateMovement(
        requested: Bool,
        wasEdgePinned: Bool,
        isEdgePinned: Bool
    ) -> Bool {
        requested || wasEdgePinned != isEdgePinned
    }
}

enum MapLibreAutoFocusZoomPolicy {
    static let zoomStep: Double = 1

    static func nextZoom(
        currentZoom: Double,
        maximumZoom: Double
    ) -> Double? {
        guard currentZoom < maximumZoom - 0.001 else { return nil }
        return min(maximumZoom, currentZoom + zoomStep)
    }
}

struct MapLibrePinCornerRadii: Equatable {
    let topLeft: CGFloat
    let topRight: CGFloat
    let bottomLeft: CGFloat
    let bottomRight: CGFloat
}

enum MapLibrePinCornerTransitionGeometry {
    /// A pointing corner is the same bubble shape with exactly one radius
    /// reduced to zero. Keeping all four path segments present lets Core
    /// Animation interpolate the corner instead of switching masks abruptly.
    static func radii(
        pointingCorner: MapLibreEdgePinPointingCorner?,
        radius: CGFloat
    ) -> MapLibrePinCornerRadii {
        MapLibrePinCornerRadii(
            topLeft: pointingCorner == .topLeft ? 0 : radius,
            topRight: pointingCorner == .topRight ? 0 : radius,
            bottomLeft: pointingCorner == .bottomLeft ? 0 : radius,
            bottomRight: pointingCorner == .bottomRight ? 0 : radius
        )
    }

    static func path(
        in rect: CGRect,
        pointingCorner: MapLibreEdgePinPointingCorner?
    ) -> CGPath {
        let maximumRadius = min(rect.width, rect.height) / 2
        let radii = radii(pointingCorner: pointingCorner, radius: maximumRadius)
        let path = CGMutablePath()

        path.move(to: CGPoint(x: rect.minX + radii.topLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radii.topRight, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radii.topRight),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radii.bottomRight))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radii.bottomRight, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radii.bottomLeft, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radii.bottomLeft),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radii.topLeft))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radii.topLeft, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()
        return path
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
    /// The orange selection border remains for merged active groups, while
    /// this flag controls the separate category/icon bubble.
    let showsCategoryBubble: Bool
    let isEdgePinned: Bool
    /// Top/bottom endpoint pins expose one square outer corner as the visual
    /// pointer toward the off-screen source. Side-edge pins remain capsules.
    let pointingCorner: MapLibreEdgePinPointingCorner?
    /// The selected member can differ from the stable representative that
    /// owns the visible annotation view.
    let highlightedCategorySymbolName: String?
    /// `nil` for a standard single-number pin. Edge clusters supply a joined
    /// value such as "2.4.9" and widen only that one pill.
    let labelText: String?
    let labelSize: CGSize
    /// Source POIs represented by this visible annotation. A merged pill is
    /// rendered only by the first stable itinerary member.
    let representedMemberIDs: [UUID]

    var topExtent: CGFloat {
        showsCategoryBubble ? Self.highlightedTopExtent : labelSize.height / 2
    }

    var bottomExtent: CGFloat { labelSize.height / 2 }

    var labelRect: CGRect {
        Self.labelRect(
            numberCenter: numberCenter,
            labelSize: labelSize,
            showsCategoryBubble: showsCategoryBubble
        )
    }

    static func labelRect(
        numberCenter: CGPoint,
        labelSize: CGSize,
        showsCategoryBubble: Bool
    ) -> CGRect {
        MapLibreEdgePinGeometry.renderedOuterFrame(
            numberCenter: numberCenter,
            labelSize: labelSize,
            topExtent: showsCategoryBubble ? Self.highlightedTopExtent : labelSize.height / 2,
            bottomExtent: labelSize.height / 2
        )
    }

    static func edgeLabelSize(for text: String) -> CGSize {
        MapLibrePinLabelGeometry.size(for: text)
    }

    static func regular(
        target: CGPoint,
        isHighlighted: Bool,
        memberID: UUID
    ) -> Self {
        return Self(
            anchorPoint: target,
            numberCenter: target,
            isHighlighted: isHighlighted,
            showsCategoryBubble: isHighlighted,
            isEdgePinned: false,
            pointingCorner: nil,
            highlightedCategorySymbolName: nil,
            labelText: nil,
            labelSize: CGSize(width: bubbleSize, height: bubbleSize),
            representedMemberIDs: [memberID]
        )
    }
}

private final class MapLibrePinShapeView: UIView {
    override class var layerClass: AnyClass { CAShapeLayer.self }

    private var shapeLayer: CAShapeLayer { layer as! CAShapeLayer }
    private(set) var pointingCorner: MapLibreEdgePinPointingCorner?

    var fillColor: UIColor = .white {
        didSet { shapeLayer.fillColor = fillColor.cgColor }
    }

    var strokeColor: UIColor = .clear {
        didSet { shapeLayer.strokeColor = strokeColor.cgColor }
    }

    var strokeWidth: CGFloat = 0 {
        didSet { shapeLayer.lineWidth = strokeWidth }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        shapeLayer.fillColor = fillColor.cgColor
        shapeLayer.strokeColor = strokeColor.cgColor
        shapeLayer.lineWidth = strokeWidth
    }

    required init?(coder: NSCoder) {
        nil
    }

    func setPointingCorner(_ corner: MapLibreEdgePinPointingCorner?) {
        pointingCorner = corner
        shapeLayer.path = shapePath(for: corner)
    }

    func animatePointingCorner(
        from oldCorner: MapLibreEdgePinPointingCorner?,
        to newCorner: MapLibreEdgePinPointingCorner?
    ) {
        pointingCorner = newCorner
        let newPath = shapePath(for: newCorner)
        guard oldCorner != newCorner, !UIAccessibility.isReduceMotionEnabled else {
            shapeLayer.removeAnimation(forKey: "pointingCorner")
            shapeLayer.path = newPath
            return
        }

        let visiblePath: CGPath
        if shapeLayer.animation(forKey: "pointingCorner") != nil,
           let presentationPath = shapeLayer.presentation()?.path {
            visiblePath = presentationPath
        } else {
            visiblePath = shapePath(for: oldCorner)
        }
        shapeLayer.path = newPath
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = visiblePath
        animation.toValue = newPath
        animation.duration = MapLibrePinTransitionGeometry.duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        shapeLayer.add(animation, forKey: "pointingCorner")
    }

    private func shapePath(for corner: MapLibreEdgePinPointingCorner?) -> CGPath {
        let inset = strokeWidth / 2
        return MapLibrePinCornerTransitionGeometry.path(
            in: bounds.insetBy(dx: inset, dy: inset),
            pointingCorner: corner
        )
    }
}

private final class MapLibreNumberedAnnotationView: MLNAnnotationView {
    static let reuseIdentifier = "MapLibreTodayNumberedPOI"

    private let numberBackground = MapLibrePinShapeView()
    private let categoryBackground = MapLibrePinShapeView()
    private let numberLabel = UILabel()
    private let categoryImageView = UIImageView()
    private var isGooeyContentHidden = false

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        scalesWithViewingDistance = false
        backgroundColor = .clear

        numberBackground.fillColor = .white
        categoryBackground.fillColor = .white

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

    override func prepareForReuse() {
        super.prepareForReuse()
        isGooeyContentHidden = false
        applyGooeyContentVisibility()
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
        numberLabel.frame = numberFrame
        numberLabel.text = placement.labelText ?? String(annotation.index + 1)

        let accentColor = UIColor(red: 1, green: 110 / 255, blue: 0, alpha: 1)
        numberBackground.strokeColor = accentColor
        numberBackground.strokeWidth = placement.isHighlighted ? 2 : 0
        categoryBackground.strokeColor = accentColor
        categoryBackground.strokeWidth = placement.isHighlighted ? 2 : 0

        if placement.showsCategoryBubble {
            let categoryFrame = CGRect(
                x: localNumberCenter.x - bubbleSize / 2,
                y: numberFrame.minY - MapLibrePinPlacement.categoryGap - bubbleSize,
                width: bubbleSize,
                height: bubbleSize
            )
            categoryBackground.frame = categoryFrame
            categoryImageView.frame = categoryFrame.insetBy(dx: 8, dy: 8)
            categoryImageView.image = MapLibrePinCategoryIcon.image(
                symbolName: placement.highlightedCategorySymbolName
                    ?? annotation.categorySymbolName
            )?.withRenderingMode(.alwaysTemplate)
            numberBackground.isHidden = false
            categoryBackground.isHidden = false
            categoryImageView.isHidden = false
        } else {
            numberBackground.isHidden = false
            categoryBackground.isHidden = true
            categoryImageView.isHidden = true
        }
        applyPointingCorner(
            placement.pointingCorner,
            showsCategoryBubble: placement.showsCategoryBubble
        )

        let title = annotation.title ?? "地点"
        if placement.representedMemberIDs.count > 1,
           let labelText = placement.labelText {
            accessibilityLabel = "行程地点 \(labelText)"
        } else {
        accessibilityLabel = placement.isHighlighted ? "正在查看，\(title)" : title
        }
        transform = .identity
        applyGooeyContentVisibility()
    }

    func setGooeyContentHidden(_ hidden: Bool) {
        isGooeyContentHidden = hidden
        applyGooeyContentVisibility()
    }

    private func applyGooeyContentVisibility() {
        let alpha: CGFloat = isGooeyContentHidden ? 0 : 1
        numberBackground.alpha = alpha
        categoryBackground.alpha = alpha
        numberLabel.alpha = alpha
        categoryImageView.alpha = alpha
    }

    func animateTransition(
        from oldPlacement: MapLibrePinPlacement,
        to newPlacement: MapLibrePinPlacement,
        animateMovement: Bool,
        animatePointingCorner: Bool
    ) {
        if animatePointingCorner {
            let oldCorners = shapeCorners(for: oldPlacement)
            let newCorners = shapeCorners(for: newPlacement)
            numberBackground.animatePointingCorner(
                from: oldCorners.number,
                to: newCorners.number
            )
            categoryBackground.animatePointingCorner(
                from: oldCorners.category,
                to: newCorners.category
            )
        }

        guard animateMovement, !UIAccessibility.isReduceMotionEnabled else { return }
        let translation = MapLibrePinTransitionGeometry.translation(
            from: oldPlacement.numberCenter,
            to: newPlacement.numberCenter
        )
        guard hypot(translation.tx, translation.ty) > 0.5 else { return }

        transform = translation
        UIView.animate(
            withDuration: MapLibrePinTransitionGeometry.duration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
            self.transform = .identity
        }
    }

    private func applyPointingCorner(
        _ pointingCorner: MapLibreEdgePinPointingCorner?,
        showsCategoryBubble: Bool
    ) {
        let corners = shapeCorners(
            pointingCorner: pointingCorner,
            showsCategoryBubble: showsCategoryBubble
        )
        numberBackground.setPointingCorner(corners.number)
        categoryBackground.setPointingCorner(corners.category)
    }

    private func shapeCorners(
        for placement: MapLibrePinPlacement
    ) -> (number: MapLibreEdgePinPointingCorner?, category: MapLibreEdgePinPointingCorner?) {
        shapeCorners(
            pointingCorner: placement.pointingCorner,
            showsCategoryBubble: placement.showsCategoryBubble
        )
    }

    private func shapeCorners(
        pointingCorner: MapLibreEdgePinPointingCorner?,
        showsCategoryBubble: Bool
    ) -> (number: MapLibreEdgePinPointingCorner?, category: MapLibreEdgePinPointingCorner?) {
        // The selected category bubble sits above the numeric bubble. On the
        // top boundary it owns the one outward-pointing square corner; on the
        // bottom boundary the numeric bubble owns it. Non-selected pins only
        // have the numeric bubble.
        let appliesToCategory = showsCategoryBubble
            && (pointingCorner == .topLeft || pointingCorner == .topRight)
        return appliesToCategory
            ? (number: nil, category: pointingCorner)
            : (number: pointingCorner, category: nil)
    }
}
