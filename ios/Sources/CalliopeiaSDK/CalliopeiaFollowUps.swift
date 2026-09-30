import Foundation

public struct CalliopeiaTranscript: Decodable, Sendable {
    public let success: Bool
    public let error: String?
    public let state: String?
    public let quoteToken: String?
    public let priceJpy: Int?
    public let purchasedAt: String?
    public let transcript: JSONValue?

    enum CodingKeys: String, CodingKey {
        case success, error, state, quoteToken, priceJpy, purchasedAt, transcriptJson
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decode(Bool.self, forKey: .success)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        quoteToken = try c.decodeIfPresent(String.self, forKey: .quoteToken)
        priceJpy = try c.decodeIfPresent(Int.self, forKey: .priceJpy)
        purchasedAt = try c.decodeIfPresent(String.self, forKey: .purchasedAt)
        transcript = try c.decodeIfPresent(String.self, forKey: .transcriptJson).map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
    }
}

public struct CalliopeiaQuestion: Codable, Sendable {
    public struct Citation: Codable, Sendable {
        public let sourceId: String
        public let startSeconds: Double
        public let endSeconds: Double
        public let quote: String

        enum CodingKeys: String, CodingKey { case sourceId, startSeconds, endSeconds, quote }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Worker source identifiers can be numeric window indexes or strings.
            if let text = try? c.decode(String.self, forKey: .sourceId) {
                sourceId = text
            } else {
                sourceId = String(try c.decode(Int.self, forKey: .sourceId))
            }
            startSeconds = try c.decode(Double.self, forKey: .startSeconds)
            endSeconds = try c.decode(Double.self, forKey: .endSeconds)
            quote = try c.decode(String.self, forKey: .quote)
        }
    }
    public let questionId: String
    public let jobId: String
    public let question: String
    public let parentQuestionId: String?
    public let sectionIndex: Int?
    public let status: String
    public let answer: String?
    public let citations: [Citation]?
    public let error: String?
}

public struct CalliopeiaQuestions: Decodable, Sendable {
    public let success: Bool
    public let error: String?
    public let question: CalliopeiaQuestion?
    public let questions: [CalliopeiaQuestion]?
    public let nextToken: String?

    enum CodingKeys: String, CodingKey { case success, error, questionJson, questionsJson, nextToken }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        success = try c.decode(Bool.self, forKey: .success)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        nextToken = try c.decodeIfPresent(String.self, forKey: .nextToken)
        question = try c.decodeIfPresent(String.self, forKey: .questionJson).map {
            try JSONDecoder().decode(CalliopeiaQuestion.self, from: Data($0.utf8))
        }
        questions = try c.decodeIfPresent(String.self, forKey: .questionsJson).map {
            try JSONDecoder().decode([CalliopeiaQuestion].self, from: Data($0.utf8))
        }
    }
}

public struct CalliopeiaAccess: Codable, Sendable {
    public let tenantId: String?
    public let tenantName: String?
    public let email: String
    public let role: String
    public let status: String
    public let canRunJobs: Bool
    public let canViewRuns: Bool
}

public extension CalliopeiaAPIClient {
    func currentAccess() async throws -> CalliopeiaAccess {
        struct Result: Decodable { let success: Bool; let error: String?; let access: CalliopeiaAccess? }
        let credential = try await credentialProvider.credential()
        guard credential.type == .jwt else {
            throw CalliopeiaSDKError.invalidRequest("currentAccess requires a signed-in Cognito session")
        }
        let payload: [String: Result] = try await graphQL(query: """
        query CurrentAccess { getCurrentAccess { success error access {
            tenantId tenantName email role status canRunJobs canViewRuns
        } } }
        """, variables: [:], credential: credential)
        guard let result = payload["getCurrentAccess"], result.success, let access = result.access else {
            throw CalliopeiaSDKError.service(payload["getCurrentAccess"]?.error ?? "access could not be retrieved")
        }
        return access
    }

    func getProvisionalTranscript(jobID: String) async throws -> CalliopeiaTranscript {
        try await transcriptOperation("externalGetJobProvisionalTranscript", jobID: jobID)
    }

    /// Fetches a quote or an already requested output. Does not start formatting.
    func getFormattedTranscript(jobID: String) async throws -> CalliopeiaTranscript {
        try await transcriptOperation("externalGetJobTranscript", jobID: jobID)
    }

    func purchaseFormattedTranscript(jobID: String, quoteToken: String, acceptCharge: Bool) async throws -> CalliopeiaTranscript {
        guard acceptCharge, !quoteToken.isEmpty else {
            throw CalliopeiaSDKError.invalidRequest("a quote and explicit charge consent are required")
        }
        return try await transcriptOperation("externalPurchaseJobTranscript", jobID: jobID,
            quoteToken: quoteToken)
    }

    func getQuestions(jobID: String, questionID: String? = nil, nextToken: String? = nil) async throws -> CalliopeiaQuestions {
        let result: CalliopeiaQuestions = try await followUp(
            field: "externalGetJobQuestions", mutation: false, jobID: jobID,
            parameters: ["questionId": questionID.map(JSONValue.string), "nextToken": nextToken.map(JSONValue.string)],
            definitions: "$questionId: String, $nextToken: String",
            arguments: "questionId: $questionId, nextToken: $nextToken",
            selection: "success error questionJson questionsJson nextToken")
        guard result.success else { throw CalliopeiaSDKError.service(result.error ?? "question lookup failed") }
        return result
    }

    /// Persist requestID and reuse it only when retrying the same question.
    func askQuestion(jobID: String, question: String, requestID: String,
                     parentQuestionID: String? = nil, sectionIndex: Int? = nil) async throws -> CalliopeiaQuestions {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              question.utf16.count <= 4000, (8...128).contains(requestID.count),
              sectionIndex.map({ $0 >= 0 }) ?? true else {
            throw CalliopeiaSDKError.invalidRequest("invalid question, requestID or sectionIndex")
        }
        let result: CalliopeiaQuestions = try await followUp(
            field: "externalAskJobQuestion", mutation: true, jobID: jobID,
            parameters: ["question": .string(question), "requestId": .string(requestID),
                         "parentQuestionId": parentQuestionID.map(JSONValue.string),
                         "sectionIndex": sectionIndex.map { .number(Double($0)) }],
            definitions: "$question: String!, $requestId: String!, $parentQuestionId: String, $sectionIndex: Int",
            arguments: "question: $question, requestId: $requestId, parentQuestionId: $parentQuestionId, sectionIndex: $sectionIndex",
            selection: "success error questionJson questionsJson nextToken")
        guard result.success else { throw CalliopeiaSDKError.service(result.error ?? "question request failed") }
        return result
    }

    private func transcriptOperation(_ field: String, jobID: String, quoteToken: String? = nil) async throws -> CalliopeiaTranscript {
        let result: CalliopeiaTranscript = try await followUp(
            field: field, mutation: quoteToken != nil, jobID: jobID,
            parameters: quoteToken.map { ["quoteToken": .string($0), "acceptCharge": .bool(true)] } ?? [:],
            definitions: quoteToken == nil ? "" : "$quoteToken: String!, $acceptCharge: Boolean!",
            arguments: quoteToken == nil ? "" : "quoteToken: $quoteToken, acceptCharge: $acceptCharge",
            selection: "success error state quoteToken priceJpy purchasedAt transcriptJson")
        guard result.success else { throw CalliopeiaSDKError.service(result.error ?? "transcript operation failed") }
        return result
    }

    private func followUp<Result: Decodable>(field: String, mutation: Bool, jobID: String,
        parameters: [String: JSONValue?], definitions: String, arguments: String, selection: String) async throws -> Result {
        guard !jobID.isEmpty else { throw CalliopeiaSDKError.invalidRequest("jobID is required") }
        let credential = try await credentialProvider.credential()
        var variables = parameters.compactMapValues { $0 }
        variables["jobId"] = .string(jobID)
        variables["credential"] = .string(credential.value)
        variables["authType"] = .string(credential.type.rawValue)
        let query = """
        \(mutation ? "mutation" : "query") FollowUp($credential: String!, $authType: String!, $jobId: ID!\(definitions.isEmpty ? "" : ", " + definitions)) {
          \(field)(credential: $credential, authType: $authType, jobId: $jobId\(arguments.isEmpty ? "" : ", " + arguments)) { \(selection) }
        }
        """
        let payload: [String: Result] = try await graphQL(query: query, variables: variables, credential: credential)
        guard let result = payload[field] else { throw CalliopeiaSDKError.invalidResponse("missing operation result") }
        return result
    }
}
