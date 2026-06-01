package com.notees.app

import android.content.Context
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity

/**
 * Manages biometric authentication for the Notees app.
 *
 * When enabled, the user must authenticate with fingerprint or face unlock
 * every time the app is resumed from the background.
 */
object BiometricHelper {

    private const val KEY_BIOMETRIC_ENABLED = "biometric_enabled"

    fun isEnabled(context: Context): Boolean {
        return AuthPreferences.getBiometricEnabled(context)
    }

    fun setEnabled(context: Context, enabled: Boolean) {
        AuthPreferences.setBiometricEnabled(context, enabled)
    }

    /**
     * Returns true if the device supports biometric authentication
     * (fingerprint, face, or iris).
     */
    fun canAuthenticate(context: Context): Boolean {
        val biometricManager = BiometricManager.from(context)
        return biometricManager.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK) ==
                BiometricManager.BIOMETRIC_SUCCESS
    }

    /**
     * Show the biometric prompt. Calls [onResult] with true if authenticated,
     * false if cancelled or failed.
     */
    fun showPrompt(
        activity: FragmentActivity,
        onResult: (success: Boolean) -> Unit,
    ) {
        val executor = ContextCompat.getMainExecutor(activity)
        val prompt = BiometricPrompt(
            activity,
            executor,
            object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    onResult(true)
                }

                override fun onAuthenticationError(errorCode: Int, errString: CharSequence) {
                    onResult(false)
                }

                override fun onAuthenticationFailed() {
                    onResult(false)
                }
            },
        )

        val info = BiometricPrompt.PromptInfo.Builder()
            .setTitle(activity.getString(R.string.biometric_title))
            .setSubtitle(activity.getString(R.string.biometric_subtitle))
            .setNegativeButtonText(activity.getString(R.string.biometric_cancel))
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_WEAK)
            .build()

        prompt.authenticate(info)
    }
}
