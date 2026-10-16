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
    final cacheKey = '$channelName-${now.year}-${now.month}-${now.day}-${now.hour}';
    if (_cache.containsKey(cacheKey)) {
      return _cache[cacheKey]!;
    }

    final lowerName = channelName.toLowerCase();
    final lowerCat = category.toLowerCase();
    final dynamicTitles = _getSpecificTitlesForChannel(lowerName, lowerCat, now);

    List<EpgProgram> schedule = [];
    DateTime slotStart = DateTime(now.year, now.month, now.day, now.hour, (now.minute >= 30 ? 30 : 0));

    for (int i = 0; i < dynamicTitles.length; i++) {
      DateTime slotEnd = slotStart.add(const Duration(minutes: 60));
      final title = dynamicTitles[i];
      
      schedule.add(
        EpgProgram(
          title: title,
          description: "Emisión de $title en directo por $channelName en alta definición.",
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

  /// CADA CANAL TIENE SU PROGRAMACIÓN PROPIA Y DIFERENTE
  static List<String> _getSpecificTitlesForChannel(String name, String cat, DateTime now) {
    final hour = now.hour;

    // ESPN 3: BÉISBOL DE GRANDES LIGAS (MLB), COLLEGE Y DEPORTES AMERICANOS
    if (name.contains("espn 3") || name.contains("espn3")) {
      return [
        "Béisbol MLB en Vivo: Postemporada / Juego de Campeonato",
        "MLB Extra Inning: Highlights y Todos los Home Runs",
        "Béisbol en Directo: Partido de la Serie Mundial",
        "College Football NCAA en Exclusiva",
        "SportsCenter ESPN 3: Edición Béisbol y Más",
        "Béisbol Clásico: Grandes Momentos de la MLB",
      ];
    }

    // ESPN 2: FÚTBOL INTERNACIONAL, TENIS Y SERIE A
    if (name.contains("espn 2") || name.contains("espn2")) {
      return [
        "Fútbol Internacional: Serie A Italiana / LaLiga en Vivo",
        "Tenis ATP Masters 1000: Semifinales en Directo",
        "SportsCenter 2: El Minuto a Minuto del Fútbol Europeo",
        "Equipo F: Debate Táctico de la Jornada",
        "Resumen de la Champions League: Goles del Día",
        "Tenis Night Sessions: Lo Mejor de la Fecha",
      ];
    }

    // ESPN 5 O ESPN EXTRA: RUGBY, POLIDEPORTIVO Y FÓRMULA 1
    if (name.contains("espn 5") || name.contains("espn5") || name.contains("extra")) {
      return [
        "Fórmula 1 en Vivo: Clasificación y Cámara a Bordo",
        "Rugby Internacional: Torneo de las 6 Naciones",
        "SportsCenter Extra: Lo Mejor del Deporte Motor",
        "Ciclismo UCI World Tour: Etapa de Montaña",
        "Paddock F1: Entrevistas a los Pilotos",
        "Lo Mejor de la NBA: Jugadas Espectaculares",
      ];
    }

    // ESPN PRINCIPAL / FOX SPORTS: FÚTBOL CONTINENTAL Y LIBERTADORES
    if (name.contains("espn") || name.contains("fox") || name.contains("tyc")) {
      return [
        "Fútbol en Vivo: Copa Continental / Liga Profesional",
        "SportsCenter Central: Todos los Goles y Polémica",
        "Debate Deportivo Central en Directo",
        "Copa Libertadores: Previa Especial y Alineaciones",
        "El Show del Gol: Resumen de Todos los Partidos",
        "SportsCenter Noche: Edición Estelar de Cierre",
      ];
    }

    // HTV: VIDEOS DE MÚSICA URBANA, POP Y RANKINGS
    if (name.contains("htv") || name.contains("music") || name.contains("mtv")) {
      return [
        "HTV Hot Ranking: Los 21 Videos Más Votados",
        "Especial Urbano: Reggaetón y Trap Latino",
        "En la Mira: Estrenos Musicales de la Semana",
        "Pausa HTV: Entrevistas a Estrellas Latinas",
        "Noche Latina: Los Mejores Videoclips en HD",
        "Hits Inolvidables del Pop y Reggaetón",
      ];
    }

    // NOTICIAS (24H, CNN, DW, ETC.)
    if (name.contains("notic") || name.contains("24h") || name.contains("cnn")) {
      return [
        "El Noticiero Central: Minuto a Minuto del Mundo",
        "Mesa de Debate Político y Economía",
        "Noticias Internacionales: Cobertura Especial",
        "Entrevistas en Vivo a Figuras del Día",
        "Resumen Informativo de Cierre",
        "Alerta de Última Hora Global",
      ];
    }

    // CANALES GENERALES / SERIES
    return [
      "Transmisión Estelar en Calidad 1080p",
      "Magacín de Entretenimiento de la Tarde",
      "Gran Película de Acción y Aventuras",
      "Documentales del Planeta y Ciencia",
      "Show Central de la Noche en Directo",
      "Cine de Medianoche: Estreno Exclusivo",
    ];
  }
}
