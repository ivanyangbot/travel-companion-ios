import SwiftUI

/// 卡包物品的固定风格图形。按类型（银行卡 / 票根 / 证件 / 其他）渲染统一的视觉卡面，
/// 用于编辑器预览和列表缩略图。图形不存原始照片，只展示标签和脱敏号码，保证统一风格。
struct WalletCardArtwork: View {
    let cardType: WalletCardType
    let label: String
    let number: String

    private static let canvas = CGSize(width: 320, height: 200)

    var body: some View {
        ZStack {
            switch cardType {
            case .bankcard: bankcard
            case .ticket: ticket
            case .id: identity
            case .other: other
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .clipped()
    }

    // MARK: - Bank card

    private var bankcard: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0x1A237E), Color(hex: 0x6A1B9A)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 10) {
                chip
                Spacer()
                Text(WalletMasker.masked(number)).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundStyle(.white)
                Text(label.isEmpty ? "银行卡" : label).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
            }
            .padding(16)
            HStack { Spacer(); Image(systemName: "creditcard.fill").foregroundStyle(.white.opacity(0.25)).font(.title) }.padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var chip: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0xFFD54F), Color(hex: 0xFFA000)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 38, height: 28)
            .overlay(
                VStack(spacing: 2) {
                    ForEach(0..<3) { _ in Rectangle().fill(.black.opacity(0.25)).frame(height: 1) }
                }.padding(.horizontal, 4)
            )
    }

    // MARK: - Ticket stub

    private var ticket: some View {
        ZStack {
            Color(hex: 0xE03060)
            TicketNotchShape().fill(Color(.systemBackground))
            VStack(spacing: 6) {
                HStack {
                    Text("票根").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.9))
                    Spacer()
                    Image(systemName: "ticket.fill").foregroundStyle(.white.opacity(0.85))
                }
                Spacer()
                Text(label.isEmpty ? "门票" : label).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(WalletMasker.masked(number)).font(.system(.subheadline, design: .monospaced)).foregroundStyle(.white.opacity(0.9))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Identity document

    private var identity: some View {
        ZStack(alignment: .topLeading) {
            Color(.systemBackground)
            VStack(alignment: .leading, spacing: 10) {
                Capsule().fill(Color(hex: 0x0D47A1)).frame(width: 90, height: 16)
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(.tertiarySystemFill))
                        .overlay(Image(systemName: "person.crop.filled.uniform").foregroundStyle(.secondary))
                        .frame(width: 54, height: 68)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(label.isEmpty ? "证件" : label).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                        Text(WalletMasker.masked(number)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        ForEach(0..<2) { _ in RoundedRectangle(cornerRadius: 1).fill(Color(.tertiarySystemFill)).frame(height: 5) }
                    }
                }
                Spacer()
            }
            .padding(14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(.separator), lineWidth: 1))
    }

    // MARK: - Other

    private var other: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(hex: 0x37474F), Color(hex: 0x455A64)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "rectangle.stack.fill").foregroundStyle(.white.opacity(0.9))
                Spacer()
                Text(label.isEmpty ? "卡片" : label).font(.headline).foregroundStyle(.white).lineLimit(1)
                Text(WalletMasker.masked(number)).font(.system(.caption, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
            }
            .padding(16)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 票根两侧的半圆缺口。
private struct TicketNotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        let radius: CGFloat = 12
        path.addArc(center: CGPoint(x: rect.minX, y: rect.midY), radius: radius, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
        path.addArc(center: CGPoint(x: rect.maxX, y: rect.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        return path
    }
}

/// 将固定风格图形渲染为 PNG，供卡包条目加密存储。
@MainActor
enum WalletCardArtworkRenderer {
    static func pngData(type: WalletCardType, label: String, number: String) -> Data? {
        let renderer = ImageRenderer(content: WalletCardArtwork(cardType: type, label: label, number: number))
        renderer.scale = 2
        return renderer.uiImage?.pngData()
    }
}

extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
