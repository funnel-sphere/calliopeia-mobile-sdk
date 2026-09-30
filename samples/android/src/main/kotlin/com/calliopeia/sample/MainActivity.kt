package com.calliopeia.sample

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.view.ViewGroup
import android.view.WindowManager
import android.widget.*
import com.calliopeia.auth.CalliopeiaLoginStep

class MainActivity : Activity() {
    private val model get() = (application as SampleApplication).model
    private lateinit var email: EditText
    private lateinit var code: EditText
    private lateinit var login: Button
    private lateinit var confirm: Button
    private lateinit var resend: Button
    private lateinit var logout: Button
    private lateinit var start: Button
    private lateinit var stop: Button
    private lateinit var submit: Button
    private lateinit var refresh: Button
    private lateinit var account: TextView
    private lateinit var status: TextView
    private lateinit var result: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(content())
    }
    override fun onStart() {
        super.onStart()
        model.onChange = ::render
        render(); model.initialize()
    }
    override fun onStop() {
        if (!isChangingConfigurations) model.stopRecording()
        model.onChange = null
        super.onStop()
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 1001 && grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED) startRecording()
        else if (requestCode == 1001) status.text = "録音にはマイクの利用許可が必要です。設定から許可してください。"
    }
    private fun startRecording() {
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) model.startRecording()
        else requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1001)
    }
    private fun content(): View {
        val scroll = ScrollView(this).apply { setBackgroundColor(getColor(R.color.calliopeia_background)); isFillViewport = true }
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setPadding(dp(20), dp(20), dp(20), dp(32)) }
        scroll.addView(column)
        scroll.setOnApplyWindowInsetsListener { _, insets ->
            scroll.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                insets.systemWindowInsetRight, insets.systemWindowInsetBottom); insets
        }
        fun label(value: String, size: Float = 16f, bold: Boolean = false) = TextView(this).apply {
            text = value; textSize = size; setTextColor(getColor(R.color.calliopeia_ink))
            if (bold) setTypeface(typeface, Typeface.BOLD)
            column.addView(this, layout())
        }
        fun button(value: String, action: () -> Unit) = Button(this).apply {
            text = value; contentDescription = value; isAllCaps = false; minHeight = dp(48)
            setTextColor(getColor(R.color.calliopeia_pink_dark)); setOnClickListener { action() }
            column.addView(this, layout())
        }
        fun input(value: String, type: Int) = EditText(this).apply {
            hint = value; contentDescription = value; inputType = type; setSingleLine(true)
            minHeight = dp(48); setTextColor(getColor(R.color.calliopeia_ink)); setHintTextColor(Color.DKGRAY)
            column.addView(this, layout())
        }
        label("Calliopeia Sample", 28f, true)
        label("録音", 20f, true)
        label("原音を端末に保存し、確認してから送信します。")
        start = button("録音開始", ::startRecording)
        stop = button("停止して保存", model::stopRecording)
        label("アカウント", 20f, true)
        account = label("")
        email = input("メールアドレス", InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS)
        login = button("確認コードを送信") { model.signIn(email.text.toString()) }
        code = input("確認コード", InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD)
        confirm = button("ログイン") { model.confirm(code.text.toString()); code.text.clear() }
        resend = button("コードを再送", model::resendCode)
        logout = button("ログアウト", model::signOut)
        label("送信と結果", 20f, true)
        label("品質優先・個別カルテOff・BGM除去Off")
        submit = button("録音を送信", model::submit)
        refresh = button("状態を更新", model::refresh)
        status = label("").apply { contentDescription = "処理状態"; accessibilityLiveRegion = View.ACCESSIBILITY_LIVE_REGION_POLITE }
        result = label("").apply { contentDescription = "解析結果"; setTextIsSelectable(true) }
        label("音声と結果には機微情報を含む場合があります。送信先を確認してください。保存ファイルは自動削除されません。", 13f)
        return scroll
    }
    private fun render() {
        val signedIn = model.loginStep as? CalliopeiaLoginStep.SignedIn
        val needsCode = model.loginStep == CalliopeiaLoginStep.EmailCode || model.loginStep == CalliopeiaLoginStep.AccountConfirmation
        val available = !model.busy && !model.isRecording
        email.visibility = if (signedIn == null && !needsCode) View.VISIBLE else View.GONE
        login.visibility = email.visibility
        code.visibility = if (needsCode) View.VISIBLE else View.GONE
        confirm.visibility = code.visibility; resend.visibility = code.visibility
        logout.visibility = if (signedIn != null) View.VISIBLE else View.GONE
        account.text = signedIn?.account?.email?.let { address -> "$address\n${if (model.access?.canRunJobs == true) "音声を送信できます" else "送信権限がありません"}" }
            ?: if (model.configured) "メールで届くコードでログインします" else "接続設定がありません"
        listOf(login, confirm, resend, logout, email, code).forEach { it.isEnabled = available && model.configured }
        start.isEnabled = available
        stop.isEnabled = model.isRecording && !model.busy
        submit.isEnabled = available && model.recording != null && model.access?.canRunJobs == true
        refresh.isEnabled = available && model.jobID != null
        status.text = model.message; result.text = model.resultText
        if (model.isRecording) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
    }
    private fun layout() = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        .apply { topMargin = dp(10) }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
}
