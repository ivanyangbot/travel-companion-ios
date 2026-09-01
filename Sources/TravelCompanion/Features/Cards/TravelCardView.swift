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
        Group {
            if card.kind == .flight {
                flightTicketCard
            } else {
                standardCard
            }
        }
        .alert("common.copied", isPresented: Binding(get: { copiedValue != nil }, set: { if !$0 { copiedValue = nil } })) {
            Button("common.ok", role: .cancel) { copiedValue = nil }
        } message: {
            Text("common.copiedPrivacyNote")
        }
    }

    private var standardCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            imageSwiper
            header
            if let intro = card.description, !intro.isEmpty {
                Text(intro).font(.subheadline).foregroundStyle(.primary)
            }
            if showsTime {
                timeRow
            }
            if let place = card.place { placeRow(place) }
            // 预估价/实际价只显示一个：填写了实际价就优先展示实际价。
            if let actual = CardPrice.format(minor: card.actualPriceMinor, currency: card.priceCurrency ?? currency) {
                priceRow(actual, label: String(localized: "travelcard.actualLabel"))
            } else if let estimated = CardPrice.format(minor: card.priceMinor, currency: card.priceCurrency ?? currency) {
                priceRow(estimated, label: String(localized: "travelcard.estimateLabel"))
            }
            if let ticket = CardPrice.format(minor: card.ticketPriceMinor, currency: card.priceCurrency ?? currency) {
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
    }

    private var flightTicketCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                flightHeader
                flightRoute
            }
            .padding(16)

            flightTicketDivider

            HStack(spacing: 12) {
                if let price = flightPrice {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.actualPriceMinor == nil ? String(localized: "travelcard.estimateLabel") : String(localized: "travelcard.actualLabel"))
                            .font(.caption2)
                            .foregroundStyle(PrimaryTabPalette.secondaryText)
                        Text(price)
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                } else if let airlineName = card.airlineName, !airlineName.isEmpty {
                    Text(airlineName)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Text("travelcard.viewDetails")
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            }
            .frame(minHeight: 48)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background {
            LinearGradient(
                colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.065, green: 0.095, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.24), radius: 18, y: 9)
        .accessibilityElement(children: .contain)
    }

    private var flightHeader: some View {
        HStack(alignment: .top, spacing: 11) {
            AirlineLogoBadge(logoURL: persistedAirlineLogoURL, size: 38, cornerRadius: 11)
            VStack(alignment: .leading, spacing: 3) {
                Text(AgentFlightDisplay.routeTitle(
                    from: card.fromAirport,
                    to: card.toAirport,
                    fallback: card.title
                ))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(flightNumberText)
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            Spacer(minLength: 6)
            cardActionsMenu
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    private var flightRoute: some View {
        HStack(alignment: .center, spacing: 10) {
            flightAirportBlock(value: card.fromAirport, time: timeOnly(card.startAt), alignment: .leading)
            VStack(spacing: 7) {
                Image(systemName: "airplane")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(PrimaryTabPalette.accent)
                HStack(spacing: 4) {
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                    Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1)
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                }
                Text(Self.flightDateFormatter.string(from: card.startAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            flightAirportBlock(
                value: card.toAirport,
                time: card.endAt.map(timeOnly) ?? String(localized: "agent.timePending"),
                alignment: .trailing
            )
        }
    }

    private func flightAirportBlock(value: String?, time: String, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(AgentFlightDisplay.airportCode(value))
                .font(.system(size: 29, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(nonEmpty(value) ?? String(localized: "agent.airportPending"))
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            Text(time)
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white.opacity(0.88))
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var flightTicketDivider: some View {
        HStack(spacing: 6) {
            ForEach(0..<20, id: \.self) { _ in
                Capsule().fill(Color.white.opacity(0.10)).frame(maxWidth: .infinity).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) {
            Circle().fill(PrimaryTabPalette.background).frame(width: 18, height: 18).offset(x: -9)
        }
        .overlay(alignment: .trailing) {
            Circle().fill(PrimaryTabPalette.background).frame(width: 18, height: 18).offset(x: 9)
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
            cardActionsMenu
        }
    }

    private var cardActionsMenu: some View {
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

    private var persistedAirlineLogoURL: URL? {
        if let url = CardImageURL.resolve(card.airlineLogoURL) { return url }
        let code = card.airlineCode ?? AgentFlightDisplay.airlineCode(fromBookingCode: card.bookingCode)
        guard let code else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }

    private var flightNumberText: String {
        nonEmpty(card.bookingCode) ?? nonEmpty(card.airlineCode) ?? String(localized: "agent.flightNumberPending")
    }

    private var flightPrice: String? {
        CardPrice.format(minor: card.actualPriceMinor, currency: card.priceCurrency ?? currency)
            ?? CardPrice.format(minor: card.priceMinor, currency: card.priceCurrency ?? currency)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func timeOnly(_ date: Date) -> String {
        Self.flightTimeFormatter.string(from: date)
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

    private static let flightTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let flightDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    private func copy(_ value: String) {
        UIPasteboard.general.string = value
        copiedValue = value
    }
}
