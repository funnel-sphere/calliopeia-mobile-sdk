# Calliopeia Mobile SDK

[![Tests](https://github.com/funnel-sphere/calliopeia-mobile-sdk/actions/workflows/tests.yml/badge.svg)](https://github.com/funnel-sphere/calliopeia-mobile-sdk/actions/workflows/tests.yml)

Calliopeiaへ高品質な原音を録音・送信するためのiOS/Android向け公開SDKです。
OS標準の録音API、Calliopeia API契約、認証差し替え、任意のパススルー情報、
品質検査の拡張インターフェースを提供します。

このリポジトリには、Calliopeia本体、モデル重み、実データ、認証情報は含みません。

## 公開範囲

| Component | License | Included |
| --- | --- | --- |
| Swift/Kotlin contracts | Apache-2.0 | Yes |
| iOS/Android raw audio capture | Apache-2.0 | Yes |
| iOS/Android Calliopeia API client | Apache-2.0 | Yes |
| Quality-inspection extension interface | Apache-2.0 | Yes |
| Model weights | Weight-specific terms | No |
| Calliopeia service backend | Proprietary service | No |

公開SDKはOS標準APIで原音録音とAPI投入を行います。
品質検査や補正を追加する場合は、`AudioFrameInspecting` / `AudioFrameInspector`
をアプリ側で実装できます。

## iOS (Swift Package Manager)

XcodeのPackage Dependenciesへ次を追加し、`0.3.0`以降を指定します。

```text
https://github.com/funnel-sphere/calliopeia-mobile-sdk
```

`Package.swift`から指定する場合:

```swift
.package(
    url: "https://github.com/funnel-sphere/calliopeia-mobile-sdk.git",
    from: "0.3.0"
)
```

録音・APIには`CalliopeiaSDK` productを、メールOTPログインには追加で
`CalliopeiaAuth` productをアプリターゲットへ追加します。

## iOS (CocoaPods)

`Podfile`からGitHubのリリースタグを直接指定できます。

```ruby
pod 'CalliopeiaSDK',
    git: 'https://github.com/funnel-sphere/calliopeia-mobile-sdk.git',
    tag: '0.3.0'
```

```bash
pod install
```

`CalliopeiaAuth`はSPM専用です。CocoaPodsでは録音・APIを利用し、
ホストアプリの認証を`CalliopeiaCredentialProvider`へ接続してください。

## iOS API

**新規iOS実装:** [Recorder互換の録音・ログイン・API](docs/recorder-capture.md)を参照してください。
0.3.0では`CalliopeiaHighQualityRecorder`でノイズ除去モデルなしの原音M4A録音、
`CalliopeiaSession`でメールOTPログインとトークン更新、APIクライアントで解析・
書き起こし・追加質問を扱えます。個別カルテは既定Offです。新APIは0.3.0から利用できます。

以下は従来の低レベルAPIで、ホストアプリが認証セッションを提供する場合の例です。

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
        pullAPIBaseURL: environment.calliopeiaPullAPIBaseURL,
        graphQLAuthorization: .cognitoUserPools
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

### iOS paired recording

`StreamingAudioEnhancer`を注入すると、原音masterと同じsample rate・sample-frame長の
mono補正音声、および区間ごとのenhanced/fallback内訳を含むJSON manifestを保存できます。
原音masterは常に独立して記録され、補正処理のoverload、model error、不正な長さ、
非finite出力、原音に対して極端に減衰した補正出力は、該当区間の原音monoへfallback
します。出力レベル判定は、意味のある入力RMS、補正出力の絶対RMS、入力に対する
RMS/peak比を使い、無音に近い入力を不要に増幅しません。
manifestには`schemaVersion`とenhancerの`identifier`も含まれます。一時処理データは
フレームごとのファイルではなく、録音ごとに固定2ファイルへ記録されます。

```swift
let recorder = CalliopeiaRecordingClient(
    apiClient: api,
    enhancer: yourStreamingEnhancer,
    pairedProcessorConfiguration: .init(maximumPendingFrames: 4)
)

try recorder.startPairedRecording(baseFileName: "visit-123")
let paired = try recorder.stopPairedRecording()

// visit-123-raw.wav
print(paired.rawAudio.fileURL)
// visit-123-enhanced.wav
print(paired.enhancedFileURL)
// visit-123-manifest.json
print(paired.manifestURL)
```

enhancerの`requiredSampleRate`と端末の実capture sample rateが一致しない場合は、
SDK内で暗黙resampleせず開始を失敗させます。

同じCalliopeia Cognito User Poolへログインするアプリは
`graphQLAuthorization: .cognitoUserPools`を指定します。外部テナントが独自JWTまたは
Calliopeia APIキーを使う場合は既定の`.apiKey`のままにし、AppSync公開キーと外部
credentialを別々に設定します。長期APIキーや固定JWTをアプリへ埋め込まず、認証済み
セッションから短期JWTを返す`CalliopeiaCredentialProvider`を実装してください。

## Android

Androidの高品質録音・メールOTP・現行API対応は`main`にあります。
この更新を利用する場合はリポジトリを取得して`android`を開き、
`calliopeia-sdk`と、ログインが必要なら`calliopeia-auth`を参照してください。
公開済みタグ`0.3.0`には今回のAndroid更新は含まれていません。

```kotlin
dependencies {
    implementation(project(":calliopeia-sdk"))
    implementation(project(":calliopeia-auth")) // メールOTP・セッション管理
}
```

`Application.onCreate`で接続設定を一度読み込み、認証を初期化します。
既にAmplifyを設定済みのアプリは、自身の初期化を利用してください。
認証モジュールのdesugaring設定などは[導入手順](docs/android-recorder.md)を参照してください。

```kotlin
val outputs = assets.open("amplify_outputs.json").bufferedReader().use { it.readText() }
CalliopeiaSession.configure(applicationContext, outputs)
val environment = CalliopeiaEnvironment(outputs)
val session = CalliopeiaSession()
val api = session.makeAPI(environment)

// coroutine内。既存アカウントのメールOTPログイン
session.signIn(email)
session.confirm(code)
// 次回起動時はsession.restore()。トークンの保存・更新はAmplifyが担当します。
```

マイク権限を取得した後、ログインせずに録音・保存できます。
録音機能にはノイズ除去モデルや別配布のネイティブライブラリは不要です。

```kotlin
val recorder = CalliopeiaHighQualityRecorder(context)
recorder.start()
// coroutine内。原音WAVを残し、AAC-LC 64 kbpsのM4Aを作成
val recording = recorder.stop()

// ユーザーが送信を選んだ時点で実行
val pending = CalliopeiaPendingAudioSubmission(
    recording.audio.file, recording.audio.contentType, recording.audio.durationSeconds,
)
val submission = pending.submit(api) // 品質優先・個別カルテOff・BGM除去Off
val result = api.getJob(submission.job.id)
val transcript = api.getProvisionalTranscript(submission.job.id)
```

応答が失われた場合は同じ`pending`を保持して再送します。
アップロード済みの音声と冪等キーを再利用します。サンプルではActivityの再生成を
またいで保持しますが、プロセス終了後の送信再開は実装していません。
原音の取得条件・OSごとの差と保存ファイルは[Android録音仕様](docs/android-recorder.md)に記載しています。

独自認証を使うホストアプリは`CalliopeiaCredentialProvider`を実装できます。
同じCalliopeia Cognito User Poolでは`COGNITO_USER_POOLS`、外部テナントの認証では
`API_KEY`を選び、AppSync公開キーと外部credentialを別々に設定します。
長期APIキーや固定JWTをアプリに埋め込まないでください。

## パススルー情報

`passthrough`は顧客や店舗などCalliopeiaが意味を決めない任意JSONオブジェクトです。
Webhookと結果取得でそのまま返るため、自社レコードとの対応付けに利用できます。
SDKはバックエンドと同じサイズ、深さ、プロパティ数、キー長の上限を送信前に検証します。

## サンプルアプリ

公開リポジトリ内に、録音からジョブ登録、状態取得までを確認できる参照実装があります。

- [iOS SwiftUI recorder sample](samples/ios/README.md): 高品質録音、メールOTPログイン、
  明示的な送信、結果表示を公開SDKだけで実装しています。Xcodeで
  `samples/ios/CalliopeiaSample.xcodeproj`を開きます。実際の接続設定は各利用者が追加します。
- [Android sample](samples/android/README.md): Android Studioで`android`を開き、
  `sample-app`を実行します。

iOSサンプルは`CalliopeiaSession`によるメールOTPログインを使い、Amplifyが
Keychainへセッションを保存・復元します。JWTの手入力はありません。
AndroidサンプルもメールOTPとセッション復元を使います。原音WAV・M4Aを保存し、
ログイン後に明示的に送信して結果を確認できます。

iOS RecorderサンプルとAndroid更新は`main`に追加されています。サンプルを利用する場合は
このブランチを取得してください。SDKの公開タグ`0.3.0`は変更していません。

## ビルドとテスト

```bash
swift test
pod lib lint CalliopeiaSDK.podspec --allow-warnings
cd android
./gradlew test lint publishToMavenLocal
```

## License

[Apache License 2.0](LICENSE)

依存ライブラリのライセンスは`THIRD_PARTY_NOTICES.md`を参照してください。
