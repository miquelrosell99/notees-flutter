package com.notees.app

import android.content.Context
import android.content.Intent
import android.webkit.JavascriptInterface
import androidx.core.content.ContextCompat

/**
 * JavaScript bridge exposed to the WebView as `window.Android`.
 *
 * The web app calls these methods from JS:
 *   window.Android.openDrawer()
 *   window.Android.closeDrawer()
 *   window.Android.setDrawerOpen(true/false)
 *   window.Android.isDrawerOpen() → Boolean
 *   window.Android.shareText("text")
 *   window.Android.openUrl("https://…")
 *
 * Native calls into JS via MainActivity.evalJs():
 *   notees_bridge.onShareReceived(text, sourceUrl)
 *   notees_bridge.onDeepLink(path)
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

    /**
     * Triggers the Android native share sheet.  Called by the web app when
     * the user taps "Share" inside the notes UI.
     */
    @JavascriptInterface
    fun shareText(text: String) {
        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_TEXT, text)
        }
        val chooser = Intent.createChooser(intent, null).apply {
            // FLAG_ACTIVITY_NEW_TASK required when launching from non-Activity context
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        context.startActivity(chooser)
    }

    /**
     * Opens an external URL in the system browser (the web app should not
     * navigate the WebView away from the server).
     */
    @JavascriptInterface
    fun openUrl(url: String) {
        val intent = Intent(Intent.ACTION_VIEW, android.net.Uri.parse(url)).apply {
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
