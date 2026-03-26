package com.notees.app

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Manages persistent storage of the server URL using encrypted shared preferences.
 */
object ServerPreferences {
    private const val PREFS_NAME = "notees_prefs"
    private const val KEY_SERVER_URL = "server_url"

    private fun getPrefs(context: Context) =
        EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )

    fun getServerUrl(context: Context): String? =
        getPrefs(context).getString(KEY_SERVER_URL, null)

    fun setServerUrl(context: Context, url: String) =
        getPrefs(context).edit().putString(KEY_SERVER_URL, url).apply()

    fun clearServerUrl(context: Context) =
        getPrefs(context).edit().remove(KEY_SERVER_URL).apply()
}
