import Foundation
import XCTest
@testable import CalliopeiaSDK

final class CalliopeiaSDKTests: XCTestCase {
    override func setUp() {
        super.setUp()
        URLProtocolStub.handler = nil
    }

    func testProcessingOptionRawValuesMatchExternalAPIContract() {
        XCTAssertEqual(CalliopeiaExtractionEffort.low.rawValue, "LOW")
        XCTAssertEqual(CalliopeiaExtractionEffort.standard.rawValue, "STANDARD")
        XCTAssertEqual(CalliopeiaExtractionEffort.maximum.rawValue, "MAX")
        XCTAssertEqual(CalliopeiaAuditMode.off.rawValue, "OFF")
        XCTAssertEqual(CalliopeiaAuditMode.observe.rawValue, "OBSERVE")
        XCTAssertEqual(CalliopeiaAuditMode.enforce.rawValue, "ENFORCE")
        XCTAssertEqual(CalliopeiaAuditEffort.standard.rawValue, "STANDARD")
        XCTAssertEqual(CalliopeiaAuditEffort.maximum.rawValue, "MAX")
        XCTAssertEqual(CalliopeiaAuditStrategy.combined.rawValue, "COMBINED")
        XCTAssertEqual(CalliopeiaAuditStrategy.atomicBatch.rawValue, "ATOMIC_BATCH")
    }

    func testSubmitUploadsThenInvokesWithPassthrough() async throws {
        let audio = FileManager.default.temporaryDirectory
            .appendingPathComponent("calliopeia-sdk-test-\(UUID().uuidString).wav")
        try Data(repeating: 0x5a, count: 128).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        var requests = [URLRequest]()
        URLProtocolStub.handler = { request in
            requests.append(request)
            if request.url?.host == "graphql.example.com" {
                let body = try request.bodyData()
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                let query = try XCTUnwrap(object["query"] as? String)
                if query.contains("CreateAudioUpload") {
                    return Self.jsonResponse(
                        url: request.url!,
                        body: #"{"data":{"externalCreateAudioUpload":{"success":true,"error":null,"upload":{"objectKey":"tenant/audio.wav","uploadUrl":"https://upload.example.com/audio.wav","method":"PUT","contentType":"audio/wav","expiresAt":"2026-08-03T00:00:00Z"}}}}"#
                    )
                }
                let variables = try XCTUnwrap(object["variables"] as? [String: Any])
                XCTAssertEqual(variables["passthrough"] as? String, #"{"crm_record_id":"C-123"}"#)
                XCTAssertEqual(variables["extractionEffort"] as? String, "MAX")
                return Self.jsonResponse(
                    url: request.url!,
                    body: #"{"data":{"externalInvokeAudioJob":{"success":true,"error":null,"message":"queued","idempotentReplay":false,"subscriptionToken":null,"statusUrl":"https://pull.example.com/v1/jobs/abc","job":{"id":"abc","status":"QUEUED","externalSummaryId":null,"externalIdempotencyKey":"idem-1","externalResponseMode":"ASYNC","externalCallbackStatus":null}}}}"#
                )
            }
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }

        let client = CalliopeiaAPIClient(
            configuration: .init(
                graphQLEndpoint: URL(string: "https://graphql.example.com/graphql")!,
                appSyncAPIKey: "public-appsync-key",
                pullAPIBaseURL: URL(string: "https://pull.example.com")!
            ),
            credentialProvider: StaticCalliopeiaCredentialProvider(
                .init(value: "short-lived-jwt", type: .jwt)
            ),
            session: Self.stubSession()
        )
        let result = try await client.submitAudio(
            fileURL: audio,
            request: .init(
                idempotencyKey: "idem-1",
                extractionEffort: .maximum,
                passthrough: .object(["crm_record_id": .string("C-123")])
            )
        )

        XCTAssertEqual(result.job.id, "abc")
        XCTAssertEqual(requests.count, 3)
    }

    func testRejectsOversizedPassthroughBeforeNetwork() async throws {
        let client = CalliopeiaAPIClient(
            configuration: .init(
                graphQLEndpoint: URL(string: "https://graphql.example.com/graphql")!,
                appSyncAPIKey: "key"
            ),
            credentialProvider: StaticCalliopeiaCredentialProvider(.init(value: "jwt")),
            session: Self.stubSession()
        )
        let ticket = CalliopeiaUploadTicket(
            objectKey: "tenant/audio.wav",
            uploadURL: URL(string: "https://upload.example.com/audio.wav")!,
            method: "PUT",
            contentType: "audio/wav",
            expiresAt: nil
        )
        let passthrough = JSONValue.object(["payload": .string(String(repeating: "x", count: 17_000))])

        do {
            _ = try await client.invokeAudioJob(
                ticket: ticket,
                fileName: "audio.wav",
                fileSizeBytes: 100,
                audioSeconds: 1,
                request: .init(idempotencyKey: "idem", passthrough: passthrough)
            )
            XCTFail("Expected passthrough validation to fail")
        } catch let error as CalliopeiaSDKError {
            guard case .invalidRequest = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGetJobUsesGraphQLWithCurrentJWTCredential() async throws {
        URLProtocolStub.handler = { request in
            let body = try request.bodyData()
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let variables = try XCTUnwrap(object["variables"] as? [String: Any])
            XCTAssertEqual(variables["credential"] as? String, "refreshed-jwt")
            XCTAssertEqual(variables["authType"] as? String, "JWT")
            XCTAssertEqual(variables["id"] as? String, "job-123")
            return Self.jsonResponse(
                url: request.url!,
                body: #"{"data":{"externalGetJob":{"success":true,"error":null,"job":{"id":"job-123","status":"SUCCEEDED","operation":"ANALYZE","inputKind":"AUDIO","fileName":"audio.wav","audioSeconds":10,"responseText":"ok","responseJson":{"summary":"ok"},"extractionEffort":"MAX","transcriptSupportAuditMode":"OBSERVE","auditEffort":"MAX","auditStrategy":"ATOMIC_BATCH","auditBatchSize":4,"transcriptSupportAuditState":"PASSED","transcriptSupportAuditJson":null,"deliveryBlockedReason":null,"errorMessage":null,"costUsd":0.1,"costJpy":15,"createdAt":null,"updatedAt":null,"completedAt":null,"externalShopId":null,"externalCustomerId":null,"externalKarteId":null,"externalSummaryId":null,"externalPassthrough":{"crm_id":"C-123"}}}}}"#
            )
        }

        let provider = ClosureCalliopeiaCredentialProvider {
            CalliopeiaCredential(value: "refreshed-jwt")
        }
        let client = CalliopeiaAPIClient(
            configuration: .init(
                graphQLEndpoint: URL(string: "https://graphql.example.com/graphql")!,
                appSyncAPIKey: "public-appsync-key"
            ),
            credentialProvider: provider,
            session: Self.stubSession()
        )

        let job = try await client.getJob(id: "job-123")
        XCTAssertEqual(job.id, "job-123")
        XCTAssertEqual(job.auditMode, "OBSERVE")
        XCTAssertEqual(job.passthrough, .object(["crm_id": .string("C-123")]))
    }

    func testGetPullJobUsesCurrentAPIKeyCredential() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://pull.example.com/v1/jobs/job-123")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer refreshed-api-key")
            return Self.jsonResponse(
                url: request.url!,
                body: #"{"success":true,"job":{"version":"1","jobId":"job-123","status":"SUCCEEDED","shopId":null,"customerId":null,"karteId":null,"summaryId":null,"passthrough":{"crm_id":"C-123"},"error":null,"delivery":{},"createdAt":null,"updatedAt":null,"completedAt":null,"result":{"summary":"ok"}},"requestId":"request-1"}"#
            )
        }

        let provider = ClosureCalliopeiaCredentialProvider {
            CalliopeiaCredential(value: "refreshed-api-key", type: .apiKey)
        }
        let client = CalliopeiaAPIClient(
            configuration: .init(
                graphQLEndpoint: URL(string: "https://graphql.example.com/graphql")!,
                appSyncAPIKey: "public-appsync-key",
                pullAPIBaseURL: URL(string: "https://pull.example.com")!
            ),
            credentialProvider: provider,
            session: Self.stubSession()
        )

        let response = try await client.getPullJob(id: "job-123")
        XCTAssertEqual(response.job.jobID, "job-123")
        XCTAssertEqual(response.job.passthrough, .object(["crm_id": .string("C-123")]))
    }

    private static func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func jsonResponse(url: URL, body: String) -> (HTTPURLResponse, Data) {
        (
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!,
            Data(body.utf8)
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func bodyData() throws -> Data {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else {
            throw CalliopeiaSDKError.invalidRequest("test request did not contain a body")
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? CalliopeiaSDKError.invalidResponse("body stream failed") }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
