package com.notees.app

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Manages persistent storage of authentication credentials using encrypted shared preferences.
 *
 * Unlike WebView localStorage — which can be cleared by WebView component updates,
 * OEM customizations, or app reinstalls — this native store is backed by the Android
 * Keystore and survives app updates reliably.
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

    // ── Auth token ────────────────────────────────────────────────────────────

    fun getAuthToken(context: Context): String? =
        getPrefs(context).getString(KEY_AUTH_TOKEN, null)

    fun setAuthToken(context: Context, token: String) =
        getPrefs(context).edit().putString(KEY_AUTH_TOKEN, token).apply()

    fun clearAuthToken(context: Context) =
        getPrefs(context).edit().remove(KEY_AUTH_TOKEN).apply()

    // ── User data (JSON string) ───────────────────────────────────────────────

    fun getUserData(context: Context): String? =
        getPrefs(context).getString(KEY_USER_DATA, null)

    fun setUserData(context: Context, userJson: String) =
        getPrefs(context).edit().putString(KEY_USER_DATA, userJson).apply()

    fun clearUserData(context: Context) =
        getPrefs(context).edit().remove(KEY_USER_DATA).apply()

    // ── Biometric lock ────────────────────────────────────────────────────────

    fun getBiometricEnabled(context: Context): Boolean =
        getPrefs(context).getBoolean(KEY_BIOMETRIC_ENABLED, false)

    fun setBiometricEnabled(context: Context, enabled: Boolean) =
        getPrefs(context).edit().putBoolean(KEY_BIOMETRIC_ENABLED, enabled).apply()

    // ── Bulk operations ───────────────────────────────────────────────────────

    fun clearAll(context: Context) {
        getPrefs(context).edit()
            .remove(KEY_AUTH_TOKEN)
            .remove(KEY_USER_DATA)
            .remove(KEY_BIOMETRIC_ENABLED)
            .apply()
    }
}
