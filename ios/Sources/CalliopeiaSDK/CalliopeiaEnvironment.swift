import Foundation

/// Reads public deployment configuration, never a user's session or tenant key.
public struct CalliopeiaEnvironment: Sendable {
    public let api: CalliopeiaAPIConfiguration

    public init(amplifyOutputs data: Data, pullAPIBaseURL: URL? = nil) throws {
        struct Outputs: Decodable {
            struct API: Decodable { let url: URL; let api_key: String? }
            let data: API
        }
        let outputs = try JSONDecoder().decode(Outputs.self, from: data)
        guard outputs.data.url.scheme == "https" else {
            throw CalliopeiaSDKError.invalidRequest("GraphQL endpoint must use HTTPS")
        }
        api = .init(graphQLEndpoint: outputs.data.url,
                    appSyncAPIKey: outputs.data.api_key ?? "",
                    pullAPIBaseURL: pullAPIBaseURL,
                    graphQLAuthorization: .cognitoUserPools)
    }

    public static func load(bundle: Bundle = .main, pullAPIBaseURL: URL? = nil) throws -> Self {
        guard let url = bundle.url(forResource: "amplify_outputs", withExtension: "json") else {
            throw CalliopeiaSDKError.invalidRequest("amplify_outputs.json is missing")
        }
        return try .init(amplifyOutputs: Data(contentsOf: url), pullAPIBaseURL: pullAPIBaseURL)
    }
}
