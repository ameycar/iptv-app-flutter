import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';

class VoiceCommandResult {
  final String actionType; // 'CHANNEL', 'EPG', 'SECTION', 'UNKNOWN'
  final dynamic targetChannel;
  final String targetSection;
  final String spokenResponse;

  VoiceCommandResult({
    required this.actionType,
    this.targetChannel,
    this.targetSection = '',
    required this.spokenResponse,
  });
}

class VoiceAssistantService {
  static final VoiceAssistantService _instance = VoiceAssistantService._internal();
  factory VoiceAssistantService() => _instance;
  VoiceAssistantService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _flutterTts = FlutterTts();
  bool _isInit = false;

  Future<void> _initTts() async {
    try {
      await _flutterTts.setLanguage("es-ES");
      await _flutterTts.setPitch(1.0);
      await _flutterTts.setSpeechRate(0.5);
    } catch (e) {
      debugPrint("Error inicializando TTS: $e");
    }
  }

  Future<void> startListening({
    required Function(String words) onWordsRecognized,
    required VoidCallback onListeningComplete,
  }) async {
    try {
      if (!_isInit) {
        _isInit = await _speech.initialize(
          onError: (val) => debugPrint('Error Speech: $val'),
          onStatus: (val) {
            if (val == 'done' || val == 'notListening') {
              onListeningComplete();
            }
          },
        );
      }

      if (_isInit) {
        await _speech.listen(
          localeId: 'es_ES',
          onResult: (val) {
            onWordsRecognized(val.recognizedWords);
          },
        );
      } else {
        // Fallback simulado para emuladores sin micro activo
        onWordsRecognized("Buscar ESPN");
        Future.delayed(const Duration(milliseconds: 1000), onListeningComplete);
      }
    } catch (e) {
      debugPrint("Error de reconocimiento de voz: $e");
      onListeningComplete();
    }
  }

  Future<void> stopListening() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  Future<void> speak(String text) async {
    try {
      await _initTts();
      await _flutterTts.speak(text);
    } catch (e) {
      debugPrint("Error TTS: $e");
    }
  }

  String _getChannelName(dynamic ch) {
    if (ch == null) return '';
    try {
      return (ch.name ?? '').toString();
    } catch (_) {
      if (ch is Map) return (ch['name'] ?? '').toString();
      return ch.toString();
    }
  }

  String _getChannelCategory(dynamic ch) {
    if (ch == null) return '';
    try {
      return (ch.groupCategory ?? '').toString();
    } catch (_) {
      if (ch is Map) return (ch['groupCategory'] ?? ch['category'] ?? '').toString();
      return '';
    }
  }

  VoiceCommandResult processVoiceCommand({
    required String query,
    required List<dynamic> channels,
    dynamic currentChannel,
  }) {
    final clean = query.toLowerCase().trim();

    // 1. Navegación a Secciones
    if (clean.contains("pelicula") || clean.contains("película") || clean.contains("cine")) {
      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'Películas',
        spokenResponse: "Abriendo la sección de películas.",
      );
    }
    if (clean.contains("serie") || clean.contains("series") || clean.contains("temporada")) {
      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'Series',
        spokenResponse: "Abriendo la sección de series.",
      );
    }
    if (clean.contains("en vivo") || clean.contains("tv") || clean.contains("television") || clean.contains("tele")) {
      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'En Vivo',
        spokenResponse: "Cambiando a televisión en vivo.",
      );
    }

    // 2. Guía EPG
    if (clean.contains("guia") || clean.contains("guía") || clean.contains("epg") || clean.contains("programacion") || clean.contains("programación") || clean.contains("horario")) {
      return VoiceCommandResult(
        actionType: 'EPG',
        spokenResponse: "Abriendo la guía electrónica de programación.",
      );
    }

    // 3. Búsqueda de deportes / partidos
    if (clean.contains("partido") || clean.contains("futbol") || clean.contains("fútbol") || clean.contains("deporte") || clean.contains("sports")) {
      for (final ch in channels) {
        final name = _getChannelName(ch).toLowerCase();
        final cat = _getChannelCategory(ch).toLowerCase();
        if (name.contains("espn") || name.contains("fox") || name.contains("sports") || cat.contains("deporte") || name.contains("win")) {
          final title = _getChannelName(ch);
          return VoiceCommandResult(
            actionType: 'CHANNEL',
            targetChannel: ch,
            spokenResponse: "Sintonizando $title en directo.",
          );
        }
      }
    }

    // 4. Coincidencia por nombre exacto o parcial del canal
    for (final ch in channels) {
      final name = _getChannelName(ch).toLowerCase();
      if (clean.contains(name) || name.contains(clean)) {
        final title = _getChannelName(ch);
        return VoiceCommandResult(
          actionType: 'CHANNEL',
          targetChannel: ch,
          spokenResponse: "Cambiando a $title.",
        );
      }
    }

    // 5. Coincidencia por categoría
    for (final ch in channels) {
      final cat = _getChannelCategory(ch).toLowerCase();
      if (cat.isNotEmpty && clean.contains(cat)) {
        final title = _getChannelName(ch);
        return VoiceCommandResult(
          actionType: 'CHANNEL',
          targetChannel: ch,
          spokenResponse: "Sintonizando $title de la categoría $cat.",
        );
      }
    }

    // Fallback: Primer canal si no hubo coincidencia precisa
    if (channels.isNotEmpty) {
      final ch = channels.first;
      final title = _getChannelName(ch);
      return VoiceCommandResult(
        actionType: 'CHANNEL',
        targetChannel: ch,
        spokenResponse: "Encontré $title. Sintonizando ahora.",
      );
    }

    return VoiceCommandResult(
      actionType: 'UNKNOWN',
      spokenResponse: "No encontré contenido con esa búsqueda.",
    );
  }
}