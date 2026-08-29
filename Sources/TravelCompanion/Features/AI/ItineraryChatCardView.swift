import SwiftUI

/// A proposed itinerary card rendered inside the AI chat. Shows the card's
/// visual content (kind, title, time, place, notes) in the glass card style
/// with a toggle to include it in the import batch.
struct ItineraryChatCardView: View {
    let card: AIItineraryDraft.Card
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: card.kind.systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(card.kind.title).font(.caption).foregroundStyle(.secondary)
                Text(card.title).font(.headline)
                if let time = card.time, !time.isEmpty {
                    Label(time, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary)
                }
                if let place = card.place {
                    Label(place.name, systemImage: "mappin").font(.subheadline).foregroundStyle(.secondary)
                    if let address = place.address, !address.isEmpty {
                        Text(address).font(.caption2).foregroundStyle(.tertiary).padding(.leading, 24)
                    }
                } else if card.placePending {
                    // The card rendered immediately; the server is verifying
                    // its place against Apple Maps in the background.
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("chatcard.verifying")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                } else if card.kind == .activity || card.kind == .hotel {
                    Label("chatcard.manualConfirm", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let extras = card.extras {
                    if card.kind != .flight,
                       let description = extras.description,
                       !description.isEmpty {
                        Text(description).font(.caption).foregroundStyle(.secondary)
                    }
                    if card.kind == .flight, let code = extras.bookingCode, !code.isEmpty {
                        Label(code, systemImage: "airplane")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let from = extras.fromAirport, let to = extras.toAirport, !from.isEmpty, !to.isEmpty {
                        Text(String(format: String(localized: "chatcard.transit"), from, to))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let priceMinor = extras.priceMinor {
                        Text(String(format: String(localized: "chatcard.estimatePrice"), formattedPrice(priceMinor)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                if let notes = card.notes, !notes.isEmpty {
                    Text(notes).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Toggle("chatcard.importToggle", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .labelsHidden()
                .tint(tint)
                .disabled(card.placePending)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .opacity(isSelected ? 1 : 0.6)
    }

    private func formattedPrice(_ minor: Int64) -> String {
        let major = Double(minor) / 100
        return major.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", major)
            : String(format: "%.2f", major)
    }

    private var tint: Color {
        switch card.kind {
        case .flight: .blue
        case .hotel: .indigo
        case .activity: .teal
        }
    }
}
