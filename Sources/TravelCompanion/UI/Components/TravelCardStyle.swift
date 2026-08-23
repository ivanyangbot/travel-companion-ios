import SwiftUI

enum PrimaryTabPalette {
    static let background = Color.black
    static let surface = Color(red: 23 / 255, green: 23 / 255, blue: 23 / 255)
    static let elevatedSurface = Color(red: 34 / 255, green: 34 / 255, blue: 34 / 255)
    static let secondaryText = Color.white.opacity(0.62)
    static let tertiaryText = Color.white.opacity(0.38)
    static let divider = Color.white.opacity(0.055)
    static let accent = Color(red: 1, green: 110 / 255, blue: 0)
}

struct TravelCardStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(red: 0.095, green: 0.10, blue: 0.115),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(.white.opacity(0.045), lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint)
                    .frame(width: 4)
                    .padding(.vertical, 14)
                    .padding(.leading, 2)
            }
    }
}

extension View {
    func travelCardStyle(tint: Color) -> some View {
        modifier(TravelCardStyle(tint: tint))
    }

    func primaryTabHeaderButtonStyle() -> some View {
        self
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background { TodayGlassBackdrop() }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.6), lineWidth: 1.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(
                color: Color(red: 24 / 255, green: 22 / 255, blue: 82 / 255).opacity(0.1),
                radius: 12,
                y: 12
            )
            .buttonStyle(.plain)
    }

    func primaryTabCardStyle(
        color: Color = PrimaryTabPalette.surface,
        cornerRadius: CGFloat = 16
    ) -> some View {
        self
            .background(color, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.035), lineWidth: 1)
            }
    }
}
