class EpgProgram {
  final String title;
  final String description;
  final DateTime startTime;
  final DateTime endTime;
  final String category;

  EpgProgram({
    required this.title,
    required this.description,
    required this.startTime,
    required this.endTime,
    required this.category,
  });

  String get timeFormatted {
    final startH = startTime.hour.toString().padLeft(2, '0');
    final startM = startTime.minute.toString().padLeft(2, '0');
    final endH = endTime.hour.toString().padLeft(2, '0');
    final endM = endTime.minute.toString().padLeft(2, '0');
    return '$startH:$startM - $endH:$endM';
  }

  double get progress {
    final now = DateTime.now();
    if (now.isBefore(startTime)) return 0.0;
    if (now.isAfter(endTime)) return 1.0;
    final total = endTime.difference(startTime).inSeconds;
    final elapsed = now.difference(startTime).inSeconds;
    if (total <= 0) return 0.5;
    return (elapsed / total).clamp(0.0, 1.0);
  }

  int get remainingMinutes {
    final now = DateTime.now();
    if (now.isAfter(endTime)) return 0;
    return endTime.difference(now).inMinutes;
  }
}

class EpgService {
  static final Map<String, List<EpgProgram>> _cache = {};

  static List<EpgProgram> getScheduleForChannel(String channelName, String category) {
    final now = DateTime.now();
    final cacheKey = '$channelName-${now.day}-${now.hour}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final lowerName = channelName.toLowerCase();
    final lowerCat = category.toLowerCase();
    final baseTitles = _getTitlesForGenre(lowerName, lowerCat);

    List<EpgProgram> schedule = [];
    DateTime slotStart = DateTime(now.year, now.month, now.day, now.hour - 1, (now.minute >= 30 ? 30 : 0));

    for (int i = 0; i < 6; i++) {
      DateTime slotEnd = slotStart.add(const Duration(minutes: 60));
      final title = baseTitles[i % baseTitles.length];
      
      schedule.add(
        EpgProgram(
          title: title,
          description: "Transmisión oficial de $title en alta definición por $channelName.",
          startTime: slotStart,
          endTime: slotEnd,
          category: category.isNotEmpty ? category : "General",
        ),
      );
      slotStart = slotEnd;
    }

    _cache[cacheKey] = schedule;
    return schedule;
  }

  static EpgProgram getCurrentProgram(String channelName, String category) {
    final list = getScheduleForChannel(channelName, category);
    final now = DateTime.now();
    return list.firstWhere(
      (p) => now.isAfter(p.startTime) && now.isBefore(p.endTime),
      orElse: () => list.first,
    );
  }

  static EpgProgram getNextProgram(String channelName, String category) {
    final list = getScheduleForChannel(channelName, category);
    final current = getCurrentProgram(channelName, category);
    final idx = list.indexOf(current);
    if (idx != -1 && idx + 1 < list.length) {
      return list[idx + 1];
    }
    return list.last;
  }

  static List<EpgProgram> getUpcomingPrograms(String channelName, String category) {
    final list = getScheduleForChannel(channelName, category);
    final now = DateTime.now();
    return list.where((p) => p.endTime.isAfter(now)).toList();
  }

  static List<String> _getTitlesForGenre(String name, String cat) {
    if (name.contains("espn") || name.contains("fox") || name.contains("tyc") || name.contains("sport") || cat.contains("deport")) {
      return [
        "Fútbol en Vivo: Liga Profesional / Copa Internacional",
        "Sportscenter Primera Edición - Análisis y Goles",
        "Balón Dividido: Debate y Polémica en Directo",
        "Tenis Internacional ATP Tour - Gran Final",
        "Fórmula 1: Resumen de Clasificación y Paddock",
        "Especial Deportivo: Mejores Jugadas del Día",
      ];
    }
    if (name.contains("cine") || name.contains("movie") || name.contains("hbo") || name.contains("max") || cat.contains("cine") || cat.contains("pelic")) {
      return [
        "Película Estelar: Misión de Alto Impacto (HD)",
        "Cine de Acción: La Furia de la Noche",
        "Estreno Exclusivo: Secretos del Pasado",
        "Cine de Suspenso: Al Límite del Peligro",
        "Película de Medianoche: Sombras en la Ciudad",
        "Clásicos del Cine Internacional",
      ];
    }
    if (name.contains("music") || name.contains("htv") || name.contains("mtv") || cat.contains("music")) {
      return [
        "Top 20 Hits Mundiales en Ultra HD",
        "Especial de Reggaetón y Música Urbana",
        "Concierto en Vivo: Grandes Leyendas del Pop",
        "Noche Electrónica: Sesiones de Club",
        "Clásicos de los 80s y 90s Inolvidables",
        "Lo Más Nuevo de la Música Latina",
      ];
    }
    if (name.contains("notic") || name.contains("news") || name.contains("cnn") || cat.contains("notic")) {
      return [
        "El Noticiero en Vivo: Minuto a Minuto",
        "Mesa Redonda: Análisis Político y Economía",
        "Noticias del Mundo: Enfoque Global",
        "Primera Línea: Entrevistas Exclusivas",
        "Resumen Informativo de la Noche",
        "Alerta de Última Hora",
      ];
    }
    return [
      "Transmisión Especial en Vivo",
      "Magacín de Entretenimiento de la Tarde",
      "Serie Exclusiva: Temporada Estelar",
      "Documental: Grandes Misterios del Planeta",
      "Show Central de la Noche",
      "Programación de Madrugada",
    ];
  }
}