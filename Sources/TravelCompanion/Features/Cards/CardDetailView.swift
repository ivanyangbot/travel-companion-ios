import SwiftUI
import UIKit

/// 与 Agent 候选详情共用视觉层级的只读行程详情。
/// 对用户展示可执行的行程、地点、提示和来源信息，隐藏内部同步字段。
struct CardDetailView: View {
    let card: TravelCardSnapshot
    let currency: String?

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
        CardPrice.format(minor: card.actualPriceMinor, currency: currency)
            ?? CardPrice.format(minor: card.priceMinor, currency: currency)
            ?? CardPrice.format(minor: card.ticketPriceMinor, currency: currency)
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
            if let actual = CardPrice.format(minor: card.actualPriceMinor, currency: currency) {
                detailRow(String(localized: "carddetail.actualPrice"), value: actual, icon: "creditcard.fill")
            }
            if let estimated = CardPrice.format(minor: card.priceMinor, currency: currency) {
                detailRow(String(localized: "carddetail.estimatedPrice"), value: estimated, icon: "tag.fill")
            }
            if let ticket = CardPrice.format(minor: card.ticketPriceMinor, currency: currency) {
                detailRow(String(localized: "carddetail.ticketPrice"), value: ticket, icon: "ticket.fill")
            }
            if let stay = card.stayDurationMinutes {
                detailRow(String(localized: "carddetail.plannedStay"), value: stayText(stay), icon: "hourglass")
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
