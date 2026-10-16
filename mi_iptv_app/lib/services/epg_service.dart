class EpgProgram {
  final String title;
  final String subtitle;
  final String timeRange;
  final String nextTitle;
  final int remainingMinutes;
  final double progress;

  const EpgProgram({
    required this.title,
    this.subtitle = '',
    required this.timeRange,
    this.nextTitle = '',
    this.remainingMinutes = 25,
    this.progress = 0.5,
  });

  // Getter de compatibilidad con main.dart
  String get timeFormatted => timeRange;
}

class EpgService {
  /// Retorna un programa realista, coherente con el nombre del canal y la hora actual
  static EpgProgram getProgramForChannel(dynamic channel) {
    final name = _getChannelName(channel).toLowerCase();
    final now = DateTime.now();
    final currentHour = now.hour;
    final nextHour = (currentHour + 1) % 24;
    final timeStr = '${currentHour.toString().padLeft(2, '0')}:00 - ${nextHour.toString().padLeft(2, '0')}:00';
    final remaining = 60 - now.minute;
    final prog = (now.minute / 60.0).clamp(0.0, 1.0);

    // 1. Canales de Béisbol o ESPN 3 (como en tu captura)
    if (name.contains('espn 3') || name.contains('espn3') || name.contains('mlb') || name.contains('beisbol') || name.contains('baseball')) {
      return EpgProgram(
        title: 'Béisbol de Grandes Ligas MLB: Playoffs en Directo',
        subtitle: 'Cobertura en vivo de la Serie de Campeonato • Entrada por Entrada',
        timeRange: timeStr,
        nextTitle: 'A continuación: SportsCenter Noche / Resumen de Béisbol',
        remainingMinutes: remaining,
        progress: prog,
      );
    }

    // 2. Canales de Fútbol / Deportes Generales (ESPN, ESPN 2, TyC, Fox Sports)
    if (name.contains('espn 2') || name.contains('espn2')) {
      return EpgProgram(
        title: 'Fútbol en Vivo: Liga Continental de Clubes',
        subtitle: 'Transmisión estelar con relatos y comentarios oficiales',
        timeRange: timeStr,
        nextTitle: 'A continuación: Equipo F / Debate Deportivo',
        remainingMinutes: remaining,
        progress: prog,
      );
    }
    if (name.contains('espn') || name.contains('fox sports') || name.contains('tyc') || name.contains('directv sports') || name.contains('dsports')) {
      return EpgProgram(
        title: 'SportsCenter: Edición Central en Directo',
        subtitle: 'Goles, jugadas destacadas y entrevistas exclusivas de la jornada',
        timeRange: timeStr,
        nextTitle: 'A continuación: Fútbol Total en Vivo',
        remainingMinutes: remaining,
        progress: prog,
      );
    }

    // 3. Canales de Películas y Series (HBO, TNT, Cinecanal, Star, etc.)
    if (name.contains('hbo') || name.contains('tnt') || name.contains('cine') || name.contains('movie') || name.contains('star')) {
      return EpgProgram(
        title: 'Cine Estelar: Película de Acción en HD',
        subtitle: 'Transmisión con audio original y doblaje en español latino',
        timeRange: timeStr,
        nextTitle: 'A continuación: Función de Medianoche',
        remainingMinutes: remaining,
        progress: prog,
      );
    }

    // 4. Canales de Noticias (CNN, TN, C5N, 1+1, etc.)
    if (name.contains('1+1') || name.contains('cnn') || name.contains('noticia') || name.contains('news') || name.contains('tn')) {
      return EpgProgram(
        title: 'Noticiero Internacional: Cobertura en Vivo',
        subtitle: 'Resumen informativo con los principales acontecimientos del mundo',
        timeRange: timeStr,
        nextTitle: 'A continuación: Análisis Político y Económico',
        remainingMinutes: remaining,
        progress: prog,
      );
    }

    // 5. Canales de Música (HTV, MTV, Quiero, etc.)
    if (name.contains('htv') || name.contains('mtv') || name.contains('musica') || name.contains('music')) {
      return EpgProgram(
        title: 'Los Éxitos del Momento: Top 20 en Directo',
        subtitle: 'Videoclips oficiales sin pausas comerciales',
        timeRange: timeStr,
        nextTitle: 'A continuación: Especial Musical de Colección',
        remainingMinutes: remaining,
        progress: prog,
      );
    }

    // 6. Genérico Coherente (usa el nombre real del canal para personalizarlo)
    final displayName = _getChannelName(channel);
    return EpgProgram(
      title: 'Transmisión Especial: $displayName',
      subtitle: 'Programación regular en emisión continua de alta calidad',
      timeRange: timeStr,
      nextTitle: 'A continuación: Continuidad de Programación',
      remainingMinutes: remaining,
      progress: prog,
    );
  }

  /// Método requerido por main.dart: obtiene el programa en vivo actual
  static EpgProgram getCurrentProgram(String channelName, String groupCategory) {
    return getProgramForChannel(channelName);
  }

  /// Método requerido por main.dart: obtiene el siguiente programa
  static EpgProgram getNextProgram(String channelName, String groupCategory) {
    final prog = getProgramForChannel(channelName);
    final now = DateTime.now();
    final nextHour = (now.hour + 1) % 24;
    final afterNextHour = (now.hour + 2) % 24;
    final nextTimeRange = '${nextHour.toString().padLeft(2, '0')}:00 - ${afterNextHour.toString().padLeft(2, '0')}:00';

    return EpgProgram(
      title: prog.nextTitle.isNotEmpty ? prog.nextTitle.replaceAll('A continuación: ', '') : 'Continuidad de Programación',
      timeRange: nextTimeRange,
      remainingMinutes: 60,
      progress: 0.0,
    );
  }

  /// Método requerido por main.dart: lista de programas para la guía y recordatorios
  static List<EpgProgram> getUpcomingPrograms(String channelName, String groupCategory) {
    final now = DateTime.now();
    final currentHour = now.hour;
    final name = channelName.toLowerCase();

    String title1, title2, title3, title4;

    if (name.contains('espn 3') || name.contains('espn3') || name.contains('mlb') || name.contains('beisbol')) {
      title1 = 'Béisbol de Grandes Ligas MLB: Playoffs en Vivo';
      title2 = 'SportsCenter Noche: Resumen MLB';
      title3 = 'Béisbol Esta Noche: Análisis y Estadísticas';
      title4 = 'MLB Clásicos: Partidos Históricos';
    } else if (name.contains('espn 2') || name.contains('espn2')) {
      title1 = 'Fútbol en Vivo: Liga Continental';
      title2 = 'Equipo F: Debate Post-Partido';
      title3 = 'Resumen de Goles de la Jornada';
      title4 = 'Fútbol Internacional Retro';
    } else if (name.contains('espn') || name.contains('fox') || name.contains('tyc')) {
      title1 = 'SportsCenter: Edición Central en Directo';
      title2 = 'Fútbol Total en Vivo';
      title3 = 'Debate Deportivo Especial';
      title4 = 'Noticias Deportivas de Medianoche';
    } else if (name.contains('hbo') || name.contains('tnt') || name.contains('cine')) {
      title1 = 'Cine Estelar: Película de Acción en HD';
      title2 = 'Función de Medianoche en HD';
      title3 = 'Cine de Suspenso y Misterio';
      title4 = 'Estrenos de la Semana';
    } else if (name.contains('1+1') || name.contains('cnn') || name.contains('noticia')) {
      title1 = 'Noticiero Internacional: Cobertura en Vivo';
      title2 = 'Panorama Político y Económico';
      title3 = 'Edición Especial de Noticias';
      title4 = 'Resumen Informativo Global';
    } else {
      title1 = 'Emisión en Directo: $channelName';
      title2 = 'Espacio de Entretenimiento';
      title3 = 'Programa Estelar Nocturno';
      title4 = 'Cierre de Transmisión';
    }

    String formatRange(int hOffset) {
      final hStart = (currentHour + hOffset) % 24;
      final hEnd = (currentHour + hOffset + 1) % 24;
      return '${hStart.toString().padLeft(2, '0')}:00 - ${hEnd.toString().padLeft(2, '0')}:00';
    }

    final remaining = 60 - now.minute;
    final prog = (now.minute / 60.0).clamp(0.0, 1.0);

    return [
      EpgProgram(title: title1, timeRange: formatRange(0), remainingMinutes: remaining, progress: prog),
      EpgProgram(title: title2, timeRange: formatRange(1)),
      EpgProgram(title: title3, timeRange: formatRange(2)),
      EpgProgram(title: title4, timeRange: formatRange(3)),
    ];
  }

  static String _getChannelName(dynamic item) {
    if (item == null) return 'Canal en Vivo';
    try { return (item.name ?? '').toString(); } catch (_) {}
    try { return (item.title ?? '').toString(); } catch (_) {}
    try { return (item['name'] ?? item['title'] ?? '').toString(); } catch (_) {}
    return item.toString();
  }
}