package com.example.mi_iptv_app
// DEJA TU PRIMERA LÍNEA "package com.tu_paquete..." INTACTA AQUÍ ARRIBA

import android.app.PictureInPictureParams
import android.os.Build
import android.util.Rational
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "ameycar.tv/pip"
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
