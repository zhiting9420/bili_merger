package cc.zhiting.bili_merger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.io.IOException

/** Holds foreground status for the complete export batch, including preparation. */
class BurnService : Service() {
    private class Request(val id: Int, val onStopped: () -> Unit) {
        val ready = CompletableDeferred<Unit>()
    }

    companion object {
        private const val CHANNEL_ID = "danmaku_burn"
        private const val NOTIFICATION_ID = 0x62726E
        private const val EXTRA_LABEL = "label"
        private const val EXTRA_REQUEST = "request"
        private var nextId = 0
        private var request: Request? = null
        private var instance: BurnService? = null

        // All entry points and notification updates run on the main thread.
        suspend fun start(context: Context, label: String, onStopped: () -> Unit) {
            check(request == null) { "前台服务正在运行" }
            val current = Request(++nextId, onStopped)
            request = current
            try {
                val intent = Intent(context, BurnService::class.java)
                    .putExtra(EXTRA_LABEL, label).putExtra(EXTRA_REQUEST, current.id)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent)
                else context.startService(intent)
                withTimeout(5000) { current.ready.await() }
            } catch (e: Exception) {
                if (request === current) stop(context)
                throw e
            }
        }

        fun update(label: String, percent: Int) { instance?.publish(label, percent) }

        fun stop(context: Context) {
            request?.ready?.completeExceptionally(IOException("导出已停止"))
            request = null
            instance?.attached = null
            instance?.stopForeground(STOP_FOREGROUND_REMOVE)
            context.stopService(Intent(context, BurnService::class.java))
        }
    }

    private var attached: Request? = null
    private var lastLabel = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val current = request
        if (current == null || current.id != intent?.getIntExtra(EXTRA_REQUEST, -1)) {
            stopSelf(startId)
            return START_NOT_STICKY
        }
        attached = current
        lastLabel = intent.getStringExtra(EXTRA_LABEL) ?: "正在导出"
        try {
            ensureChannel()
            val notification = buildNotification(lastLabel, -1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            current.ready.complete(Unit)
        } catch (e: Exception) {
            failCurrent(e)
        }
        return START_NOT_STICKY
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        failCurrent(IOException("后台导出超过系统允许的时限"))
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        failCurrent(IOException("导出任务已移除"))
        super.onTaskRemoved(rootIntent)
    }

    private fun failCurrent(error: Exception) {
        val current = attached
        attached = null
        if (request === current) request = null
        current?.ready?.completeExceptionally(error)
        current?.onStopped?.invoke()
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        val current = attached
        attached = null
        if (request === current) request = null
        current?.ready?.completeExceptionally(IOException("前台服务已停止"))
        current?.onStopped?.invoke()
        super.onDestroy()
    }

    private fun publish(label: String, percent: Int) {
        if (attached == null || attached !== request) return
        if (label.isNotEmpty()) lastLabel = label
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try { manager.notify(NOTIFICATION_ID, buildNotification(lastLabel, percent)) }
        catch (e: Exception) { android.util.Log.w("BiliMerger", "notify failed", e) }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "视频导出进度",
            NotificationManager.IMPORTANCE_LOW, // LOW:不响铃、不横幅,只在通知栏挂着
        ).apply {
            description = "显示视频导出任务的进度,任务结束后自动消失"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    @Suppress("DEPRECATION")
    private fun buildNotification(label: String, percent: Int): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }

        builder
            .setContentTitle(if (percent >= 0) "正在导出 $percent%" else "正在导出")
            .setContentText(label)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentIntent)

        if (percent >= 0) {
            builder.setProgress(100, percent.coerceIn(0, 100), false)
        } else {
            builder.setProgress(0, 0, true)
        }
        return builder.build()
    }
}
