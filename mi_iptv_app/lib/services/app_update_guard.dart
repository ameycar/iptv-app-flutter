import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AppUpdateGuard {
  static const MethodChannel _updateChannel = MethodChannel('ameycar.tv/update');
  static bool _isDialogShowing = false;
  static bool _dismissedOptionalThisSession = false;

  /// Verifica versión mínima en Firestore + Google Play In-App Update
  static Future<void> checkForUpdates(
    BuildContext context, {
    required bool isTv,
    bool isAdmin = false,
  }) async {
    if (_isDialogShowing) return;

    try {
      final info = await PackageInfo.fromPlatform();
      final int currentBuild = int.tryParse(info.buildNumber) ?? 1;
      final String currentVersion = info.version;
      final String packageName = info.packageName;

      // 1. Si es Android instalado desde Google Play, consultar actualización inmediata nativa
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
        unawaited(_triggerPlayStoreImmediateIfAvailable());
      }

      // 2. Consultar regla maestra en Firestore (100% bajo tu control)
      final doc = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('app_version_control')
          .get()
          .timeout(const Duration(seconds: 4));

      if (!doc.exists || !context.mounted) return;
      final data = doc.data();
      if (data == null) return;

      final int minRequiredBuild =
          int.tryParse((data['minRequiredBuild'] ?? 1).toString()) ?? 1;
      final int latestBuild =
          int.tryParse((data['latestBuild'] ?? currentBuild).toString()) ??
              currentBuild;
      final bool forceFlag = data['forceUpdate'] == true;
      final String latestVersionName =
          (data['latestVersionName'] ?? '').toString().trim();
      final String releaseNotes = (data['releaseNotes'] ??
              'Hemos publicado mejoras importantes de estabilidad, velocidad y compatibilidad.')
          .toString()
          .trim();
      final String customStoreUrl =
          (data['playStoreUrl'] ?? '').toString().trim();

      final String resolvedStoreUrl = customStoreUrl.isNotEmpty
          ? customStoreUrl
          : 'https://play.google.com/store/apps/details?id=$packageName';

      final bool mustForce =
          !isAdmin && (currentBuild < minRequiredBuild || (forceFlag && currentBuild < latestBuild));
      final bool hasOptionalUpdate =
          !mustForce && currentBuild < latestBuild && !_dismissedOptionalThisSession;

      if (!mustForce && !hasOptionalUpdate) return;
      if (!context.mounted) return;

      _isDialogShowing = true;
      await showDialog(
        context: context,
        barrierDismissible: !mustForce,
        barrierColor: Colors.black.withOpacity(0.90),
        builder: (ctx) => _UpdateRequiredDialog(
          isMandatory: mustForce,
          isTv: isTv,
          currentVersion: '$currentVersion ($currentBuild)',
          targetVersion: latestVersionName.isNotEmpty
              ? '$latestVersionName ($latestBuild)'
              : 'Build $latestBuild',
          releaseNotes: releaseNotes,
          storeUrl: resolvedStoreUrl,
          onLater: () {
            _dismissedOptionalThisSession = true;
            Navigator.of(ctx).pop();
          },
        ),
      );
    } catch (e) {
      debugPrint('Aviso verificando actualización: $e');
    } finally {
      _isDialogShowing = false;
    }
  }

  static Future<void> _triggerPlayStoreImmediateIfAvailable() async {
    try {
      await _updateChannel.invokeMethod('checkImmediatePlayUpdate');
    } catch (_) {}
  }

  /// Panel rápido para que tú como Admin configures la versión mínima desde la app
  static Future<void> showAdminVersionControlModal(BuildContext context) async {
    final info = await PackageInfo.fromPlatform();
    final currentBuild = int.tryParse(info.buildNumber) ?? 1;

    Map existing = {};
    try {
      final doc = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('app_version_control')
          .get();
      if (doc.exists && doc.data() != null) {
        existing = doc.data()!;
      }
    } catch (_) {}

    if (!context.mounted) return;

    final minBuildCtrl = TextEditingController(
      text: (existing['minRequiredBuild'] ?? currentBuild).toString(),
    );
    final latestBuildCtrl = TextEditingController(
      text: (existing['latestBuild'] ?? currentBuild).toString(),
    );
    final latestNameCtrl = TextEditingController(
      text: (existing['latestVersionName'] ?? info.version).toString(),
    );
    final notesCtrl = TextEditingController(
      text: (existing['releaseNotes'] ??
              'Mejoras críticas de rendimiento, estabilidad y reproducción.')
          .toString(),
    );
    final storeUrlCtrl = TextEditingController(
      text: (existing['playStoreUrl'] ??
              'https://play.google.com/store/apps/details?id=${info.packageName}')
          .toString(),
    );
    bool isSaving = false;

    await showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF0F172A),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
          ),
          title: const Row(
            children: [
              Icon(Icons.system_update_rounded, color: Color(0xFF00E5FF)),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Control de Versiones Google Play',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16.5,
                      fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Versión de esta compilación: ${info.version} (+$currentBuild)',
                    style: const TextStyle(
                        color: Color(0xFFFFD600),
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '• Si un usuario tiene un Build menor a "Build Mínimo Obligatorio", la app bloqueará el acceso hasta que actualice en Google Play.\n• Súbelo solo ante cambios verdaderamente importantes.',
                    style: TextStyle(color: Colors.white60, fontSize: 11.5),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: minBuildCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Build Mínimo Obligatorio',
                            labelStyle: const TextStyle(
                                color: Colors.redAccent, fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF1E293B),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: latestBuildCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Último Build Publicado',
                            labelStyle: const TextStyle(
                                color: Color(0xFF00E5FF), fontSize: 12),
                            filled: true,
                            fillColor: const Color(0xFF1E293B),
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: latestNameCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Nombre de Versión (Ej: 1.1.0)',
                      labelStyle:
                          const TextStyle(color: Colors.white60, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: notesCtrl,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'Mensaje al usuario',
                      labelStyle:
                          const TextStyle(color: Colors.white60, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: storeUrlCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                    decoration: InputDecoration(
                      labelText: 'URL Oficial en Google Play',
                      labelStyle:
                          const TextStyle(color: Colors.white60, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar',
                  style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
              ),
              onPressed: isSaving
                  ? null
                  : () async {
                      setModalState(() => isSaving = true);
                      final minB =
                          int.tryParse(minBuildCtrl.text.trim()) ?? currentBuild;
                      final latB =
                          int.tryParse(latestBuildCtrl.text.trim()) ?? minB;
                      await FirebaseFirestore.instance
                          .collection('system_config')
                          .doc('app_version_control')
                          .set({
                        'minRequiredBuild': minB,
                        'latestBuild': latB,
                        'latestVersionName': latestNameCtrl.text.trim(),
                        'releaseNotes': notesCtrl.text.trim(),
                        'playStoreUrl': storeUrlCtrl.text.trim(),
                        'updatedAt': FieldValue.serverTimestamp(),
                      }, SetOptions(merge: true));

                      if (ctx.mounted) Navigator.pop(ctx);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                '✅ Política guardada: Build mínimo obligatorio = $minB'),
                            backgroundColor: const Color(0xFF00C853),
                          ),
                        );
                      }
                    },
              child: Text(
                isSaving ? 'Guardando...' : 'Guardar Regla',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UpdateRequiredDialog extends StatelessWidget {
  final bool isMandatory;
  final bool isTv;
  final String currentVersion;
  final String targetVersion;
  final String releaseNotes;
  final String storeUrl;
  final VoidCallback onLater;

  const _UpdateRequiredDialog({
    required this.isMandatory,
    required this.isTv,
    required this.currentVersion,
    required this.targetVersion,
    required this.releaseNotes,
    required this.storeUrl,
    required this.onLater,
  });

  Future<void> _openGooglePlay() async {
    // 1. Intentar primero el flujo nativo In-App Update de Google Play
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        final bool? launched = await AppUpdateGuard._updateChannel
            .invokeMethod<bool>('checkImmediatePlayUpdate');
        if (launched == true) return;
      } catch (_) {}
    }

    // 2. Abrir ficha directa en Google Play Store
    final uri = Uri.tryParse(storeUrl);
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent =
        isMandatory ? const Color(0xFFFFD600) : const Color(0xFF00E5FF);

    return PopScope(
      canPop: !isMandatory,
      child: Dialog(
        backgroundColor: const Color(0xFF0F172A),
        insetPadding: EdgeInsets.symmetric(
          horizontal: isTv ? 140 : 22,
          vertical: 24,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: accent, width: 1.8),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: isTv ? 560 : 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.15),
                    shape: BoxShape.circle,
                    border: Border.all(color: accent.withOpacity(0.6)),
                  ),
                  child: Icon(
                    isMandatory
                        ? Icons.security_update_warning_rounded
                        : Icons.system_update_rounded,
                    color: accent,
                    size: 38,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  isMandatory
                      ? 'Actualización Requerida'
                      : 'Nueva Versión Disponible',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tu versión: $currentVersion  →  Nueva: $targetVersion',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  releaseNotes,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13.5,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    autofocus: true,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    onPressed: _openGooglePlay,
                    icon: const Icon(Icons.shop_rounded),
                    label: const Text(
                      'ACTUALIZAR EN GOOGLE PLAY',
                      style: TextStyle(
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                      ),
                    ),
                  ),
                ),
                if (!isMandatory) ...[
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: onLater,
                    child: const Text(
                      'Más tarde',
                      style: TextStyle(color: Colors.white54),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}