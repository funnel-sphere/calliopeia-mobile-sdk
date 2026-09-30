import AVFoundation
import CalliopeiaAuth
import CalliopeiaSDK
import SwiftUI

@MainActor
final class SampleModel: ObservableObject {
    @Published var email = ""
    @Published var code = ""
    @Published private(set) var loginStep: CalliopeiaLoginStep = .signedOut
    @Published private(set) var configurationError: String?
    @Published private(set) var accountStatus = "ログインすると音声を送信できます"
    @Published private(set) var status = "録音はログイン前でも利用できます"
    @Published private(set) var isRecording = false
    @Published private(set) var isWorking = false
    @Published private(set) var recording: CalliopeiaHighQualityRecording?
    @Published private(set) var jobID: String?
    @Published private(set) var result = ""
    @Published private(set) var canRunJobs = false

    private let recorder = CalliopeiaHighQualityRecorder()
    private let session = CalliopeiaSession()
    private var api: CalliopeiaAPIClient?
    private var configured = false
    private var pendingSubmission: PendingAudioSubmission?

    var signedIn: Bool {
        if case .signedIn = loginStep { return true }
        return false
    }
    var awaitingCode: Bool {
        loginStep == .emailCode || loginStep == .accountConfirmation
    }
    var canSubmit: Bool {
        signedIn && canRunJobs && recording != nil && jobID == nil && !isRecording && !isWorking
    }

    func configure() async {
        guard !configured else { return }
        configured = true
        do {
            let environment = try CalliopeiaEnvironment.load()
            try CalliopeiaSession.configure()
            api = session.makeAPI(environment: environment)
            await authenticate { try await self.session.restore() }
        } catch {
            configurationError = "接続設定がありません。READMEに従って amplify_outputs.json を追加してください。"
        }
    }

    func signIn() async { await authenticate { try await self.session.signIn(email: self.email) } }
    func confirm() async { await authenticate { try await self.session.confirm(code: self.code) } }
    func resend() async { await authenticate { try await self.session.resendCode() } }

    private func authenticate(_ action: () async throws -> CalliopeiaLoginStep) async {
        guard !isWorking, !isRecording else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            loginStep = try await action()
            code = ""
            switch loginStep {
            case .signedIn(let account):
                email = account.email
                accountStatus = "ログイン済み"
                let access = try await api?.currentAccess()
                canRunJobs = access?.canRunJobs == true
                accountStatus = canRunJobs ? "音声を送信できます" : "このアカウントには音声送信の権限がありません"
            case .emailCode: accountStatus = "メールに届いたコードを入力してください"
            case .accountConfirmation: accountStatus = "メールに届いたアカウント確認コードを入力してください"
            case .signedOut: accountStatus = "登録済みのメールアドレスでログインしてください"
            }
        } catch { accountStatus = message(for: error) }
    }

    func signOut() async {
        guard !isWorking, !isRecording else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await session.signOut()
            loginStep = .signedOut
            canRunJobs = false
            code = ""
            jobID = nil
            result = ""
            pendingSubmission = nil
            accountStatus = "ログアウトしました"
        } catch { accountStatus = message(for: error) }
    }

    func startRecording() async {
        guard !isWorking, !isRecording else { return }
        isWorking = true
        defer { isWorking = false }
        guard await CalliopeiaHighQualityRecorder.requestPermission() else {
            status = "設定アプリでマイクの利用を許可してください"
            return
        }
        do {
            let format = try recorder.start()
            recording = nil
            jobID = nil
            result = ""
            pendingSubmission = nil
            isRecording = true
            UIApplication.shared.isIdleTimerDisabled = true
            status = "録音中 · \(Int(format.actualSampleRate)) Hz / \(format.channelCount) ch"
        } catch { status = message(for: error) }
    }

    func stopRecording(interrupted: Bool = false) async {
        guard isRecording, !isWorking else { return }
        isWorking = true
        defer {
            isWorking = false
            isRecording = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            recording = try await recorder.stop()
            status = interrupted ? "録音が中断されました。音声は端末に保存しました" : "録音を端末に保存しました。送信するには下のボタンを押してください"
        } catch {
            status = "保存処理に失敗しました。元のWAVは端末に残っています。 " + message(for: error)
        }
    }

    func submit() async {
        guard canSubmit, let api, let recording else { return }
        isWorking = true
        status = "音声を送信しています"
        defer { isWorking = false }
        do {
            if pendingSubmission == nil {
                pendingSubmission = PendingAudioSubmission(fileURL: recording.audioURL,
                                                           durationSeconds: recording.durationSeconds)
            }
            guard let pendingSubmission else { return }
            let submission = try await pendingSubmission.submit(using: api)
            jobID = submission.job.id
            status = "受付済み。状態を更新して結果を確認してください"
        } catch { status = message(for: error) }
    }

    func refreshStatus() async {
        guard !isWorking, !isRecording, let api, let jobID else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let job = try await api.getJob(id: jobID)
            status = "処理状態: " + job.status
            if let text = job.responseText {
                struct Field: Decodable { let title: String; let body: String }
                if let fields = try? JSONDecoder().decode([Field].self, from: Data(text.utf8)) {
                    result = fields.map { $0.title + "\n" + $0.body }.joined(separator: "\n\n")
                } else { result = text }
            }
        } catch { status = message(for: error) }
    }

    private func message(for error: Error) -> String {
        // Do not log tokens, OTP values, or server response bodies.
        (error as? LocalizedError)?.errorDescription ?? "処理に失敗しました。接続と設定を確認して再試行してください"
    }
}
