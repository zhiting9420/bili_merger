package cc.zhiting.bili_merger

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.bili_merger/video"
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // 进度要从 IO 线程回推到 Dart,所以得留住 channel 的引用。
    private var channel: MethodChannel? = null

    // FFmpeg 是通过 ProcessBuilder 拉起的独立子进程。App 被划掉后台时,系统未必
    // 会连带回收它,残留的进程会继续吃 CPU 并往输出目录写半截文件。这里持有引用,
    // 在 onDestroy 里主动结束。@Volatile 是因为赋值发生在 IO 线程、读取在主线程。
    @Volatile
    private var currentProcess: Process? = null

    // 用户主动中断(划掉后台)时置位,避免把中断当成合并失败弹错误。
    @Volatile
    private var cancelled = false

    companion object {
        /**
         * 随 APK 打包的中文字体。
         *
         * 这份 ffmpeg 是 `--disable-libfontconfig` 编译的,libass 拿不到任何系统字体,
         * 只会打印 "fontconfig is not available, ignoring font option." 然后把每个汉字
         * 渲染成方框。唯一的解法就是把字体释放到一个可读目录,再用 ass 滤镜的
         * `fontsdir=` 指过去 —— 此时 libass 走 directory provider,按**家族名精确匹配**。
         * 所以 [FONT_FAMILY] 必须和 BiliDanmaku.otf 内部 name ID 1 完全一致,写错等于没做。
         */
        private const val FONT_ASSET = "assets/fonts/BiliDanmaku.otf"
        private const val FONT_FILE = "BiliDanmaku.otf"
        const val FONT_FAMILY = "BiliDanmaku"

        /** 单个 ffmpeg 进程多久没有任何输出就判定为卡死。烧录本身可以跑很久,不能按总时长设上限。 */
        private const val STALL_TIMEOUT_MS = 10 * 60 * 1000L
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "mergeVideoAudio" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val audioPath = call.argument<String>("audioPath")
                    val outputPath = call.argument<String>("outputPath")

                    if (videoPath != null && audioPath != null && outputPath != null) {
                        scope.launch {
                            try {
                                withContext(Dispatchers.IO) {
                                    mergeWithFFmpeg(videoPath, audioPath, outputPath)
                                }
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("MERGE_ERROR", e.message, null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Missing required arguments", null)
                    }
                }

                // 烧录前准备:释放字体、给出可写的工作目录。Dart 侧据此写 .ass。
                "prepareBurn" -> {
                    scope.launch {
                        try {
                            val env = withContext(Dispatchers.IO) { prepareBurnEnv() }
                            result.success(env)
                        } catch (e: Exception) {
                            result.error("PREPARE_ERROR", e.message, null)
                        }
                    }
                }

                "burnDanmaku" -> {
                    val videoPath = call.argument<String>("videoPath")
                    val audioPath = call.argument<String>("audioPath")
                    val assPath = call.argument<String>("assPath")
                    val outputPath = call.argument<String>("outputPath")
                    val durationMs = (call.argument<Number>("durationMs") ?: 0).toLong()
                    val bitrateKbps = (call.argument<Number>("bitrateKbps") ?: 4000).toInt()
                    val label = call.argument<String>("label") ?: ""

                    if (videoPath != null && audioPath != null && assPath != null && outputPath != null) {
                        scope.launch {
                            BurnService.start(applicationContext, label)
                            try {
                                val encoder = withContext(Dispatchers.IO) {
                                    burnWithFFmpeg(
                                        videoPath, audioPath, assPath, outputPath,
                                        durationMs, bitrateKbps, label,
                                    )
                                }
                                result.success(encoder)
                            } catch (e: Exception) {
                                result.error("BURN_ERROR", e.message, null)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Missing required arguments", null)
                    }
                }

                // 整批烧录结束,撤掉前台服务与通知。
                "finishBurnSession" -> {
                    BurnService.stop(applicationContext)
                    result.success(true)
                }

                "cancelMerge" -> {
                    // 用户点了「中断导出」:结束当前 ffmpeg 子进程。
                    // 后续条目由 Dart 侧看到取消标记后不再发起。
                    scope.launch {
                        withContext(Dispatchers.IO) { stopFFmpeg() }
                        BurnService.stop(applicationContext)
                        result.success(true)
                    }
                }

                "extractThumbnail" -> {
                    val videoPath = call.argument<String>("videoPath")
                    if (videoPath != null) {
                        scope.launch {
                            val path = withContext(Dispatchers.IO) { extractThumb(videoPath) }
                            result.success(path)
                        }
                    } else {
                        result.error("INVALID_ARGUMENT", "Missing videoPath", null)
                    }
                }

                else -> result.notImplemented()
            }
        }
    }

    // 用内置 ffmpeg 抽取一帧作为缩略图,缓存在 cacheDir/thumbs 下,返回路径(失败返回 null)
    private fun extractThumb(videoPath: String): String? {
        try {
            val thumbsDir = File(cacheDir, "thumbs").apply { mkdirs() }
            val key = videoPath.hashCode().toString().replace("-", "n")
            val out = File(thumbsDir, "$key.jpg")
            if (out.exists() && out.length() > 0) return out.absolutePath

            val nativeLibDir = applicationInfo.nativeLibraryDir
            val ffmpegFile = File(nativeLibDir, "libffmpeg.so")
            if (!ffmpegFile.exists() || !File(videoPath).exists()) return null

            val pb = ProcessBuilder(
                ffmpegFile.absolutePath,
                "-ss", "1",
                "-i", videoPath,
                "-frames:v", "1",
                "-vf", "scale=240:-1",
                "-y",
                out.absolutePath
            )
            pb.environment()["LD_LIBRARY_PATH"] = nativeLibDir
            pb.redirectErrorStream(true)
            val process = pb.start()
            process.inputStream.bufferedReader().forEachLine { }
            val finished = process.waitFor(15, java.util.concurrent.TimeUnit.SECONDS)
            if (!finished) {
                process.destroy()
                return null
            }
            return if (out.exists() && out.length() > 0) out.absolutePath else null
        } catch (e: Exception) {
            android.util.Log.e("BiliMerger", "extractThumb failed", e)
            return null
        }
    }

    // ------------------------------------------------------------------ 弹幕烧录

    /**
     * 把打包的字体释放到私有目录并返回烧录所需的三个路径。
     *
     * fontsDir 里**只能**放这一个字体文件:libass 会把整个目录扫一遍,多放东西纯属浪费启动时间。
     * 用 versionCode 做标记,应用升级后自动重新释放,避免旧字体残留。
     */
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

    /**
     * 把 .ass 烧进画面。优先硬件编码(h264_mediacodec),失败自动回退 libx264 重跑一次。
     * 返回实际使用的编码器名,供 Dart 侧写日志。
     */
    private fun burnWithFFmpeg(
        videoPath: String,
        audioPath: String,
        assPath: String,
        outputPath: String,
        durationMs: Long,
        bitrateKbps: Int,
        label: String,
    ): String {
        // 这里不再复位 cancelled。中断可能发生在 Dart 侧转换弹幕(大文件要数秒)
        // 的窗口内,那时还没有子进程可杀,只置了标记;若在此处复位,这一项会
        // 照常烧完,而前台服务已被停掉,后台还会被系统冻结。
        // 复位统一交给 startBurnSession(一批任务开始时调用一次)。
        if (cancelled) throw Exception("已取消")

        val nativeLibDir = applicationInfo.nativeLibraryDir
        val ffmpegFile = File(nativeLibDir, "libffmpeg.so")
        if (!ffmpegFile.exists()) throw Exception("FFmpeg 可执行文件缺失: ${ffmpegFile.absolutePath}")
        if (!File(videoPath).exists()) throw Exception("视频文件不存在: $videoPath")
        if (!File(audioPath).exists()) throw Exception("音频文件不存在: $audioPath")
        if (!File(assPath).exists()) throw Exception("弹幕文件未生成: $assPath")

        val fontsDir = prepareBurnEnv()["fontsDir"]!!

        var lastOutput = ""
        // true = 硬件编码,false = 软件回退。顺序不能反。
        for (hardware in listOf(true, false)) {
            if (cancelled) break

            val cmd = buildBurnCommand(
                ffmpegFile.absolutePath, videoPath, audioPath, assPath,
                fontsDir, outputPath, bitrateKbps, hardware,
            )
            android.util.Log.d("BiliMerger", "Burn (${if (hardware) "hw" else "sw"}): ${cmd.joinToString(" ")}")

            val run = runFFmpeg(cmd, nativeLibDir, videoPath, durationMs, label)
            lastOutput = run.tail

            if (run.exitCode == 0 && File(outputPath).exists() && File(outputPath).length() > 0) {
                return if (hardware) "h264_mediacodec" else "libx264"
            }

            // 无论失败还是中断,半成品都不能留。
            File(outputPath).takeIf { it.exists() }?.delete()

            if (cancelled) throw Exception("已取消")
            android.util.Log.w(
                "BiliMerger",
                "Burn with ${if (hardware) "h264_mediacodec" else "libx264"} failed (exit ${run.exitCode})",
            )
        }

        if (cancelled) throw Exception("已取消")
        throw Exception("烧录失败: $lastOutput")
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

    private class RunResult(val exitCode: Int, val tail: String)

    /**
     * 跑一次 ffmpeg,边跑边解析 -progress 输出并把百分比回推给 Dart / 通知栏。
     * 不设总时长上限 —— 烧录一部两小时的片子本来就要一小时以上;改用「多久没输出算卡死」。
     */
    private fun runFFmpeg(
        cmd: List<String>,
        nativeLibDir: String,
        videoPath: String,
        durationMsHint: Long,
        label: String,
    ): RunResult {
        val pb = ProcessBuilder(cmd)
        pb.environment()["LD_LIBRARY_PATH"] = nativeLibDir
        pb.redirectErrorStream(true)

        val process = pb.start()
        currentProcess = process

        val tail = ArrayDeque<String>()
        // 局部变量不能用 @Volatile,而这个值要在 reader 线程里读写,所以用 AtomicLong。
        val totalUs = java.util.concurrent.atomic.AtomicLong(
            if (durationMsHint > 0) durationMsHint * 1000 else 0L,
        )
        val lastOutputAt = java.util.concurrent.atomic.AtomicLong(System.currentTimeMillis())
        val lastPushAt = java.util.concurrent.atomic.AtomicLong(0L)
        val lastPercent = java.util.concurrent.atomic.AtomicInteger(-1)

        val reader = Thread {
            try {
                process.inputStream.bufferedReader().forEachLine { line ->
                    lastOutputAt.set(System.currentTimeMillis())

                    // 输入时长兜底:entry.json 缺 total_time_milli 时从 ffmpeg 自己的报头里取。
                    if (totalUs.get() <= 0 && line.contains("Duration:")) {
                        totalUs.set(parseDurationUs(line))
                    }

                    val us = parseProgressUs(line)
                    val total = totalUs.get()
                    if (us >= 0 && total > 0) {
                        val p = (us.toDouble() / total).coerceIn(0.0, 0.999)
                        val percent = (p * 100).toInt()
                        val now = System.currentTimeMillis()
                        // 限流:百分比没变就别推,变了也至少隔 400ms,免得刷爆 platform channel。
                        if (percent != lastPercent.get() && now - lastPushAt.get() > 400) {
                            lastPercent.set(percent)
                            lastPushAt.set(now)
                            reportProgress(videoPath, p)
                            BurnService.update(label, percent)
                        }
                    } else if (!line.startsWith("frame=") && !line.contains("=")) {
                        android.util.Log.d("BiliMerger", "FFmpeg: $line")
                    }

                    if (!line.contains('=') || line.startsWith("[")) {
                        tail.addLast(line)
                        while (tail.size > 40) tail.removeFirst()
                    }
                }
            } catch (e: Exception) {
                android.util.Log.e("BiliMerger", "Error reading FFmpeg output", e)
            }
        }
        reader.start()

        while (true) {
            if (process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) break
            if (cancelled) {
                // stopFFmpeg 已经 destroyForcibly 过了,这里只是兜底防止死等。
                process.destroyForcibly()
                process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                break
            }
            if (System.currentTimeMillis() - lastOutputAt.get() > STALL_TIMEOUT_MS) {
                android.util.Log.e("BiliMerger", "FFmpeg stalled, killing")
                process.destroyForcibly()
                process.waitFor(5, java.util.concurrent.TimeUnit.SECONDS)
                reader.join(1000)
                currentProcess = null
                return RunResult(-1, "ffmpeg 超过 10 分钟没有任何输出,已判定为卡死")
            }
        }

        reader.join(2000)
        currentProcess = null

        val exitCode = try { process.exitValue() } catch (e: Exception) { -1 }
        android.util.Log.d("BiliMerger", "FFmpeg exit code: $exitCode")
        // join 有 2 秒上限,极端情况下 reader 可能还在往 tail 里写。诊断信息不值得为此崩掉整个烧录。
        val tailText = try {
            tail.joinToString("\n")
        } catch (e: Exception) {
            "(无法读取 ffmpeg 输出)"
        }
        return RunResult(exitCode, tailText)
    }

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

    private fun reportProgress(videoPath: String, progress: Double) {
        scope.launch(Dispatchers.Main) {
            try {
                channel?.invokeMethod(
                    "burnProgress",
                    mapOf("videoPath" to videoPath, "progress" to progress),
                )
            } catch (e: Exception) {
                android.util.Log.w("BiliMerger", "reportProgress failed", e)
            }
        }
    }

    // ------------------------------------------------------------------ 快速合并

    private fun mergeWithFFmpeg(videoPath: String, audioPath: String, outputPath: String) {
        // 复位交给 beginSession;这里只做检查,避免吞掉两项之间发出的中断。
        if (cancelled) throw Exception("已取消")
        android.util.Log.d("BiliMerger", "Starting FFmpeg merge")
        android.util.Log.d("BiliMerger", "Video: $videoPath")
        android.util.Log.d("BiliMerger", "Audio: $audioPath")
        android.util.Log.d("BiliMerger", "Output: $outputPath")

        // Log device architecture
        val abi = android.os.Build.SUPPORTED_ABIS.joinToString(", ")
        android.util.Log.d("BiliMerger", "Device ABIs: $abi")

        // Use FFmpeg from native library directory
        val nativeLibDir = applicationInfo.nativeLibraryDir
        val ffmpegFile = File(nativeLibDir, "libffmpeg.so")
        android.util.Log.d("BiliMerger", "FFmpeg path: ${ffmpegFile.absolutePath}")

        // List native libraries for debugging
        val libs = File(nativeLibDir).listFiles()?.joinToString { it.name } ?: "none"
        android.util.Log.d("BiliMerger", "Native libraries available: $libs")

        if (!ffmpegFile.exists()) {
            throw Exception("FFmpeg library not found in native lib directory: ${ffmpegFile.absolutePath}")
        }

        // Build process with LD_LIBRARY_PATH
        val pb = ProcessBuilder()
        val env = pb.environment()
        env["LD_LIBRARY_PATH"] = nativeLibDir
        android.util.Log.d("BiliMerger", "Set LD_LIBRARY_PATH to $nativeLibDir")

        // Test FFmpeg binary
        try {
            android.util.Log.d("BiliMerger", "Testing FFmpeg binary...")
            pb.command(ffmpegFile.absolutePath, "-version")
            pb.redirectErrorStream(true)
            val testProcess = pb.start()

            val testOutput = testProcess.inputStream.bufferedReader().readText()
            val testExitCode = testProcess.waitFor()

            android.util.Log.d("BiliMerger", "FFmpeg test exit code: $testExitCode")
            android.util.Log.d("BiliMerger", "FFmpeg version output: $testOutput")

            if (testExitCode != 0 || testOutput.isEmpty()) {
                throw Exception("FFmpeg binary test failed. Output: $testOutput")
            }
        } catch (e: Exception) {
            android.util.Log.e("BiliMerger", "FFmpeg binary test failed", e)
            throw Exception("FFmpeg binary is not compatible or missing dependencies. Architecture: $abi. Error: ${e.message}")
        }

        // Verify input files exist
        if (!File(videoPath).exists()) {
            throw Exception("Video file not found: $videoPath")
        }
        if (!File(audioPath).exists()) {
            throw Exception("Audio file not found: $audioPath")
        }

        // Build FFmpeg command: -i video -i audio -c copy output
        pb.command(
            ffmpegFile.absolutePath,
            "-i", videoPath,
            "-i", audioPath,
            // 明确指定取哪条流。不写 -map 时由 ffmpeg 自行挑选,
            // 若某个 m4s 里混有封面图之类的附加流就可能选错。
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c", "copy",
            "-y",
            outputPath
        )

        android.util.Log.d("BiliMerger", "Executing: ${pb.command().joinToString(" ")}")

        // Execute FFmpeg with proper async I/O handling
        pb.redirectErrorStream(true)
        val process = pb.start()
        currentProcess = process

        // Read output asynchronously to prevent blocking
        val outputBuilder = StringBuilder()
        val reader = process.inputStream.bufferedReader()

        // Start a thread to read output
        val readerThread = Thread {
            try {
                reader.forEachLine { line ->
                    outputBuilder.appendLine(line)
                    android.util.Log.d("BiliMerger", "FFmpeg: $line")
                }
            } catch (e: Exception) {
                android.util.Log.e("BiliMerger", "Error reading FFmpeg output", e)
            }
        }
        readerThread.start()

        // Wait for process with a generous timeout. Merge is a stream-copy remux (-c copy),
        // so it is bounded by disk I/O; 30 min covers even very large files while still
        // guarding against a stuck process hanging forever.
        val finished = process.waitFor(30, java.util.concurrent.TimeUnit.MINUTES)

        if (!finished) {
            process.destroy()
            throw Exception("FFmpeg timeout after 30 minutes")
        }

        readerThread.join(1000) // Wait for reader thread to finish
        currentProcess = null

        val exitCode = process.exitValue()
        val output = outputBuilder.toString()

        android.util.Log.d("BiliMerger", "FFmpeg exit code: $exitCode")

        if (cancelled) {
            // 被用户中断,删掉写了一半的输出,避免留下损坏的 mp4。
            File(outputPath).takeIf { it.exists() }?.delete()
            throw Exception("已取消")
        }

        if (exitCode != 0) {
            throw Exception("FFmpeg failed with exit code $exitCode: $output")
        }

        // Verify output file was created
        if (!File(outputPath).exists()) {
            throw Exception("Output file was not created: $outputPath")
        }

        android.util.Log.d("BiliMerger", "Merge completed successfully")
    }

    /// 划掉后台 / 退出应用时,连同 FFmpeg 子进程一起结束。
    private fun stopFFmpeg() {
        cancelled = true
        currentProcess?.let { p ->
            try {
                if (p.isAlive) {
                    android.util.Log.d("BiliMerger", "Destroying FFmpeg process")
                    p.destroyForcibly()
                    // 给它一点时间落地,避免文件句柄还没释放就返回。
                    p.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)
                }
            } catch (e: Exception) {
                android.util.Log.e("BiliMerger", "stopFFmpeg failed", e)
            }
        }
        currentProcess = null
    }

    override fun onDestroy() {
        stopFFmpeg()
        // 划掉任务卡片是明确的「不要了」,前台服务不该继续挂在通知栏。
        BurnService.stop(applicationContext)
        channel = null
        scope.cancel()
        super.onDestroy()
    }
}
