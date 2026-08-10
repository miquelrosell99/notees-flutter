package com.notees.notees

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity : FlutterActivity() {
    companion object {
        const val CHANNEL = "com.notees.notees/intents"
        private var pendingShare: SharePayload? = null
        private var pendingDeepLink: String? = null
        private var pendingQuickNoteTile: Boolean = false
        private var pendingAudioNoteTile: Boolean = false
    }

    data class SharePayload(
        var text: String? = null,
        var imagePath: String? = null,
    ) {
        fun toMap(): Map<String, String?> {
            return mapOf(
                "text" to text,
                "imagePath" to imagePath,
            )
        }
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
                "getPendingShare" -> {
                    val payload = pendingShare
                    pendingShare = null
                    result.success(payload?.toMap() ?: emptyMap<String, String>())
                }
                "getPendingDeepLink" -> {
                    val link = pendingDeepLink
                    pendingDeepLink = null
                    result.success(link)
                }
                "getPendingQuickNoteTile" -> {
                    val pending = pendingQuickNoteTile
                    pendingQuickNoteTile = false
                    result.success(pending)
                }
                "getPendingAudioNoteTile" -> {
                    val pending = pendingAudioNoteTile
                    pendingAudioNoteTile = false
                    result.success(pending)
                }
                else -> result.notImplemented()
            }
        }
        flushPendingEvents()
    }

    private fun handleIntent(intent: Intent?) {
        when (intent?.action) {
            Intent.ACTION_SEND -> {
                when {
                    intent.type?.startsWith("image/") == true -> {
                        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                        if (uri != null) {
                            val path = cacheUri(uri)
                            if (path != null) {
                                pendingShare = SharePayload(imagePath = path)
                                flushPendingEvents()
                            }
                        }
                    }
                    intent.type?.startsWith("text/") == true -> {
                        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                        if (!text.isNullOrBlank()) {
                            pendingShare = SharePayload(text = text.take(100_000))
                            flushPendingEvents()
                        }
                    }
                    else -> {
                        // Graceful fallback: try to read any shared text.
                        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                        if (!text.isNullOrBlank()) {
                            pendingShare = SharePayload(text = text.take(100_000))
                            flushPendingEvents()
                        }
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
            QuickNoteTileService.ACTION_QUICK_NOTE -> {
                pendingQuickNoteTile = true
                flushPendingEvents()
            }
            AudioNoteTileService.ACTION_AUDIO_NOTE -> {
                pendingAudioNoteTile = true
                flushPendingEvents()
            }
        }
    }

    private fun cacheUri(uri: Uri): String? {
        val resolver = contentResolver ?: return null
        val mimeType = resolver.getType(uri) ?: "image/jpeg"
        val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: "jpg"
        val file = File(cacheDir, "share_${System.currentTimeMillis()}.$extension")
        return try {
            resolver.openInputStream(uri)?.use { input ->
                FileOutputStream(file).use { output ->
                    input.copyTo(output)
                }
            }
            file.absolutePath
        } catch (e: Exception) {
            e.printStackTrace()
            null
        }
    }

    private fun flushPendingEvents() {
        methodChannel ?: return
        pendingShare?.let {
            pendingShare = null
            methodChannel?.invokeMethod("onShare", it.toMap())
        }
        if (pendingDeepLink != null) {
            methodChannel?.invokeMethod("onDeepLink", pendingDeepLink)
        }
        if (pendingQuickNoteTile) {
            pendingQuickNoteTile = false
            methodChannel?.invokeMethod("onQuickNoteTile", null)
        }
        if (pendingAudioNoteTile) {
            pendingAudioNoteTile = false
            methodChannel?.invokeMethod("onAudioNoteTile", null)
        }
    }
}
