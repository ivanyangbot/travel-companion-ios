import CoreLocation
import MapKit

/// All interactive map work stays on-device through Apple's MapKit services.
/// No POI keyword or route query is sent to the travel backend.
enum AppleMapService {
    static let unverifiedPlaceNote = String(localized: "mapservice.unverified")

    enum ServiceError: LocalizedError {
        case noRoute

        var errorDescription: String? {
            switch self {
            case .noRoute: String(localized: "mapservice.noRoute")
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
                name: item.name ?? placemark.name ?? String(localized: "common.unnamedPlace"),
                address: formattedAddress(for: placemark),
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                placeId: nil
            )
        }
    }

    /// Resolves the two structured airport labels on each flight into a
    /// display-only map route. Failures omit only the map decoration; the
    /// itinerary flight card itself remains untouched and available elsewhere.
    static func resolveFlightRoutes(
        cards: [TravelCardSnapshot]
    ) async -> [TodayFlightRoute] {
        await resolveFlightRoutes(cards: cards) { airport in
            await TodayFlightAirportSearchCache.shared.result(for: airport)
        }
    }

    static func resolveFlightRoutes(
        cards: [TravelCardSnapshot],
        search: @escaping @Sendable (String) async -> PlaceSearchResult?
    ) async -> [TodayFlightRoute] {
        await withTaskGroup(of: (Int, TodayFlightRoute?).self, returning: [TodayFlightRoute].self) { group in
            for (index, card) in cards.enumerated() where card.kind == .flight {
                group.addTask {
                    guard let fromAirport = nonEmptyAirport(card.fromAirport),
                          let toAirport = nonEmptyAirport(card.toAirport) else {
                        return (index, nil)
                    }
                    async let origin = search(fromAirport)
                    async let destination = search(toAirport)
                    guard let originResult = await origin,
                          let destinationResult = await destination else {
                        return (index, nil)
                    }
                    return (
                        index,
                        TodayFlightRoute(
                            id: card.id,
                            cardID: card.id,
                            title: card.title,
                            fromAirport: fromAirport,
                            toAirport: toAirport,
                            originLatitude: originResult.latitude,
                            originLongitude: originResult.longitude,
                            destinationLatitude: destinationResult.latitude,
                            destinationLongitude: destinationResult.longitude
                        )
                    )
                }
            }

            var resolved: [(Int, TodayFlightRoute)] = []
            for await (index, route) in group {
                if let route { resolved.append((index, route)) }
            }
            return resolved.sorted { $0.0 < $1.0 }.map { $0.1 }
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
        do {
            let response = try await MKDirections(request: request).calculate()
            if let route = response.routes.first {
                return RouteEstimate(
                    distanceMeters: Int(route.distance.rounded()),
                    durationSeconds: Int(route.expectedTravelTime.rounded()),
                    mode: mode,
                    updatedAt: .now,
                    source: String(localized: "route.sourceAppleMaps")
                )
            }
        } catch {
            // Retry through the backend's Apple Maps Directions Server API.
            // This is still an actual Apple route, not a geometric estimate.
        }
        return try await APIClient().estimateRoute(RouteEstimateRequest(origin: origin, destination: destination, mode: mode))
    }

    static func mapItem(for point: RoutePoint, name: String? = nil) -> MKMapItem {
        let item = MKMapItem(
            location: CLLocation(latitude: point.latitude, longitude: point.longitude),
            address: nil
        )
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

    private static func nonEmptyAirport(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private actor TodayFlightAirportSearchCache {
    static let shared = TodayFlightAirportSearchCache()

    private var results: [String: PlaceSearchResult] = [:]
    private var misses: Set<String> = []

    func result(for airport: String) async -> PlaceSearchResult? {
        let key = airport
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = results[key] { return cached }
        if misses.contains(key) { return nil }

        let code = AgentFlightDisplay.airportCode(airport)
        let codeHint = code == "—" ? "" : " \(code)"
        let query = "\(airport)\(codeHint) airport 机场"
        let candidates = (try? await AppleMapService.searchPlaces(query: query, city: nil)) ?? []
        let selected = preferredResult(in: candidates, airport: airport, code: code)
        if let selected {
            results[key] = selected
        } else {
            misses.insert(key)
        }
        return selected
    }

    private func preferredResult(
        in candidates: [PlaceSearchResult],
        airport: String,
        code: String
    ) -> PlaceSearchResult? {
        guard !candidates.isEmpty else { return nil }
        if code != "—", let codeMatch = candidates.first(where: {
            [$0.name, $0.address].compactMap { $0 }.contains(where: {
                $0.localizedCaseInsensitiveContains(code)
            })
        }) {
            return codeMatch
        }
        let airportName = airport
            .replacingOccurrences(of: code == "—" ? "" : code, with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if airportName.count >= 2, let nameMatch = candidates.first(where: {
            $0.name.localizedCaseInsensitiveContains(airportName)
                || airportName.localizedCaseInsensitiveContains($0.name)
        }) {
            return nameMatch
        }
        return candidates.first
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
