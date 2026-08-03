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
                    TextField("搜索景点、酒店或机场", text: $keyword)
                        .submitLabel(.search)
                        .onSubmit(search)
                    TextField("城市（可选）", text: $city)
                        .submitLabel(.search)
                        .onSubmit(search)
                    Button("搜索", systemImage: "magnifyingglass", action: search)
                        .disabled(keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSearching)
                } footer: {
                    Text("地点搜索由 Apple 地图在本机完成，不会通过同行服务端查询第三方地图。")
                }
                if isSearching {
                    Section { HStack { Spacer(); ProgressView("正在搜索 Apple 地图…"); Spacer() } }
                } else if let errorMessage {
                    ContentUnavailableView("无法搜索地点", systemImage: "map", description: Text(errorMessage))
                } else if !results.isEmpty {
                    Section("搜索结果") {
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
            .navigationTitle("搜索地点")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
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
                if results.isEmpty { errorMessage = "Apple 地图没有找到匹配地点，请换一个关键词。" }
            } catch {
                errorMessage = "无法完成 Apple 地图搜索，请检查网络后重试。"
            }
            isSearching = false
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
