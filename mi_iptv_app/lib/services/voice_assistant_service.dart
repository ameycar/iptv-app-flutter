import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Modelo que encapsula el resultado enriquecido de la orden de voz
class VoiceCommandResult {
  final String actionType; // 'CHANNEL', 'SECTION', 'EPG', 'SEARCH', 'NONE'
  final String spokenResponse;
  final dynamic targetChannel;
  final String targetSection; // 'LIVE', 'PELICULAS', 'SERIES'
  final String? searchQuery;
  final String? genre;
  final bool isRecent;
  final String? quality;

  VoiceCommandResult({
    required this.actionType,
    required this.spokenResponse,
    this.targetChannel,
    this.targetSection = '',
    this.searchQuery,
    this.genre,
    this.isRecent = false,
    this.quality,
  });
}

class VoiceAssistantService {
  static final VoiceAssistantService _instance = VoiceAssistantService._internal();
  factory VoiceAssistantService() => _instance;

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  bool _isSpeechInitialized = false;
  bool _isSpeaking = false;
  
  // Memoria del usuario (nombre y preferencias)
  String _userName = '';
  String get userName => _userName;

  void setUserName(String name) {
    _userName = name.trim();
  }

  VoiceAssistantService._internal() {
    _initTts();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setLanguage("es-ES");
      await _tts.setPitch(1.0);
      await _tts.setSpeechRate(0.52);

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

  /// Pronuncia una respuesta con entonación natural
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

  /// Sugerencias contextuales según la pantalla donde esté el usuario
  List<Map<String, String>> getSuggestionsForContext(String currentSection) {
    final sec = currentSection.toUpperCase();

    if (sec.contains('PELICULA') || sec.contains('MOVIE')) {
      return [
        {'label': '🍿 Terror más reciente', 'query': 'película de terror la más actual'},
        {'label': '💥 Acción en 4K', 'query': 'películas de acción en 4k'},
        {'label': '🎭 Comedias de estreno', 'query': 'comedias de estreno'},
        {'label': '🚀 Ciencia Ficción', 'query': 'película de ciencia ficción'},
      ];
    } else if (sec.contains('SERIE')) {
      return [
        {'label': '📺 Series de Suspenso', 'query': 'series de suspenso'},
        {'label': '🔥 Estrenos de Series', 'query': 'series de estreno'},
        {'label': '🍿 Animación y Anime', 'query': 'series de animación'},
      ];
    } else {
      return [
        {'label': '⚽ Deportes en Vivo', 'query': 'ver partido de fútbol en HD'},
        {'label': '📰 Canales de Noticias', 'query': 'noticias en vivo'},
        {'label': '📅 Guía de Canales (EPG)', 'query': 'abrir guía de canales'},
        {'label': '🎶 Música en Directo', 'query': 'canales de música'},
      ];
    }
  }

  /// Procesa la orden de voz con entendimiento de oraciones y contexto
  VoiceCommandResult processVoiceCommand({
    required String query,
    required List<dynamic> channels,
    dynamic currentChannel,
    String currentSection = 'LIVE',
  }) {
    final cleanQuery = _normalizeText(query);
    final greeting = _userName.isNotEmpty ? '$_userName, ' : '';

    if (cleanQuery.isEmpty) {
      return VoiceCommandResult(
        actionType: 'NONE',
        spokenResponse: "¿En qué te puedo colaborar hoy?",
      );
    }

    // Guardar nombre si el usuario dice "me llamo X" o "mi nombre es X"
    final nameRegex = RegExp(r'\b(me llamo|mi nombre es|soy)\s+([a-zA-ZáéíóúÁÉÍÓÚñÑ]+)\b');
    final nameMatch = nameRegex.firstMatch(query);
    if (nameMatch != null && nameMatch.groupCount >= 2) {
      final detectedName = nameMatch.group(2)!;
      setUserName(detectedName);
      return VoiceCommandResult(
        actionType: 'NONE',
        spokenResponse: "¡Mucho gusto $detectedName! He guardado tu nombre en mi memoria. ¿Qué te gustaría ver hoy?",
      );
    }

    // 1. Detección de Guía EPG
    if (cleanQuery.contains("guia") ||
        cleanQuery.contains("epg") ||
        cleanQuery.contains("programacion") ||
        cleanQuery.contains("cartelera") ||
        cleanQuery.contains("horario")) {
      return VoiceCommandResult(
        actionType: 'EPG',
        spokenResponse: "${greeting}abriendo la guía electrónica de canales.",
      );
    }

    // 2. Extracción de filtros (calidad, recencia, género)
    String? quality;
    if (cleanQuery.contains("4k")) quality = "4K";
    else if (cleanQuery.contains("fhd")) quality = "FHD";
    else if (cleanQuery.contains("hd")) quality = "HD";

    final isRecent = cleanQuery.contains("mas actual") ||
        cleanQuery.contains("mas reciente") ||
        cleanQuery.contains("estreno") ||
        cleanQuery.contains("estrenos") ||
        cleanQuery.contains("nueva") ||
        cleanQuery.contains("reciente");

    const genres = [
      'terror', 'miedo', 'accion', 'comedia', 'drama', 'suspenso',
      'animacion', 'infantil', 'ciencia ficcion', 'fantasia', 'romance',
      'aventura', 'documental'
    ];
    String? detectedGenre;
    for (final g in genres) {
      if (cleanQuery.contains(g)) {
        detectedGenre = (g == 'miedo') ? 'terror' : g;
        break;
      }
    }

    // 3. Comando de Películas o Series
    final isMovie = cleanQuery.contains("pelicula") ||
        cleanQuery.contains("peliculas") ||
        cleanQuery.contains("cine") ||
        cleanQuery.contains("film") ||
        (currentSection.toUpperCase().contains("PELICULA") && detectedGenre != null);

    final isSeries = cleanQuery.contains("serie") ||
        cleanQuery.contains("series") ||
        cleanQuery.contains("temporada") ||
        (currentSection.toUpperCase().contains("SERIE") && detectedGenre != null);

    if (isMovie) {
      String response = "${greeting}buscando películas ";
      if (detectedGenre != null) response += "de $detectedGenre ";
      if (isRecent) response += "más actuales ";
      if (quality != null) response += "en $quality ";

      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'PELICULAS',
        genre: detectedGenre,
        isRecent: isRecent,
        quality: quality,
        searchQuery: detectedGenre ?? (isRecent ? 'estreno' : null),
        spokenResponse: response.trim(),
      );
    }

    if (isSeries) {
      String response = "${greeting}mostrando series ";
      if (detectedGenre != null) response += "de $detectedGenre ";

      return VoiceCommandResult(
        actionType: 'SECTION',
        targetSection: 'SERIES',
        genre: detectedGenre,
        isRecent: isRecent,
        quality: quality,
        searchQuery: detectedGenre,
        spokenResponse: response.trim(),
      );
    }

    // 4. Comando de Deportes / Partidos (SOLO si NO estamos en Películas o Series)
    final isSports = cleanQuery.contains("deporte") ||
        cleanQuery.contains("partido") ||
        cleanQuery.contains("futbol") ||
        cleanQuery.contains("soccer") ||
        cleanQuery.contains("champions") ||
        cleanQuery.contains("liga");

    if (isSports && !currentSection.toUpperCase().contains("PELICULA")) {
      dynamic sportsChannel;
      final sportsKeywords = ["espn", "fox sports", "directv sports", "dsports", "tyc", "gol", "tnt sports", "deportes"];

      for (var kw in sportsKeywords) {
        sportsChannel = channels.firstWhere(
          (c) {
            final name = _normalizeText(c['name']?.toString() ?? '');
            if (quality != null && !name.contains(quality.toLowerCase())) return false;
            return name.contains(kw);
          },
          orElse: () => null,
        );
        if (sportsChannel != null) break;
      }

      // Si no encontró con la calidad específica, buscar el canal normal
      if (sportsChannel == null) {
        for (var kw in sportsKeywords) {
          sportsChannel = channels.firstWhere(
            (c) => _normalizeText(c['name']?.toString() ?? '').contains(kw),
            orElse: () => null,
          );
          if (sportsChannel != null) break;
        }
      }

      if (sportsChannel != null) {
        final name = sportsChannel['name'] ?? 'Deportes';
        return VoiceCommandResult(
          actionType: 'CHANNEL',
          targetChannel: sportsChannel,
          spokenResponse: "${greeting}sintonizando $name para ver los eventos deportivos.",
        );
      }
    }

    // 5. Búsqueda de Canal en Vivo por Nombre
    String targetName = cleanQuery
        .replaceAll(RegExp(r'\b(pon|poner|ver|canal|cambiar a|cambia a|sintoniza|sintonizar|quiero ver|reproducir)\b'), '')
        .trim();

    if (targetName.isEmpty) targetName = cleanQuery;

    dynamic matchedChannel;

    // A. Búsqueda exacta
    matchedChannel = channels.firstWhere(
      (c) => _normalizeText(c['name']?.toString() ?? '') == targetName,
      orElse: () => null,
    );

    // B. Búsqueda contenida
    if (matchedChannel == null) {
      matchedChannel = channels.firstWhere(
        (c) => _normalizeText(c['name']?.toString() ?? '').contains(targetName),
        orElse: () => null,
      );
    }

    // C. Búsqueda por tokens
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
        spokenResponse: "${greeting}sintonizando $name.",
      );
    }

    // 6. Si no es canal, búsqueda por texto en la sección actual
    return VoiceCommandResult(
      actionType: 'SEARCH',
      searchQuery: targetName,
      targetSection: currentSection,
      spokenResponse: "${greeting}buscando $targetName.",
    );
  }

  /// Limpia tildes, mayúsculas y caracteres especiales
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