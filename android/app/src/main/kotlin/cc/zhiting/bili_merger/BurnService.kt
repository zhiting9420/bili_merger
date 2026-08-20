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

/**
 * 弹幕烧录期间的前台服务。
 *
 * 为什么非要有它:烧录是分钟级甚至小时级的任务,而 Android 12 之后进入 cached 状态的
 * 应用会被 App Freezer 直接 SIGSTOP。ffmpeg 是本进程 fork 出来的子进程,和宿主同属
 * 一个 cgroup,宿主被冻住它也跟着停,表现就是「切出去一会儿回来进度条没动」。
 * 前台服务把进程钉在 foreground 档位,既躲开冻结,也大幅降低被 LMK 回收的概率。
 *
 * 注意它只负责「持有前台身份 + 显示进度」,不承载任何转码逻辑 —— ffmpeg 仍由
 * MainActivity 拉起。这样做是因为两者本来就在同一个进程里,不需要跨进程通信。
 * 用户主动划掉任务卡片时 MainActivity.onDestroy 仍会结束 ffmpeg 并停掉本服务:
 * 划掉后台是明确的「我不要了」,不该偷偷继续跑。
 */
class BurnService : Service() {

    companion object {
        private const val CHANNEL_ID = "danmaku_burn"
        private const val NOTIFICATION_ID = 0x62726E
        private const val EXTRA_LABEL = "label"

        @Volatile
        private var instance: BurnService? = null

        val isRunning: Boolean get() = instance != null

        /** 开始烧录时调用;已在运行则只刷新文案。 */
        fun start(context: Context, label: String) {
            val running = instance
            if (running != null) {
                running.publish(label, -1)
                return
            }
            val intent = Intent(context, BurnService::class.java).putExtra(EXTRA_LABEL, label)
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // Android 12+ 在应用不可见时禁止启动前台服务,会抛
                // ForegroundServiceStartNotAllowedException。批量任务里第一项走了
                // 快速合并、用户切走后第二项才需要烧录,就会走到这里。
                // 没有通知栏进度不影响烧录本身,不能让它把进程带崩。
                android.util.Log.w("BiliMerger", "startForegroundService rejected", e)
            }
        }

        /** 刷新通知栏进度。[percent] 为 -1 表示不确定进度。 */
        fun update(label: String, percent: Int) {
            instance?.publish(label, percent)
        }

        fun stop(context: Context) {
            // 不能用 instance == null 提前返回:startForegroundService 是异步的,
            // onCreate 可能还没跑到就已经要停(比如第一项就因文件缺失立刻失败),
            // 那样 service 随后启动却再也收不到 stop,通知栏会永久挂着。
            // stopService 对未运行的服务本就是无害的 no-op。
            try {
                context.stopService(Intent(context, BurnService::class.java))
            } catch (e: Exception) {
                android.util.Log.w("BiliMerger", "stopService failed", e)
            }
        }
    }

    private var lastLabel: String = ""

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        lastLabel = intent?.getStringExtra(EXTRA_LABEL) ?: lastLabel
        startInForeground(buildNotification(lastLabel, -1))
        // 不要 START_STICKY:进程真被杀掉之后 ffmpeg 也已经没了,重建一个空服务毫无意义。
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    fun publish(label: String, percent: Int) {
        if (label.isNotEmpty()) lastLabel = label
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        try {
            nm.notify(NOTIFICATION_ID, buildNotification(lastLabel, percent))
        } catch (e: Exception) {
            android.util.Log.w("BiliMerger", "notify failed", e)
        }
    }

    private fun startInForeground(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // Android 14+ 在极端情况下会拒绝前台服务(例如已被限制的后台启动)。
            // 这不该让烧录本身失败 —— 退化成普通服务继续跑。
            android.util.Log.w("BiliMerger", "startForeground failed", e)
        }
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "弹幕烧录进度",
            NotificationManager.IMPORTANCE_LOW, // LOW:不响铃、不横幅,只在通知栏挂着
        ).apply {
            description = "显示弹幕烧录任务的进度,任务结束后自动消失"
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
            .setContentTitle(if (percent >= 0) "正在烧录弹幕 $percent%" else "正在烧录弹幕")
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
