class EpgProgram {
  final String title;
  final String subtitle;
  final String timeRange;
  final String nextTitle;

  const EpgProgram({
    required this.title,
    required this.subtitle,
    required this.timeRange,
    required this.nextTitle,
  });
}

class EpgService {
  /// Retorna un programa realista, coherente con el nombre del canal y la hora actual
  static EpgProgram getProgramForChannel(dynamic channel) {
    final name = _getChannelName(channel).toLowerCase();
    final now = DateTime.now();
    final currentHour = now.hour;
    final timeStr = '${currentHour.toString().padLeft(2, '0')}:00 - ${(currentHour + 1).toString().padLeft(2, '0')}:00';

    // 1. Canales de Béisbol o ESPN 3 (como en tu captura)
    if (name.contains('espn 3') || name.contains('espn3') || name.contains('mlb') || name.contains('beisbol') || name.contains('baseball')) {
      return EpgProgram(
        title: 'Béisbol de Grandes Ligas MLB: Playoffs en Directo',
        subtitle: 'Cobertura en vivo de la Serie de Campeonato • Entrada por Entrada',
        timeRange: timeStr,
        nextTitle: 'A continuación: SportsCenter Noche / Resumen de Béisbol',
      );
    }

    // 2. Canales de Fútbol / Deportes Generales (ESPN, ESPN 2, TyC, Fox Sports)
    if (name.contains('espn 2') || name.contains('espn2')) {
      return EpgProgram(
        title: 'Fútbol en Vivo: Liga Continental de Clubes',
        subtitle: 'Transmisión estelar con relatos y comentarios oficiales',
        timeRange: timeStr,
        nextTitle: 'A continuación: Equipo F / Debate Deportivo',
      );
    }
    if (name.contains('espn') || name.contains('fox sports') || name.contains('tyc') || name.contains('directv sports') || name.contains('dsports')) {
      return EpgProgram(
        title: 'SportsCenter: Edición Central en Directo',
        subtitle: 'Goles, jugadas destacadas y entrevistas exclusivas de la jornada',
        timeRange: timeStr,
        nextTitle: 'A continuación: Fútbol Total en Vivo',
      );
    }

    // 3. Canales de Películas y Series (HBO, TNT, Cinecanal, Star, etc.)
    if (name.contains('hbo') || name.contains('tnt') || name.contains('cine') || name.contains('movie') || name.contains('star')) {
      return EpgProgram(
        title: 'Cine Estelar: Película de Acción en HD',
        subtitle: 'Transmisión con audio original y doblaje en español latino',
        timeRange: timeStr,
        nextTitle: 'A continuación: Función de Medianoche',
      );
    }

    // 4. Canales de Noticias (CNN, TN, C5N, 1+1, etc.)
    if (name.contains('1+1') || name.contains('cnn') || name.contains('noticia') || name.contains('news') || name.contains('tn')) {
      return EpgProgram(
        title: 'Noticiero Internacional: Cobertura en Vivo',
        subtitle: 'Resumen informativo con los principales acontecimientos del mundo',
        timeRange: timeStr,
        nextTitle: 'A continuación: Análisis Político y Económico',
      );
    }

    // 5. Canales de Música (HTV, MTV, Quiero, etc.)
    if (name.contains('htv') || name.contains('mtv') || name.contains('musica') || name.contains('music')) {
      return EpgProgram(
        title: 'Los Éxitos del Momento: Top 20 en Directo',
        subtitle: 'Videoclips oficiales sin pausas comerciales',
        timeRange: timeStr,
        nextTitle: 'A continuación: Especial Musical de Colección',
      );
    }

    // 6. Genérico Coherente (usa el nombre real del canal para personalizarlo)
    final displayName = _getChannelName(channel);
    return EpgProgram(
      title: 'Transmisión Especial: $displayName',
      subtitle: 'Programación regular en emisión continua de alta calidad',
      timeRange: timeStr,
      nextTitle: 'A continuación: Continuidad de Programación',
    );
  }

  static String _getChannelName(dynamic item) {
    if (item == null) return 'Canal en Vivo';
    try { return (item.name ?? '').toString(); } catch (_) {}
    try { return (item.title ?? '').toString(); } catch (_) {}
    try { return (item['name'] ?? item['title'] ?? '').toString(); } catch (_) {}
    return 'Canal en Vivo';
  }
}
