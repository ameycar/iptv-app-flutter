import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'auth_service.dart';

class PlayerSettingsService {
  static final ValueNotifier bufferSizeNotifier = ValueNotifier(10.0);
  static final ValueNotifier eqModeNotifier = ValueNotifier('Plano');
  static final ValueNotifier audioTrackNotifier = ValueNotifier('Español (Predeterminado)');
  
  // --- NUEVAS VARIABLES DE INCLUSIÓN ---
  static final ValueNotifier subtitleTrackNotifier = ValueNotifier('Desactivado');
  static final ValueNotifier colorFilterNotifier = ValueNotifier('Normal');

  // Lista oficial de idiomas soportados para Subtítulos y Traducción en Vivo (CC)
  static const supportedCcLanguages = [
    {'id': 'Desactivado', 'label': 'Desactivado (Sin Subtítulos)', 'flag': '🚫', 'code': 'off'},
    {'id': 'Español', 'label': 'Español (Traducción en Vivo / CC)', 'flag': '🇪🇸', 'code': 'es'},
    {'id': 'Inglés', 'label': 'English (Live Translation / CC)', 'flag': '🇺🇸', 'code': 'en'},
    {'id': 'Portugués', 'label': 'Português (Tradução ao Vivo / CC)', 'flag': '🇧🇷', 'code': 'pt'},
    {'id': 'Francés', 'label': 'Français (Traduction en Direct / CC)', 'flag': '🇫🇷', 'code': 'fr'},
    {'id': 'Italiano', 'label': 'Italiano (Traduzione dal Vivo / CC)', 'flag': '🇮🇹', 'code': 'it'},
    {'id': 'Alemán', 'label': 'Deutsch (Live-Übersetzung / CC)', 'flag': '🇩🇪', 'code': 'de'},
  ];

  // Obtiene el perfil específico de la familia (o el usuario principal)
  static String get _profileId => AuthService.currentActiveProfile?.id ?? AuthService.currentUser?.id ?? 'default';

  static Future initialize() async {
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
            final settings = Map.from(data['player_settings_$pId'] as Map);
            bufferSizeNotifier.value = ((settings['buffer_size'] ?? 10.0) as num).toDouble();
            eqModeNotifier.value = (settings['eq_mode'] ?? 'Plano').toString();
            audioTrackNotifier.value = (settings['audio_track'] ?? 'Español (Predeterminado)').toString();
            
            // Cargar datos de inclusión desde la nube
            subtitleTrackNotifier.value = (settings['subtitle_track'] ?? 'Desactivado').toString();
            colorFilterNotifier.value = (settings['color_filter'] ?? 'Normal').toString();

            // Guardar copia local
            await prefs.setDouble('adv_buffer_size_$pId', bufferSizeNotifier.value as double);
            await prefs.setString('adv_eq_mode_$pId', eqModeNotifier.value.toString());
            await prefs.setString('adv_audio_track_$pId', audioTrackNotifier.value.toString());
            await prefs.setString('adv_subtitle_track_$pId', subtitleTrackNotifier.value.toString());
            await prefs.setString('adv_color_filter_$pId', colorFilterNotifier.value.toString());
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
      subtitleTrackNotifier.value = prefs.getString('adv_subtitle_track_$pId') ?? 'Desactivado';
      colorFilterNotifier.value = prefs.getString('adv_color_filter_$pId') ?? 'Normal';
    }
  }

  static Future _syncToCloud() async {
    final user = AuthService.currentUser;
    if (user == null || !AuthService.isFirebaseAvailable) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.id).set({
        'player_settings_$_profileId': {
          'buffer_size': bufferSizeNotifier.value,
          'eq_mode': eqModeNotifier.value,
          'audio_track': audioTrackNotifier.value,
          'subtitle_track': subtitleTrackNotifier.value,
          'color_filter': colorFilterNotifier.value,
        }
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future setBufferSize(double val) async {
    bufferSizeNotifier.value = val;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('adv_buffer_size_$_profileId', val);
    _syncToCloud();
  }

  static Future setEqMode(String mode) async {
    eqModeNotifier.value = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adv_eq_mode_$_profileId', mode);
    _syncToCloud();
  }

  static Future setAudioTrack(String track) async {
    audioTrackNotifier.value = track;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adv_audio_track_$_profileId', track);
    _syncToCloud();
  }

  // --- NUEVOS SETTERS DE INCLUSIÓN ---
  static Future setSubtitleTrack(String track) async {
    subtitleTrackNotifier.value = track;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adv_subtitle_track_$_profileId', track);
    _syncToCloud();
  }

  static Future setColorFilter(String filter) async {
    colorFilterNotifier.value = filter;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('adv_color_filter_$_profileId', filter);
    _syncToCloud();
  }

  /// Ventana Emergente (Modal) para el botón CC: Permite elegir idioma de subtítulos y traducción en vivo
  static Future showLiveCcLanguageModal(BuildContext context) async {
    await showDialog(
      context: context,
      barrierColor: Colors.black87,
      builder: (ctx) {
        return ValueListenableBuilder(
          valueListenable: subtitleTrackNotifier,
          builder: (context, currentLangObj, _) {
            final currentLang = currentLangObj.toString();
            return Dialog(
              backgroundColor: const Color(0xFF10141D),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
                side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460, maxHeight: 520),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E5FF).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Icon(
                              Icons.closed_caption_rounded,
                              color: Color(0xFF00E5FF),
                              size: 26,
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Subtítulos y Traducción CC en Vivo',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 17,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(height: 2),
                                Text(
                                  'Traduce automáticamente el audio del canal a tu idioma',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(Icons.close, color: Colors.white70),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: supportedCcLanguages.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (context, index) {
                            final item = supportedCcLanguages[index];
                            final id = item['id']!;
                            final isSelected = currentLang.toLowerCase().contains(id.toLowerCase());

                            return InkWell(
                              autofocus: isSelected || index == 0,
                              borderRadius: BorderRadius.circular(12),
                              onTap: () async {
                                await setSubtitleTrack(id);
                                if (ctx.mounted) {
                                  Navigator.of(ctx).pop();
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                decoration: BoxDecoration(
                                  color: isSelected
                                      ? const Color(0xFF00E5FF).withOpacity(0.18)
                                      : Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: isSelected
                                        ? const Color(0xFF00E5FF)
                                        : Colors.white12,
                                    width: isSelected ? 1.5 : 1.0,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Text(
                                      item['flag']!,
                                      style: const TextStyle(fontSize: 20),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Text(
                                        item['label']!,
                                        style: TextStyle(
                                          color: isSelected
                                              ? const Color(0xFF00E5FF)
                                              : Colors.white,
                                          fontWeight: isSelected
                                              ? FontWeight.bold
                                              : FontWeight.w500,
                                          fontSize: 14,
                                        ),
                                      ),
                                    ),
                                    if (isSelected)
                                      const Icon(
                                        Icons.check_circle_rounded,
                                        color: Color(0xFF00E5FF),
                                        size: 20,
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}