package com.example.mi_iptv_app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import android.util.Log

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val isBootAction = action == Intent.ACTION_BOOT_COMPLETED ||
            action == "android.intent.action.QUICKBOOT_POWERON" ||
            action == "com.htc.intent.action.QUICKBOOT_POWERON"

        if (!isBootAction) return

        // Activo por defecto (true) al instalar; el usuario puede apagarlo desde Ajustes en Flutter
        val autoStartEnabled = try {
            val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            prefs.getBoolean("flutter.auto_start_on_boot", true)
        } catch (e: Exception) {
            Log.w("AmeycarBoot", "No se pudo leer preferencia en arranque temprano, usando valor por defecto (true): ${e.message}")
            true
        }

        if (!autoStartEnabled) {
            Log.d("AmeycarBoot", "Auto-inicio desactivado por el usuario en Ajustes. Omitiendo lanzamiento.")
            return
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && !Settings.canDrawOverlays(context)) {
            Log.w("AmeycarBoot", "Permiso de superposición no concedido aún; intentando inicio de respaldo...")
        } else {
            Log.d("AmeycarBoot", "¡Dispositivo encendido! Lanzando Ameycar TV automáticamente...")
        }

        try {
            val launchIntent = Intent(context, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP)
                addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                addFlags(Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            }
            context.startActivity(launchIntent)
        } catch (e: Exception) {
            Log.e("AmeycarBoot", "No se pudo abrir Ameycar TV al inicio: ${e.message}")
        }
    }
}