import SwiftUI

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
}
