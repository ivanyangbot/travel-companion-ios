import Foundation

/// 卡包照片录入请求体：单张 inline base64 图片 + 风格提示。照片只用于本次识别，
/// 不在服务端留存，与其它 AI 接口一致。
struct WalletCardScanRequest: Encodable, Sendable {
    let image: String
    let styleHint: String
}

/// AI 识别一张卡包照片后返回的字段。客户端据此填入编辑器并渲染固定风格图形。
struct WalletCardScanResult: Decodable, Sendable, Equatable {
    let label: String
    let number: String
    let note: String?
    let detectedType: String

    var cardType: WalletCardType? { WalletCardType(rawValue: detectedType) }
}

/// 卡包物品的视觉类型，决定本地渲染的固定风格图形（银行卡 / 票根 / 证件 / 其他）。
enum WalletCardType: String, Sendable, CaseIterable, Identifiable {
    case bankcard, ticket, id, other

    var id: String { rawValue }
    var title: String {
        switch self {
        case .bankcard: "银行卡"
        case .ticket: "门票"
        case .id: "证件"
        case .other: "其他"
        }
    }
    var systemImage: String {
        switch self {
        case .bankcard: "creditcard"
        case .ticket: "ticket"
        case .id: "doc.text"
        case .other: "rectangle.stack"
        }
    }
    /// 用于请求体的 styleHint。
    var styleHint: String { rawValue }
}

enum WalletCardScanError: LocalizedError {
    case visionUnavailable

    var errorDescription: String? {
        switch self {
        case .visionUnavailable: "尚未配置 AI 视觉服务，无法识别照片。请在行程页的连接设置中配置。"
        }
    }
}
