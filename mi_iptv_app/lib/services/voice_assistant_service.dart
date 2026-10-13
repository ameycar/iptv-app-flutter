import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

class VoiceAssistantResult {
  final String query;
  final String spokenResponse;
  final dynamic targetChannel;
  final String actionType; // 'CHANNEL', 'EPG', 'VOL_UP', 'VOL_DOWN', 'NONE'

  VoiceAssistantResult({
    required this.query,
    required this.spokenResponse,
    this.targetChannel,
    required this.actionType,
  });
}

class VoiceAssistantService {
  static final VoiceAssistantService _instance = VoiceAssistantService._internal();
  factory VoiceAssistantService() => _instance;
  VoiceAssistantService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isInitialized = false;
  bool isListening = false;

  Future<void> init() async {
    if (_isInitialized) return;
    try {
      await _tts.setLanguage("es-ES");
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.9);
      _isInitialized = true;
    } catch (e) {
      debugPrint("Error inicializando TTS: $e");
    }
  }

  /// Hablar respuesta al usuario por los parlantes
  Future<void> speak(String text) async {
    try {
      await init();
      await _tts.stop();
      await _tts.speak(text);
    } catch (e) {
      debugPrint("Error hablando con TTS: $e");
    }
  }

  /// Iniciar escucha activa en el micrófono
  Future<bool> startListening({
    required Function(String currentWords) onWordsRecognized,
    required Function() onListeningComplete,
  }) async {
    await init();

    // 1. Solicitar permiso de micrófono
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        speak("Necesito permiso de micrófono para escucharte.");
        return false;
      }
    }

    // 2. Iniciar motor de reconocimiento de voz
    bool available = await _speech.initialize(
      onError: (val) {
        debugPrint('Error de voz: $val');
        isListening = false;
        onListeningComplete();
      },
      onStatus: (val) {
        if (val == 'done' || val == 'notListening') {
          isListening = false;
          onListeningComplete();
        }
      },
    );

    if (available) {
      isListening = true;
      _speech.listen(
        localeId: 'es_ES',
        listenMode: stt.ListenMode.confirmation,
        pauseFor: const Duration(seconds: 3),
        onResult: (val) {
          onWordsRecognized(val.recognizedWords);
          if (val.hasConfidenceRating && val.confidence > 0.4 && val.finalResult) {
            isListening = false;
            onListeningComplete();
          }
        },
      );
      return true;
    } else {
      speak("El reconocimiento de voz no está disponible en este momento.");
      return false;
    }
  }

  /// Detener escucha manual
  Future<void> stopListening() async {
    if (isListening) {
      await _speech.stop();
      isListening = false;
    }
  }

  /// MOTOR DE INTELIGENCIA Y FILTRO DE CALIDAD HD
  VoiceAssistantResult processVoiceCommand({
    required String query,
    required List<dynamic> channels,
    dynamic currentChannel,
  }) {
    final lower = query.toLowerCase().trim();

    if (lower.isEmpty) {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "No alcancé a escucharte bien, ¿puedes repetir?",
        actionType: 'NONE',
      );
    }

    // 1. Consulta sobre la programación (Guía EPG)
    if (lower.contains("qué están dando") ||
        lower.contains("que dan") ||
        lower.contains("programación") ||
        lower.contains("guía") ||
        lower.contains("epg")) {
      final name = _getChannelName(currentChannel) ?? "este canal";
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Abriendo la guía interactiva para ver la programación de $name.",
        actionType: 'EPG',
      );
    }

    // 2. Control de volumen
    if (lower.contains("subir volumen") || lower.contains("sube volumen") || lower.contains("más volumen")) {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Subiendo volumen.",
        actionType: 'VOL_UP',
      );
    }
    if (lower.contains("bajar volumen") || lower.contains("baja volumen") || lower.contains("menos volumen")) {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Bajando volumen.",
        actionType: 'VOL_DOWN',
      );
    }

    // 3. Intención de deportes / fútbol / partidos
    bool wantsSports = lower.contains("partido") ||
        lower.contains("futbol") ||
        lower.contains("fútbol") ||
        lower.contains("deporte") ||
        lower.contains("champions") ||
        lower.contains("liga") ||
        lower.contains("copa");

    List<dynamic> candidates = [];

    if (wantsSports) {
      candidates = channels.where((ch) {
        final name = (_getChannelName(ch) ?? '').toLowerCase();
        final group = (_getChannelGroup(ch) ?? '').toLowerCase();
        return group.contains('deport') ||
            group.contains('sport') ||
            name.contains('espn') ||
            name.contains('fox') ||
            name.contains('tyc') ||
            name.contains('win') ||
            name.contains('directv') ||
            name.contains('liga') ||
            name.contains('sport');
      }).toList();
    } else {
      // Filtrar palabras de relleno
      final cleanKeyword = lower
          .replaceAll(RegExp(r'\b(pon|poner|canal|busca|buscar|el|la|los|en|hd|quiero|ver)\b'), '')
          .trim();

      candidates = channels.where((ch) {
        final name = (_getChannelName(ch) ?? '').toLowerCase();
        final group = (_getChannelGroup(ch) ?? '').toLowerCase();
        return name.contains(cleanKeyword) || group.contains(cleanKeyword);
      }).toList();
    }

    if (candidates.isEmpty && channels.isNotEmpty) {
      candidates = channels;
    }

    // 4. RANKING POR RESOLUCIÓN HD: 4K (40 pts) > 1080p FHD (30 pts) > 720p HD (20 pts)
    candidates.sort((a, b) {
      int scoreA = _calculateQualityScore(_getChannelName(a) ?? '');
      int scoreB = _calculateQualityScore(_getChannelName(b) ?? '');
      return scoreB.compareTo(scoreA); // El de mayor resolución primero
    });

    if (candidates.isNotEmpty) {
      final best = candidates.first;
      final chName = _getChannelName(best) ?? 'Canal';
      final hasHD = chName.toUpperCase().contains('1080') ||
          chName.toUpperCase().contains('FHD') ||
          chName.toUpperCase().contains('HD') ||
          chName.toUpperCase().contains('4K');

      String responseText = wantsSports
          ? "Sintonizando $chName ${hasHD ? 'en máxima resolución HD' : ''} para tu partido."
          : "Sintonizando $chName.";

      return VoiceAssistantResult(
        query: query,
        spokenResponse: responseText,
        targetChannel: best,
        actionType: 'CHANNEL',
      );
    }

    return VoiceAssistantResult(
      query: query,
      spokenResponse: "No encontré un canal coincidente para tu búsqueda.",
      actionType: 'NONE',
    );
  }

  int _calculateQualityScore(String name) {
    final n = name.toUpperCase();
    if (n.contains("4K") || n.contains("UHD")) return 40;
    if (n.contains("1080") || n.contains("FHD")) return 30;
    if (n.contains("720") || n.contains("HD")) return 20;
    return 10;
  }

  String? _getChannelName(dynamic ch) {
    if (ch == null) return null;
    try {
      if (ch is Map) return ch['name']?.toString();
      return ch.name?.toString();
    } catch (_) {
      return ch.toString();
    }
  }

  String? _getChannelGroup(dynamic ch) {
    if (ch == null) return null;
    try {
      if (ch is Map) return (ch['group'] ?? ch['groupTitle'])?.toString();
      return (ch.group ?? ch.groupTitle)?.toString();
    } catch (_) {
      return '';
    }
  }
}