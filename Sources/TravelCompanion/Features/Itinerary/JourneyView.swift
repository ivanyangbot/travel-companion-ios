import SwiftUI

/// 合并「今日地图」与「旅程时间线」的主入口。
struct JourneyView: View {
    enum Section {
        case today
        case itinerary

        var title: String {
            switch self {
            case .today: String(localized: "journey.todaySection")
            case .itinerary: String(localized: "journey.tripSection")
            }
        }

        var alternateTitle: String {
            switch self {
            case .today: String(localized: "journey.viewTrip")
            case .itinerary: String(localized: "journey.viewToday")
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
            TodayView(syncEngine: syncEngine, appleSignIn: appleSignIn, section: $section)
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
