import '../models/playlist_item.dart';

enum VoiceIntentType {
  playChannel,
  switchTab,
  openEPG,
  searchContent,
  unknown,
}

class VoiceIntentResult {
  final VoiceIntentType type;
  final String text;
  final dynamic targetChannel;
  final String? targetTab; // 'live', 'movies', 'series'
  final String? searchQuery;
  final String spokenResponse;

  VoiceIntentResult({
    required this.type,
    required this.text,
    this.targetChannel,
    this.targetTab,
    this.searchQuery,
    required this.spokenResponse,
  });
}

class VoiceNLPService {
  /// Normaliza texto quitando tildes, símbolos raros y minúsculas
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

  /// Limpia nombres de canales M3U quitando etiquetas basura (FHD, 4K, 1080p, prefijos de país)
  static String cleanChannelName(String rawName) {
    var name = rawName.toLowerCase();
    // Quitar prefijos de país como [es], [ar], [mx], |latam|, es:, ar:
    name = name.replaceAll(RegExp(r'(\[|\().*?(\]|\))'), ' ');
    name = name.replaceAll(RegExp(r'^[a-z]{2,4}\s*[:|\-]\s*'), ' ');
    name = name.replaceAll(RegExp(r'\|\s*[a-z]{2,5}\s*\|'), ' ');
    // Quitar calidades y codecs
    name = name.replaceAll(RegExp(r'\b(fhd|hd|sd|4k|2k|uhd|hevc|h265|1080p|720p|50fps|60fps|raw|vip)\b'), ' ');
    // Quitar palabras de servidor
    name = name.replaceAll(RegExp(r'\b(opcion|servidor|server|latam|espana|mexico|colombia|argentina)\b'), ' ');
    return normalize(name);
  }

  /// Procesa cualquier comando en lenguaje natural y determina la acción en milisegundos
  static VoiceIntentResult processCommand(
    String spokenText,
    List<dynamic> channels, {
    String currentSection = 'LIVE',
  }) {
    final cleanInput = normalize(spokenText);

    if (cleanInput.isEmpty) {
      return VoiceIntentResult(
        type: VoiceIntentType.unknown,
        text: spokenText,
        spokenResponse: "No logré escucharte con claridad.",
      );
    }

    // 1. Detección Inteligente de EPG / Guía de Programación
    if (cleanInput.contains('guia') ||
        cleanInput.contains('epg') ||
        cleanInput.contains('programacion') ||
        cleanInput.contains('horario') ||
        cleanInput.contains('que estan dando') ||
        cleanInput.contains('que dan')) {
      return VoiceIntentResult(
        type: VoiceIntentType.openEPG,
        text: spokenText,
        spokenResponse: "Abriendo la guía de programación.",
      );
    }

    // 2. Cambio de Pestañas / Secciones
    if (cleanInput.contains('pelicula') || cleanInput.contains('cine') || cleanInput.contains('peliculas')) {
      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        text: spokenText,
        targetTab: 'movies',
        searchQuery: _extractSearchTerm(cleanInput, ['pelicula', 'peliculas', 'cine', 'ver']),
        spokenResponse: "Cambiando a Películas.",
      );
    }

    if (cleanInput.contains('serie') || cleanInput.contains('series') || cleanInput.contains('temporada')) {
      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        text: spokenText,
        targetTab: 'series',
        searchQuery: _extractSearchTerm(cleanInput, ['serie', 'series', 'temporada', 'ver']),
        spokenResponse: "Cambiando a Series.",
      );
    }

    if (cleanInput.contains('en vivo') || cleanInput.contains('television') || cleanInput.contains('tv en directo')) {
      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        text: spokenText,
        targetTab: 'live',
        spokenResponse: "Cambiando a Canales en Vivo.",
      );
    }

    // 3. Extracción de palabras clave de búsqueda para Canales
    // Quita frases de cortesía como "ponme", "sintoniza", "quiero ver", "canal"
    String targetQuery = cleanInput
        .replaceAll(RegExp(r'^(pon|ponme|coloca|sintoniza|reproduce|cambia a|cambia al|quiero ver|vamos a ver|busca|buscar)\s+'), '')
        .replaceAll(RegExp(r'^(canal|el canal)\s+'), '')
        .trim();

    if (targetQuery.isEmpty) targetQuery = cleanInput;

    // 4. Búsqueda Inteligente difusa en la lista de canales
    dynamic bestMatch;
    double highestScore = 0.0;

    for (final ch in channels) {
      final rawName = (ch is PlaylistItem) ? ch.name : (ch.name ?? ch['name'] ?? '').toString();
      final cleanedChannel = cleanChannelName(rawName);

      // Coincidencia exacta o contenida directa (máxima prioridad)
      if (cleanedChannel == targetQuery) {
        bestMatch = ch;
        highestScore = 1.0;
        break;
      }

      if (cleanedChannel.contains(targetQuery) || targetQuery.contains(cleanedChannel)) {
        double score = 0.85;
        // Si además empieza por la palabra buscada (ej: "espn 2" empieza con "espn")
        if (cleanedChannel.startsWith(targetQuery)) score = 0.95;

        if (score > highestScore) {
          highestScore = score;
          bestMatch = ch;
        }
      } else {
        // Coincidencia por tokens / palabras
        final inputTokens = targetQuery.split(' ');
        int matchedTokens = 0;
        for (final token in inputTokens) {
          if (token.length >= 2 && cleanedChannel.contains(token)) {
            matchedTokens++;
          }
        }

        if (inputTokens.isNotEmpty) {
          double tokenScore = matchedTokens / inputTokens.length;
          if (tokenScore > 0.6 && tokenScore > highestScore) {
            highestScore = tokenScore;
            bestMatch = ch;
          }
        }
      }
    }

    // Si encontramos un canal con buen puntaje, sintonizarlo
    if (bestMatch != null && highestScore >= 0.6) {
      final chName = (bestMatch is PlaylistItem) ? bestMatch.name : (bestMatch.name ?? bestMatch['name'] ?? 'Canal');
      return VoiceIntentResult(
        type: VoiceIntentType.playChannel,
        text: spokenText,
        targetChannel: bestMatch,
        spokenResponse: "Sintonizando $chName.",
      );
    }

    // 5. Si estás en la sección de Películas o Series, convertir en búsqueda de contenido
    if (currentSection == 'PELICULAS' || currentSection == 'SERIES') {
      return VoiceIntentResult(
        type: VoiceIntentType.searchContent,
        text: spokenText,
        searchQuery: targetQuery,
        spokenResponse: "Buscando $targetQuery en $currentSection.",
      );
    }

    // 6. Si no encontró canal pero hay una consulta, mandar a buscar
    return VoiceIntentResult(
      type: VoiceIntentType.searchContent,
      text: spokenText,
      searchQuery: targetQuery,
      spokenResponse: "Buscando $targetQuery.",
    );
  }

  static String _extractSearchTerm(String text, List<String> removeWords) {
    String clean = text;
    for (final w in removeWords) {
      clean = clean.replaceAll(w, '');
    }
    return clean.trim();
  }
}