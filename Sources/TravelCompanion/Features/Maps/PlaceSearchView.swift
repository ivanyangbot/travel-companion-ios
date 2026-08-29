import Combine
import MapKit
import SwiftUI

struct PlaceSearchView: View {
    let onSelect: (PlaceSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var city = ""
    @State private var results: [PlaceSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?
    @StateObject private var completer = ApplePlaceSearchCompleter()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("placesearch.placeholder", text: $keyword)
                        .submitLabel(.search)
                        .onSubmit(search)
                    TextField("placesearch.city", text: $city)
                        .submitLabel(.search)
                        .onSubmit(search)
                    Button("placesearch.searchButton", systemImage: "magnifyingglass", action: search)
                        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                } footer: {
                    Text("placesearch.footer")
                }
                if !isSearching, results.isEmpty, !completer.suggestions.isEmpty {
                    Section("placesearch.suggestions") {
                        ForEach(completer.suggestions) { suggestion in
                            Button {
                                search(suggestion: suggestion)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.and.ellipse")
                                        .foregroundStyle(PrimaryTabPalette.accent)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(suggestion.title)
                                            .foregroundStyle(.primary)
                                        if !suggestion.subtitle.isEmpty {
                                            Text(suggestion.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if isSearching {
                    Section { HStack { Spacer(); ProgressView("placesearch.searching"); Spacer() } }
                } else if let errorMessage {
                    ContentUnavailableView("placesearch.errorTitle", systemImage: "map", description: Text(errorMessage))
                } else if !results.isEmpty {
                    Section("placesearch.results") {
                        ForEach(results) { result in
                            Button {
                                onSelect(result)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(result.name).foregroundStyle(.primary)
                                    if let address = result.address { Text(address).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("placesearch.title")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("common.cancel") { dismiss() } } }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: keyword) { _, _ in updateSuggestions() }
            .onChange(of: city) { _, _ in updateSuggestions() }
            .onDisappear { searchTask?.cancel() }
        }
    }

    private func search() {
        search(suggestion: nil)
    }

    private func search(suggestion: ApplePlaceSearchSuggestion?) {
        let cleanedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKeyword.isEmpty else { return }
        let cleanedCity = city.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let fallbackSuggestions = suggestion.map { [$0] } ?? Array(completer.suggestions.prefix(3))
        searchTask?.cancel()
        isSearching = true
        errorMessage = nil
        searchTask = Task { @MainActor in
            var candidates: [PlaceSearchResult] = []
            var completedRequest = false
            for suggestion in fallbackSuggestions {
                guard !Task.isCancelled else { return }
                if let resolved = try? await AppleMapService.searchPlaces(
                    completion: suggestion.completion,
                    query: cleanedKeyword,
                    city: cleanedCity
                ) {
                    completedRequest = true
                    candidates.append(contentsOf: resolved)
                }
            }
            guard !Task.isCancelled else { return }
            if let direct = try? await AppleMapService.searchPlaces(
                query: cleanedKeyword,
                city: cleanedCity
            ) {
                completedRequest = true
                candidates.append(contentsOf: direct)
            }
            guard !Task.isCancelled else { return }
            results = AppleMapService.rankedPlaceResults(
                query: cleanedKeyword,
                city: cleanedCity,
                candidates: candidates,
                filtersWeakMatches: fallbackSuggestions.isEmpty
            )
            if results.isEmpty {
                errorMessage = completedRequest
                    ? String(localized: "placesearch.noResults")
                    : String(localized: "placesearch.failed")
            }
            isSearching = false
        }
    }

    private func updateSuggestions() {
        searchTask?.cancel()
        isSearching = false
        results = []
        errorMessage = nil
        completer.update(query: keyword, city: city)
    }
}

@MainActor
private final class ApplePlaceSearchCompleter: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published private(set) var suggestions: [ApplePlaceSearchSuggestion] = []

    private let completer: MKLocalSearchCompleter

    override init() {
        let completer = MKLocalSearchCompleter()
        completer.resultTypes = [.pointOfInterest, .address]
        self.completer = completer
        super.init()
        completer.delegate = self
    }

    func update(query: String, city: String) {
        let cleanedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedQuery.isEmpty else {
            completer.queryFragment = ""
            suggestions = []
            return
        }
        let cleanedCity = city.trimmingCharacters(in: .whitespacesAndNewlines)
        completer.queryFragment = [cleanedQuery, cleanedCity]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = completer.results.prefix(8).map(ApplePlaceSearchSuggestion.init)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        suggestions = []
    }
}

private struct ApplePlaceSearchSuggestion: Identifiable {
    let completion: MKLocalSearchCompletion
    let title: String
    let subtitle: String

    init(_ completion: MKLocalSearchCompletion) {
        self.completion = completion
        title = completion.title
        subtitle = completion.subtitle
    }

    var id: String { "\(title)|\(subtitle)" }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
