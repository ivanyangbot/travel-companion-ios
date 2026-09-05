import Foundation

/// 预置兴趣标签的稳定 code：会话偏好中只保存 code（与 agent.interest.* 本地化
/// key 一一对应），展示时映射为当前语言名称，切换语言后已保存的偏好不受影响；
/// 发送给后端时再映射回展示名，保证提示词可读。自定义兴趣不在此列，原样存取。
enum AgentInterest {
    static let presets = ["food", "culture", "nature", "shopping", "photo", "nightlife"]

    static func displayName(for code: String) -> String {
        switch code {
        case "food": String(localized: "agent.interest.food")
        case "culture": String(localized: "agent.interest.culture")
        case "nature": String(localized: "agent.interest.nature")
        case "shopping": String(localized: "agent.interest.shopping")
        case "photo": String(localized: "agent.interest.photo")
        case "nightlife": String(localized: "agent.interest.nightlife")
        default: code
        }
    }

    static func displayNames(for codes: [String]) -> [String] {
        codes.map(displayName(for:))
    }
}

/// Versioned, local-first contract for the PRD Agent workbench.  The server
/// receives an explicit snapshot each turn and never owns a conversation.
struct AgentV2TurnRequest: Codable, Sendable {
    struct Trip: Codable, Sendable {
        let destination: String?
        let startDate: String?
        let endDate: String?
        let currency: String?
        let timeZone: String
        let version: Int
        let days: [Day]
    }
    struct Day: Codable, Sendable {
        let date: String
        let cards: [Card]
    }
    struct Card: Codable, Sendable {
        let id: Int?
        let kind: String
        let title: String
        let startAt: String
        let endAt: String?
        let place: String?
        let notes: String?
        var hotelVisits: [HotelVisit] = []
        var roomType: String? = nil
        var priceMinor: Int64? = nil
        var priceCurrency: String? = nil
        /// 账本 agent 需要：卡片实际价（预估价之外的已付价）。
        var actualPriceMinor: Int64? = nil
        var timeZone: String? = nil
    }

    /// 账本 agent 的轻量引用项（备忘物品/卡包条目）：id 仅为轮内引用的
    /// 顺序编号，不对应任何服务端实体；秘密字段永不进入本结构。
    struct ReferenceItem: Codable, Sendable, Equatable {
        let id: Int
        let title: String?
        var note: String? = nil
        var kind: String? = nil
    }
    struct Preferences: Codable, Sendable, Equatable {
        var pace: String?
        var companions: String?
        var budget: String?
        var interests: [String]
        var allowUnverifiedRecommendations: Bool? = true

        var retainsUnverifiedRecommendations: Bool {
            allowUnverifiedRecommendations ?? true
        }
    }
    struct Message: Codable, Sendable, Identifiable {
        let id: UUID
        let role: String
        let content: String
        let createdAt: Date
    }
    struct Attachment: Codable, Sendable, Identifiable {
        let id: UUID
        let mediaType: String
        let dataURI: String
        let fileName: String?

        init(id: UUID, mediaType: String, dataURI: String, fileName: String? = nil) {
            self.id = id
            self.mediaType = mediaType
            self.dataURI = dataURI
            self.fileName = fileName
        }
    }

    /// 账本 agent 的只读费用快照项（服务端上限 60 条，note 截 200）。
    struct ExpenseSnapshotItem: Codable, Sendable, Equatable {
        let id: Int
        let amountMinor: Int64
        let currency: String
        let category: String
        let occurredOn: String
        var note: String? = nil
        var cardId: Int? = nil
        var settlementAmountMinor: Int64? = nil
    }

    /// 手书 agent 的只读手书快照（groups ≤ 20 / entries ≤ 40，content 截 2000）。
    struct JournalContext: Codable, Sendable, Equatable {
        struct Group: Codable, Sendable, Equatable {
            let id: Int
            let name: String
        }
        struct Entry: Codable, Sendable, Equatable {
            let id: Int
            var groupId: Int? = nil
            let title: String
            var content: String? = nil
        }
        var groups: [Group] = []
        var entries: [Entry] = []
    }

    var schemaVersion: Int = 2
    /// 分 tab agent 判别；缺省 itinerary 兼容旧服务端与既有调用点。
    var agent: String = AgentKind.itinerary.wireValue
    let sessionId: UUID
    let turnId: UUID
    let intent: String
    let message: String
    /// `nil` 表示 plan_new 轮次：用户还没有创建旅程，服务端会产出待确认的
    /// 旅程提案（trip_proposal 事件），提案确认前不会落库创建旅程。
    let trip: Trip?
    let preferences: Preferences
    let history: [Message]
    let activeDraft: AgentV2Draft?
    let attachments: [Attachment]
    /// 仅 ledger / journal agent 携带；Optional + encodeIfPresent 使行程
    /// 轮次的线上格式与旧版本完全一致。
    var expenses: [ExpenseSnapshotItem]? = nil
    var journal: JournalContext? = nil
    var memos: [ReferenceItem]? = nil
    var walletCards: [ReferenceItem]? = nil
}

struct AgentV2Draft: Codable, Sendable, Equatable {
    var candidates: [AgentV2Candidate]
    var changes: [AgentV2Change]

    /// Every fully decoded candidate remains visible in the durable draft.
    /// Import validation belongs to the explicit commit action; streaming
    /// placeholders still live separately in `AgentV2LiveCard`.
    func sanitizedForPersistence() -> AgentV2Draft {
        self
    }

    /// A malformed backend turn may reference a card that never arrived.
    /// Keep that inconsistency visible instead of making the change list look
    /// complete while the corresponding candidate silently disappears.
    var unresolvedCandidateChanges: [AgentV2Change] {
        let candidateIDs = Set(candidates.map(\.id))
        return changes.filter { change in
            guard change.operation == .add || change.operation == .replace else { return false }
            guard let candidateID = change.candidateId else { return true }
            return !candidateIDs.contains(candidateID)
        }
    }

    /// Only candidates backed by an explicit add/replace operation may be
    /// selected and committed. Read-only search or information cards remain
    /// inspectable without accidentally turning a query into a trip mutation.
    var actionableCandidateIDs: Set<UUID> {
        Set(changes.compactMap { change in
            guard change.operation == .add || change.operation == .replace else { return nil }
            return change.candidateId
        })
    }
}

struct AgentV2Source: Codable, Sendable, Equatable, Identifiable {
    var id: String { url }
    let provider: String
    let url: String
    let title: String?
    let author: String?
    let sourceProof: String?
}

/// 候选卡 kind：三个行程卡 kind 之外，账本/手书 agent 会产出 `expense`
/// 与 `journal_entry` 候选。服务端契约里只有这五个值；未知值在 decode 时
/// fail-fast（与服务端白名单一致），避免静默渲染错误卡片。
enum AgentV2CandidateKind: String, Codable, Sendable, CaseIterable, Hashable {
    case flight
    case hotel
    case activity
    case expense
    case journalEntry = "journal_entry"

    /// 行程卡专属字段归位：非行程 kind 对应 nil，调用点据此走既有行程渲染。
    var cardKind: TravelCardSnapshot.Kind? {
        switch self {
        case .flight: .flight
        case .hotel: .hotel
        case .activity: .activity
        case .expense, .journalEntry: nil
        }
    }
}

struct AgentV2Candidate: Codable, Sendable, Equatable, Identifiable {
    enum PlaceStatus: String, Codable, Sendable { case verified, pending, failed, notRequired }
    enum DateStatus: String, Codable, Sendable { case inRange, outOfRange, unscheduled, invalid }
    let id: UUID
    var kind: AgentV2CandidateKind
    var title: String
    var images: [String] = []
    /// Server-owned presentation decision derived from verified image-tool
    /// dimensions. It survives draft confirmation into the persisted card.
    var imageScore: Int = 0
    var showLargeImage: Bool = false
    var sourceText: String? = nil
    var allowsUnverifiedPlace: Bool? = nil
    var date: String
    var dateStatus: DateStatus? = nil
    var startAt: String
    var endAt: String?
    /// Hotel checkout date. Kept separate from the local checkout clock so
    /// multi-night stays survive draft persistence and commit round-trips.
    var endDate: String? = nil
    var place: AIChatPlace?
    var placeStatus: PlaceStatus
    var description: String?
    var notes: String?
    var url: String?
    var sources: [AgentV2Source] = []
    var sourceProof: String? = nil
    var priceMinor: Int64?
    /// ISO 4217 currency explicitly read from the source. Nil is retained for
    /// legacy candidates that predate per-card currency support.
    var priceCurrency: String? = nil
    var ticketPriceMinor: Int64?
    var stayDurationMinutes: Int?
    var roomType: String? = nil
    var hotelVisits: [HotelVisit] = []
    var validationIssues: [String] = []
    var tips: [String]
    var bookingCode: String?
    var fromAirport: String?
    var toAirport: String?
    var passengers: String? = nil
    var ticketNumber: String? = nil
    var departureTerminal: String? = nil
    var arrivalTerminal: String? = nil
    var gate: String? = nil
    var seat: String? = nil
    var cabinClass: String? = nil
    var baggageAllowance: String? = nil
    var airlineCode: String? = nil
    var airlineName: String? = nil
    var airlineLogoURL: String? = nil
    var reason: String?
    var risks: [String]
    var missingFields: [String]
    var selected: Bool
    // ----- 账本/手书候选的专属字段（decodeIfPresent，旧会话解码不受影响） -----
    /// expense：账本分类 transport|lodging|food|tickets|shopping|other。
    var category: String? = nil
    /// expense：关联的行程卡 ID（该项目的一笔实际花费）。
    var cardId: Int? = nil
    /// expense：修改行程卡实际价时的新实际价（最小单位）。
    var actualPriceMinor: Int64? = nil
    /// journal_entry：正文。
    var content: String? = nil
    /// journal_entry：目标分组名（提交时服务端按名找组，无则建组）。
    var groupName: String? = nil

    /// Activity and hotel drafts are only useful after the server has
    /// resolved a concrete Apple Maps result. Requiring the normalized name,
    /// display address and sane coordinates prevents old pending/failed or
    /// partially decoded candidates from reappearing after an app update.
    var hasConcreteVerifiedPlace: Bool {
        guard placeStatus == .verified, let place,
              !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let address = place.address,
              !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let latitude = place.latitude, latitude.isFinite, (-90...90).contains(latitude),
              let longitude = place.longitude, longitude.isFinite, (-180...180).contains(longitude)
        else { return false }
        return true
    }

    /// A server-approved text-only itinerary item copied from the user's
    /// message. It is addable without inventing coordinates or a provider ID.
    var hasExplicitUnverifiedPlace: Bool {
        guard placeStatus == .failed, place == nil,
              let sourceText,
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return true
    }

    /// The server marks this only after applying the user's current policy.
    /// The card remains text-only; no coordinates or provider identity are
    /// invented, and the user must still select it before commit.
    var hasAllowedUnverifiedPlace: Bool {
        placeStatus == .failed && place == nil && allowsUnverifiedPlace == true
    }

    var isCommitReady: Bool {
        guard validationIssues.isEmpty else { return false }
        switch kind {
        case .expense:
            // 金额/币种/分类/日期任一缺失都阻断提交（服务端同规则）。
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !date.isEmpty,
                  priceMinor != nil,
                  let priceCurrency,
                  priceCurrency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil,
                  let category, !category.isEmpty
            else { return false }
            return true
        case .journalEntry:
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return false }
            return true
        case .flight, .hotel, .activity:
            guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !date.isEmpty, !startAt.isEmpty,
                  dateStatus != .outOfRange, dateStatus != .invalid else { return false }
            if priceMinor != nil || ticketPriceMinor != nil {
                guard let priceCurrency,
                      priceCurrency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil
                else { return false }
            }
            if kind == .activity || kind == .hotel {
                return hasConcreteVerifiedPlace || hasExplicitUnverifiedPlace || hasAllowedUnverifiedPlace
            }
            return kind != .flight || (bookingCode?.isEmpty == false && fromAirport?.isEmpty == false && toAirport?.isEmpty == false)
        }
    }
}

enum AgentV2CommitRepairRequest {
    static func message(for candidates: [AgentV2Candidate]) -> String {
        let items = candidates.map { candidate in
            let reportedIssues = (candidate.missingFields + candidate.validationIssues)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let issueText = reportedIssues.isEmpty ? "commit validation failed" : reportedIssues.joined(separator: "; ")
            return "- id=\(candidate.id.uuidString), title=\(candidate.title), issues=\(issueText)"
        }
        .joined(separator: "\n")

        return """
        This is an automatic repair required before the user is shown the option to select itinerary items for import. Repair only the active-draft candidates listed below. For each repaired item, output a replace change whose targetDraftId is the listed UUID and whose candidateId points to its repaired card. Fill missing or invalid dates and times within the current trip, verify activity/hotel places with the available place tools, and preserve the source currency in priceCurrency whenever a price exists (for example USD when the user wrote USD or the source shows $). Update dateStatus, placeStatus, place, and missingFields accordingly. Do not add unrelated suggestions and do not ask the user to confirm information that can be reasonably inferred or verified.
        \(items)
        """
    }
}

extension AgentV2Candidate {
    /// Unscheduled POI-inquiry cards legitimately carry null `date`/`startAt`
    /// (the user picks a date later, or asks the agent to schedule them in a
    /// follow-up turn). Decode those as empty strings so one unscheduled card
    /// cannot abort the whole SSE stream at `candidate_upsert`. Defined in an
    /// extension so the memberwise initializer stays available for tests.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(AgentV2CandidateKind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        images = try container.decodeIfPresent([String].self, forKey: .images) ?? []
        imageScore = max(0, min(100, try container.decodeIfPresent(Int.self, forKey: .imageScore) ?? 0))
        showLargeImage = (try container.decodeIfPresent(Bool.self, forKey: .showLargeImage) ?? false)
            && !images.isEmpty
        sourceText = try container.decodeIfPresent(String.self, forKey: .sourceText)
        allowsUnverifiedPlace = try container.decodeIfPresent(Bool.self, forKey: .allowsUnverifiedPlace)
        date = try container.decodeIfPresent(String.self, forKey: .date) ?? ""
        dateStatus = try container.decodeIfPresent(DateStatus.self, forKey: .dateStatus)
        startAt = try container.decodeIfPresent(String.self, forKey: .startAt) ?? ""
        endAt = try container.decodeIfPresent(String.self, forKey: .endAt)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        place = try container.decodeIfPresent(AIChatPlace.self, forKey: .place)
        // 账本/手书候选没有地点语义，服务端可省略 placeStatus；缺省视为
        // notRequired，与行程卡的未排期信息卡同一兜底策略。
        placeStatus = try container.decodeIfPresent(PlaceStatus.self, forKey: .placeStatus) ?? .notRequired
        description = try container.decodeIfPresent(String.self, forKey: .description)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        sources = try container.decodeIfPresent([AgentV2Source].self, forKey: .sources) ?? []
        sourceProof = try container.decodeIfPresent(String.self, forKey: .sourceProof)
        priceMinor = try container.decodeIfPresent(Int64.self, forKey: .priceMinor)
        let decodedPriceCurrency = try container.decodeIfPresent(String.self, forKey: .priceCurrency)
        priceCurrency = decodedPriceCurrency?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        ticketPriceMinor = try container.decodeIfPresent(Int64.self, forKey: .ticketPriceMinor)
        stayDurationMinutes = try container.decodeIfPresent(Int.self, forKey: .stayDurationMinutes)
        roomType = try container.decodeIfPresent(String.self, forKey: .roomType)
        hotelVisits = try container.decodeIfPresent([HotelVisit].self, forKey: .hotelVisits) ?? []
        validationIssues = try container.decodeIfPresent([String].self, forKey: .validationIssues) ?? []
        tips = try container.decodeIfPresent([String].self, forKey: .tips) ?? []
        bookingCode = try container.decodeIfPresent(String.self, forKey: .bookingCode)
        fromAirport = try container.decodeIfPresent(String.self, forKey: .fromAirport)
        toAirport = try container.decodeIfPresent(String.self, forKey: .toAirport)
        passengers = try container.decodeIfPresent(String.self, forKey: .passengers)
        ticketNumber = try container.decodeIfPresent(String.self, forKey: .ticketNumber)
        departureTerminal = try container.decodeIfPresent(String.self, forKey: .departureTerminal)
        arrivalTerminal = try container.decodeIfPresent(String.self, forKey: .arrivalTerminal)
        gate = try container.decodeIfPresent(String.self, forKey: .gate)
        seat = try container.decodeIfPresent(String.self, forKey: .seat)
        cabinClass = try container.decodeIfPresent(String.self, forKey: .cabinClass)
        baggageAllowance = try container.decodeIfPresent(String.self, forKey: .baggageAllowance)
        airlineCode = try container.decodeIfPresent(String.self, forKey: .airlineCode)
        airlineName = try container.decodeIfPresent(String.self, forKey: .airlineName)
        airlineLogoURL = try container.decodeIfPresent(String.self, forKey: .airlineLogoURL)
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
        risks = try container.decodeIfPresent([String].self, forKey: .risks) ?? []
        missingFields = try container.decodeIfPresent([String].self, forKey: .missingFields) ?? []
        selected = try container.decodeIfPresent(Bool.self, forKey: .selected) ?? false
        category = try container.decodeIfPresent(String.self, forKey: .category)
        cardId = try container.decodeIfPresent(Int.self, forKey: .cardId)
        actualPriceMinor = try container.decodeIfPresent(Int64.self, forKey: .actualPriceMinor)
        content = try container.decodeIfPresent(String.self, forKey: .content)
        groupName = try container.decodeIfPresent(String.self, forKey: .groupName)
    }
}

/// 航班展示字段的服务端无关解析：机场三字码与航司二字码。
enum AgentFlightDisplay {
    /// 从机场描述提取 IATA 三字码。模型常附加航站楼信息且可能使用全角
    /// 括号（如 努拉莱伊机场（DPS）D 航站楼），按空格/半角括号分词会丢失
    /// 代码，因此改为扫描独立的 3 个连续大写 ASCII 字母段。
    static func airportCode(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let range = NSRange(value.startIndex..., in: value)
        if let match = iataCodeRegex.firstMatch(in: value, range: range),
           let matchRange = Range(match.range(at: 1), in: value) {
            return String(value[matchRange])
        }
        return "—"
    }

    /// 从航班号提取航司二字码（IATA 前缀），如 ID6331 → ID。
    static func airlineCode(fromBookingCode value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        if let match = bookingCodeRegex.firstMatch(in: trimmed, range: range),
           let matchRange = Range(match.range(at: 1), in: trimmed) {
            return String(trimmed[matchRange]).uppercased()
        }
        return nil
    }

    /// 卡片大标题只保留路线地点，去掉三字码和“机场”冗余词；完整机场名仍在
    /// 下方的起降信息中展示。例如“丽江三义国际机场 (LJG)”显示为“丽江三义”。
    static func airportTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fullRange = NSRange(trimmed.startIndex..., in: trimmed)
        var result = iataDecorationRegex.stringByReplacingMatches(
            in: trimmed,
            range: fullRange,
            withTemplate: " "
        )
        let airportRange = NSRange(result.startIndex..., in: result)
        result = airportWordRegex.stringByReplacingMatches(
            in: result,
            range: airportRange,
            withTemplate: " "
        )
        result = result
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: routeTitleTrimCharacters)
        return result.isEmpty ? trimmed : result
    }

    static func routeTitle(from: String?, to: String?, fallback: String) -> String {
        guard let origin = airportTitle(from), let destination = airportTitle(to) else {
            return fallback
        }
        return "\(origin) → \(destination)"
    }

    private static let iataCodeRegex = try! NSRegularExpression(pattern: "(?:^|[^A-Z])([A-Z]{3})(?![A-Z])")
    private static let bookingCodeRegex = try! NSRegularExpression(pattern: "^\\s*([A-Z0-9]{2})\\s*[- ]?\\s*\\d{1,4}[A-Z]?\\s*$", options: [.caseInsensitive])
    private static let iataDecorationRegex = try! NSRegularExpression(
        pattern: "[（(]\\s*[A-Z]{3}\\s*[）)]|(?<![A-Z])[A-Z]{3}(?![A-Z])"
    )
    private static let airportWordRegex = try! NSRegularExpression(
        pattern: "国际机场|机场|\\bInternational\\s+Airport\\b|\\bAirport\\b",
        options: [.caseInsensitive]
    )
    private static let routeTitleTrimCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: "-–—·,，()（）")
    )
}

extension AgentV2Candidate {
    /// 展示用航司二字码：优先服务端 enrichment，缺失时从航班号前缀推导。
    var displayAirlineCode: String? {
        if let code = airlineCode?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty {
            return code.uppercased()
        }
        return AgentFlightDisplay.airlineCode(fromBookingCode: bookingCode)
    }

    /// 航司标识图：服务端下发的相对路径，或按航司码拼装的托管 logo 地址。
    var airlineLogoImageURL: URL? {
        if let path = airlineLogoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty {
            return CardImageURL.resolve(path)
        }
        guard let code = displayAirlineCode else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }
}

extension AgentV2LiveCard {
    /// 流式阶段的航司标识图：字段随 bookingCode 之后增量到达，未到达时
    /// 退回从航班号推导。
    var airlineLogoImageURL: URL? {
        if let path = fields["airlineLogoURL"], !path.isEmpty {
            return CardImageURL.resolve(path)
        }
        let code = fields["airlineCode"].flatMap { $0.isEmpty ? nil : $0.uppercased() }
            ?? AgentFlightDisplay.airlineCode(fromBookingCode: fields["bookingCode"])
        guard let code else { return nil }
        return CardImageURL.resolve("/v1/airlines/logos/\(code).png")
    }
}

extension AgentV2TurnRequest {
    /// The server-side debug conversation caps history at 10 turns (20
    /// messages) and 2 000 characters per message. Mirror that here so a
    /// long-lived local session cannot grow the turn payload without bound.
    static func trimmedHistory(_ messages: [Message], limit: Int = 20, fieldLimit: Int = 2_000) -> [Message] {
        messages.suffix(limit).map { message in
            guard message.content.count > fieldLimit else { return message }
            return Message(id: message.id, role: message.role, content: String(message.content.prefix(fieldLimit)), createdAt: message.createdAt)
        }
    }
}

struct AgentV2Change: Codable, Sendable, Equatable, Identifiable {
    enum Operation: String, Codable, Sendable { case add, replace, remove, move, keep }
    let id: UUID
    var operation: Operation
    var candidateId: UUID?
    var targetCardId: Int?
    /// 账本 agent：replace/remove 作用的既有支出 ID（与 targetCardId 互斥；
    /// targetCardId 仅用于“改行程卡预估/实际价”的 replace）。
    var targetExpenseId: Int? = nil
    /// Unconfirmed draft candidate targeted by a replace/remove. Paired with
    /// `candidateId` for replace (the new candidate supersedes the draft) or
    /// nil for remove (discard the draft). Mutually exclusive with
    /// `targetCardId`, which only addresses already-committed trip cards.
    var targetDraftId: UUID? = nil
    var summary: String
    var impact: String?

    init(id: UUID = UUID(), operation: Operation, candidateId: UUID?, targetCardId: Int? = nil, targetExpenseId: Int? = nil, targetDraftId: UUID? = nil, summary: String, impact: String? = nil) {
        self.id = id
        self.operation = operation
        self.candidateId = candidateId
        self.targetCardId = targetCardId
        self.targetExpenseId = targetExpenseId
        self.targetDraftId = targetDraftId
        self.summary = summary
        self.impact = impact
    }
}

struct AgentV2Summary: Codable, Sendable, Equatable {
    var text: String
    var coveredDates: [String]
    var pending: [String]
}

enum AgentV2StreamEvent: Sendable {
    case status(String)
    case reasoningSummary(String)
    case assistantDelta(String)
    case cardBegin(id: UUID, index: Int)
    case cardFieldDelta(id: UUID, field: String, value: String)
    case question(String)
    case summary(AgentV2Summary)
    case candidateUpsert(AgentV2Candidate)
    case candidatePatch(id: UUID, candidate: AgentV2Candidate)
    case changeSet([AgentV2Change])
    case tripProposal(AgentV2TripProposal)
    case fliggySearchStarted(AgentV2FliggySearchStart)
    case fliggySearchCompleted(AgentV2FliggySearchCompletion)
    case done
}

/// plan_new 轮次服务端下发的旅程提案。仅作展示与用户确认用途：确认前
/// 服务端不落库，确认后由客户端调用既有建旅程接口创建。
struct AgentV2TripProposal: Codable, Sendable, Equatable {
    let destination: String
    let startDate: String
    let endDate: String
    let currency: String
    let timeZone: String
}

/// Brand-structured progress signal emitted around each Fliggy realtime
/// tool call. Ephemeral UI progress only: it must never enter the persisted
/// session, drafts, or logs (see `AgentV2FliggySearchKind`).
struct AgentV2FliggySearchStart: Decodable, Sendable, Equatable {
    let searchType: String
    private let query: String?
    private let destName: String?
    private let origin: String?
    private let destination: String?
    private let cityName: String?

    /// The first non-empty search term the model filled in (server caps it at
    /// 120 characters; the client truncates defensively for display).
    var searchTerm: String? {
        for value in [query, destName, origin, destination, cityName] {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { continue }
            return String(trimmed.prefix(120))
        }
        return nil
    }
}

/// Terminal signal for one Fliggy tool call. `ok == false` means Fliggy was
/// unavailable/rate-limited and the model degrades gracefully; the stream
/// keeps flowing and the client must not treat it as an error.
struct AgentV2FliggySearchCompletion: Decodable, Sendable, Equatable {
    let searchType: String
    let ok: Bool
    let count: Int?
}

/// `searchType` of a Fliggy search notification. Unknown server values fall
/// back to `other` so newer/older servers stay renderable without throwing.
enum AgentV2FliggySearchKind: String, Sendable, Equatable {
    case fast
    case ai
    case hotel
    case flight
    case train
    case poi
    case other

    init(raw: String) {
        self = Self(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ?? .other
    }

    /// Chip copy while the search is running.
    var progressTitle: String {
        switch self {
        case .hotel: String(localized: "agentv2.queryHotels")
        case .flight: String(localized: "agentv2.queryFlights")
        case .train: String(localized: "agentv2.queryTrains")
        case .poi: String(localized: "agentv2.queryTickets")
        case .fast, .ai, .other: String(localized: "agentv2.queryInventory")
        }
    }
}

/// Ephemeral, field-by-field card state for the current streaming turn.
/// It is deliberately separate from a confirmable draft until the server has
/// validated the whole candidate and its Apple Maps POI.
struct AgentV2LiveCard: Identifiable, Equatable {
    let id: UUID
    let index: Int
    var fields: [String: String] = [:]

    var kind: TravelCardSnapshot.Kind? {
        candidateKind?.cardKind
    }
    /// 原始 kind 字符串：账本/手书的流式占位卡据此分派渲染。
    var kindRaw: String? {
        guard let rawValue = fields["kind"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !rawValue.isEmpty else {
            return nil
        }
        return rawValue
    }
    var candidateKind: AgentV2CandidateKind? {
        guard let rawValue = fields["kind"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return nil
        }
        return AgentV2CandidateKind(rawValue: rawValue)
    }
    var title: String { fields["title"] ?? String(localized: "agentv2.organizing") }
    var timing: String {
        [fields["date"], fields["startAt"]].compactMap { $0 }.joined(separator: " · ")
    }
    var place: String? { fields["placeQuery"] }
    var reason: String? { fields["reason"] }
}

struct AgentV2CommitRequest: Codable, Sendable {
    var schemaVersion: Int = 2
    /// 分 tab agent 判别；itinerary 时不发送以保持旧线上格式。
    var agent: String? = nil
    let sessionId: UUID
    let expectedTripVersion: Int
    let timeZone: String
    let selectedCandidateIds: [UUID]
    let draft: AgentV2Draft
}

struct AgentV2CommitResult: Codable, Sendable {
    let tripVersion: Int
    let committedCandidateIds: [UUID]
    let retryCandidateIds: [UUID]?
}

/// Attachments that have left the composer and now belong to one persisted
/// chat message. Keeping this local-only avoids adding UI data to the server's
/// `history` contract while allowing restored conversations to show what the
/// user actually sent.
struct AgentV2MessageAttachmentGroup: Codable, Identifiable {
    let messageID: UUID
    let attachments: [AgentV2TurnRequest.Attachment]

    var id: UUID { messageID }
}

struct AgentV2LocalSession: Codable, Identifiable {
    var id: UUID
    var updatedAt: Date
    var preferences: AgentV2TurnRequest.Preferences
    var messages: [AgentV2TurnRequest.Message]
    var attachments: [AgentV2TurnRequest.Attachment]
    var draft: AgentV2Draft?
    var summary: AgentV2Summary?
    /// Candidate ids produced by the most recent completed turn. Other draft
    /// candidates carried forward from earlier turns and render in a separate
    /// "still pending" group. Optional so sessions persisted by older builds
    /// decode cleanly (nil = treat every candidate as current-turn).
    var lastTurnCandidateIDs: [UUID]? = nil
    /// plan_new 会话中待用户确认的旅程提案；确认创建旅程后清除。Optional so
    /// sessions persisted by older builds decode cleanly.
    var pendingProposal: AgentV2TripProposal? = nil
    /// Optional for backward-compatible decoding of sessions written before
    /// sent attachments were associated with their user message.
    var messageAttachmentGroups: [AgentV2MessageAttachmentGroup]? = nil

    func sentAttachments(for messageID: UUID) -> [AgentV2TurnRequest.Attachment] {
        messageAttachmentGroups?.first(where: { $0.messageID == messageID })?.attachments ?? []
    }

    static let empty = AgentV2LocalSession(id: UUID(), updatedAt: .now, preferences: .init(pace: nil, companions: nil, budget: nil, interests: [], allowUnverifiedRecommendations: true), messages: [], attachments: [], draft: nil, summary: nil)
}
