import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

class VoiceAssistantResult {
  final String query;
  final String spokenResponse;
  final dynamic targetChannel;
  final String actionType; // 'CHANNEL', 'EPG', 'VOL_UP', 'VOL_DOWN', 'NAV_MOVIES', 'NAV_SERIES', 'NAV_LIVE', 'NONE'

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
      await _tts.setSpeechRate(0.5); // Velocidad natural y clara estilo Alexa
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

  /// Iniciar escucha activa en el micrófono con reintentos y tolerancia
  Future<bool> startListening({
    required Function(String currentWords) onWordsRecognized,
    required Function() onListeningComplete,
  }) async {
    await init();

    // 1. Solicitar permiso de micrófono nativo
    var status = await Permission.microphone.status;
    if (!status.isGranted) {
      status = await Permission.microphone.request();
      if (!status.isGranted) {
        await speak("Necesito permiso de micrófono para escucharte.");
        return false;
      }
    }

    // 2. Iniciar motor de reconocimiento de voz
    bool available = await _speech.initialize(
      onError: (val) {
        debugPrint('Error de voz: ${val.errorMsg}');
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
          if (val.hasConfidenceRating && val.confidence > 0.3 && val.finalResult) {
            isListening = false;
            onListeningComplete();
          }
        },
      );
      return true;
    } else {
      await speak("El reconocimiento de voz no está disponible en este momento.");
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

  /// MOTOR DE INTELIGENCIA, ANÁLISIS DE INTENCIÓN Y FILTRO DE CALIDAD HD
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

    // 1. Consulta sobre la programación (Guía interactiva / EPG / Alarma)
    if (lower.contains("qué están dando") ||
        lower.contains("que dan") ||
        lower.contains("programación") ||
        lower.contains("programacion") ||
        lower.contains("horario") ||
        lower.contains("guía") ||
        lower.contains("guia") ||
        lower.contains("epg")) {
      final name = _getChannelName(currentChannel) ?? "este canal";
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Abriendo la guía interactiva con la programación de $name.",
        actionType: 'EPG',
      );
    }

    // 2. Control de volumen
    if (lower.contains("subir volumen") || lower.contains("sube volumen") || lower.contains("más volumen") || lower.contains("mas volumen")) {
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

    // 3. Navegación entre Pestañas: Películas, Series, En Vivo
    if (lower.contains("sección películas") ||
        lower.contains("seccion peliculas") ||
        lower.contains("ver películas") ||
        lower.contains("ver peliculas") ||
        lower.contains("abrir películas") ||
        lower.contains("abrir peliculas") ||
        lower == "películas" ||
        lower == "peliculas") {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Abriendo el catálogo de películas.",
        actionType: 'NAV_MOVIES',
      );
    }

    if (lower.contains("sección series") ||
        lower.contains("seccion series") ||
        lower.contains("ver series") ||
        lower.contains("abrir series") ||
        lower == "series") {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Abriendo el catálogo de series.",
        actionType: 'NAV_SERIES',
      );
    }

    if (lower.contains("televisión en vivo") ||
        lower.contains("canales en vivo") ||
        lower.contains("en vivo") ||
        lower == "tv") {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "Regresando a televisión en vivo.",
        actionType: 'NAV_LIVE',
      );
    }

    // 4. Intención Infantil / Dibujos Animados (ej: Peppa Pig, Cartoon, Disney)
    bool wantsKids = lower.contains("pepa") ||
        lower.contains("peppa") ||
        lower.contains("pig") ||
        lower.contains("infantil") ||
        lower.contains("dibujo") ||
        lower.contains("niño") ||
        lower.contains("kids") ||
        lower.contains("cartoon") ||
        lower.contains("disney") ||
        lower.contains("nick") ||
        lower.contains("boing");

    // 5. Intención de deportes / fútbol / partidos
    bool wantsSports = lower.contains("partido") ||
        lower.contains("futbol") ||
        lower.contains("fútbol") ||
        lower.contains("deporte") ||
        lower.contains("champions") ||
        lower.contains("liga") ||
        lower.contains("copa") ||
        lower.contains("madrid") ||
        lower.contains("barcelona");

    List<dynamic> candidates = [];

    if (wantsKids) {
      // Buscar canales infantiles o que contengan los términos
      candidates = channels.where((ch) {
        final name = (_getChannelName(ch) ?? '').toLowerCase();
        final group = (_getChannelGroup(ch) ?? '').toLowerCase();
        return group.contains('infantil') ||
            group.contains('kids') ||
            name.contains('pep') ||
            name.contains('kids') ||
            name.contains('disney') ||
            name.contains('cartoon') ||
            name.contains('nick') ||
            name.contains('boing') ||
            name.contains('junior');
      }).toList();
    } else if (wantsSports) {
      candidates = channels.where((ch) {
        final name = (_getChannelName(ch) ?? '').toLowerCase();
        final group = (_getChannelGroup(ch) ?? '').toLowerCase();
        return group.contains('deport') ||
            group.contains('sport') ||
            group.contains('futbol') ||
            name.contains('espn') ||
            name.contains('fox') ||
            name.contains('tyc') ||
            name.contains('win') ||
            name.contains('directv') ||
            name.contains('liga') ||
            name.contains('sport') ||
            name.contains('dazn');
      }).toList();
    } else {
      // Limpiar términos de relleno para buscar canal por nombre
      final cleanKeyword = lower
          .replaceAll(RegExp(r'\b(pon|poner|canal|busca|buscar|el|la|los|las|un|una|en|hd|quiero|ver|reproduce|sintoniza|por favor)\b'), '')
          .trim();

      if (cleanKeyword.isNotEmpty) {
        candidates = channels.where((ch) {
          final name = (_getChannelName(ch) ?? '').toLowerCase();
          final group = (_getChannelGroup(ch) ?? '').toLowerCase();
          return name.contains(cleanKeyword) || group.contains(cleanKeyword);
        }).toList();
      }
    }

    // 6. Si no encontramos nada con filtro específico, no cambiamos a ciegas a cualquier canal
    if (candidates.isEmpty) {
      return VoiceAssistantResult(
        query: query,
        spokenResponse: "No encontré un canal para '$query'. Prueba diciendo el nombre del canal o deporte.",
        actionType: 'NONE',
      );
    }

    // 7. RANKING POR CALIDAD Y RESOLUCIÓN HD (4K > 1080p FHD > 720p HD)
    candidates.sort((a, b) {
      int scoreA = _calculateQualityScore(a, lower);
      int scoreB = _calculateQualityScore(b, lower);
      return scoreB.compareTo(scoreA); // Mayor calidad primero
    });

    final best = candidates.first;
    final chName = _getChannelName(best) ?? 'Canal';
    final res = _getChannelResolution(best);

    String responseText = wantsSports
        ? "Sintonizando $chName en $res para el partido."
        : wantsKids
            ? "Sintonizando $chName para los niños."
            : "Sintonizando $chName en $res.";

    return VoiceAssistantResult(
      query: query,
      spokenResponse: responseText,
      targetChannel: best,
      actionType: 'CHANNEL',
    );
  }

  int _calculateQualityScore(dynamic ch, String userQuery) {
    int score = 0;
    final name = (_getChannelName(ch) ?? '').toUpperCase();
    final res = _getChannelResolution(ch).toUpperCase();
    final combined = '$name $res';

    // Prioridad por Calidad de Resolución
    if (combined.contains("4K") || combined.contains("UHD")) {
      score += 50;
    } else if (combined.contains("1080") || combined.contains("FHD")) {
      score += 35;
    } else if (combined.contains("720") || combined.contains("HD")) {
      score += 20;
    } else {
      score += 10;
    }

    // Coincidencia exacta de nombre
    final nameLower = name.toLowerCase();
    if (userQuery.contains(nameLower) && nameLower.isNotEmpty) {
      score += 40;
    }

    return score;
  }

  String _getChannelResolution(dynamic ch) {
    if (ch == null) return '1080p FHD';
    try {
      if (ch is Map && ch['resolution'] != null) return ch['resolution'].toString();
      if (ch.resolution != null) return ch.resolution.toString();
    } catch (_) {}

    final name = (_getChannelName(ch) ?? '').toUpperCase();
    if (name.contains('4K') || name.contains('UHD')) return '4K UHD';
    if (name.contains('720') || name.contains('HD')) return '720p HD';
    return '1080p FHD';
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
      if (ch is Map) return (ch['groupCategory'] ?? ch['group'] ?? ch['groupTitle'])?.toString();
      return (ch.groupCategory ?? ch.group ?? ch.groupTitle)?.toString();
    } catch (_) {
      return '';
    }
  }
}