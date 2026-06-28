package com.notees.notees

import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Quick Settings tile that launches the app straight into the audio recorder
 * sheet. The recording is uploaded as an asset block to the user's configured
 * quick-capture destination.
 */
class AudioNoteTileService : TileService() {

    override fun onStartListening() {
        super.onStartListening()
        qsTile?.apply {
            state = Tile.STATE_ACTIVE
            label = "Audio note"
            contentDescription = "Record an audio note"
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                subtitle = "Notees"
            }
            updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            action = ACTION_AUDIO_NOTE
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        startActivityAndCollapse(intent)
    }

    companion object {
        const val ACTION_AUDIO_NOTE = "com.notees.notees.action.AUDIO_NOTE"
    }
}
