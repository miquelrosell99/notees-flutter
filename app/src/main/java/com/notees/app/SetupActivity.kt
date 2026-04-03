package com.notees.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.inputmethod.EditorInfo
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import java.net.HttpURLConnection
import java.net.URL

class SetupActivity : AppCompatActivity() {

    private lateinit var urlInputLayout: TextInputLayout
    private lateinit var urlInput: TextInputEditText
    private lateinit var connectButton: MaterialButton

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)

        // If a server URL is already saved, skip straight to MainActivity
        val savedUrl = ServerPreferences.getServerUrl(this)
        if (savedUrl != null) {
            launchMain(savedUrl)
            return
        }

        setContentView(R.layout.activity_setup)

        urlInputLayout = findViewById(R.id.urlInputLayout)
        urlInput = findViewById(R.id.urlInput)
        connectButton = findViewById(R.id.connectButton)

        connectButton.setOnClickListener { attemptConnect() }

        urlInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_GO) {
                attemptConnect()
                true
            } else false
        }
    }

    private fun attemptConnect() {
        val rawUrl = urlInput.text?.toString()?.trim() ?: ""
        urlInputLayout.error = null

        if (rawUrl.isEmpty()) {
            urlInputLayout.error = getString(R.string.error_url_empty)
            return
        }

        val url = normalizeUrl(rawUrl)
        if (!isValidUrl(url)) {
            urlInputLayout.error = getString(R.string.error_url_invalid)
            return
        }

        // Warn about cleartext HTTP on public-looking hostnames
        val uri = Uri.parse(url)
        if (uri.scheme == "http" && !isPrivateHost(uri.host ?: "")) {
            AlertDialog.Builder(this)
                .setTitle(R.string.dialog_http_warning_title)
                .setMessage(R.string.dialog_http_warning_message)
                .setPositiveButton(R.string.dialog_http_warning_continue) { _, _ ->
                    verifyAndConnect(url)
                }
                .setNegativeButton(R.string.dialog_cancel, null)
                .show()
            return
        }

        verifyAndConnect(url)
    }

    /**
     * Ping the server in a background thread, then save + launch if reachable.
     */
    private fun verifyAndConnect(url: String) {
        connectButton.isEnabled = false
        connectButton.text = getString(R.string.button_connecting)
        urlInputLayout.error = null

        Thread {
            val reachable = try {
                val conn = URL(url).openConnection() as HttpURLConnection
                conn.connectTimeout = 8_000
                conn.readTimeout = 8_000
                conn.requestMethod = "HEAD"
                conn.instanceFollowRedirects = true
                try {
                    conn.responseCode in 200..499 // any response = server exists
                } finally {
                    conn.disconnect()
                }
            } catch (_: Exception) {
                false
            }

            runOnUiThread {
                connectButton.isEnabled = true
                connectButton.text = getString(R.string.button_connect)
                if (reachable) {
                    ServerPreferences.setServerUrl(this, url)
                    launchMain(url)
                } else {
                    urlInputLayout.error = getString(R.string.error_unreachable)
                }
            }
        }.start()
    }

    /**
     * Returns true for hostnames / IPs that look like private networks,
     * Tailscale, or local mDNS — where cleartext HTTP is expected.
     */
    private fun isPrivateHost(host: String): Boolean {
        // Tailscale MagicDNS
        if (host.endsWith(".ts.net")) return true
        // mDNS
        if (host.endsWith(".local")) return true
        // localhost
        if (host == "localhost" || host == "127.0.0.1") return true
        // Check for private / CGNAT IP ranges
        return try {
            val addr = java.net.InetAddress.getByName(host)
            addr.isSiteLocalAddress || addr.isLoopbackAddress || addr.isLinkLocalAddress ||
                // Tailscale CGNAT 100.64.0.0/10
                (addr.address.size == 4 && (addr.address[0].toInt() and 0xFF) == 100 &&
                    (addr.address[1].toInt() and 0xC0) == 64)
        } catch (_: Exception) {
            false
        }
    }

    private fun normalizeUrl(raw: String): String {
        var url = raw
        if (!url.startsWith("http://") && !url.startsWith("https://")) {
            url = "https://$url"
        }
        return url.trimEnd('/')
    }

    private fun isValidUrl(url: String): Boolean =
        try {
            val uri = Uri.parse(url)
            uri.scheme in listOf("http", "https") && !uri.host.isNullOrBlank()
        } catch (_: Exception) {
            false
        }

    private fun launchMain(url: String) {
        val intent = Intent(this, MainActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_SERVER_URL, url)
        }
        startActivity(intent)
        finish()
    }
}
