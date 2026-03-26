package com.notees.app

import android.content.Intent
import android.os.Bundle
import android.view.inputmethod.EditorInfo
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout

class SetupActivity : AppCompatActivity() {

    private lateinit var urlInputLayout: TextInputLayout
    private lateinit var urlInput: TextInputEditText
    private lateinit var connectButton: MaterialButton

    override fun onCreate(savedInstanceState: Bundle?) {
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

        ServerPreferences.setServerUrl(this, url)
        launchMain(url)
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
            val uri = android.net.Uri.parse(url)
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
