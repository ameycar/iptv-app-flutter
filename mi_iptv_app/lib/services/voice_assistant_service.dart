import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Modelo que encapsula el resultado de la orden de voz procesada
class VoiceCommandResult {
  final String actionType; // 'CHANNEL', 'SECTION', 'EPG', 'NONE'
  final String spokenResponse;
  final dynamic targetChannel;
  final String targetSection;

  VoiceCommandResult({
    required this.actionType,
    required this.spokenResponse,
    this.targetChannel,
    this.targetSection = '',
  });
}

class VoiceAssistantService {
  static final VoiceAssistantService _instance = VoiceAssistantService._internal();
  factory VoiceAssistantService() => _instance;

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isSpeechInitialized = false;
  bool _isSpeaking = false;

  VoiceAssistantService._internal() {
    _initTts();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage("es-ES");
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.55);

      _tts.setStartHandler(() {
        _isSpeaking = true;
      });

      _tts.setCompletionHandler(() {
        _isSpeaking = false;
      });

      _tts.setErrorHandler((msg) {
        _isSpeaking = false;
      });
    } catch (e) {
      debugPrint("Error inicializando TTS: $e");
    }
  }

  /// Inicia la escucha por micrófono
  Future<bool> startListening({
    required Function(String words) onWordsRecognized,
    required VoidCallback onListeningComplete,
  }) async {
    try {
      if (!_isSpeechInitialized) {
        _isSpeechInitialized = await _speech.initialize(
          onError: (val) {
            debugPrint("Speech Error: ${val.errorMsg}");
            onListeningComplete();
          },
          onStatus: (status) {
            if (status == 'done' || status == 'notListening') {
              onListeningComplete();
            }
          },
        );
      }

      if (_isSpeechInitialized) {
        await _speech.listen(
          localeId: "es_ES",
          onResult: (val) {
            onWordsRecognized(val.recognizedWords);
            if (val.finalResult) {
              onListeningComplete();
            }
          },
          listenFor: const Duration(seconds: 8),
          pauseFor: const Duration(seconds: 2),
        );
        return true;
      }
    } catch (e) {
      debugPrint("Error al escuchar voz: $e");
    }
    return false;
  }

  /// Detiene la escucha y libera el micrófono
  Future<void> stopListening() async {
    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
    } catch (e) {
      debugPrint("Error deteniendo speech: $e");
    }
  }

  /// Pronuncia una respuesta por los altavoces
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    try {
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint("Error al hablar TTS: $e");
    }
  }

  /// Detiene cualquier habla en progreso
  Future<void> stopSpeaking() async {
    try {
      await _tts.stop();
      _isSpeaking = false;
    } catch (e) {
      debugPrint("Error deteniendo TTS: $e");
    }
  }

  /// Procesa la orden de voz reconociendo canales, deportes o secciones
  VoiceCommandResult processVoiceCommand({
    required String query,
    required List<dynamic> channels,
    dynamic currentChannel,
  }) {
    final cleanQuery = _normalizeText(query);

    if (cleanQuery.isEmpty) {
      return VoiceCommandResult(
        actionType: 'NONE',
        spokenResponse: "No logré escucharte con claridad. ¿Puedes repetirlo?",
      );
    }

    // 1. Detectar comando de Guía EPG
    if (cleanQuery.contains("guia") ||
        cleanQuery.contains("epg") ||
        cleanQuery.contains("programacion") ||
        cleanQuery.contains("cartelera")) {
      return VoiceCommandResult(
        actionType: 'EPG',
        spokenResponse: "Abriendo la guía electrónica de canales.",
      );
    }

    // 2. Detectar comando de Películas o Series
    if (cleanQuery.contains("pelicula") ||
        cleanQuery.contains("cine") ||
        cleanQuery.contains("estreno") ||
        cleanQuery.contains("vod")) {
      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'PELICULAS',
        spokenResponse: "Mostrando catálogo de películas.",
      );
    }

    if (cleanQuery.contains("serie") || cleanQuery.contains("temporada")) {
      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'SERIES',
        spokenResponse: "Mostrando catálogo de series.",
      );
    }

    // 3. Detectar comando de Deportes / Partidos
    if (cleanQuery.contains("deporte") ||
        cleanQuery.contains("partido") ||
        cleanQuery.contains("futbol") ||
        cleanQuery.contains("soccer") ||
        cleanQuery.contains("champions") ||
        cleanQuery.contains("liga")) {
      
      // Buscar el mejor canal de deportes en la lista
      dynamic sportsChannel;
      final sportsKeywords = ["espn", "fox sports", "directv sports", "dsports", "tyc", "gol", "tnt sports", "deportes"];

      for (var kw in sportsKeywords) {
        sportsChannel = channels.firstWhere(
          (c) => _normalizeText(c['name']?.toString() ?? '').contains(kw),
          orElse: () => null,
        );
        if (sportsChannel != null) break;
      }

      if (sportsChannel != null) {
        final name = sportsChannel['name'] ?? 'Deportes';
        return VoiceCommandResult(
          actionType: 'CHANNEL',
          targetChannel: sportsChannel,
          spokenResponse: "Sintonizando $name para los eventos deportivos.",
        );
      }
    }

    // 4. Búsqueda directa del nombre del canal en la lista
    // Quitar palabras de relleno como "pon", "poner", "ver", "canal", "cambiar a", "sintoniza"
    String targetName = cleanQuery
        .replaceAll(RegExp(r'\b(pon|poner|ver|canal|cambiar a|cambia a|sintoniza|sintonizar|quiero ver|reproducir)\b'), '')
        .trim();

    if (targetName.isEmpty) {
      targetName = cleanQuery;
    }

    dynamic matchedChannel;

    // A. Búsqueda exacta
    matchedChannel = channels.firstWhere(
      (c) => _normalizeText(c['name']?.toString() ?? '') == targetName,
      orElse: () => null,
    );

    // B. Búsqueda que contenga la palabra (ej: "espn 2" o "discovery")
    if (matchedChannel == null) {
      matchedChannel = channels.firstWhere(
        (c) => _normalizeText(c['name']?.toString() ?? '').contains(targetName),
        orElse: () => null,
      );
    }

    // C. Búsqueda por palabras individuales clave
    if (matchedChannel == null) {
      final tokens = targetName.split(' ').where((t) => t.length > 2).toList();
      if (tokens.isNotEmpty) {
        matchedChannel = channels.firstWhere(
          (c) {
            final cName = _normalizeText(c['name']?.toString() ?? '');
            return tokens.any((tok) => cName.contains(tok));
          },
          orElse: () => null,
        );
      }
    }

    if (matchedChannel != null) {
      final name = matchedChannel['name'] ?? 'el canal solicitado';
      return VoiceCommandResult(
        actionType: 'CHANNEL',
        targetChannel: matchedChannel,
        spokenResponse: "Sintonizando $name.",
      );
    }

    // 5. No encontrado
    return VoiceCommandResult(
      actionType: 'NONE',
      spokenResponse: "No encontré el canal $targetName. Intenta con otro nombre.",
    );
  }

  /// Limpia tildes, mayúsculas y caracteres especiales para búsquedas precisas
  String _normalizeText(String input) {
    return input
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), '')
        .trim();
  }
}