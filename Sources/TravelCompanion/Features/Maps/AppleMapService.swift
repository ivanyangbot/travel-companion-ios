import CoreLocation
import Contacts
import MapKit

/// Airport-coordinate enrichment is intentionally partial. A ground leg after
/// a flight only needs the arrival airport, while a ground leg before it only
/// needs the departure airport. Requiring both endpoints would discard a valid
/// coordinate whenever the other airport temporarily fails to resolve.
struct FlightAirportLocationResolution: Equatable, Sendable {
    let cardID: UUID
    let originLocation: FlightAirportLocationSnapshot?
    let destinationLocation: FlightAirportLocationSnapshot?
}

/// Interactive POI and route work stays on-device through MapKit. Airports use
/// the backend's static reference dataset first and fall back to MapKit.
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
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCity = city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        guard !cleanedQuery.isEmpty else { return [] }

        let request = MKLocalSearch.Request()
        request.resultTypes = [.pointOfInterest, .address]
        if let cleanedCity,
           let scope = await searchScope(for: cleanedCity) {
            request.naturalLanguageQuery = cleanedQuery
            request.region = scope.region
            if scope.requiresMatch {
                request.regionPriority = .required
            }
        } else {
            request.naturalLanguageQuery = [cleanedQuery, cleanedCity]
                .compactMap { $0 }
                .joined(separator: " ")
        }

        let response = try await MKLocalSearch(request: request).start()
        return rankedPlaceResults(
            query: cleanedQuery,
            city: cleanedCity,
            candidates: response.mapItems.map(placeSearchResult(for:))
        )
    }

    /// Resolving an Apple-provided completion preserves the context MapKit used
    /// to build it, including localized names and its city/country subtitle.
    @MainActor
    static func searchPlaces(
        completion: MKLocalSearchCompletion,
        query: String,
        city: String?
    ) async throws -> [PlaceSearchResult] {
        let request = MKLocalSearch.Request(completion: completion)
        request.resultTypes = [.pointOfInterest, .address]
        let response = try await MKLocalSearch(request: request).start()
        return rankedPlaceResults(
            query: query,
            city: city,
            candidates: response.mapItems.map(placeSearchResult(for:)),
            filtersWeakMatches: false
        )
    }

    /// Deduplicates and ranks MapKit candidates instead of trusting a result
    /// order that is commonly biased toward the device's current country.
    static func rankedPlaceResults(
        query: String,
        city: String?,
        candidates: [PlaceSearchResult],
        filtersWeakMatches: Bool = true
    ) -> [PlaceSearchResult] {
        let queryTokens = meaningfulSearchTokens(in: query)
        let requiresIdentityMatch = queryTokens.count >= 2

        var seen: Set<String> = []
        let unique = candidates.filter { candidate in
            guard hasValidCoordinate(candidate) else { return false }
            let key = candidate.placeId?.nilIfEmpty
                ?? "\(normalizePlaceName(candidate.name))|\(String(format: "%.5f", candidate.latitude))|\(String(format: "%.5f", candidate.longitude))"
            return seen.insert(key).inserted
        }

        return unique.enumerated()
            .compactMap { index, candidate -> (Int, Int, PlaceSearchResult)? in
                let searchable = [candidate.name, candidate.address]
                    .compactMap { $0 }
                    .joined(separator: " ")
                    .folding(
                        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                        locale: .current
                    )
                    .lowercased()
                let compactSearchable = normalizePlaceName(searchable)
                let compactQuery = normalizePlaceName(query)
                let matchedTokens = queryTokens.filter { searchable.contains($0) }

                // A multi-part identity such as "fairfield jakarta airport"
                // must match more than a generic brand/category word.
                if filtersWeakMatches,
                   requiresIdentityMatch,
                   matchedTokens.count * 2 <= queryTokens.count,
                   !compactSearchable.contains(compactQuery) {
                    return nil
                }

                var score = matchedTokens.count * 30
                if compactSearchable.contains(compactQuery) { score += 140 }
                let compactName = normalizePlaceName(candidate.name)
                if compactName.contains(compactQuery) { score += 80 }
                if let city = city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                    let compactCity = normalizePlaceName(city)
                    if compactSearchable.contains(compactCity) { score += 90 }
                }
                return (score, index, candidate)
            }
            .sorted {
                if $0.0 != $1.0 { return $0.0 > $1.0 }
                return $0.1 < $1.1
            }
            .map(\.2)
    }

    /// Resolves the two structured airport labels on each flight into a
    /// display-only map route. Failures omit only the map decoration; the
    /// itinerary flight card itself remains untouched and available elsewhere.
    static func resolveFlightRoutes(
        cards: [TravelCardSnapshot]
    ) async -> [TodayFlightRoute] {
        let locations = await resolveFlightAirportLocationsWithResolver(cards: cards) { airport in
            await TodayFlightAirportSearchCache.shared.result(for: airport)
        }
        return flightRoutes(cards: cards, resolvedLocations: locations)
    }

    static func resolveFlightRoutes(
        cards: [TravelCardSnapshot],
        search: @escaping @Sendable (String) async -> PlaceSearchResult?
    ) async -> [TodayFlightRoute] {
        let locations = await resolveFlightAirportLocationsWithResolver(cards: cards) { airport in
            guard let result = await search(airport) else { return nil }
            return mapLocation(for: airport, result: result)
        }
        return flightRoutes(cards: cards, resolvedLocations: locations)
    }

    static func resolveFlightAirportLocations(
        cards: [TravelCardSnapshot]
    ) async -> [FlightAirportLocationResolution] {
        await resolveFlightAirportLocationsWithResolver(cards: cards) { airport in
            await TodayFlightAirportSearchCache.shared.result(for: airport)
        }
    }

    static func resolveFlightAirportLocations(
        cards: [TravelCardSnapshot],
        search: @escaping @Sendable (String) async -> PlaceSearchResult?
    ) async -> [FlightAirportLocationResolution] {
        await resolveFlightAirportLocationsWithResolver(cards: cards) { airport in
            guard let result = await search(airport) else { return nil }
            return mapLocation(for: airport, result: result)
        }
    }

    private static func resolveFlightAirportLocationsWithResolver(
        cards: [TravelCardSnapshot],
        resolve: @escaping @Sendable (String) async -> FlightAirportLocationSnapshot?
    ) async -> [FlightAirportLocationResolution] {
        await withTaskGroup(of: (Int, FlightAirportLocationResolution?).self, returning: [FlightAirportLocationResolution].self) { group in
            for (index, card) in cards.enumerated() where card.kind == .flight {
                group.addTask {
                    let fromAirport = nonEmptyAirport(card.fromAirport)
                    let toAirport = nonEmptyAirport(card.toAirport)
                    guard fromAirport != nil || toAirport != nil else {
                        return (index, nil)
                    }
                    async let originLocation = resolveAirportEndpoint(
                        airport: fromAirport,
                        cached: card.fromAirportLocation,
                        resolve: resolve
                    )
                    async let destinationLocation = resolveAirportEndpoint(
                        airport: toAirport,
                        cached: card.toAirportLocation,
                        resolve: resolve
                    )
                    return (
                        index,
                        FlightAirportLocationResolution(
                            cardID: card.id,
                            originLocation: await originLocation,
                            destinationLocation: await destinationLocation
                        )
                    )
                }
            }

            var resolved: [(Int, FlightAirportLocationResolution)] = []
            for await (index, locations) in group {
                if let locations { resolved.append((index, locations)) }
            }
            return resolved.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private static func resolveAirportEndpoint(
        airport: String?,
        cached: FlightAirportLocationSnapshot?,
        resolve: @escaping @Sendable (String) async -> FlightAirportLocationSnapshot?
    ) async -> FlightAirportLocationSnapshot? {
        guard let airport else { return nil }
        if cached?.isFresh(for: airport) == true { return cached }
        return await resolve(airport)
    }

    static func flightRoutes(
        cards: [TravelCardSnapshot],
        resolvedLocations: [FlightAirportLocationResolution]
    ) -> [TodayFlightRoute] {
        let locationsByCardID = Dictionary(uniqueKeysWithValues: resolvedLocations.map { ($0.cardID, $0) })
        return cards.compactMap { card in
            guard card.kind == .flight,
                  let fromAirport = nonEmptyAirport(card.fromAirport),
                  let toAirport = nonEmptyAirport(card.toAirport),
                  let locations = locationsByCardID[card.id],
                  let originLocation = locations.originLocation,
                  let destinationLocation = locations.destinationLocation else {
                return nil
            }
            return TodayFlightRoute(
                id: card.id,
                cardID: card.id,
                title: card.title,
                fromAirport: fromAirport,
                toAirport: toAirport,
                originLocation: originLocation,
                destinationLocation: destinationLocation
            )
        }
    }

    /// Resolves through `/v1/airports` before MapKit. Injected closures keep the
    /// ordering deterministic in tests and make every backend failure a normal
    /// fallback rather than a reason for the flight route to disappear.
    static func resolveAirportLocation(
        _ airport: String,
        lookupByCode: @escaping @Sendable (String) async -> AirportReference? = { code in
            try? await APIClient().airport(code: code)
        },
        searchAPI: @escaping @Sendable (String) async -> [AirportReference] = { query in
            (try? await APIClient().searchAirports(query: query, limit: 10)) ?? []
        },
        searchMap: @escaping @Sendable (String, String?) async throws -> [PlaceSearchResult] = { query, city in
            try await searchPlaces(query: query, city: city)
        }
    ) async -> FlightAirportLocationSnapshot? {
        let trimmed = airport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let code = validIATACode(in: airport)

        if let code,
           let reference = await lookupByCode(code),
           hasValidCoordinate(reference) {
            return apiLocation(for: trimmed, reference: reference)
        }

        let apiQuery = code ?? trimmed
        if let reference = await searchAPI(apiQuery).first(where: { reference in
            guard hasValidCoordinate(reference) else { return false }
            if let code { return reference.iata.caseInsensitiveCompare(code) == .orderedSame }
            return true
        }) {
            return apiLocation(for: trimmed, reference: reference)
        }

        for query in airportSearchQueries(for: airport) {
            guard let candidates = try? await searchMap(query, nil) else { continue }
            let allowsCodeQueryFallback = code.map { query.caseInsensitiveCompare("\($0) airport") == .orderedSame } ?? false
            if let result = preferredAirportResult(
                in: candidates,
                airport: airport,
                code: code,
                allowsCodeQueryFallback: allowsCodeQueryFallback
            ) {
                return mapLocation(for: trimmed, result: result)
            }
        }
        return nil
    }

    private static func apiLocation(
        for query: String,
        reference: AirportReference
    ) -> FlightAirportLocationSnapshot {
        FlightAirportLocationSnapshot(
            query: query,
            iata: reference.iata,
            icao: reference.icao,
            name: reference.name,
            city: reference.city,
            country: reference.country,
            latitude: reference.latitude,
            longitude: reference.longitude,
            resolvedAt: .now
        )
    }

    private static func mapLocation(
        for query: String,
        result: PlaceSearchResult
    ) -> FlightAirportLocationSnapshot {
        FlightAirportLocationSnapshot(
            query: query,
            iata: validIATACode(in: query),
            icao: nil,
            name: result.name,
            city: nil,
            country: nil,
            latitude: result.latitude,
            longitude: result.longitude,
            resolvedAt: .now
        )
    }

    static func airportSearchQueries(for airport: String) -> [String] {
        let trimmed = airport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var queries: [String] = []
        if let code = validIATACode(in: trimmed) {
            queries.append("\(code) airport")
        }
        queries.append(trimmed)

        let title = AgentFlightDisplay.airportTitle(trimmed)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let title, !title.isEmpty, title.caseInsensitiveCompare(trimmed) != .orderedSame {
            queries.append("\(title) airport")
        }

        var seen: Set<String> = []
        return queries.filter {
            seen.insert($0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)).inserted
        }
    }

    static func preferredAirportResult(
        in candidates: [PlaceSearchResult],
        airport: String,
        code: String?,
        allowsCodeQueryFallback: Bool
    ) -> PlaceSearchResult? {
        let validCandidates = candidates.filter(hasValidCoordinate)
        guard !validCandidates.isEmpty else { return nil }

        if let code, let exactCodeMatch = validCandidates.first(where: {
            containsExactToken(code, in: [$0.name, $0.address].compactMap { $0 }.joined(separator: " "))
        }) {
            return exactCodeMatch
        }

        let airportTitle = AgentFlightDisplay.airportTitle(airport) ?? airport
        if let semanticMatch = validCandidates.first(where: {
            isSemanticAirportMatch(query: airportTitle, candidate: $0)
        }) {
            return semanticMatch
        }

        // MapKit often localizes an overseas airport's name and omits its IATA
        // code from both name and address. The first airport POI is acceptable
        // only for the dedicated, unambiguous `<IATA> airport` query.
        if allowsCodeQueryFallback {
            return validCandidates.first(where: looksLikeAirport)
        }
        return nil
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

    private static let genericSearchTokens: Set<String> = [
        "aeroport", "airport", "and", "at", "attraction", "by", "hotel", "inn", "international",
        "lodge", "marriott", "motel", "poi", "resort", "station", "suites",
        "the", "near",
        "住宿", "景点", "景區", "景区", "酒店", "旅馆", "旅館", "机场", "機場", "車站", "车站"
    ]

    private static func meaningfulSearchTokens(in value: String) -> [String] {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        ).lowercased()
        let tokens = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && !genericSearchTokens.contains($0) }
        var seen: Set<String> = []
        return tokens.filter { seen.insert($0).inserted }
    }

    private static func validIATACode(in airport: String) -> String? {
        let code = AgentFlightDisplay.airportCode(airport)
        guard code.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
        return code
    }

    private static func containsExactToken(_ token: String, in value: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: token)
        return value.range(
            of: "(?<![A-Z])\(escaped)(?![A-Z])",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func isSemanticAirportMatch(query: String, candidate: PlaceSearchResult) -> Bool {
        let normalizedQuery = normalizeAirportName(query)
        let normalizedCandidate = normalizeAirportName(candidate.name)
        guard normalizedQuery.count >= 2, normalizedCandidate.count >= 2 else { return false }
        return normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate)
    }

    private static func normalizeAirportName(_ value: String) -> String {
        let genericWords = try! NSRegularExpression(
            pattern: "international|intl|airport|aeroport|aéroport|aeropuerto|aeroporto|flughafen|国际机场|國際機場|机场|機場|空港",
            options: [.caseInsensitive]
        )
        let range = NSRange(value.startIndex..., in: value)
        let withoutGenericWords = genericWords.stringByReplacingMatches(in: value, range: range, withTemplate: " ")
        return normalizePlaceName(withoutGenericWords)
    }

    private static func looksLikeAirport(_ candidate: PlaceSearchResult) -> Bool {
        let value = [candidate.name, candidate.address].compactMap { $0 }.joined(separator: " ")
        return value.range(
            of: "airport|aeroport|aéroport|aeropuerto|aeroporto|flughafen|机场|機場|空港",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func hasValidCoordinate(_ candidate: PlaceSearchResult) -> Bool {
        (-90...90).contains(candidate.latitude)
            && (-180...180).contains(candidate.longitude)
            && !(candidate.latitude == 0 && candidate.longitude == 0)
    }

    private static func hasValidCoordinate(_ airport: AirportReference) -> Bool {
        (-90...90).contains(airport.latitude)
            && (-180...180).contains(airport.longitude)
            && !(airport.latitude == 0 && airport.longitude == 0)
    }

    private static func appendUnverifiedPlaceNote(to notes: String?) -> String {
        let existing = notes?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !existing.contains(unverifiedPlaceNote) else { return existing }
        return existing.isEmpty ? unverifiedPlaceNote : "\(existing) \(unverifiedPlaceNote)"
    }

    private static func stableIdentifier(for item: MKMapItem) -> String {
        if let identifier = item.identifier?.rawValue.nilIfEmpty {
            return "apple-\(identifier)"
        }
        let coordinate = item.placemark.coordinate
        return "apple-\(item.name ?? "poi")-\(coordinate.latitude)-\(coordinate.longitude)"
    }

    private static func formattedAddress(for item: MKMapItem) -> String? {
        if let address = item.addressRepresentations?
            .fullAddress(includingRegion: true, singleLine: true)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return address
        }
        if let address = item.address?.fullAddress
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !address.isEmpty {
            return address
        }
        let placemark = item.placemark
        if let postalAddress = placemark.postalAddress {
            let formatted = CNPostalAddressFormatter
                .string(from: postalAddress, style: .mailingAddress)
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .joined(separator: ", ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty { return formatted }
        }
        let parts = [placemark.administrativeArea, placemark.locality, placemark.subLocality, placemark.thoroughfare, placemark.subThoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func placeSearchResult(for item: MKMapItem) -> PlaceSearchResult {
        let placemark = item.placemark
        let coordinate = placemark.coordinate
        return PlaceSearchResult(
            id: stableIdentifier(for: item),
            name: item.name ?? placemark.name ?? String(localized: "common.unnamedPlace"),
            address: formattedAddress(for: item),
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            placeId: item.identifier?.rawValue
        )
    }

    private struct SearchScope {
        let region: MKCoordinateRegion
        let requiresMatch: Bool
    }

    private static func searchScope(for city: String) async -> SearchScope? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = city
        request.resultTypes = .address
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else {
            return nil
        }

        let coordinate = item.placemark.coordinate
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let requestedCity = normalizePlaceName(city)
        let resolvedLocality = normalizePlaceName(item.placemark.locality ?? "")
        let exactLocality = requestedCity.count >= 2
            && resolvedLocality.count >= 2
            && (requestedCity.contains(resolvedLocality) || resolvedLocality.contains(requestedCity))
        return SearchScope(
            region: MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: exactLocality ? 160_000 : 600_000,
                longitudinalMeters: exactLocality ? 160_000 : 600_000
            ),
            requiresMatch: exactLocality
        )
    }

    private static func nonEmptyAirport(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private actor TodayFlightAirportSearchCache {
    static let shared = TodayFlightAirportSearchCache()

    private var results: [String: FlightAirportLocationSnapshot] = [:]

    func result(for airport: String) async -> FlightAirportLocationSnapshot? {
        let key = airport
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = results[key], cached.isFresh(for: airport) { return cached }

        let selected = await AppleMapService.resolveAirportLocation(airport)
        if let selected {
            results[key] = selected
        }
        return selected
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
