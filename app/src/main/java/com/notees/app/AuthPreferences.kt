package com.notees.app

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.MessageDigest

/**
 * Manages persistent storage of authentication credentials using encrypted shared preferences.
 *
 * Supports per-server auth storage so switching between multiple Notees instances
 * preserves each server's login state independently.
 *
 * The SharedPreferences instance is cached per-application to avoid recreating
 * the MasterKey on every access.
 */
object AuthPreferences {
    private const val PREFS_NAME = "notees_auth"
    private const val KEY_AUTH_TOKEN = "auth_token"
    private const val KEY_USER_DATA = "user_data"
    private const val KEY_BIOMETRIC_ENABLED = "biometric_enabled"

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

    // ── Server-scoped key helpers ─────────────────────────────────────────────

    private fun serverHash(serverUrl: String): String {
        return MessageDigest.getInstance("SHA-256")
            .digest(serverUrl.toByteArray())
            .joinToString("") { "%02x".format(it) }
            .take(16)
    }

    private fun tokenKey(serverUrl: String?): String {
        return if (serverUrl.isNullOrBlank()) KEY_AUTH_TOKEN else "${KEY_AUTH_TOKEN}_${serverHash(serverUrl)}"
    }

    private fun userDataKey(serverUrl: String?): String {
        return if (serverUrl.isNullOrBlank()) KEY_USER_DATA else "${KEY_USER_DATA}_${serverHash(serverUrl)}"
    }

    private fun getActiveServerUrl(context: Context): String? =
        ServerPreferences.getActiveServer(context)?.url

    // ── Auth token ────────────────────────────────────────────────────────────

    fun getAuthToken(context: Context): String? {
        val prefs = getPrefs(context)
        val serverUrl = getActiveServerUrl(context)
        // Try server-specific key first, then legacy fallback
        return prefs.getString(tokenKey(serverUrl), null)
            ?: prefs.getString(KEY_AUTH_TOKEN, null)
    }

    fun setAuthToken(context: Context, token: String) {
        val serverUrl = getActiveServerUrl(context)
        getPrefs(context).edit().putString(tokenKey(serverUrl), token).apply()
    }

    fun clearAuthToken(context: Context) {
        val serverUrl = getActiveServerUrl(context)
        getPrefs(context).edit().remove(tokenKey(serverUrl)).apply()
    }

    // ── User data (JSON string) ───────────────────────────────────────────────

    fun getUserData(context: Context): String? {
        val prefs = getPrefs(context)
        val serverUrl = getActiveServerUrl(context)
        return prefs.getString(userDataKey(serverUrl), null)
            ?: prefs.getString(KEY_USER_DATA, null)
    }

    fun setUserData(context: Context, userJson: String) {
        val serverUrl = getActiveServerUrl(context)
        getPrefs(context).edit().putString(userDataKey(serverUrl), userJson).apply()
    }

    fun clearUserData(context: Context) {
        val serverUrl = getActiveServerUrl(context)
        getPrefs(context).edit().remove(userDataKey(serverUrl)).apply()
    }

    // ── Biometric lock (global, not per-server) ───────────────────────────────

    fun getBiometricEnabled(context: Context): Boolean =
        getPrefs(context).getBoolean(KEY_BIOMETRIC_ENABLED, false)

    fun setBiometricEnabled(context: Context, enabled: Boolean) =
        getPrefs(context).edit().putBoolean(KEY_BIOMETRIC_ENABLED, enabled).apply()

    // ── Bulk operations ───────────────────────────────────────────────────────

    fun clearAll(context: Context) {
        getPrefs(context).edit().clear().apply()
    }

    fun clearServerData(context: Context, serverUrl: String) {
        getPrefs(context).edit()
            .remove(tokenKey(serverUrl))
            .remove(userDataKey(serverUrl))
            .apply()
    }
}
