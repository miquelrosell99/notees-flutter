package com.notees.notees

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker

/**
 * Receiver that re-enqueues the Workmanager task which re-schedules task due-date
 * reminders after a reboot. Android clears AlarmManager alarms on boot, so we
 * must re-create the local notifications that back each reminder.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in bootActions) return

        val inputData = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, RESCHEDULE_REMINDERS_TASK)
            .build()

        val workRequest = OneTimeWorkRequest.Builder(BackgroundWorker::class.java)
            .setInputData(inputData)
            .build()

        WorkManager.getInstance(context).enqueueUniqueWork(
            "notees-boot-reschedule-reminders",
            ExistingWorkPolicy.KEEP,
            workRequest,
        )
    }

    companion object {
        const val RESCHEDULE_REMINDERS_TASK = "notees.rescheduleReminders"

        private val bootActions = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
