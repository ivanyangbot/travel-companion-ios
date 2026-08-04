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
    var id: String { key }
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
    var imageKeys: [String]
}

struct DeletedJournalItem: Decodable, Sendable {
    let deleted: Bool
    let id: Int
}

struct JournalUploadIntentRequest: Encodable, Sendable {
    let contentType: String
    let sizeBytes: Int
}

struct JournalUploadIntent: Decodable, Sendable {
    let key: String
    let uploadUrl: String
    let expiresIn: Int
    let headers: [String: String]
}
