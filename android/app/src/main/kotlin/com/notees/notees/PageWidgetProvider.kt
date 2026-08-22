package com.notees.notees

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONArray

/**
 * Home-screen widget that previews the first blocks of the Inbox page.
 *
 * The Flutter side writes a JSON snapshot of the blocks to
 * [SharedPreferences] (see WidgetService); this provider renders up to five
 * rows, each opening the block in the app via a notees:// deep link. Tapping
 * the title opens the Inbox page itself.
 */
class PageWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val INBOX_BLOCKS_KEY = "flutter.notees.widget_inbox_blocks"
        private const val MAX_ROWS = 5

        // Fixed system page, mirrors SystemPageUuids.inbox in
        // lib/core/constants/system.dart.
        private const val INBOX_UUID = "00000000-0000-0000-0002-000000000002"
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    private fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val blocks = loadWidgetData(context)

        val views = RemoteViews(context.packageName, R.layout.widget_page)

        val openPageIntent = Intent(Intent.ACTION_VIEW, Uri.parse("notees://editor/$INBOX_UUID")).apply {
            setClass(context, MainActivity::class.java)
        }
        val pendingOpen = PendingIntent.getActivity(
            context,
            appWidgetId * 1000,
            openPageIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_title, pendingOpen)

        if (blocks.isEmpty()) {
            views.setViewVisibility(R.id.widget_pages_container, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
        } else {
            views.setViewVisibility(R.id.widget_pages_container, View.VISIBLE)
            views.setViewVisibility(R.id.widget_empty, View.GONE)

            for ((index, block) in blocks.take(MAX_ROWS).withIndex()) {
                val row = RemoteViews(context.packageName, R.layout.widget_page_row)
                row.setTextViewText(R.id.page_name, block.displayName)

                val openEditorIntent = Intent(Intent.ACTION_VIEW, Uri.parse("notees://editor/${block.uuid}")).apply {
                    setClass(context, MainActivity::class.java)
                }
                val pendingRow = PendingIntent.getActivity(
                    context,
                    appWidgetId * 1000 + index,
                    openEditorIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
                )
                row.setOnClickPendingIntent(R.id.page_row, pendingRow)

                views.addView(R.id.widget_pages_container, row)
            }
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)
    }

    private fun loadWidgetData(context: Context): List<BlockSummary> {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(INBOX_BLOCKS_KEY, null)
            if (raw.isNullOrBlank()) {
                return emptyList()
            }
            val array = JSONArray(raw)
            (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                BlockSummary(
                    uuid = obj.getString("uuid"),
                    displayName = obj.optString("displayName", ""),
                )
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private data class BlockSummary(
        val uuid: String,
        val displayName: String,
    )
}
