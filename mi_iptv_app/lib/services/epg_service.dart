import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

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

  Map<String, dynamic> toJson() => {
        's': start.millisecondsSinceEpoch,
        'e': stop.millisecondsSinceEpoch,
        't': title,
        'd': desc,
      };

  factory _XmlTvSlot.fromJson(Map<String, dynamic> json) => _XmlTvSlot(
        start: DateTime.fromMillisecondsSinceEpoch(json['s'] as int),
        stop: DateTime.fromMillisecondsSinceEpoch(json['e'] as int),
        title: (json['t'] ?? 'Transmisión en Vivo').toString(),
        desc: (json['d'] ?? 'Emisión en directo').toString(),
      );
}

class CanonicalChannelIdentity {
  final String rawName;
  final String cleanDisplayName;
  final String tvgIdKey;
  final String canonicalNameKey;
  final String brandKey;
  final String countryFeed;

  const CanonicalChannelIdentity({
    required this.rawName,
    required this.cleanDisplayName,
    required this.tvgIdKey,
    required this.canonicalNameKey,
    required this.brandKey,
    required this.countryFeed,
  });
}

class EpgService {
  // ===========================================================================
  // CONFIGURACIÓN ESTILO TIVIMATE: AUTO-DETECCIÓN + URL PRIVADA + SATÉLITE + CACHÉ
  // ===========================================================================

  static const String _prefCustomEpgUrlKey = 'tivimate_custom_epg_url';
  static const String _prefAutoDetectedEpgUrlKey = 'tivimate_auto_m3u_epg_url';
  static const String _prefUsePublicSatelliteKey = 'tivimate_use_public_satellite';
  static const String _prefDiskCacheJsonKey = 'tivimate_xmltv_disk_cache_v3';
  static const String _prefDiskCacheTimeKey = 'tivimate_xmltv_disk_time_v3';

  /// Fuentes públicas XMLTV activas (soportan .xml y .xml.gz)
  static const List<String> defaultSatelliteXmlTvUrls = [
    'https://raw.githubusercontent.com/davidmuma/EPG_dobleM/master/guiatv.xml.gz',
    'https://www.open-epg.com/files/colombia1.xml.gz',
    'https://www.open-epg.com/files/argentina1.xml.gz',
    'https://www.open-epg.com/files/mexico1.xml.gz',
    'https://www.open-epg.com/files/chile1.xml.gz',
    'https://www.open-epg.com/files/peru1.xml.gz',
  ];

  // ===========================================================================
  // CACHÉS EN MEMORIA RAM Y CONTROL DE BÚSQUEDA EN VIVO POR CANAL
  // ===========================================================================

  /// Caché principal de programación real descargada de internet (mi.tv, gatotv, XMLTV)
  static final Map<String, List<_XmlTvSlot>> _xmlTvCache = {};

  /// Caché de eventos deportivos reales obtenidos de la API en vivo de ESPN
  static final Map<String, List<_XmlTvSlot>> _liveSportsCache = {};

  /// Caché de lectura directa del stream en vivo / OCR
  static final Map<String, _XmlTvSlot> _ocrFrameOverrideCache = {};

  /// Control de qué canales ya fueron consultados hoy en vivo en internet (mi.tv / gatotv)
  static final Set<String> _webScrapedChannelsToday = {};
  static final Set<String> _channelsCurrentlyScraping = {};

  /// Registro de metadatos M3U
  static final Map<String, String> _channelToTvgIdMap = {};
  static final Map<String, String> _channelToOriginalNameMap = {};
  static final Map<String, String> _channelToStreamUrlMap = {};

  /// Cola de pre-carga en segundo plano para ir nutriendo los canales de la lista
  static final List<String> _backgroundPrefetchQueue = [];
  static bool _isRunningBackgroundPrefetch = false;

  /// Notificador para refrescar la UI en cuanto llega la guía de internet (a los 2-3 seg)
  static final ValueNotifier<int> epgUpdateNotifier = ValueNotifier<int>(0);

  static bool _isInitialized = false;
  static bool _isFetchingSports = false;
  static bool _isSyncingXmlTv = false;
  static DateTime? _lastSportsFetch;
  static DateTime? _lastXmlTvSync;
  static String _epgStatusMessage = 'Buscador EPG Universal Activo';
  static String _activeEpgUrl = '';
  static Timer? _refreshTimer;

  /// Temporizador de 2 segundos al sintonizar un canal (no frena jamás el zapping)
  static Timer? _delayedChannelProbeTimer;
  static String _lastTunedProbeKey = '';

  static bool get isSyncingXmlTv => _isSyncingXmlTv;
  static String get epgStatusMessage => _epgStatusMessage;
  static String get activeEpgUrl => _activeEpgUrl;
  static DateTime? get lastXmlTvSync => _lastXmlTvSync;
  static int get cachedXmlTvChannelsCount => _xmlTvCache.length;

  // ===========================================================================
  // INICIALIZACIÓN AUTOMÁTICA NO BLOQUEANTE (0 MS DE RETRASO EN ZAPPING)
  // ===========================================================================

  static void ensureInitialized() {
    if (_isInitialized) return;
    _isInitialized = true;

    unawaited(_initTiviMateXmlTvEngine());
    unawaited(refreshRealTimeSportsEpg());

    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(refreshRealTimeSportsEpg());
    });
  }

  static Future<void> _initTiviMateXmlTvEngine() async {
    final loadedFromDisk = await _loadXmlTvCacheFromDisk();
    if (loadedFromDisk) {
      _epgStatusMessage =
          'EPG en Caché Activo (${_xmlTvCache.length} llaves reales)';
      epgUpdateNotifier.value++;
    }

    final prefs = await SharedPreferences.getInstance();
    final lastSavedMs = prefs.getInt(_prefDiskCacheTimeKey) ?? 0;
    final cacheAgeHours = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(lastSavedMs))
        .inHours;

    if (!loadedFromDisk || cacheAgeHours >= 4) {
      await syncAllEpgSources(forceNetwork: false);
    }
  }

  // ===========================================================================
  // MOTOR UNIVERSAL DE BÚSQUEDA EN INTERNET A LOS 2 SEGUNDOS DE SINTONIZAR
  // ===========================================================================

  /// Cuando el usuario sintoniza CUALQUIER canal, el video arranca en 0 ms.
  /// Si el canal aún no tiene guía real de internet, espera 2 segundos de estabilidad
  /// y busca en vivo en internet (mi.tv + gatotv.com + HLS) la programación real de hoy.
  static void _scheduleDelayedChannelProbe(CanonicalChannelIdentity identity) {
    final lookupKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';

    // Si ya fue descargado hoy de internet y tiene programas vigentes, no repetir
    if (_webScrapedChannelsToday.contains(lookupKey) &&
        _hasValidRealSlots(identity)) {
      return;
    }

    if (_lastTunedProbeKey == lookupKey &&
        _channelsCurrentlyScraping.contains(lookupKey)) {
      return;
    }

    _lastTunedProbeKey = lookupKey;
    _delayedChannelProbeTimer?.cancel();

    // Espera 2 segundos después del cambio de canal para que el zapping sea 100% instantáneo
    _delayedChannelProbeTimer = Timer(const Duration(seconds: 2), () {
      unawaited(_fetchLiveInternetEpgForChannel(identity, saveToDisk: true));
    });
  }

  static bool _hasValidRealSlots(CanonicalChannelIdentity identity) {
    final now = DateTime.now();
    final candidates = [
      '${identity.brandKey}_${identity.countryFeed.toLowerCase()}',
      identity.brandKey,
      identity.canonicalNameKey,
      identity.tvgIdKey,
    ];
    for (final k in candidates) {
      if (k.isNotEmpty && _xmlTvCache.containsKey(k)) {
        final list = _xmlTvCache[k]!;
        if (list.any((s) => !now.isBefore(s.start) && now.isBefore(s.stop))) {
          return true;
        }
      }
    }
    return false;
  }

  /// Consulta en tiempo real en Internet la guía de hoy para CUALQUIER canal
  static Future<bool> _fetchLiveInternetEpgForChannel(
    CanonicalChannelIdentity identity, {
    bool saveToDisk = true,
  }) async {
    final lookupKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';
    if (_channelsCurrentlyScraping.contains(lookupKey)) return false;
    _channelsCurrentlyScraping.add(lookupKey);

    try {
      // 1. Verificar metadatos en vivo del propio stream .m3u8 si existen
      unawaited(_probeHlsStreamTitle(identity));

      // 2. Intentar descargar la programación real de hoy desde mi.tv (Directo + Buscador)
      List<_XmlTvSlot> fetchedSlots = await _scrapeMiTvScheduleForChannel(identity);

      // 3. Si mi.tv no tuvo resultados para ese canal, buscar en gatotv.com (Directo + Buscador)
      if (fetchedSlots.isEmpty) {
        fetchedSlots = await _scrapeGatoTvScheduleForChannel(identity);
      }

      if (fetchedSlots.isNotEmpty) {
        _storeFetchedSlotsForIdentity(identity, fetchedSlots);
        _webScrapedChannelsToday.add(lookupKey);
        _epgStatusMessage =
            'Guía en Vivo sincronizada: ${identity.cleanDisplayName} (${_xmlTvCache.length} canales en caché)';

        // Notificar inmediatamente a la pantalla para que actualice el banner y la lista
        epgUpdateNotifier.value++;

        if (saveToDisk) {
          unawaited(_saveXmlTvCacheToDisk());
        }
        return true;
      }
    } catch (_) {
    } finally {
      _channelsCurrentlyScraping.remove(lookupKey);
    }
    return false;
  }

  static void _storeFetchedSlotsForIdentity(
    CanonicalChannelIdentity identity,
    List<_XmlTvSlot> slots,
  ) {
    slots.sort((a, b) => a.start.compareTo(b.start));
    final keys = <String>{
      '${identity.brandKey}_${identity.countryFeed.toLowerCase()}',
      identity.brandKey,
      identity.canonicalNameKey,
      if (identity.tvgIdKey.isNotEmpty) identity.tvgIdKey,
    };
    for (final k in keys) {
      if (k.isNotEmpty) {
        _xmlTvCache[k] = slots;
      }
    }
  }

  // ===========================================================================
  // MOTOR WEB 1: SCRAPER Y BUSCADOR AUTOMÁTICO EN VIVO DE MI.TV (TODA LATAM)
  // ===========================================================================

  static Future<List<_XmlTvSlot>> _scrapeMiTvScheduleForChannel(
    CanonicalChannelIdentity identity,
  ) async {
    final countries = _getOrderedMiTvCountries(identity.countryFeed);
    final candidateSlugs = _buildMiTvCandidateSlugs(identity);
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    final tzOffsetMin = now.timeZoneOffset.inMinutes;

    // Paso A: Probar slugs candidatos directos en el endpoint rápido de mi.tv
    for (final country in countries.take(2)) {
      for (final slug in candidateSlugs) {
        final asyncUrl =
            'https://mi.tv/$country/async/channel/$slug/$dateStr/$tzOffsetMin';
        final slots = await _downloadAndParseMiTvHtml(asyncUrl, now);
        if (slots.length >= 3) return slots;

        final pageUrl = 'https://mi.tv/$country/canales/$slug';
        final pageSlots = await _downloadAndParseMiTvHtml(pageUrl, now);
        if (pageSlots.length >= 3) return pageSlots;
      }
    }

    // Paso B: Si el canal no coincidió con el slug directo, usar el BUSCADOR de mi.tv
    // Esto permite encontrar CUALQUIER canal regional, de cable o internacional
    final searchQuery = Uri.encodeQueryComponent(identity.cleanDisplayName);
    if (searchQuery.length >= 2) {
      for (final country in countries.take(2)) {
        try {
          final searchUrl = 'https://mi.tv/$country/buscar?q=$searchQuery';
          final res = await http.get(
            Uri.parse(searchUrl),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
              'Accept-Language': 'es-419,es;q=0.9',
            },
          ).timeout(const Duration(seconds: 4));

          if (res.statusCode == 200 && res.body.isNotEmpty) {
            final html = utf8.decode(res.bodyBytes, allowMalformed: true);
            // Buscar el primer enlace a un canal: href="/co/canales/nombre-del-canal"
            final chanLinkRegex = RegExp(
              r'href="/([a-z]{2})/canales/([a-z0-9\-_]+)"',
              caseSensitive: false,
            );
            final matches = chanLinkRegex.allMatches(html).toList();
            for (final m in matches.take(2)) {
              final foundCountry = m.group(1)!;
              final foundSlug = m.group(2)!;
              // Verificar que el slug encontrado tenga relación con el canal buscado
              if (_slugMatchesChannel(foundSlug, identity)) {
                final asyncUrl =
                    'https://mi.tv/$foundCountry/async/channel/$foundSlug/$dateStr/$tzOffsetMin';
                final slots = await _downloadAndParseMiTvHtml(asyncUrl, now);
                if (slots.length >= 3) return slots;

                final fullUrl = 'https://mi.tv/$foundCountry/canales/$foundSlug';
                final fullSlots = await _downloadAndParseMiTvHtml(fullUrl, now);
                if (fullSlots.length >= 3) return fullSlots;
              }
            }
          }
        } catch (_) {}
      }
    }

    return [];
  }

  static Future<List<_XmlTvSlot>> _downloadAndParseMiTvHtml(
    String url,
    DateTime referenceDate,
  ) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'es-419,es;q=0.9',
        },
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return [];
      final html = utf8.decode(res.bodyBytes, allowMalformed: true);
      return _parseMiTvHtmlContent(html, referenceDate);
    } catch (_) {
      return [];
    }
  }

  /// Extrae todos los programas y horarios reales del HTML de mi.tv
  static List<_XmlTvSlot> _parseMiTvHtmlContent(
    String html,
    DateTime now,
  ) {
    final List<Map<String, dynamic>> rawItems = [];

    // En mi.tv cada bloque de programa tiene <span class="time">HH:MM</span> y <h2>Título</h2>
    final blockRegex = RegExp(
      r'<span\s+class="time"[^>]*>\s*(\d{1,2}:\d{2})\s*(am|pm)?\s*<\/span>[\s\S]{1,600}?<h2>([\s\S]*?)<\/h2>(?:[\s\S]{1,400}?<span\s+class="sub-title"[^>]*>([\s\S]*?)<\/span>)?(?:[\s\S]{1,500}?<p\s+class="synopsis"[^>]*>([\s\S]*?)<\/p>)?',
      caseSensitive: false,
    );

    for (final m in blockRegex.allMatches(html)) {
      final rawTime = (m.group(1) ?? '').trim();
      final amPm = (m.group(2) ?? '').trim().toLowerCase();
      final rawTitle = _stripHtmlTags(_unescapeXml(m.group(3) ?? ''));
      final rawSub = _stripHtmlTags(_unescapeXml(m.group(4) ?? ''));
      final rawSyn = _stripHtmlTags(_unescapeXml(m.group(5) ?? ''));

      if (rawTime.isEmpty || rawTitle.isEmpty) continue;

      final parts = rawTime.split(':');
      if (parts.length != 2) continue;
      int hour = int.tryParse(parts[0]) ?? 0;
      final int minute = int.tryParse(parts[1]) ?? 0;

      if (amPm == 'pm' && hour < 12) hour += 12;
      if (amPm == 'am' && hour == 12) hour = 0;

      String desc = '';
      if (rawSub.isNotEmpty && rawSyn.isNotEmpty) {
        desc = '$rawSub • $rawSyn';
      } else if (rawSyn.isNotEmpty) {
        desc = rawSyn;
      } else if (rawSub.isNotEmpty) {
        desc = rawSub;
      } else {
        desc = 'Programación oficial en vivo';
      }

      rawItems.add({
        'hour': hour,
        'minute': minute,
        'title': rawTitle,
        'desc': desc,
      });
    }

    if (rawItems.length < 2) return [];

    // Construir la línea de tiempo continua del día manejando cruces de medianoche
    final List<_XmlTvSlot> slots = [];
    DateTime baseDay = DateTime(now.year, now.month, now.day);

    // Si el primer programa de la guía empieza temprano (ej. 05:00 o 06:00) y ahora son las 00:30 AM,
    // la guía corresponde al día calendario que inició ayer
    final firstHour = rawItems.first['hour'] as int;
    if (now.hour < 5 && firstHour >= 4 && firstHour <= 7) {
      baseDay = baseDay.subtract(const Duration(days: 1));
    }

    DateTime? prevStart;
    final List<DateTime> computedStarts = [];

    for (final item in rawItems) {
      final h = item['hour'] as int;
      final m = item['minute'] as int;
      DateTime candidate = DateTime(baseDay.year, baseDay.month, baseDay.day, h, m);

      if (prevStart != null && candidate.isBefore(prevStart)) {
        // Cruzó la medianoche hacia el día siguiente
        baseDay = baseDay.add(const Duration(days: 1));
        candidate = DateTime(baseDay.year, baseDay.month, baseDay.day, h, m);
      }
      computedStarts.add(candidate);
      prevStart = candidate;
    }

    for (int i = 0; i < rawItems.length; i++) {
      final start = computedStarts[i];
      DateTime stop;
      if (i + 1 < computedStarts.length) {
        stop = computedStarts[i + 1];
        if (!stop.isAfter(start) || stop.difference(start).inHours > 6) {
          stop = start.add(const Duration(minutes: 60));
        }
      } else {
        stop = start.add(const Duration(minutes: 60));
      }

      slots.add(
        _XmlTvSlot(
          start: start,
          stop: stop,
          title: rawItems[i]['title'] as String,
          desc: rawItems[i]['desc'] as String,
        ),
      );
    }

    return slots;
  }

  // ===========================================================================
  // MOTOR WEB 2: SCRAPER Y BUSCADOR EN VIVO DE GATOTV.COM (+1.500 CANALES)
  // ===========================================================================

  static Future<List<_XmlTvSlot>> _scrapeGatoTvScheduleForChannel(
    CanonicalChannelIdentity identity,
  ) async {
    final slugs = _buildGatoTvCandidateSlugs(identity);
    final now = DateTime.now();

    for (final slug in slugs) {
      final url = 'https://www.gatotv.com/canal/$slug';
      final slots = await _downloadAndParseGatoTvHtml(url, now);
      if (slots.length >= 3) return slots;
    }
    return [];
  }

  static Future<List<_XmlTvSlot>> _downloadAndParseGatoTvHtml(
    String url,
    DateTime now,
  ) async {
    try {
      final res = await http.get(
        Uri.parse(url),
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'es-419,es;q=0.9',
        },
      ).timeout(const Duration(seconds: 4));

      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return [];
      final html = utf8.decode(res.bodyBytes, allowMalformed: true);

      final List<_XmlTvSlot> slots = [];
      final rowRegex = RegExp(
        r'<tr[^>]*class="[^"]*tbl_EPG_row[^"]*"[^>]*>([\s\S]*?)<\/tr>',
        caseSensitive: false,
      );
      final timeRegex = RegExp(r'datetime="(\d{2}:\d{2})"', caseSensitive: false);
      final titleSpanRegex = RegExp(
        r'class="div_program_title_on_channel"[^>]*>[\s\S]*?<span[^>]*>([\s\S]*?)<\/span>',
        caseSensitive: false,
      );

      DateTime baseDay = DateTime(now.year, now.month, now.day);
      DateTime? lastStart;

      for (final rowMatch in rowRegex.allMatches(html)) {
        final rowHtml = rowMatch.group(1) ?? '';
        final times = timeRegex
            .allMatches(rowHtml)
            .map((m) => m.group(1) ?? '')
            .where((t) => t.isNotEmpty)
            .toList();

        if (times.isEmpty) continue;

        String title = '';
        final tMatch = titleSpanRegex.firstMatch(rowHtml);
        if (tMatch != null) {
          title = _stripHtmlTags(_unescapeXml(tMatch.group(1) ?? ''));
        } else {
          final fallbackMatch =
              RegExp(r'<a[^>]*title="([^"]+)"', caseSensitive: false)
                  .firstMatch(rowHtml);
          if (fallbackMatch != null) {
            title = _unescapeXml(fallbackMatch.group(1) ?? '');
          }
        }

        if (title.isEmpty) continue;

        final startParts = times.first.split(':');
        final sH = int.tryParse(startParts[0]) ?? 0;
        final sM = int.tryParse(startParts[1]) ?? 0;

        DateTime startDt = DateTime(baseDay.year, baseDay.month, baseDay.day, sH, sM);
        if (lastStart != null && startDt.isBefore(lastStart)) {
          baseDay = baseDay.add(const Duration(days: 1));
          startDt = DateTime(baseDay.year, baseDay.month, baseDay.day, sH, sM);
        }
        lastStart = startDt;

        DateTime stopDt = startDt.add(const Duration(minutes: 60));
        if (times.length >= 2) {
          final endParts = times[1].split(':');
          final eH = int.tryParse(endParts[0]) ?? 0;
          final eM = int.tryParse(endParts[1]) ?? 0;
          stopDt = DateTime(startDt.year, startDt.month, startDt.day, eH, eM);
          if (!stopDt.isAfter(startDt)) {
            stopDt = stopDt.add(const Duration(days: 1));
          }
        }

        slots.add(
          _XmlTvSlot(
            start: startDt,
            stop: stopDt,
            title: title,
            desc: 'Guía de programación en tiempo real',
          ),
        );
      }

      return slots;
    } catch (_) {
      return [];
    }
  }

  static List<String> _getOrderedMiTvCountries(String countryFeed) {
    switch (countryFeed.toUpperCase()) {
      case 'AR':
        return ['ar', 'co', 'mx', 'cl', 'pe'];
      case 'MX':
        return ['mx', 'co', 'ar', 'pe', 'cl'];
      case 'CL':
        return ['cl', 'ar', 'co', 'pe', 'mx'];
      case 'PE':
        return ['pe', 'co', 'ar', 'cl', 'mx'];
      case 'CO':
      default:
        return ['co', 'ar', 'mx', 'pe', 'cl'];
    }
  }

  /// Genera automáticamente los slugs candidatos de mi.tv para CUALQUIER canal de la lista
  static List<String> _buildMiTvCandidateSlugs(CanonicalChannelIdentity identity) {
    final Set<String> slugs = {};

    // Diccionario directo para nombres especiales conocidos en mi.tv
    const knownSlugs = <String, List<String>>{
      'discoverykids': ['discovery-kids'],
      'discoverychannel': ['discovery-channel', 'discovery'],
      'discoveryhh': ['discovery-home-health', 'discovery-h-h'],
      'discoveryid': ['investigation-discovery', 'id-investigation-discovery'],
      'discoveryturbo': ['discovery-turbo'],
      'discoverytheater': ['discovery-theater-hd', 'discovery-theater'],
      'discoveryworld': ['discovery-world-hd', 'discovery-world'],
      'discoveryscience': ['discovery-science'],
      'tlc': ['tlc', 'discovery-tlc'],
      'animalplanet': ['animal-planet'],
      'history': ['history', 'history-channel'],
      'history2': ['history-2', 'h2'],
      'natgeo': ['national-geographic', 'nat-geo'],
      'cartoonnetwork': ['cartoon-network'],
      'cartoonito': ['cartoonito', 'boomerang'],
      'tooncast': ['tooncast'],
      'nickelodeon': ['nickelodeon', 'nick'],
      'nickjr': ['nick-jr'],
      'disneychannel': ['disney-channel', 'disney'],
      'disneyjunior': ['disney-junior', 'disney-jr'],
      'warner': ['warner', 'warner-channel', 'warner-tv'],
      'starchannel': ['star-channel', 'fox', 'fox-channel'],
      'universal': ['universal-channel', 'universal-tv', 'universal'],
      'studiouniversal': ['studio-universal'],
      'axn': ['axn'],
      'sony': ['sony', 'canal-sony', 'sony-channel'],
      'fx': ['fx'],
      'amc': ['amc'],
      'paramount': ['paramount-channel', 'paramount-network', 'paramount'],
      'tnt': ['tnt'],
      'tntseries': ['tnt-series'],
      'tntnovelas': ['tnt-novelas'],
      'space': ['space'],
      'cinecanal': ['cinecanal'],
      'cinemax': ['cinemax'],
      'hbo': ['hbo'],
      'golden': ['golden', 'golden-multiplex'],
      'espn': ['espn'],
      'espn2': ['espn-2', 'espn2'],
      'espn3': ['espn-3', 'espn3'],
      'espn4': ['espn-4', 'espn-extra'],
      'foxsports': ['fox-sports'],
      'foxsports2': ['fox-sports-2'],
      'foxsports3': ['fox-sports-3'],
      'dsports': ['directv-sports', 'dsports'],
      'winsports': ['win-sports'],
      'tycsports': ['tyc-sports'],
    };

    if (knownSlugs.containsKey(identity.brandKey)) {
      slugs.addAll(knownSlugs[identity.brandKey]!);
    }

    // Generación dinámica automática a partir del nombre limpio de CUALQUIER canal
    final hyphenated = identity.cleanDisplayName
        .toLowerCase()
        .replaceAll('&', 'and')
        .replaceAll('+', 'plus')
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');

    if (hyphenated.isNotEmpty) {
      slugs.add(hyphenated);
      if (hyphenated.endsWith('-tv')) {
        slugs.add(hyphenated.substring(0, hyphenated.length - 3));
      } else {
        slugs.add('$hyphenated-tv');
        slugs.add('$hyphenated-channel');
      }
    }

    return slugs.toList();
  }

  static List<String> _buildGatoTvCandidateSlugs(
    CanonicalChannelIdentity identity,
  ) {
    final Set<String> slugs = {};
    final underscored = identity.cleanDisplayName
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');

    if (underscored.isNotEmpty) {
      slugs.add(underscored);
      slugs.add('${underscored}_latinoamerica');
    }
    return slugs.toList();
  }

  static bool _slugMatchesChannel(
    String foundSlug,
    CanonicalChannelIdentity identity,
  ) {
    final cleanFound = foundSlug.replaceAll('-', '').toLowerCase();
    final target = identity.canonicalNameKey.toLowerCase();
    if (cleanFound == target) return true;
    if (cleanFound.contains(target) || target.contains(cleanFound)) {
      // Evitar confundir "discovery" con "discovery-kids" si no es kids
      if (target.contains('kids') != cleanFound.contains('kids')) return false;
      return true;
    }
    return false;
  }

  static String _stripHtmlTags(String htmlText) {
    return htmlText
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Future<void> _probeHlsStreamTitle(
    CanonicalChannelIdentity identity,
  ) async {
    try {
      final urlToProbe = _channelToStreamUrlMap[identity.canonicalNameKey] ??
          _channelToStreamUrlMap[identity.rawName.toLowerCase()] ??
          '';
      if (!urlToProbe.startsWith('http')) return;

      final response = await http
          .get(Uri.parse(urlToProbe))
          .timeout(const Duration(seconds: 3));
      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final sessionTitleMatch = RegExp(
          r'DATA-ID="com\.apple\.hls\.title"[^>]*VALUE="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(response.body);
        if (sessionTitleMatch != null) {
          final extractedTitle = sessionTitleMatch.group(1)?.trim() ?? '';
          if (extractedTitle.length > 3 &&
              !extractedTitle.toLowerCase().contains('stream') &&
              !extractedTitle.toLowerCase().contains('chunk')) {
            applyLiveFrameOcrText(
              channelName: identity.rawName,
              rawScreenText: extractedTitle,
            );
            epgUpdateNotifier.value++;
          }
        }
      }
    } catch (_) {}
  }

  // ===========================================================================
  // PRE-CARGA SILENCIOSA EN SEGUNDO PLANO DE LOS CANALES DE LA LISTA M3U
  // ===========================================================================

  static void _enqueueChannelForBackgroundPrefetch(String channelName) {
    final trimmed = channelName.trim();
    if (trimmed.isEmpty) return;
    if (!_backgroundPrefetchQueue.contains(trimmed) &&
        _backgroundPrefetchQueue.length < 120) {
      _backgroundPrefetchQueue.add(trimmed);
    }
    if (!_isRunningBackgroundPrefetch) {
      unawaited(_runBackgroundPrefetchWorker());
    }
  }

  static Future<void> _runBackgroundPrefetchWorker() async {
    if (_isRunningBackgroundPrefetch) return;
    _isRunningBackgroundPrefetch = true;
    try {
      // Esperar 4 segundos al inicio para no competir con la carga del primer video
      await Future.delayed(const Duration(seconds: 4));
      while (_backgroundPrefetchQueue.isNotEmpty) {
        final nextName = _backgroundPrefetchQueue.removeAt(0);
        final identity = normalizeChannel(nextName);
        final lookupKey =
            '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';
        if (!_webScrapedChannelsToday.contains(lookupKey) &&
            !_hasValidRealSlots(identity)) {
          await _fetchLiveInternetEpgForChannel(identity, saveToDisk: false);
          // Pausa suave entre consultas de fondo para no saturar la red
          await Future.delayed(const Duration(milliseconds: 1200));
        }
      }
      await _saveXmlTvCacheToDisk();
    } catch (_) {
    } finally {
      _isRunningBackgroundPrefetch = false;
    }
  }

  // ===========================================================================
  // FUNCIONES TIVIMATE: AUTO-DETECCIÓN EN M3U + URL PRIVADA + CONECTOR SATELITAL
  // ===========================================================================

  static Future<String?> extractAndSaveEpgUrlFromM3u(String m3uContent) async {
    if (m3uContent.isEmpty) return null;
    final headerLimit = m3uContent.length > 3500 ? 3500 : m3uContent.length;
    final header = m3uContent.substring(0, headerLimit);

    final regex = RegExp(
      r'(?:url-tvg|x-tvg-url|tvg-url)\s*=\s*"([^"]+)"',
      caseSensitive: false,
    );
    final match = regex.firstMatch(header);
    if (match != null) {
      final raw = match.group(1)?.trim() ?? '';
      final urls = raw
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.startsWith('http'))
          .toList();

      if (urls.isNotEmpty) {
        final primaryEpgUrl = urls.first;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_prefAutoDetectedEpgUrlKey, primaryEpgUrl);
        _epgStatusMessage = 'EPG auto-detectado en M3U: $primaryEpgUrl';
        unawaited(syncAllEpgSources(forceNetwork: true));
        return primaryEpgUrl;
      }
    }
    return null;
  }

  static Future<int> setCustomEpgUrl(
    String customUrl, {
    bool syncImmediately = true,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final clean = customUrl.trim();
    await prefs.setString(_prefCustomEpgUrlKey, clean);
    if (syncImmediately) {
      return await syncAllEpgSources(forceNetwork: true);
    }
    return 0;
  }

  static Future<String> getCustomEpgUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefCustomEpgUrlKey) ?? '';
  }

  static Future<String> getAutoDetectedEpgUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_prefAutoDetectedEpgUrlKey) ?? '';
  }

  static Future<void> setUsePublicSatelliteConnector(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefUsePublicSatelliteKey, enabled);
  }

  static Future<bool> getUsePublicSatelliteConnector() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_prefUsePublicSatelliteKey) ?? true;
  }

  static Future<int> syncAllEpgSources({bool forceNetwork = true}) async {
    if (_isSyncingXmlTv) return _xmlTvCache.length;
    _isSyncingXmlTv = true;
    _epgStatusMessage = 'Sincronizando guía satelital y web en vivo...';

    int totalLoadedPrograms = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final customUrl = (prefs.getString(_prefCustomEpgUrlKey) ?? '').trim();
      final autoM3uUrl = (prefs.getString(_prefAutoDetectedEpgUrlKey) ?? '').trim();
      final usePublicSatellite = prefs.getBool(_prefUsePublicSatelliteKey) ?? true;

      final List<String> sourcesToLoad = [];

      if (customUrl.isNotEmpty && customUrl.startsWith('http')) {
        sourcesToLoad.add(customUrl);
      }

      if (autoM3uUrl.isNotEmpty &&
          autoM3uUrl.startsWith('http') &&
          !sourcesToLoad.contains(autoM3uUrl)) {
        sourcesToLoad.add(autoM3uUrl);
      }

      if (usePublicSatellite) {
        unawaited(refreshRealTimeSportsEpg());
        for (final satUrl in defaultSatelliteXmlTvUrls) {
          if (!sourcesToLoad.contains(satUrl)) {
            sourcesToLoad.add(satUrl);
          }
        }
      }

      for (final url in sourcesToLoad) {
        final count = await loadXmlTvFromUrl(url, saveToDiskWhenDone: false);
        if (count > 0) {
          totalLoadedPrograms += count;
          if (_activeEpgUrl.isEmpty) _activeEpgUrl = url;
        }
      }

      await _saveXmlTvCacheToDisk();
      _lastXmlTvSync = DateTime.now();
      _epgStatusMessage =
          'Buscador EPG Activo (${_xmlTvCache.length} canales indexados)';
      epgUpdateNotifier.value++;
    } catch (_) {
      _epgStatusMessage =
          'Buscador EPG Activo (${_xmlTvCache.length} canales indexados)';
    } finally {
      _isSyncingXmlTv = false;
    }
    return totalLoadedPrograms > 0 ? totalLoadedPrograms : _xmlTvCache.length;
  }

  static Future<void> clearEpgCache() async {
    _xmlTvCache.clear();
    _webScrapedChannelsToday.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefDiskCacheJsonKey);
    await prefs.remove(_prefDiskCacheTimeKey);
    _epgStatusMessage = 'Caché EPG limpiada • Listo para consulta en vivo';
    epgUpdateNotifier.value++;
  }

  static void registerChannelMetadata({
    required String cleanName,
    required String originalName,
    String tvgId = '',
    String tvgName = '',
    String category = '',
    String streamUrl = '',
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
    if (streamUrl.trim().isNotEmpty) {
      if (normClean.isNotEmpty) {
        _channelToStreamUrlMap[normClean] = streamUrl.trim();
      }
      if (normOrig.isNotEmpty) {
        _channelToStreamUrlMap[normOrig] = streamUrl.trim();
      }
    }

    // Agregar a la cola de pre-carga en segundo plano
    _enqueueChannelForBackgroundPrefetch(cleanName);
  }

  // ===========================================================================
  // NORMALIZADOR CANÓNICO DE DOBLE LLAVE + DETECTOR EXACTO DE CANAL Y PAÍS
  // ===========================================================================

  static CanonicalChannelIdentity normalizeChannel(
    String channelName, {
    String? explicitTvgId,
  }) {
    final trimmed = channelName.trim();
    final lowerLookup = trimmed.toLowerCase();

    final fullReferenceName = _channelToOriginalNameMap[lowerLookup] ?? trimmed;
    final lowerFull = fullReferenceName.toLowerCase();

    String rawTvgId = (explicitTvgId != null && explicitTvgId.trim().isNotEmpty)
        ? explicitTvgId.trim().toLowerCase()
        : (_channelToTvgIdMap[lowerLookup] ?? _channelToTvgIdMap[lowerFull] ?? '');

    String countryFeed = 'CO'; // Feed Panregional por defecto (UTC-5)
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
    } else {
      // Si el canal dice solo "Latin America", inferir el feed según la zona horaria del teléfono
      final tzHours = DateTime.now().timeZoneOffset.inHours;
      if (tzHours == -3) {
        countryFeed = 'AR';
      } else if (tzHours == -4) {
        countryFeed = 'CL';
      } else if (tzHours <= -6) {
        countryFeed = 'MX';
      } else {
        countryFeed = 'CO';
      }
    }

    String cleaned = lowerFull
        .replaceAll(RegExp(r'\(\s*\d{3,4}[pi]\s*\)', caseSensitive: false), ' ')
        .replaceAll(
          RegExp(
            r'\b(1080p|1080i|720p|576p|480p|360p|2160p|4k|uhd|fhd|hd|sd|hevc|h264)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'\[[^\]]*\]'), ' ')
        .replaceAll(
          RegExp(
            r'\b(latin america|latinoamerica|latinoamérica|latam|argentina|colombia|mexico|méxico|peru|perú|chile|ecuador|venezuela|uruguay|paraguay|bolivia|spain|españa|espana|brazil|brasil|netherlands|panregional|sur|norte|andino|feed|opcion\s*\d+|opción\s*\d+)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[()\-_•|:/\\]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final canonicalKey = cleaned.replaceAll(RegExp(r'[^a-z0-9]'), '');

    String brandKey = canonicalKey;
    if (lowerFull.contains('discovery kids') ||
        canonicalKey.contains('discoverykids')) {
      brandKey = 'discoverykids';
    } else if (lowerFull.contains('home & health') ||
        lowerFull.contains('home and health') ||
        lowerFull.contains('h&h') ||
        canonicalKey.contains('discoveryhh')) {
      brandKey = 'discoveryhh';
    } else if (lowerFull.contains('investigation discovery') ||
        canonicalKey.contains('investigationdiscovery')) {
      brandKey = 'discoveryid';
    } else if (lowerFull.contains('discovery turbo') ||
        canonicalKey.contains('discoveryturbo')) {
      brandKey = 'discoveryturbo';
    } else if (lowerFull.contains('discovery theater') ||
        canonicalKey.contains('discoverytheater')) {
      brandKey = 'discoverytheater';
    } else if (lowerFull.contains('discovery world') ||
        canonicalKey.contains('discoveryworld')) {
      brandKey = 'discoveryworld';
    } else if (lowerFull.contains('discovery science') ||
        canonicalKey.contains('discoveryscience')) {
      brandKey = 'discoveryscience';
    } else if (lowerFull.contains('tlc') || canonicalKey.contains('tlc')) {
      brandKey = 'tlc';
    } else if (lowerFull.contains('animal planet') ||
        canonicalKey.contains('animalplanet')) {
      brandKey = 'animalplanet';
    } else if (lowerFull.contains('discovery') ||
        canonicalKey.contains('discovery')) {
      brandKey = 'discoverychannel';
    } else if (lowerFull.contains('history 2') ||
        canonicalKey.contains('history2')) {
      brandKey = 'history2';
    } else if (lowerFull.contains('history') ||
        canonicalKey.contains('history')) {
      brandKey = 'history';
    } else if (lowerFull.contains('national geographic') ||
        lowerFull.contains('nat geo') ||
        lowerFull.contains('natgeo')) {
      brandKey = 'natgeo';
    } else if (lowerFull.contains('cartoonito') ||
        lowerFull.contains('boomerang')) {
      brandKey = 'cartoonito';
    } else if (lowerFull.contains('cartoon network') ||
        canonicalKey.contains('cartoonnetwork')) {
      brandKey = 'cartoonnetwork';
    } else if (lowerFull.contains('nick jr') ||
        canonicalKey.contains('nickjr')) {
      brandKey = 'nickjr';
    } else if (lowerFull.contains('nickelodeon') ||
        canonicalKey.contains('nickelodeon')) {
      brandKey = 'nickelodeon';
    } else if (lowerFull.contains('disney junior') ||
        lowerFull.contains('disney jr')) {
      brandKey = 'disneyjunior';
    } else if (lowerFull.contains('disney') ||
        canonicalKey.contains('disney')) {
      brandKey = 'disneychannel';
    } else if (canonicalKey.contains('espnpremium') ||
        canonicalKey.contains('espnpack')) {
      brandKey = 'espnpremium';
    } else if (canonicalKey.contains('espnextra') ||
        canonicalKey.contains('espn4')) {
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
    } else if (canonicalKey.contains('dsports2') ||
        canonicalKey.contains('directvsports2')) {
      brandKey = 'dsports2';
    } else if (canonicalKey.contains('dsports') ||
        canonicalKey.contains('directvsports')) {
      brandKey = 'dsports';
    } else if (canonicalKey.contains('tycsports') ||
        canonicalKey.contains('tyc')) {
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

    if (rawTvgId.isEmpty && brandKey.isNotEmpty) {
      rawTvgId = '$brandKey.${countryFeed.toLowerCase()}';
    }

    return CanonicalChannelIdentity(
      rawName: fullReferenceName,
      cleanDisplayName: cleaned.isEmpty ? trimmed : cleaned,
      tvgIdKey: rawTvgId,
      canonicalNameKey:
          canonicalKey.isEmpty ? lowerLookup.replaceAll(' ', '') : canonicalKey,
      brandKey: brandKey.isEmpty ? canonicalKey : brandKey,
      countryFeed: countryFeed,
    );
  }

  static bool _isSportsBrand(String brandKey) {
    return brandKey.startsWith('espn') ||
        brandKey.startsWith('foxsports') ||
        brandKey.startsWith('dsports') ||
        brandKey == 'tycsports' ||
        brandKey == 'winsports' ||
        brandKey == 'tntsports' ||
        brandKey == 'tudn' ||
        brandKey == 'liga1max' ||
        brandKey == 'golperu';
  }

  // ===========================================================================
  // CAPA 3: INYECTOR VISUAL EN VIVO (AI LIVE-FRAME OCR OVERRIDE)
  // ===========================================================================

  static void applyLiveFrameOcrText({
    required String channelName,
    required String rawScreenText,
    Duration validity = const Duration(minutes: 45),
  }) {
    final text = rawScreenText.trim();
    if (text.isEmpty) return;

    final identity = normalizeChannel(channelName);
    final now = DateTime.now();

    final scoreRegex =
        RegExp(r'\b([A-Z]{3})\s*(\d+)\s*[-–:]\s*(\d+)\s*([A-Z]{3})\b');
    final hashtagRegex = RegExp(r'#([A-Za-z0-9_]{4,30})');
    final timeRegex = RegExp(r'\b(\d{1,2}:\d{2})\b');

    String detectedTitle = '';
    String detectedDesc =
        'Transmisión en directo verificada en pantalla (${identity.countryFeed})';

    final scoreMatch = scoreRegex.firstMatch(text);
    final hashMatch = hashtagRegex.firstMatch(text);
    final timeMatch = timeRegex.firstMatch(text);

    if (scoreMatch != null) {
      final teamA = scoreMatch.group(1)!;
      final goalsA = scoreMatch.group(2)!;
      final goalsB = scoreMatch.group(3)!;
      final teamB = scoreMatch.group(4)!;
      final matchClock =
          timeMatch != null ? ' • Min ${timeMatch.group(1)}' : '';
      final tag = hashMatch != null ? ' (#${hashMatch.group(1)})' : '';
      detectedTitle = '🔴 EN VIVO: $teamA $goalsA - $goalsB $teamB$tag';
      detectedDesc =
          'Fútbol en Directo$matchClock • Señal ${identity.countryFeed}';
    } else if (hashMatch != null) {
      detectedTitle = '🔴 EN VIVO: #${hashMatch.group(1)}';
    } else if (text.length >= 4) {
      detectedTitle = text.split('\n').first.trim();
    }

    if (detectedTitle.isNotEmpty) {
      final slot = _XmlTvSlot(
        start: now.subtract(const Duration(minutes: 20)),
        stop: now.add(validity),
        title: detectedTitle,
        desc: detectedDesc,
      );
      _ocrFrameOverrideCache[identity.canonicalNameKey] = slot;
      _ocrFrameOverrideCache[
          '${identity.brandKey}_${identity.countryFeed.toLowerCase()}'] = slot;
    }
  }

  // ===========================================================================
  // CAPA 2: CONECTOR DEPORTIVO EN TIEMPO REAL (API PÚBLICA ESPN EN ESPAÑOL)
  // ===========================================================================

  static Future<void> refreshRealTimeSportsEpg() async {
    if (_isFetchingSports) return;
    if (_lastSportsFetch != null &&
        DateTime.now().difference(_lastSportsFetch!) <
            const Duration(minutes: 5) &&
        _liveSportsCache.isNotEmpty) {
      return;
    }

    _isFetchingSports = true;
    try {
      const endpoints = [
        'https://site.api.espn.com/apis/site/v2/sports/soccer/esp.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/ita.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/eng.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/uefa.champions/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/esp.2/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/conmebol.libertadores/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/conmebol.sudamericana/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/arg.1/scoreboard?lang=es&region=ar',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/col.1/scoreboard?lang=es&region=co',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/per.1/scoreboard?lang=es&region=pe',
        'https://site.api.espn.com/apis/site/v2/sports/soccer/mex.1/scoreboard?lang=es&region=mx',
        'https://site.api.espn.com/apis/site/v2/sports/baseball/mlb/scoreboard?lang=es',
        'https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?lang=es',
      ];

      final responses = await Future.wait(
        endpoints.map((url) async {
          try {
            return await http
                .get(Uri.parse(url))
                .timeout(const Duration(seconds: 6));
          } catch (_) {
            return null;
          }
        }),
      );

      final List<Map<String, dynamic>> parsedMatches = [];

      for (int i = 0; i < responses.length; i++) {
        final res = responses[i];
        if (res == null || res.statusCode != 200) continue;

        final Map<String, dynamic> data = jsonDecode(
          utf8.decode(res.bodyBytes, allowMalformed: true),
        );
        final leagues = (data['leagues'] as List?) ?? [];
        final leagueName = leagues.isNotEmpty
            ? (leagues.first['name']?.toString() ?? 'Fútbol Internacional')
            : 'Torneo en Vivo';
        final slug =
            leagues.isNotEmpty ? (leagues.first['slug']?.toString() ?? '') : '';

        final events = (data['events'] as List?) ?? [];
        for (final ev in events) {
          final rawDate = ev['date']?.toString() ?? '';
          final startDt = DateTime.tryParse(rawDate)?.toLocal();
          if (startDt == null) continue;

          final isBaseball = endpoints[i].contains('/baseball/');
          final stopDt = startDt.add(Duration(minutes: isBaseball ? 150 : 120));

          final statusObj = ev['status'] ?? {};
          final typeObj = statusObj['type'] ?? {};
          final state = typeObj['state']?.toString() ?? 'pre';
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
        epgUpdateNotifier.value++;
      }
    } catch (_) {
    } finally {
      _isFetchingSports = false;
    }
  }

  static void _distributeMatchesAcrossSportsChannels(
    List<Map<String, dynamic>> matches,
  ) {
    final Map<String, List<_XmlTvSlot>> updatedCache = {};

    void addSlot(String channelKey, _XmlTvSlot slot) {
      final list = updatedCache.putIfAbsent(channelKey, () => []);
      final hasConflict = list.any((existing) =>
          slot.start.isBefore(existing.stop) &&
          slot.stop.isAfter(existing.start) &&
          existing.title.startsWith('🔴'));
      if (!hasConflict) {
        list.add(slot);
      }
    }

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

      if (broadcast.contains('espn 2') ||
          broadcast.contains('espn2') ||
          slug.contains('ita.1')) {
        addSlot('espn2', slot);
      } else if (broadcast.contains('espn 3') ||
          broadcast.contains('espn3') ||
          slug.contains('esp.2')) {
        addSlot('espn3', slot);
      } else if (broadcast.contains('dsports') ||
          broadcast.contains('directv')) {
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
        final targets = ['espn', 'espn2', 'espn3', 'dsports', 'foxsports'];
        final primary = targets[soccerCounter % targets.length];
        addSlot(primary, slot);
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
  // CAPA 1: PARSER XMLTV PROFESIONAL + CACHÉ EN MEMORIA Y DISCO (.xml / .gz)
  // ===========================================================================

  static Future<int> loadXmlTvFromUrl(
    String xmlUrl, {
    bool saveToDiskWhenDone = true,
  }) async {
    try {
      final uri = Uri.tryParse(xmlUrl.trim());
      if (uri == null) return 0;
      final response = await http.get(
        uri,
        headers: const {'User-Agent': 'TiviMate/4.7.0 (Android TV)'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return 0;

      List<int> bytes = response.bodyBytes;
      if (xmlUrl.toLowerCase().endsWith('.gz') ||
          (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)) {
        try {
          bytes = gzip.decode(bytes);
        } catch (_) {}
      }

      final count = parseXmlTvContent(utf8.decode(bytes, allowMalformed: true));
      if (count > 0) {
        _activeEpgUrl = xmlUrl.trim();
        if (saveToDiskWhenDone) {
          await _saveXmlTvCacheToDisk();
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  static int parseXmlTvContent(String xmlContent) {
    int count = 0;
    try {
      final now = DateTime.now();
      final minTime = now.subtract(const Duration(hours: 6));
      final maxTime = now.add(const Duration(hours: 36));

      final Map<String, CanonicalChannelIdentity> channelIdToIdentity = {};
      final chanRegex = RegExp(
        r'<channel[^>]*id="([^"]+)"[^>]*>([\s\S]*?)<\/channel>',
        caseSensitive: false,
      );
      final dispRegex = RegExp(
        r'<display-name[^>]*>([\s\S]*?)<\/display-name>',
        caseSensitive: false,
      );

      for (final m in chanRegex.allMatches(xmlContent)) {
        final rawId = (m.group(1) ?? '').trim().toLowerCase();
        final inner = m.group(2) ?? '';
        if (rawId.isEmpty) continue;

        for (final dispMatch in dispRegex.allMatches(inner)) {
          final dispName = _unescapeXml(dispMatch.group(1) ?? '');
          if (dispName.isNotEmpty) {
            final identity = normalizeChannel(dispName, explicitTvgId: rawId);
            channelIdToIdentity[rawId] = identity;
          }
        }
      }

      final progBlockRegex = RegExp(
        r'<programme\s+([^>]+)>([\s\S]*?)<\/programme>',
        caseSensitive: false,
      );
      final startAttrRegex = RegExp(r'start="([^"]+)"', caseSensitive: false);
      final stopAttrRegex = RegExp(r'stop="([^"]+)"', caseSensitive: false);
      final chanAttrRegex = RegExp(r'channel="([^"]+)"', caseSensitive: false);

      final titleRegex =
          RegExp(r'<title[^>]*>([\s\S]*?)<\/title>', caseSensitive: false);
      final descRegex =
          RegExp(r'<desc[^>]*>([\s\S]*?)<\/desc>', caseSensitive: false);

      final Set<String> touchedKeys = {};

      for (final match in progBlockRegex.allMatches(xmlContent)) {
        final attrs = match.group(1) ?? '';
        final innerXml = match.group(2) ?? '';

        final rawStart = startAttrRegex.firstMatch(attrs)?.group(1) ?? '';
        final rawStop = stopAttrRegex.firstMatch(attrs)?.group(1) ?? '';
        final rawChannelId =
            (chanAttrRegex.firstMatch(attrs)?.group(1) ?? '').trim().toLowerCase();

        if (rawStart.isEmpty || rawStop.isEmpty || rawChannelId.isEmpty) continue;

        final startDt = _parseXmlTvDate(rawStart);
        final stopDt = _parseXmlTvDate(rawStop);
        if (startDt == null || stopDt == null) continue;

        if (stopDt.isBefore(minTime) || startDt.isAfter(maxTime)) continue;

        final titleMatch = titleRegex.firstMatch(innerXml);
        final descMatch = descRegex.firstMatch(innerXml);

        final cleanTitle =
            _unescapeXml(titleMatch?.group(1) ?? 'Transmisión en Vivo');
        final cleanDesc = _unescapeXml(
          descMatch?.group(1) ?? 'Emisión oficial programada en directo',
        );

        final slot = _XmlTvSlot(
          start: startDt,
          stop: stopDt,
          title: cleanTitle,
          desc: cleanDesc,
        );

        void indexUnderKey(String key) {
          if (key.isEmpty) return;
          if (!touchedKeys.contains(key)) {
            _xmlTvCache[key] = [];
            touchedKeys.add(key);
          }
          _xmlTvCache[key]!.add(slot);
        }

        indexUnderKey(rawChannelId);
        final idWithoutCountry = rawChannelId.split('.').first;
        if (idWithoutCountry != rawChannelId) {
          indexUnderKey(idWithoutCountry);
        }

        final normalizedId = channelIdToIdentity[rawChannelId] ??
            normalizeChannel(rawChannelId, explicitTvgId: rawChannelId);
        indexUnderKey(normalizedId.canonicalNameKey);
        if (normalizedId.brandKey.isNotEmpty) {
          indexUnderKey(
            '${normalizedId.brandKey}_${normalizedId.countryFeed.toLowerCase()}',
          );
          indexUnderKey(normalizedId.brandKey);
        }

        count++;
      }

      for (final key in touchedKeys) {
        _xmlTvCache[key]?.sort((a, b) => a.start.compareTo(b.start));
      }
    } catch (_) {}
    return count;
  }

  static Future<void> _saveXmlTvCacheToDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> dump = {};
      final now = DateTime.now();

      int savedKeys = 0;
      for (final entry in _xmlTvCache.entries) {
        if (savedKeys >= 400) break;
        final upcoming = entry.value
            .where((s) => s.stop.isAfter(now.subtract(const Duration(hours: 1))))
            .take(18)
            .map((s) => s.toJson())
            .toList();
        if (upcoming.isNotEmpty) {
          dump[entry.key] = upcoming;
          savedKeys++;
        }
      }

      if (dump.isNotEmpty) {
        await prefs.setString(_prefDiskCacheJsonKey, jsonEncode(dump));
        await prefs.setInt(_prefDiskCacheTimeKey, now.millisecondsSinceEpoch);
      }
    } catch (_) {}
  }

  static Future<bool> _loadXmlTvCacheFromDisk() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawJson = prefs.getString(_prefDiskCacheJsonKey);
      if (rawJson == null || rawJson.isEmpty) return false;

      final Map<String, dynamic> decoded = jsonDecode(rawJson);
      final now = DateTime.now();
      int restored = 0;

      decoded.forEach((key, value) {
        if (value is List) {
          final slots = value
              .map((item) => _XmlTvSlot.fromJson(Map<String, dynamic>.from(item)))
              .where(
                  (s) => s.stop.isAfter(now.subtract(const Duration(hours: 1))))
              .toList();
          if (slots.isNotEmpty) {
            _xmlTvCache[key] = slots;
            restored++;
          }
        }
      });

      return restored > 0;
    } catch (_) {
      return false;
    }
  }

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
      final second =
          digits.length >= 14 ? int.parse(digits.substring(12, 14)) : 0;

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

      return DateTime.utc(year, month, day, hour, minute, second).toLocal();
    } catch (_) {
      return null;
    }
  }

  static String _unescapeXml(String input) {
    return input
        .replaceAll('&amp;', '&')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll(RegExp(r'<!\[CDATA\[([\s\S]*?)\]\]>'), r'$1')
        .trim();
  }

  // ===========================================================================
  // MÉTODOS PÚBLICOS COMPATIBLES AL 100% CON MAIN.DART Y RECORDATORIOS
  // ===========================================================================

  static EpgProgram getProgramForChannel(dynamic channel) {
    ensureInitialized();
    final name = _getChannelName(channel);
    final cat = _getChannelCategory(channel);
    final tvgId = _getChannelTvgId(channel);
    final streamUrl = _getChannelStreamUrl(channel);
    if (streamUrl != null && streamUrl.isNotEmpty) {
      _channelToStreamUrlMap[name.trim().toLowerCase()] = streamUrl;
    }
    return getCurrentProgram(name, cat, tvgId);
  }

  static EpgProgram getCurrentProgram(
    String channelName, [
    String? category,
    String? tvgId,
  ]) {
    ensureInitialized();
    final now = DateTime.now();
    final identity = normalizeChannel(channelName, explicitTvgId: tvgId);

    // Dispara la búsqueda universal en internet para ESTE canal a los 2 seg de sintonizarlo
    _scheduleDelayedChannelProbe(identity);

    return _buildProgramForSlot(
      channelName: channelName,
      category: category ?? '',
      explicitTvgId: tvgId,
      slotTime: now,
      isCurrentSlot: true,
    );
  }

  static EpgProgram getNextProgram(
    String channelName, [
    String? category,
    String? tvgId,
  ]) {
    ensureInitialized();
    final current = getCurrentProgram(channelName, category, tvgId);
    final nextLookupTime = current.endTime != null
        ? current.endTime!.add(const Duration(minutes: 1))
        : DateTime.now().add(const Duration(minutes: 30));

    return _buildProgramForSlot(
      channelName: channelName,
      category: category ?? '',
      explicitTvgId: tvgId,
      slotTime: nextLookupTime,
      isCurrentSlot: false,
    );
  }

  static List<EpgProgram> getUpcomingPrograms(
    String channelName, [
    String? category,
    String? tvgId,
  ]) {
    ensureInitialized();
    final identity = normalizeChannel(channelName, explicitTvgId: tvgId);
    _scheduleDelayedChannelProbe(identity);

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

      if (prog.endTime != null && prog.endTime!.isAfter(cursorTime)) {
        cursorTime = prog.endTime!.add(const Duration(minutes: 1));
      } else {
        cursorTime = cursorTime.add(const Duration(hours: 1));
      }
    }

    return schedule;
  }

  // ===========================================================================
  // MOTOR DE RESOLUCIÓN EN CASCADA (INTERNET EN VIVO -> DEPORTES -> RESPALDO)
  // ===========================================================================

  static EpgProgram _buildProgramForSlot({
    required String channelName,
    required String category,
    String? explicitTvgId,
    required DateTime slotTime,
    required bool isCurrentSlot,
  }) {
    final identity = normalizeChannel(channelName, explicitTvgId: explicitTvgId);
    final cleanName =
        channelName.trim().isEmpty ? 'Canal en Vivo' : channelName.trim();
    final lowerName = cleanName.toLowerCase();
    final lowerCat = category.toLowerCase();

    // -------------------------------------------------------------------------
    // 1. CAPA 3: Lectura en vivo del fotograma / Metadatos directos del stream HLS
    // -------------------------------------------------------------------------
    if (isCurrentSlot) {
      final ocrSlot = _ocrFrameOverrideCache[
              '${identity.brandKey}_${identity.countryFeed.toLowerCase()}'] ??
          _ocrFrameOverrideCache[identity.canonicalNameKey];
      if (ocrSlot != null && slotTime.isBefore(ocrSlot.stop)) {
        return _formatSlotToProgram(
          slot: ocrSlot,
          slotTime: slotTime,
          isCurrentSlot: true,
          nextTitleFallback: 'Continuación de programación en vivo',
          sourceLayer: 'ocr_live',
        );
      }
    }

    // -------------------------------------------------------------------------
    // 2. CAPA 1 (PRIORIDAD MÁXIMA): Guía Real descargada de Internet (mi.tv / gatotv / XMLTV)
    // -------------------------------------------------------------------------
    final xmlCandidates = <String>[
      '${identity.brandKey}_${identity.countryFeed.toLowerCase()}',
      if (identity.tvgIdKey.isNotEmpty) identity.tvgIdKey,
      if (identity.tvgIdKey.contains('.')) identity.tvgIdKey.split('.').first,
      identity.brandKey,
      identity.canonicalNameKey,
      lowerName.replaceAll(' ', ''),
    ];

    for (final key in xmlCandidates) {
      if (key.isNotEmpty && _xmlTvCache.containsKey(key)) {
        final slots = _xmlTvCache[key]!;
        for (int i = 0; i < slots.length; i++) {
          final slot = slots[i];
          if (!slotTime.isBefore(slot.start) && slotTime.isBefore(slot.stop)) {
            final nextTitle = (i + 1 < slots.length)
                ? slots[i + 1].title
                : 'Siguiente emisión programada';
            return _formatSlotToProgram(
              slot: slot,
              slotTime: slotTime,
              isCurrentSlot: isCurrentSlot,
              nextTitleFallback: nextTitle,
              sourceLayer: 'internet_live_epg',
            );
          }
        }
      }
    }

    // -------------------------------------------------------------------------
    // 3. CAPA 2: Eventos Deportivos en Tiempo Real (API ESPN en vivo)
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
    // 4. MIENTRAS TERMINA LA CONSULTA EN INTERNET (PRIMEROS 2 SEGUNDOS):
    //    Mostrar el respaldo individual de ese canal sin mezclar cadenas
    // -------------------------------------------------------------------------
    final bool isHalfHourKids = identity.brandKey == 'discoverykids' ||
        identity.brandKey == 'cartoonnetwork' ||
        identity.brandKey == 'cartoonito' ||
        identity.brandKey == 'nickelodeon' ||
        identity.brandKey == 'nickjr' ||
        identity.brandKey == 'disneychannel' ||
        identity.brandKey == 'disneyjunior';

    final int blockMinutes = isHalfHourKids
        ? 30
        : (_isSportsOrMovieChannel(identity.brandKey, lowerName, lowerCat)
            ? 120
            : 60);

    final DateTime blockStart = blockMinutes == 30
        ? DateTime(
            slotTime.year,
            slotTime.month,
            slotTime.day,
            slotTime.hour,
            slotTime.minute >= 30 ? 30 : 0,
          )
        : DateTime(
            slotTime.year,
            slotTime.month,
            slotTime.day,
            blockMinutes == 120 ? (slotTime.hour ~/ 2) * 2 : slotTime.hour,
            0,
          );
    final DateTime blockEnd = blockStart.add(Duration(minutes: blockMinutes));

    final String sH = blockStart.hour.toString().padLeft(2, '0');
    final String sM = blockStart.minute.toString().padLeft(2, '0');
    final String eH = blockEnd.hour.toString().padLeft(2, '0');
    final String eM = blockEnd.minute.toString().padLeft(2, '0');
    final String timeRange = '$sH:$sM - $eH:$eM';

    final int elapsedMinutes =
        slotTime.difference(blockStart).inMinutes.clamp(0, blockMinutes);
    final int remMinutes = isCurrentSlot
        ? (blockMinutes - elapsedMinutes).clamp(1, blockMinutes)
        : blockMinutes;
    final double progressVal = isCurrentSlot
        ? (elapsedMinutes / blockMinutes).clamp(0.04, 0.96)
        : 0.0;

    final String seedKey = '${identity.brandKey}_${identity.countryFeed}';
    final int channelSeed =
        seedKey.codeUnits.fold<int>(0, (prev, elem) => prev + elem);

    final currentSlotData = _resolveChannelSpecificFallback(
      cleanName: cleanName,
      lowerName: lowerName,
      lowerCat: lowerCat,
      brandKey: identity.brandKey,
      countryFeed: identity.countryFeed,
      slotStart: blockStart,
      channelSeed: channelSeed,
    );

    final nextSlotData = _resolveChannelSpecificFallback(
      cleanName: cleanName,
      lowerName: lowerName,
      lowerCat: lowerCat,
      brandKey: identity.brandKey,
      countryFeed: identity.countryFeed,
      slotStart: blockEnd,
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
    final elapsedMin =
        slotTime.difference(slot.start).inMinutes.clamp(0, totalMin);
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

  static bool _isSportsOrMovieChannel(
    String brandKey,
    String lowerName,
    String lowerCat,
  ) {
    return _isSportsBrand(brandKey) ||
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

  /// Respaldo instantáneo (primeros 2 segundos mientras llega la respuesta de internet)
  static Map<String, String> _resolveChannelSpecificFallback({
    required String cleanName,
    required String lowerName,
    required String lowerCat,
    required String brandKey,
    required String countryFeed,
    required DateTime slotStart,
    required int channelSeed,
  }) {
    final int hour = slotStart.hour;
    final int halfHourSlot = (hour * 2) + (slotStart.minute >= 30 ? 1 : 0);
    final feedLabel =
        countryFeed == 'LATAM' ? 'Señal Internacional' : 'Señal $countryFeed';

    if (brandKey == 'discoverykids') {
      const dkShows = [
        {
          'title': 'Mini Beat Power Rockers',
          'subtitle': 'Fuz, Wat, Myo y Carlos hacen música en la guardería • Discovery Kids'
        },
        {
          'title': 'Peppa Pig',
          'subtitle': 'Aventuras familiares con Peppa y George • Discovery Kids'
        },
        {
          'title': 'Mi Perro Pat',
          'subtitle': 'Pat hace lo imposible por proteger a Lola • Discovery Kids'
        },
        {
          'title': 'El Mundo de Luna',
          'subtitle': 'Luna, Júpiter y Claudio investigan la ciencia • Discovery Kids'
        },
        {
          'title': 'Doki',
          'subtitle': 'Expediciones por el mundo con Doki y sus amigos • Discovery Kids'
        },
        {
          'title': '44 Gatos',
          'subtitle': 'Las aventuras musicales de los Buffycats • Discovery Kids'
        },
      ];
      return dkShows[halfHourSlot % dkShows.length];
    }

    if (brandKey == 'discoverychannel') {
      const discShows = [
        {
          'title': 'Supervivencia al Desnudo',
          'subtitle': '21 días de supervivencia extrema en ambientes salvajes • Discovery Channel'
        },
        {
          'title': 'Supervivencia al Desnudo XL',
          'subtitle': 'Reto grupal de 40 días en la jungla • Discovery Channel'
        },
        {
          'title': 'Fiebre del Oro',
          'subtitle': 'Excavaciones millonarias de oro en el Yukón • Discovery Channel'
        },
        {
          'title': 'Pesca Mortal',
          'subtitle': 'Temporada de pesca extrema en el Mar de Bering • Discovery Channel'
        },
        {
          'title': 'Sobre Ruedas (Wheeler Dealers)',
          'subtitle': 'Restauración mecánica de autos clásicos • Discovery Channel'
        },
      ];
      if (hour >= 19 && hour <= 22) return discShows[0];
      return discShows[hour % discShows.length];
    }

    if (brandKey == 'history' || brandKey == 'history2') {
      const histShows = [
        {
          'title': 'El Precio de la Historia',
          'subtitle': 'Reliquias históricas en Las Vegas con Rick Harrison • History'
        },
        {
          'title': 'Alienígenas Ancestrales',
          'subtitle': 'Misterios arqueológicos de las civilizaciones antiguas • History'
        },
        {
          'title': 'Desafío Sobre Fuego',
          'subtitle': 'Competencia de herrería de armas históricas • History'
        },
        {
          'title': 'Cazadores de Tesoros',
          'subtitle': 'Búsqueda de antigüedades olvidadas por Estados Unidos • History'
        },
      ];
      return histShows[hour % histShows.length];
    }

    if (brandKey == 'natgeo') {
      const natShows = [
        {
          'title': 'Alerta Aeropuerto',
          'subtitle': 'Operativos de seguridad e inspección internacional • National Geographic'
        },
        {
          'title': 'Mayday: Catástrofes Aéreas',
          'subtitle': 'Investigación de accidentes que cambiaron la aviación • National Geographic'
        },
        {
          'title': 'La Ciencia de lo Absurdo',
          'subtitle': 'Explicación física de las caídas y accidentes más insólitos • NatGeo'
        },
      ];
      return natShows[hour % natShows.length];
    }

    if (brandKey == 'cartoonnetwork') {
      const cnShows = [
        {
          'title': 'Los Jóvenes Titanes en Acción',
          'subtitle': 'Aventuras cómicas con Robin, Starfire, Cyborg, Raven y Chico Bestia'
        },
        {
          'title': 'El Increíble Mundo de Gumball',
          'subtitle': 'Comedia animada con Gumball y Darwin en Elmore'
        },
        {
          'title': 'Escandalosos (We Bare Bears)',
          'subtitle': 'Pardo, Panda y Polar en la gran ciudad'
        },
        {
          'title': 'Hora de Aventura',
          'subtitle': 'Finn y Jake en la Tierra de Ooo'
        },
      ];
      return cnShows[halfHourSlot % cnShows.length];
    }

    if (_isSportsBrand(brandKey) ||
        lowerCat.contains('deporte') ||
        lowerCat.contains('sport')) {
      return {
        'title': 'Transmisión Deportiva en Vivo ($cleanName)',
        'subtitle': 'Sincronizando cartelera deportiva oficial ($feedLabel)...',
      };
    }

    return {
      'title': 'Programación en Vivo • $cleanName',
      'subtitle': 'Sincronizando guía de TV en tiempo real ($feedLabel)...',
    };
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
      if (item is Map &&
          (item['groupCategory'] != null || item['category'] != null)) {
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

  static String? _getChannelStreamUrl(dynamic item) {
    if (item == null || item is String) return null;
    try {
      if (item.streamUrl != null && item.streamUrl.toString().isNotEmpty) {
        return item.streamUrl.toString();
      }
    } catch (_) {}
    try {
      if (item is Map && item['streamUrl'] != null) {
        return item['streamUrl'].toString();
      }
    } catch (_) {}
    return null;
  }
}