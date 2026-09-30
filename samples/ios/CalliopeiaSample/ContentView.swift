import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var model = SampleModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Form {
                Section("録音") {
                    Text("高品質録音を端末に保存し、確認してから送信します。")
                        .foregroundStyle(.secondary)
                    if model.isRecording {
                        Button("録音を停止", role: .destructive) {
                            Task { await model.stopRecording() }
                        }.accessibilityIdentifier("stop-recording")
                    } else {
                        Button("録音開始", systemImage: "mic.fill") {
                            Task { await model.startRecording() }
                        }.accessibilityIdentifier("start-recording")
                    }
                    if let recording = model.recording {
                        Text(String(format: "保存済み · %.1f 秒", recording.durationSeconds))
                        ShareLink("録音を共有", item: recording.audioURL)
                        ShareLink("元のWAVを共有", item: recording.rawMasterURL)
                    }
                }.disabled(model.isWorking)

                Section("アカウント") {
                    if let error = model.configurationError {
                        Text(error).foregroundStyle(.secondary)
                    } else if model.signedIn {
                        Text(model.email).textSelection(.enabled)
                        Text(model.accountStatus).foregroundStyle(.secondary)
                        Button("ログアウト") { Task { await model.signOut() } }
                    } else {
                        TextField("メールアドレス", text: $model.email)
                            .keyboardType(.emailAddress)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .disabled(model.awaitingCode)
                            .accessibilityIdentifier("email")
                        if model.awaitingCode {
                            TextField("確認コード", text: $model.code)
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .accessibilityIdentifier("otp")
                            Button("コードを確認") { Task { await model.confirm() } }
                                .disabled(model.code.isEmpty)
                            Button("コードを再送") { Task { await model.resend() } }
                        } else {
                            Button("ログインコードを送信") { Task { await model.signIn() } }
                                .disabled(model.email.isEmpty)
                        }
                        Text(model.accountStatus).foregroundStyle(.secondary)
                    }
                }.disabled(model.isWorking || model.isRecording)

                Section("送信と結果") {
                    Button("録音を送信", systemImage: "arrow.up.circle") {
                        Task { await model.submit() }
                    }
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("submit-recording")
                    Text(model.status).textSelection(.enabled)
                        .accessibilityIdentifier("job-status")
                    if model.isWorking { ProgressView() }
                    if let jobID = model.jobID {
                        Text(jobID).font(.caption.monospaced()).textSelection(.enabled)
                        Button("状態を更新", systemImage: "arrow.clockwise") {
                            Task { await model.refreshStatus() }
                        }.disabled(model.isWorking || model.isRecording)
                    }
                    if !model.result.isEmpty {
                        Text(model.result).textSelection(.enabled)
                            .accessibilityIdentifier("job-result")
                    }
                }
                Section {
                    Text("録音と結果は機微情報を含む場合があります。共有先を確認してください。端末内の保存ファイルは自動削除されません。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Calliopeia Sample")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
        }
        .task { await model.configure() }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
            if let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
               type == AVAudioSession.InterruptionType.began.rawValue {
                Task { await model.stopRecording(interrupted: true) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // This sample has no background-recording entitlement.
            if phase == .background { Task { await model.stopRecording(interrupted: true) } }
        }
    }
}
