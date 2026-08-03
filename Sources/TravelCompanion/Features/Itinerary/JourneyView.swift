import SwiftUI

/// 合并「今日地图」与「旅程时间线」的主入口。
struct JourneyView: View {
    enum Section {
        case today
        case itinerary

        var title: String {
            switch self {
            case .today: "今日"
            case .itinerary: "旅程"
            }
        }

        var alternateTitle: String {
            switch self {
            case .today: "查看旅程"
            case .itinerary: "查看今日"
            }
        }

        var alternateIcon: String {
            switch self {
            case .today: "list.bullet"
            case .itinerary: "map"
            }
        }

        mutating func toggle() {
            self = self == .today ? .itinerary : .today
        }
    }

    @ObservedObject var syncEngine: SyncEngine
    @ObservedObject var sharedLinkStore: PendingSharedLinkStore
    @ObservedObject var appleSignIn: AppleSignInStore
    @State private var section: Section = .today

    var body: some View {
        switch section {
        case .today:
            TodayView(syncEngine: syncEngine, section: $section)
        case .itinerary:
            ItineraryView(
                syncEngine: syncEngine,
                sharedLinkStore: sharedLinkStore,
                appleSignIn: appleSignIn,
                section: $section
            )
        }
    }
}
