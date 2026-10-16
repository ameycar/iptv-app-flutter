import 'dart:math';

/// Enum oficial que espera tu alexa_voice_sheet.dart
enum AIActionType {
  playChannel,
  openEPG,
  switchTab,
  searchContent,
  speakOnly,
}

/// Respuesta estructurada compatible tanto con .action como con ['action']
class AICuratorResult {
  final AIActionType action;
  final dynamic item;
  final String message;
  final String? targetSection;
  final String? category;

  const AICuratorResult({
    required this.action,
    this.item,
    this.message = '',
    this.targetSection,
    this.category,
  });

  // Compatibilidad por si se accede como Map result['action']
  dynamic operator [](String key) {
    switch (key) {
      case 'action':
        return action;
      case 'item':
        return item;
      case 'message':
        return message;
      case 'targetSection':
      case 'target':
        return targetSection;
      case 'category':
        return category;
      default:
        return null;
    }
  }
}

class AICuratorService {
  /// Interpreta la voz o texto usando el parámetro exacto 'userVoicePrompt'
  static Future<AICuratorResult> interpretVoiceCommand({
    required String userVoicePrompt,
    required List<dynamic> channels,
    String currentSection = 'En Vivo',
    dynamic currentChannel,
  }) async {
    final raw = userVoicePrompt.trim();
    if (raw.isEmpty || channels.isEmpty) {
      return const AICuratorResult(
        action: AIActionType.speakOnly,
        message: 'Por favor indica qué deseas ver.',
      );
    }

    final clean = _cleanQuery(raw.toLowerCase());

    // 1. Detección de Guía EPG
    if (clean.contains('guia') || clean.contains('guía') || clean.contains('epg') || clean.contains('programacion')) {
      return const AICuratorResult(
        action: AIActionType.openEPG,
        message: 'Abriendo Guía EPG...',
      );
    }

    // 2. Cambio de Pestañas / Secciones
    if (clean == 'peliculas' || clean == 'películas' || clean.contains('ir a peliculas')) {
      return const AICuratorResult(
        action: AIActionType.switchTab,
        targetSection: 'Películas',
        message: 'Cambiando a Películas...',
      );
    }
    if (clean == 'series' || clean.contains('ir a series')) {
      return const AICuratorResult(
        action: AIActionType.switchTab,
        targetSection: 'Series',
        message: 'Cambiando a Series...',
      );
    }
    if (clean == 'en vivo' || clean == 'tv' || clean.contains('ir a vivo')) {
      return const AICuratorResult(
        action: AIActionType.switchTab,
        targetSection: 'En Vivo',
        message: 'Cambiando a TV en Vivo...',
      );
    }

    // 3. Búsqueda Ponderada de Canales (ej: "espn 2")
    dynamic bestItem;
    double maxScore = 0.0;

    for (final ch in channels) {
      final name = _extractName(ch).toLowerCase();
      final category = _extractCategory(ch).toLowerCase();

      final score = _calculateScore(clean, raw.toLowerCase(), name, category);
      if (score > maxScore) {
        maxScore = score;
        bestItem = ch;
      }
    }

    // Si encontramos coincidencia suficiente
    if (bestItem != null && maxScore >= 40.0) {
      return AICuratorResult(
        action: AIActionType.playChannel,
        item: bestItem,
        message: 'Sintonizando ${_extractName(bestItem)}...',
      );
    }

    // 4. Búsqueda de contenido general
    return AICuratorResult(
      action: AIActionType.searchContent,
      message: 'Buscando "$raw"...',
    );
  }

  static String _cleanQuery(String text) {
    var s = text.toLowerCase();
    for (final w in [
      'quiero ver', 'colocame', 'colócame', 'ponme', 'sintoniza', 'canal de',
      'canal', 'canales', 'por favor', 'ver el', 'ver la', 'ver', 'pon', 'busca'
    ]) {
      s = s.replaceAll(w, ' ');
    }
    s = s.replaceAll('uno', '1').replaceAll('dos', '2').replaceAll('tres', '3').replaceAll('cuatro', '4').replaceAll('cinco', '5');
    return s.replaceAll(RegExp(r'[^\w\s\d]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static double _calculateScore(String clean, String raw, String name, String category) {
    if (name.isEmpty) return 0.0;

    final normName = name.replaceAll(RegExp(r'^[a-z]{2,3}\s*[:|]\s*', caseSensitive: false), '')
                         .replaceAll(RegExp(r'\[.*?\]|\(.*?\)', caseSensitive: false), '')
                         .trim();

    if (normName == clean || name == clean) return 100.0;

    final noSpaceName = normName.replaceAll(' ', '');
    final noSpaceClean = clean.replaceAll(' ', '');
    if (noSpaceName.contains(noSpaceClean) || noSpaceClean.contains(noSpaceName)) return 95.0;
    if (normName.contains(clean)) return 90.0;

    final tokens = clean.split(' ').where((t) => t.length > 1).toList();
    if (tokens.isEmpty) return 0.0;

    int matches = 0;
    for (final t in tokens) {
      if (normName.contains(t) || noSpaceName.contains(t)) matches++;
    }

    double score = (matches / tokens.length) * 80.0;
    if (category.isNotEmpty && tokens.any((t) => category.contains(t))) score += 20.0;
    return min(score, 100.0);
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