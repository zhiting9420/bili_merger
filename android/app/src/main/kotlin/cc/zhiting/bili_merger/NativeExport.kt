package cc.zhiting.bili_merger

import java.io.Closeable
import java.io.File
import java.io.IOException
import java.util.concurrent.atomic.AtomicLong

/** One batch owns the exporter; cancellation and child registration share the same lock. */
internal class ExportSession {
    private var active = false
    private var exporting = false
    private var cancelled = false
    private var process: Process? = null

    @Synchronized fun begin() {
        check(!active && !exporting && process == null) { "已有导出任务正在运行" }
        active = true
        cancelled = false
    }

    @Synchronized fun checkActive() {
        check(active && !cancelled) { "导出已取消或尚未开始" }
    }

    @Synchronized fun acquireExport() {
        checkActive()
        check(!exporting) { "已有导出任务正在运行" }
        exporting = true
    }

    @Synchronized fun releaseExport() { exporting = false }

    @Synchronized fun startProcess(start: () -> Process): Process {
        checkActive()
        check(process == null) { "已有 FFmpeg 进程正在运行" }
        return start().also { process = it }
    }

    @Synchronized fun releaseProcess(finished: Process) {
        if (process === finished) process = null
    }

    @Synchronized fun cancel(): Process? {
        cancelled = true
        return process
    }

    @Synchronized fun finish(): Process? {
        active = false
        return cancel()
    }

    @Synchronized fun publish(output: PendingOutput) {
        checkActive()
        output.publish()
    }
}

/** Write beside the destination, reserve its name without replacement, then rename. */
internal class PendingOutput(private val destination: File) : Closeable {
    val file: File

    init {
        if (destination.exists()) throw IOException("输出文件已存在: ${destination.name}")
        val parent = destination.absoluteFile.parentFile
        if (parent == null || !parent.isDirectory) throw IOException("输出目录不存在")
        file = File.createTempFile(".bili-", ".mp4", parent)
    }

    fun publish() {
        if (!file.isFile || file.length() == 0L) throw IOException("FFmpeg 未生成有效输出")
        // createNewFile is atomic, unlike an exists() check followed by renameTo().
        if (!destination.createNewFile()) throw IOException("输出文件已存在: ${destination.name}")
        if (!file.renameTo(destination)) {
            destination.delete()
            throw IOException("无法保存输出文件: ${destination.name}")
        }
    }

    override fun close() { file.delete() }
}

/** API 24 compatible process handling, shared by exports and thumbnails. */
internal object ProcessRunner {
    data class Result(val exitCode: Int, val tail: String)

    fun exitCode(process: Process): Int? = try {
        process.exitValue()
    } catch (_: IllegalThreadStateException) { null }

    fun terminate(process: Process) {
        if (exitCode(process) != null) return
        // Android 24/25's destroy() kills the native child. Newer runtimes expose
        // destroyForcibly; reflect it to avoid linking API 26 methods on API 24.
        try {
            Process::class.java.getMethod("destroyForcibly").invoke(process)
        } catch (_: ReflectiveOperationException) {
            process.destroy()
        }
    }

    fun run(
        process: Process,
        timeoutMs: Long = Long.MAX_VALUE,
        stallMs: Long = Long.MAX_VALUE,
        checkCancelled: () -> Unit = {},
        onLine: (String) -> Unit = {},
    ): Result {
        val started = System.nanoTime()
        val lastOutput = AtomicLong(started)
        val tail = java.util.ArrayDeque<String>()
        val reader = Thread {
            try {
                process.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        lastOutput.set(System.nanoTime())
                        synchronized(tail) {
                            tail.addLast(line.take(2000))
                            while (tail.size > 40) tail.removeFirst()
                        }
                        onLine(line)
                    }
                }
            } catch (_: IOException) {
                // Killing a child or closing its pipe during cleanup ends the reader.
            }
        }.apply { isDaemon = true }
        try {
            process.outputStream.close()
            reader.start()
            while (true) {
                checkCancelled()
                val exit = exitCode(process)
                if (exit != null) {
                    reader.join(1000)
                    return Result(exit, synchronized(tail) { tail.joinToString("\n") })
                }
                val now = System.nanoTime()
                if ((now - started) / 1_000_000 >= timeoutMs) throw IOException("FFmpeg 执行超时")
                if ((now - lastOutput.get()) / 1_000_000 >= stallMs) throw IOException("FFmpeg 长时间没有输出")
                Thread.sleep(50)
            }
        } finally {
            terminate(process)
            val deadline = System.nanoTime() + 1_000_000_000
            while (exitCode(process) == null && System.nanoTime() < deadline) Thread.sleep(10)
            runCatching { process.inputStream.close() }
            runCatching { process.errorStream.close() }
            runCatching { process.outputStream.close() }
            reader.join(500)
        }
    }
}
