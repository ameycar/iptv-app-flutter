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

  static final ValueNotifier<bool> isListeningNotifier =
      ValueNotifier<bool>(false);

  /// Envía un comando instantáneo desde el celular hacia la TV / PC / Chromecast
  static Future<bool> sendCommandToTv({
    required String command,
    Map<String, dynamic>? extraData,
  }) async {
    if (!AuthService.isFirebaseAvailable) return false;
    final userId = AuthService.currentUser?.id;
    if (userId == null || userId.isEmpty) return false;

    final nonce =
        '${DateTime.now().microsecondsSinceEpoch}_${Random().nextInt(99999)}';

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
        'serverAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      debugPrint('Error enviando comando remoto a TV: $e');
      return false;
    }
  }

  /// La TV / PC escucha comandos entrantes enviados desde el celular del usuario
  static void listenToCommands({
    required void Function(String command, Map<String, dynamic> extraData)
        onCommandReceived,
  }) {
    if (!AuthService.isFirebaseAvailable) return;
    final userId = AuthService.currentUser?.id;
    if (userId == null || userId.isEmpty) return;

    _tvCommandSub?.cancel();
    _initialSnapshotSkipped = false;
    isListeningNotifier.value = true;

    _tvCommandSub = FirebaseFirestore.instance
        .collection('remote_sessions')
        .doc(userId)
        .snapshots()
        .listen(
      (snapshot) {
        if (!snapshot.exists) {
          _initialSnapshotSkipped = true;
          return;
        }
        final data = snapshot.data() ?? {};

        // Ignoramos el primer snapshot viejo guardado al abrir la app
        if (!_initialSnapshotSkipped) {
          _initialSnapshotSkipped = true;
          _lastExecutedNonce = (data['nonce'] ?? '').toString();
          return;
        }

        final senderId = (data['senderId'] ?? '').toString();
        final nonce = (data['nonce'] ?? '').toString();

        // No ejecutar en el mismo dispositivo que envió la orden
        if (senderId == localInstanceId) return;
        if (nonce.isEmpty || nonce == _lastExecutedNonce) return;

        // NOTA: No comparamos relojes locales porque muchos TV Box tienen desfase horario
        _lastExecutedNonce = nonce;
        final cmd = (data['command'] ?? '').toString();
        final rawExtra = data['extraData'];
        final extra = rawExtra is Map
            ? Map<String, dynamic>.from(rawExtra)
            : <String, dynamic>{};

        if (cmd.isNotEmpty) {
          onCommandReceived(cmd, extra);
        }
      },
      onError: (e) {
        debugPrint('Error en listener de Mando Remoto: $e');
      },
    );
  }

  static void dispose() {
    _tvCommandSub?.cancel();
    _tvCommandSub = null;
    isListeningNotifier.value = false;
  }
}