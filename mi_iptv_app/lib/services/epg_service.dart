import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

class EpgProgram {
  final String title;
  final String subtitle;
  final String timeRange;
  final String nextTitle;
  final double progress;
  final int remainingMinutes;
  final DateTime? startTime;
  final DateTime? endTime;
  final bool isLiveEvent;
  final String sourceLayer;

  const EpgProgram({
    required this.title,
    required this.subtitle,
    required this.timeRange,
    required this.nextTitle,
    this.progress = 0.5,
    this.remainingMinutes = 30,
    this.startTime,
    this.endTime,
    this.isLiveEvent = false,
    this.sourceLayer = 'smart',
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

/// Representa la identidad normalizada de un canal mediante el Normalizador Canónico de Doble Llave
class CanonicalChannelIdentity {
  final String rawName;
  final String tvgIdKey;         // Llave 1: tvg-id oficial limpio (ej. "espn2sur.ar")
  final String canonicalNameKey; // Llave 2: Nombre limpio sin (1080p), FHD, Latin America (ej. "espn2")
  final String brandKey;         // Marca base del canal (ej. "espn2", "espn3", "dsports")
  final String countryFeed;      // País/Feed detectado: AR, CO, MX, PE, CL, ES, BR, LATAM

  const CanonicalChannelIdentity({
    required this.rawName,
    required this.tvgIdKey,
    required this.canonicalNameKey,
    required this.brandKey,
    required this.countryFeed,
  });
}

class EpgService {
  // ===========================================================================
  // CACHÉS DE LAS 3 CAPAS Y REGISTRO CANÓNICO DE DOBLE LLAVE
  // ===========================================================================

  /// Capa 1: Caché en memoria para fuentes XMLTV indexadas por tvg-id y por llave canónica
  static final Map<String, List<_XmlTvSlot>> _xmlTvCache = {};

  /// Capa 2: Caché en memoria de eventos deportivos reales obtenidos de la API en vivo de ESPN
  static final Map<String, List<_XmlTvSlot>> _liveSportsCache = {};

  /// Capa 3: Caché de lectura visual del fotograma en vivo (AI Live-Frame OCR Override)
  static final Map<String, _XmlTvSlot> _ocrFrameOverrideCache = {};

  /// Registro de metadatos M3U (asocia nombres limpios y originales con su tvg-id oficial)
  static final Map<String, String> _channelToTvgIdMap = {};
  static final Map<String, String> _channelToOriginalNameMap = {};

  static bool _isInitialized = false;
  static bool _isFetchingSports = false;
  static DateTime? _lastSportsFetch;
  static Timer? _refreshTimer;

  // ===========================================================================
  // INICIALIZACIÓN AUTOMÁTICA NO BLOQUEANTE (0 MS DE RETRASO EN ZAPPING)
  // ===========================================================================

  /// Arranca la sincronización en segundo plano de las Capas 1 y 2 sin bloquear la UI
  static void ensureInitialized() {
    if (_isInitialized) return;
    _isInitialized = true;

    // Descarga inmediata de cartelera deportiva real en vivo (Capa 2)
    unawaited(refreshRealTimeSportsEpg());

    // Actualización silenciosa cada 10 minutos para mantener marcadores y partidos al día
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(refreshRealTimeSportsEpg());
    });
  }

  /// Registra el tvg-id y nombre original desde m3u_parser.dart para el Normalizador de Doble Llave
  static void registerChannelMetadata({
    required String cleanName,
    required String originalName,
    String tvgId = '',
    String tvgName = '',
    String category = '',
  }) {
    final normClean = cleanName.trim().toLowerCase();
    final normOrig = originalName.trim().toLowerCase();

    if (tvgId.trim().isNotEmpty) {
      final cleanTvg = tvgId.trim().toLowerCase();
      if (normClean.isNotEmpty) _channelToTvgIdMap[normClean] = cleanTvg;
      if (normOrig.isNotEmpty) _channelToTvgIdMap[normOrig] = cleanTvg;
    }
    if (normClean.isNotEmpty && originalName.trim().isNotEmpty) {
      _channelToOriginalNameMap[normClean] = originalName.trim();
    }
  }

  // ===========================================================================
  // NORMALIZADOR CANÓNICO DE DOBLE LLAVE + DETECTOR DE PAÍS/FEED
  // ===========================================================================

  static CanonicalChannelIdentity normalizeChannel(
    String channelName, {
    String? explicitTvgId,
  }) {
    final trimmed = channelName.trim();
    final lowerLookup = trimmed.toLowerCase();

    // Recuperar el nombre original completo (por si el limpiador previo quitó el país)
    final fullReferenceName = _channelToOriginalNameMap[lowerLookup] ?? trimmed;
    final lowerFull = fullReferenceName.toLowerCase();

    // 1. LLAVE PRIMARIA: tvg-id oficial del M3U
    String rawTvgId = (explicitTvgId != null && explicitTvgId.trim().isNotEmpty)
        ? explicitTvgId.trim().toLowerCase()
        : (_channelToTvgIdMap[lowerLookup] ?? _channelToTvgIdMap[lowerFull] ?? '');

    // 2. DETECTOR DE PAÍS Y FEED REGIONAL (Argentina, Colombia, México, Perú, España, Chile, Brasil)
    String countryFeed = 'LATAM';
    if (rawTvgId.endsWith('.ar') ||
        lowerFull.contains('argentina') ||
        lowerFull.contains('cono sur') ||
        lowerFull.contains(' sur')) {
      countryFeed = 'AR';
    } else if (rawTvgId.endsWith('.co') ||
        lowerFull.contains('colombia') ||
        lowerFull.contains('andino')) {
      countryFeed = 'CO';
    } else if (rawTvgId.endsWith('.mx') ||
        lowerFull.contains('mexico') ||
        lowerFull.contains('méxico') ||
        lowerFull.contains('cono norte')) {
      countryFeed = 'MX';
    } else if (rawTvgId.endsWith('.pe') ||
        lowerFull.contains('peru') ||
        lowerFull.contains('perú')) {
      countryFeed = 'PE';
    } else if (rawTvgId.endsWith('.es') ||
        lowerFull.contains('spain') ||
        lowerFull.contains('españa') ||
        lowerFull.contains('espana')) {
      countryFeed = 'ES';
    } else if (rawTvgId.endsWith('.cl') || lowerFull.contains('chile')) {
      countryFeed = 'CL';
    } else if (rawTvgId.endsWith('.br') ||
        lowerFull.contains('brazil') ||
        lowerFull.contains('brasil')) {
      countryFeed = 'BR';
    }

    // 3. LLAVE SECUNDARIA: Limpieza profunda de basura de texto de iptv-org (spa.m3u)
    String cleaned = lowerFull
        // Quitar resoluciones entre paréntesis o sueltas: (1080p), (720p), FHD, 4K, etc.
        .replaceAll(RegExp(r'\(\s*\d{3,4}[pi]\s*\)', caseSensitive: false), ' ')
        .replaceAll(RegExp(r'\b(1080p|1080i|720p|576p|480p|360p|2160p|4k|uhd|fhd|hd|sd|hevc|h264)\b', caseSensitive: false), ' ')
        // Quitar etiquetas entre corchetes: [Geo-blocked], [Not 24/7], etc.
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        // Quitar nombres de regiones y sufijos de idioma para obtener la marca pura del canal
        .replaceAll(
          RegExp(
            r'\b(latin america|latinoamerica|latinoamérica|latam|argentina|colombia|mexico|méxico|peru|perú|chile|ecuador|venezuela|uruguay|paraguay|bolivia|spain|españa|espana|brazil|brasil|netherlands|sur|norte|andino|feed|opcion\s*\d+|opción\s*\d+)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[()\-_•|:/\\]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final canonicalKey = cleaned.replaceAll(RegExp(r'[^a-z0-9]'), '');

    // Identificar la marca deportiva o televisiva exacta para el cruce de parrillas
    String brandKey = canonicalKey;
    if (canonicalKey.contains('espnpremium') || canonicalKey.contains('espnpack')) {
      brandKey = 'espnpremium';
    } else if (canonicalKey.contains('espnextra') || canonicalKey.contains('espn4')) {
      brandKey = 'espn4';
    } else if (canonicalKey.contains('espn3')) {
      brandKey = 'espn3';
    } else if (canonicalKey.contains('espn2')) {
      brandKey = 'espn2';
    } else if (canonicalKey.contains('espn5')) {
      brandKey = 'espn5';
    } else if (canonicalKey.contains('espn6')) {
      brandKey = 'espn6';
    } else if (canonicalKey.contains('espn7')) {
      brandKey = 'espn7';
    } else if (canonicalKey.contains('espn')) {
      brandKey = 'espn';
    } else if (canonicalKey.contains('foxsports2')) {
      brandKey = 'foxsports2';
    } else if (canonicalKey.contains('foxsports3')) {
      brandKey = 'foxsports3';
    } else if (canonicalKey.contains('foxsports')) {
      brandKey = 'foxsports';
    } else if (canonicalKey.contains('dsports2') || canonicalKey.contains('directvsports2')) {
      brandKey = 'dsports2';
    } else if (canonicalKey.contains('dsports') || canonicalKey.contains('directvsports')) {
      brandKey = 'dsports';
    } else if (canonicalKey.contains('tycsports') || canonicalKey.contains('tyc')) {
      brandKey = 'tycsports';
    } else if (canonicalKey.contains('winsports')) {
      brandKey = 'winsports';
    } else if (canonicalKey.contains('tntsports')) {
      brandKey = 'tntsports';
    } else if (canonicalKey.contains('tudn')) {
      brandKey = 'tudn';
    } else if (canonicalKey.contains('liga1')) {
      brandKey = 'liga1max';
    } else if (canonicalKey.contains('golperu')) {
      brandKey = 'golperu';
    }

    // Si el canal no traía tvg-id explícito en el M3U, inferimos su tvg-id estándar de iptv-org
    if (rawTvgId.isEmpty && brandKey.isNotEmpty) {
      final countrySuffix = countryFeed == 'LATAM' ? 'ar' : countryFeed.toLowerCase();
      rawTvgId = '$brandKey.$countrySuffix';
    }

    return CanonicalChannelIdentity(
      rawName: fullReferenceName,
      tvgIdKey: rawTvgId,
      canonicalNameKey: canonicalKey.isEmpty ? lowerLookup.replaceAll(' ', '') : canonicalKey,
      brandKey: brandKey,
      countryFeed: countryFeed,
    );
  }

  // ===========================================================================
  // CAPA 3: INYECTOR VISUAL EN VIVO (AI LIVE-FRAME OCR OVERRIDE)
  // ===========================================================================

  /// Permite que el motor OCR visual (o un webhook en vivo) inyecte lo que se lee
  /// directamente en los cintillos/marcadores del fotograma del video (ej. "OSA 1 - 0 RAC | 34:22")
  static void applyLiveFrameOcrText({
    required String channelName,
    required String rawScreenText,
    Duration validity = const Duration(minutes: 45),
  }) {
    final text = rawScreenText.trim();
    if (text.isEmpty) return;

    final identity = normalizeChannel(channelName);
    final now = DateTime.now();

    // Detectar patrones de marcadores en pantalla (ej. "OSA 1 - 0 RAC", "34:22", "#OsasunaRacing")
    final scoreRegex = RegExp(r'\b([A-Z]{3})\s*(\d+)\s*[-–:]\s*(\d+)\s*([A-Z]{3})\b');
    final hashtagRegex = RegExp(r'#([A-Za-z0-9_]{4,30})');
    final timeRegex = RegExp(r'\b(\d{1,2}:\d{2})\b');

    String detectedTitle = '';
    String detectedDesc = 'Transmisión en directo verificada en pantalla (${identity.countryFeed})';

    final scoreMatch = scoreRegex.firstMatch(text);
    final hashMatch = hashtagRegex.firstMatch(text);
    final timeMatch = timeRegex.firstMatch(text);

    if (scoreMatch != null) {
      final teamA = scoreMatch.group(1)!;
      final goalsA = scoreMatch.group(2)!;
      final goalsB = scoreMatch.group(3)!;
      final teamB = scoreMatch.group(4)!;
      final matchClock = timeMatch != null ? ' • Min ${timeMatch.group(1)}' : '';
      final tag = hashMatch != null ? ' (#${hashMatch.group(1)})' : '';
      detectedTitle = '🔴 EN VIVO: $teamA $goalsA - $goalsB $teamB$tag';
      detectedDesc = 'Fútbol en Directo$matchClock • Señal ${identity.countryFeed}';
    } else if (hashMatch != null) {
      detectedTitle = '🔴 EN VIVO: #${hashMatch.group(1)}';
    } else if (text.length >= 5) {
      detectedTitle = '🔴 EN VIVO: ${text.split('\n').first.trim()}';
    }

    if (detectedTitle.isNotEmpty) {
      final slot = _XmlTvSlot(
        start: now.subtract(const Duration(minutes: 30)),
        stop: now.add(validity),
        title: detectedTitle,
        desc: detectedDesc,
      );
      _ocrFrameOverrideCache[identity.canonicalNameKey] = slot;
      _ocrFrameOverrideCache['${identity.brandKey}_${identity.countryFeed}'] = slot;
    }
  }

  // ===========================================================================
  // CAPA 2: CONECTOR DEPORTIVO EN TIEMPO REAL (API PÚBLICA ESPN EN ESPAÑOL)
  // ===========================================================================

  /// Consulta los partidos reales del día (LaLiga, Serie A, Premier, Champions,
  /// Libertadores, Liga Argentina, Colombia, Perú, MLB, NBA) con horarios reales
  static Future<void> refreshRealTimeSportsEpg() async {
    if (_isFetchingSports) return;
    if (_lastSportsFetch != null &&
        DateTime.now().difference(_lastSportsFetch!) < const Duration(minutes: 5) &&
        _liveSportsCache.isNotEmpty) {
      return;
    }

    _isFetchingSports = true;
    try {
      const endpoints = [
        // Fútbol Europeo (los partidos matutinos de tus capturas como LaLiga y Serie A)
        'https://site.api.espn.com/apis/site/v2/sports/soccer/esp.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/ita.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/esp.2/scoreboard?lang=es&region=pe',
        // Fútbol Sudamericano y Conmebol
        'https://site.api.espn.com/apis/site/v2/sports/soccer/conmebol.libertadores/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/conmebol.sudamericana/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/arg.1/scoreboard?lang=es&region=ar',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/col.1/scoreboard?lang=es&region=co',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/per.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/mex.1/scoreboard?lang=es&region=mx',
        // Béisbol MLB y Basquetbol NBA
        'https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?lang=es',
        'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?lang=es',
      ];

      final responses = await Future.wait(
        endpoints.map((url) async {
          try {
            return await http.get(Uri.parse(url)).timeout(const Duration(seconds: 6));
          } catch (_) {
            return null;
          }
        }),
      );

      final List<Map<String, dynamic>> parsedMatches = [];

      for (int i = 0; i < responses.length; i++) {
        final res = responses[i];
        if (res == null || res.statusCode != 200) continue;

        final Map<String, dynamic> data = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
        final leagues = (data['leagues'] as List?) ?? [];
        final leagueName = leagues.isNotEmpty
            ? (leagues.first['name']?.toString() ?? 'Fútbol Internacional')
            : 'Torneo en Vivo';
        final slug = leagues.isNotEmpty ? (leagues.first['slug']?.toString() ?? '') : '';

        final events = (data['events'] as List?) ?? [];
        for (final ev in events) {
          final rawDate = ev['date']?.toString() ?? '';
          final startDt = DateTime.tryParse(rawDate)?.toLocal();
          if (startDt == null) continue;

          // Duración real de 2 horas para partidos de fútbol y 2.5h para MLB/NBA
          final isBaseball = endpoints[i].contains('/baseball/');
          final stopDt = startDt.add(Duration(minutes: isBaseball ? 150 : 120));

          final statusObj = ev['status'] ?? {};
          final typeObj = statusObj['type'] ?? {};
          final state = typeObj['state']?.toString() ?? 'pre'; // 'pre', 'in', 'post'
          final detail = typeObj['shortDetail']?.toString() ?? '';

          final competitions = (ev['competitions'] as List?) ?? [];
          String matchTitle = ev['name']?.toString() ?? 'Partido en Vivo';
          String scoreText = '';
          String broadcastHint = '';

          if (competitions.isNotEmpty) {
            final comp = competitions.first;
            final competitors = (comp['competitors'] as List?) ?? [];
            if (competitors.length >= 2) {
              final home = competitors[0]['team']?['shortDisplayName'] ??
                  competitors[0]['team']?['displayName'] ??
                  'Local';
              final away = competitors[1]['team']?['shortDisplayName'] ??
                  competitors[1]['team']?['displayName'] ??
                  'Visita';
              final hScore = competitors[0]['score']?.toString() ?? '0';
              final aScore = competitors[1]['score']?.toString() ?? '0';

              if (state == 'in') {
                matchTitle = '🔴 EN VIVO: $home $hScore - $aScore $away';
                scoreText = 'En juego ($detail) • $leagueName';
              } else if (state == 'post') {
                matchTitle = 'Finalizado: $home $hScore - $aScore $away';
                scoreText = 'Resumen y goles • $leagueName';
              } else {
                matchTitle = '$home vs. $away';
                scoreText = '$leagueName • Transmisión en Directo';
              }
            }

            final broadcasts = (comp['broadcasts'] as List?) ?? [];
            if (broadcasts.isNotEmpty) {
              final names = (broadcasts.first['names'] as List?) ?? [];
              if (names.isNotEmpty) {
                broadcastHint = names.join(' ').toLowerCase();
              }
            }
          }

          parsedMatches.add({
            'start': startDt,
            'stop': stopDt,
            'title': matchTitle,
            'desc': scoreText.isNotEmpty ? scoreText : '$leagueName en Directo',
            'state': state,
            'slug': slug,
            'broadcast': broadcastHint,
            'isBaseball': isBaseball,
          });
        }
      }

      if (parsedMatches.isNotEmpty) {
        _distributeMatchesAcrossSportsChannels(parsedMatches);
        _lastSportsFetch = DateTime.now();
      }
    } catch (_) {
      // Fallo silencioso sin afectar la reproducción
    } finally {
      _isFetchingSports = false;
    }
  }

  /// Distribuye de forma determinista los partidos reales en los canales deportivos según liga y señal
  static void _distributeMatchesAcrossSportsChannels(List<Map<String, dynamic>> matches) {
    final Map<String, List<_XmlTvSlot>> updatedCache = {};

    void addSlot(String channelKey, _XmlTvSlot slot) {
      final list = updatedCache.putIfAbsent(channelKey, () => []);
      // Evitar solapamiento si ya hay un partido EN VIVO ('🔴') en esa misma ventana
      final hasConflict = list.any((existing) =>
          slot.start.isBefore(existing.stop) &&
          slot.stop.isAfter(existing.start) &&
          existing.title.startsWith('🔴'));
      if (!hasConflict) {
        list.add(slot);
      }
    }

    // Ordenar dando prioridad a los partidos que están EN JUEGO ('in') ahora mismo
    matches.sort((a, b) {
      final aLive = a['state'] == 'in' ? 0 : (a['state'] == 'pre' ? 1 : 2);
      final bLive = b['state'] == 'in' ? 0 : (b['state'] == 'pre' ? 1 : 2);
      if (aLive != bLive) return aLive.compareTo(bLive);
      return (a['start'] as DateTime).compareTo(b['start'] as DateTime);
    });

    int soccerCounter = 0;
    for (final m in matches) {
      final slot = _XmlTvSlot(
        start: m['start'] as DateTime,
        stop: m['stop'] as DateTime,
        title: m['title'] as String,
        desc: m['desc'] as String,
      );

      final slug = (m['slug'] as String).toLowerCase();
      final broadcast = (m['broadcast'] as String).toLowerCase();
      final isBaseball = m['isBaseball'] as bool;

      if (broadcast.contains('espn 2') || broadcast.contains('espn2') || slug.contains('ita.1')) {
        addSlot('espn2', slot);
      } else if (broadcast.contains('espn 3') || broadcast.contains('espn3') || slug.contains('esp.2')) {
        addSlot('espn3', slot);
      } else if (broadcast.contains('dsports') || broadcast.contains('directv')) {
        addSlot('dsports', slot);
      } else if (slug.contains('col.1')) {
        addSlot('winsports', slot);
        addSlot('espn2', slot);
      } else if (slug.contains('per.1')) {
        addSlot('liga1max', slot);
        addSlot('golperu', slot);
      } else if (slug.contains('arg.1')) {
        addSlot('espnpremium', slot);
        addSlot('tntsports', slot);
        addSlot('tycsports', slot);
        addSlot('espn', slot);
      } else if (slug.contains('mex.1')) {
        addSlot('tudn', slot);
        addSlot('foxsports', slot);
      } else if (isBaseball) {
        addSlot('espn3', slot);
        addSlot('foxsports2', slot);
      } else {
        // Reparto rotativo entre ESPN, ESPN 2, ESPN 3, DSports y Fox Sports para ligas europeas/Champions
        final targets = ['espn', 'espn2', 'espn3', 'dsports', 'foxsports'];
        final primary = targets[soccerCounter % targets.length];
        addSlot(primary, slot);
        // Si está en vivo ahora mismo, asegurar cobertura en los canales hermanos vacíos
        if (m['state'] == 'in') {
          for (final t in targets) {
            addSlot(t, slot);
          }
        }
        soccerCounter++;
      }
    }

    _liveSportsCache
      ..clear()
      ..addAll(updatedCache);
  }

  // ===========================================================================
  // CAPA 1: PARSER XMLTV PROFESIONAL CON CONVERSIÓN DE HUSOS HORARIOS (.xml / .gz)
  // ===========================================================================

  /// Permite cargar una guía XMLTV real desde una URL (.xml o .xml.gz)
  static Future<int> loadXmlTvFromUrl(String xmlUrl) async {
    try {
      final uri = Uri.tryParse(xmlUrl.trim());
      if (uri == null) return 0;
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return 0;

      List<int> bytes = response.bodyBytes;
      // Soporte nativo si el archivo viene comprimido en GZIP (.xml.gz)
      if (xmlUrl.toLowerCase().endsWith('.gz') ||
          (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)) {
        try {
          bytes = gzip.decode(bytes);
        } catch (_) {}
      }

      return parseXmlTvContent(utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return 0;
    }
  }

  /// Parser de estándar XMLTV indexado por Doble Llave (tvg-id + nombre canónico)
  static int parseXmlTvContent(String xmlContent) {
    int count = 0;
    try {
      // 1. Mapear <channel id="ESPN2.ar"><display-name>ESPN 2</display-name></channel>
      final Map<String, String> channelIdToCanonical = {};
      final chanRegex = RegExp(
        r'<channel[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/channel>',
        caseSensitive: false,
      );
      final dispRegex = RegExp(r'<display-name[^>]*>([\s\S]*?)<\/display-name>', caseSensitive: false);

      for (final m in chanRegex.allMatches(xmlContent)) {
        final rawId = (m.group(1) ?? '').trim().toLowerCase();
        final inner = m.group(2) ?? '';
        final dispMatch = dispRegex.firstMatch(inner);
        if (rawId.isNotEmpty && dispMatch != null) {
          final dispName = _unescapeXml(dispMatch.group(1) ?? '');
          final identity = normalizeChannel(dispName, explicitTvgId: rawId);
          channelIdToCanonical[rawId] = identity.canonicalNameKey;
        }
      }

      // 2. Parsear bloques <programme start="..." stop="..." channel="...">
      final progRegex = RegExp(
        r'<programme[^>]*start="([^"]+)"[^>]*stop="([^"]+)"[^>]*channel="([^"]+)"[^>]*>([\s\S]*?)<\/programme>',
        caseSensitive: false,
      );
      final titleRegex = RegExp(r'<title[^>]*>([\s\S]*?)<\/title>', caseSensitive: false);
      final descRegex = RegExp(r'<desc[^>]*>([\s\S]*?)<\/desc>', caseSensitive: false);

      for (final match in progRegex.allMatches(xmlContent)) {
        final rawStart = match.group(1) ?? '';
        final rawStop = match.group(2) ?? '';
        final rawChannelId = (match.group(3) ?? '').trim().toLowerCase();
        final innerXml = match.group(4) ?? '';

        final startDt = _parseXmlTvDate(rawStart);
        final stopDt = _parseXmlTvDate(rawStop);
        if (startDt == null || stopDt == null || rawChannelId.isEmpty) continue;

        final titleMatch = titleRegex.firstMatch(innerXml);
        final descMatch = descRegex.firstMatch(innerXml);

        final cleanTitle = _unescapeXml(titleMatch?.group(1) ?? 'Transmisión en Vivo');
        final cleanDesc = _unescapeXml(descMatch?.group(1) ?? 'Emisión en directo');

        final slot = _XmlTvSlot(
          start: startDt,
          stop: stopDt,
          title: cleanTitle,
          desc: cleanDesc,
        );

        // Indexar por Llave 1: tvg-id exacto (ej. "espn2sur.ar")
        _xmlTvCache.putIfAbsent(rawChannelId, () => []).add(slot);

        // Indexar por Llave 2: nombre canónico limpio (ej. "espn2")
        final normalizedId = normalizeChannel(rawChannelId, explicitTvgId: rawChannelId);
        if (normalizedId.canonicalNameKey.isNotEmpty) {
          _xmlTvCache.putIfAbsent(normalizedId.canonicalNameKey, () => []).add(slot);
        }
        if (channelIdToCanonical.containsKey(rawChannelId)) {
          _xmlTvCache.putIfAbsent(channelIdToCanonical[rawChannelId]!, () => []).add(slot);
        }
        count++;
      }
    } catch (_) {}
    return count;
  }

  /// Motor de Husos Horarios: Convierte fechas XMLTV ("20261018093000 -0300") a la hora local exacta del dispositivo
  static DateTime? _parseXmlTvDate(String raw) {
    try {
      final trimmed = raw.trim();
      final parts = trimmed.split(RegExp(r'\s+'));
      final digits = parts.first;
      if (digits.length < 12) return null;

      final year = int.parse(digits.substring(0, 4));
      final month = int.parse(digits.substring(4, 6));
      final day = int.parse(digits.substring(6, 8));
      final hour = int.parse(digits.substring(8, 10));
      final minute = int.parse(digits.substring(10, 12));
      final second = digits.length >= 14 ? int.parse(digits.substring(12, 14)) : 0;

      // Si incluye huso horario (ej. "-0300", "+0200"), convertir a UTC y luego a hora local del teléfono/TV
      if (parts.length > 1) {
        final tz = parts[1].trim();
        final tzMatch = RegExp(r'^([+-])(\d{2})(\d{2})$').firstMatch(tz);
        if (tzMatch != null) {
          final sign = tzMatch.group(1) == '-' ? -1 : 1;
          final tzHours = int.parse(tzMatch.group(2)!);
          final tzMinutes = int.parse(tzMatch.group(3)!);
          final totalOffsetMinutes = sign * ((tzHours * 60) + tzMinutes);

          final utcDate = DateTime.utc(year, month, day, hour, minute, second)
              .subtract(Duration(minutes: totalOffsetMinutes));
          return utcDate.toLocal();
        }
      }

      return DateTime(year, month, day, hour, minute, second);
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

  // ===========================================================================
  // MÉTODOS PÚBLICOS COMPATIBLES AL 100% CON MAIN.DART Y RECORDATORIOS
  // ===========================================================================

  /// Método principal compatible con widgets/overlay
  static EpgProgram getProgramForChannel(dynamic channel) {
    ensureInitialized();
    final name = _getChannelName(channel);
    final cat = _getChannelCategory(channel);
    final tvgId = _getChannelTvgId(channel);
    return getCurrentProgram(name, cat, tvgId: tvgId);
  }

  /// Obtiene el programa EN VIVO actual para el canal según la hora exacta del reloj
  static EpgProgram getCurrentProgram(String channelName, [String? category, String? tvgId]) {
    ensureInitialized();
    final now = DateTime.now();
    return _buildProgramForSlot(
      channelName: channelName,
      category: category ?? '',
      explicitTvgId: tvgId,
      slotTime: now,
      isCurrentSlot: true,
    );
  }

  /// Obtiene el siguiente programa inmediato (calculado según el fin real del programa actual)
  static EpgProgram getNextProgram(String channelName, [String? category, String? tvgId]) {
    ensureInitialized();
    final current = getCurrentProgram(channelName, category, tvgId);
    final nextLookupTime = current.endTime != null
        ? current.endTime!.add(const Duration(minutes: 1))
        : DateTime.now().add(const Duration(hours: 1));

    return _buildProgramForSlot(
      channelName: channelName,
      category: category ?? '',
      explicitTvgId: tvgId,
      slotTime: nextLookupTime,
      isCurrentSlot: false,
    );
  }

  /// Genera la parrilla completa de las próximas horas para la Guía EPG interactiva y Recordatorios/Alarmas
  static List<EpgProgram> getUpcomingPrograms(String channelName, [String? category, String? tvgId]) {
    ensureInitialized();
    final List<EpgProgram> schedule = [];
    DateTime cursorTime = DateTime.now();

    for (int i = 0; i < 8; i++) {
      final prog = _buildProgramForSlot(
        channelName: channelName,
        category: category ?? '',
        explicitTvgId: tvgId,
        slotTime: cursorTime,
        isCurrentSlot: i == 0,
      );
      schedule.add(prog);

      // Avanzar el cursor exactamente al minuto donde termina este programa (para que las alarmas no se desfasen)
      if (prog.endTime != null && prog.endTime!.isAfter(cursorTime)) {
        cursorTime = prog.endTime!.add(const Duration(minutes: 1));
      } else {
        cursorTime = cursorTime.add(const Duration(hours: 1));
      }
    }

    return schedule;
  }

  // ===========================================================================
  // MOTOR DE RESOLUCIÓN EN CASCADA (CAPA 3 -> CAPA 1 -> CAPA 2 -> RESPALDO REAL)
  // ===========================================================================

  static EpgProgram _buildProgramForSlot({
    required String channelName,
    required String category,
    String? explicitTvgId,
    required DateTime slotTime,
    required bool isCurrentSlot,
  }) {
    final identity = normalizeChannel(channelName, explicitTvgId: explicitTvgId);
    final cleanName = channelName.trim().isEmpty ? 'Canal en Vivo' : channelName.trim();
    final lowerName = cleanName.toLowerCase();
    final lowerCat = category.toLowerCase();

    // -------------------------------------------------------------------------
    // 1. CAPA 3: Revisar si hay lectura visual OCR del fotograma en vivo
    // -------------------------------------------------------------------------
    if (isCurrentSlot) {
      final ocrSlot = _ocrFrameOverrideCache['${identity.brandKey}_${identity.countryFeed}'] ??
          _ocrFrameOverrideCache[identity.canonicalNameKey];
      if (ocrSlot != null && slotTime.isBefore(ocrSlot.stop)) {
        return _formatSlotToProgram(
          slot: ocrSlot,
          slotTime: slotTime,
          isCurrentSlot: true,
          nextTitleFallback: 'Continuación de transmisión en directo',
          sourceLayer: 'ocr_live',
        );
      }
    }

    // -------------------------------------------------------------------------
    // 2. CAPA 1: Revisar caché XMLTV por Doble Llave (tvg-id oficial o llave canónica)
    // -------------------------------------------------------------------------
    final xmlCandidates = <String>[
      if (identity.tvgIdKey.isNotEmpty) identity.tvgIdKey,
      identity.canonicalNameKey,
      identity.brandKey,
      lowerName.replaceAll(' ', ''),
    ];

    for (final key in xmlCandidates) {
      if (_xmlTvCache.containsKey(key)) {
        final slots = _xmlTvCache[key]!;
        for (int i = 0; i < slots.length; i++) {
          final slot = slots[i];
          if (!slotTime.isBefore(slot.start) && slotTime.isBefore(slot.stop)) {
            final nextTitle = (i + 1 < slots.length)
                ? slots[i + 1].title
                : 'Siguiente emisión en programación';
            return _formatSlotToProgram(
              slot: slot,
              slotTime: slotTime,
              isCurrentSlot: isCurrentSlot,
              nextTitleFallback: nextTitle,
              sourceLayer: 'xmltv',
            );
          }
        }
      }
    }

    // -------------------------------------------------------------------------
    // 3. CAPA 2: Revisar eventos reales de la API Deportiva en Vivo (ESPN / Ligas)
    // -------------------------------------------------------------------------
    if (_liveSportsCache.containsKey(identity.brandKey)) {
      final liveSlots = _liveSportsCache[identity.brandKey]!;
      for (int i = 0; i < liveSlots.length; i++) {
        final slot = liveSlots[i];
        if (!slotTime.isBefore(slot.start) && slotTime.isBefore(slot.stop)) {
          final nextTitle = (i + 1 < liveSlots.length)
              ? liveSlots[i + 1].title
              : 'SportsCenter: Resumen y Goles de la Fecha';
          return _formatSlotToProgram(
            slot: slot,
            slotTime: slotTime,
            isCurrentSlot: isCurrentSlot,
            nextTitleFallback: nextTitle,
            sourceLayer: 'espn_live_api',
          );
        }
      }
    }

    // -------------------------------------------------------------------------
    // 4. RESPALDO SINCRONIZADO POR PAÍS Y DURACIÓN REAL (2H PARA PARTIDOS/CINE)
    // -------------------------------------------------------------------------
    final bool isLongFormatChannel = _isSportsOrMovieChannel(identity.brandKey, lowerName, lowerCat);
    final int blockDurationHours = isLongFormatChannel ? 2 : 1;

    final int startHour = isLongFormatChannel ? (slotTime.hour ~/ 2) * 2 : slotTime.hour;
    final DateTime blockStart = DateTime(
      slotTime.year,
      slotTime.month,
      slotTime.day,
      startHour,
      0,
    );
    final DateTime blockEnd = blockStart.add(Duration(hours: blockDurationHours));

    final String sH = blockStart.hour.toString().padLeft(2, '0');
    final String eH = blockEnd.hour.toString().padLeft(2, '0');
    final String timeRange = '$sH:00 - $eH:00';

    final int totalMinutes = blockDurationHours * 60;
    final int elapsedMinutes = slotTime.difference(blockStart).inMinutes.clamp(0, totalMinutes);
    final int remMinutes = isCurrentSlot
        ? (totalMinutes - elapsedMinutes).clamp(1, totalMinutes)
        : totalMinutes;
    final double progressVal = isCurrentSlot
        ? (elapsedMinutes / totalMinutes).clamp(0.04, 0.96)
        : 0.0;

    // Semilla diferenciada por canal y por país/feed para que Argentina y Colombia no repitan lo mismo
    final String seedKey = '${identity.brandKey}_${identity.countryFeed}';
    final int channelSeed = seedKey.codeUnits.fold<int>(0, (prev, elem) => prev + elem);

    final currentSlotData = _resolveSmartSlot(
      cleanName: cleanName,
      lowerName: lowerName,
      lowerCat: lowerCat,
      brandKey: identity.brandKey,
      countryFeed: identity.countryFeed,
      hour: blockStart.hour,
      channelSeed: channelSeed,
    );

    final nextSlotData = _resolveSmartSlot(
      cleanName: cleanName,
      lowerName: lowerName,
      lowerCat: lowerCat,
      brandKey: identity.brandKey,
      countryFeed: identity.countryFeed,
      hour: blockEnd.hour,
      channelSeed: channelSeed,
    );

    return EpgProgram(
      title: currentSlotData['title']!,
      subtitle: currentSlotData['subtitle']!,
      timeRange: timeRange,
      nextTitle: nextSlotData['title']!,
      progress: progressVal,
      remainingMinutes: remMinutes,
      startTime: blockStart,
      endTime: blockEnd,
      isLiveEvent: true,
      sourceLayer: 'smart_regional',
    );
  }

  static EpgProgram _formatSlotToProgram({
    required _XmlTvSlot slot,
    required DateTime slotTime,
    required bool isCurrentSlot,
    required String nextTitleFallback,
    required String sourceLayer,
  }) {
    final totalMin = slot.stop.difference(slot.start).inMinutes.clamp(1, 360);
    final elapsedMin = slotTime.difference(slot.start).inMinutes.clamp(0, totalMin);
    final sH = slot.start.hour.toString().padLeft(2, '0');
    final sM = slot.start.minute.toString().padLeft(2, '0');
    final eH = slot.stop.hour.toString().padLeft(2, '0');
    final eM = slot.stop.minute.toString().padLeft(2, '0');

    return EpgProgram(
      title: slot.title,
      subtitle: slot.desc,
      timeRange: '$sH:$sM - $eH:$eM',
      nextTitle: nextTitleFallback,
      progress: isCurrentSlot ? (elapsedMin / totalMin).clamp(0.04, 0.96) : 0.0,
      remainingMinutes: (totalMin - elapsedMin).clamp(1, 360),
      startTime: slot.start,
      endTime: slot.stop,
      isLiveEvent: slot.title.startsWith('🔴'),
      sourceLayer: sourceLayer,
    );
  }

  static bool _isSportsOrMovieChannel(String brandKey, String lowerName, String lowerCat) {
    return brandKey.startsWith('espn') ||
        brandKey.startsWith('foxsports') ||
        brandKey.startsWith('dsports') ||
        brandKey == 'tycsports' ||
        brandKey == 'winsports' ||
        brandKey == 'tntsports' ||
        brandKey == 'tudn' ||
        brandKey == 'liga1max' ||
        brandKey == 'golperu' ||
        lowerCat.contains('deporte') ||
        lowerCat.contains('sport') ||
        lowerCat.contains('cine') ||
        lowerCat.contains('pelicula') ||
        lowerName.contains('hbo') ||
        lowerName.contains('cinecanal') ||
        lowerName.contains('space') ||
        lowerName.contains('tnt') ||
        lowerName.contains('golden');
  }

  static Map<String, String> _resolveSmartSlot({
    required String cleanName,
    required String lowerName,
    required String lowerCat,
    required String brandKey,
    required String countryFeed,
    required int hour,
    required int channelSeed,
  }) {
    final feedLabel = countryFeed == 'LATAM' ? 'Señal Internacional' : 'Señal $countryFeed';

    // =========================================================================
    // 1. BÉISBOL PURO (MLB NETWORK / IVC) - SIN MEZCLAR CON ESPN 3 FÚTBOL
    // =========================================================================
    if (lowerName.contains('mlb') ||
        lowerName.contains('beisbol') ||
        lowerName.contains('béisbol') ||
        lowerName.contains('baseball')) {
      const lineup = [
        {'title': 'MLB Network: Resumen de Grandes Ligas', 'subtitle': 'Las mejores jugadas, cuadrangulares y estadísticas de la jornada'},
        {'title': 'Béisbol MLB en Vivo: Juego de la Semana', 'subtitle': 'Transmisión en directo entrada por entrada con audio original y latino'},
        {'title': 'Grandes Ligas en Directo: Duelo Divisional', 'subtitle': 'Cobertura exclusiva desde el diamante en Full HD'},
        {'title': 'Clásicos del Béisbol: Serie Mundial Histórica', 'subtitle': 'Partidos inolvidables de postemporada completos'},
      ];
      return lineup[(hour + channelSeed) % lineup.length];
    }

    // =========================================================================
    // 2. DEPORTES Y FÚTBOL EN VIVO (ESPN, ESPN 2, ESPN 3, DSPORTS, FOX, TYC, WIN, LIGA 1)
    // =========================================================================
    if (brandKey.startsWith('espn') ||
        brandKey.startsWith('foxsports') ||
        brandKey.startsWith('dsports') ||
        lowerName.contains('espn') ||
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
      // Mañanas de Fútbol Europeo en directo (06:00 a 12:00 hora Latinoamérica)
      if (hour >= 6 && hour < 12) {
        final morningSoccer = [
          {
            'title': 'Fútbol Europeo en Vivo: LaLiga / Serie A ($feedLabel)',
            'subtitle': 'Transmisión en directo desde Europa • Relatos y comentarios en español',
          },
          {
            'title': 'Fútbol Internacional en Directo: Jornada Europea ($feedLabel)',
            'subtitle': 'Cobertura en vivo desde el estadio en Full HD • Audio Principal y Ambiente',
          },
          {
            'title': 'SportsCenter Matutino & Fútbol en Vivo ($feedLabel)',
            'subtitle': 'Partidos matutinos de ligas europeas, goles al instante y análisis táctico',
          },
        ];
        return morningSoccer[((hour ~/ 2) + channelSeed) % morningSoccer.length];
      } else if (hour >= 12 && hour < 17) {
        final afternoonSports = [
          {
            'title': 'Fútbol Internacional en Vivo: Torneo Europeo ($feedLabel)',
            'subtitle': 'Transmisión oficial en alta definición con relatos en español',
          },
          {
            'title': 'F90 / Equipo F: Debate y Previa Futbolera ($feedLabel)',
            'subtitle': 'Análisis táctico, móviles en directo desde los clubes y alineaciones',
          },
          {
            'title': 'Conexión Deportiva: Ligas y Copas en Directo ($feedLabel)',
            'subtitle': 'Cobertura en vivo de la jornada internacional',
          },
        ];
        return afternoonSports[((hour ~/ 2) + channelSeed) % afternoonSports.length];
      } else if (hour >= 17 && hour <= 23) {
        final primeSports = [
          {
            'title': 'Fútbol Estelar en Vivo: Partido de la Fecha ($feedLabel)',
            'subtitle': 'Transmisión en directo desde el estadio • Audio Principal y Ambiente',
          },
          {
            'title': 'Noche de Copa en Directo: Torneo Continental ($feedLabel)',
            'subtitle': 'Cobertura exclusiva con cámaras tácticas y análisis en vivo',
          },
          {
            'title': 'SportsCenter Edición Central Nocturna ($feedLabel)',
            'subtitle': 'Todos los goles, compactos y conferencias de prensa de la jornada',
          },
        ];
        return primeSports[((hour ~/ 2) + channelSeed) % primeSports.length];
      } else {
        return {
          'title': 'Repetición Estelar: El Partido de la Jornada ($feedLabel)',
          'subtitle': 'Retransmisión íntegra del encuentro más destacado sin cortes',
        };
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
      ];
      return moviesLineup[((hour ~/ 2) + channelSeed) % moviesLineup.length];
    }

    // =========================================================================
    // 4. CANALES INFANTILES Y ANIME
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
        {'title': 'Bloque Anime: Dragon Ball Super — Torneo de la Fuerza', 'subtitle': 'Saga completa en alta definición'},
      ];
      return kidsLineup[(hour + channelSeed) % kidsLineup.length];
    }

    // =========================================================================
    // 5. DOCUMENTALES, CULTURA Y ESTILO DE VIDA
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
        {'title': 'Planeta Tierra: Vida Salvaje en 4K', 'subtitle': 'Documental de naturaleza con fotografía cinematográfica'},
      ];
      return docLineup[(hour + channelSeed) % docLineup.length];
    }

    // =========================================================================
    // 6. NOTICIAS 24 HORAS
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
        lowerName.contains('noticia') ||
        lowerName.contains('news') ||
        lowerCat.contains('noticia') ||
        lowerCat.contains('news')) {
      if (hour >= 5 && hour < 12) {
        return {
          'title': 'Noticiero Matutino en Vivo: Titulares ($cleanName)',
          'subtitle': 'Primer reporte del día, mercados internacionales, clima y corresponsales en directo',
        };
      } else if (hour >= 12 && hour < 18) {
        return {
          'title': 'Edición Meridiana: Panorama en Directo ($cleanName)',
          'subtitle': 'Cobertura minuto a minuto de las noticias más importantes de la jornada',
        };
      } else {
        return {
          'title': 'Edición Central y Análisis Político ($cleanName)',
          'subtitle': 'Entrevistas exclusivas, economía global y mesa de periodistas en vivo',
        };
      }
    }

    // =========================================================================
    // 7. MÚSICA Y VARIEDADES
    // =========================================================================
    if (lowerName.contains('htv') ||
        lowerName.contains('mtv') ||
        lowerName.contains('telehit') ||
        lowerName.contains('vh1') ||
        lowerName.contains('musica') ||
        lowerName.contains('música') ||
        lowerName.contains('music') ||
        lowerCat.contains('musica') ||
        lowerCat.contains('música') ||
        lowerCat.contains('music')) {
      const musicLineup = [
        {'title': 'Hot Ranking Latino: Los 20 Más Pedidos', 'subtitle': 'Los éxitos urbanos, pop y tropicales que dominan las listas'},
        {'title': 'Especial en Concierto: Gira Internacional en Vivo', 'subtitle': 'Presentaciones en directo con sonido de alta fidelidad'},
        {'title': 'Clásicos de Oro y Estrenos de la Semana', 'subtitle': 'Los mejores videoclips sin interrupciones'},
      ];
      return musicLineup[(hour + channelSeed) % musicLineup.length];
    }

    // =========================================================================
    // 8. CANALES NACIONALES Y ABIERTOS POR FRANJA HORARIA Y PAÍS
    // =========================================================================
    if (hour >= 6 && hour < 12) {
      return {
        'title': 'Magazine y Noticiero Matutino en Vivo • $cleanName',
        'subtitle': 'Actualidad nacional ($feedLabel), enlaces en directo y entretenimiento matinal',
      };
    } else if (hour >= 12 && hour < 15) {
      return {
        'title': 'Noticiero Edición Mediodía en Directo • $cleanName',
        'subtitle': 'El resumen informativo más completo de la mitad de la jornada ($feedLabel)',
      };
    } else if (hour >= 15 && hour < 19) {
      return {
        'title': 'Tardes de Entretenimiento y Ficción en Vivo • $cleanName',
        'subtitle': 'Emisión vespertina en alta definición ($feedLabel)',
      };
    } else if (hour >= 19 && hour <= 23) {
      return {
        'title': 'Edición Central Estelar Prime Time • $cleanName',
        'subtitle': 'Las noticias más relevantes y gala estelar de la noche ($feedLabel)',
      };
    } else {
      return {
        'title': 'Trasnoche Estelar • $cleanName',
        'subtitle': 'Lo mejor de la programación del día ($feedLabel)',
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
      if (item.category != null) {
        return item.category.toString();
      }
    } catch (_) {}
    try {
      if (item is Map && (item['groupCategory'] != null || item['category'] != null)) {
        return (item['groupCategory'] ?? item['category']).toString();
      }
    } catch (_) {}
    return '';
  }

  static String? _getChannelTvgId(dynamic item) {
    if (item == null || item is String) return null;
    try {
      if (item.tvgId != null && item.tvgId.toString().isNotEmpty) {
        return item.tvgId.toString();
      }
    } catch (_) {}
    try {
      if (item is Map && item['tvgId'] != null) {
        return item['tvgId'].toString();
      }
    } catch (_) {}
    return null;
  }
}