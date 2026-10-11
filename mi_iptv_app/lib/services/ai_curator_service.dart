class AICuratorService {
  static String cleanChannelName(String rawName) {
    String cleaned = rawName;
    
    final patterns = [
      RegExp(r'^US:\s*', caseSensitive: false),
      RegExp(r'^ES:\s*', caseSensitive: false),
      RegExp(r'^MX:\s*', caseSensitive: false),
      RegExp(r'\[BACKUP\]', caseSensitive: false),
      RegExp(r'\(FHD\)', caseSensitive: false),
      RegExp(r'\(HD\)', caseSensitive: false),
      RegExp(r'\(SD\)', caseSensitive: false),
      RegExp(r'\|.*$', caseSensitive: false),
    ];

    for (var pattern in patterns) {
      cleaned = cleaned.replaceAll(pattern, '');
    }

    return cleaned.trim();
  }

  static String normalizeCategory(String rawCategory, String channelName) {
    final lower = '$rawCategory $channelName'.toLowerCase();
    
    if (lower.contains('sports') || lower.contains('deportes') || lower.contains('espn')) {
      return 'Deportes';
    } else if (lower.contains('news') || lower.contains('noticias')) {
      return 'Noticias';
    } else if (lower.contains('movie') || lower.contains('cine') || lower.contains('hbo')) {
      return 'Cine y Películas';
    } else if (lower.contains('kids') || lower.contains('infantil') || lower.contains('disney')) {
      return 'Infantil';
    }
    
    return rawCategory.isNotEmpty ? rawCategory : 'Entretenimiento';
  }
}
