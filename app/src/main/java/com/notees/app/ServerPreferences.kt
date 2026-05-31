package com.notees.app

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject

/**
 * Manages persistent storage of server profiles using encrypted shared preferences.
 * Supports multiple servers with nicknames, URLs, and API keys.
 * The SharedPreferences instance is cached per-application.
 */
object ServerPreferences {
    private const val PREFS_NAME = "notees_prefs"
    private const val KEY_SERVERS = "servers"
    private const val KEY_ACTIVE_SERVER_ID = "active_server_id"

    data class ServerProfile(
        val id: String,
        val nickname: String,
        val url: String,
        val apiKey: String = ""
    ) {
        fun toJson(): JSONObject {
            return JSONObject().apply {
                put("id", id)
                put("nickname", nickname)
                put("url", url)
                put("apiKey", apiKey)
            }
        }

        companion object {
            fun fromJson(json: JSONObject): ServerProfile {
                return ServerProfile(
                    id = json.optString("id", ""),
                    nickname = json.optString("nickname", ""),
                    url = json.optString("url", ""),
                    apiKey = json.optString("apiKey", "")
                )
            }
        }
    }

    @Volatile
    private var cachedPrefs: SharedPreferences? = null

    private fun getPrefs(context: Context): SharedPreferences {
        return cachedPrefs ?: synchronized(this) {
            cachedPrefs ?: EncryptedSharedPreferences.create(
                context.applicationContext,
                PREFS_NAME,
                MasterKey.Builder(context.applicationContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build(),
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            ).also { cachedPrefs = it }
        }
    }

    // ─── Legacy migration ───────────────────────────────────────────

    fun migrateLegacyServerUrl(context: Context) {
        val prefs = getPrefs(context)
        val legacyUrl = prefs.getString("server_url", null)
        if (legacyUrl != null && getServers(context).isEmpty()) {
            val profile = ServerProfile(
                id = java.util.UUID.randomUUID().toString(),
                nickname = "Default Server",
                url = legacyUrl
            )
            addServer(context, profile)
            setActiveServerId(context, profile.id)
            prefs.edit().remove("server_url").apply()
        }
    }

    // ─── Server list ────────────────────────────────────────────────

    fun getServers(context: Context): List<ServerProfile> {
        val jsonStr = getPrefs(context).getString(KEY_SERVERS, "[]") ?: "[]"
        return try {
            val array = JSONArray(jsonStr)
            List(array.length()) { i -> ServerProfile.fromJson(array.getJSONObject(i)) }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun addServer(context: Context, profile: ServerProfile) {
        val servers = getServers(context).toMutableList()
        servers.add(profile)
        saveServers(context, servers)
    }

    fun updateServer(context: Context, profile: ServerProfile) {
        val servers = getServers(context).toMutableList()
        val index = servers.indexOfFirst { it.id == profile.id }
        if (index >= 0) {
            servers[index] = profile
            saveServers(context, servers)
        }
    }

    fun removeServer(context: Context, id: String) {
        val servers = getServers(context).filter { it.id != id }
        saveServers(context, servers)
        val activeId = getActiveServerId(context)
        if (activeId == id) {
            clearActiveServerId(context)
        }
    }

    private fun saveServers(context: Context, servers: List<ServerProfile>) {
        val array = JSONArray()
        servers.forEach { array.put(it.toJson()) }
        getPrefs(context).edit().putString(KEY_SERVERS, array.toString()).apply()
    }

    // ─── Active server ──────────────────────────────────────────────

    fun getActiveServerId(context: Context): String? =
        getPrefs(context).getString(KEY_ACTIVE_SERVER_ID, null)

    fun setActiveServerId(context: Context, id: String) {
        getPrefs(context).edit().putString(KEY_ACTIVE_SERVER_ID, id).apply()
    }

    fun clearActiveServerId(context: Context) {
        getPrefs(context).edit().remove(KEY_ACTIVE_SERVER_ID).apply()
    }

    fun getActiveServer(context: Context): ServerProfile? {
        val id = getActiveServerId(context) ?: return null
        return getServers(context).find { it.id == id }
    }

    // ─── Convenience ────────────────────────────────────────────────

    fun getServerUrl(context: Context): String? =
        getActiveServer(context)?.url

    fun getApiKey(context: Context): String? =
        getActiveServer(context)?.apiKey

    fun setApiKey(context: Context, serverId: String, apiKey: String) {
        val server = getServers(context).find { it.id == serverId } ?: return
        updateServer(context, server.copy(apiKey = apiKey))
    }

    fun clearAll(context: Context) {
        getPrefs(context).edit().clear().apply()
        cachedPrefs = null
    }
}
