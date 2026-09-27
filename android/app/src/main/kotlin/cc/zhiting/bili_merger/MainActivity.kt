package cc.zhiting.bili_merger

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.io.File
import java.io.IOException
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val session = ExportSession()
    private var channel: MethodChannel? = null
    private val thumbnailSlots = Semaphore(2)
    private val thumbnailJobs = mutableMapOf<String, Deferred<String?>>()
    private val thumbnailProcesses = mutableSetOf<Process>()
    @Volatile private var destroyed = false

    companion object {
        private const val FONT_ASSET = "assets/fonts/BiliDanmaku.otf"
        private const val FONT_FILE = "BiliDanmaku.otf"
        const val FONT_FAMILY = "BiliDanmaku"
        private const val STALL_TIMEOUT_MS = 10 * 60 * 1000L
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.bili_merger/video").also { ch ->
            ch.setMethodCallHandler { call, result ->
                when (call.method) {
                    "storageInfo" -> {
                        @Suppress("DEPRECATION")
                        val primary = android.os.Environment.getExternalStorageDirectory().absolutePath
                        val roots = (listOf(primary) + getExternalFilesDirs(null).filterNotNull().map {
                            it.absolutePath.substringBefore("/Android/")
                        }).distinct().filter { File(it).isDirectory }
                        result.success(mapOf(
                            "sdk" to android.os.Build.VERSION.SDK_INT,
                            "roots" to roots,
                        ))
                    }
                    "beginSession" -> {
                        try {
                            session.begin()
                            scope.launch {
                                try {
                                    session.checkActive()
                                    BurnService.start(applicationContext, call.argument<String>("label") ?: "正在导出") {
                                        session.cancel()?.let(ProcessRunner::terminate)
                                    }
                                    session.checkActive()
                                    result.success(true)
                                } catch (e: Exception) {
                                    session.finish()?.let(ProcessRunner::terminate)
                                    BurnService.stop(applicationContext)
                                    result.error("SESSION_ERROR", e.message, null)
                                }
                            }
                        } catch (e: Exception) {
                            result.error("BUSY", e.message, null)
                        }
                    }
                    "finishSession" -> {
                        session.finish()?.let(ProcessRunner::terminate)
                        BurnService.stop(applicationContext)
                        result.success(true)
                    }
                    "cancelMerge" -> {
                        // Set the flag before replying or dispatching work; a late coroutine
                        // must never cancel the next batch instead of this one.
                        session.cancel()?.let(ProcessRunner::terminate)
                        BurnService.stop(applicationContext)
                        result.success(true)
                    }
                    "prepareBurn" -> scope.launch {
                        try {
                            result.success(withContext(Dispatchers.IO) { prepareBurnEnv() })
                        } catch (e: Exception) {
                            result.error("PREPARE_ERROR", e.message, null)
                        }
                    }
                    "mergeVideoAudio", "burnDanmaku" -> {
                        val video = call.argument<String>("videoPath")
                        val audio = call.argument<String>("audioPath")
                        val output = call.argument<String>("outputPath")
                        val ass = call.argument<String>("assPath")
                        val burn = call.method == "burnDanmaku"
                        if (video == null || audio == null || output == null || (burn && ass == null)) {
                            result.error("INVALID_ARGUMENT", "Missing required arguments", null)
                        } else {
                            launchExport(result) {
                                if (burn) burnWithFFmpeg(
                                    video, audio, ass!!, output,
                                    (call.argument<Number>("durationMs") ?: 0).toLong(),
                                    (call.argument<Number>("bitrateKbps") ?: 4000).toInt(),
                                    call.argument<String>("label") ?: "正在烧录弹幕",
                                ) else {
                                    mergeWithFFmpeg(video, audio, output)
                                    true
                                }
                            }
                        }
                    }
                    "extractThumbnail" -> {
                        val path = call.argument<String>("videoPath")
                        if (path == null) {
                            result.error("INVALID_ARGUMENT", "Missing videoPath", null)
                        } else scope.launch {
                            val job = thumbnailJobs.getOrPut(path) {
                                scope.async {
                                    thumbnailSlots.withPermit {
                                        withContext(Dispatchers.IO) { extractThumb(path) }
                                    }
                                }
                            }
                            try { result.success(job.await()) }
                            finally { if (thumbnailJobs[path] === job) thumbnailJobs.remove(path) }
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        }
    }

    private fun launchExport(result: MethodChannel.Result, work: () -> Any) {
        try {
            session.acquireExport()
        } catch (e: Exception) {
            result.error("EXPORT_ERROR", e.message, null)
            return
        }
        scope.launch {
            try {
                result.success(withContext(Dispatchers.IO) { work() })
            } catch (e: Exception) {
                result.error("EXPORT_ERROR", e.message, null)
            } finally {
                session.releaseExport()
            }
        }
    }

    private fun ffmpegBuilder(command: List<String>): ProcessBuilder =
        ProcessBuilder(command).redirectErrorStream(true).apply {
            environment()["LD_LIBRARY_PATH"] = applicationInfo.nativeLibraryDir
        }

    private fun ffmpegPath(): String = File(applicationInfo.nativeLibraryDir, "libffmpeg.so").also {
        if (!it.isFile) throw IOException("FFmpeg 可执行文件缺失")
    }.absolutePath

    private fun extractThumb(videoPath: String): String? {
        var process: Process? = null
        var temporary: File? = null
        try {
            val source = File(videoPath)
            if (!source.isFile) return null
            val identity = "${source.canonicalPath}:${source.length()}:${source.lastModified()}"
            val key = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray())
                .joinToString("") { "%02x".format(it) }
            val directory = File(cacheDir, "thumbs").apply { mkdirs() }
            val output = File(directory, "$key.jpg")
            if (output.isFile && output.length() > 0) return output.absolutePath
            temporary = File.createTempFile(".thumb-", ".jpg", directory)
            val builder = ffmpegBuilder(listOf(
                ffmpegPath(), "-nostdin", "-ss", "0", "-i", videoPath,
                "-frames:v", "1", "-vf", "scale=240:-1", "-y", temporary.absolutePath,
            ))
            process = synchronized(thumbnailProcesses) {
                check(!destroyed)
                builder.start().also { thumbnailProcesses.add(it) }
            }
            val run = ProcessRunner.run(process, timeoutMs = 15_000, checkCancelled = { check(!destroyed) })
            if (run.exitCode != 0 || temporary.length() == 0L || !temporary.renameTo(output)) return null
            return output.absolutePath
        } catch (e: Exception) {
            android.util.Log.w("BiliMerger", "Thumbnail unavailable", e)
            return null
        } finally {
            process?.let {
                ProcessRunner.terminate(it)
                synchronized(thumbnailProcesses) { thumbnailProcesses.remove(it) }
            }
            temporary?.delete()
        }
    }

    private fun prepareBurnEnv(): Map<String, String> {
        val fontsDir = File(filesDir, "danmaku_fonts")
        val fontFile = File(fontsDir, FONT_FILE)

        @Suppress("DEPRECATION")
        val versionCode = try {
            packageManager.getPackageInfo(packageName, 0).versionCode.toString()
        } catch (e: Exception) {
            "0"
        }
        val stamp = File(fontsDir, ".v$versionCode")

        if (!fontFile.exists() || fontFile.length() == 0L || !stamp.exists()) {
            fontsDir.deleteRecursively()
            fontsDir.mkdirs()
            val key = io.flutter.FlutterInjector.instance()
                .flutterLoader()
                .getLookupKeyForAsset(FONT_ASSET)
            assets.open(key).use { input ->
                fontFile.outputStream().use { output -> input.copyTo(output) }
            }
            stamp.writeText(versionCode)
            android.util.Log.d("BiliMerger", "Extracted font: ${fontFile.length()} bytes")
        }

        val workDir = File(cacheDir, "danmaku_burn").apply { mkdirs() }
        return mapOf(
            "fontsDir" to fontsDir.absolutePath,
            "workDir" to workDir.absolutePath,
            "fontFamily" to FONT_FAMILY,
        )
    }

    private fun burnWithFFmpeg(
        videoPath: String, audioPath: String, assPath: String, outputPath: String,
        durationMs: Long, bitrateKbps: Int, label: String,
    ): String {
        session.checkActive()
        val ffmpeg = ffmpegPath()
        val fontsDir = prepareBurnEnv().getValue("fontsDir")
        var failure = ""
        PendingOutput(File(outputPath)).use { output ->
            for (hardware in listOf(true, false)) {
                session.checkActive()
                val command = buildBurnCommand(
                    ffmpeg, videoPath, audioPath, assPath, fontsDir,
                    output.file.absolutePath, bitrateKbps.coerceIn(500, 100_000), hardware,
                )
                val run = try {
                    runFFmpeg(command, videoPath, durationMs, label)
                } catch (e: IOException) {
                    failure = e.message ?: "FFmpeg 执行失败"
                    null
                }
                if (run?.exitCode == 0 && output.file.length() > 0) {
                    session.publish(output)
                    return if (hardware) "h264_mediacodec" else "libx264"
                }
                if (run != null) failure = run.tail
                session.checkActive()
            }
        }
        throw IOException("烧录失败: $failure")
    }

    private fun mergeWithFFmpeg(videoPath: String, audioPath: String, outputPath: String) {
        session.checkActive()
        PendingOutput(File(outputPath)).use { output ->
            val command = listOf(
                ffmpegPath(), "-nostdin", "-hide_banner", "-nostats", "-progress", "pipe:1",
                "-i", videoPath, "-i", audioPath,
                "-map", "0:v:0", "-map", "1:a:0", "-c", "copy", "-y", output.file.absolutePath,
            )
            val run = runFFmpeg(command, videoPath, 0, File(outputPath).name)
            if (run.exitCode != 0) throw IOException("合并失败: ${run.tail}")
            session.publish(output)
        }
    }

    private fun runFFmpeg(
        command: List<String>, videoPath: String, durationMs: Long, label: String,
    ): ProcessRunner.Result {
        val process = session.startProcess { ffmpegBuilder(command).start() }
        var totalUs = if (durationMs in 1..Long.MAX_VALUE / 1000) durationMs * 1000 else 0
        var lastPushAt = 0L
        var lastPercent = -1
        try {
            return ProcessRunner.run(process, stallMs = STALL_TIMEOUT_MS, checkCancelled = session::checkActive) { line ->
                if (totalUs <= 0 && line.contains("Duration:")) totalUs = parseDurationUs(line)
                val us = parseProgressUs(line)
                if (us >= 0 && totalUs > 0) {
                    val progress = (us.toDouble() / totalUs).coerceIn(0.0, 0.999)
                    val percent = (progress * 100).toInt()
                    val now = System.nanoTime() / 1_000_000
                    if (percent != lastPercent && now - lastPushAt >= 400) {
                        lastPercent = percent
                        lastPushAt = now
                        scope.launch {
                            channel?.invokeMethod("burnProgress", mapOf("videoPath" to videoPath, "progress" to progress))
                            BurnService.update(label, percent)
                        }
                    }
                }
            }
        } finally {
            session.releaseProcess(process)
        }
    }

    private fun buildBurnCommand(
        ffmpeg: String,
        videoPath: String,
        audioPath: String,
        assPath: String,
        fontsDir: String,
        outputPath: String,
        bitrateKbps: Int,
        hardware: Boolean,
    ): List<String> {
        val vf = "ass=filename=${escapeFilterValue(assPath)}:fontsdir=${escapeFilterValue(fontsDir)}"
        val cmd = mutableListOf(
            ffmpeg,
            "-nostdin",
            "-hide_banner",
            "-nostats",
            // -progress 走 stdout,输出的是 key=value,比解析 "time=00:00:12.34" 稳得多。
            "-progress", "pipe:1",
            "-i", videoPath,
            "-i", audioPath,
            // 原来的合并命令没有 -map,这里显式指定,避免多轨输入选错流。
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-vf", vf,
        )
        if (hardware) {
            cmd += listOf(
                "-c:v", "h264_mediacodec",
                "-b:v", "${bitrateKbps}k",
                // MediaCodec 没有 CRF。默认的 VBR 模式在满屏弹幕这种高频内容上会把码率冲到
                // 目标值的 1.6 倍以上,文件大得离谱;CBR(2)实测能把码率咬在目标附近。
                "-bitrate_mode", "2",
                // 不设 gop_size 时 MediaCodec 默认每秒一个 I 帧,同样的画质要多花一倍以上码率。
                "-g", "150",
            )
        } else {
            cmd += listOf(
                "-c:v", "libx264",
                "-preset", "veryfast",
                "-crf", "23",
                "-pix_fmt", "yuv420p",
                "-g", "150",
            )
        }
        cmd += listOf(
            "-c:a", "copy",
            // moov 前置,手机播放器和分享出去的文件都能立刻起播。
            "-movflags", "+faststart",
            "-y",
            outputPath,
        )
        return cmd
    }

    /** filtergraph 参数里的这几个字符会被当成分隔符,必须转义。App 私有路径通常不含它们,防御性处理。 */
    private fun escapeFilterValue(value: String): String =
        value.replace("\\", "\\\\").replace(":", "\\:").replace("'", "\\'")

    /** -progress 的时间字段。7.x 只有 out_time_ms(实为微秒),8.x 两个都给,取任一即可。 */
    private fun parseProgressUs(line: String): Long {
        val key = when {
            line.startsWith("out_time_us=") -> 12
            line.startsWith("out_time_ms=") -> 12
            else -> return -1
        }
        return line.substring(key).trim().toLongOrNull() ?: -1
    }

    /** 解析 "  Duration: 00:19:05.53, start: ..." 里的时长,返回微秒。 */
    private fun parseDurationUs(line: String): Long {
        val m = Regex("Duration: (\\d+):(\\d{2}):(\\d{2})\\.(\\d{2})").find(line) ?: return 0
        val (h, mm, s, cs) = m.destructured
        return ((h.toLong() * 3600 + mm.toLong() * 60 + s.toLong()) * 100 + cs.toLong()) * 10_000
    }

    override fun onDestroy() {
        destroyed = true
        session.finish()?.let(ProcessRunner::terminate)
        synchronized(thumbnailProcesses) { thumbnailProcesses.forEach(ProcessRunner::terminate) }
        BurnService.stop(applicationContext)
        channel?.setMethodCallHandler(null)
        channel = null
        scope.cancel()
        super.onDestroy()
    }
}
