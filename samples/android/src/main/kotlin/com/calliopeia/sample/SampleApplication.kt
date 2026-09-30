package com.calliopeia.sample

import android.app.Application
import com.calliopeia.auth.CalliopeiaSession
import com.calliopeia.sdk.CalliopeiaEnvironment

class SampleApplication : Application() {
    lateinit var model: SampleModel
        private set
    override fun onCreate() {
        super.onCreate()
        val environment = runCatching {
            val outputs = assets.open("amplify_outputs.json").bufferedReader().use { it.readText() }
            CalliopeiaSession.configure(this, outputs)
            CalliopeiaEnvironment(outputs)
        }.getOrNull()
        model = SampleModel(this, environment)
    }
}
