import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../models/playlist_item.dart';

enum AIActionType {
  playChannel,
  searchContent,
  switchTab,
  openEPG,
  speakOnly,
}

class AICurationResult {
  final AIActionType action;
  final String speechResponse;
  final PlaylistItem? targetItem;
  final String? searchQuery;
  final String? targetTab; // 'live', 'movies', 'series'

  AICurationResult({
    required this.action,
    required this.speechResponse,
    this.targetItem,
    this.searchQuery,
    this.targetTab,
  });
}

class AICuratorService {
  // Clave Gemini opcional: el motor local resuelve el 100% de canales y categorías en < 10ms
  static const String _geminiApiKey = "";

  /// Normaliza texto quitando tildes y caracteres especiales
  static String normalize(String text) {
    var str = text.toLowerCase().trim();
    str = str.replaceAll(RegExp(r'[áàäâ]'), 'a');
    str = str.replaceAll(RegExp(r'[éèëê]'), 'e');
    str = str.replaceAll(RegExp(r'[íìïî]'), 'i');
    str = str.replaceAll(RegExp(r'[óòöô]'), 'o');
    str = str.replaceAll(RegExp(r'[úùüû]'), 'u');
    str = str.replaceAll(RegExp(r'[^a-z0-9\s]'), ' ');
    return str.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Limpia nombres de canales M3U de etiquetas basura
  static String cleanChannelName(String rawName) {
    String cleaned = rawName;
    final patterns = [
      RegExp(r'(\[|\().*?(\]|\))'), // Quita [ES], (FHD), [4K], etc.
      RegExp(r'^[a-z]{2,4}\s*[:|\-]\s*', caseSensitive: false),
      RegExp(r'\|\s*[a-z]{2,5}\s*\|', caseSensitive: false),
      RegExp(r'\b(fhd|hd|sd|4k|2k|uhd|hevc|h265|1080p|720p|50fps|60fps|raw|vip|backup)\b', caseSensitive: false),
      RegExp(r'\b(opcion\s*\d+|server\s*\d+|servidor\s*\d+)\b', caseSensitive: false),
      RegExp(r'\|.*$', caseSensitive: false),
    ];

    for (var pattern in patterns) {
      cleaned = cleaned.replaceAll(pattern, '');
    }

    return normalize(cleaned);
  }

  /// PROCESADOR INTELIGENTE DE COMANDOS DE VOZ EN LENGUAJE NATURAL
  static Future<AICurationResult> interpretVoiceCommand({
    required String userVoicePrompt,
    required List<PlaylistItem> availableItems,
    required String currentTab, // 'live', 'movies', 'series' o 'en vivo', 'peliculas', etc.
  }) async {
    final rawPrompt = userVoicePrompt.trim();
    final cleanPrompt = normalize(rawPrompt);

    if (cleanPrompt.isEmpty || cleanPrompt.length < 2) {
      return AICurationResult(
        action: AIActionType.speakOnly,
        speechResponse: "No logré escucharte con claridad. Intenta de nuevo.",
      );
    }

    // Normalizar pestaña actual de forma infalible
    final tabLower = currentTab.toLowerCase().trim();
    final String activeSection = (tabLower.contains('peli') || tabLower == 'movies' || tabLower == '1')
        ? 'movies'
        : (tabLower.contains('seri') || tabLower == 'series' || tabLower == '2')
            ? 'series'
            : 'live';

    // ========================================================================
    // 1. NAVEGACIÓN Y ACCIONES DEL SISTEMA
    // ========================================================================

    // A) Guía de canales / EPG
    if (cleanPrompt.contains('guia') ||
        cleanPrompt.contains('epg') ||
        cleanPrompt.contains('programacion') ||
        cleanPrompt.contains('horario') ||
        cleanPrompt.contains('que estan dando') ||
        cleanPrompt.contains('que dan')) {
      return AICurationResult(
        action: AIActionType.openEPG,
        speechResponse: "Abriendo la guía de programación.",
      );
    }

    // B) Cambio a Películas
    if (cleanPrompt == 'peliculas' ||
        cleanPrompt.contains('ir a peliculas') ||
        cleanPrompt.contains('ver peliculas') ||
        cleanPrompt.contains('seccion de peliculas')) {
      return AICurationResult(
        action: AIActionType.switchTab,
        targetTab: 'movies',
        speechResponse: "Cambiando a Películas.",
      );
    }

    // C) Cambio a Series
    if (cleanPrompt == 'series' ||
        cleanPrompt.contains('ir a series') ||
        cleanPrompt.contains('ver series') ||
        cleanPrompt.contains('seccion de series')) {
      return AICurationResult(
        action: AIActionType.switchTab,
        targetTab: 'series',
        speechResponse: "Cambiando a Series.",
      );
    }

    // D) Cambio a Canales en Vivo
    if (cleanPrompt == 'en vivo' ||
        cleanPrompt.contains('ir a en vivo') ||
        cleanPrompt.contains('ver canales') ||
        cleanPrompt.contains('television en vivo') ||
        cleanPrompt.contains('tele en vivo')) {
      return AICurationResult(
        action: AIActionType.switchTab,
        targetTab: 'live',
        speechResponse: "Cambiando a Canales en Vivo.",
      );
    }

    // ========================================================================
    // 2. CONTEXTO VOD: SI EL USUARIO ESTÁ EN PELÍCULAS O SERIES
    // ========================================================================
    if (activeSection == 'movies' || activeSection == 'series') {
      final isRequestingLive = cleanPrompt.startsWith('canal') ||
          cleanPrompt.contains('en vivo') ||
          cleanPrompt.contains('espn') ||
          cleanPrompt.contains('fox sports') ||
          cleanPrompt.contains('noticiero');

      if (!isRequestingLive) {
        String searchQuery = cleanPrompt
            .replaceAll(RegExp(r'^(busca|buscar|encuentra|ver|quiero ver|pelicula|peliculas|serie|series|de)\s+'), '')
            .trim();

        if (searchQuery.isEmpty) searchQuery = cleanPrompt;

        return AICurationResult(
          action: AIActionType.searchContent,
          searchQuery: searchQuery,
          targetTab: activeSection,
          speechResponse: "Buscando $searchQuery en ${activeSection == 'movies' ? 'Películas' : 'Series'}.",
        );
      }
    }

    // ========================================================================
    // 3. EXTRACCIÓN DE PARÁMETROS: CALIDAD Y LIMPIEZA
    // ========================================================================
    final bool wantsHd = cleanPrompt.contains('hd') ||
        cleanPrompt.contains('fhd') ||
        cleanPrompt.contains('alta definicion') ||
        cleanPrompt.contains('1080');
    final bool wants4k = cleanPrompt.contains('4k') || cleanPrompt.contains('uhd');

    // Quitar verbos y frases de cortesía
    String targetQuery = cleanPrompt
        .replaceAll(RegExp(r'^(pon|ponme|coloca|colocame|sintoniza|reproduce|cambia a|cambia al|quiero ver|vamos a ver|busca|buscar)\s+'), '')
        .replaceAll(RegExp(r'^(el canal|un canal|canal de|canal|el partido de|el partido|partido de|partido)\s+'), '')
        .replaceAll(RegExp(r'\b(en hd|en fhd|en 4k|en alta definicion|hd|4k|fhd)\b'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    if (targetQuery.isEmpty) targetQuery = cleanPrompt;

    // ========================================================================
    // 4. BÚSQUEDA SEMÁNTICA POR CATEGORÍAS (MÚSICA, DEPORTES, NOTICIAS, ETC.)
    // ========================================================================
    final isMusicIntent = targetQuery.contains('musica') || targetQuery.contains('musical') || targetQuery.contains('cancion');
    final isSportsIntent = targetQuery.contains('deporte') || targetQuery.contains('futbol') || targetQuery.contains('soccer');
    final isNewsIntent = targetQuery.contains('noticia') || targetQuery.contains('informativo') || targetQuery.contains('noticiero');
    final isKidsIntent = targetQuery.contains('infantil') || targetQuery.contains('nino') || targetQuery.contains('dibujito');

    PlaylistItem? bestCategoryMatch;

    if (isMusicIntent || isSportsIntent || isNewsIntent || isKidsIntent) {
      for (final item in availableItems) {
        final cat = normalize(item.category);
        final chName = normalize(item.name);

        bool matches = false;
        if (isMusicIntent && (cat.contains('music') || chName.contains('htv') || chName.contains('mtv') || chName.contains('vh1'))) {
          matches = true;
        } else if (isSportsIntent && (cat.contains('deport') || cat.contains('sport') || chName.contains('espn') || chName.contains('fox'))) {
          matches = true;
        } else if (isNewsIntent && (cat.contains('noticia') || cat.contains('news') || chName.contains('24h') || chName.contains('cnn'))) {
          matches = true;
        } else if (isKidsIntent && (cat.contains('infantil') || cat.contains('kid') || chName.contains('disney') || chName.contains('cartoon'))) {
          matches = true;
        }

        if (matches) {
          // Si pidió HD, priorizar el que contenga HD en el nombre original
          if ((wantsHd || wants4k) && (item.originalName.toUpperCase().contains('HD') || item.originalName.toUpperCase().contains('FHD'))) {
            bestCategoryMatch = item;
            break;
          }
          bestCategoryMatch ??= item;
        }
      }

      if (bestCategoryMatch != null) {
        return AICurationResult(
          action: AIActionType.playChannel,
          targetItem: bestCategoryMatch,
          speechResponse: "Sintonizando ${bestCategoryMatch.name}.",
        );
      }
    }

    // ========================================================================
    // 5. BÚSQUEDA DIRECTA Y DIFUSA EN CANALES (< 5 ms)
    // ========================================================================
    PlaylistItem? bestMatch;
    double highestScore = 0.0;

    for (final item in availableItems) {
      final cleanName = cleanChannelName(item.name);
      final rawUpper = item.originalName.toUpperCase();
      double score = 0.0;

      // Coincidencia exacta
      if (cleanName == targetQuery) {
        score = 1.0;
      }
      // Coincidencia por prefijo (ej: "espn" hace match con "espn 2")
      else if (cleanName.startsWith(targetQuery) || targetQuery.startsWith(cleanName)) {
        score = 0.95;
      }
      // Coincidencia contenida
      else if (cleanName.contains(targetQuery) || targetQuery.contains(cleanName)) {
        score = 0.85;
      } else {
        // Coincidencia por tokens
        final queryTokens = targetQuery.split(' ');
        int matchedTokens = 0;
        for (final token in queryTokens) {
          if (token.length >= 2 && cleanName.contains(token)) {
            matchedTokens++;
          }
        }
        if (queryTokens.isNotEmpty) {
          score = (matchedTokens / queryTokens.length) * 0.8;
        }
      }

      // Bonus si el usuario pidió HD/4K y el canal lo incluye
      if (wantsHd && (rawUpper.contains('HD') || rawUpper.contains('1080') || rawUpper.contains('FHD'))) {
        score += 0.08;
      }
      if (wants4k && (rawUpper.contains('4K') || rawUpper.contains('UHD'))) {
        score += 0.12;
      }

      if (score > highestScore) {
        highestScore = score;
        bestMatch = item;
      }
    }

    if (bestMatch != null && highestScore >= 0.55) {
      return AICurationResult(
        action: AIActionType.playChannel,
        targetItem: bestMatch,
        speechResponse: "Sintonizando ${bestMatch.name}.",
      );
    }

    // ========================================================================
    // 6. GEMINI EN LA NUBE (Opcional, si hay API Key)
    // ========================================================================
    if (_geminiApiKey.isNotEmpty) {
      try {
        final geminiResult = await _queryGeminiAI(rawPrompt, activeSection, availableItems);
        if (geminiResult != null) return geminiResult;
      } catch (e) {
        print("Error Gemini Cloud: $e");
      }
    }

    // ========================================================================
    // 7. FALLBACK SEGURO: BÚSQUEDA GENERAL
    // ========================================================================
    return AICurationResult(
      action: AIActionType.searchContent,
      searchQuery: targetQuery,
      targetTab: activeSection,
      speechResponse: "Buscando $targetQuery.",
    );
  }

  /// Conexión HTTP nativa con Google Gemini REST API
  static Future<AICurationResult?> _queryGeminiAI(
    String prompt,
    String currentTab,
    List<PlaylistItem> items,
  ) async {
    final sampleTitles = items.take(40).map((e) => cleanChannelName(e.name)).join(', ');
    final systemPrompt = """
Eres el asistente de voz IA de la app AMEYCAR TV.
Pestaña actual: $currentTab.
Voz del usuario: "$prompt".
Canales de muestra: [$sampleTitles].

Responde ESTRICTAMENTE con un JSON sin formato markdown:
{
  "action": "play" | "search" | "epg" | "tab",
  "target": "nombre o termino de busqueda",
  "tab": "live" | "movies" | "series",
  "speech": "frase corta estilo Alexa"
}
""";

    final client = HttpClient();
    final request = await client.postUrl(Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_geminiApiKey',
    ));
    request.headers.set('Content-Type', 'application/json');
    request.add(utf8.encode(jsonEncode({
      "contents": [
        {
          "parts": [{"text": systemPrompt}]
        }
      ]
    })));

    final response = await request.close().timeout(const Duration(milliseconds: 1200));
    if (response.statusCode == 200) {
      final responseBody = await response.transform(utf8.decoder).join();
      final json = jsonDecode(responseBody);
      final rawText = json['candidates'][0]['content']['parts'][0]['text'] as String;
      final cleanJsonText = rawText.replaceAll('```json', '').replaceAll('```', '').trim();
      final data = jsonDecode(cleanJsonText);

      final actionStr = data['action'] ?? 'search';
      final speech = data['speech'] ?? "Entendido.";
      final target = data['target'] ?? prompt;
      final tab = data['tab'] ?? currentTab;

      if (actionStr == 'epg') {
        return AICurationResult(action: AIActionType.openEPG, speechResponse: speech);
      } else if (actionStr == 'tab') {
        return AICurationResult(action: AIActionType.switchTab, targetTab: tab, speechResponse: speech);
      } else if (actionStr == 'play') {
        final match = items.firstWhere(
          (i) => cleanChannelName(i.name).contains(cleanChannelName(target)),
          orElse: () => items.first,
        );
        return AICurationResult(action: AIActionType.playChannel, targetItem: match, speechResponse: speech);
      } else {
        return AICurationResult(action: AIActionType.searchContent, searchQuery: target, targetTab: tab, speechResponse: speech);
      }
    }
    return null;
  }
}
