package com.notees.app

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Manages persistent storage of the server URL using encrypted shared preferences.
 * The SharedPreferences instance is cached per-application to avoid recreating
 * the MasterKey on every access.
 */
object ServerPreferences {
    private const val PREFS_NAME = "notees_prefs"
    private const val KEY_SERVER_URL = "server_url"

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

    fun getServerUrl(context: Context): String? =
        getPrefs(context).getString(KEY_SERVER_URL, null)

    fun setServerUrl(context: Context, url: String) =
        getPrefs(context).edit().putString(KEY_SERVER_URL, url).apply()

    fun clearServerUrl(context: Context) =
        getPrefs(context).edit().remove(KEY_SERVER_URL).apply()
}
