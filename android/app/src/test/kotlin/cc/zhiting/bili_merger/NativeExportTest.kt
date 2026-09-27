package cc.zhiting.bili_merger

import org.junit.Assert.*
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

class NativeExportTest {
    @Test fun cancelledSessionCanBeginAgainAfterFinishing() {
        val session = ExportSession()
        session.begin()
        session.cancel()
        assertThrows(IllegalStateException::class.java) { session.checkActive() }
        session.finish()
        session.begin()
        session.checkActive()
    }

    @Test fun busySessionRejectsAnotherBegin() {
        val session = ExportSession()
        session.begin()
        assertThrows(IllegalStateException::class.java) { session.begin() }
        session.acquireExport()
        session.finish()
        assertThrows(IllegalStateException::class.java) { session.begin() }
        session.releaseExport()
        session.begin()
    }

    @Test fun cancellationDuringLaunchCapturesTheNewProcess() {
        val session = ExportSession()
        session.begin()
        val launching = CountDownLatch(1)
        val continueLaunch = CountDownLatch(1)
        var process: Process? = null
        val starter = thread {
            process = session.startProcess {
                launching.countDown()
                assertTrue(continueLaunch.await(2, TimeUnit.SECONDS))
                ProcessBuilder("sh", "-c", "exec sleep 10").start()
            }
        }
        assertTrue(launching.await(2, TimeUnit.SECONDS))
        val canceller = thread { session.cancel()?.let(ProcessRunner::terminate) }
        continueLaunch.countDown()
        starter.join(2000)
        canceller.join(2000)
        assertNotNull(process)
        assertTrue(process!!.waitFor(2, TimeUnit.SECONDS))
        assertThrows(IllegalStateException::class.java) { session.startProcess { error("must not launch") } }
    }

    @Test fun processTimeoutDoesNotWaitForOutputEof() {
        val process = ProcessBuilder("sh", "-c", "exec sleep 10").start()
        val start = System.nanoTime()
        assertThrows(java.io.IOException::class.java) {
            ProcessRunner.run(process, timeoutMs = 150)
        }
        assertTrue((System.nanoTime() - start) / 1_000_000 < 3000)
        assertNotNull(ProcessRunner.exitCode(process))
    }

    @Test fun outputReaderIsDrainedAndDiagnosticsAreBounded() {
        val process = ProcessBuilder("sh", "-c", "i=0; while [ \"\$i\" -lt 3000 ]; do echo diagnostic-\$i; i=\$((i+1)); done").start()
        val result = ProcessRunner.run(process, timeoutMs = 3000)
        assertEquals(0, result.exitCode)
        assertTrue(result.tail.contains("diagnostic-2999"))
        assertTrue(result.tail.lines().size <= 40)
    }

    @Test fun failedExportKeepsExistingFile() = withDirectory { directory ->
        val output = File(directory, "video.mp4").apply { writeText("original") }
        assertThrows(java.io.IOException::class.java) { PendingOutput(output) }
        assertEquals("original", output.readText())
        assertEquals(1, directory.list()!!.size)
    }

    @Test fun failureRemovesOnlyItsTemporaryOutput() = withDirectory { directory ->
        val output = File(directory, "video.mp4")
        val pending = PendingOutput(output)
        pending.file.writeText("partial")
        pending.close()
        assertFalse(output.exists())
        assertTrue(directory.list()!!.isEmpty())
    }

    @Test fun publishingNeverOverwritesFileCreatedDuringExport() = withDirectory { directory ->
        val output = File(directory, "video.mp4")
        PendingOutput(output).use { pending ->
            pending.file.writeText("new")
            output.writeText("other export")
            assertThrows(java.io.IOException::class.java) { pending.publish() }
        }
        assertEquals("other export", output.readText())
        assertEquals(1, directory.list()!!.size)
    }

    @Test fun successfulExportPublishesAndRemovesTemporaryFile() = withDirectory { directory ->
        val output = File(directory, "video.mp4")
        PendingOutput(output).use { pending ->
            pending.file.writeText("complete")
            pending.publish()
        }
        assertEquals("complete", output.readText())
        assertEquals(1, directory.list()!!.size)
    }

    @Test fun cancellationAfterEncodingPreventsPublishing() = withDirectory { directory ->
        val session = ExportSession()
        session.begin()
        val output = File(directory, "video.mp4")
        PendingOutput(output).use { pending ->
            pending.file.writeText("encoded")
            session.cancel()
            assertThrows(IllegalStateException::class.java) { session.publish(pending) }
        }
        assertFalse(output.exists())
        assertTrue(directory.list()!!.isEmpty())
    }

    private fun withDirectory(block: (File) -> Unit) {
        val directory = Files.createTempDirectory("bili-export-test").toFile()
        try { block(directory) } finally { directory.deleteRecursively() }
    }
}
