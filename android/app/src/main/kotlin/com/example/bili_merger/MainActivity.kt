package com.example.bili_merger

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.*
import java.io.File
import java.io.BufferedReader

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.bili_merger/video"
    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "mergeVideoAudio") {
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
            } else {
                result.notImplemented()
            }
        }
    }

    private fun mergeWithFFmpeg(videoPath: String, audioPath: String, outputPath: String) {
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
            "-c", "copy",
            "-y",
            outputPath
        )

        android.util.Log.d("BiliMerger", "Executing: ${pb.command().joinToString(" ")}")

        // Execute FFmpeg with proper async I/O handling
        pb.redirectErrorStream(true)
        val process = pb.start()

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

        // Wait for process with timeout (30 seconds per video should be enough)
        val finished = process.waitFor(30, java.util.concurrent.TimeUnit.SECONDS)
        
        if (!finished) {
            process.destroy()
            throw Exception("FFmpeg timeout after 30 seconds")
        }

        readerThread.join(1000) // Wait for reader thread to finish
        
        val exitCode = process.exitValue()
        val output = outputBuilder.toString()

        android.util.Log.d("BiliMerger", "FFmpeg exit code: $exitCode")

        if (exitCode != 0) {
            throw Exception("FFmpeg failed with exit code $exitCode: $output")
        }
        
        // Verify output file was created
        if (!File(outputPath).exists()) {
            throw Exception("Output file was not created: $outputPath")
        }
        
        android.util.Log.d("BiliMerger", "Merge completed successfully")
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
