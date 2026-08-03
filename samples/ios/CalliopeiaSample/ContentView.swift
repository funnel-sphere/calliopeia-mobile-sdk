import SwiftUI

struct ContentView: View {
    @StateObject private var model = SampleModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case endpoint
        case apiKey
        case token
        case recordID
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    connectionSection
                    recordingSection
                    jobSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Calliopeia Sample")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完了") { focusedField = nil }
                }
            }
        }
        .navigationViewStyle(.stack)
        .tint(.calliopeiaPink)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("接続", systemImage: "network")
            field("GraphQL endpoint", text: $model.graphQLEndpoint, field: .endpoint)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            field("AppSync API key", text: $model.appSyncAPIKey, field: .apiKey)
                .textInputAutocapitalization(.never)
            SecureField("短期JWT", text: $model.accessToken)
                .textContentType(.password)
                .focused($focusedField, equals: .token)
                .sampleField()
                .accessibilityIdentifier("access-token")
            Text("認証情報はこのセッション内だけで保持されます")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("録音と送信", systemImage: "waveform")
            field("自社レコードID", text: $model.externalRecordID, field: .recordID)
                .textInputAutocapitalization(.never)

            HStack(spacing: 12) {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    Label("録音開始", systemImage: "mic.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                .accessibilityIdentifier("start-recording")

                Button {
                    Task { await model.stopAndSubmit() }
                } label: {
                    Label("停止・送信", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .disabled(!model.isRecording || model.isWorking)
                .accessibilityIdentifier("stop-and-submit")
            }
        }
    }

    private var jobSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("ジョブ", systemImage: "doc.text.magnifyingglass")
            Text(model.status)
                .font(.body.monospaced())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                .textSelection(.enabled)
                .accessibilityIdentifier("job-status")

            Button {
                Task { await model.refreshStatus() }
            } label: {
                Label("状態を更新", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .disabled(!model.canRefresh)
            .accessibilityIdentifier("refresh-status")
        }
    }

    private func sectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .foregroundStyle(Color.calliopeiaInk)
    }

    private func field(_ title: String, text: Binding<String>, field: Field) -> some View {
        TextField(title, text: text)
            .focused($focusedField, equals: field)
            .sampleField()
            .accessibilityIdentifier(String(describing: field))
    }
}

private extension View {
    func sampleField() -> some View {
        padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.calliopeiaBorder, lineWidth: 1)
            }
    }
}

private extension Color {
    static let calliopeiaPink = Color(red: 0.76, green: 0.09, blue: 0.36)
    static let calliopeiaInk = Color(red: 0.16, green: 0.13, blue: 0.18)
    static let calliopeiaBorder = Color(red: 0.89, green: 0.82, blue: 0.85)
}
