package com.notees.app

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.webkit.JavascriptInterface
import androidx.core.content.ContextCompat

/**
 * JavaScript bridge exposed to the WebView as `window.Android`.
 *
 * Web → Native (JS calls these):
 *   window.Android.openDrawer()
 *   window.Android.closeDrawer()
 *   window.Android.setDrawerOpen(true/false)
 *   window.Android.isDrawerOpen()       → Boolean
 *   window.Android.shareText("text")
 *   window.Android.openUrl("https://…")
 *   window.Android.showServerSettings()
 *   window.Android.isNativeApp()        → true
 *
 * Native → Web (Kotlin calls into JS via evaluateJavascript):
 *   window.noteesBridge.onShareReceived(text)
 *   window.noteesBridge.onDeepLink(path)
 *   window.noteesBridge.openQuickNote()
 *   window.noteesBridge.openDrawer()
 *   window.noteesBridge.closeDrawer()
 */
class AndroidBridge(
    private val context: Context,
    private val host: Host,
) {

    interface Host {
        fun bridgeOpenDrawer()
        fun bridgeCloseDrawer()
        fun bridgeIsDrawerOpen(): Boolean
        fun bridgeShowServerSettings()
    }

    // ── Called by JS ─────────────────────────────────────────────────────────

    @JavascriptInterface
    fun openDrawer() = ContextCompat.getMainExecutor(context).execute { host.bridgeOpenDrawer() }

    @JavascriptInterface
    fun closeDrawer() = ContextCompat.getMainExecutor(context).execute { host.bridgeCloseDrawer() }

    @JavascriptInterface
    fun setDrawerOpen(open: Boolean) =
        ContextCompat.getMainExecutor(context).execute {
            if (open) host.bridgeOpenDrawer() else host.bridgeCloseDrawer()
        }

    @JavascriptInterface
    fun isDrawerOpen(): Boolean = host.bridgeIsDrawerOpen()

    companion object {
        /** Maximum text length accepted by shareText() to prevent ANR. */
        private const val MAX_SHARE_LENGTH = 100_000
    }

    /**
     * Triggers the Android native share sheet.  Called by the web app when
     * the user taps "Share" inside the notes UI.
     */
    @JavascriptInterface
    fun shareText(text: String) {
        val safeText = if (text.length > MAX_SHARE_LENGTH) text.take(MAX_SHARE_LENGTH) else text
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, safeText)
        }
        val chooser = Intent.createChooser(intent, null).apply {
            // FLAG_ACTIVITY_NEW_TASK required when launching from non-Activity context
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(chooser)
    }

    /**
     * Opens an external URL in the system browser.  Only http(s) schemes
     * are allowed to prevent intent-based attacks via custom schemes.
     */
    @JavascriptInterface
    fun openUrl(url: String) {
        val parsed = Uri.parse(url)
        if (parsed.scheme !in listOf("http", "https")) return
        val intent = Intent(Intent.ACTION_VIEW, parsed).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(intent)
    }

    /**
     * Opens the native "Change server" dialog from JS.
     * Callable as: window.Android.showServerSettings()
     */
    @JavascriptInterface
    fun showServerSettings() =
        ContextCompat.getMainExecutor(context).execute { host.bridgeShowServerSettings() }

    /**
     * Returns `true` — lets JS feature-detect that it's running inside the
     * Android wrapper.
     */
    @JavascriptInterface
    fun isNativeApp(): Boolean = true
}
