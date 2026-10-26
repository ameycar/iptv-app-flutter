import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';

class RemoteControlService {
  static StreamSubscription? _tvCommandSub;

  // Identificador único de esta instancia/pantalla para no auto-ejecutar comandos propios
  static final String localInstanceId =
      'dev_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(99999)}';

  static String _lastExecutedNonce = '';
  static bool _initialSnapshotSkipped = false;

  /// Envía un comando instantáneo desde el celular hacia la TV / PC / Chromecast
  static Future<void> sendCommandToTv({
    required String command,
    Map<String, dynamic>? extraData,
  }) async {
    if (!AuthService.isFirebaseAvailable) return;
    final userId = AuthService.currentUser?.id;
    if (userId == null) return;

    final nonce = '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(9999)}';

    try {
      await FirebaseFirestore.instance
          .collection('remote_sessions')
          .doc(userId)
          .set({
        'command': command,
        'extraData': extraData ?? {},
        'senderId': localInstanceId,
        'nonce': nonce,
        'updatedAtMs': DateTime.now().millisecondsSinceEpoch,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error enviando comando remoto a TV: $e');
    }
  }

  /// La TV / PC escucha comandos entrantes enviados desde el celular del usuario
  static void listenToCommands({
    required void Function(String command, Map<String, dynamic> extraData)
        onCommandReceived,
  }) {
    if (!AuthService.isFirebaseAvailable) return;
    final userId = AuthService.currentUser?.id;
    if (userId == null) return;

    _tvCommandSub?.cancel();
    _initialSnapshotSkipped = false;

    _tvCommandSub = FirebaseFirestore.instance
        .collection('remote_sessions')
        .doc(userId)
        .snapshots()
        .listen((snapshot) {
      if (!snapshot.exists) return;
      final data = snapshot.data() ?? {};

      // Ignoramos el primer snapshot viejo guardado en servidor al abrir la app
      if (!_initialSnapshotSkipped) {
        _initialSnapshotSkipped = true;
        _lastExecutedNonce = (data['nonce'] ?? '').toString();
        return;
      }

      final senderId = (data['senderId'] ?? '').toString();
      final nonce = (data['nonce'] ?? '').toString();
      final updatedAtMs = (data['updatedAtMs'] as int?) ?? 0;

      // No ejecutar en el mismo celular que envió la orden
      if (senderId == localInstanceId) return;
      if (nonce.isEmpty || nonce == _lastExecutedNonce) return;

      // Ignorar comandos viejos de hace más de 15 segundos
      if (updatedAtMs > 0 &&
          (DateTime.now().millisecondsSinceEpoch - updatedAtMs).abs() > 15000) {
        return;
      }

      _lastExecutedNonce = nonce;
      final cmd = (data['command'] ?? '').toString();
      final extra = Map<String, dynamic>.from(data['extraData'] ?? {});

      if (cmd.isNotEmpty) {
        onCommandReceived(cmd, extra);
      }
    });
  }

  static void dispose() {
    _tvCommandSub?.cancel();
    _tvCommandSub = null;
  }
}
