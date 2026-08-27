import SwiftUI

struct PlaceSearchView: View {
    let onSelect: (PlaceSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""
    @State private var city = ""
    @State private var results: [PlaceSearchResult] = []
    @State private var isSearching = false
    @State private var errorMessage: String?

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
        }
    }

    private func search() {
        let cleanedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedKeyword.isEmpty else { return }
        isSearching = true
        errorMessage = nil
        Task {
            do {
                results = try await AppleMapService.searchPlaces(
                    query: cleanedKeyword,
                    city: city.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                )
                if results.isEmpty { errorMessage = String(localized: "placesearch.noResults") }
            } catch {
                errorMessage = String(localized: "placesearch.failed")
            }
            isSearching = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
