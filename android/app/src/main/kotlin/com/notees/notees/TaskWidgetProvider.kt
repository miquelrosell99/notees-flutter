package com.notees.notees

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.widget.RemoteViews
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import dev.fluttercommunity.workmanager.BackgroundWorker
import org.json.JSONArray
import org.json.JSONObject

private const val EXTRA_TASK_UUID = "task_uuid"

/**
 * Home-screen widget that surfaces today's open tasks.
 *
 * The Flutter side writes a JSON snapshot of today's tasks to
 * [SharedPreferences]; this provider reads that snapshot and renders one of
 * three layouts depending on the widget's current width:
 *  - Compact (2×1): task count + next due task
 *  - Medium (4×2): up to 6 task rows with "complete" checkboxes
 *  - Large (4×4): up to 10 rows plus an "Add task" footer
 */
class TaskWidgetProvider : AppWidgetProvider() {

    companion object {
        const val ACTION_COMPLETE_TASK = "com.notees.notees.action.COMPLETE_TASK"
        const val ACTION_REFRESH_WIDGET = "com.notees.notees.action.REFRESH_WIDGET"

        private const val PREFS_NAME = "FlutterSharedPreferences"
        private const val TASKS_KEY = "flutter.notees.widget_tasks"
        private const val UPDATED_AT_KEY = "flutter.notees.widget_tasks_updated_at"
        private const val MAX_AGE_MILLIS = 1000L * 60 * 60 * 2 // 2 hours

        private const val WIDGET_UPDATE_WORK = "notees-widget-update"
        private const val WIDGET_COMPLETE_WORK_PREFIX = "notees-widget-complete-"
        private const val WIDGET_UPDATE_DART_TASK = "notees.widgetUpdate"
        private const val WIDGET_COMPLETE_DART_TASK = "notees.widgetCompleteTask"

        fun requestUpdate(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val component = ComponentName(context, TaskWidgetProvider::class.java)
            val ids = manager.getAppWidgetIds(component)
            if (ids.isNotEmpty()) {
                val intent = Intent(context, TaskWidgetProvider::class.java).apply {
                    action = AppWidgetManager.ACTION_APPWIDGET_UPDATE
                    putExtra(AppWidgetManager.EXTRA_APPWIDGET_IDS, ids)
                }
                context.sendBroadcast(intent)
            }
        }
    }

    override fun onUpdate(context: Context, appWidgetManager: AppWidgetManager, appWidgetIds: IntArray) {
        for (appWidgetId in appWidgetIds) {
            updateAppWidget(context, appWidgetManager, appWidgetId)
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            ACTION_COMPLETE_TASK -> {
                val uuid = intent.getStringExtra(EXTRA_TASK_UUID)
                if (!uuid.isNullOrBlank()) {
                    scheduleCompleteTask(context, uuid)
                }
            }
            Intent.ACTION_BOOT_COMPLETED -> {
                scheduleWidgetUpdate(context)
            }
        }
        super.onReceive(context, intent)
    }

    override fun onAppWidgetOptionsChanged(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetId: Int,
        newOptions: Bundle?,
    ) {
        super.onAppWidgetOptionsChanged(context, appWidgetManager, appWidgetId, newOptions)
        updateAppWidget(context, appWidgetManager, appWidgetId)
    }

    private fun updateAppWidget(context: Context, appWidgetManager: AppWidgetManager, appWidgetId: Int) {
        val (tasks, updatedAt) = loadWidgetData(context)
        val options = appWidgetManager.getAppWidgetOptions(appWidgetId)
        val minWidthDp = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 0)

        val layoutRes = when {
            minWidthDp < 180 -> R.layout.widget_task_compact
            minWidthDp < 300 -> R.layout.widget_task_medium
            else -> R.layout.widget_task_large
        }

        val views = RemoteViews(context.packageName, layoutRes).apply {
            bindHeader(this, tasks)
        }

        when (layoutRes) {
            R.layout.widget_task_compact -> bindCompact(views, context, appWidgetId, tasks)
            R.layout.widget_task_medium -> bindList(views, context, appWidgetId, tasks, maxRows = 6)
            R.layout.widget_task_large -> {
                bindList(views, context, appWidgetId, tasks, maxRows = 10)
                bindLargeFooter(views, context, appWidgetId)
            }
        }

        appWidgetManager.updateAppWidget(appWidgetId, views)

        if (tasks.isEmpty() || updatedAt == null || System.currentTimeMillis() - updatedAt > MAX_AGE_MILLIS) {
            scheduleWidgetUpdate(context)
        }
    }

    private fun bindHeader(views: RemoteViews, tasks: List<TaskSummary>) {
        views.setTextViewText(R.id.widget_count, tasks.size.toString())
    }

    private fun bindCompact(views: RemoteViews, context: Context, appWidgetId: Int, tasks: List<TaskSummary>) {
        views.setTextViewText(
            R.id.widget_count,
            context.resources.getQuantityString(R.plurals.widget_task_count, tasks.size, tasks.size),
        )
        views.setTextViewText(
            R.id.widget_next,
            tasks.firstOrNull()?.displayName ?: context.getString(R.string.widget_all_caught_up),
        )

        val openTasksIntent = Intent(Intent.ACTION_VIEW, Uri.parse("notees://tasks")).apply {
            setClass(context, MainActivity::class.java)
        }
        val pendingOpen = PendingIntent.getActivity(
            context,
            appWidgetId * 1000,
            openTasksIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_root, pendingOpen)
    }

    private fun bindList(
        views: RemoteViews,
        context: Context,
        appWidgetId: Int,
        tasks: List<TaskSummary>,
        maxRows: Int,
    ) {
        if (tasks.isEmpty()) {
            views.setViewVisibility(R.id.widget_tasks_container, View.GONE)
            views.setViewVisibility(R.id.widget_empty, View.VISIBLE)
            return
        }

        views.setViewVisibility(R.id.widget_tasks_container, View.VISIBLE)
        views.setViewVisibility(R.id.widget_empty, View.GONE)

        val container = R.id.widget_tasks_container
        for ((index, task) in tasks.take(maxRows).withIndex()) {
            val row = RemoteViews(context.packageName, R.layout.widget_task_row)
            row.setTextViewText(R.id.task_name, task.displayName)
            row.setImageViewResource(R.id.task_checkbox, R.drawable.ic_widget_checkbox_unchecked)

            val openEditorIntent = Intent(Intent.ACTION_VIEW, Uri.parse("notees://editor/${task.uuid}")).apply {
                setClass(context, MainActivity::class.java)
            }
            val baseRequestCode = appWidgetId * 1000 + index
            val pendingOpen = PendingIntent.getActivity(
                context,
                baseRequestCode,
                openEditorIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            row.setOnClickPendingIntent(R.id.task_row, pendingOpen)

            val completeIntent = Intent(context, TaskWidgetProvider::class.java).apply {
                action = ACTION_COMPLETE_TASK
                putExtra(EXTRA_TASK_UUID, task.uuid)
            }
            val pendingComplete = PendingIntent.getBroadcast(
                context,
                baseRequestCode + 500,
                completeIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            row.setOnClickPendingIntent(R.id.task_checkbox, pendingComplete)

            views.addView(container, row)
        }
    }

    private fun bindLargeFooter(views: RemoteViews, context: Context, appWidgetId: Int) {
        val addTaskIntent = Intent(Intent.ACTION_VIEW, Uri.parse("notees://shortcut/task")).apply {
            setClass(context, MainActivity::class.java)
        }
        val pendingAdd = PendingIntent.getActivity(
            context,
            appWidgetId * 1000 + 2000,
            addTaskIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        views.setOnClickPendingIntent(R.id.widget_add, pendingAdd)
    }

    private fun loadWidgetData(context: Context): Pair<List<TaskSummary>, Long?> {
        return try {
            val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            val raw = prefs.getString(TASKS_KEY, null)
            val updatedAt = prefs.getLong(UPDATED_AT_KEY, 0L).takeIf { it > 0L }

            if (raw.isNullOrBlank()) {
                return emptyList<TaskSummary>() to updatedAt
            }

            val array = JSONArray(raw)
            val tasks = (0 until array.length()).map { i ->
                val obj = array.getJSONObject(i)
                TaskSummary(
                    uuid = obj.getString("uuid"),
                    displayName = obj.optString("displayName", ""),
                    dueDate = obj.optString("dueDate").takeIf { it.isNotBlank() },
                )
            }
            tasks to updatedAt
        } catch (e: Exception) {
            emptyList<TaskSummary>() to null
        }
    }

    private fun scheduleWidgetUpdate(context: Context) {
        val inputData = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, WIDGET_UPDATE_DART_TASK)
            .build()
        val workRequest = OneTimeWorkRequest.Builder(BackgroundWorker::class.java)
            .setInputData(inputData)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            WIDGET_UPDATE_WORK,
            ExistingWorkPolicy.KEEP,
            workRequest,
        )
    }

    private fun scheduleCompleteTask(context: Context, uuid: String) {
        val inputData = Data.Builder()
            .putString(BackgroundWorker.DART_TASK_KEY, WIDGET_COMPLETE_DART_TASK)
            .putString(EXTRA_TASK_UUID, uuid)
            .build()
        val workRequest = OneTimeWorkRequest.Builder(BackgroundWorker::class.java)
            .setInputData(inputData)
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork(
            "$WIDGET_COMPLETE_WORK_PREFIX$uuid",
            ExistingWorkPolicy.REPLACE,
            workRequest,
        )
    }

    private data class TaskSummary(
        val uuid: String,
        val displayName: String,
        val dueDate: String?,
    )
}
