import Foundation

struct JournalSnapshot: Codable, Sendable {
    let groups: [JournalGroup]
    let entries: [JournalEntry]
}

struct JournalGroup: Codable, Identifiable, Sendable, Hashable {
    let id: Int
    var name: String
    var color: String
    var position: Int
    let updatedAt: Date
}

struct JournalImage: Codable, Identifiable, Sendable, Hashable {
    let key: String
    let url: String?
    let kind: String?
    let contentType: String?
    let fileName: String?
    let sizeBytes: Int?
    let pairedVideo: JournalMediaResource?
    var id: String { key }

    init(
        key: String,
        url: String?,
        kind: String? = nil,
        contentType: String? = nil,
        fileName: String? = nil,
        sizeBytes: Int? = nil,
        pairedVideo: JournalMediaResource? = nil
    ) {
        self.key = key
        self.url = url
        self.kind = kind
        self.contentType = contentType
        self.fileName = fileName
        self.sizeBytes = sizeBytes
        self.pairedVideo = pairedVideo
    }

    var uploadReference: JournalMediaReference {
        guard let kind, let contentType, let fileName, let sizeBytes else {
            return .legacy(key)
        }
        return .item(.init(
            key: key,
            kind: kind,
            contentType: contentType,
            fileName: fileName,
            sizeBytes: sizeBytes,
            pairedVideo: pairedVideo.map {
                JournalMediaUploadResource(
                    key: $0.key,
                    contentType: $0.contentType,
                    fileName: $0.fileName,
                    sizeBytes: $0.sizeBytes
                )
            }
        ))
    }
}

struct JournalMediaResource: Codable, Sendable, Hashable {
    let key: String
    let url: String?
    let contentType: String
    let fileName: String
    let sizeBytes: Int
}

struct JournalMediaUploadResource: Codable, Sendable, Hashable {
    let key: String
    let contentType: String
    let fileName: String
    let sizeBytes: Int
}

struct JournalMediaUpload: Codable, Sendable, Hashable {
    let key: String
    let kind: String
    let contentType: String
    let fileName: String
    let sizeBytes: Int
    let pairedVideo: JournalMediaUploadResource?
}

enum JournalMediaReference: Codable, Sendable, Hashable {
    case legacy(String)
    case item(JournalMediaUpload)

    var primaryKey: String {
        switch self {
        case .legacy(let key): key
        case .item(let item): item.key
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let key = try? container.decode(String.self) {
            self = .legacy(key)
        } else {
            self = .item(try container.decode(JournalMediaUpload.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .legacy(let key):
            try container.encode(key)
        case .item(let item):
            try container.encode(item)
        }
    }
}

struct JournalEntry: Codable, Identifiable, Sendable, Hashable {
    let id: Int
    var groupId: Int?
    var title: String
    var content: String?
    var images: [JournalImage]
    let createdAt: Date
    let updatedAt: Date
}

struct JournalGroupRequest: Encodable, Sendable {
    var name: String
    var color: String
    var position: Int
}

struct JournalEntryRequest: Encodable, Sendable {
    var groupId: Int?
    var title: String
    var content: String?
    var imageKeys: [JournalMediaReference]
}

struct DeletedJournalItem: Decodable, Sendable {
    let deleted: Bool
    let id: Int
}

struct JournalUploadIntentRequest: Encodable, Sendable {
    let contentType: String
    let sizeBytes: Int
    let fileName: String
}

struct JournalUploadIntent: Decodable, Sendable {
    let key: String
    let uploadUrl: String
    let expiresIn: Int
    let headers: [String: String]
}
