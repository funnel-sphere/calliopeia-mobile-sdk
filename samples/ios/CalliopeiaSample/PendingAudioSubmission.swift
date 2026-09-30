import CalliopeiaSDK
import Foundation

/// Keep this object until the submission succeeds. An uncertain invoke response
/// must retry the original objectKey and idempotency key together.
@MainActor
final class PendingAudioSubmission {
    private let fileURL: URL
    private let durationSeconds: Double
    private let request: CalliopeiaAudioJobRequest
    private var ticket: CalliopeiaUploadTicket?

    init(fileURL: URL, durationSeconds: Double, request: CalliopeiaAudioJobRequest = .qualityBatch()) {
        self.fileURL = fileURL
        self.durationSeconds = durationSeconds
        self.request = request
    }

    func submit(using api: CalliopeiaAPIClient) async throws -> CalliopeiaJobSubmission {
        if ticket == nil {
            let created = try await api.createAudioUpload(fileName: fileURL.lastPathComponent, contentType: "audio/mp4")
            try await api.uploadAudio(fileURL: fileURL, using: created)
            // No job has been invoked before this point. After this point, never
            // create a replacement objectKey for this idempotency key.
            ticket = created
        }
        guard let ticket else { throw CalliopeiaSDKError.invalidRequest("upload did not complete") }
        let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        return try await api.invokeAudioJob(ticket: ticket, fileName: fileURL.lastPathComponent,
                                           fileSizeBytes: size, audioSeconds: durationSeconds, request: request)
    }
}
