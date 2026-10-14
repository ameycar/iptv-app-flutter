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
  final PlaylistItem? targetChannel;
  final String? targetTab; // 'live', 'movies', 'series'
  final String? searchQuery;

  VoiceIntentResult({
    required this.type,
    required this.text,
    this.targetChannel,
    this.targetTab,
    this.searchQuery,
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
    str = str.replaceAll(RegExp(r'[^\w\s]'), '');
    return str;
  }

  /// Calcula similitud entre dos palabras (0.0 a 1.0)
  static double calculateSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.contains(b) || b.contains(a)) return 0.85;

    // Conteo de coincidencias de caracteres contiguos (Bigramas)
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

  /// Analiza la frase hablada y determina la acción exacta al instante
  static VoiceIntentResult processCommand(String spokenText, List<PlaylistItem> channels) {
    final clean = normalize(spokenText);

    // 1. Detectar intención de Guía EPG / Horarios / Programación
    if (clean.contains('guia') ||
        clean.contains('epg') ||
        clean.contains('programacion') ||
        clean.contains('horario') ||
        clean.contains('que estan dando')) {
      return VoiceIntentResult(
        type: VoiceIntentType.openEPG,
        text: 'Abriendo Guía EPG interactiva',
      );
    }

    // 2. Detectar cambio de Pestañas (Películas / Series / En Vivo)
    if (clean.contains('pelicula') || clean.contains('peliculas') || clean.contains('cine') || clean.contains('films')) {
      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        targetTab: 'movies',
        text: 'Cambiando a Películas',
      );
    }

    if (clean.contains('serie') || clean.contains('series') || clean.contains('temporada')) {
      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        targetTab: 'series',
        text: 'Cambiando a Series',
      );
    }

    if (clean.contains('en vivo') || clean.contains('television') || clean.contains('canales en directo') || clean.contains('tv en vivo')) {
      return VoiceIntentResult(
        type: VoiceIntentType.switchTab,
        targetTab: 'live',
        text: 'Cambiando a TV En Vivo',
      );
    }

    // 3. Limpiar prefijos de comando de sintonización ("pon", "sintoniza", "abre", "ver", "reproducir")
    String channelQuery = clean;
    final prefixes = [
      'sintoniza el canal',
      'sintoniza',
      'pon el canal',
      'coloca el canal',
      'ponme el canal',
      'cambia a',
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

    // 4. Buscar coincidencia exacta o de alta similitud en la lista de canales
    PlaylistItem? bestChannel;
    double highestScore = 0.0;

    for (final ch in channels) {
      final chClean = normalize(ch.name);

      // Coincidencia exacta o contenida directa
      if (chClean == channelQuery) {
        return VoiceIntentResult(
          type: VoiceIntentType.playChannel,
          targetChannel: ch,
          text: 'Sintonizando ${ch.name}',
        );
      }

      if (chClean.contains(channelQuery) || channelQuery.contains(chClean)) {
        final score = 0.90;
        if (score > highestScore) {
          highestScore = score;
          bestChannel = ch;
        }
        continue;
      }

      // Similitud fonética / difusa
      final sim = calculateSimilarity(channelQuery, chClean);
      if (sim > highestScore) {
        highestScore = sim;
        bestChannel = ch;
      }
    }

    // Si la coincidencia supera el umbral del 45%, sintonizar directamente
    if (bestChannel != null && highestScore >= 0.45) {
      return VoiceIntentResult(
        type: VoiceIntentType.playChannel,
        targetChannel: bestChannel,
        text: 'Sintonizando ${bestChannel.name}',
      );
    }

    // 5. Si no es un canal específico, activar Búsqueda General rápida con el texto filtrado
    return VoiceIntentResult(
      type: VoiceIntentType.searchContent,
      searchQuery: channelQuery,
      text: 'Buscando "$channelQuery"',
    );
  }
}