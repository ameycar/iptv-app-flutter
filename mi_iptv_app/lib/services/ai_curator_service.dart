import 'dart:math';

class AICuratorService {
  /// Interpreta cualquier instrucción de voz o texto en milésimas de segundo (< 5ms)
  static Future<Map<String, dynamic>> interpretVoiceCommand({
    required String command,
    required List<dynamic> channels,
    required String currentSection,
    dynamic currentChannel,
  }) async {
    if (command.trim().isEmpty || channels.isEmpty) {
      return {'action': 'not_found', 'message': 'Por favor indica qué deseas ver.'};
    }

    final raw = command.toLowerCase().trim();
    final clean = _cleanQuery(raw);

    // 1. Detección de navegación entre secciones (Live / Películas / Series)
    if (_isMovieSectionRequest(clean)) {
      return {'action': 'navigate_section', 'target': 'Películas'};
    }
    if (_isSeriesSectionRequest(clean)) {
      return {'action': 'navigate_section', 'target': 'Series'};
    }
    if (_isLiveSectionRequest(clean)) {
      return {'action': 'navigate_section', 'target': 'En Vivo'};
    }

    // 2. Búsqueda Ponderada de Canales / Contenido
    dynamic bestItem;
    double maxScore = 0.0;

    for (final item in channels) {
      final name = _extractName(item).toLowerCase();
      final category = _extractCategory(item).toLowerCase();

      final score = _calculateMatchScore(
        cleanQuery: clean,
        rawQuery: raw,
        itemName: name,
        itemCategory: category,
      );

      if (score > maxScore) {
        maxScore = score;
        bestItem = item;
      }
    }

    // Si el score supera el umbral de confianza (55%), sintonizamos al instante
    if (bestItem != null && maxScore >= 55.0) {
      return {
        'action': 'play_channel',
        'item': bestItem,
        'name': _extractName(bestItem),
        'score': maxScore,
      };
    }

    // 3. Detección de Categorías
    final categoryTarget = _detectCategoryFilter(clean);
    if (categoryTarget != null) {
      return {
        'action': 'filter_category',
        'category': categoryTarget,
      };
    }

    // 4. Si hubo un resultado parcial con menor score pero razonable
    if (bestItem != null && maxScore >= 35.0) {
      return {
        'action': 'play_channel',
        'item': bestItem,
        'name': _extractName(bestItem),
        'score': maxScore,
      };
    }

    return {
      'action': 'not_found',
      'message': 'No se encontró "$command" en tu catálogo actual.',
    };
  }

  /// Limpia palabras de parada habituales en comandos de voz
  static String _cleanQuery(String text) {
    var s = text.toLowerCase();
    final stopWords = [
      'quiero ver', 'colocame', 'colócame', 'ponme', 'sintonizame', 'sintonízame',
      'sintoniza', 'canal de', 'canal', 'canales de', 'canales', 'por favor',
      'el partido de', 'el partido', 'ver a', 'ver el', 'ver la', 'ver', 'pon',
      'busca', 'reproduce', 'abrir', 'abre'
    ];

    for (final w in stopWords) {
      s = s.replaceAll(w, ' ');
    }

    // Normalizar números y variantes (espn dos -> espn 2)
    s = s.replaceAll('uno', '1')
         .replaceAll('dos', '2')
         .replaceAll('tres', '3')
         .replaceAll('cuatro', '4')
         .replaceAll('cinco', '5')
         .replaceAll('seis', '6');

    // Quitar símbolos extraños
    s = s.replaceAll(RegExp(r'[^\w\s\d]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// Algoritmo de Coincidencia Ponderada
  static double _calculateMatchScore({
    required String cleanQuery,
    required String rawQuery,
    required String itemName,
    required String itemCategory,
  }) {
    if (itemName.isEmpty) return 0.0;

    // Normalizar nombres de canales (eliminar prefijos como "ES:", "AR |", etc.)
    final normalizedItem = itemName
        .replaceAll(RegExp(r'^[a-z]{2,3}\s*[:|]\s*', caseSensitive: false), '')
        .replaceAll(RegExp(r'\[.*?\]|\(.*?\)', caseSensitive: false), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    // 1. Coincidencia exacta completa (Score: 100)
    if (normalizedItem == cleanQuery || itemName == cleanQuery) return 100.0;

    // 2. Variante sin espacios (ej: "espn2" vs "espn 2")
    final noSpaceItem = normalizedItem.replaceAll(' ', '');
    final noSpaceQuery = cleanQuery.replaceAll(' ', '');
    if (noSpaceItem.contains(noSpaceQuery) || noSpaceQuery.contains(noSpaceItem)) {
      return 95.0;
    }

    // 3. El nombre del canal contiene la búsqueda completa
    if (normalizedItem.contains(cleanQuery)) {
      return 90.0;
    }

    // 4. Tokenización y coincidencia de palabras clave
    final queryTokens = cleanQuery.split(' ').where((t) => t.length > 1).toList();
    if (queryTokens.isEmpty) return 0.0;

    int matchedTokens = 0;
    for (final token in queryTokens) {
      if (normalizedItem.contains(token) || noSpaceItem.contains(token)) {
        matchedTokens++;
      }
    }

    double tokenScore = (matchedTokens / queryTokens.length) * 80.0;

    // Bonus si coincide la categoría (ej: "música", "deportes")
    if (itemCategory.isNotEmpty) {
      for (final token in queryTokens) {
        if (itemCategory.contains(token)) {
          tokenScore += 25.0;
          break;
        }
      }
    }

    // Bonus especial si la consulta pide HD/FHD/4K y el canal lo incluye
    if ((rawQuery.contains('hd') || rawQuery.contains('1080') || rawQuery.contains('4k')) &&
        (itemName.contains('hd') || itemName.contains('1080') || itemName.contains('4k') || itemName.contains('fhd'))) {
      tokenScore += 10.0;
    }

    return min(tokenScore, 100.0);
  }

  static bool _isMovieSectionRequest(String q) {
    return q == 'peliculas' || q == 'películas' || q.contains('ir a peliculas') || q.contains('seccion peliculas');
  }

  static bool _isSeriesSectionRequest(String q) {
    return q == 'series' || q.contains('ir a series') || q.contains('seccion series');
  }

  static bool _isLiveSectionRequest(String q) {
    return q == 'en vivo' || q == 'tv en vivo' || q == 'canales' || q.contains('ir a vivo');
  }

  static String? _detectCategoryFilter(String q) {
    if (q.contains('deporte') || q.contains('futbol') || q.contains('beisbol')) return 'Deportes';
    if (q.contains('noticia') || q.contains('informativo')) return 'Noticias';
    if (q.contains('musica') || q.contains('música') || q.contains('musical')) return 'Música';
    if (q.contains('cine') || q.contains('pelicula')) return 'Películas';
    if (q.contains('infantil') || q.contains('dibujo') || q.contains('niño')) return 'Infantiles';
    return null;
  }

  static String _extractName(dynamic item) {
    if (item == null) return '';
    try { return (item.name ?? '').toString(); } catch (_) {}
    try { return (item.title ?? '').toString(); } catch (_) {}
    try { return (item['name'] ?? item['title'] ?? '').toString(); } catch (_) {}
    return '';
  }

  static String _extractCategory(dynamic item) {
    if (item == null) return '';
    try { return (item.category ?? '').toString(); } catch (_) {}
    try { return (item.group ?? '').toString(); } catch (_) {}
    try { return (item['category'] ?? item['group'] ?? '').toString(); } catch (_) {}
    return '';
  }
}
