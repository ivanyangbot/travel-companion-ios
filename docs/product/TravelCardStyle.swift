import SwiftUI

struct TravelCardStyle: ViewModifier {
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
