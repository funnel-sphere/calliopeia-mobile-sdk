import Foundation

public actor CalliopeiaAPIClient {
    private let configuration: CalliopeiaAPIConfiguration
    private let credentialProvider: any CalliopeiaCredentialProvider
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        configuration: CalliopeiaAPIConfiguration,
        credentialProvider: any CalliopeiaCredentialProvider,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.credentialProvider = credentialProvider
        self.session = session
    }

    public func createAudioUpload(fileName: String, contentType: String) async throws -> CalliopeiaUploadTicket {
        guard !fileName.isEmpty, !contentType.isEmpty else {
            throw CalliopeiaSDKError.invalidRequest("fileName and contentType are required")
        }
        let credential = try await credentialProvider.credential()
        let variables: [String: JSONValue] = [
            "credential": .string(credential.value),
            "authType": .string(credential.type.rawValue),
            "fileName": .string(fileName),
            "contentType": .string(contentType),
        ]
        let payload: CreateAudioUploadPayload = try await graphQL(
            query: Self.createAudioUploadMutation,
            variables: variables,
            credential: credential
        )
        guard payload.externalCreateAudioUpload.success,
              let upload = payload.externalCreateAudioUpload.upload else {
            throw CalliopeiaSDKError.service(
                payload.externalCreateAudioUpload.error ?? "Calliopeia rejected the upload request"
            )
        }
        return upload
    }

    public func uploadAudio(fileURL: URL, using ticket: CalliopeiaUploadTicket) async throws {
        var request = URLRequest(url: ticket.uploadURL)
        request.httpMethod = ticket.method
        request.setValue(ticket.contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await session.upload(for: request, fromFile: fileURL)
        try Self.validateHTTP(response: response, body: nil)
    }

    public func invokeAudioJob(
        ticket: CalliopeiaUploadTicket,
        fileName: String,
        fileSizeBytes: Int,
        audioSeconds: Double?,
        request jobRequest: CalliopeiaAudioJobRequest
    ) async throws -> CalliopeiaJobSubmission {
        guard fileSizeBytes > 0, fileSizeBytes <= 2 * 1_024 * 1_024 * 1_024 else {
            throw CalliopeiaSDKError.invalidRequest("audio file must be between 1 byte and 2 GiB")
        }
        guard !jobRequest.idempotencyKey.isEmpty, jobRequest.idempotencyKey.count <= 128 else {
            throw CalliopeiaSDKError.invalidRequest("idempotencyKey must be 1 to 128 characters")
        }
        if let audioSeconds, !audioSeconds.isFinite || audioSeconds < 0 {
            throw CalliopeiaSDKError.invalidRequest("audioSeconds must be a finite non-negative number")
        }
        if let batchSize = jobRequest.auditBatchSize, !(1...16).contains(batchSize) {
            throw CalliopeiaSDKError.invalidRequest("auditBatchSize must be between 1 and 16")
        }
        if jobRequest.responseMode == .webhook, jobRequest.webhookEndpointID == nil {
            throw CalliopeiaSDKError.invalidRequest("webhookEndpointID is required for WEBHOOK mode")
        }

        let credential = try await credentialProvider.credential()
        var variables: [String: JSONValue] = [
            "credential": .string(credential.value),
            "authType": .string(credential.type.rawValue),
            "objectKey": .string(ticket.objectKey),
            "fileName": .string(fileName),
            "contentType": .string(ticket.contentType),
            "fileSizeBytes": .number(Double(fileSizeBytes)),
            "responseMode": .string(jobRequest.responseMode.rawValue),
            "idempotencyKey": .string(jobRequest.idempotencyKey),
        ]
        variables.set(audioSeconds.map(JSONValue.number), for: "audioSeconds")
        variables.set(jobRequest.processingProfileID.map(JSONValue.string), for: "processingProfileId")
        variables.set(jobRequest.extractionEffort.map { .string($0.rawValue) }, for: "extractionEffort")
        variables.set(jobRequest.auditMode.map { .string($0.rawValue) }, for: "transcriptSupportAuditMode")
        variables.set(jobRequest.auditEffort.map { .string($0.rawValue) }, for: "auditEffort")
        variables.set(jobRequest.auditStrategy.map { .string($0.rawValue) }, for: "auditStrategy")
        variables.set(jobRequest.auditBatchSize.map { .number(Double($0)) }, for: "auditBatchSize")
        variables.set(jobRequest.promptText.map(JSONValue.string), for: "promptText")
        variables.set(jobRequest.promptTemplateID.map(JSONValue.string), for: "promptTemplateId")
        variables.set(jobRequest.promptTitle.map(JSONValue.string), for: "promptTitle")
        variables.set(jobRequest.webhookEndpointID.map(JSONValue.string), for: "webhookEndpointId")
        variables.set(jobRequest.userID.map(JSONValue.string), for: "userId")
        variables.set(jobRequest.shopID.map(JSONValue.string), for: "shopId")
        variables.set(jobRequest.customerID.map(JSONValue.string), for: "customerId")
        variables.set(jobRequest.expectedAddressee.map(JSONValue.string), for: "expectedAddressee")
        variables.set(jobRequest.karteID.map(JSONValue.string), for: "karteId")
        variables.set(jobRequest.summaryID.map(JSONValue.string), for: "summaryId")
        if let passthrough = jobRequest.passthrough {
            let data = try passthrough.validatedPassthroughData()
            guard let json = String(data: data, encoding: .utf8) else {
                throw CalliopeiaSDKError.invalidRequest("passthrough is not valid UTF-8 JSON")
            }
            variables["passthrough"] = .string(json)
        }

        let payload: InvokeAudioJobPayload = try await graphQL(
            query: Self.invokeAudioJobMutation,
            variables: variables,
            credential: credential
        )
        let result = payload.externalInvokeAudioJob
        guard result.success, let job = result.job else {
            throw CalliopeiaSDKError.service(result.error ?? "Calliopeia rejected the audio job")
        }
        return CalliopeiaJobSubmission(
            message: result.message,
            idempotentReplay: result.idempotentReplay ?? false,
            subscriptionToken: result.subscriptionToken,
            statusURL: result.statusURL,
            job: job
        )
    }

    public func submitAudio(
        fileURL: URL,
        fileName: String? = nil,
        contentType: String = "audio/wav",
        audioSeconds: Double? = nil,
        request: CalliopeiaAudioJobRequest
    ) async throws -> CalliopeiaJobSubmission {
        let resolvedFileName = fileName ?? fileURL.lastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CalliopeiaSDKError.invalidRequest("unable to determine audio file size")
        }
        let ticket = try await createAudioUpload(fileName: resolvedFileName, contentType: contentType)
        try await uploadAudio(fileURL: fileURL, using: ticket)
        return try await invokeAudioJob(
            ticket: ticket,
            fileName: resolvedFileName,
            fileSizeBytes: size.intValue,
            audioSeconds: audioSeconds,
            request: request
        )
    }

    public func getJob(id: String) async throws -> CalliopeiaJobSnapshot {
        guard !id.isEmpty else {
            throw CalliopeiaSDKError.invalidRequest("job id is required")
        }
        let credential = try await credentialProvider.credential()
        let variables: [String: JSONValue] = [
            "credential": .string(credential.value),
            "authType": .string(credential.type.rawValue),
            "id": .string(id),
        ]
        let payload: GetAudioJobPayload = try await graphQL(
            query: Self.getAudioJobQuery,
            variables: variables,
            credential: credential
        )
        guard payload.externalGetJob.success, let job = payload.externalGetJob.job else {
            throw CalliopeiaSDKError.service(
                payload.externalGetJob.error ?? "Calliopeia could not retrieve the job"
            )
        }
        return job
    }

    public func getPullJob(id: String) async throws -> CalliopeiaPullJobResponse {
        guard let baseURL = configuration.pullAPIBaseURL else {
            throw CalliopeiaSDKError.missingPullAPIBaseURL
        }
        let credential = try await credentialProvider.credential()
        guard credential.type == .apiKey else {
            throw CalliopeiaSDKError.invalidRequest("the pull API currently requires an API_KEY credential")
        }
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("jobs")
            .appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.value)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response: response, body: data)
        return try decoder.decode(CalliopeiaPullJobResponse.self, from: data)
    }

    private func graphQL<Payload: Decodable>(
        query: String,
        variables: [String: JSONValue],
        credential: CalliopeiaCredential
    ) async throws -> Payload {
        var request = URLRequest(url: configuration.graphQLEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        switch configuration.graphQLAuthorization {
        case .apiKey:
            request.setValue(configuration.appSyncAPIKey, forHTTPHeaderField: "x-api-key")
        case .cognitoUserPools:
            guard credential.type == .jwt else {
                throw CalliopeiaSDKError.invalidRequest(
                    "Cognito User Pools GraphQL authorization requires a JWT credential"
                )
            }
            request.setValue(credential.value, forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try encoder.encode(GraphQLRequest(query: query, variables: variables))
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response: response, body: data)
        let envelope = try decoder.decode(GraphQLResponse<Payload>.self, from: data)
        if let errors = envelope.errors, !errors.isEmpty {
            throw CalliopeiaSDKError.service(errors.map(\.message).joined(separator: "; "))
        }
        guard let payload = envelope.data else {
            throw CalliopeiaSDKError.invalidResponse("GraphQL response did not contain data")
        }
        return payload
    }

    private static func validateHTTP(response: URLResponse, body: Data?) throws {
        guard let response = response as? HTTPURLResponse else {
            throw CalliopeiaSDKError.invalidResponse("response was not HTTP")
        }
        guard (200..<300).contains(response.statusCode) else {
            let text = body.flatMap { String(data: $0, encoding: .utf8) }
            throw CalliopeiaSDKError.http(statusCode: response.statusCode, body: text)
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    mutating func set(_ value: JSONValue?, for key: String) {
        if let value { self[key] = value }
    }
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: JSONValue]
}

private struct GraphQLResponse<Payload: Decodable>: Decodable {
    let data: Payload?
    let errors: [GraphQLError]?
}

private struct GraphQLError: Decodable {
    let message: String
}

private struct CreateAudioUploadPayload: Decodable {
    let externalCreateAudioUpload: CreateAudioUploadResult
}

private struct CreateAudioUploadResult: Decodable {
    let success: Bool
    let error: String?
    let upload: CalliopeiaUploadTicket?
}

private struct InvokeAudioJobPayload: Decodable {
    let externalInvokeAudioJob: InvokeAudioJobResult
}

private struct GetAudioJobPayload: Decodable {
    let externalGetJob: GetAudioJobResult
}

private struct GetAudioJobResult: Decodable {
    let success: Bool
    let error: String?
    let job: CalliopeiaJobSnapshot?
}

private struct InvokeAudioJobResult: Decodable {
    let success: Bool
    let error: String?
    let message: String?
    let idempotentReplay: Bool?
    let subscriptionToken: String?
    let statusURL: URL?
    let job: CalliopeiaAcceptedJob?

    enum CodingKeys: String, CodingKey {
        case success, error, message, idempotentReplay, subscriptionToken, job
        case statusURL = "statusUrl"
    }
}

private extension CalliopeiaAPIClient {
    static let createAudioUploadMutation = #"""
    mutation CreateAudioUpload($credential: String!, $authType: String!, $fileName: String!, $contentType: String!) {
      externalCreateAudioUpload(credential: $credential, authType: $authType, fileName: $fileName, contentType: $contentType) {
        success
        error
        upload { objectKey uploadUrl method contentType expiresAt }
      }
    }
    """#

    static let invokeAudioJobMutation = #"""
    mutation InvokeAudioJob(
      $credential: String!, $authType: String!, $objectKey: String!, $fileName: String!,
      $contentType: String, $fileSizeBytes: Int, $audioSeconds: Float,
      $processingProfileId: String, $extractionEffort: String,
      $transcriptSupportAuditMode: String, $auditEffort: String,
      $auditStrategy: String, $auditBatchSize: Int, $promptText: String,
      $promptTemplateId: String, $promptTitle: String, $responseMode: String,
      $webhookEndpointId: String, $idempotencyKey: String, $userId: String,
      $shopId: String, $customerId: String, $expectedAddressee: String,
      $karteId: String, $passthrough: AWSJSON, $summaryId: String
    ) {
      externalInvokeAudioJob(
        credential: $credential, authType: $authType, objectKey: $objectKey,
        fileName: $fileName, contentType: $contentType, fileSizeBytes: $fileSizeBytes,
        audioSeconds: $audioSeconds, processingProfileId: $processingProfileId,
        extractionEffort: $extractionEffort,
        transcriptSupportAuditMode: $transcriptSupportAuditMode,
        auditEffort: $auditEffort, auditStrategy: $auditStrategy,
        auditBatchSize: $auditBatchSize, promptText: $promptText,
        promptTemplateId: $promptTemplateId, promptTitle: $promptTitle,
        responseMode: $responseMode, webhookEndpointId: $webhookEndpointId,
        idempotencyKey: $idempotencyKey, userId: $userId, shopId: $shopId,
        customerId: $customerId, expectedAddressee: $expectedAddressee,
        karteId: $karteId, passthrough: $passthrough, summaryId: $summaryId
      ) {
        success error message idempotentReplay subscriptionToken statusUrl
        job {
          id status externalSummaryId externalIdempotencyKey
          externalResponseMode externalCallbackStatus
        }
      }
    }
    """#

    static let getAudioJobQuery = #"""
    query GetAudioJob($credential: String!, $authType: String!, $id: String!) {
      externalGetJob(credential: $credential, authType: $authType, id: $id) {
        success
        error
        job {
          id status operation inputKind fileName audioSeconds responseText responseJson
          extractionEffort transcriptSupportAuditMode auditEffort auditStrategy auditBatchSize
          transcriptSupportAuditState transcriptSupportAuditJson deliveryBlockedReason errorMessage
          costUsd costJpy createdAt updatedAt completedAt externalShopId externalCustomerId
          externalKarteId externalSummaryId externalPassthrough
        }
      }
    }
    """#
}
