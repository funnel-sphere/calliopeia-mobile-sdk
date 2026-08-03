import CalliopeiaSDK
import Foundation

@MainActor
final class SampleModel: ObservableObject {
    @Published var graphQLEndpoint = ""
    @Published var appSyncAPIKey = ""
    @Published var accessToken = ""
    @Published var externalRecordID = "sample-record-001"
    @Published private(set) var isRecording = false
    @Published private(set) var isWorking = false
    @Published private(set) var status = "接続情報を入力してください"
    @Published private(set) var jobID: String?

    private var apiClient: CalliopeiaAPIClient?
    private var recordingClient: CalliopeiaRecordingClient?

    var canStart: Bool {
        !isWorking && !isRecording &&
            !graphQLEndpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !appSyncAPIKey.isEmpty && !accessToken.isEmpty
    }

    var canRefresh: Bool { !isWorking && jobID != nil && apiClient != nil }

    func startRecording() async {
        guard canStart else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            guard await CalliopeiaRecordingClient.requestRecordPermission() else {
                status = "マイクの利用が許可されていません"
                return
            }
            let (api, recorder) = try makeClients()
            let format = try recorder.startRecording(mode: .rawMaster)
            apiClient = api
            recordingClient = recorder
            isRecording = true
            status = "録音中: \(format.actualSampleRate) Hz / \(format.channelCount) ch"
        } catch {
            status = message(for: error)
        }
    }

    func stopAndSubmit() async {
        guard isRecording, let recordingClient else { return }
        isWorking = true
        status = "音声を送信しています"
        defer { isWorking = false }

        do {
            let reference = externalRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
            let passthrough: JSONValue = .object([
                "external_record_id": .string(reference),
                "source": .string("ios-sample"),
            ])
            let request = CalliopeiaAudioJobRequest(
                extractionEffort: .standard,
                auditMode: .observe,
                auditEffort: .standard,
                auditStrategy: .atomicBatch,
                passthrough: passthrough
            )
            let result = try await recordingClient.stopAndSubmit(request: request)
            isRecording = false
            jobID = result.submission.job.id
            status = "受付済み: \(result.submission.job.status)"
        } catch {
            isRecording = false
            status = message(for: error)
        }
    }

    func refreshStatus() async {
        guard let apiClient, let jobID else { return }
        isWorking = true
        status = "状態を確認しています"
        defer { isWorking = false }

        do {
            let snapshot = try await apiClient.getJob(id: jobID)
            status = "\(snapshot.status) / \(snapshot.id)"
        } catch {
            status = message(for: error)
        }
    }

    private func makeClients() throws -> (CalliopeiaAPIClient, CalliopeiaRecordingClient) {
        guard let endpoint = URL(string: graphQLEndpoint), endpoint.scheme == "https" else {
            throw SampleError.invalidEndpoint
        }
        let credential = StaticCalliopeiaCredentialProvider(
            CalliopeiaCredential(value: accessToken, type: .jwt)
        )
        let api = CalliopeiaAPIClient(
            configuration: .init(
                graphQLEndpoint: endpoint,
                appSyncAPIKey: appSyncAPIKey
            ),
            credentialProvider: credential
        )
        return (api, CalliopeiaRecordingClient(apiClient: api))
    }

    private func message(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

private enum SampleError: LocalizedError {
    case invalidEndpoint

    var errorDescription: String? {
        "GraphQL endpointにはHTTPS URLを指定してください"
    }
}
