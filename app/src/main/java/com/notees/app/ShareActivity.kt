package com.notees.app

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity

/**
 * Transparent trampoline activity that receives Android Share intents
 * (text/plain and text/html) and forwards the payload to MainActivity
 * via the JavaScript bridge.
 *
 * Flow:
 *  1. User shares a URL / text from another app → Android sends an
 *     ACTION_SEND intent to this activity.
 *  2. ShareActivity reads the payload, starts (or brings-to-front)
 *     MainActivity and passes the text via EXTRA_SHARE_TEXT.
 *  3. MainActivity injects it into the WebView via JS:
 *       noteesBridge.onShareReceived(text, sourceUrl)
 *  4. The web app opens a quick-capture popup so the user can save it.
 */
class ShareActivity : AppCompatActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val sharedText = when {
            intent.action == Intent.ACTION_SEND &&
            intent.type?.startsWith("text/") == true ->
                intent.getStringExtra(Intent.EXTRA_TEXT)
            else -> null
        }

        val serverUrl = ServerPreferences.getServerUrl(this)

        if (sharedText != null && serverUrl != null) {
            // Relay to MainActivity (creates it if not running, or reuses existing)
            val main = Intent(this, MainActivity::class.java).apply {
                action = MainActivity.ACTION_SHARE_RECEIVED
                putExtra(MainActivity.EXTRA_SERVER_URL, serverUrl)
                putExtra(MainActivity.EXTRA_SHARE_TEXT, sharedText)
                // Bring existing task to front rather than creating a new stack
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP
                )
            }
            startActivity(main)
        }

        // ShareActivity has no UI — dismiss immediately
        finish()
    }
}
