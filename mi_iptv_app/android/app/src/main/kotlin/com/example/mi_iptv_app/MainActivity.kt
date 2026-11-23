package com.example.mi_iptv_app
// DEJA TU PRIMERA LÍNEA "package com.tu_paquete..." INTACTA AQUÍ ARRIBA

import android.Manifest
import android.app.ActivityManager
import android.app.PictureInPictureParams
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Rational
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ameycar.tv/pip"
    private val DEVICE_CHANNEL = "ameycar.tv/device"
    private val AUDIO_CHANNEL = "ameycar.tv/audio_capture"
    private var autoPipEnabled = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "enterPip" -> {
                    val entered = enterNativePipMode()
                    result.success(entered)
                }
                "setAutoPip" -> {
                    autoPipEnabled = call.argument<Boolean>("enabled") ?: true
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getPersistentDeviceId" -> {
                    result.success(getPersistentDeviceFingerprint())
                }
                "canDrawOverlays" -> {
                    result.success(canDrawOverlaysPermission())
                }
                "requestOverlayPermission" -> {
                    result.success(openOverlayPermissionSettings())
                }
                "isAutoStartEnabled" -> {
                    result.success(isAutoStartEnabled())
                }
                "setAutoStartEnabled" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    setAutoStartEnabled(enabled)
                    result.success(true)
                }
                "openCaptionSettings" -> {
                    result.success(openCaptionSettingsScreen())
                }
                else -> result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUDIO_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getTotalRamMb" -> {
                    result.success(getDeviceTotalRamMb())
                }
                "captureAudioChunk" -> {
                    val durationMs = call.argument<Int>("durationMs") ?: 3500
                    captureAudioChunkToWav(durationMs, result)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun canDrawOverlaysPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(this)
        } else {
            true
        }
    }

    private fun openOverlayPermissionSettings(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return true
        }

        val intents = listOf(
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            Intent(
                Settings.ACTION_MANAGE_OVERLAY_PERMISSION
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            Intent(
                Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:$packageName")
            ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        )

        for (intent in intents) {
            try {
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Probar siguiente ruta compatible con Android TV / TV Box
            }
        }
        return false
    }

    private fun openCaptionSettingsScreen(): Boolean {
        return try {
            val intent = Intent(Settings.ACTION_CAPTIONING_SETTINGS).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun isAutoStartEnabled(): Boolean {
        return try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.getBoolean("flutter.auto_start_on_boot", true)
        } catch (_: Exception) {
            true
        }
    }

    private fun setAutoStartEnabled(enabled: Boolean) {
        try {
            val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.edit().putBoolean("flutter.auto_start_on_boot", enabled).apply()
        } catch (_: Exception) {}
    }

    private fun getDeviceTotalRamMb(): Int {
        return try {
            val actManager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val memInfo = ActivityManager.MemoryInfo()
            actManager.getMemoryInfo(memInfo)
            (memInfo.totalMem / (1024 * 1024)).toInt()
        } catch (e: Exception) {
            2048
        }
    }

    private fun captureAudioChunkToWav(durationMs: Int, result: MethodChannel.Result) {
        val mainHandler = Handler(Looper.getMainLooper())
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            mainHandler.post { result.success(null) }
            return
        }

        Thread {
            var recorder: AudioRecord? = null
            try {
                val sampleRate = 16000
                val channelConfig = AudioFormat.CHANNEL_IN_MONO
                val audioFormat = AudioFormat.ENCODING_PCM_16BIT
                val minBufSize = AudioRecord.getMinBufferSize(sampleRate, channelConfig, audioFormat)
                val bufferSize = maxOf(minBufSize, 4096)

                recorder = AudioRecord(
                    MediaRecorder.AudioSource.MIC,
                    sampleRate,
                    channelConfig,
                    audioFormat,
                    bufferSize
                )

                if (recorder.state != AudioRecord.STATE_INITIALIZED) {
                    recorder.release()
                    mainHandler.post { result.success(null) }
                    return@Thread
                }

                val pcmStream = ByteArrayOutputStream()
                val readBuffer = ByteArray(bufferSize)
                val targetBytes = ((sampleRate * 2L) * durationMs) / 1000L

                recorder.startRecording()
                var totalBytesRead = 0L
                while (totalBytesRead < targetBytes) {
                    val read = recorder.read(readBuffer, 0, readBuffer.size)
                    if (read > 0) {
                        pcmStream.write(readBuffer, 0, read)
                        totalBytesRead += read
                    } else {
                        break
                    }
                }
                recorder.stop()
                recorder.release()
                recorder = null

                val pcmBytes = pcmStream.toByteArray()
                val wavFile = File(cacheDir, "whisper_live_chunk.wav")
                writeWavFile(wavFile, pcmBytes, sampleRate, 1, 16)

                mainHandler.post { result.success(wavFile.absolutePath) }
            } catch (e: Exception) {
                try {
                    recorder?.release()
                } catch (_: Exception) {}
                mainHandler.post { result.success(null) }
            }
        }.start()
    }

    private fun writeWavFile(file: File, pcmData: ByteArray, sampleRate: Int, channels: Int, bitsPerSample: Int) {
        val byteRate = sampleRate * channels * bitsPerSample / 8
        val dataSize = pcmData.size
        val totalDataLen = dataSize + 36

        val header = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        header.put("RIFF".toByteArray(Charsets.US_ASCII))
        header.putInt(totalDataLen)
        header.put("WAVE".toByteArray(Charsets.US_ASCII))
        header.put("fmt ".toByteArray(Charsets.US_ASCII))
        header.putInt(16)
        header.putShort(1) // PCM
        header.putShort(channels.toShort())
        header.putInt(sampleRate)
        header.putInt(byteRate)
        header.putShort((channels * bitsPerSample / 8).toShort())
        header.putShort(bitsPerSample.toShort())
        header.put("data".toByteArray(Charsets.US_ASCII))
        header.putInt(dataSize)

        FileOutputStream(file).use { out ->
            out.write(header.array())
            out.write(pcmData)
        }
    }

    private fun getPersistentDeviceFingerprint(): String {
        val androidId = try {
            Settings.Secure.getString(contentResolver, Settings.Secure.ANDROID_ID) ?: ""
        } catch (e: Exception) {
            ""
        }

        val parts = listOf(
            "aid:$androidId",
            "brand:${Build.BRAND ?: ""}",
            "model:${Build.MODEL ?: ""}",
            "device:${Build.DEVICE ?: ""}",
            "board:${Build.BOARD ?: ""}",
            "hardware:${Build.HARDWARE ?: ""}"
        ).filter { !it.endsWith(":") }

        return parts.joinToString("|")
    }

    private fun enterNativePipMode(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val params = PictureInPictureParams.Builder()
                .setAspectRatio(Rational(16, 9))
                .build()
            return enterPictureInPictureMode(params)
        }
        return false
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (autoPipEnabled) {
            enterNativePipMode()
        }
    }
}