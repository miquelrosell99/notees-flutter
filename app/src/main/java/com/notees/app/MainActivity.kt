package com.notees.app

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Message
import android.view.View
import android.webkit.CookieManager
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.ProgressBar
import android.widget.TextView
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import org.json.JSONObject

class MainActivity : AppCompatActivity(), AndroidBridge.Host {

    companion object {
        const val EXTRA_SERVER_URL = "server_url"
        const val EXTRA_SHARE_TEXT = "share_text"
        const val EXTRA_DEEP_LINK_PATH = "deep_link_path"
        const val ACTION_SHARE_RECEIVED = "com.notees.app.ACTION_SHARE_RECEIVED"
        const val ACTION_QUICK_NOTE = "com.notees.app.ACTION_QUICK_NOTE"
    }

    private lateinit var webView: WebView
    private lateinit var progressBar: ProgressBar
    private lateinit var errorOverlay: View
    private lateinit var errorText: TextView

    private var serverUrl: String = ""
    private var fileUploadCallback: ValueCallback<Array<Uri>>? = null

    /** Tracks whether the web-app drawer is open (kept in sync via bridge). */
    private var drawerOpen: Boolean = false

    /** Set to true once the first page finishes loading (dismisses splash screen). */
    private var pageLoaded: Boolean = false

    private val fileChooserLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult()
    ) { result ->
        val uris = if (result.resultCode == Activity.RESULT_OK) {
            result.data?.let { intent ->
                intent.clipData?.let { clip ->
                    Array(clip.itemCount) { clip.getItemAt(it).uri }
                } ?: intent.data?.let { arrayOf(it) }
            }
        } else null
        fileUploadCallback?.onReceiveValue(uris ?: emptyArray())
        fileUploadCallback = null
    }

    // ── AndroidBridge.Host ────────────────────────────────────────────────────

    override fun bridgeOpenDrawer() {
        drawerOpen = true
    }

    override fun bridgeCloseDrawer() {
        drawerOpen = false
    }

    override fun bridgeIsDrawerOpen(): Boolean = drawerOpen

    override fun bridgeShowServerSettings() {
        showChangeServerDialog()
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onCreate(savedInstanceState: Bundle?) {
        val splashScreen = installSplashScreen()
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)

        setContentView(R.layout.activity_main)

        serverUrl = intent.getStringExtra(EXTRA_SERVER_URL)
            ?: ServerPreferences.getServerUrl(this)
            ?: run { goToSetup(); return }

        webView = findViewById(R.id.webView)
        progressBar = findViewById(R.id.progressBar)
        errorOverlay = findViewById(R.id.errorOverlay)
        errorText = findViewById(R.id.errorText)

        // Keep splash screen visible until the first page load completes
        splashScreen.setKeepOnScreenCondition { !pageLoaded }

        // Pad WebView so content doesn't render behind system bars.
        // Android WebView doesn't expose env(safe-area-inset-*) CSS values,
        // so we handle the insets natively instead.
        ViewCompat.setOnApplyWindowInsetsListener(webView) { view, insets ->
            val statusTop = insets.getInsets(WindowInsetsCompat.Type.statusBars()).top
            val imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            val navBottom = insets.getInsets(WindowInsetsCompat.Type.navigationBars()).bottom
            view.setPadding(0, statusTop, 0, maxOf(imeBottom, navBottom))
            insets
        }
        // Trigger the listener immediately so padding is applied before the
        // first page load rather than waiting for the next inset dispatch.
        ViewCompat.requestApplyInsets(webView)

        findViewById<View>(R.id.retryButton).setOnClickListener {
            errorOverlay.visibility = View.GONE
            webView.loadUrl(serverUrl)
        }

        setupWebView()
        setupBackNavigation()

        if (savedInstanceState != null) {
            webView.restoreState(savedInstanceState)
            // Replay any pending intent after restore
            handleIncomingIntent(intent)
        } else {
            webView.loadUrl(serverUrl)
            // Payload will be injected once the page finishes loading
        }
    }

    /**
     * Called when the activity is already running and receives a new intent
     * (FLAG_ACTIVITY_SINGLE_TOP / FLAG_ACTIVITY_CLEAR_TOP).
     * Handles share intents and deep links arriving while the app is open.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIncomingIntent(intent)
    }

    // ── WebView setup ─────────────────────────────────────────────────────────

    @SuppressLint("SetJavaScriptEnabled")
    private fun setupWebView() {
        // Enable remote debugging in debug builds only
        WebView.setWebContentsDebuggingEnabled(BuildConfig.DEBUG)

        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            @Suppress("DEPRECATION")
            databaseEnabled = true
            allowFileAccess = false
            mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            cacheMode = WebSettings.LOAD_DEFAULT
            setSupportMultipleWindows(false)
            setSupportZoom(false)
            builtInZoomControls = false
            displayZoomControls = false
            // Don't override the web app's viewport — it handles mobile itself
            useWideViewPort = false
            loadWithOverviewMode = false
            userAgentString = "${userAgentString} NoteesAndroid/1.0"
        }

        // Register the JS bridge as window.Android
        webView.addJavascriptInterface(AndroidBridge(this, this), "Android")

        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(
                view: WebView,
                request: WebResourceRequest,
            ): Boolean {
                val url = request.url.toString()
                return if (url.startsWith(serverUrl)) {
                    false // internal — let WebView navigate
                } else {
                    startActivity(Intent(Intent.ACTION_VIEW, request.url))
                    true
                }
            }

            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                progressBar.visibility = View.GONE
                pageLoaded = true

                // Inject any pending payload after initial load
                handleIncomingIntent(intent)
            }

            override fun onReceivedError(
                view: WebView,
                request: WebResourceRequest,
                error: WebResourceError,
            ) {
                if (request.isForMainFrame) {
                    progressBar.visibility = View.GONE
                    errorOverlay.visibility = View.VISIBLE
                    errorText.text = getString(
                        R.string.error_connection,
                        error.description?.toString() ?: getString(R.string.error_unknown),
                    )
                }
            }
        }

        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                if (newProgress < 100) {
                    progressBar.visibility = View.VISIBLE
                    progressBar.progress = newProgress
                } else {
                    progressBar.visibility = View.GONE
                }
            }

            override fun onShowFileChooser(
                webView: WebView,
                callback: ValueCallback<Array<Uri>>,
                params: FileChooserParams,
            ): Boolean {
                fileUploadCallback?.onReceiveValue(null)
                fileUploadCallback = callback
                fileChooserLauncher.launch(params.createIntent())
                return true
            }

            override fun onCreateWindow(
                view: WebView,
                isDialog: Boolean,
                isUserGesture: Boolean,
                resultMsg: Message?,
            ): Boolean = false
        }
    }

    // ── Back navigation ───────────────────────────────────────────────────────

    private fun setupBackNavigation() {
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    // 1. If the web-app drawer is open, tell JS to close it
                    drawerOpen -> {
                        evalJs("if(window.noteesBridge) window.noteesBridge.closeDrawer()")
                        drawerOpen = false
                    }
                    // 2. Navigate back inside the WebView history
                    webView.canGoBack() -> webView.goBack()
                    // 3. Fall through to the system (minimises / exits)
                    else -> {
                        isEnabled = false
                        onBackPressedDispatcher.onBackPressed()
                    }
                }
            }
        })
    }

    // ── Incoming intents (share / deep link / quick note) ─────────────────────

    /**
     * Dispatches an incoming intent to the appropriate JS handler.
     * Safe to call before the page has loaded — the flag is checked
     * in onPageFinished and replayed once the page is ready.
     */
    private var intentDispatched = false

    private fun handleIncomingIntent(intent: Intent?) {
        if (intent == null || intentDispatched) return
        // Only act once the WebView has a loaded page
        if (webView.url == null) return

        when (intent.action) {
            ACTION_SHARE_RECEIVED -> {
                val text = intent.getStringExtra(EXTRA_SHARE_TEXT) ?: return
                val safe = JSONObject.quote(text) // returns a JSON-safe "…" string
                evalJs("if(window.noteesBridge) window.noteesBridge.onShareReceived($safe)")
                intentDispatched = true
            }
            ACTION_QUICK_NOTE -> {
                evalJs("if(window.noteesBridge) window.noteesBridge.openQuickNote()")
                intentDispatched = true
            }
            Intent.ACTION_VIEW -> {
                val uri = intent.data ?: return
                val path = buildDeepLinkPath(uri) ?: return
                val safe = JSONObject.quote(path)
                evalJs("if(window.noteesBridge) window.noteesBridge.onDeepLink($safe)")
                intentDispatched = true
            }
        }
    }

    /**
     * Converts a deep-link URI to a relative path the web app can route to.
     *
     * Supported schemes:
     *   notees://note/42          → /node/42
     *   https://myserver/note/42  → /note/42
     */
    private fun buildDeepLinkPath(uri: Uri): String? {
        return when (uri.scheme) {
            "notees" -> {
                val rest = uri.encodedPath?.trimStart('/')
                "/$rest"
            }
            "https", "http" -> {
                // Only handle URLs that belong to our server
                val serverHost = Uri.parse(serverUrl).host
                if (uri.host == serverHost) uri.path else null
            }
            else -> null
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    /** Runs arbitrary JS on the main thread. */
    fun evalJs(js: String) = webView.post { webView.evaluateJavascript(js, null) }

    private fun showChangeServerDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_change_server_title)
            .setMessage(R.string.dialog_change_server_message)
            .setPositiveButton(R.string.dialog_disconnect) { _, _ ->
                CookieManager.getInstance().removeAllCookies(null)
                webView.clearCache(true)
                webView.clearHistory()
                ServerPreferences.clearServerUrl(this)
                goToSetup()
            }
            .setNegativeButton(R.string.dialog_cancel, null)
            .show()
    }

    private fun goToSetup() {
        startActivity(Intent(this, SetupActivity::class.java))
        finish()
    }

    // ── State save / restore ──────────────────────────────────────────────────

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        webView.saveState(outState)
    }

    override fun onResume() {
        super.onResume()
        webView.onResume()
        CookieManager.getInstance().flush()
    }

    override fun onPause() {
        webView.onPause()
        CookieManager.getInstance().flush()
        super.onPause()
    }

    override fun onDestroy() {
        webView.destroy()
        super.onDestroy()
    }
}

