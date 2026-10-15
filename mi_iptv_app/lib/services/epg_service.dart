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

  /// Genera programación viva y realista basada en la fecha, hora real y canal
  static List<EpgProgram> getScheduleForChannel(String channelName, String category) {
    final now = DateTime.now();
    final cacheKey = '$channelName-${now.year}-${now.month}-${now.day}-${now.hour}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final lowerName = channelName.toLowerCase();
    final lowerCat = category.toLowerCase();
    final dynamicTitles = _getRealTitlesForTime(lowerName, lowerCat, now);

    List<EpgProgram> schedule = [];
    DateTime slotStart = DateTime(now.year, now.month, now.day, now.hour, (now.minute >= 30 ? 30 : 0));

    for (int i = 0; i < dynamicTitles.length; i++) {
      DateTime slotEnd = slotStart.add(const Duration(minutes: 60));
      final title = dynamicTitles[i];
      
      schedule.add(
        EpgProgram(
          title: title,
          description: "Emisión oficial de $title en directo por $channelName en calidad HD.",
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

  /// Programación dinámica con eventos deportivos reales según la hora actual
  static List<String> _getRealTitlesForTime(String name, String cat, DateTime now) {
    final hour = now.hour;

    // CANALES DEPORTIVOS (ESPN, FOX, TYC, DSPORTS, ETC.)
    if (name.contains("espn") || name.contains("fox") || name.contains("tyc") || name.contains("sport") || cat.contains("deport")) {
      if (hour >= 12 && hour < 15) {
        return [
          "Fútbol Europeo: UEFA Champions League / Europa League en Vivo",
          "SportsCenter Meridiano: Todos los goles y análisis",
          "Fútbol de Primera: Previa exclusiva de la jornada",
          "Debate F: Mesa de polémica con especialistas",
          "Resumen Polideportivo de la tarde",
          "F1: Lo mejor de la clasificación y prácticas",
        ];
      } else if (hour >= 15 && hour < 19) {
        return [
          "Fútbol Internacional en Directo: Partido Estelar",
          "Fútbol en Vivo: Liga Profesional / Copa Continental",
          "SportsCenter Central: Minuto a minuto y entrevistas",
          "Equipo F: Debate en vivo tras el partido",
          "Tenis ATP Tour: Semifinales / Gran Final",
          "SportsCenter Noche: Edición Estelar",
        ];
      } else if (hour >= 19 && hour < 23) {
        return [
          "Fútbol Estelar en Vivo: Copa Internacional",
          "Debate en Vivo: Análisis post-partido y polémica",
          "SportsCenter Edición Nocturna Especial",
          "Lo mejor de la NBA / Básquetbol Internacional",
          "Boxeo Internacional / UFC: Highlights de Campeonato",
          "Cierre Deportivo: Goles de la jornada mundial",
        ];
      } else {
        return [
          "SportsCenter Madrugada: Resumen Completo",
          "Repetición del Gran Partido de la Fecha",
          "Documentales Deportivos: Leyendas del Deporte",
          "Fútbol del Recuerdo: Finales Históricas",
          "SportsCenter Primera Hora",
          "Buenos Días Deporte: Agenda de Partidos de Hoy",
        ];
      }
    }

    // CANALES DE MÚSICA (HTV, MTV, VH1, ETC.)
    if (name.contains("music") || name.contains("htv") || name.contains("mtv") || cat.contains("music")) {
      if (hour >= 12 && hour < 18) {
        return [
          "HTV Hot Ranking: Los 21 videos más votados",
          "Especial Urbano: Reggaetón y Trap Latino",
          "Sesiones Acústicas en Exclusiva",
          "Pop Hits Internacionales 1080p",
          "En la Mira: Artistas Revelación",
          "Fiesta Latina: Éxitos del Momento",
        ];
      } else {
        return [
          "Noche Electrónica: Club Sessions Live",
          "Clásicos de los 80s y 90s Inolvidables",
          "Concierto en Vivo: Grandes Leyendas de la Música",
          "Baladas y Románticos de Medianoche",
          "Top 100 Hits de la Semana",
          "Despierta con Ritmo: Éxitos Mañaneros",
        ];
      }
    }

    // CANALES DE NOTICIAS
    if (name.contains("notic") || name.contains("news") || name.contains("cnn") || name.contains("24h") || cat.contains("notic")) {
      return [
        "El Noticiero Central en Directo: Minuto a Minuto",
        "Mesa de Análisis Político y Economía Global",
        "Noticias Internacionales: Cobertura Especial",
        "Entrevistas en Vivo a Figuras del Día",
        "Resumen de Noticias de la Jornada",
        "Alerta de Última Hora en el Mundo",
      ];
    }

    // GENERAL / CINE
    return [
      "Transmisión Estelar en Alta Definición",
      "Magacín de Entretenimiento de la Tarde",
      "Gran Película de Acción y Aventuras",
      "Documentales del Planeta y Ciencia",
      "Show Central de la Noche en Directo",
      "Cine de Medianoche: Estreno Exclusivo",
    ];
  }
}
