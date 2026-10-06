# Android: 録音・ログイン・API

`calliopeia-sdk`は認証から独立した録音とAPIを提供します。
メールOTPログインを使う場合は追加の`calliopeia-auth`を利用します。
この更新版のソースは`0.4.0`タグから取得できます。

まず[サンプル](../samples/android/README.md)のローカルGradleモジュールで確認できます。
既存アプリへの組み込みでもKotlin 2.2.0以降とJDK 17以降を使います。
認証モジュールはAmplify Android **2.42.0**に固定しています。アプリ側のGradleに次を設定します。

```kotlin
android {
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation(project(":calliopeia-sdk"))
    implementation(project(":calliopeia-auth"))
}
```

## 認証

Applicationの起動時に一度だけ設定します。Amplifyを既に設定済みのアプリではその設定を使います。
`amplify_outputs.json`は自分の環境の公開接続設定です。テナントAPIキーや利用者のJWTは含めません。

```kotlin
val outputs = context.assets.open("amplify_outputs.json").bufferedReader().use { it.readText() }
CalliopeiaSession.configure(context, outputs)
val session = CalliopeiaSession()
val api = session.makeAPI(CalliopeiaEnvironment(outputs))

// 以下はCoroutine内。画面にはstepを反映する。
val step = session.restore()
if (step is CalliopeiaLoginStep.SignedOut) session.signIn(email)
// EmailCodeまたはAccountConfirmationのとき、利用者の入力から確認する。
session.confirm(code)
val access = api.currentAccess()
// access.canRunJobsで送信可能かを表示する。
```

`resendCode()`、`signOut()`、`refreshCredentials()`も利用できます。
通常のAPI呼び出し時には必要に応じたトークン更新をAmplifyが行います。
`signIn`は暗黙に新規アカウントを作成しません。新規登録はホストアプリの登録フローで扱ってください。

## 録音と再試行

```kotlin
// RECORD_AUDIOのランタイム権限をアプリ側で取得した後
val recorder = CalliopeiaHighQualityRecorder(context)
val format = recorder.start()
val saved = recorder.stop() // suspend。WAVを保持してAACのM4Aを作成
val pending = CalliopeiaPendingAudioSubmission(
    saved.audio.file, saved.audio.contentType, saved.audio.durationSeconds,
    CalliopeiaAudioJobRequest.qualityBatch(),
)
val accepted = pending.submit(api)
val job = api.getJob(accepted.job.id)
```

`pending`は同じ録音の再試行で保持し、`pending.submit(api)`を再実行します。
成功済みアップロードを繰り返さず、同じobjectKey・冪等キーを利用します。
プロセス終了後の再試行が必要なら、`createAudioUpload → uploadAudio → invokeAudioJob`の
分割APIを使い、アップロード済みobjectKey・入力条件・冪等キーを安全に保存してください。
`createAudioUpload`を直接呼ぶ場合は、`file.length()`を`fileSizeBytes: Long`で渡します。
`submitAudio`と`CalliopeiaPendingAudioSubmission.submit`はファイルから自動取得します。
署名付きuploadUrlは短時間のみ保持し、ログへ出さないでください。
`submitAudio` / `stopAndSubmit`は一度の処理用です。

元のWAVからの書き出しは`CalliopeiaRecordingExport.export(rawMaster, output)`です。
SDKが作成したmono float WAV形式専用で、IOスレッドから呼びます。

## 書き起こし・質問

```kotlin
val transcript = api.getProvisionalTranscript(jobID)
val offer = api.getFormattedTranscript(jobID) // 見積もりまたは取得済み結果。購入はしない。
// 金額を示して利用者の課金同意を得た場合だけpurchaseFormattedTranscriptを使う。
val requested = api.askQuestion(jobID, "次回の予定は？", savedQuestionRequestID)
val answer = api.getQuestions(jobID, questionID = requested.question?.questionID)
```

処理中の質問は同じquestionIDを時間を置いて取得します。質問再送には同じrequestIDを使います。
`sectionIndex = 0`は最初の接客、省略は録音全体です。引用には原文と開始・終了秒が含まれます。

参照: [AmplifyのメールOTP](https://docs.amplify.aws/android/frontend/auth/sign-in/#email-otp)、
[セッション](https://docs.amplify.aws/android/frontend/auth/manage-user-sessions/)、
[Android MediaCodec](https://developer.android.com/reference/android/media/MediaCodec)。
