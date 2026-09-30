import Foundation

public struct CalliopeiaPromptTemplate: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let body: String?
    public let isDefault: Bool?
    public var displayTitle: String { title?.isEmpty == false ? title! : "名称未設定" }
}

public extension CalliopeiaAPIClient {
    func promptTemplates() async throws -> [CalliopeiaPromptTemplate] {
        struct Page: Decodable {
            let success: Bool
            let error: String?
            let nextToken: String?
            let prompts: [CalliopeiaPromptTemplate?]?
        }
        let credential = try await credentialProvider.credential()
        var prompts: [CalliopeiaPromptTemplate] = []
        var nextToken: String?
        var seenTokens = Set<String>()
        repeat {
            var variables: [String: JSONValue] = ["credential": .string(credential.value),
                "authType": .string(credential.type.rawValue), "limit": .number(200)]
            if let nextToken { variables["nextToken"] = .string(nextToken) }
            let response: [String: Page] = try await graphQL(query: """
            query Prompts($credential: String!, $authType: String, $limit: Int, $nextToken: String) {
              externalListPromptTemplates(credential: $credential, authType: $authType, limit: $limit, nextToken: $nextToken) {
                success error nextToken prompts { id title body isDefault }
              }
            }
            """, variables: variables, credential: credential)
            guard let page = response["externalListPromptTemplates"], page.success else {
                throw CalliopeiaSDKError.service(response["externalListPromptTemplates"]?.error ?? "could not load prompts")
            }
            prompts.append(contentsOf: (page.prompts ?? []).compactMap { $0 })
            nextToken = page.nextToken
            if let token = nextToken, !seenTokens.insert(token).inserted {
                throw CalliopeiaSDKError.invalidResponse("prompt pagination repeated its cursor")
            }
        } while nextToken != nil
        return prompts.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    /// Submit an existing transcript without uploading or re-transcribing audio.
    func submitTranscript(_ transcript: String, fileName: String,
                          processingProfileID: String) async throws -> String {
        let normalized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !fileName.isEmpty, !processingProfileID.isEmpty else {
            throw CalliopeiaSDKError.invalidRequest("transcript, fileName and processingProfileID are required")
        }
        struct Job: Decodable { let id: String }
        struct Result: Decodable { let success: Bool; let error: String?; let job: Job? }
        let credential = try await credentialProvider.credential()
        let response: [String: Result] = try await graphQL(query: """
        mutation Transcript($credential: String!, $authType: String, $transcriptText: String!,
                            $fileName: String, $processingProfileId: String) {
          externalCreateTranscriptJob(credential: $credential, authType: $authType,
            transcriptText: $transcriptText, fileName: $fileName, processingProfileId: $processingProfileId) {
            success error job { id }
          }
        }
        """, variables: ["credential": .string(credential.value), "authType": .string(credential.type.rawValue),
            "transcriptText": .string(normalized), "fileName": .string(fileName),
            "processingProfileId": .string(processingProfileID)], credential: credential)
        guard let result = response["externalCreateTranscriptJob"], result.success, let job = result.job else {
            throw CalliopeiaSDKError.service(response["externalCreateTranscriptJob"]?.error ?? "could not submit transcript")
        }
        return job.id
    }
}
