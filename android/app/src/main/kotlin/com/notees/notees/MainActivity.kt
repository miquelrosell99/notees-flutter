package com.notees.notees

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.notees.notees/intents"
        private var pendingShareText: String? = null
        private var pendingDeepLink: String? = null
    }

    private var methodChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getPendingShareText" -> {
                    val text = pendingShareText
                    pendingShareText = null
                    result.success(text)
                }
                "getPendingDeepLink" -> {
                    val link = pendingDeepLink
                    pendingDeepLink = null
                    result.success(link)
                }
                else -> result.notImplemented()
            }
        }
        flushPendingEvents()
    }

    private fun handleIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                if (intent.type?.startsWith("text/") == true) {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (!text.isNullOrBlank()) {
                        pendingShareText = text.take(100_000)
                        flushPendingEvents()
                    }
                }
            }
            Intent.ACTION_VIEW -> {
                val data = intent.data
                if (data != null) {
                    pendingDeepLink = data.toString()
                    flushPendingEvents()
                }
            }
        }
    }

    private fun flushPendingEvents() {
        methodChannel ?: return
        if (pendingShareText != null) {
            methodChannel?.invokeMethod("onShareText", pendingShareText)
        }
        if (pendingDeepLink != null) {
            methodChannel?.invokeMethod("onDeepLink", pendingDeepLink)
        }
    }
}
