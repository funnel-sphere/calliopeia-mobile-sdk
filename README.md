# Calliopeia Mobile SDK

[![Tests](https://github.com/funnel-sphere/calliopeia-mobile-sdk/actions/workflows/tests.yml/badge.svg)](https://github.com/funnel-sphere/calliopeia-mobile-sdk/actions/workflows/tests.yml)

Calliopeiaへ高品質な原音を録音・送信するためのiOS/Android向け公開SDKです。
OS標準の録音API、Calliopeia API契約、認証差し替え、任意のパススルー情報、
品質検査の拡張インターフェースを提供します。

このリポジトリには、Calliopeia本体、独自DSP実装、モデル重み、実データ、
認証情報、プロプライエタリなエッジ処理バイナリは含みません。

## 公開範囲

| Component | License | Included |
| --- | --- | --- |
| Swift/Kotlin contracts | Apache-2.0 | Yes |
| iOS/Android raw audio capture | Apache-2.0 | Yes |
| iOS Calliopeia API client | Apache-2.0 | Yes |
| Quality-inspection extension interface | Apache-2.0 | Yes |
| Calliopeia edge-processing runtime | Commercial | No |
| Model weights | Weight-specific terms | No |
| Calliopeia service backend | Proprietary service | No |

公開SDKはエッジ処理バイナリなしでも原音録音とAPI投入に利用できます。
品質検査や補正を追加する場合は、`AudioFrameInspecting` / `AudioFrameInspector`
を実装する別配布のランタイムを注入します。

## iOS

XcodeのPackage Dependenciesへ次を追加します。

```text
https://github.com/funnel-sphere/calliopeia-mobile-sdk
```

ホストアプリの`Info.plist`には`NSMicrophoneUsageDescription`が必要です。

```swift
import CalliopeiaSDK

let credentials = ClosureCalliopeiaCredentialProvider {
    CalliopeiaCredential(value: try await session.currentAccessToken())
}
let api = CalliopeiaAPIClient(
    configuration: .init(
        graphQLEndpoint: environment.calliopeiaGraphQLEndpoint,
        appSyncAPIKey: environment.calliopeiaAppSyncAPIKey,
        pullAPIBaseURL: environment.calliopeiaPullAPIBaseURL
    ),
    credentialProvider: credentials
)
let recorder = CalliopeiaRecordingClient(apiClient: api)

guard await CalliopeiaRecordingClient.requestRecordPermission() else { return }
try recorder.startRecording(mode: .rawMaster)

let request = CalliopeiaAudioJobRequest(
    extractionEffort: .maximum,
    auditMode: .observe,
    auditEffort: .maximum,
    auditStrategy: .atomicBatch,
    passthrough: .object([
        "crm_customer_id": .string(customerID),
        "source": .string("mobile")
    ])
)
let (_, submission) = try await recorder.stopAndSubmit(request: request)
let result = try await api.getJob(id: submission.job.id)
```

長期APIキーや固定JWTをアプリへ埋め込まないでください。認証済みセッションから
短期JWTを返す`CalliopeiaCredentialProvider`を実装します。

## Android

現在の公開Androidモジュールは録音・契約層です。リポジトリを取得し、
ホストプロジェクトから`audio-contracts`と`audio-capture`を組み込めます。

```kotlin
includeBuild("../calliopeia-mobile-sdk/android")
```

```kotlin
dependencies {
    implementation("com.calliopeia:audio-contracts")
    implementation("com.calliopeia:audio-capture")
}
```

アプリ側で`RECORD_AUDIO`のランタイム権限を取得してから開始します。

```kotlin
val recorder = HighFidelityRecorder(context)
val format = recorder.start(
    rawMasterFile = outputFile,
    mode = CaptureMode.RAW_MASTER,
)
// Stop from the host lifecycle before submitting the file.
recorder.stop()
```

AndroidのCalliopeia APIファサードとMaven配布は今後の公開対象です。現時点では
ホストアプリのHTTPクライアントからAPIへ接続してください。

## パススルー情報

`passthrough`は顧客や店舗などCalliopeiaが意味を決めない任意JSONオブジェクトです。
Webhookと結果取得でそのまま返るため、自社レコードとの対応付けに利用できます。
SDKはバックエンドと同じサイズ、深さ、プロパティ数、キー長の上限を送信前に検証します。

## ビルドとテスト

```bash
swift test
cd android
./gradlew test lint
```

## License

[Apache License 2.0](LICENSE)

`NOTICE`に明記したとおり、別配布の商用ランタイムおよびモデル重みにはこの
ライセンスは適用されません。
