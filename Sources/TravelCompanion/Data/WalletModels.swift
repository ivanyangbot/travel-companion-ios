import Foundation
import SwiftData

/// The only persisted representation of a wallet entry. Its number and note are
/// AES-GCM ciphertext, so SwiftData never receives those values in clear text.
@Model
final class LocalWalletItem {
    @Attribute(.unique) var id: UUID
    var label: String
    var encryptedSecret: Data
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        label: String,
        encryptedSecret: Data,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.label = label
        self.encryptedSecret = encryptedSecret
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// This type is intentionally local-only. It is only serialized before AES-GCM
/// encryption and is not a request, response, or sync payload.
struct WalletSecret: Codable, Equatable, Sendable {
    var number: String
    var note: String?
    /// AI 识别的卡片类型，用于决定本地渲染的固定风格图形。可为空（手动添加）。
    var cardType: String?
    /// 本地按固定风格渲染的卡片图形 PNG，与号码一同加密存储。
    var image: Data?

    init(number: String, note: String? = nil, cardType: String? = nil, image: Data? = nil) {
        self.number = number
        self.note = note
        self.cardType = cardType
        self.image = image
    }

    private enum CodingKeys: String, CodingKey { case number, note, cardType, image }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(String.self, forKey: .number)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        // cardType/image were added after launch; older ciphertext decodes without them.
        cardType = try container.decodeIfPresent(String.self, forKey: .cardType)
        image = try container.decodeIfPresent(Data.self, forKey: .image)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encodeIfPresent(note, forKey: .note)
        try container.encodeIfPresent(cardType, forKey: .cardType)
        try container.encodeIfPresent(image, forKey: .image)
    }
}

enum WalletMasker {
    static func masked(_ value: String) -> String {
        let characters = Array(value)
        guard characters.count > 4 else { return String(repeating: "•", count: max(characters.count, 4)) }
        return String(repeating: "•", count: max(4, characters.count - 4)) + String(characters.suffix(4))
    }
}
