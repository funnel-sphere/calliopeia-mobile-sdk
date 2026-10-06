# Recorder互換の録音・ログイン・API

この節のAPIは0.3.0以降で利用できます。Swift Packageのバージョンに
0.4.0以降を指定してください。OS標準APIで原音を録音します。
旧APIとpaired recordingは後方互換用に残しています。

## 構成

- `CalliopeiaHighQualityRecorder`: 原音の録音、M4A作成、形式・経路・音量設定の記録。
- `CalliopeiaRecordingExport`: 既存の原音WAVから同じ設定でM4Aを作成。
- `CalliopeiaSession`（`CalliopeiaAuth` product）: CognitoメールOTP、セッション復元、再送、ログアウト。
- `CalliopeiaAPIClient`: アップロード、解析投入、結果取得、書き起こし、追加質問。

SPMの`CalliopeiaSDK`と、ログインを使う場合は`CalliopeiaAuth`を追加します。
現在の依存関係を解決する場合はSwift 6.2以上を含むXcodeを使ってください。
公開サンプルはiOS 17以上を対象とし、Xcode 27.0で実機確認しています。
認証はRecorderと同じAmplify Swift **2.58.1**を使います。アプリのリソースに
環境の`amplify_outputs.json`を入れ、Info.plistに`NSMicrophoneUsageDescription`を設定します。
バックグラウンド録音を行うアプリはaudio background modeも設定してください。
`CalliopeiaAuth`はSPMで提供します。CocoaPodsでは録音とAPI clientを使い、
ホストアプリの認証をcredential providerへ接続してください。

## ログイン

```swift
import CalliopeiaSDK
import CalliopeiaAuth

// 起動時に一度だけ。Amplify設定済みのアプリでは呼ばない。
try CalliopeiaSession.configure()
let session = CalliopeiaSession()
let api = session.makeAPI(environment: try CalliopeiaEnvironment.load())

let restored = try await session.restore()
if case .signedOut = restored {
    // ログインボタンの操作で、ユーザーが入力したメールを使う。
    let next = try await session.signIn(email: email)
    // .emailCode / .accountConfirmationならコード入力画面を表示し、
    // ユーザーが受け取ったコードを送信する操作で:
    let signedIn = try await session.confirm(code: code)
}
let access = try await api.currentAccess()
// status == "ACTIVE" && canRunJobsを確認して送信を許可。
```

MainActor上で操作します。`signIn`は既存アカウント用です。登録する場合は明示的に
`signUp(email:)`を呼び、`.accountConfirmation`を`confirm(code:)`で進めます。
`resendCode()`と`signOut()`も利用できます。トークン保存と期限更新はAmplifyに任せ、
アプリへJWT・テナントAPIキーを埋め込みません。自社ログインを使う場合は、従来の
`ClosureCalliopeiaCredentialProvider`を注入できます。

## 録音と送信

```swift
let recorder = CalliopeiaHighQualityRecorder()
guard await CalliopeiaHighQualityRecorder.requestPermission() else { return }
let format = try recorder.start()
// 利用者が録音を止める操作で:
let take = try await recorder.stop()

var request = CalliopeiaAudioJobRequest.qualityBatch(
    idempotencyKey: savedRequestID,
    generateIndividualKartes: false
)
request.passthrough = .object(["external_record_id": .string(recordID)])
let accepted = try await api.submit(take, request: request)
let job = try await api.getJob(id: accepted.job.id)
```

停止・保存と送信は別操作です。通信失敗時も録音は端末に残ります。
上の`submit`はアップロードから投入までを一度実行する便利メソッドです。
応答不明の投入を再試行するアプリでは`createAudioUpload`、`uploadAudio`、
`invokeAudioJob`を分け、アップロード済みticketと同じidempotencyKeyを保持して
`invokeAudioJob`を再試行してください。`submit`を再び呼ぶと別のobjectKeyが発行されます。
実装例は[PendingAudioSubmission](../samples/ios/CalliopeiaSample/PendingAudioSubmission.swift)を参照してください。
`createAudioUpload`を直接呼ぶ場合は、録音ファイルの実サイズを`fileSizeBytes: Int`で渡します。
`submitAudio`やサンプルの`PendingAudioSubmission.submit`はファイルから自動取得します。
`qualityBatch()`は個別カルテOff・
BGM除去Offを明示します。従来の`.init(...)`では両項目の省略も可能です。
個別カルテOnにする場合は`generateIndividualKartes: true`を指定します。

既存WAVからの書き出しだけなら:

```swift
let exported = try await CalliopeiaRecordingExport.export(
    rawMasterURL: existingWAV, outputURL: newM4A
)
```

原音WAV、M4A、JSONは自動削除しません。保持期間と削除操作はアプリ側で管理します。
変換失敗時も原音は残り、`recorder.rawMasterURL`から回復できます。
録音中の割り込み・音声ルート変更を監視し、`stop()`して保存してください。

## 書き起こしと質問

```swift
let provisional = try await api.getProvisionalTranscript(jobID: job.id)
let formatted = try await api.getFormattedTranscript(jobID: job.id)
// OFFERの金額を表示し、ユーザーが同意したときだけ:
let requested = try await api.purchaseFormattedTranscript(
    jobID: job.id, quoteToken: quoteToken, acceptCharge: userAcceptedCharge
)

let question = try await api.askQuestion(
    jobID: job.id, question: "修理の完了予定は？",
    requestID: savedQuestionRequestID, parentQuestionID: nil, sectionIndex: nil
)
let answer = try await api.getQuestions(jobID: job.id, questionID: questionID)
let history = try await api.getQuestions(jobID: job.id, nextToken: nextToken)
```

`sectionIndex: nil`は録音全体、`0`は最初の接客です。継続質問は完了した前の質問IDを
`parentQuestionID`へ渡します。質問の再送では同じrequestIDを使います。
HTTP成功は解析完了ではありません。ジョブ・質問の`status`、書き起こしの`state`を
確認してください。PROCESSINGなら時間を置いて取得します。取得・質問で個別カルテが
Onに変わることはなく、質問から整形書き起こしを自動購入することもありません。

## 録音設定と出所

移植元: Recorder commit `b12487526f227f50282849747634a06865a7bcd9`の
`RecordingController.swift`原音側、`AudioLevelDynamics.swift`、`CaptureRouteOptimizer.swift`。

| 設定 | 値 |
| --- | --- |
| Audio session | record / measurement、voice processing無効 |
| 優先sample rate / I/O buffer | 48,000 Hz / 20 ms |
| Tap buffer | 960 frames |
| 原音保存 | デバイス実形式のFloat32 WAV |
| 指向性 | 現入力ルートのcardioid、次にsubcardioidを選択可能なら利用 |
| AAC | mono AAC-LC、既定64 kbps（64〜96 kbpsを指定可能） |
| 音量調整 | RMS目標0.12、RMS下限0.0005、最大+30 dB |
| Headroom | 99.9 percentile、上限0.85 |
| Limiter | ceiling 0.89、release 30 ms、clamp 0.98 |
| 変換chunk | 4,096 frames |
| ノイズ除去・小声専用補正 | 実行しない |

指向性の選択はsession有効化後、録音tap開始前に行います。Recorderの開始後選択から
この順序だけを変え、録音冒頭の経路変更を避けます。選択不可なら既存ルートを使います。
48 kHzは要求値です。実際の形式は`captureFormat`、経路は`captureRoute`で確認します。
M4Aのmono AAC・長さ・サイズ・先頭と末尾のPCMデコードを検証してから返します。
この移植は原音経路の再現であり、認識精度やノイズ除去効果の改善を主張しません。

参考: [Apple audio session](https://developer.apple.com/library/archive/qa/qa1631/_index.html)、
[マイク選択](https://developer.apple.com/library/archive/qa/qa1799/_index.html)、
[Amplify Email OTP](https://docs.amplify.aws/swift/frontend/auth/sign-in/)。
