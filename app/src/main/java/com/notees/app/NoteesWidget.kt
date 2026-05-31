package com.notees.app

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * Home screen widget for Notees.
 *
 * Provides one-tap actions:
 * - Quick Note: opens the app and shows the quick-capture UI
 * - Today's Journal: opens the app and navigates to today's daily note
 */
class NoteesWidget : AppWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
    ) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    companion object {
        fun updateAppWidget(
            context: Context,
            appWidgetManager: AppWidgetManager,
            appWidgetId: Int,
        ) {
            val views = RemoteViews(context.packageName, R.layout.widget_notees)

            // Quick Note button
            val quickNoteIntent = Intent(context, MainActivity::class.java).apply {
                action = MainActivity.ACTION_QUICK_NOTE
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val quickNotePending = PendingIntent.getActivity(
                context,
                0,
                quickNoteIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widgetQuickNote, quickNotePending)

            // Today's Journal button
            val journalIntent = Intent(context, MainActivity::class.java).apply {
                action = Intent.ACTION_VIEW
                // Daily note deep-link: notees://journal/today
                data = android.net.Uri.parse("notees://journal/today")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
            val journalPending = PendingIntent.getActivity(
                context,
                1,
                journalIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            views.setOnClickPendingIntent(R.id.widgetJournal, journalPending)

            appWidgetManager.updateAppWidget(appWidgetId, views)
        }
    }
}
