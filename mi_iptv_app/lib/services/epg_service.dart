import 'dart:convert';
import 'package:http/http.dart' as http;

class EpgProgram {
  final String title;
  final String subtitle;
  final String timeRange;
  final String nextTitle;
  final double progress;
  final int remainingMinutes;

  const EpgProgram({
    required this.title,
    required this.subtitle,
    required this.timeRange,
    required this.nextTitle,
    this.progress = 0.5,
    this.remainingMinutes = 30,
  });

  String get timeFormatted => timeRange;
}

class _XmlTvSlot {
  final DateTime start;
  final DateTime stop;
  final String title;
  final String desc;

  const _XmlTvSlot({
    required this.start,
    required this.stop,
    required this.title,
    required this.desc,
  });
}

class EpgService {
  // Caché opcional en memoria para fuentes XMLTV externas
  static final Map<String, List<_XmlTvSlot>> _xmlTvCache = {};

  /// Permite cargar una guía XMLTV real desde una URL (.xml) si el proveedor IPTV la ofrece
  static Future<int> loadXmlTvFromUrl(String xmlUrl) async {
    try {
      final uri = Uri.tryParse(xmlUrl.trim());
      if (uri == null) return 0;
      final response = await http.get(uri).timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return 0;
      return parseXmlTvContent(utf8.decode(response.bodyBytes, allowMalformed: true));
    } catch (_) {
      return 0;
    }
  }

  /// Parser ligero de estándar XMLTV (<programme start="..." stop="..." channel="...">)
  static int parseXmlTvContent(String xmlContent) {
    int count = 0;
    try {
      final progRegex = RegExp(
        r'<programme[^>]*start="([^"]+)"[^>]*stop="([^"]+)"[^>]*channel="([^"]+)"[^>]*>([\s\S]*?)<\/programme>',
        caseSensitive: false,
      );
      final titleRegex = RegExp(r'<title[^>]*>([\s\S]*?)<\/title>', caseSensitive: false);
      final descRegex = RegExp(r'<desc[^>]*>([\s\S]*?)<\/desc>', caseSensitive: false);

      for (final match in progRegex.allMatches(xmlContent)) {
        final rawStart = match.group(1) ?? '';
        final rawStop = match.group(2) ?? '';
        final rawChannel = (match.group(3) ?? '').trim().toLowerCase();
        final innerXml = match.group(4) ?? '';

        final startDt = _parseXmlTvDate(rawStart);
        final stopDt = _parseXmlTvDate(rawStop);
        if (startDt == null || stopDt == null || rawChannel.isEmpty) continue;

        final titleMatch = titleRegex.firstMatch(innerXml);
        final descMatch = descRegex.firstMatch(innerXml);

        final cleanTitle = _unescapeXml(titleMatch?.group(1) ?? 'Transmisión en Vivo');
        final cleanDesc = _unescapeXml(descMatch?.group(1) ?? 'Emisión en directo');

        _xmlTvCache.putIfAbsent(rawChannel, () => []).add(
          _XmlTvSlot(
            start: startDt,
            stop: stopDt,
            title: cleanTitle,
            desc: cleanDesc,
          ),
        );
        count++;
      }
    } catch (_) {}
    return count;
  }

  static DateTime? _parseXmlTvDate(String raw) {
    try {
      final digits = raw.split(' ').first.trim();
      if (digits.length < 12) return null;
      final year = int.parse(digits.substring(0, 4));
      final month = int.parse(digits.substring(4, 6));
      final day = int.parse(digits.substring(6, 8));
      final hour = int.parse(digits.substring(8, 10));
      final minute = int.parse(digits.substring(10, 12));
      return DateTime(year, month, day, hour, minute);
    } catch (_) {
      return null;
    }
  }

  static String _unescapeXml(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .trim();
  }

  /// Método principal compatible con widgets/overlay
  static EpgProgram getProgramForChannel(dynamic channel) {
    final name = _getChannelName(channel);
    final cat = _getChannelCategory(channel);
    return getCurrentProgram(name, cat);
  }

  /// Obtiene el programa EN VIVO actual para el canal según la hora exacta del reloj
  static EpgProgram getCurrentProgram(String channelName, [String? category]) {
    final now = DateTime.now();
    return _buildProgramForSlot(
      channelName: channelName,
      category: category ?? '',
      slotTime: now,
      isCurrentSlot: true,
    );
  }

  /// Obtiene el siguiente programa inmediato (próxima hora)
  static EpgProgram getNextProgram(String channelName, [String? category]) {
    final nextSlotTime = DateTime.now().add(const Duration(hours: 1));
    return _buildProgramForSlot(
      channelName: channelName,
      category: category ?? '',
      slotTime: nextSlotTime,
      isCurrentSlot: false,
    );
  }

  /// Genera la parrilla completa de las próximas 8 horas para la Guía EPG interactiva y alarmas
  static List<EpgProgram> getUpcomingPrograms(String channelName, [String? category]) {
    final now = DateTime.now();
    final List<EpgProgram> schedule = [];

    for (int offsetHours = 0; offsetHours < 8; offsetHours++) {
      final slotTime = now.add(Duration(hours: offsetHours));
      schedule.add(
        _buildProgramForSlot(
          channelName: channelName,
          category: category ?? '',
          slotTime: slotTime,
          isCurrentSlot: offsetHours == 0,
        ),
      );
    }

    return schedule;
  }

  static EpgProgram _buildProgramForSlot({
    required String channelName,
    required String category,
    required DateTime slotTime,
    required bool isCurrentSlot,
  }) {
    final cleanName = channelName.trim().isEmpty ? 'Canal en Vivo' : channelName.trim();
    final lowerName = cleanName.toLowerCase();
    final lowerCat = category.toLowerCase();

    final hour = slotTime.hour;
    final nextHour = (hour + 1) % 24;
    final startStr = hour.toString().padLeft(2, '0');
    final endStr = nextHour.toString().padLeft(2, '0');
    final timeRange = '$startStr:00 - $endStr:00';

    final int remMinutes = isCurrentSlot ? (60 - slotTime.minute).clamp(1, 60) : 60;
    final double progressVal = isCurrentSlot
        ? (slotTime.minute / 60.0).clamp(0.04, 0.96)
        : 0.0;

    // 1. Si existe información XMLTV cargada para este canal, priorizarla
    final xmlKey = lowerName.replaceAll(' ', '');
    if (_xmlTvCache.containsKey(xmlKey)) {
      final slots = _xmlTvCache[xmlKey]!;
      for (final slot in slots) {
        if (slotTime.isAfter(slot.start) && slotTime.isBefore(slot.stop)) {
          final totalMin = slot.stop.difference(slot.start).inMinutes.clamp(1, 300);
          final elapsedMin = slotTime.difference(slot.start).inMinutes.clamp(0, totalMin);
          final sH = slot.start.hour.toString().padLeft(2, '0');
          final sM = slot.start.minute.toString().padLeft(2, '0');
          final eH = slot.stop.hour.toString().padLeft(2, '0');
          final eM = slot.stop.minute.toString().padLeft(2, '0');

          return EpgProgram(
            title: slot.title,
            subtitle: slot.desc,
            timeRange: '$sH:$sM - $eH:$eM',
            nextTitle: 'Siguiente emisión en programación',
            progress: isCurrentSlot ? (elapsedMin / totalMin).clamp(0.04, 0.96) : 0.0,
            remainingMinutes: (totalMin - elapsedMin).clamp(1, 300),
          );
        }
      }
    }

    // Semilla única por nombre de canal para que dos canales de la misma categoría NO muestren lo mismo a la misma hora
    final int channelSeed = cleanName.codeUnits.fold<int>(0, (prev, elem) => prev + elem);

    final currentSlotData = _resolveSmartSlot(
      cleanName: cleanName,
      lowerName: lowerName,
      lowerCat: lowerCat,
      hour: hour,
      channelSeed: channelSeed,
    );

    final nextSlotData = _resolveSmartSlot(
      cleanName: cleanName,
      lowerName: lowerName,
      lowerCat: lowerCat,
      hour: nextHour,
      channelSeed: channelSeed,
    );

    return EpgProgram(
      title: currentSlotData['title']!,
      subtitle: currentSlotData['subtitle']!,
      timeRange: timeRange,
      nextTitle: nextSlotData['title']!,
      progress: progressVal,
      remainingMinutes: remMinutes,
    );
  }

  static Map<String, String> _resolveSmartSlot({
    required String cleanName,
    required String lowerName,
    required String lowerCat,
    required int hour,
    required int channelSeed,
  }) {
    // =========================================================================
    // 1. BÉISBOL / MLB / ESPN 3
    // =========================================================================
    if (lowerName.contains('espn 3') ||
        lowerName.contains('espn3') ||
        lowerName.contains('mlb') ||
        lowerName.contains('beisbol') ||
        lowerName.contains('béisbol') ||
        lowerName.contains('baseball') ||
        lowerName.contains('ivc')) {
      const lineup = [
        {'title': 'MLB Network: Resumen de Grandes Ligas', 'subtitle': 'Las mejores jugadas, cuadrangulares y estadísticas de la jornada'},
        {'title': 'Clásicos del Béisbol: Serie Mundial Histórica', 'subtitle': 'Partidos inolvidables de postemporada completos'},
        {'title': 'Béisbol al Día: Previa y Rosters Oficiales', 'subtitle': 'Análisis de abridores, bullpen y alineaciones confirmadas'},
        {'title': 'Béisbol MLB en Vivo: Juego de la Semana', 'subtitle': 'Transmisión en directo entrada por entrada con audio original y latino'},
        {'title': 'Grandes Ligas en Directo: Duelo Divisional', 'subtitle': 'Cobertura exclusiva desde el diamante en Full HD'},
        {'title': 'Zona de Strike: Debate de Béisbol Invernal y MLB', 'subtitle': 'Mesa redonda con especialistas del Caribe y Grandes Ligas'},
        {'title': 'Béisbol Estelar en Vivo: Serie de Campeonato', 'subtitle': 'Transmisión estelar nocturna en vivo'},
        {'title': 'SportsCenter Béisbol: Compacto de la Noche', 'subtitle': 'Todos los resultados y pizarras finales de la jornada'},
      ];
      return lineup[(hour + (channelSeed % 3)) % lineup.length];
    }

    // =========================================================================
    // 2. DEPORTES Y FÚTBOL (ESPN, ESPN 2, FOX SPORTS, DSPORTS, TYC, TUDN, WIN, TNT SPORTS)
    // =========================================================================
    if (lowerName.contains('espn') ||
        lowerName.contains('fox sports') ||
        lowerName.contains('dsports') ||
        lowerName.contains('directv sports') ||
        lowerName.contains('tyc') ||
        lowerName.contains('tudn') ||
        lowerName.contains('win sports') ||
        lowerName.contains('tnt sports') ||
        lowerName.contains('gol ') ||
        lowerName.contains('golperu') ||
        lowerName.contains('liga 1') ||
        lowerName.contains('dazn') ||
        lowerName.contains('ufc') ||
        lowerName.contains('nba') ||
        lowerName.contains('claro sports') ||
        lowerName.contains('f1') ||
        lowerCat.contains('deporte') ||
        lowerCat.contains('sport') ||
        lowerCat.contains('futbol') ||
        lowerCat.contains('fútbol')) {
      if (hour >= 6 && hour < 12) {
        const morningSports = [
          {'title': 'SportsCenter Matutino: Edición en Vivo', 'subtitle': 'Resumen completo de goles, tenis, motor y actualidad internacional'},
          {'title': 'Agenda Deportiva AM: Entrenamientos y Ruedas de Prensa', 'subtitle': 'Cobertura en directo desde los principales clubes'},
          {'title': 'Fútbol Europeo: Compacto de la Fecha', 'subtitle': 'Lo mejor de la Premier League, LaLiga y Serie A'},
          {'title': 'Debate Matinal: Análisis Táctico', 'subtitle': 'La previa de los compromisos internacionales de hoy'},
        ];
        return morningSports[(hour + channelSeed) % morningSports.length];
      } else if (hour >= 12 && hour < 17) {
        const afternoonSports = [
          {'title': 'F90 / Equipo F: Debate Futbolero en Vivo', 'subtitle': 'Polémica, invitados especiales y móviles en directo'},
          {'title': 'Fútbol Internacional en Vivo: Torneo Europeo', 'subtitle': 'Transmisión oficial en alta definición con relatos en español'},
          {'title': 'Previa Estelar: Camino al Estadio', 'subtitle': 'Alineaciones confirmadas y llegada de los equipos'},
          {'title': 'Conexión Deportiva: Fútbol Sudamericano y Ligas', 'subtitle': 'Análisis en vivo de la jornada continental'},
        ];
        return afternoonSports[(hour + channelSeed) % afternoonSports.length];
      } else if (hour >= 17 && hour <= 23) {
        const primeSports = [
          {'title': 'Fútbol Estelar en Vivo: Partido de la Fecha', 'subtitle': 'Transmisión en directo desde el estadio • Audio Principal y Ambiente'},
          {'title': 'Noche de Copa en Directo: Fase de Grupos / Eliminatorias', 'subtitle': 'Cobertura exclusiva con cámaras tácticas y análisis en vivo'},
          {'title': 'Boxeo y MMA Estelar: Cartelera Internacional', 'subtitle': 'Combates titulares en directo desde la arena principal'},
          {'title': 'Post-Partido y Línea de Tiempo: Todos los Goles', 'subtitle': 'Conferencias de prensa de los entrenadores y figuras del encuentro'},
          {'title': 'SportsCenter Edición Central Nocturna', 'subtitle': 'El resumen más completo del día deportivo'},
        ];
        return primeSports[(hour + channelSeed) % primeSports.length];
      } else {
        const nightSports = [
          {'title': 'Repetición Estelar: El Partido de la Jornada', 'subtitle': 'Retransmisión íntegra del encuentro más destacado'},
          {'title': 'Especiales del Deporte: Leyendas del Fútbol Mundial', 'subtitle': 'Documental biográfico y goles históricos'},
          {'title': 'Compacto Internacional: Goles de la Semana', 'subtitle': 'Resumen continuo sin cortes comerciales'},
        ];
        return nightSports[(hour + channelSeed) % nightSports.length];
      }
    }

    // =========================================================================
    // 3. CINE Y SERIES PREMIUM (HBO, TNT, SPACE, CINECANAL, STAR, WARNER, SONY, AXN, FX, AMC, GOLDEN)
    // =========================================================================
    if (lowerName.contains('hbo') ||
        lowerName.contains('tnt') ||
        lowerName.contains('space') ||
        lowerName.contains('cinecanal') ||
        lowerName.contains('star') ||
        lowerName.contains('warner') ||
        lowerName.contains('sony') ||
        lowerName.contains('axn') ||
        lowerName.contains('fx') ||
        lowerName.contains('amc') ||
        lowerName.contains('universal') ||
        lowerName.contains('paramount') ||
        lowerName.contains('cinemax') ||
        lowerName.contains('golden') ||
        lowerName.contains('pelicula') ||
        lowerName.contains('película') ||
        lowerName.contains('movie') ||
        lowerName.contains('cine') ||
        lowerName.contains('syfy') ||
        lowerCat.contains('cine') ||
        lowerCat.contains('pelicula') ||
        lowerCat.contains('movie') ||
        lowerCat.contains('serie')) {
      const moviesLineup = [
        {'title': 'Cine Taquilla: Duna — Parte Dos (FHD)', 'subtitle': 'Ciencia Ficción / Épica • Audio Español Latino y Subtítulos'},
        {'title': 'Acción Sin Límites: John Wick 4', 'subtitle': 'Acción / Suspenso • Función especial sin cortes'},
        {'title': 'Estreno Estelar: Oppenheimer', 'subtitle': 'Drama Histórico • Ganadora de 7 Premios de la Academia'},
        {'title': 'Maratón de Series: The Last of Us — Temporada Estelar', 'subtitle': 'Episodio doble en alta definición'},
        {'title': 'Superproducción: Misión Imposible — Sentencia Mortal', 'subtitle': 'Acción / Espionaje • Proyección de alta definición'},
        {'title': 'Noche de Adrenalina: Top Gun — Maverick', 'subtitle': 'Acción / Aviación • Sonido Envolvente Digital'},
        {'title': 'Especial DC: Batman — El Caballero de la Noche', 'subtitle': 'Acción / Crimen • Clásico moderno de colección'},
        {'title': 'Cine de Suspenso: En un Lugar en Silencio — Día Uno', 'subtitle': 'Suspenso / Thriller • Emisión estelar'},
        {'title': 'Serie Original: La Casa del Dragón', 'subtitle': 'Fantasía Épica • Episodio de estreno en español'},
        {'title': 'Blockbuster: Spider-Man — A Través del Spider-Verso', 'subtitle': 'Animación / Acción • Edición Especial'},
        {'title': 'Cine de Acción: Gladiador — Edición Extendida', 'subtitle': 'Épica / Aventura • Transmisión remasterizada'},
        {'title': 'Thriller Nocturno: Rescate Imposible', 'subtitle': 'Acción / Suspenso • Función continua'},
      ];
      return moviesLineup[(hour + channelSeed) % moviesLineup.length];
    }

    // =========================================================================
    // 4. CANALES INFANTILES Y ANIME (CARTOON NETWORK, DISNEY, NICK, DISCOVERY KIDS, ETC.)
    // =========================================================================
    if (lowerName.contains('cartoon') ||
        lowerName.contains('disney') ||
        lowerName.contains('nick') ||
        lowerName.contains('kids') ||
        lowerName.contains('junior') ||
        lowerName.contains('toon') ||
        lowerName.contains('boing') ||
        lowerName.contains('infantil') ||
        lowerName.contains('anime') ||
        lowerName.contains('bitme') ||
        lowerCat.contains('infantil') ||
        lowerCat.contains('kids') ||
        lowerCat.contains('niños') ||
        lowerCat.contains('anime')) {
      const kidsLineup = [
        {'title': 'El Increíble Mundo de Gumball: Maratón de Risas', 'subtitle': 'Episodios seguidos llenos de aventuras en Elmore'},
        {'title': 'Bluey y Bingo: Juegos en Familia', 'subtitle': 'Serie infantil educativa • Doblaje oficial latino'},
        {'title': 'Bob Esponja: Aventuras en Fondo de Bikini', 'subtitle': 'Comedia animada clásica • Episodios dobles'},
        {'title': 'Los Jóvenes Titanes en Acción: Misión Especial', 'subtitle': 'Animación y comedia de superhéroes'},
        {'title': 'Paw Patrol: Patrulla Canina al Rescate', 'subtitle': 'Aventuras preescolares en Bahía Aventura'},
        {'title': 'Miraculous: Las Aventuras de Ladybug y Cat Noir', 'subtitle': 'Acción y animación desde París'},
        {'title': 'Bloque Anime: Dragon Ball Super — Torneo de la Fuerza', 'subtitle': 'Saga completa en alta definición'},
        {'title': 'Cine Infantil en Casa: Película Animada Familiar', 'subtitle': 'Función especial para toda la familia'},
      ];
      return kidsLineup[(hour + channelSeed) % kidsLineup.length];
    }

    // =========================================================================
    // 5. DOCUMENTALES, CULTURA Y ESTILO DE VIDA (DISCOVERY, HISTORY, NATGEO, ANIMAL PLANET, ID, H&H)
    // =========================================================================
    if (lowerName.contains('discovery') ||
        lowerName.contains('history') ||
        lowerName.contains('natgeo') ||
        lowerName.contains('national geographic') ||
        lowerName.contains('animal planet') ||
        lowerName.contains('tlc') ||
        lowerName.contains('h&h') ||
        lowerName.contains('home & health') ||
        lowerName.contains('gourmet') ||
        lowerName.contains('food') ||
        lowerCat.contains('documental') ||
        lowerCat.contains('cultura')) {
      const docLineup = [
        {'title': 'El Precio de la Historia: Reliquias Millonarias', 'subtitle': 'Negociaciones únicas de objetos históricos en Las Vegas'},
        {'title': 'Alerta Aeropuerto: Operativos en Frontera', 'subtitle': 'Casos reales de seguridad e inspección internacional'},
        {'title': 'Supervivencia al Desnudo: Desafío Extremo', 'subtitle': '21 días en los ecosistemas más salvajes del planeta'},
        {'title': 'Alienígenas Ancestrales: Misterios de las Civilizaciones', 'subtitle': 'Investigación arqueológica y enigmas de la historia'},
        {'title': 'Hermanos a la Obra: Renovación Total', 'subtitle': 'Diseño, arquitectura y transformación de hogares'},
        {'title': 'Planeta Tierra: Vida Salvaje en 4K', 'subtitle': 'Documental de naturaleza con fotografía cinematográfica'},
        {'title': 'Crímenes Imperfectos: Investigación Forense', 'subtitle': 'Reconstrucción detallada de casos reales'},
        {'title': 'Rutas Mortales: Camioneros del Hielo', 'subtitle': 'Travesías extremas por las carreteras más peligrosas'},
      ];
      return docLineup[(hour + channelSeed) % docLineup.length];
    }

    // =========================================================================
    // 6. NOTICIAS 24 HORAS (CNN, NTN24, DW, RT, FRANCE 24, TN, C5N, CANAL N, RPP, 24 HORAS, 1+1)
    // =========================================================================
    if (lowerName.contains('cnn') ||
        lowerName.contains('ntn24') ||
        lowerName.contains('dw') ||
        lowerName.contains('france 24') ||
        lowerName.contains('euronews') ||
        lowerName.contains('rt ') ||
        lowerName.contains('tn ') ||
        lowerName.contains('c5n') ||
        lowerName.contains('ln+') ||
        lowerName.contains('canal n') ||
        lowerName.contains('rpp') ||
        lowerName.contains('milenio') ||
        lowerName.contains('foro') ||
        lowerName.contains('24 horas') ||
        lowerName.contains('globovision') ||
        lowerName.contains('globovisión') ||
        lowerName.contains('1+1') ||
        lowerName.contains('noticia') ||
        lowerName.contains('news') ||
        lowerCat.contains('noticia') ||
        lowerCat.contains('news')) {
      if (hour >= 5 && hour < 12) {
        return {
          'title': 'Noticiero Matutino en Vivo: Titulares del Mundo ($cleanName)',
          'subtitle': 'Primer reporte del día, mercados internacionales, clima y corresponsales en directo',
        };
      } else if (hour >= 12 && hour < 18) {
        return {
          'title': 'Edición Meridiana: Panorama Internacional en Directo',
          'subtitle': 'Cobertura minuto a minuto de las noticias más importantes de la jornada',
        };
      } else if (hour >= 18 && hour <= 23) {
        return {
          'title': 'Edición Central y Debate Político: Análisis a Fondo',
          'subtitle': 'Entrevistas exclusivas, economía global y mesa de periodistas en vivo',
        };
      } else {
        return {
          'title': 'Reporte Nocturno Internacional: Resumen de Medianoche',
          'subtitle': 'Actualización continua las 24 horas con enlaces internacionales',
        };
      }
    }

    // =========================================================================
    // 7. MÚSICA Y VARIEDADES (HTV, MTV, TELEHIT, VH1, QUIERO MÚSICA)
    // =========================================================================
    if (lowerName.contains('htv') ||
        lowerName.contains('mtv') ||
        lowerName.contains('telehit') ||
        lowerName.contains('vh1') ||
        lowerName.contains('musica') ||
        lowerName.contains('música') ||
        lowerName.contains('music') ||
        lowerName.contains('kally') ||
        lowerCat.contains('musica') ||
        lowerCat.contains('música') ||
        lowerCat.contains('music')) {
      const musicLineup = [
        {'title': 'Hot Ranking Latino: Los 20 Más Pedidos', 'subtitle': 'Los éxitos urbanos, pop y tropicales que dominan las listas'},
        {'title': 'Especial en Concierto: Gira Internacional en Vivo', 'subtitle': 'Presentaciones en directo con sonido de alta fidelidad'},
        {'title': 'Clásicos de Oro: Éxitos Inolvidables', 'subtitle': 'Los mejores videoclips de los 90s, 2000s y actualidad'},
        {'title': 'Sesiones Acústicas y Estrenos de la Semana', 'subtitle': 'Nuevos lanzamientos musicales sin interrupciones'},
      ];
      return musicLineup[(hour + channelSeed) % musicLineup.length];
    }

    // =========================================================================
    // 8. CANALES NACIONALES, ABIERTOS Y VARIEDADES LATINAS (POR FRANJA HORARIA REAL)
    // (Telemundo, Univision, Caracol, RCN, Latina, América, Las Estrellas, Azteca, Telefe, etc.)
    // =========================================================================
    if (hour >= 6 && hour < 12) {
      const morningGeneral = [
        {'title': 'Magazine Matutino en Vivo: La Mañana con Todo', 'subtitle': 'Actualidad, entretenimiento, cocina en vivo y entrevistas exclusivas'},
        {'title': 'Noticiero Primera Edición: Despierta Informado', 'subtitle': 'Enlaces en vivo desde las calles, tránsito y noticias nacionales'},
        {'title': 'Mañanas en Familia: Salud, Hogar y Variedades', 'subtitle': 'Consejos prácticos, invitados especiales y horóscopo del día'},
      ];
      final pick = morningGeneral[(hour + channelSeed) % morningGeneral.length];
      return {
        'title': '${pick['title']} • $cleanName',
        'subtitle': pick['subtitle']!,
      };
    } else if (hour >= 12 && hour < 15) {
      const middayGeneral = [
        {'title': 'Noticiero Edición Mediodía en Directo', 'subtitle': 'El resumen informativo más completo de la mitad de la jornada'},
        {'title': 'Espectáculos y Mediodía: Lo Último de la Farándula', 'subtitle': 'Exclusivas del entretenimiento, música y televisión en vivo'},
      ];
      final pick = middayGeneral[(hour + channelSeed) % middayGeneral.length];
      return {
        'title': '${pick['title']} • $cleanName',
        'subtitle': pick['subtitle']!,
      };
    } else if (hour >= 15 && hour < 19) {
      const afternoonGeneral = [
        {'title': 'Tardes de Telenovela: Capítulo de Estreno', 'subtitle': 'Drama y romance • Emisión vespertina en alta definición'},
        {'title': 'Cine Familiar de la Tarde', 'subtitle': 'Película doblada al español para disfrutar en casa'},
        {'title': 'Show de Concursos y Entretenimiento en Vivo', 'subtitle': 'Competencias, premios y diversión para toda la familia'},
      ];
      final pick = afternoonGeneral[(hour + channelSeed) % afternoonGeneral.length];
      return {
        'title': '${pick['title']} • $cleanName',
        'subtitle': pick['subtitle']!,
      };
    } else if (hour >= 19 && hour <= 23) {
      const primeGeneral = [
        {'title': 'Noticiero Central Estelar en Vivo', 'subtitle': 'Las noticias más relevantes del país y el mundo en horario central'},
        {'title': 'Gala Estelar Prime Time: Reality y Competencia en Vivo', 'subtitle': 'Emisión estelar de la noche con votaciones y sorpresas en directo'},
        {'title': 'Superproducción Estelar de las 9: Capítulo Clave', 'subtitle': 'La serie/novela más vista del horario nocturno'},
        {'title': 'Noche de Estrenos y Especial Periodístico', 'subtitle': 'Investigación, reportajes a fondo y debate nacional'},
      ];
      final pick = primeGeneral[(hour + channelSeed) % primeGeneral.length];
      return {
        'title': '${pick['title']} • $cleanName',
        'subtitle': pick['subtitle']!,
      };
    } else {
      const lateNightGeneral = [
        {'title': 'Función Nocturna de Medianoche', 'subtitle': 'Películas y series seleccionadas en horario de trasnoche'},
        {'title': 'Lo Mejor de la Jornada: Repetición Estelar', 'subtitle': 'Revive los mejores momentos de la programación del día'},
      ];
      final pick = lateNightGeneral[(hour + channelSeed) % lateNightGeneral.length];
      return {
        'title': '${pick['title']} • $cleanName',
        'subtitle': pick['subtitle']!,
      };
    }
  }

  static String _getChannelName(dynamic item) {
    if (item == null) return 'Canal en Vivo';
    if (item is String) return item;
    try {
      if (item.name != null && item.name.toString().isNotEmpty) {
        return item.name.toString();
      }
    } catch (_) {}
    try {
      if (item.title != null && item.title.toString().isNotEmpty) {
        return item.title.toString();
      }
    } catch (_) {}
    try {
      if (item is Map) {
        final val = item['name'] ?? item['title'];
        if (val != null) return val.toString();
      }
    } catch (_) {}
    return 'Canal en Vivo';
  }

  static String _getChannelCategory(dynamic item) {
    if (item == null || item is String) return '';
    try {
      if (item.groupCategory != null) {
        return item.groupCategory.toString();
      }
    } catch (_) {}
    try {
      if (item is Map && item['groupCategory'] != null) {
        return item['groupCategory'].toString();
      }
    } catch (_) {}
    return '';
  }
}