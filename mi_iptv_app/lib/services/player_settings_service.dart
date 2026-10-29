import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';

class PlayerSettingsService {
  static final ValueNotifier<double> bufferSizeNotifier = ValueNotifier(10.0);
  static final ValueNotifier<String> eqModeNotifier = ValueNotifier('Plano');
  static final ValueNotifier<String> audioTrackNotifier = ValueNotifier('Español (Predeterminado)');

  // Obtiene el perfil específico de la familia (o el usuario principal)
  static String get _profileId => AuthService.currentActiveProfile?.id ?? AuthService.currentUser?.id ?? 'default';

  static Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    final pId = _profileId;
    bool loadedFromCloud = false;

    // 1. Intentar descargar la configuración de la nube
    final user = AuthService.currentUser;
    if (user != null && AuthService.isFirebaseAvailable) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.id).get();
        if (doc.exists) {
          final data = doc.data();
          if (data != null && data['player_settings_$pId'] != null) {
            final settings = data['player_settings_$pId'] as Map<String, dynamic>;
            bufferSizeNotifier.value = (settings['buffer_size'] ?? 10.0).toDouble();
            eqModeNotifier.value = settings['eq_mode'] ?? 'Plano';
            audioTrackNotifier.value = settings['audio_track'] ?? 'Español (Predeterminado)';

            // Guardar copia local
            await prefs.setDouble('adv_buffer_size_$pId', bufferSizeNotifier.value);
            await prefs.setString('adv_eq_mode_$pId', eqModeNotifier.value);
            await prefs.setString('adv_audio_track_$pId', audioTrackNotifier.value);
            loadedFromCloud = true;
          }
        }
      } catch (_) {}
    }

    // 2. Si no hay internet o falla la nube, cargar caché local
    if (!loadedFromCloud) {
      bufferSizeNotifier.value = prefs.getDouble('adv_buffer_size_$pId') ?? 10.0;
      eqModeNotifier.value = prefs.getString('adv_eq_mode_$pId') ?? 'Plano';
      audioTrackNotifier.value = prefs.getString('adv_audio_track_$pId') ?? 'Español (Predeterminado)';
    }
  }

  static Future<void> _syncToCloud() async {
    final user = AuthService.currentUser;
    if (user == null || !AuthService.isFirebaseAvailable) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.id).set({
        'player_settings_$_profileId': {
          'buffer_size': bufferSizeNotifier.value,
          'eq_mode': eqModeNotifier.value,
          'audio_track': audioTrackNotifier.value,
        }
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> setBufferSize(double val) async {
    bufferSizeNotifier.value = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('adv_buffer_size_$_profileId', val);
    _syncToCloud();
  }

  static Future<void> setEqMode(String mode) async {
    eqModeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adv_eq_mode_$_profileId', mode);
    _syncToCloud();
  }

  static Future<void> setAudioTrack(String track) async {
    audioTrackNotifier.value = track;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adv_audio_track_$_profileId', track);
    _syncToCloud();
  }
}