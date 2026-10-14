import '../models/playlist_item.dart';

enum VoiceIntentType {
  playChannel,
  switchTab,
  openEPG,
  searchContent,
  filterGenre,
  filterRecent,
  unknown,
}

class VoiceIntentResult {
  final VoiceIntentType type;
  final String text;
  final PlaylistItem? targetChannel;
  final String? targetTab; // 'live', 'movies', 'series'
  final String? searchQuery;
  final String? genre;
  final bool isRecent;
  final String? quality; // '4k', 'hd', 'fhd'
  final String? sportsMatch;

  VoiceIntentResult({
    required this.type,
    required this.text,
    this.targetChannel,
    this.targetTab,
    this.searchQuery,
    this.genre,
    this.isRecent = false,
    this.quality,
    this.sportsMatch,
  });
}

class VoiceNLPService {
  /// Normaliza texto quitando tildes, signos y convirtiendo a minúsculas
  static String normalize(String text) {
    var str = text.toLowerCase().trim();
    str = str.replaceAll(RegExp(r'[áàäâ]'), 'a');
    str = str.replaceAll(RegExp(r'[éèëê]'), 'e');
    str = str.replaceAll(RegExp(r'[íìïî]'), 'i');
    str = str.replaceAll(RegExp(r'[óòöô]'), 'o');
    str = str.replaceAll(RegExp(r'[úùüû]'), 'u');
    str = str.replaceAll(RegExp(r'ñ'), 'n');
    str = str.replaceAll(RegExp(r'[^\w\s]'), ' ');
    str = str.replaceAll(RegExp(r'\s+'), ' ');
    return str.trim();
  }

  /// Calcula similitud entre dos palabras (0.0 a 1.0)
  static double calculateSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.contains(b) || b.contains(a)) return 0.85;

    final aBigrams = <String>{};
    for (int i = 0; i < a.length - 1; i++) {
      aBigrams.add(a.substring(i, i + 2));
    }
    final bBigrams = <String>{};
    for (int i = 0; i < b.length - 1; i++) {
      bBigrams.add(b.substring(i, i + 2));
    }

    if (aBigrams.isEmpty || bBigrams.isEmpty) return 0.0;
    final intersection = aBigrams.intersection(bBigrams).length;
    return (2.0 * intersection) / (aBigrams.length + bBigrams.length);
  }

  /// Lista de géneros cinematográficos reconocidos
  static const List<String> _genres = [
    'terror', 'miedo', 'accion', 'comedia', 'drama', 'suspenso',
    'animacion', 'infantil', 'ciencia ficcion', 'fantasia', 'romance',
    'aventura', 'crimen', 'documental', 'misterio', 'belico', 'anime'
  ];

  /// Analiza la frase hablada e interpreta inteligentemente el pedido del usuario
  static VoiceIntentResult processCommand(
    String spokenText,
    List<PlaylistItem> channels, {
    String currentTab = 'live',
    String? userName,
  }) {
    final clean = normalize(spokenText);
    final greeting = (userName != null && userName.isNotEmpty) ? '$userName, ' : '';

    if (clean.isEmpty) {
      return VoiceIntentResult(
        type: VoiceIntentType.unknown,
        text: '¿En qué te puedo ayudar hoy?',
      );
    }

    // 1. Detectar intención de Guía EPG / Horarios / Programación
    if (clean.contains('guia') ||
        clean.contains('epg') ||
        clean.contains('programacion') ||
        clean.contains('horario') ||
        clean.contains('que estan dando') ||
        clean.contains('que dan hoy')) {
      return VoiceIntentResult(
        type: VoiceIntentType.openEPG,
        text: '${greeting}abriendo la guía EPG interactiva',
      );
    }

    // 2. Extracción de filtros de calidad (4K, HD, FHD)
    String? quality;
    if (clean.contains('4k') || clean.contains('ultra hd')) {
      quality = '4K';
    } else if (clean.contains('fhd') || clean.contains('full hd')) {
      quality = 'FHD';
    } else if (clean.contains('hd') || clean.contains('alta definicion')) {
      quality = 'HD';
    }

    // 3. Extracción de recencia / novedad ("la más actual", "estrenos", "nuevas")
    final isRecent = clean.contains('mas actual') ||
        clean.contains('mas reciente') ||
        clean.contains('mas nueva') ||
        clean.contains('estreno') ||
        clean.contains('estrenos') ||
        clean.contains('reciente') ||
        clean.contains('actual') ||
        clean.contains('ultimas');

    // 4. Extracción de Género
    String? detectedGenre;
    for (final g in _genres) {
      if (clean.contains(g)) {
        detectedGenre = (g == 'miedo') ? 'terror' : g;
        break;
      }
    }

    // 5. Detectar intención explícita de Películas o Series
    final isMovieRequest = clean.contains('pelicula') ||
        clean.contains('peliculas') ||
        clean.contains('cine') ||
        clean.contains('film') ||
        clean.contains('films') ||
        clean.contains('peli') ||
        (currentTab == 'movies' && detectedGenre != null);

    final isSeriesRequest = clean.contains('serie') ||
        clean.contains('series') ||
        clean.contains('temporada') ||
        clean.contains('capitulo') ||
        (currentTab == 'series' && detectedGenre != null);

    if (isMovieRequest) {
      String responseMsg = '${greeting}buscando ';
      if (detectedGenre != null) {
        responseMsg += 'películas de $detectedGenre ';
      } else {
        responseMsg += 'películas ';
      }
      if (isRecent) responseMsg += 'más actuales ';
      if (quality != null) responseMsg += 'en $quality ';

      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        targetTab: 'movies',
        genre: detectedGenre,
        isRecent: isRecent,
        quality: quality,
        searchQuery: detectedGenre ?? (isRecent ? 'estreno' : null),
        text: responseMsg.trim(),
      );
    }

    if (isSeriesRequest) {
      String responseMsg = '${greeting}mostrando series ';
      if (detectedGenre != null) responseMsg += 'de $detectedGenre ';
      if (isRecent) responseMsg += 'recientes ';

      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        targetTab: 'series',
        genre: detectedGenre,
        isRecent: isRecent,
        quality: quality,
        searchQuery: detectedGenre,
        text: responseMsg.trim(),
      );
    }

    // 6. Detectar Eventos Deportivos o Partidos ("partido de ... contra ...")
    final isSports = clean.contains('partido') ||
        clean.contains('futbol') ||
        clean.contains('vs') ||
        clean.contains('contra') ||
        clean.contains('champions') ||
        clean.contains('copa');

    if (isSports && currentTab != 'movies' && currentTab != 'series') {
      // Intentar sintonizar el canal que transmite deportes con preferencia de calidad
      PlaylistItem? sportsChannel;
      final sportsKeywords = ['espn', 'fox sports', 'directv', 'dsports', 'tnt sports', 'tyc', 'gol', 'deportes'];

      for (final kw in sportsKeywords) {
        final matches = channels.where((c) => normalize(c.name).contains(kw)).toList();
        if (matches.isNotEmpty) {
          if (quality != null) {
            sportsChannel = matches.firstWhere(
              (c) => normalize(c.name).contains(quality!.toLowerCase()),
              orElse: () => matches.first,
            );
          } else {
            sportsChannel = matches.first;
          }
          break;
        }
      }

      if (sportsChannel != null) {
        return VoiceIntentResult(
          type: VoiceIntentType.playChannel,
          targetChannel: sportsChannel,
          targetTab: 'live',
          quality: quality,
          text: '${greeting}sintonizando ${sportsChannel.name} para ver el evento${quality != null ? ' en $quality' : ''}',
        );
      }
    }

    // 7. Limpiar prefijos de comando de sintonización de canales en vivo
    String channelQuery = clean;
    final prefixes = [
      'sintoniza el canal',
      'sintoniza',
      'pon el canal',
      'coloca el canal',
      'ponme el canal',
      'cambia a',
      'quiero ver el canal',
      'quiero ver',
      'ponme',
      'coloca',
      'pon',
      'ver',
      'abre',
      'busca',
      'buscar',
      'canal'
    ];

    for (final p in prefixes) {
      if (channelQuery.startsWith(p)) {
        channelQuery = channelQuery.substring(p.length).trim();
        break;
      }
    }

    if (channelQuery.isEmpty) {
      channelQuery = clean;
    }

    // 8. Buscar coincidencia exacta o de alta similitud en la lista de canales
    PlaylistItem? bestChannel;
    double highestScore = 0.0;

    for (final ch in channels) {
      final chClean = normalize(ch.name);

      if (chClean == channelQuery) {
        return VoiceIntentResult(
          type: VoiceIntentType.playChannel,
          targetChannel: ch,
          targetTab: 'live',
          text: '${greeting}sintonizando ${ch.name}',
        );
      }

      if (chClean.contains(channelQuery) || channelQuery.contains(chClean)) {
        double score = 0.90;
        if (quality != null && chClean.contains(quality.toLowerCase())) {
          score += 0.05;
        }
        if (score > highestScore) {
          highestScore = score;
          bestChannel = ch;
        }
        continue;
      }

      final sim = calculateSimilarity(channelQuery, chClean);
      if (sim > highestScore) {
        highestScore = sim;
        bestChannel = ch;
      }
    }

    if (bestChannel != null && highestScore >= 0.45) {
      return VoiceIntentResult(
        type: VoiceIntentType.playChannel,
        targetChannel: bestChannel,
        targetTab: 'live',
        text: '${greeting}sintonizando ${bestChannel.name}',
      );
    }

    // 9. Si no es un canal, activar Búsqueda General respetando la sección actual
    return VoiceIntentResult(
      type: VoiceIntentType.searchContent,
      searchQuery: channelQuery,
      targetTab: currentTab,
      text: '${greeting}buscando "$channelQuery"',
    );
  }
}