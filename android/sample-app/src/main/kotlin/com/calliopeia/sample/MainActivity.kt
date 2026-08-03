package com.calliopeia.sample

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.Gravity
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import com.calliopeia.edgeaudio.contracts.CaptureMode
import com.calliopeia.sdk.CalliopeiaAPIClient
import com.calliopeia.sdk.CalliopeiaAPIConfiguration
import com.calliopeia.sdk.CalliopeiaAudioJobRequest
import com.calliopeia.sdk.CalliopeiaAuditEffort
import com.calliopeia.sdk.CalliopeiaAuditMode
import com.calliopeia.sdk.CalliopeiaAuditStrategy
import com.calliopeia.sdk.CalliopeiaCredential
import com.calliopeia.sdk.CalliopeiaCredentialProvider
import com.calliopeia.sdk.CalliopeiaExtractionEffort
import com.calliopeia.sdk.CalliopeiaRecordingClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import java.net.URI

class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var endpointInput: EditText
    private lateinit var apiKeyInput: EditText
    private lateinit var tokenInput: EditText
    private lateinit var recordIDInput: EditText
    private lateinit var startButton: Button
    private lateinit var submitButton: Button
    private lateinit var refreshButton: Button
    private lateinit var statusText: TextView

    private var apiClient: CalliopeiaAPIClient? = null
    private var recordingClient: CalliopeiaRecordingClient? = null
    private var jobID: String? = null
    private var pendingRecordStart = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(buildContent())
        updateActions(recording = false, working = false)
    }

    override fun onDestroy() {
        recordingClient?.close()
        scope.cancel()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == RECORD_PERMISSION_REQUEST && pendingRecordStart) {
            pendingRecordStart = false
            if (grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) {
                startRecording()
            } else {
                setStatus("マイクの利用が許可されていません")
            }
        }
    }

    private fun buildContent(): ScrollView {
        val root = ScrollView(this).apply {
            setBackgroundColor(getColor(R.color.calliopeia_background))
            isFillViewport = true
        }
        val column = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(28), dp(20), dp(40))
        }
        root.addView(column, ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)

        column.addView(text("Calliopeia Sample", 30f, true).apply {
            setTextColor(getColor(R.color.calliopeia_ink))
        })
        column.addView(text("接続", 19f, true), spaced(top = 28))

        endpointInput = input("GraphQL endpoint", InputType.TYPE_TEXT_VARIATION_URI)
        endpointInput.contentDescription = "GraphQL endpoint"
        column.addView(endpointInput, spaced(top = 12))

        apiKeyInput = input("AppSync API key")
        apiKeyInput.contentDescription = "AppSync API key"
        column.addView(apiKeyInput, spaced(top = 10))

        tokenInput = input("短期JWT", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD)
        tokenInput.contentDescription = "短期JWT"
        column.addView(tokenInput, spaced(top = 10))

        column.addView(text("認証情報はこのセッション内だけで保持されます", 12f, false).apply {
            setTextColor(Color.DKGRAY)
        }, spaced(top = 8))

        column.addView(text("録音と送信", 19f, true), spaced(top = 28))
        recordIDInput = input("自社レコードID").apply { setText(R.string.default_record_id) }
        recordIDInput.contentDescription = "自社レコードID"
        column.addView(recordIDInput, spaced(top = 12))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        startButton = actionButton("録音開始").apply {
            contentDescription = "録音開始"
            setOnClickListener { requestRecordingStart() }
        }
        submitButton = actionButton("停止・送信").apply {
            contentDescription = "停止・送信"
            setOnClickListener { stopAndSubmit() }
        }
        actions.addView(startButton, weighted(end = 6))
        actions.addView(submitButton, weighted(start = 6))
        column.addView(actions, spaced(top = 14))

        column.addView(text("ジョブ", 19f, true), spaced(top = 28))
        statusText = text("接続情報を入力してください", 14f, false).apply {
            setTextColor(getColor(R.color.calliopeia_ink))
            typeface = Typeface.MONOSPACE
            minHeight = dp(58)
            contentDescription = "ジョブ状態"
        }
        column.addView(statusText, spaced(top = 12))

        refreshButton = actionButton("状態を更新").apply {
            contentDescription = "状態を更新"
            setOnClickListener { refreshStatus() }
        }
        column.addView(refreshButton, spaced(top = 12))
        return root
    }

    private fun requestRecordingStart() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            startRecording()
        } else {
            pendingRecordStart = true
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), RECORD_PERMISSION_REQUEST)
        }
    }

    private fun startRecording() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            setStatus("マイクの利用が許可されていません")
            updateActions(recording = false, working = false)
            return
        }
        updateActions(recording = false, working = true)
        runCatching {
            val endpoint = URI.create(endpointInput.text.toString().trim())
            require(endpoint.scheme == "https") { "GraphQL endpointにはHTTPS URLを指定してください" }
            val credential = CalliopeiaCredentialProvider {
                CalliopeiaCredential(tokenInput.text.toString())
            }
            val api = CalliopeiaAPIClient(
                CalliopeiaAPIConfiguration(
                    graphQLEndpoint = endpoint,
                    appSyncAPIKey = apiKeyInput.text.toString(),
                ),
                credential,
            )
            val recorder = CalliopeiaRecordingClient(applicationContext, api)
            val format = recorder.startRecording(mode = CaptureMode.RAW_MASTER)
            apiClient = api
            recordingClient = recorder
            setStatus("録音中: ${format.actualSampleRate} Hz / ${format.channelCount} ch")
        }.onSuccess {
            updateActions(recording = true, working = false)
        }.onFailure {
            setStatus(it.message ?: it.javaClass.simpleName)
            updateActions(recording = false, working = false)
        }
    }

    private fun stopAndSubmit() {
        val recorder = recordingClient ?: return
        updateActions(recording = true, working = true)
        setStatus("音声を送信しています")
        scope.launch {
            runCatching {
                val passthrough = JsonObject(
                    mapOf(
                        "external_record_id" to JsonPrimitive(recordIDInput.text.toString().trim()),
                        "source" to JsonPrimitive("android-sample"),
                    ),
                )
                val request = CalliopeiaAudioJobRequest(
                    extractionEffort = CalliopeiaExtractionEffort.STANDARD,
                    auditMode = CalliopeiaAuditMode.OBSERVE,
                    auditEffort = CalliopeiaAuditEffort.STANDARD,
                    auditStrategy = CalliopeiaAuditStrategy.ATOMIC_BATCH,
                    passthrough = passthrough,
                )
                recorder.stopAndSubmit(request)
            }.onSuccess { (_, submission) ->
                jobID = submission.job.id
                setStatus("受付済み: ${submission.job.status}")
                updateActions(recording = false, working = false)
            }.onFailure {
                setStatus(it.message ?: it.javaClass.simpleName)
                updateActions(recording = false, working = false)
            }
        }
    }

    private fun refreshStatus() {
        val api = apiClient ?: return
        val id = jobID ?: return
        updateActions(recording = false, working = true)
        setStatus("状態を確認しています")
        scope.launch {
            runCatching { api.getJob(id) }
                .onSuccess {
                    setStatus("${it.status} / ${it.id}")
                    updateActions(recording = false, working = false)
                }
                .onFailure {
                    setStatus(it.message ?: it.javaClass.simpleName)
                    updateActions(recording = false, working = false)
                }
        }
    }

    private fun updateActions(recording: Boolean, working: Boolean) {
        startButton.isEnabled = !recording && !working
        submitButton.isEnabled = recording && !working
        refreshButton.isEnabled = !recording && !working && jobID != null
    }

    private fun setStatus(value: String) {
        statusText.text = value
    }

    private fun input(hint: String, type: Int = InputType.TYPE_CLASS_TEXT) = EditText(this).apply {
        this.hint = hint
        inputType = type
        setSingleLine(true)
        setPadding(dp(14), 0, dp(14), 0)
        minHeight = dp(50)
        setTextColor(getColor(R.color.calliopeia_ink))
        setHintTextColor(Color.GRAY)
        setBackgroundColor(Color.WHITE)
    }

    private fun actionButton(label: String) = Button(this).apply {
        text = label
        minHeight = dp(48)
        isAllCaps = false
        setTextColor(getColor(R.color.calliopeia_pink_dark))
    }

    private fun text(value: String, size: Float, bold: Boolean) = TextView(this).apply {
        text = value
        textSize = size
        if (bold) setTypeface(typeface, Typeface.BOLD)
    }

    private fun spaced(top: Int = 0) = LinearLayout.LayoutParams(
        ViewGroup.LayoutParams.MATCH_PARENT,
        ViewGroup.LayoutParams.WRAP_CONTENT,
    ).apply { topMargin = dp(top) }

    private fun weighted(start: Int = 0, end: Int = 0) = LinearLayout.LayoutParams(
        0,
        ViewGroup.LayoutParams.WRAP_CONTENT,
        1f,
    ).apply {
        marginStart = dp(start)
        marginEnd = dp(end)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).toInt()

    private companion object {
        const val RECORD_PERMISSION_REQUEST = 1001
    }
}
