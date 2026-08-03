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
| iOS/Android Calliopeia API client | Apache-2.0 | Yes |
| Quality-inspection extension interface | Apache-2.0 | Yes |
| Calliopeia edge-processing runtime | Commercial | No |
| Model weights | Weight-specific terms | No |
| Calliopeia service backend | Proprietary service | No |

公開SDKはエッジ処理バイナリなしでも原音録音とAPI投入に利用できます。
品質検査や補正を追加する場合は、`AudioFrameInspecting` / `AudioFrameInspector`
を実装する別配布のランタイムを注入します。

## iOS (Swift Package Manager)

XcodeのPackage Dependenciesへ次を追加し、`0.1.0`以降を指定します。

```text
https://github.com/funnel-sphere/calliopeia-mobile-sdk
```

`Package.swift`から指定する場合:

```swift
.package(
    url: "https://github.com/funnel-sphere/calliopeia-mobile-sdk.git",
    from: "0.1.0"
)
```

## iOS (CocoaPods)

`Podfile`からGitHubのリリースタグを直接指定できます。

```ruby
pod 'CalliopeiaSDK',
    git: 'https://github.com/funnel-sphere/calliopeia-mobile-sdk.git',
    tag: '0.1.0'
```

```bash
pod install
```

## iOS API

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

JitPackを利用すると、GitHubのリリースタグからMaven依存関係として直接導入できます。
`settings.gradle.kts`へリポジトリを追加します。

```kotlin
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
        maven("https://jitpack.io")
    }
}
```

```kotlin
dependencies {
    implementation(
        "com.github.funnel-sphere.calliopeia-mobile-sdk:calliopeia-sdk:0.1.0"
    )
}
```

アプリ側で`RECORD_AUDIO`のランタイム権限を取得してから開始します。

```kotlin
val credentials = CalliopeiaCredentialProvider {
    CalliopeiaCredential(value = session.currentAccessToken())
}
val api = CalliopeiaAPIClient(
    configuration = CalliopeiaAPIConfiguration(
        graphQLEndpoint = URI.create(environment.calliopeiaGraphQLEndpoint),
        appSyncAPIKey = environment.calliopeiaAppSyncAPIKey,
        pullAPIBaseURL = URI.create(environment.calliopeiaPullAPIBaseURL),
    ),
    credentialProvider = credentials,
)
val recorder = CalliopeiaRecordingClient(context, api)

recorder.startRecording(mode = CaptureMode.RAW_MASTER)

lifecycleScope.launch {
    val request = CalliopeiaAudioJobRequest(
        extractionEffort = CalliopeiaExtractionEffort.MAXIMUM,
        auditMode = CalliopeiaAuditMode.OBSERVE,
        auditEffort = CalliopeiaAuditEffort.MAXIMUM,
        auditStrategy = CalliopeiaAuditStrategy.ATOMIC_BATCH,
        passthrough = buildJsonObject {
            put("crm_customer_id", customerID)
            put("source", "mobile")
        },
    )
    val (_, submission) = recorder.stopAndSubmit(request)
    val result = api.getJob(submission.job.id)
}
```

`CalliopeiaTransport`を実装して差し込めば、既存のHTTPクライアントや監視処理へ
置き換えられます。標準実装は大きな音声ファイルをメモリへ載せずストリーミングします。

## パススルー情報

`passthrough`は顧客や店舗などCalliopeiaが意味を決めない任意JSONオブジェクトです。
Webhookと結果取得でそのまま返るため、自社レコードとの対応付けに利用できます。
SDKはバックエンドと同じサイズ、深さ、プロパティ数、キー長の上限を送信前に検証します。

## サンプルアプリ

公開リポジトリ内に、録音からジョブ登録、状態取得までを確認できる参照実装があります。

- [iOS SwiftUI sample](samples/ios/README.md): Xcodeで
  `samples/ios/CalliopeiaSample.xcodeproj`を開きます。
- [Android sample](android/sample-app/README.md): Android Studioで`android`を開き、
  `sample-app`を実行します。

サンプルへ入力した認証情報は端末へ永続化しません。本番アプリでは、ログイン済みの
ホストアプリから短期JWTを返すcredential providerへ置き換えてください。

## 商用エッジランタイム

独自DSP、Rustネイティブコア、モデル重みを含む商用ランタイムは、この公開SDKと
分離して認証付きで配布します。公開SDKは単独で動作し、商用ランタイムを利用する
契約では次の拡張点へ実装を注入します。

- iOS: `AudioFrameInspecting`
- Android: `AudioFrameInspector`

この分離により、アプリの連携コードとサンプルはOSSのまま再利用でき、商用バイナリ、
モデル、顧客別の利用権限は公開リポジトリへ含めずに更新できます。

## ビルドとテスト

```bash
swift test
pod lib lint CalliopeiaSDK.podspec --allow-warnings
cd android
./gradlew test lint publishToMavenLocal
```

## License

[Apache License 2.0](LICENSE)

`NOTICE`に明記したとおり、別配布の商用ランタイムおよびモデル重みにはこの
ライセンスは適用されません。
