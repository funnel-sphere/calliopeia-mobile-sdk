import Foundation

public enum CalliopeiaCredentialType: String, Codable, Sendable {
    case jwt = "JWT"
    case apiKey = "API_KEY"
}

public struct CalliopeiaCredential: Sendable {
    public let value: String
    public let type: CalliopeiaCredentialType

    public init(value: String, type: CalliopeiaCredentialType = .jwt) {
        self.value = value
        self.type = type
    }
}

public protocol CalliopeiaCredentialProvider: Sendable {
    func credential() async throws -> CalliopeiaCredential
}

public struct ClosureCalliopeiaCredentialProvider: CalliopeiaCredentialProvider {
    public typealias Loader = @Sendable () async throws -> CalliopeiaCredential

    private let loader: Loader

    public init(loader: @escaping Loader) {
        self.loader = loader
    }

    public func credential() async throws -> CalliopeiaCredential {
        try await loader()
    }
}

public struct StaticCalliopeiaCredentialProvider: CalliopeiaCredentialProvider {
    private let storedCredential: CalliopeiaCredential

    public init(_ credential: CalliopeiaCredential) {
        self.storedCredential = credential
    }

    public func credential() async throws -> CalliopeiaCredential {
        storedCredential
    }
}

public enum CalliopeiaGraphQLAuthorization: Sendable {
    case apiKey
    case cognitoUserPools
}

public struct CalliopeiaAPIConfiguration: Sendable {
    public let graphQLEndpoint: URL
    public let appSyncAPIKey: String
    public let pullAPIBaseURL: URL?
    public let graphQLAuthorization: CalliopeiaGraphQLAuthorization

    public init(
        graphQLEndpoint: URL,
        appSyncAPIKey: String,
        pullAPIBaseURL: URL? = nil,
        graphQLAuthorization: CalliopeiaGraphQLAuthorization = .apiKey
    ) {
        self.graphQLEndpoint = graphQLEndpoint
        self.appSyncAPIKey = appSyncAPIKey
        self.pullAPIBaseURL = pullAPIBaseURL
        self.graphQLAuthorization = graphQLAuthorization
    }
}

public enum CalliopeiaResponseMode: String, Codable, Sendable {
    case async = "ASYNC"
    case subscription = "SUBSCRIPTION"
    case webhook = "WEBHOOK"
}

public enum CalliopeiaExtractionEffort: String, Codable, Sendable {
    case low = "LOW"
    case standard = "STANDARD"
    case maximum = "MAX"
}

public enum CalliopeiaAuditMode: String, Codable, Sendable {
    case off = "OFF"
    case observe = "OBSERVE"
    case enforce = "ENFORCE"
}

public enum CalliopeiaAuditEffort: String, Codable, Sendable {
    case standard = "STANDARD"
    case maximum = "MAX"
}

public enum CalliopeiaAuditStrategy: String, Codable, Sendable {
    case combined = "COMBINED"
    case atomicBatch = "ATOMIC_BATCH"
}

public struct CalliopeiaAudioJobRequest: Sendable {
    public var processingProfileID: String?
    public var extractionEffort: CalliopeiaExtractionEffort?
    public var auditMode: CalliopeiaAuditMode?
    public var auditEffort: CalliopeiaAuditEffort?
    public var auditStrategy: CalliopeiaAuditStrategy?
    public var auditBatchSize: Int?
    public var promptText: String?
    public var promptTemplateID: String?
    public var promptTitle: String?
    public var responseMode: CalliopeiaResponseMode
    public var webhookEndpointID: String?
    public var idempotencyKey: String
    public var userID: String?
    public var shopID: String?
    public var customerID: String?
    public var expectedAddressee: String?
    public var karteID: String?
    public var summaryID: String?
    public var passthrough: JSONValue?

    public init(
        idempotencyKey: String = UUID().uuidString,
        processingProfileID: String? = nil,
        extractionEffort: CalliopeiaExtractionEffort? = nil,
        auditMode: CalliopeiaAuditMode? = nil,
        auditEffort: CalliopeiaAuditEffort? = nil,
        auditStrategy: CalliopeiaAuditStrategy? = nil,
        auditBatchSize: Int? = nil,
        promptText: String? = nil,
        promptTemplateID: String? = nil,
        promptTitle: String? = nil,
        responseMode: CalliopeiaResponseMode = .async,
        webhookEndpointID: String? = nil,
        userID: String? = nil,
        shopID: String? = nil,
        customerID: String? = nil,
        expectedAddressee: String? = nil,
        karteID: String? = nil,
        summaryID: String? = nil,
        passthrough: JSONValue? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.processingProfileID = processingProfileID
        self.extractionEffort = extractionEffort
        self.auditMode = auditMode
        self.auditEffort = auditEffort
        self.auditStrategy = auditStrategy
        self.auditBatchSize = auditBatchSize
        self.promptText = promptText
        self.promptTemplateID = promptTemplateID
        self.promptTitle = promptTitle
        self.responseMode = responseMode
        self.webhookEndpointID = webhookEndpointID
        self.userID = userID
        self.shopID = shopID
        self.customerID = customerID
        self.expectedAddressee = expectedAddressee
        self.karteID = karteID
        self.summaryID = summaryID
        self.passthrough = passthrough
    }
}

public struct CalliopeiaUploadTicket: Codable, Equatable, Sendable {
    public let objectKey: String
    public let uploadURL: URL
    public let method: String
    public let contentType: String
    public let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case objectKey
        case uploadURL = "uploadUrl"
        case method
        case contentType
        case expiresAt
    }
}

public struct CalliopeiaAcceptedJob: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let externalSummaryID: String?
    public let externalIdempotencyKey: String?
    public let externalResponseMode: String?
    public let externalCallbackStatus: String?

    enum CodingKeys: String, CodingKey {
        case id, status
        case externalSummaryID = "externalSummaryId"
        case externalIdempotencyKey
        case externalResponseMode
        case externalCallbackStatus
    }
}

public struct CalliopeiaJobSubmission: Codable, Equatable, Sendable {
    public let message: String?
    public let idempotentReplay: Bool
    public let subscriptionToken: String?
    public let statusURL: URL?
    public let job: CalliopeiaAcceptedJob

    enum CodingKeys: String, CodingKey {
        case message, idempotentReplay, subscriptionToken, job
        case statusURL = "statusUrl"
    }
}

public struct CalliopeiaJobSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let status: String
    public let operation: String?
    public let inputKind: String?
    public let fileName: String?
    public let audioSeconds: Double?
    public let responseText: String?
    public let responseJSON: JSONValue?
    public let extractionEffort: String?
    public let auditMode: String?
    public let auditEffort: String?
    public let auditStrategy: String?
    public let auditBatchSize: Int?
    public let auditState: String?
    public let auditJSON: JSONValue?
    public let deliveryBlockedReason: String?
    public let errorMessage: String?
    public let costUSD: Double?
    public let costJPY: Double?
    public let createdAt: String?
    public let updatedAt: String?
    public let completedAt: String?
    public let externalShopID: String?
    public let externalCustomerID: String?
    public let externalKarteID: String?
    public let externalSummaryID: String?
    public let passthrough: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, status, operation, inputKind, fileName, audioSeconds, responseText
        case extractionEffort, auditEffort, auditStrategy, auditBatchSize
        case deliveryBlockedReason, errorMessage, createdAt, updatedAt, completedAt
        case responseJSON = "responseJson"
        case auditMode = "transcriptSupportAuditMode"
        case auditState = "transcriptSupportAuditState"
        case auditJSON = "transcriptSupportAuditJson"
        case costUSD = "costUsd"
        case costJPY = "costJpy"
        case externalShopID = "externalShopId"
        case externalCustomerID = "externalCustomerId"
        case externalKarteID = "externalKarteId"
        case externalSummaryID = "externalSummaryId"
        case passthrough = "externalPassthrough"
    }
}

public struct CalliopeiaPullJob: Codable, Equatable, Sendable {
    public let version: String
    public let jobID: String
    public let status: String
    public let shopID: String?
    public let customerID: String?
    public let karteID: String?
    public let summaryID: String?
    public let passthrough: JSONValue?
    public let error: JSONValue?
    public let delivery: JSONValue
    public let createdAt: String?
    public let updatedAt: String?
    public let completedAt: String?
    public let result: JSONValue?

    enum CodingKeys: String, CodingKey {
        case version, status, passthrough, error, delivery, createdAt, updatedAt, completedAt, result
        case jobID = "jobId"
        case shopID = "shopId"
        case customerID = "customerId"
        case karteID = "karteId"
        case summaryID = "summaryId"
    }
}

public struct CalliopeiaPullJobResponse: Codable, Equatable, Sendable {
    public let success: Bool
    public let job: CalliopeiaPullJob
    public let requestID: String

    enum CodingKeys: String, CodingKey {
        case success, job
        case requestID = "requestId"
    }
}

public enum CalliopeiaSDKError: Error, Equatable, Sendable {
    case invalidRequest(String)
    case invalidResponse(String)
    case service(String)
    case http(statusCode: Int, body: String?)
    case missingPullAPIBaseURL
}

extension CalliopeiaSDKError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let message): message
        case .invalidResponse(let message): message
        case .service(let message): message
        case .http(let statusCode, let body):
            body.map { "Calliopeia returned HTTP \(statusCode): \($0)" }
                ?? "Calliopeia returned HTTP \(statusCode)"
        case .missingPullAPIBaseURL:
            "pullAPIBaseURL is required to retrieve job results"
        }
    }
}
