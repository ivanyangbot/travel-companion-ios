import SwiftUI
import UIKit

/// A cinematic, read-only dossier for the itinerary card and its linked POI.
/// Every server-backed card and place field remains visible here so a traveller
/// can use the page as the single source of truth while on the move.
struct CardDetailView: View {
    let card: TravelCardSnapshot
    let currency: String?

    @Environment(\.dismiss) private var dismiss
    @StateObject private var linkHandler = ExternalLinkHandler()
    @State private var copiedField: String?

    var body: some View {
        NavigationStack {
            ZStack {
                background
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        hero
                        quickFacts
                        if let description = card.description, !description.isEmpty {
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
                        auditSection
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.down")
                            .font(.headline.weight(.bold))
                            .frame(width: 38, height: 38)
                            .background(.thinMaterial, in: Circle())
                    }
                    .accessibilityLabel("关闭详情")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let url = validatedCardURL {
                        ShareLink(item: url, subject: Text(card.title), message: Text("来自同行的旅行卡片")) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.headline.weight(.semibold))
                                .frame(width: 38, height: 38)
                                .background(.thinMaterial, in: Circle())
                        }
                        .accessibilityLabel("分享卡片")
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { linkHandler.browserURL != nil },
                set: { if !$0 { linkHandler.browserURL = nil } }
            )) {
                if let url = linkHandler.browserURL { SafariBrowserView(url: url) }
            }
            .alert("已复制", isPresented: Binding(
                get: { copiedField != nil },
                set: { if !$0 { copiedField = nil } }
            )) {
                Button("好", role: .cancel) { copiedField = nil }
            } message: {
                Text("\(copiedField ?? "内容") 已复制到剪贴板。")
            }
            .alert("无法打开链接", isPresented: Binding(
                get: { linkHandler.alertMessage != nil },
                set: { if !$0 { linkHandler.alertMessage = nil } }
            )) {
                Button("好", role: .cancel) { linkHandler.alertMessage = nil }
            } message: {
                Text(linkHandler.alertMessage ?? "")
            }
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [tint.opacity(0.24), Color.indigo.opacity(0.14), Color(uiColor: .systemBackground)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            heroImage
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label(card.kind.title, systemImage: card.kind.systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(tint.opacity(0.9), in: Capsule())
                    Text("行程档案")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                Text(card.title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                Text(timeText)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.white.opacity(0.86))
            }
            .padding(22)
        }
        .frame(height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: tint.opacity(0.24), radius: 24, y: 14)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var heroImage: some View {
        if let firstImage = (card.images ?? []).compactMap({ CardImageURL.resolve($0) }).first {
            AsyncImage(url: firstImage) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    Rectangle().fill(tint.opacity(0.35)).overlay { ProgressView().tint(.white) }
                default:
                    heroPlaceholder
                }
            }
        } else {
            heroPlaceholder
        }
    }

    private var heroPlaceholder: some View {
        LinearGradient(colors: [tint, .indigo, .black.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(alignment: .topTrailing) {
                Image(systemName: card.kind.systemImage)
                    .font(.system(size: 120, weight: .thin))
                    .foregroundStyle(.white.opacity(0.16))
                    .padding(18)
            }
    }

    private var quickFacts: some View {
        HStack(spacing: 10) {
            factTile("时间", value: timeText, icon: "clock.fill")
            if let stay = card.stayDurationMinutes {
                factTile("停留", value: stayText(stay), icon: "hourglass")
            }
            if let place = card.place {
                factTile("坐标", value: place.latitude == nil ? "待补充" : "已定位", icon: "location.fill")
            }
        }
    }

    private func factTile(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.caption.weight(.bold)).foregroundStyle(tint)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
    }

    private func narrative(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("这一站的故事", icon: "quote.opening")
            Text(description).font(.body).lineSpacing(5)
        }
        .detailSurface(tint: tint)
    }

    private var itinerarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("行程信息", icon: "calendar.badge.clock")
            detailRow("开始时间", value: dateTimeText(card.startAt), icon: "play.circle.fill")
            if let endAt = card.endAt {
                detailRow("结束时间", value: dateTimeText(endAt), icon: "stop.circle.fill")
            }
            if card.kind == .flight, let from = card.fromAirport, !from.isEmpty {
                detailRow("出发机场", value: from, icon: "airplane.departure")
            }
            if card.kind == .flight, let to = card.toAirport, !to.isEmpty {
                detailRow("到达机场", value: to, icon: "airplane.arrival")
            }
            if let actual = CardPrice.format(minor: card.actualPriceMinor, currency: currency) {
                detailRow("实际价格", value: actual, icon: "creditcard.fill")
            }
            if let estimated = CardPrice.format(minor: card.priceMinor, currency: currency) {
                detailRow("预估价格", value: estimated, icon: "tag.fill")
            }
            if let ticket = CardPrice.format(minor: card.ticketPriceMinor, currency: currency) {
                detailRow("门票价格", value: ticket, icon: "ticket.fill")
            }
            if let stay = card.stayDurationMinutes {
                detailRow("计划停留", value: stayText(stay), icon: "hourglass")
            }
            if let booking = card.bookingCode, !booking.isEmpty {
                copyableRow("订单编号", value: booking, icon: "number")
            }
            if let link = card.url, !link.isEmpty {
                Button { linkHandler.openPublicLink(link) } label: {
                    detailRow("相关链接", value: "打开网页", icon: "arrow.up.right.square.fill", showsChevron: true)
                }
                .buttonStyle(.plain)
            }
        }
        .detailSurface(tint: tint)
    }

    private func poiSection(_ place: PlaceSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("目的地 POI", icon: "mappin.circle.fill")
                Spacer()
                if place.latitude != nil, place.longitude != nil {
                    Button("地图", systemImage: "map.fill") { linkHandler.openInMaps(for: place) }
                        .font(.caption.weight(.bold))
                        .buttonStyle(.borderedProminent)
                        .tint(tint)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(place.name).font(.title3.weight(.bold))
                Text("POI #\(place.id)").font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            if let address = place.address, !address.isEmpty {
                copyableRow("地址", value: address, icon: "building.2.fill")
            }
            if let latitude = place.latitude, let longitude = place.longitude {
                copyableRow("地理坐标", value: String(format: "%.6f, %.6f", latitude, longitude), icon: "scope")
            }
            if let placeID = place.placeId, !placeID.isEmpty {
                copyableRow("地点标识", value: placeID, icon: "key.fill")
            }
            if let cityCode = place.cityCode, !cityCode.isEmpty {
                copyableRow("城市代码", value: cityCode, icon: "building.columns.fill")
            }
            detailRow("POI 更新时间", value: dateTimeText(place.updatedAt), icon: "arrow.triangle.2.circlepath")
        }
        .detailSurface(tint: tint)
    }

    private func tipsSection(_ tips: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("出行锦囊", icon: "sparkles")
            ForEach(Array(tips.enumerated()), id: \.offset) { index, tip in
                HStack(alignment: .top, spacing: 11) {
                    Text("\(index + 1)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(tint, in: Circle())
                    Text(tip).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .detailSurface(tint: tint)
    }

    private func notesSection(_ notes: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("私享备注", icon: "note.text")
            Text(notes).font(.subheadline).foregroundStyle(.secondary).lineSpacing(4)
        }
        .detailSurface(tint: tint)
    }

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("数据档案", icon: "checkmark.seal.fill")
            detailRow("卡片 ID", value: card.serverID.map(String.init) ?? "尚未同步", icon: "number")
            detailRow("所属日期 ID", value: String(card.dayID), icon: "calendar")
            detailRow("排序位置", value: String(card.position), icon: "list.number")
            detailRow("卡片更新时间", value: dateTimeText(card.updatedAt), icon: "clock.arrow.circlepath")
            detailRow("图片数量", value: String(card.images?.count ?? 0), icon: "photo.on.rectangle")
        }
        .detailSurface(tint: tint)
        .opacity(0.8)
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
        .accessibilityHint("点按复制")
    }

    private var tint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }

    private var validatedCardURL: URL? {
        card.url.flatMap(ExternalLinkHandler.validatedHTTPSURL)
    }

    private var timeText: String {
        if let endAt = card.endAt { return "\(timeOnlyText(card.startAt)) — \(timeOnlyText(endAt))" }
        return timeOnlyText(card.startAt)
    }

    private func timeOnlyText(_ date: Date) -> String {
        Self.timeFormatter.string(from: date)
    }

    private func dateTimeText(_ date: Date) -> String {
        Self.dateTimeFormatter.string(from: date)
    }

    private func stayText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let rest = minutes % 60
        if hours > 0, rest > 0 { return "\(hours) 小时 \(rest) 分钟" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(rest) 分钟"
    }

    private func copy(_ value: String, label: String) {
        UIPasteboard.general.string = value
        copiedField = label
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

private struct DetailSurface: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 25, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 25, style: .continuous)
                    .stroke(tint.opacity(0.12), lineWidth: 1)
            }
    }
}

private extension View {
    func detailSurface(tint: Color) -> some View {
        modifier(DetailSurface(tint: tint))
    }
}
