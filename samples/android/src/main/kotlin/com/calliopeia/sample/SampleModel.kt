package com.calliopeia.sample

import android.Manifest
import android.content.Context
import androidx.annotation.RequiresPermission
import com.calliopeia.auth.*
import com.calliopeia.sdk.*
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

/** App-scoped state survives Activity recreation; audio files also survive process exit. */
class SampleModel(context: Context, environment: CalliopeiaEnvironment?) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val session = CalliopeiaSession()
    private val api = environment?.let(session::makeAPI)
    private val recorder = CalliopeiaHighQualityRecorder(context)
    private var initialized = false
    private var pending: CalliopeiaPendingAudioSubmission? = null
    var onChange: (() -> Unit)? = null
    var busy = false
        private set
    var recording: CalliopeiaHighQualityRecording? = null
        private set
    var jobID: String? = null
        private set
    var access: CalliopeiaAccess? = null
        private set
    var resultText = "まだ送信していません"
        private set
    var message = if (api == null) "接続設定がありません。READMEに従ってamplify_outputs.jsonを追加してください。録音は利用できます。" else "録音して保存し、確認してから送信します"
        private set
    val configured get() = api != null
    val loginStep get() = session.step
    val isRecording get() = recorder.isRecording

    fun initialize() {
        if (initialized || !configured) return
        initialized = true
        perform("ログイン状態を確認しています") {
            if (session.restore() is CalliopeiaLoginStep.SignedIn) access = checkNotNull(api).currentAccess()
            message = "録音はログイン前でも利用できます"
        }
    }
    fun signIn(email: String) = perform("確認コードを送信しています") {
        session.signIn(email); updateAccount()
    }
    fun confirm(code: String) = perform("確認コードを確認しています") {
        session.confirm(code); updateAccount()
    }
    fun resendCode() = perform("確認コードを再送しています") {
        session.resendCode(); updateAccount()
    }
    fun signOut() = perform("ログアウトしています") {
        session.signOut(); access = null; jobID = null; pending = null; recording = null
        resultText = "まだ送信していません"; message = "ログアウトしました。保存済み音声は端末内に残ります。"
    }
    private suspend fun updateAccount() {
        if (session.step is CalliopeiaLoginStep.SignedIn) {
            access = checkNotNull(api).currentAccess(); message = "ログインしました"
        } else message = "メールの確認コードを入力してください"
    }
    @RequiresPermission(Manifest.permission.RECORD_AUDIO)
    fun startRecording() {
        if (busy || isRecording) return
        runCatching { recorder.start() }.onSuccess {
            recording = null; pending = null; jobID = null; resultText = "まだ送信していません"
            message = "録音中: ${it.actualSampleRate} Hz / ${it.channelCount} ch"
        }.onFailure { message = "録音を開始できませんでした。マイクの権限と利用状態を確認してください。" }
        onChange?.invoke()
    }
    fun stopRecording() {
        if (busy || !isRecording) return
        perform("音声を保存しています") {
            recording = recorder.stop()
            message = "保存しました: %.1f秒。送信ボタンで解析を開始します。".format(recording!!.audio.durationSeconds)
        }
    }
    fun submit() {
        val audio = recording?.audio ?: return
        if (access?.canRunJobs != true || isRecording) return
        perform("音声を送信しています") {
            val submission = (pending ?: CalliopeiaPendingAudioSubmission(audio.file, audio.contentType, audio.durationSeconds)
                .also { pending = it }).submit(checkNotNull(api))
            jobID = submission.job.id; resultText = "${submission.job.status}\n${submission.job.id}"
            message = "受付済みです。「状態を更新」で確認できます。"
        }
    }
    fun refresh() {
        val id = jobID ?: return
        perform("結果を確認しています") {
            val job = checkNotNull(api).getJob(id)
            resultText = buildString {
                append(job.status)
                val raw = when (val value = job.responseJSON) {
                    is JsonPrimitive -> value.contentOrNull?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }
                    is JsonArray, is JsonObject -> value
                    else -> null
                } ?: job.responseText?.let { runCatching { Json.parseToJsonElement(it) }.getOrNull() }
                if (raw is JsonArray) for (item in raw) {
                    val field = item as? JsonObject ?: continue
                    append("\n\n"); append(field["title"]?.jsonPrimitive?.contentOrNull ?: "")
                    append("\n"); append(field["body"]?.jsonPrimitive?.contentOrNull ?: "")
                } else if (!job.responseText.isNullOrBlank()) append("\n\n${job.responseText}")
                if (!job.errorMessage.isNullOrBlank()) append("\n${job.errorMessage}")
            }
            message = if (job.status == "COMPLETED") "解析が完了しました" else "現在の状態: ${job.status}"
        }
    }
    private fun perform(progress: String, block: suspend () -> Unit) {
        if (busy) return
        busy = true; message = progress; onChange?.invoke()
        scope.launch {
            try { block() }
            catch (cancelled: CancellationException) { throw cancelled }
            catch (_: Exception) { message = "処理できませんでした。入力・接続状態を確認して再試行してください。" }
            finally { busy = false; onChange?.invoke() }
        }
    }
}
