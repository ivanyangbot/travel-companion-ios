import SwiftUI
import UIKit

/// 与 Agent 候选详情共用视觉层级的只读行程详情。
/// 对用户展示可执行的行程、地点、提示和来源信息，隐藏内部同步字段。
struct CardDetailView: View {
    let card: TravelCardSnapshot
    let currency: String?
    /// Shared-trip gate: passengers render only when the viewer is signed in
    /// and the trip has at least one companion.
    var showsPassengers: Bool = false

    @Environment(\.dismiss) private var dismiss
    @StateObject private var linkHandler = ExternalLinkHandler()
    @State private var copiedField: String?
    @State private var imageIndex = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            background
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    hero
                    titleBlock
                    if card.kind != .flight,
                       let description = card.description,
                       !description.isEmpty {
                        narrative(description)
                    }
                    itinerarySection
                    if let place = card.place {
                        poiSection(place)
                    }
                    if let tips = card.tips, !tips.isEmpty {
                        tipsSection(tips)
                    }
                    if let notes = card.notes, !notes.isEmpty {
                        notesSection(notes)
                    }
                    if !displaySources.isEmpty {
                        sourcesSection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .scrollDismissesKeyboard(.interactively)

            HStack(spacing: 10) {
                if let url = validatedCardURL {
                    ShareLink(item: url, subject: Text(card.title), message: Text("common.shareCardMessage")) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(.black.opacity(0.72), in: Circle())
                    }
                    .accessibilityLabel(Text("carddetail.shareA11y"))
                }
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(.black.opacity(0.76), in: Circle())
                }
                .accessibilityLabel(Text("agent.closeDetailsA11y"))
            }
            .padding(.top, 18)
            .padding(.trailing, 24)
        }
        .sheet(isPresented: Binding(
            get: { linkHandler.browserURL != nil },
            set: { if !$0 { linkHandler.browserURL = nil } }
        )) {
            if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
        }
        .alert("common.copied", isPresented: Binding(
            get: { copiedField != nil },
            set: { if !$0 { copiedField = nil } }
        )) {
            Button("common.ok", role: .cancel) { copiedField = nil }
        } message: {
            Text(String(format: String(localized: "common.copiedToClipboard"), copiedField ?? String(localized: "common.copiedToClipboardField")))
        }
        .alert("common.cannotOpenLink", isPresented: Binding(
            get: { linkHandler.alertMessage != nil },
            set: { if !$0 { linkHandler.alertMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { linkHandler.alertMessage = nil }
        } message: {
            Text(linkHandler.alertMessage ?? "")
        }
        .preferredColorScheme(.dark)
    }

    private var background: some View {
        PrimaryTabPalette.background.ignoresSafeArea()
    }

    private var hero: some View {
        CardDetailImagePager(urls: imageURLs, selection: $imageIndex, height: imageURLs.isEmpty ? 144 : 252, tint: tint, placeholderIcon: card.kind.systemImage)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.26), radius: 18, y: 10)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(card.kind.title, systemImage: card.kind.systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(tint.opacity(0.13), in: Capsule())
                if card.place?.latitude != nil {
                    Label("carddetail.coordsSet", systemImage: "checkmark.seal.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(Color.green.opacity(0.11), in: Capsule())
                }
            }
            Text(card.title)
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Label(dateTimeText(card.startAt), systemImage: "calendar")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(PrimaryTabPalette.secondaryText)
            HStack(spacing: 8) {
                if let price = displayPrice {
                    detailBadge(price, icon: "tag.fill")
                }
                if let stay = card.stayDurationMinutes {
                    detailBadge(stayText(stay), icon: "hourglass")
                }
            }
        }
    }

    private func detailBadge(_ value: String, icon: String) -> some View {
        Label(value, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white.opacity(0.86))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07), in: Capsule())
    }

    private var imageURLs: [URL] {
        (card.images ?? []).compactMap(CardImageURL.resolve)
    }

    private var displayPrice: String? {
        CardPrice.format(minor: card.actualPriceMinor, currency: card.priceCurrency ?? currency)
            ?? CardPrice.format(minor: card.priceMinor, currency: card.priceCurrency ?? currency)
            ?? CardPrice.format(minor: card.ticketPriceMinor, currency: card.priceCurrency ?? currency)
    }

    private func narrative(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(String(localized: "agent.sectionIntro"), icon: "text.alignleft")
            Text(description)
                .font(.body)
                .foregroundStyle(.white.opacity(0.86))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .detailSurface(tint: tint)
    }

    private var itinerarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "carddetail.infoSection"), icon: "calendar.badge.clock")
            detailRow(String(localized: "carddetail.startTime"), value: dateTimeText(card.startAt), icon: "play.circle.fill")
            if let endAt = card.endAt {
                detailRow(String(localized: "carddetail.endTime"), value: dateTimeText(endAt), icon: "stop.circle.fill")
            }
            if card.kind == .flight, let from = card.fromAirport, !from.isEmpty {
                detailRow(String(localized: "carddetail.departureAirport"), value: from, icon: "airplane.departure")
            }
            if card.kind == .flight, let to = card.toAirport, !to.isEmpty {
                detailRow(String(localized: "carddetail.arrivalAirport"), value: to, icon: "airplane.arrival")
            }
            if card.kind == .flight, showsPassengers,
               let passengers = card.passengers, !passengers.isEmpty {
                detailRow(String(localized: "carddetail.passengers"), value: passengers, icon: "person.2.fill")
            }
            if let actual = CardPrice.format(minor: card.actualPriceMinor, currency: card.priceCurrency ?? currency) {
                detailRow(String(localized: "carddetail.actualPrice"), value: actual, icon: "creditcard.fill")
            }
            if let estimated = CardPrice.format(minor: card.priceMinor, currency: card.priceCurrency ?? currency) {
                detailRow(String(localized: "carddetail.estimatedPrice"), value: estimated, icon: "tag.fill")
            }
            if let ticket = CardPrice.format(minor: card.ticketPriceMinor, currency: card.priceCurrency ?? currency) {
                detailRow(String(localized: "carddetail.ticketPrice"), value: ticket, icon: "ticket.fill")
            }
            if let stay = card.stayDurationMinutes {
                detailRow(String(localized: "carddetail.plannedStay"), value: stayText(stay), icon: "hourglass")
            }
            if card.kind == .hotel, let roomType = card.roomType, !roomType.isEmpty {
                detailRow(String(localized: "hotelcard.roomType"), value: roomType, icon: "bed.double.fill")
            }
            if card.kind == .hotel, let checkIn = card.checkInTime, !checkIn.isEmpty {
                detailRow(String(localized: "hotelcard.checkIn"), value: checkIn, icon: "arrow.down.circle")
            }
            if card.kind == .hotel, let checkOut = card.checkOutTime, !checkOut.isEmpty {
                detailRow(String(localized: "hotelcard.checkOut"), value: checkOut, icon: "arrow.up.circle")
            }
            if let booking = card.bookingCode, !booking.isEmpty {
                copyableRow(String(localized: "carddetail.orderId"), value: booking, icon: "number")
            }
        }
        .detailSurface(tint: tint)
    }

    private func poiSection(_ place: PlaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "agent.sectionPlace"), icon: "mappin.and.ellipse")
            Button { linkHandler.openInMaps(for: place) } label: {
                HStack(spacing: 13) {
                    Image(systemName: "map.fill")
                        .font(.title3)
                        .foregroundStyle(PrimaryTabPalette.accent)
                        .frame(width: 42, height: 42)
                        .background(PrimaryTabPalette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(place.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                        if let address = place.address, !address.isEmpty {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                }
                .padding(14)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(place.latitude == nil || place.longitude == nil)
        }
        .detailSurface(tint: tint)
    }

    private func tipsSection(_ tips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "agent.sectionTips"), icon: "lightbulb.fill")
            ForEach(tips, id: \.self) { tip in
                HStack(alignment: .top, spacing: 9) {
                    Circle()
                        .fill(PrimaryTabPalette.accent)
                        .frame(width: 5, height: 5)
                        .padding(.top, 7)
                    Text(tip)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .detailSurface(tint: tint)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle(String(localized: "carddetail.notesSection"), icon: "note.text")
            Text(notes).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
        }
        .detailSurface(tint: tint)
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "agent.sectionSources"), icon: "link")
            VStack(spacing: 0) {
                ForEach(Array(displaySources.enumerated()), id: \.element.id) { index, source in
                    Button { linkHandler.openPublicLink(source.url) } label: {
                        sourceRow(source, showsSectionLabel: false)
                    }
                    .buttonStyle(.plain)
                    if index < displaySources.count - 1 {
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
        }
        .detailSurface(tint: tint)
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline.weight(.bold))
            .foregroundStyle(tint)
    }

    private func detailRow(_ label: String, value: String, icon: String, showsChevron: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing)
            if showsChevron { Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary) }
        }
        .padding(.vertical, 3)
    }

    private func copyableRow(_ label: String, value: String, icon: String) -> some View {
        Button { copy(value, label: label) } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: icon).foregroundStyle(tint).frame(width: 20)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).font(.subheadline.weight(.medium)).multilineTextAlignment(.trailing).lineLimit(2)
                Image(systemName: "doc.on.doc").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("carddetail.copyHint"))
    }

    private func sourceRow(_ source: TravelCardSource, showsSectionLabel _: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: sourceIcon(source))
                .font(.body.weight(.semibold))
                .foregroundStyle(PrimaryTabPalette.accent)
                .frame(width: 36, height: 36)
                .background(PrimaryTabPalette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(sourceTitle(source))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                if let author = source.author, !author.isEmpty {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Image(systemName: "arrow.up.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
    }

    private var tint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }

    private var validatedCardURL: URL? {
        displaySources.first.flatMap { ExternalLinkHandler.validatedHTTPSURL($0.url) }
    }

    private var displaySources: [TravelCardSource] {
        var seen = Set<String>()
        let sources = (card.sources ?? []).filter { source in
            ExternalLinkHandler.validatedHTTPSURL(source.url) != nil && seen.insert(source.url).inserted
        }
        if !sources.isEmpty { return sources }
        guard let url = card.url,
              ExternalLinkHandler.validatedHTTPSURL(url) != nil else { return [] }
        return [TravelCardSource(provider: sourceProvider(url), url: url, title: nil, author: nil)]
    }

    private func sourceTitle(_ source: TravelCardSource) -> String {
        if let title = source.title, !title.isEmpty { return title }
        switch source.provider.lowercased() {
        case "xiaohongshu": return String(localized: "agent.viewXhsNote")
        case "fliggy": return String(localized: "agent.viewBookingFliggy")
        default: return String(localized: "carddetail.openWeb")
        }
    }

    private func sourceIcon(_ source: TravelCardSource) -> String {
        switch source.provider.lowercased() {
        case "xiaohongshu": return "book.pages.fill"
        case "fliggy": return "airplane"
        default: return "safari.fill"
        }
    }

    private func sourceProvider(_ value: String) -> String {
        let host = URL(string: value)?.host?.lowercased() ?? ""
        if host.contains("xiaohongshu") || host.contains("xhslink") { return "xiaohongshu" }
        if host.contains("fliggy") || host.contains("alitrip") { return "fliggy" }
        return "web"
    }

    private func dateTimeText(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    private func stayText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0, rest > 0 { return String(format: String(localized: "common.durationHourMinute"), hours, rest) }
        if hours > 0 { return String(format: String(localized: "common.durationHours"), hours) }
        return String(format: String(localized: "common.durationMinutes"), rest)
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        copiedField = label
    }

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = String(localized: "carddetail.dateFormat.full")
        return formatter
    }()
}

/// Shared modal used by the map and itinerary list. The surrounding dimmer
/// keeps context visible while the ticket itself carries the complete flight
/// hierarchy, matching the app's dark surfaces and brand orange accent.
struct FlightTicketPopup: View {
    let card: TravelCardSnapshot
    let currency: String?
    var showsPassengers = false
    let onDismiss: () -> Void

    @StateObject private var linkHandler = ExternalLinkHandler()
    @State private var popupFrame = CGRect.null

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.72)
                    .ignoresSafeArea()

                VStack(spacing: 14) {
                    HStack {
                        popupButton(systemImage: "xmark", label: "agent.closeDetailsA11y", action: onDismiss)
                        Spacer()
                        ShareLink(item: shareText) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .background(PrimaryTabPalette.elevatedSurface, in: Circle())
                                .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 1) }
                        }
                        .accessibilityLabel(Text("carddetail.shareA11y"))
                    }

                    ScrollView(showsIndicators: false) {
                        ticket
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: 460)
                .frame(maxHeight: min(geometry.size.height * 0.9, 790))
                .background(.black.opacity(0.30), in: RoundedRectangle(cornerRadius: 32, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("flight-ticket-popup"))
                } action: { frame in
                    popupFrame = frame
                }
                .padding(.vertical, max(10, geometry.safeAreaInsets.top * 0.25))
            }
            .coordinateSpace(name: "flight-ticket-popup")
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture().onEnded { value in
                    guard !popupFrame.contains(value.location) else { return }
                    onDismiss()
                },
                including: .all
            )
        }
        .sheet(isPresented: Binding(
            get: { linkHandler.browserURL != nil },
            set: { if !$0 { linkHandler.browserURL = nil } }
        )) {
            if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
        }
        .alert("common.cannotOpenLink", isPresented: Binding(
            get: { linkHandler.alertMessage != nil },
            set: { if !$0 { linkHandler.alertMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { linkHandler.alertMessage = nil }
        } message: {
            Text(linkHandler.alertMessage ?? "")
        }
        .preferredColorScheme(.dark)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onDismiss)
    }

    private var ticket: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 24) {
                airlineHeader
                route
            }
            .padding(20)

            perforatedDivider

            if !ticketDetails.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 18) {
                    ForEach(ticketDetails) { detail in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(detail.label)
                                .font(.caption)
                                .foregroundStyle(PrimaryTabPalette.secondaryText)
                            Text(detail.value)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(20)
            }

            if let notes = nonEmpty(card.notes) {
                perforatedDivider
                Text(notes)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }

            if let source = sourceURL {
                perforatedDivider
                Button { linkHandler.openPublicLink(source.absoluteString) } label: {
                    HStack {
                        Label("carddetail.openWeb", systemImage: "safari.fill")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(height: 48)
                    .padding(.horizontal, 20)
                }
                .buttonStyle(.plain)
            }
        }
        .background {
            LinearGradient(
                colors: [PrimaryTabPalette.elevatedSurface, Color(red: 0.07, green: 0.09, blue: 0.13)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(PrimaryTabPalette.accent.opacity(0.64), lineWidth: 1.2)
        }
        .shadow(color: PrimaryTabPalette.accent.opacity(0.10), radius: 28, y: 16)
    }

    private var airlineHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            AirlineLogoBadge(logoURL: airlineLogoURL, size: 48, cornerRadius: 14)
            VStack(alignment: .leading, spacing: 3) {
                Text(nonEmpty(card.airlineName) ?? String(localized: "kind.flight"))
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                Text(nonEmpty(card.bookingCode) ?? String(localized: "agent.flightNumberPending"))
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            Spacer(minLength: 8)
            if let ticketNumber = nonEmpty(card.ticketNumber) {
                VStack(alignment: .trailing, spacing: 3) {
                    Text("flightticket.ticketNumber")
                        .font(.caption2)
                        .foregroundStyle(PrimaryTabPalette.secondaryText)
                    Text(ticketNumber)
                        .font(.caption.monospaced().weight(.bold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                        .lineLimit(1)
                }
            }
        }
    }

    private var route: some View {
        HStack(alignment: .center, spacing: 12) {
            airport(card.fromAirport, date: card.startAt, terminal: card.departureTerminal, alignment: .leading)
            VStack(spacing: 8) {
                if let durationText {
                    Text(durationText)
                        .font(.caption2.monospacedDigit().weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(PrimaryTabPalette.accent, in: Capsule())
                }
                HStack(spacing: 4) {
                    Circle().fill(.white.opacity(0.30)).frame(width: 5, height: 5)
                    Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                    Image(systemName: "airplane")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(PrimaryTabPalette.accent)
                    Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
                    Circle().fill(.white.opacity(0.30)).frame(width: 5, height: 5)
                }
            }
            .frame(maxWidth: .infinity)
            airport(card.toAirport, date: card.endAt, terminal: card.arrivalTerminal, alignment: .trailing)
        }
    }

    private func airport(_ value: String?, date: Date?, terminal: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 5) {
            Text(AgentFlightDisplay.airportCode(value))
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(nonEmpty(value) ?? String(localized: "agent.airportPending"))
                .font(.caption2)
                .foregroundStyle(PrimaryTabPalette.secondaryText)
                .lineLimit(2)
                .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            if let date {
                Text(Self.timeFormatter.string(from: date))
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                Text(Self.dateFormatter.string(from: date))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            } else {
                Text("agent.timePending")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.secondaryText)
            }
            if let terminal = nonEmpty(terminal) {
                Text(String(format: String(localized: "flightticket.terminalFormat"), terminal))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(PrimaryTabPalette.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }

    private var perforatedDivider: some View {
        HStack(spacing: 5) {
            ForEach(0..<22, id: \.self) { _ in
                Capsule().fill(.white.opacity(0.12)).frame(maxWidth: .infinity).frame(height: 1)
            }
        }
        .overlay(alignment: .leading) {
            Circle().fill(.black.opacity(0.88)).frame(width: 20, height: 20).offset(x: -10)
        }
        .overlay(alignment: .trailing) {
            Circle().fill(.black.opacity(0.88)).frame(width: 20, height: 20).offset(x: 10)
        }
    }

    private var ticketDetails: [FlightTicketDetail] {
        var details: [FlightTicketDetail] = []
        appendDetail(&details, key: "airline", label: String(localized: "flightticket.airline"), value: card.airlineName)
        appendDetail(&details, key: "flight", label: String(localized: "flightticket.flight"), value: card.bookingCode)
        if showsPassengers {
            appendDetail(&details, key: "passengers", label: String(localized: "carddetail.passengers"), value: card.passengers)
        }
        appendDetail(&details, key: "gate", label: String(localized: "flightticket.gate"), value: card.gate)
        appendDetail(&details, key: "cabin", label: String(localized: "flightticket.cabinClass"), value: card.cabinClass)
        appendDetail(&details, key: "seat", label: String(localized: "flightticket.seat"), value: card.seat)
        appendDetail(&details, key: "baggage", label: String(localized: "flightticket.baggage"), value: card.baggageAllowance)
        if let actual = CardPrice.format(minor: card.actualPriceMinor, currency: card.priceCurrency ?? currency) {
            details.append(.init(id: "actualPrice", label: String(localized: "carddetail.actualPrice"), value: actual))
        } else if let estimated = CardPrice.format(minor: card.priceMinor, currency: card.priceCurrency ?? currency) {
            details.append(.init(id: "price", label: String(localized: "carddetail.estimatedPrice"), value: estimated))
        }
        if let ticket = CardPrice.format(minor: card.ticketPriceMinor, currency: card.priceCurrency ?? currency) {
            details.append(.init(id: "ticketPrice", label: String(localized: "flightticket.ticketPrice"), value: ticket))
        }
        return details
    }

    private func appendDetail(_ details: inout [FlightTicketDetail], key: String, label: String, value: String?) {
        guard let value = nonEmpty(value) else { return }
        details.append(.init(id: key, label: label, value: value))
    }

    private func popupButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(PrimaryTabPalette.elevatedSurface, in: Circle())
                .overlay { Circle().stroke(.white.opacity(0.10), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var airlineLogoURL: URL? {
        if let url = CardImageURL.resolve(card.airlineLogoURL) { return url }
        let code = card.airlineCode ?? AgentFlightDisplay.airlineCode(fromBookingCode: card.bookingCode)
        guard let code else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }

    private var sourceURL: URL? {
        if let source = card.sources?.first,
           let url = ExternalLinkHandler.validatedHTTPSURL(source.url) { return url }
        guard let raw = card.url else { return nil }
        return ExternalLinkHandler.validatedHTTPSURL(raw)
    }

    private var durationText: String? {
        guard let endAt = card.endAt else { return nil }
        let minutes = max(0, Int(endAt.timeIntervalSince(card.startAt) / 60))
        guard minutes > 0, minutes <= 24 * 60 else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours > 0, remainder > 0 {
            return String(format: String(localized: "common.durationHourMinute"), hours, remainder)
        }
        if hours > 0 { return String(format: String(localized: "common.durationHours"), hours) }
        return String(format: String(localized: "common.durationMinutes"), remainder)
    }

    private var shareText: String {
        let parts: [String?] = [
            AgentFlightDisplay.routeTitle(from: card.fromAirport, to: card.toAirport, fallback: card.title),
            nonEmpty(card.bookingCode),
            Self.dateTimeFormatter.string(from: card.startAt),
            sourceURL?.absoluteString
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("HH:mm")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy HH:mm")
        return formatter
    }()
}

private struct FlightTicketDetail: Identifiable {
    let id: String
    let label: String
    let value: String
}

private struct CardDetailImagePager: View {
    let urls: [URL]
    @Binding var selection: Int
    let height: CGFloat
    let tint: Color
    let placeholderIcon: String

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if urls.isEmpty {
                placeholder(icon: placeholderIcon)
            } else {
                TabView(selection: $selection) {
                    ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                        AsyncImage(url: url, transaction: Transaction(animation: .easeInOut(duration: 0.25))) { phase in
                            switch phase {
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                placeholder(icon: "photo.badge.exclamationmark")
                            case .empty:
                                ZStack {
                                    placeholder(icon: "photo")
                                    ProgressView().tint(.white.opacity(0.8))
                                }
                            @unknown default:
                                placeholder(icon: "photo")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .clipped()
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            LinearGradient(colors: [.clear, .black.opacity(0.48)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)

            if urls.count > 1 {
                Text(String(format: String(localized: "agent.pagerFormat"), selection + 1, urls.count))
                    .font(.caption2.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.62), in: Capsule())
                    .padding(12)
                    .accessibilityLabel(Text(String(format: String(localized: "agent.pagerA11y"), selection + 1, urls.count)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
    }

    private func placeholder(icon: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [tint.opacity(0.42), PrimaryTabPalette.elevatedSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: icon)
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
    }
}

private struct DetailSurface: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PrimaryTabPalette.elevatedSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            }
    }
}

private extension View {
    func detailSurface(tint: Color) -> some View {
        modifier(DetailSurface(tint: tint))
    }
}
