import CoreLocation
import MapKit

/// All interactive map work stays on-device through Apple's MapKit services.
/// No POI keyword or route query is sent to the travel backend.
enum AppleMapService {
    static let unverifiedPlaceNote = "地点未通过地图验证，请手动确认。"

    enum ServiceError: LocalizedError {
        case noRoute

        var errorDescription: String? {
            switch self {
            case .noRoute: "地图未找到该出行方式的路线，请尝试更换出行方式或终点。"
            }
        }
    }

    static func searchPlaces(query: String, city: String?) async throws -> [PlaceSearchResult] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = [query, city].compactMap { value in
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }.joined(separator: " ")
        request.resultTypes = [.pointOfInterest, .address]

        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems.map { item in
            let placemark = item.placemark
            let coordinate = placemark.coordinate
            return PlaceSearchResult(
                id: stableIdentifier(for: item),
                name: item.name ?? placemark.name ?? "未命名地点",
                address: formattedAddress(for: placemark),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                placeId: nil
            )
        }
    }

    /// Converts model-generated place names into destination-scoped Apple Maps
    /// POIs before they reach the chat UI. A model hint is never treated as a
    /// verified location. Activity and hotel cards with no matching POI remain
    /// visible for correction but are deliberately not selected for import.
    static func validateItineraryChatCards(
        _ cards: [AIItineraryDraft.Card],
        destination: String?,
        search: @escaping @Sendable (String, String?) async throws -> [PlaceSearchResult] = { query, city in
            try await searchPlaces(query: query, city: city)
        }
    ) async -> [AIItineraryDraft.Card] {
        let city = destination?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scopedCity = city?.isEmpty == false ? city : nil

        return await withTaskGroup(of: (Int, AIItineraryDraft.Card).self, returning: [AIItineraryDraft.Card].self) { group in
            for (index, original) in cards.enumerated() {
                group.addTask {
                    var card = original
                    guard card.kind == .activity || card.kind == .hotel else { return (index, card) }
                    guard let query = card.place?.name.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
                          let candidates = try? await search(query, scopedCity),
                          let result = candidates.first(where: { isSemanticPlaceMatch(query: query, candidate: $0) }) else {
                        card.place = nil
                        card.isSelected = false
                        card.notes = appendUnverifiedPlaceNote(to: card.notes)
                        return (index, card)
                    }
                    card.place = AIChatPlace(
                        name: result.name,
                        address: result.address,
                        latitude: result.latitude,
                        longitude: result.longitude,
                        placeId: result.placeId,
                        cityCode: result.cityCode
                    )
                    return (index, card)
                }
            }

            var ordered = Array<AIItineraryDraft.Card?>(repeating: nil, count: cards.count)
            for await (index, card) in group {
                ordered[index] = card
            }
            return ordered.compactMap { $0 }
        }
    }

    static func estimateRoute(origin: RoutePoint, destination: RoutePoint, mode: RouteMode) async throws -> RouteEstimate {
        let request = MKDirections.Request()
        request.source = mapItem(for: origin)
        request.destination = mapItem(for: destination)
        request.transportType = mode.transportType
        let response = try await MKDirections(request: request).calculate()
        guard let route = response.routes.first else { throw ServiceError.noRoute }
        return RouteEstimate(
            distanceMeters: Int(route.distance.rounded()),
            durationSeconds: Int(route.expectedTravelTime.rounded()),
            mode: mode,
            updatedAt: .now,
            source: "Apple 地图"
        )
    }

    static func mapItem(for point: RoutePoint, name: String? = nil) -> MKMapItem {
        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)))
        item.name = name
        return item
    }

    static func mapItem(for place: PlaceSnapshot) -> MKMapItem? {
        guard let point = place.point else { return nil }
        return mapItem(for: point, name: place.name)
    }

    /// `MKLocalSearch` can return a broadly related or even a different-city
    /// result for an ambiguous query. Scope by destination *and* require that
    /// the actual POI name semantically matches the model's query before using
    /// its coordinates; accepting the first result is unsafe.
    static func isSemanticPlaceMatch(query: String, candidate: PlaceSearchResult) -> Bool {
        let normalizedQuery = normalizePlaceName(query)
        let normalizedCandidate = normalizePlaceName(candidate.name)
        guard normalizedQuery.count >= 2, normalizedCandidate.count >= 2 else { return false }
        return normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate)
    }

    private static func normalizePlaceName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || (0x4E00...0x9FFF).contains($0.value) }
            .map(String.init)
            .joined()
    }

    private static func appendUnverifiedPlaceNote(to notes: String?) -> String {
        let existing = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !existing.contains(unverifiedPlaceNote) else { return existing }
        return existing.isEmpty ? unverifiedPlaceNote : "\(existing) \(unverifiedPlaceNote)"
    }

    private static func stableIdentifier(for item: MKMapItem) -> String {
        let coordinate = item.placemark.coordinate
        return "apple-\(item.name ?? "poi")-\(coordinate.latitude)-\(coordinate.longitude)"
    }

    private static func formattedAddress(for placemark: MKPlacemark) -> String? {
        let parts = [placemark.administrativeArea, placemark.locality, placemark.subLocality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: "")
    }
}

extension RouteMode {
    var transportType: MKDirectionsTransportType {
        switch self {
        case .walking: .walking
        case .driving: .automobile
        case .transit: .transit
        }
    }

    var launchOptionsDirectionMode: String {
        switch self {
        case .walking: MKLaunchOptionsDirectionsModeWalking
        case .driving: MKLaunchOptionsDirectionsModeDriving
        case .transit: MKLaunchOptionsDirectionsModeTransit
        }
    }
}
