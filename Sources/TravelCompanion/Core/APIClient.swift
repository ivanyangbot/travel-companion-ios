import Foundation

actor APIClient {
    private let baseURL: URL?
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Reads the current access token from the device keychain on each call so
    /// a token saved by ``AppleSignInStore`` is picked up without rebuilding
    /// the client. ``nil`` means "no authenticated user yet" — requests that
    /// require auth are expected to be skipped by the caller in that case.
    private let tokenProvider: @Sendable () -> String?
    private var activeTripID: Int?

    init(baseURL: URL? = AppConfiguration.apiBaseURL(), session: URLSession = .shared, keychain: KeychainStore = KeychainStore()) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        // Capture the keychain by value-friendly closure; KeychainStore is a
        // lightweight struct that reads from the Security framework each call.
        self.tokenProvider = { (try? keychain.accessToken()) ?? nil }
        self.activeTripID = nil
    }

    /// Convenience initializer for tests or callers that already hold a token.
    init(baseURL: URL?, session: URLSession, tokenProvider: @escaping @Sendable () -> String?) {
        self.baseURL = baseURL
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.tokenProvider = tokenProvider
        self.activeTripID = nil
    }

    /// The current access token, or `nil` when the user is not signed in.
    var accessToken: String? { tokenProvider() }

    /// Whether the client currently has a bearer token to attach.
    var isAuthenticated: Bool { tokenProvider() != nil }

    /// Attaches the `Authorization: Bearer <token>` header when a token is
    /// available. The auth endpoint itself does not need it, but every other
    /// trip/journal/AI endpoint does once the user is signed in.
    func setActiveTripID(_ tripID: Int?) {
        activeTripID = tripID
    }

    private func authorize(_ request: inout URLRequest, tripID: Int? = nil) {
        if let token = tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let tripID = tripID ?? activeTripID {
            request.setValue(String(tripID), forHTTPHeaderField: "X-Trip-ID")
        }
    }

    func signInWithApple(identityToken: String, fullName: String?) async throws -> AppleSignInResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/auth/apple"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(AppleSignInRequest(identityToken: identityToken, fullName: fullName))
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<AppleSignInResult>.self, from: data).data
    }

    func fetchTrips() async throws -> [TripSummary] {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/trips"))
        request.httpMethod = "GET"
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<[TripSummary]>.self, from: data).data
    }

    func createTrip(_ requestBody: TripPatchRequest, idempotencyKey: UUID? = nil) async throws -> TripSummary {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/trips"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let idempotencyKey {
            request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        }
        authorize(&request)
        request.httpBody = try encoder.encode(requestBody)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<TripSummary>.self, from: data).data
    }

    func deleteTrip(id: Int) async throws {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/trips/\(id)"))
        request.httpMethod = "DELETE"
        authorize(&request, tripID: id)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
    }

    func createInvite(for tripID: Int, expiresInHours: Int? = nil) async throws -> TripInvite {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/trips/\(tripID)/invites"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, tripID: tripID)
        request.httpBody = try encoder.encode(TripInviteRequest(expiresInHours: expiresInHours))
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<TripInvite>.self, from: data).data
    }

    func fetchTripMembers(for tripID: Int) async throws -> [TripMemberSummary] {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/trips/\(tripID)/members"))
        request.httpMethod = "GET"
        authorize(&request, tripID: tripID)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<[TripMemberSummary]>.self, from: data).data
    }

    func inviteLandingURL(token: String) throws -> URL {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        guard var components = URLComponents(
            url: baseURL.appending(path: "/join"),
            resolvingAgainstBaseURL: false
        ) else { throw URLError(.badURL) }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return try requiredURL(components)
    }

    func joinTrip(inviteToken: String) async throws -> TripSummary {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/trips/join"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try encoder.encode(TripJoinRequest(token: inviteToken))
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<TripSummary>.self, from: data).data
    }

    func fetchTrip(id: Int, afterVersion: Int?) async throws -> SharedTripSnapshot? {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var components = URLComponents(url: baseURL.appending(path: "/v1/trip"), resolvingAgainstBaseURL: false)!
        if let afterVersion {
            components.queryItems = [URLQueryItem(name: "afterVersion", value: String(afterVersion))]
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        authorize(&request, tripID: id)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if httpResponse.statusCode == 204 { return nil }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<SharedTripSnapshot>.self, from: data).data
    }

    func estimateRoute(_ routeRequest: RouteEstimateRequest) async throws -> RouteEstimate {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/routes/estimate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try encoder.encode(routeRequest)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<RouteEstimate>.self, from: data).data
    }

    func routeDirections(_ routeRequest: RouteDirectionsRequest) async throws -> RouteDirections {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/routes/directions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try encoder.encode(routeRequest)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<RouteDirections>.self, from: data).data
    }

    func send(_ operation: PendingOperationPayload, tripID: Int) async throws -> APIMeta {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: operation.path))
        request.httpMethod = operation.method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(operation.idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue(String(operation.baseVersion), forHTTPHeaderField: "X-Expected-Trip-Version")
        authorize(&request, tripID: tripID)
        request.httpBody = operation.body
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIWriteResponse.self, from: data).meta
    }

    func itineraryChat(_ request: AIItineraryChatRequest) async throws -> AIItineraryChatResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/ai/itinerary-chat"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<AIItineraryChatResult>.self, from: data).data
    }

    /// Agent 欢迎页「可以这样问」的三条动态建议（``/v1/ai/trip-suggestions``）。
    /// 独立于 Agent v2 轮次管线的一次性调用；失败时由调用方回退到本地静态提示。
    func fetchTripSuggestions(_ request: AITripSuggestionsRequest, tripID: Int?) async throws -> AITripSuggestionsResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/ai/trip-suggestions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest, tripID: tripID)
        urlRequest.httpBody = try encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<AITripSuggestionsResult>.self, from: data).data
    }

    /// Streaming variant of ``itineraryChat``. Returns an async stream of SSE
    /// events (``reply`` deltas then a final ``result``) from
    /// ``/v1/ai/itinerary-chat/stream``. SSE bytes are read at the byte level
    /// (not via ``AsyncBytes.lines``, which can buffer a whole chunked response
    /// until the connection closes on some iOS versions) so reply deltas reach
    /// the UI as soon as the server emits them.
    func itineraryChatStream(_ request: AIItineraryChatRequest) async throws -> AsyncThrowingStream<AIItineraryChatStreamEvent, Error> {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/ai/itinerary-chat/stream"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        // Long generations plus per-card server-side place verification can
        // run for minutes; the server streams heartbeats to hold the line.
        urlRequest.timeoutInterval = 300
        let finalRequest = urlRequest
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let decoder = JSONDecoder()
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)
                    guard let httpResponse = response as? HTTPURLResponse else {
                        continuation.finish(throwing: URLError(.badServerResponse))
                        return
                    }
                    if !(200 ..< 300).contains(httpResponse.statusCode) {
                        // Validation/rate-limit errors arrive as a normal JSON
                        // body, not as SSE. Drain and surface the server's
                        // error envelope so the user sees its message.
                        var body = Data()
                        for try await byte in bytes { body.append(byte) }
                        continuation.finish(throwing: Self.error(for: httpResponse.statusCode, body: body, decoder: decoder))
                        return
                    }
                    // Parse SSE at the byte level: accumulate until a blank line
                    // ("\n\n") completes one event, then dispatch it. This avoids
                    // AsyncBytes.lines buffering an entire streamed response.
                    var event = ""
                    var dataBuffer = ""
                    var line = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A {
                            // "\n" ends a line; a blank line dispatches the event.
                            let str = String(data: line, encoding: .utf8) ?? ""
                            line.removeAll(keepingCapacity: true)
                            if str.hasPrefix("event:") {
                                event = String(str.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                            } else if str.hasPrefix("data:") {
                                let fragment = String(str.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                                dataBuffer += fragment
                            } else if str.hasPrefix(":") {
                                continue
                            } else if str.isEmpty {
                                if !event.isEmpty, let payload = dataBuffer.data(using: .utf8) {
                                    switch event {
                                    case "thinking":
                                        // Legacy events are deliberately ignored: model reasoning
                                        // must never enter user-visible or persisted state.
                                        break
                                    case "reply":
                                        continuation.yield(.reply(try decoder.decode(String.self, from: payload)))
                                    case "card":
                                        let cardPayload = try decoder.decode(AIItineraryStreamCardPayload.self, from: payload)
                                        continuation.yield(.card(index: cardPayload.index, card: cardPayload.card))
                                    case "cardx":
                                        let update = try decoder.decode(AIItineraryStreamCardUpdatePayload.self, from: payload)
                                        continuation.yield(.cardUpdate(index: update.index, extras: update.fields?.extras ?? AICardExtras(), notes: update.fields?.notes ?? nil))
                                    case "cardPlace":
                                        let placePayload = try decoder.decode(AIItineraryStreamCardPlacePayload.self, from: payload)
                                        continuation.yield(.cardPlace(index: placePayload.index, place: placePayload.place, verified: placePayload.verified))
                                    case "result":
                                        let result = try decoder.decode(AIItineraryChatResult.self, from: payload)
                                        continuation.yield(.result(result))
                                    case "error":
                                        let error = try decoder.decode(AIItineraryStreamError.self, from: payload)
                                        continuation.finish(throwing: error)
                                        return
                                    default:
                                        break
                                    }
                                }
                                event = ""
                                dataBuffer = ""
                            }
                        } else if byte != 0x0D {
                            line.append(byte)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func error(for statusCode: Int, body: Data, decoder: JSONDecoder) -> Error {
        if var problem = try? decoder.decode(APIErrorEnvelope.self, from: body).error {
            problem.statusCode = statusCode
            return problem
        }
        return APIResponseError(statusCode: statusCode)
    }

    func importFromLink(_ linkRequest: LinkImportRequest) async throws -> LinkImportResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v1/ai/link-import"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try encoder.encode(linkRequest)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<LinkImportResult>.self, from: data).data
    }

    /// 备忘智能助手：把脱敏后的行程快照交给服务端 AI，让其针对「明日」安排
    /// 给出闹钟、提醒事项和物品建议。和其它 AI 接口一样，原文不在服务端落库。
    func createMemoAssist(_ request: MemoAssistRequest) async throws -> MemoAssistResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/ai/memo-assist"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<MemoAssistResult>.self, from: data).data
    }

    /// 卡包照片录入：把一张照片交给服务端 AI 视觉模型识别，返回标签、号码、备注和
    /// 检测到的类型。照片只在本次识别中使用，不在服务端留存，也不写入共享行程。
    func scanWalletCard(_ request: WalletCardScanRequest) async throws -> WalletCardScanResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/ai/wallet-card-scan"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<WalletCardScanResult>.self, from: data).data
    }

    /// 扫小票/对话生成一笔实际价支出草案。客户端持有对话历史，每轮重放；
    /// 小票图片以 base64 data URI 附在最后一条用户消息上（视觉模型）。
    func createExpenseDraft(_ request: AIExpenseConversationRequest) async throws -> AIExpenseDraft {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/ai/expense-drafts"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        urlRequest.httpBody = try encoder.encode(request)
        let (data, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<AIExpenseDraft>.self, from: data).data
    }

    /// V2 Agent stream. Reasoning summaries remain ephemeral UI progress;
    /// durable candidate patches use stable identifiers. `tripID` 为 nil 表示
    /// plan_new 轮次（无旅程上下文），服务端不强制本接口的旅程鉴权。
    func agentV2Stream(_ payload: AgentV2TurnRequest, tripID: Int?) async throws -> AsyncThrowingStream<AgentV2StreamEvent, Error> {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v2/agent/turns/stream"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&request, tripID: tripID)
        request.httpBody = try encoder.encode(payload)
        request.timeoutInterval = 600
        let finalRequest = request
        let session = self.session
        return AsyncThrowingStream { continuation in
            // Network byte iteration and SSE decoding must not inherit the UI
            // actor. Long reasoning/card payloads can otherwise monopolize
            // the main executor and make progressive rendering look frozen.
            let task = Task.detached(priority: .userInitiated) {
                do {
                    let (bytes, response) = try await session.bytes(for: finalRequest)
                    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    guard (200 ..< 300).contains(response.statusCode) else {
                        var data = Data()
                        for try await byte in bytes { data.append(byte) }
                        throw Self.error(for: response.statusCode, body: data, decoder: JSONDecoder())
                    }
                    var parser = AgentV2SSEParser()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        guard let decoded = try parser.consume(byte) else { continue }
                        continuation.yield(decoded)
                        if case .done = decoded { continuation.finish(); return }
                    }
                    if Task.isCancelled {
                        continuation.finish()
                    } else {
                        try parser.finishAtEOF()
                        continuation.finish()
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func commitAgentV2(_ payload: AgentV2CommitRequest, tripID: Int, idempotencyKey: UUID) async throws -> AgentV2CommitResult {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: "/v2/agent/commits"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(idempotencyKey.uuidString.lowercased(), forHTTPHeaderField: "Idempotency-Key")
        request.setValue(String(payload.expectedTripVersion), forHTTPHeaderField: "X-Expected-Trip-Version")
        authorize(&request, tripID: tripID)
        request.httpBody = try encoder.encode(payload)
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: response, data: data)
        return try decoder.decode(APIEnvelope<AgentV2CommitResult>.self, from: data).data
    }

    fileprivate static func agentV2Event(_ name: String, _ data: Data) throws -> AgentV2StreamEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch name {
        case "status": return .status(try decoder.decode(String.self, from: data))
        case "reasoning_summary": return .reasoningSummary(try decoder.decode(String.self, from: data))
        case "assistant_delta": return .assistantDelta(try decoder.decode(String.self, from: data))
        case "card_begin":
            struct Begin: Decodable { let id: UUID; let index: Int }
            let begin = try decoder.decode(Begin.self, from: data)
            return .cardBegin(id: begin.id, index: begin.index)
        case "card_field_delta":
            struct Field: Decodable { let id: UUID; let field: String; let value: String }
            let field = try decoder.decode(Field.self, from: data)
            return .cardFieldDelta(id: field.id, field: field.field, value: field.value)
        case "question": return .question(try decoder.decode(String.self, from: data))
        case "summary": return .summary(try decoder.decode(AgentV2Summary.self, from: data))
        case "candidate_upsert": return .candidateUpsert(try decoder.decode(AgentV2Candidate.self, from: data))
        case "candidate_patch":
            struct Patch: Decodable { let id: UUID; let candidate: AgentV2Candidate }
            let patch = try decoder.decode(Patch.self, from: data)
            return .candidatePatch(id: patch.id, candidate: patch.candidate)
        case "change_set": return .changeSet(try decoder.decode([AgentV2Change].self, from: data))
        case "trip_proposal": return .tripProposal(try decoder.decode(AgentV2TripProposal.self, from: data))
        case "fliggy_search_started": return .fliggySearchStarted(try decoder.decode(AgentV2FliggySearchStart.self, from: data))
        case "fliggy_search_completed": return .fliggySearchCompleted(try decoder.decode(AgentV2FliggySearchCompletion.self, from: data))
        case "done": return .done
        case "error": throw try decoder.decode(AIItineraryStreamError.self, from: data)
        default: return nil
        }
    }

    func fetchJournal(tripID: Int) async throws -> JournalSnapshot {
        try await journalRequest(path: "/v1/journal", method: "GET", body: nil, tripID: tripID)
    }

    func createJournalGroup(_ value: JournalGroupRequest, tripID: Int) async throws -> JournalGroup {
        try await journalRequest(path: "/v1/journal/groups", method: "POST", body: encoder.encode(value), tripID: tripID)
    }

    func updateJournalGroup(id: Int, _ value: JournalGroupRequest, tripID: Int) async throws -> JournalGroup {
        try await journalRequest(path: "/v1/journal/groups/\(id)", method: "PATCH", body: encoder.encode(value), tripID: tripID)
    }

    func deleteJournalGroup(id: Int, tripID: Int) async throws {
        let _: DeletedJournalItem = try await journalRequest(path: "/v1/journal/groups/\(id)", method: "DELETE", body: nil, tripID: tripID)
    }

    func createJournalEntry(_ value: JournalEntryRequest, tripID: Int) async throws -> JournalEntry {
        try await journalRequest(path: "/v1/journal/entries", method: "POST", body: encoder.encode(value), tripID: tripID)
    }

    func updateJournalEntry(id: Int, _ value: JournalEntryRequest, tripID: Int) async throws -> JournalEntry {
        try await journalRequest(path: "/v1/journal/entries/\(id)", method: "PATCH", body: encoder.encode(value), tripID: tripID)
    }

    func deleteJournalEntry(id: Int, tripID: Int) async throws {
        let _: DeletedJournalItem = try await journalRequest(path: "/v1/journal/entries/\(id)", method: "DELETE", body: nil, tripID: tripID)
    }

    func uploadJournalFile(
        at fileURL: URL,
        contentType: String,
        fileName: String,
        tripID: Int,
        progress: (@Sendable (_ sentBytes: Int64, _ expectedBytes: Int64) -> Void)? = nil
    ) async throws -> String {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let sizeBytes = values.fileSize else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let intent: JournalUploadIntent = try await journalRequest(
            path: "/v1/journal/upload-intents",
            method: "POST",
            body: encoder.encode(JournalUploadIntentRequest(
                contentType: contentType,
                sizeBytes: sizeBytes,
                fileName: fileName
            )),
            tripID: tripID
        )
        guard let url = URL(string: intent.uploadUrl) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.timeoutInterval = 24 * 60 * 60
        for (name, value) in intent.headers { request.setValue(value, forHTTPHeaderField: name) }
        let delegate = JournalUploadProgressDelegate(progress: progress)
        let (_, response) = try await session.upload(for: request, fromFile: fileURL, delegate: delegate)
        guard let httpResponse = response as? HTTPURLResponse, (200 ..< 300).contains(httpResponse.statusCode) else { throw APIResponseError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0) }
        return intent.key
    }

    private func journalRequest<Value: Decodable>(path: String, method: String, body: Data?, tripID: Int) async throws -> Value {
        guard let baseURL else { throw APIConfigurationError.missingBaseURL }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        if let body { request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body }
        authorize(&request, tripID: tripID)
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try validate(response: httpResponse, data: data)
        return try decoder.decode(APIEnvelope<Value>.self, from: data).data
    }

    func encode<Request: Encodable>(_ request: Request) throws -> Data {
        try encoder.encode(request)
    }

    private func validate(response: HTTPURLResponse, data: Data) throws {
        guard (200 ..< 300).contains(response.statusCode) else {
            if let problem = try? decoder.decode(APIErrorEnvelope.self, from: data) {
                var problem = problem.error
                problem.statusCode = response.statusCode
                throw problem
            }
            throw APIResponseError(statusCode: response.statusCode)
        }
    }

    private func requiredURL(_ components: URLComponents) throws -> URL {
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}

private final class JournalUploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Int64, Int64) -> Void)?

    init(progress: (@Sendable (Int64, Int64) -> Void)?) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progress?(totalBytesSent, totalBytesExpectedToSend)
    }
}

/// Stateful byte-level parser for the Agent v2 SSE contract. Kept independent
/// from URLSession so framing, completion, and truncated-stream behavior can
/// be verified with deterministic fixtures.
struct AgentV2SSEParser: Sendable {
    private var eventName = ""
    private var eventData = ""
    private var line = Data()
    private(set) var receivedDone = false

    mutating func consume(_ byte: UInt8) throws -> AgentV2StreamEvent? {
        guard byte == 0x0A else {
            if byte != 0x0D { line.append(byte) }
            return nil
        }

        let value = String(data: line, encoding: .utf8) ?? ""
        line.removeAll(keepingCapacity: true)
        if value.hasPrefix("event:") {
            eventName = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if value.hasPrefix("data:") {
            eventData += String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            return nil
        }
        if value.hasPrefix(":") || !value.isEmpty { return nil }

        defer {
            eventName = ""
            eventData = ""
        }
        guard !eventName.isEmpty, let payload = eventData.data(using: .utf8),
              let decoded = try APIClient.agentV2Event(eventName, payload)
        else { return nil }
        if case .done = decoded { receivedDone = true }
        return decoded
    }

    func finishAtEOF() throws {
        guard receivedDone else { throw AgentV2IncompleteStreamError() }
    }
}

struct AgentV2IncompleteStreamError: LocalizedError, Equatable, Sendable {
    var errorDescription: String? {
        String(localized: "error.streamIncomplete")
    }
}

enum AgentV2StreamRetryPolicy {
    static let maximumReconnectAttempts = 2

    static func shouldRetry(_ error: Error) -> Bool {
        if error is AgentV2IncompleteStreamError { return true }
        if let problem = error as? APIProblem { return !problem.isPermanentClientFailure }
        if let response = error as? APIResponseError {
            return response.statusCode == 408
                || response.statusCode == 429
                || (500 ... 599).contains(response.statusCode)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .networkConnectionLost,
            .dnsLookupFailed,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .resourceUnavailable,
        ].contains(urlError.code)
    }

    static func userMessage(for error: Error) -> String {
        if shouldRetry(error) {
            return String(localized: "error.streamUnstable")
        }
        return error.localizedDescription
    }
}

enum APIConfigurationError: LocalizedError {
    case missingBaseURL

    var errorDescription: String? { String(localized: "error.missingConfig") }
}

/// Non-2xx response whose body is not the `{error:{...}}` envelope (e.g. a
/// reverse-proxy 404/502 HTML page, or a route the deployed backend lacks).
/// Surfacing the status code is far more actionable than a bare -1011.
struct APIResponseError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? {
        switch statusCode {
        case 404: return String(localized: "error.notFound404")
        case 500...599: return String(format: String(localized: "error.serverUnavailable"), statusCode)
        default: return String(format: String(localized: "error.serverUnrecognized"), statusCode)
        }
    }
}
