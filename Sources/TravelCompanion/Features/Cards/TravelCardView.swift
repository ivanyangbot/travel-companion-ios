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
                priceRow(actual, label: "实际价")
            } else if let estimated = CardPrice.format(minor: card.priceMinor, currency: currency) {
                priceRow(estimated, label: "预估价")
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
        .alert("已复制", isPresented: Binding(get: { copiedValue != nil }, set: { if !$0 { copiedValue = nil } })) {
            Button("好", role: .cancel) { copiedValue = nil }
        } message: {
            Text("已复制到剪贴板。订单号和地址可能含有个人信息，请仅粘贴到可信应用。")
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
            Text("门票").font(.caption).foregroundStyle(.secondary)
            Text(price).font(.subheadline.weight(.semibold))
            Spacer()
        }
    }

    private func stayRow(_ minutes: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "hourglass").foregroundStyle(.secondary)
            Text("停留").font(.caption).foregroundStyle(.secondary)
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
        if hours > 0, rest > 0 { return "\(hours) 小时 \(rest) 分钟" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(rest) 分钟"
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: card.kind.systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(card.kind.title).font(.caption.weight(.semibold)).foregroundStyle(tint)
                Text(card.title).font(.headline)
            }
            Spacer(minLength: 8)
            Menu {
                Button("编辑", systemImage: "pencil", action: onEdit)
                Button("上移", systemImage: "arrow.up", action: { onMove(-1) }).disabled(!canMoveUp)
                Button("下移", systemImage: "arrow.down", action: { onMove(1) }).disabled(!canMoveDown)
                Button("删除", systemImage: "trash", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("\(card.title) 的更多操作")
        }
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
                Button("复制地点", systemImage: "doc.on.doc") {
                    copy([place.name, place.address].compactMap { $0 }.joined(separator: " "))
                }
                Button("在 Apple 地图打开", systemImage: "location") { linkHandler.openInMaps(for: place) }
                    .disabled(place.latitude == nil || place.longitude == nil)
                Button("规划路线", systemImage: "point.topleft.down.curvedto.point.bottomright") { showsRoute = true }
                    .disabled(place.latitude == nil || place.longitude == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("地点操作")
        }
        .sheet(isPresented: $showsRoute) { RouteSheet(origin: place, routeCards: routeCards) }
    }

    private func bookingRow(_ code: String) -> some View {
        HStack(spacing: 8) {
            Text("订单号 \(code)").font(.subheadline.monospaced())
            Spacer()
            Button { copy(code) } label: {
                Image(systemName: "doc.on.doc")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("复制订单号")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var actions: some View {
        if let value = card.url, let url = ExternalLinkHandler.validatedHTTPSURL(value) {
            HStack(spacing: 10) {
                Button("打开链接", systemImage: "arrow.up.right.square") { linkHandler.openPublicLink(value) }
                    .buttonStyle(.glass)
                    .frame(minHeight: 44)
                ShareLink(item: url, subject: Text(card.title), message: Text("来自同行的旅行卡片")) {
                    Label("分享", systemImage: "square.and.arrow.up")
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
