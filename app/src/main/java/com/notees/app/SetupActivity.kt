package com.notees.app

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.google.android.material.textfield.TextInputEditText
import com.google.android.material.textfield.TextInputLayout
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.net.HttpURLConnection
import java.net.URL

class SetupActivity : AppCompatActivity() {

    private lateinit var serverListView: RecyclerView
    private lateinit var addServerButton: MaterialButton
    private lateinit var addServerForm: ViewGroup
    private lateinit var urlInputLayout: TextInputLayout
    private lateinit var urlInput: TextInputEditText
    private lateinit var nicknameInput: TextInputEditText
    private lateinit var saveServerButton: MaterialButton
    private lateinit var cancelAddButton: MaterialButton
    private lateinit var emptyStateView: TextView

    private lateinit var adapter: ServerListAdapter

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)

        ServerPreferences.migrateLegacyServerUrl(this)

        val servers = ServerPreferences.getServers(this)
        if (servers.isEmpty()) {
            showSetupForm()
        } else {
            val activeServer = ServerPreferences.getActiveServer(this)
            if (activeServer != null) {
                launchMain(activeServer.url)
                return
            }
            showServerList()
        }
    }

    private fun showSetupForm() {
        setContentView(R.layout.activity_setup)

        urlInputLayout = findViewById(R.id.urlInputLayout)
        urlInput = findViewById(R.id.urlInput)
        val connectButton: MaterialButton = findViewById(R.id.connectButton)

        connectButton.setOnClickListener { attemptConnect() }
        findViewById<MaterialButton>(R.id.privacyButton).setOnClickListener { showPrivacyDialog() }

        urlInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_GO) {
                attemptConnect()
                true
            } else false
        }
    }

    private fun showServerList() {
        setContentView(R.layout.activity_setup_list)

        serverListView = findViewById(R.id.serverListView)
        addServerButton = findViewById(R.id.addServerButton)
        addServerForm = findViewById(R.id.addServerForm)
        urlInputLayout = findViewById(R.id.urlInputLayout)
        urlInput = findViewById(R.id.urlInput)
        nicknameInput = findViewById(R.id.nicknameInput)
        saveServerButton = findViewById(R.id.saveServerButton)
        cancelAddButton = findViewById(R.id.cancelAddButton)
        emptyStateView = findViewById(R.id.emptyStateView)

        adapter = ServerListAdapter(
            onConnect = { server ->
                ServerPreferences.setActiveServerId(this, server.id)
                launchMain(server.url)
            },
            onDelete = { server ->
                showDeleteConfirm(server)
            },
            onEdit = { server ->
                showEditDialog(server)
            }
        )

        serverListView.layoutManager = LinearLayoutManager(this)
        serverListView.adapter = adapter

        addServerButton.setOnClickListener { showAddForm() }
        saveServerButton.setOnClickListener { saveNewServer() }
        cancelAddButton.setOnClickListener { hideAddForm() }
        findViewById<MaterialButton>(R.id.privacyButton).setOnClickListener { showPrivacyDialog() }

        refreshServerList()
    }

    private fun showPrivacyDialog() {
        AlertDialog.Builder(this)
            .setTitle(R.string.privacy_policy_title)
            .setMessage(R.string.privacy_policy_message)
            .setPositiveButton(R.string.button_ok, null)
            .show()
    }

    private fun refreshServerList() {
        val servers = ServerPreferences.getServers(this)
        adapter.submitList(servers)
        emptyStateView.visibility = if (servers.isEmpty()) View.VISIBLE else View.GONE
    }

    private fun showAddForm() {
        addServerForm.visibility = View.VISIBLE
        addServerButton.visibility = View.GONE
        urlInput.text?.clear()
        nicknameInput.text?.clear()
        urlInputLayout.error = null
    }

    private fun hideAddForm() {
        addServerForm.visibility = View.GONE
        addServerButton.visibility = View.VISIBLE
        urlInputLayout.error = null
    }

    private fun saveNewServer() {
        val rawUrl = urlInput.text?.toString()?.trim() ?: ""
        val nickname = nicknameInput.text?.toString()?.trim() ?: ""
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

        val finalNickname = nickname.ifBlank { Uri.parse(url).host ?: url }

        saveServerButton.isEnabled = false
        saveServerButton.text = getString(R.string.button_connecting)

        lifecycleScope.launch(Dispatchers.IO) {
            val reachable = pingServer(url)
            withContext(Dispatchers.Main) {
                saveServerButton.isEnabled = true
                saveServerButton.text = getString(R.string.button_save)
                if (reachable) {
                    val profile = ServerPreferences.ServerProfile(
                        id = java.util.UUID.randomUUID().toString(),
                        nickname = finalNickname,
                        url = url
                    )
                    ServerPreferences.addServer(this@SetupActivity, profile)
                    ServerPreferences.setActiveServerId(this@SetupActivity, profile.id)
                    hideAddForm()
                    refreshServerList()
                    launchMain(url)
                } else {
                    urlInputLayout.error = getString(R.string.error_unreachable)
                }
            }
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

    private fun verifyAndConnect(url: String) {
        val connectButton = findViewById<MaterialButton>(R.id.connectButton)
        connectButton.isEnabled = false
        connectButton.text = getString(R.string.button_connecting)
        urlInputLayout.error = null

        lifecycleScope.launch(Dispatchers.IO) {
            val reachable = pingServer(url)
            withContext(Dispatchers.Main) {
                connectButton.isEnabled = true
                connectButton.text = getString(R.string.button_connect)
                if (reachable) {
                    val profile = ServerPreferences.ServerProfile(
                        id = java.util.UUID.randomUUID().toString(),
                        nickname = Uri.parse(url).host ?: url,
                        url = url
                    )
                    ServerPreferences.addServer(this@SetupActivity, profile)
                    ServerPreferences.setActiveServerId(this@SetupActivity, profile.id)
                    launchMain(url)
                } else {
                    urlInputLayout.error = getString(R.string.error_unreachable)
                }
            }
        }
    }

    private fun pingServer(url: String): Boolean {
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.connectTimeout = 8_000
            conn.readTimeout = 8_000
            conn.requestMethod = "HEAD"
            conn.instanceFollowRedirects = true
            try {
                conn.responseCode in 200..299
            } finally {
                conn.disconnect()
            }
        } catch (_: Exception) {
            false
        }
    }

    private fun showDeleteConfirm(server: ServerPreferences.ServerProfile) {
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_remove_server_title)
            .setMessage(getString(R.string.dialog_remove_server_message, server.nickname))
            .setPositiveButton(R.string.button_remove) { _, _ ->
                AuthPreferences.clearServerData(this, server.url)
                ServerPreferences.removeServer(this, server.id)
                refreshServerList()
            }
            .setNegativeButton(R.string.dialog_cancel, null)
            .show()
    }

    private fun showEditDialog(server: ServerPreferences.ServerProfile) {
        val editText = TextInputEditText(this).apply {
            setText(server.nickname)
            hint = getString(R.string.hint_nickname)
        }
        val inputLayout = TextInputLayout(this).apply {
            addView(editText)
            setPadding(48, 24, 48, 0)
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.dialog_edit_server_title)
            .setView(inputLayout)
            .setPositiveButton(R.string.button_save) { _, _ ->
                val newName = editText.text?.toString()?.trim() ?: server.nickname
                ServerPreferences.updateServer(this, server.copy(nickname = newName))
                refreshServerList()
            }
            .setNegativeButton(R.string.dialog_cancel, null)
            .show()
    }

    private fun isPrivateHost(host: String): Boolean {
        if (host.endsWith(".ts.net")) return true
        if (host.endsWith(".local")) return true
        if (host == "localhost" || host == "127.0.0.1") return true
        return try {
            val addr = java.net.InetAddress.getByName(host)
            addr.isSiteLocalAddress || addr.isLoopbackAddress || addr.isLinkLocalAddress ||
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

    // ─── RecyclerView Adapter ──────────────────────────────────────────

    class ServerListAdapter(
        private val onConnect: (ServerPreferences.ServerProfile) -> Unit,
        private val onDelete: (ServerPreferences.ServerProfile) -> Unit,
        private val onEdit: (ServerPreferences.ServerProfile) -> Unit,
    ) : RecyclerView.Adapter<ServerListAdapter.ViewHolder>() {

        private var servers: List<ServerPreferences.ServerProfile> = emptyList()

        fun submitList(list: List<ServerPreferences.ServerProfile>) {
            servers = list
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ViewHolder {
            val view = LayoutInflater.from(parent.context)
                .inflate(R.layout.item_server, parent, false)
            return ViewHolder(view)
        }

        override fun onBindViewHolder(holder: ViewHolder, position: Int) {
            holder.bind(servers[position])
        }

        override fun getItemCount(): Int = servers.size

        inner class ViewHolder(itemView: View) : RecyclerView.ViewHolder(itemView) {
            private val nameView: TextView = itemView.findViewById(R.id.serverName)
            private val urlView: TextView = itemView.findViewById(R.id.serverUrl)
            private val connectBtn: MaterialButton = itemView.findViewById(R.id.serverConnectBtn)
            private val editBtn: MaterialButton = itemView.findViewById(R.id.serverEditBtn)
            private val deleteBtn: MaterialButton = itemView.findViewById(R.id.serverDeleteBtn)

            fun bind(server: ServerPreferences.ServerProfile) {
                nameView.text = server.nickname
                urlView.text = server.url
                connectBtn.setOnClickListener { onConnect(server) }
                editBtn.setOnClickListener { onEdit(server) }
                deleteBtn.setOnClickListener { onDelete(server) }
                connectBtn.contentDescription = itemView.context.getString(
                    R.string.content_description_connect_server,
                    server.nickname,
                )
                editBtn.contentDescription = itemView.context.getString(
                    R.string.content_description_edit_server,
                    server.nickname,
                )
                deleteBtn.contentDescription = itemView.context.getString(
                    R.string.content_description_delete_server,
                    server.nickname,
                )
                itemView.contentDescription = itemView.context.getString(
                    R.string.server_row_content_description,
                    server.nickname,
                    server.url,
                )
                itemView.setOnLongClickListener {
                    onEdit(server)
                    true
                }
            }
        }
    }
}
