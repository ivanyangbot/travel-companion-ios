import SwiftUI
import UIKit

struct TravelCardView: View {
    let card: TravelCardSnapshot
    let canMoveUp: Bool
    let canMoveDown: Bool
    let routeCards: [TravelCardSnapshot]
    let currency: String?
    /// 行程页会将时间绘制到卡片左侧的时间轴上，其他场景仍在卡片内展示。
    let showsTime: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onMove: (Int) -> Void
    @ObservedObject var linkHandler: ExternalLinkHandler
    @State private var copiedValue: String?
    @State private var showsRoute = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            imageSwiper
            header
            if let intro = card.description, !intro.isEmpty {
                Text(intro).font(.subheadline).foregroundStyle(.primary)
            }
            if showsTime {
                timeRow
            }
            if card.kind == .flight, let from = card.fromAirport, let to = card.toAirport, !from.isEmpty, !to.isEmpty {
                flightRouteRow(from: from, to: to)
            }
            if let place = card.place { placeRow(place) }
            // 预估价/实际价只显示一个：填写了实际价就优先展示实际价。
            if let actual = CardPrice.format(minor: card.actualPriceMinor, currency: currency) {
                priceRow(actual, label: String(localized: "travelcard.actualLabel"))
            } else if let estimated = CardPrice.format(minor: card.priceMinor, currency: currency) {
                priceRow(estimated, label: String(localized: "travelcard.estimateLabel"))
            }
            if let ticket = CardPrice.format(minor: card.ticketPriceMinor, currency: currency) {
                ticketRow(ticket)
            }
            if let stayMinutes = card.stayDurationMinutes {
                stayRow(stayMinutes)
            }
            if let code = card.bookingCode, !code.isEmpty { bookingRow(code) }
            if let tips = card.tips, !tips.isEmpty { tipsSection(tips) }
            if let notes = card.notes, !notes.isEmpty {
                Text(notes).font(.subheadline).foregroundStyle(.secondary)
            }
            actions
        }
        .travelCardStyle(tint: tint)
        .alert("common.copied", isPresented: Binding(get: { copiedValue != nil }, set: { if !$0 { copiedValue = nil } })) {
            Button("common.ok", role: .cancel) { copiedValue = nil }
        } message: {
            Text("common.copiedPrivacyNote")
        }
    }

    @ViewBuilder
    private var imageSwiper: some View {
        let urls = (card.images ?? []).compactMap { CardImageURL.resolve($0) }
        if !urls.isEmpty {
            TabView {
                ForEach(Array(urls.enumerated()), id: \.offset) { _, url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .empty:
                            Rectangle().fill(.quaternary).frame(maxWidth: .infinity, minHeight: 120)
                        case .success(let image):
                            image.resizable().scaledToFill().frame(maxWidth: .infinity).frame(height: 160).clipped()
                        case .failure:
                            Rectangle().fill(.quaternary).frame(maxWidth: .infinity).frame(height: 160)
                                .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: urls.count > 1 ? .automatic : .never))
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func flightRouteRow(from: String, to: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "airplane.departure").foregroundStyle(.secondary)
            Text(from).font(.subheadline.weight(.semibold))
            Image(systemName: "arrow.right").foregroundStyle(.secondary).font(.caption)
            Text(to).font(.subheadline.weight(.semibold))
            Spacer()
        }
    }

    private func priceRow(_ price: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "tag").foregroundStyle(.secondary)
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(price).font(.subheadline.weight(.semibold))
            Spacer()
        }
    }

    private func ticketRow(_ price: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "ticket").foregroundStyle(.secondary)
            Text("travelcard.ticketLabel").font(.caption).foregroundStyle(.secondary)
            Text(price).font(.subheadline.weight(.semibold))
            Spacer()
        }
    }

    private func stayRow(_ minutes: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
            Text("travelcard.stayLabel").font(.caption).foregroundStyle(.secondary)
            Text(Self.stayText(minutes)).font(.subheadline.weight(.semibold))
            Spacer()
        }
    }

    private func tipsSection(_ tips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(tips.enumerated()), id: \.offset) { _, tip in
                Label {
                    Text(tip).font(.caption).foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lightbulb").font(.caption).foregroundStyle(.yellow)
                }
            }
        }
    }

    /// 分钟格式化为「X 小时 Y 分钟」/「X 分钟」/「X 小时」。
    private static func stayText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0, rest > 0 { return String(format: String(localized: "common.durationHourMinute"), hours, rest) }
        if hours > 0 { return String(format: String(localized: "common.durationHours"), hours) }
        return String(format: String(localized: "common.durationMinutes"), rest)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            if card.kind == .flight {
                AirlineLogoBadge(logoURL: persistedAirlineLogoURL, size: 28, cornerRadius: 8)
            } else {
                Image(systemName: card.kind.systemImage)
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(card.kind.title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(card.title).font(.headline)
            }
            Spacer(minLength: 8)
            Menu {
                Button("common.edit", systemImage: "pencil", action: onEdit)
                Button("travelcard.moveUp", systemImage: "arrow.up", action: { onMove(-1) }).disabled(!canMoveUp)
                Button("travelcard.moveDown", systemImage: "arrow.down", action: { onMove(1) }).disabled(!canMoveDown)
                Button("common.delete", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text(String(format: String(localized: "common.moreActions"), card.title)))
        }
    }

    private var persistedAirlineLogoURL: URL? {
        if let url = CardImageURL.resolve(card.airlineLogoURL) { return url }
        let code = card.airlineCode ?? AgentFlightDisplay.airlineCode(fromBookingCode: card.bookingCode)
        guard let code else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }

    private var timeRow: some View {
        Label {
            Text(timeText)
        } icon: {
            Image(systemName: "clock")
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private func placeRow(_ place: PlaceSnapshot) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "mappin")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name).font(.subheadline.weight(.medium))
                if let address = place.address, !address.isEmpty {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Menu {
                Button("travelcard.copyPlace", systemImage: "doc.on.doc") {
                    copy([place.name, place.address].compactMap { $0 }.joined(separator: " "))
                }
                Button("travelcard.openInAppleMaps", systemImage: "location") { linkHandler.openInMaps(for: place) }
                    .disabled(place.latitude == nil || place.longitude == nil)
                Button("travelcard.planRoute", systemImage: "point.topleft.down.curvedto.point.bottomright") { showsRoute = true }
                    .disabled(place.latitude == nil || place.longitude == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("travelcard.placeActionsA11y"))
        }
        .sheet(isPresented: $showsRoute) { RouteSheet(origin: place, routeCards: routeCards) }
    }

    private func bookingRow(_ code: String) -> some View {
        HStack(spacing: 8) {
            Text(String(format: String(localized: "common.orderNumber"), code)).font(.subheadline.monospaced())
            Spacer()
            Button { copy(code) } label: {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("common.copyOrderNumber"))
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actions: some View {
        if let value = card.url, let url = ExternalLinkHandler.validatedHTTPSURL(value) {
            HStack(spacing: 10) {
                Button("common.openLink", systemImage: "arrow.up.right.square") { linkHandler.openPublicLink(value) }
                    .buttonStyle(.glass)
                    .frame(minHeight: 44)
                ShareLink(item: url, subject: Text(card.title), message: Text("common.shareCardMessage")) {
                    Label("common.share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.glass)
                .frame(minHeight: 44)
            }
        }
    }

    private var timeText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        if let endAt = card.endAt { return "\(formatter.string(from: card.startAt)) — \(formatter.string(from: endAt))" }
        return formatter.string(from: card.startAt)
    }

    private var tint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        copiedValue = value
    }
}
