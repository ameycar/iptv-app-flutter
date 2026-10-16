import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final dynamic targetItem;
  final String? searchQuery;
  final String? targetTab;

  AICurationResult({
    required this.action,
    required this.speechResponse,
    this.targetItem,
    this.searchQuery,
    this.targetTab,
  });
}

class AICuratorService {
  static const String _geminiApiKey = "";

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

  static String cleanChannelName(String rawName) {
    String cleaned = rawName;
    final patterns = [
      RegExp(r'(\[|\().*?(\]|\))'),
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

  static String _safeGetName(dynamic item) {
    try {
      if (item == null) return '';
      return (item.name ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static String _safeGetCategory(dynamic item) {
    try {
      if (item == null) return '';
      return (item.groupCategory ?? item.category ?? '').toString();
    } catch (_) {
      return '';
    }
  }

  static Future<AICurationResult> interpretVoiceCommand({
    required String userVoicePrompt,
    required List<dynamic> availableItems,
    required String currentTab,
  }) async {
    try {
      final rawPrompt = userVoicePrompt.trim();
      final cleanPrompt = normalize(rawPrompt);

      if (cleanPrompt.isEmpty || cleanPrompt.length < 2) {
        return AICurationResult(
          action: AIActionType.speakOnly,
          speechResponse: "No logré escucharte con claridad. Intenta de nuevo.",
        );
      }

      final tabClean = normalize(currentTab);
      final String activeSection = (tabClean.contains('peli') || tabClean == 'movies' || tabClean == '1')
          ? 'movies'
          : (tabClean.contains('seri') || tabClean == 'series' || tabClean == '2')
              ? 'series'
              : 'live';

      // 1. Acciones de interfaz
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

      // 2. Si estamos en Películas o Series
      if (activeSection == 'movies' || activeSection == 'series') {
        final isRequestingLive = cleanPrompt.startsWith('canal') ||
            cleanPrompt.contains('en vivo') ||
            cleanPrompt.contains('espn') ||
            cleanPrompt.contains('htv') ||
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

      // 3. Extracción de palabras clave (eliminar verbos, cortesías y calidades)
      String targetQuery = cleanPrompt
          .replaceAll(RegExp(r'^(pon|ponme|coloca|colocame|sintoniza|reproduce|cambia a|cambia al|quiero ver|vamos a ver|busca|buscar)\s+'), '')
          .replaceAll(RegExp(r'^(el canal|un canal|canal de|canal|el partido de|el partido|partido de|partido)\s+'), '')
          .replaceAll(RegExp(r'\b(canal de video|de video|canal|en vivo|en hd|en fhd|en 4k|alta definicion|hd|4k|fhd)\b'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

      if (targetQuery.isEmpty) targetQuery = cleanPrompt;

      // 4. Búsqueda directa por canal específico (ej: HTV, ESPN 2, ESPN 3, etc.)
      dynamic bestMatch;
      double highestScore = 0.0;

      for (final item in availableItems) {
        final rawName = _safeGetName(item);
        final cleanName = cleanChannelName(rawName);

        if (cleanName.isEmpty) continue;

        double score = 0.0;

        // Coincidencia exacta (ej: 'htv' == 'htv')
        if (cleanName == targetQuery) {
          score = 1.0;
        }
        // Coincidencia por prefijo (ej: 'espn' con 'espn 2')
        else if (cleanName.startsWith(targetQuery) || targetQuery.startsWith(cleanName)) {
          score = 0.95;
        }
        // Coincidencia contenida
        else if (cleanName.contains(targetQuery) || targetQuery.contains(cleanName)) {
          score = 0.85;
        } else {
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

        if (score > highestScore) {
          highestScore = score;
          bestMatch = item;
        }
      }

      if (bestMatch != null && highestScore >= 0.5) {
        final name = _safeGetName(bestMatch);
        return AICurationResult(
          action: AIActionType.playChannel,
          targetItem: bestMatch,
          speechResponse: "Sintonizando $name.",
        );
      }

      // 5. Búsqueda por categoría (Música, Deportes, Noticias, etc.)
      final isMusic = targetQuery.contains('musica') || targetQuery.contains('cancion') || targetQuery.contains('video');
      final isSports = targetQuery.contains('deporte') || targetQuery.contains('futbol') || targetQuery.contains('beisbol') || targetQuery.contains('baseball');
      final isNews = targetQuery.contains('noticia') || targetQuery.contains('noticiero');

      for (final item in availableItems) {
        final cat = normalize(_safeGetCategory(item));
        final chName = normalize(_safeGetName(item));

        if (isMusic && (cat.contains('music') || chName.contains('htv') || chName.contains('mtv'))) {
          return AICurationResult(
            action: AIActionType.playChannel,
            targetItem: item,
            speechResponse: "Sintonizando ${_safeGetName(item)}.",
          );
        }
        if (isSports && (cat.contains('deport') || chName.contains('espn') || chName.contains('fox'))) {
          return AICurationResult(
            action: AIActionType.playChannel,
            targetItem: item,
            speechResponse: "Sintonizando ${_safeGetName(item)}.",
          );
        }
        if (isNews && (cat.contains('notic') || chName.contains('24h') || chName.contains('cnn'))) {
          return AICurationResult(
            action: AIActionType.playChannel,
            targetItem: item,
            speechResponse: "Sintonizando ${_safeGetName(item)}.",
          );
        }
      }

      // 6. Fallback seguro de búsqueda
      return AICurationResult(
        action: AIActionType.searchContent,
        searchQuery: targetQuery,
        targetTab: activeSection,
        speechResponse: "Buscando $targetQuery.",
      );
    } catch (e) {
      // Protección total: si algo falla, no congela la app
      return AICurationResult(
        action: AIActionType.searchContent,
        searchQuery: userVoicePrompt,
        targetTab: currentTab,
        speechResponse: "Buscando $userVoicePrompt.",
      );
    }
  }
}
