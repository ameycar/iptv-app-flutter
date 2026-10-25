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
    required String title,
    required String desc,
  })  : title = title,
        desc = desc;

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
  final bool hasExplicitCountry;

  const CanonicalChannelIdentity({
    required this.rawName,
    required this.cleanDisplayName,
    required this.tvgIdKey,
    required this.canonicalNameKey,
    required this.brandKey,
    required this.countryFeed,
    this.hasExplicitCountry = false,
  });
}

class EpgService {
  // ===========================================================================
  // CONFIGURACIÓN EPG AMEYCAR (CACHÉ V6 LIMPIA + FUENTES LATAM VERIFICADAS)
  // ===========================================================================

  static const String _prefCustomEpgUrlKey = 'ameycar_custom_epg_url';
  static const String _prefAutoDetectedEpgUrlKey = 'ameycar_auto_m3u_epg_url';
  static const String _prefUsePublicSatelliteKey = 'ameycar_use_public_satellite';
  static const String _prefDiskCacheJsonKey = 'ameycar_xmltv_disk_cache_v6';
  static const String _prefDiskCacheTimeKey = 'ameycar_xmltv_disk_time_v6';

  /// Fuentes XMLTV reales de Latinoamérica (sin mezclar guías de España)
  static const List<Map<String, String>> _regionalXmlTvSources = [
    {
      'country': 'PE',
      'url': 'https://epgshare01.online/epgshare01/epg_ripper_PE1.xml.gz',
    },
    {
      'country': 'CO',
      'url': 'https://epgshare01.online/epgshare01/epg_ripper_CO1.xml.gz',
    },
    {
      'country': 'PE',
      'url': 'https://www.open-epg.com/files/peru.xml.gz',
    },
    {
      'country': 'CO',
      'url': 'https://www.open-epg.com/files/colombia1.xml.gz',
    },
    {
      'country': 'AR',
      'url': 'https://epgshare01.online/epgshare01/epg_ripper_AR1.xml.gz',
    },
    {
      'country': 'AR',
      'url': 'https://www.open-epg.com/files/argentina.xml.gz',
    },
    {
      'country': 'CL',
      'url': 'https://epgshare01.online/epgshare01/epg_ripper_CL1.xml.gz',
    },
    {
      'country': 'MX',
      'url': 'https://epgshare01.online/epgshare01/epg_ripper_MX1.xml.gz',
    },
  ];

  static List<String> get defaultSatelliteXmlTvUrls =>
      _regionalXmlTvSources.map((s) => s['url']!).toList();

  // ===========================================================================
  // CACHÉS EN MEMORIA RAM Y CONTROL REACTIVO
  // ===========================================================================

  static final Map<String, List<_XmlTvSlot>> _xmlTvCache = {};
  static final Map<String, List<_XmlTvSlot>> _liveSportsCache = {};
  static final Map<String, _XmlTvSlot> _ocrFrameOverrideCache = {};

  static final Set<String> _webScrapedChannelsToday = {};
  static final Set<String> _channelsCurrentlyScraping = {};

  static final Map<String, String> _channelToTvgIdMap = {};
  static final Map<String, String> _channelToOriginalNameMap = {};
  static final Map<String, String> _channelToStreamUrlMap = {};

  static final List<String> _backgroundPrefetchQueue = [];
  static bool _isRunningBackgroundPrefetch = false;

  static final ValueNotifier<int> epgUpdateNotifier = ValueNotifier<int>(0);

  static bool _isInitialized = false;
  static bool _isFetchingSports = false;
  static bool _isSyncingXmlTv = false;
  static DateTime? _lastSportsFetch;
  static DateTime? _lastXmlTvSync;
  static String _epgStatusMessage = 'Buscador EPG Oficial Activo';
  static String _activeEpgUrl = '';
  static Timer? _refreshTimer;

  static Timer? _delayedChannelProbeTimer;
  static String _lastTunedProbeKey = '';

  static bool get isSyncingXmlTv => _isSyncingXmlTv;
  static String get epgStatusMessage => _epgStatusMessage;
  static String get activeEpgUrl => _activeEpgUrl;
  static DateTime? get lastXmlTvSync => _lastXmlTvSync;
  static int get cachedXmlTvChannelsCount => _xmlTvCache.length;

  /// Determina el país local del usuario según el reloj de su dispositivo
  static String get _deviceLocalCountry {
    final tzHours = DateTime.now().timeZoneOffset.inHours;
    if (tzHours == -5) return 'PE'; // Perú / Colombia / Ecuador
    if (tzHours == -3) return 'AR'; // Argentina / Uruguay / Chile verano
    if (tzHours == -4) return 'CL'; // Chile / Bolivia / Venezuela
    if (tzHours <= -6) return 'MX'; // México / Centroamérica
    return 'PE';
  }

  static bool isChannelSyncing(String channelName) {
    final identity = normalizeChannel(channelName);
    final lookupKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';
    return _channelsCurrentlyScraping.contains(lookupKey);
  }

  static void ensureInitialized() {
    if (_isInitialized) return;
    _isInitialized = true;

    unawaited(_initXmlTvEngine());

    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      epgUpdateNotifier.value++;
    });
  }

  static Future<void> _initXmlTvEngine() async {
    // Limpiar cachés obsoletas de versiones previas para evitar horarios fantasmas
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('tivimate_xmltv_disk_cache_v4');
      await prefs.remove('tivimate_xmltv_disk_time_v4');
    } catch (_) {}

    final loadedFromDisk = await _loadXmlTvCacheFromDisk();
    if (loadedFromDisk) {
      _epgStatusMessage = 'EPG Activo (${_xmlTvCache.length} señales sincronizadas)';
      epgUpdateNotifier.value++;
    }

    final prefs = await SharedPreferences.getInstance();
    final lastSavedMs = prefs.getInt(_prefDiskCacheTimeKey) ?? 0;
    final cacheAgeHours = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(lastSavedMs))
        .inHours;

    if (!loadedFromDisk || cacheAgeHours >= 3) {
      await syncAllEpgSources(forceNetwork: false);
    }
  }

  // ===========================================================================
  // SONDEO EN TIEMPO REAL AL SINTONIZAR UN CANAL (MI.TV + GATOTV)
  // ===========================================================================

  static void _scheduleDelayedChannelProbe(CanonicalChannelIdentity identity) {
    final lookupKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';

    if (_webScrapedChannelsToday.contains(lookupKey) && _hasValidRealSlots(identity)) {
      return;
    }

    // Si ya tiene guía XMLTV válida y limpia para este país exacto, no hace falta raspar web
    if (_hasExactCountrySlots(identity)) {
      return;
    }

    if (_lastTunedProbeKey == lookupKey && _channelsCurrentlyScraping.contains(lookupKey)) {
      return;
    }

    _lastTunedProbeKey = lookupKey;
    _delayedChannelProbeTimer?.cancel();

    _delayedChannelProbeTimer = Timer(const Duration(milliseconds: 900), () {
      unawaited(_fetchLiveInternetEpgForChannel(identity, saveToDisk: true));
    });
  }

  static bool _hasExactCountrySlots(CanonicalChannelIdentity identity) {
    final now = DateTime.now();
    final exactKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';
    if (_xmlTvCache.containsKey(exactKey)) {
      final list = _xmlTvCache[exactKey]!;
      return list.any((s) => !now.isBefore(s.start) && now.isBefore(s.stop));
    }
    return false;
  }

  static bool _hasValidRealSlots(CanonicalChannelIdentity identity) {
    final now = DateTime.now();
    final candidates = _buildLookupKeysForIdentity(identity);
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

  static Future<bool> _fetchLiveInternetEpgForChannel(
    CanonicalChannelIdentity identity, {
    bool saveToDisk = true,
  }) async {
    if (identity.brandKey.isEmpty) return false;
    final lookupKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';
    if (_channelsCurrentlyScraping.contains(lookupKey)) return false;

    _channelsCurrentlyScraping.add(lookupKey);
    epgUpdateNotifier.value++;

    try {
      unawaited(_probeHlsStreamTitle(identity));

      // 1. Prioridad 1 para Latinoamérica: Mi.tv con el país exacto del feed
      List<_XmlTvSlot> fetchedSlots = await _scrapeMiTvScheduleForChannel(identity);

      // 2. Prioridad 2: GatoTV (parrilla regional en español)
      if (fetchedSlots.isEmpty) {
        fetchedSlots = await _scrapeGatoTvScheduleForChannel(identity);
      }

      // 3. Prioridad 3: TVMaze solo si hay coincidencia estricta de cadena
      if (fetchedSlots.isEmpty) {
        fetchedSlots = await _fetchTvMazeScheduleForChannel(identity);
      }

      if (fetchedSlots.isNotEmpty) {
        final sanitized = _deduplicateAndSortSlots(fetchedSlots);
        if (sanitized.isNotEmpty) {
          _storeFetchedSlotsForIdentity(identity, sanitized);
          _webScrapedChannelsToday.add(lookupKey);
          _epgStatusMessage =
              'Guía sincronizada: ${identity.cleanDisplayName.toUpperCase()} (${identity.countryFeed})';
          epgUpdateNotifier.value++;

          if (saveToDisk) {
            unawaited(_saveXmlTvCacheToDisk());
          }
          return true;
        }
      }
    } catch (_) {
    } finally {
      _channelsCurrentlyScraping.remove(lookupKey);
      epgUpdateNotifier.value++;
    }
    return false;
  }

  /// Limpia programas duplicados o solapados para que jamás aparezcan dos horarios pisándose
  static List<_XmlTvSlot> _deduplicateAndSortSlots(List<_XmlTvSlot> rawSlots) {
    if (rawSlots.isEmpty) return [];
    final sorted = List<_XmlTvSlot>.from(rawSlots)
      ..sort((a, b) => a.start.compareTo(b.start));

    final List<_XmlTvSlot> clean = [];
    for (final slot in sorted) {
      if (!slot.stop.isAfter(slot.start)) continue;
      // Ignorar bloques corruptos de más de 8 horas continuas (como "14:00 - 02:00")
      if (slot.stop.difference(slot.start).inHours > 8) continue;

      if (clean.isEmpty) {
        clean.add(slot);
      } else {
        final prev = clean.last;
        // Si empieza exactamente a la misma hora que el anterior, nos quedamos con el más descriptivo
        if (slot.start.isAtSameMomentAs(prev.start)) {
          if (slot.title.length > prev.title.length && !slot.title.toLowerCase().contains('espn 3')) {
            clean[clean.length - 1] = slot;
          }
          continue;
        }
        // Si se solapa parcialmente con el anterior, ajustamos el cierre del anterior
        if (slot.start.isBefore(prev.stop)) {
          clean[clean.length - 1] = _XmlTvSlot(
            start: prev.start,
            stop: slot.start,
            title: prev.title,
            desc: prev.desc,
          );
        }
        clean.add(slot);
      }
    }
    return clean;
  }

  static void _storeFetchedSlotsForIdentity(
    CanonicalChannelIdentity identity,
    List<_XmlTvSlot> slots,
  ) {
    final countryLower = identity.countryFeed.toLowerCase();
    final exactRegionalKey = '${identity.brandKey}_$countryLower';
    _xmlTvCache[exactRegionalKey] = slots;

    if (identity.tvgIdKey.isNotEmpty) {
      _xmlTvCache[identity.tvgIdKey] = slots;
    }

    // Solo guardamos en la llave genérica si coincide con la región del usuario o no existía aún
    final localCountry = _deviceLocalCountry;
    if (!_xmlTvCache.containsKey(identity.brandKey) ||
        identity.countryFeed == localCountry ||
        (localCountry == 'PE' && identity.countryFeed == 'CO')) {
      _xmlTvCache[identity.brandKey] = slots;
      _xmlTvCache[identity.canonicalNameKey] = slots;
    }
  }

  // ===========================================================================
  // CAPA 1: SCRAPER MI.TV (AJUSTADO A HUSO HORARIO DEL DISPOSITIVO)
  // ===========================================================================

  static Future<List<_XmlTvSlot>> _scrapeMiTvScheduleForChannel(
    CanonicalChannelIdentity identity,
  ) async {
    final countries = _getOrderedMiTvCountries(identity.countryFeed, identity.hasExplicitCountry);
    final candidateSlugs = _buildMiTvCandidateSlugs(identity);
    final now = DateTime.now();
    final dateStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    // Mi.tv recibe el offset en minutos (ej. Perú/Colombia UTC-5 = -300)
    final tzOffsetMin = now.timeZoneOffset.inMinutes;

    for (final country in countries.take(3)) {
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

    // Búsqueda dinámica en mi.tv si el slug directo varía
    final searchQuery = Uri.encodeQueryComponent(identity.cleanDisplayName);
    if (searchQuery.length >= 2) {
      for (final country in countries.take(2)) {
        try {
          final searchUrl = 'https://mi.tv/$country/buscar?q=$searchQuery';
          final res = await http.get(
            Uri.parse(searchUrl),
            headers: const {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36',
              'Accept-Language': 'es-PE,es-419;q=0.9,es;q=0.8',
            },
          ).timeout(const Duration(seconds: 7));

          if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
            final html = utf8.decode(res.bodyBytes, allowMalformed: true);
            final chanLinkRegex = RegExp(
              r'href="/([a-z]{2})/canales/([a-z0-9\-_]+)"',
              caseSensitive: false,
            );
            final matches = chanLinkRegex.allMatches(html).toList();
            for (final m in matches.take(3)) {
              final foundCountry = m.group(1)!;
              final foundSlug = m.group(2)!;
              if (_slugMatchesChannel(foundSlug, identity)) {
                final asyncUrl =
                    'https://mi.tv/$foundCountry/async/channel/$foundSlug/$dateStr/$tzOffsetMin';
                final slots = await _downloadAndParseMiTvHtml(asyncUrl, now);
                if (slots.length >= 3) return slots;
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
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'es-PE,es-419;q=0.9,es;q=0.8',
        },
      ).timeout(const Duration(seconds: 8));

      if (res.statusCode != 200 || res.bodyBytes.isEmpty) return [];
      final html = utf8.decode(res.bodyBytes, allowMalformed: true);
      return _parseMiTvHtmlContent(html, referenceDate);
    } catch (_) {
      return [];
    }
  }

  static List<_XmlTvSlot> _parseMiTvHtmlContent(String html, DateTime now) {
    final List<Map<String, dynamic>> rawItems = [];

    final blockRegex = RegExp(
      r'<span\s+class="time"[^>]*>\s*(\d{1,2}:\d{2})\s*(am|pm)?\s*<\/span>[\s\S]{1,750}?<h2[^>]*>([\s\S]*?)<\/h2>(?:[\s\S]{1,450}?<span\s+class="sub-title"[^>]*>([\s\S]*?)<\/span>)?',
      caseSensitive: false,
    );

    for (final m in blockRegex.allMatches(html)) {
      final rawTime = (m.group(1) ?? '').trim();
      final amPm = (m.group(2) ?? '').trim().toLowerCase();
      final rawTitle = _stripHtmlTags(_unescapeXml(m.group(3) ?? ''));
      final rawSub = _stripHtmlTags(_unescapeXml(m.group(4) ?? ''));

      if (rawTime.isEmpty || rawTitle.isEmpty) continue;

      final parts = rawTime.split(':');
      if (parts.length != 2) continue;
      int hour = int.tryParse(parts[0]) ?? 0;
      final int minute = int.tryParse(parts[1]) ?? 0;

      if (amPm == 'pm' && hour < 12) hour += 12;
      if (amPm == 'am' && hour == 12) hour = 0;

      rawItems.add({
        'hour': hour,
        'minute': minute,
        'title': rawTitle,
        'desc': rawSub.isNotEmpty ? rawSub : 'Programación oficial en vivo',
      });
    }

    if (rawItems.length < 2) return [];

    // Mi.tv inicia su parrilla diaria alrededor de las 05:00 o 06:00 AM
    DateTime baseDay = DateTime(now.year, now.month, now.day);
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
        baseDay = baseDay.add(const Duration(days: 1));
        candidate = DateTime(baseDay.year, baseDay.month, baseDay.day, h, m);
      }
      computedStarts.add(candidate);
      prevStart = candidate;
    }

    final List<_XmlTvSlot> slots = [];
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
  // CAPA 2: SCRAPER GATOTV.COM
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
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0.0.0 Mobile Safari/537.36',
          'Accept-Language': 'es-PE,es-419;q=0.9',
        },
      ).timeout(const Duration(seconds: 7));

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
            desc: 'Guía de programación oficial',
          ),
        );
      }

      return slots;
    } catch (_) {
      return [];
    }
  }

  // ===========================================================================
  // CAPA 3: TVMAZE CON VALIDACIÓN ESTRICTA (SIN CADENAS VACÍAS)
  // ===========================================================================

  static Future<List<_XmlTvSlot>> _fetchTvMazeScheduleForChannel(
    CanonicalChannelIdentity identity,
  ) async {
    if (identity.brandKey.length < 3) return [];
    try {
      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final country = identity.countryFeed.isNotEmpty ? identity.countryFeed.toUpperCase() : 'US';

      final url = 'https://api.tvmaze.com/schedule?country=$country&date=$dateStr';
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 5));

      if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
        final List list = jsonDecode(utf8.decode(res.bodyBytes, allowMalformed: true));
        final List<_XmlTvSlot> matchedSlots = [];

        for (final item in list) {
          final show = item['show'] ?? {};
          final network = (show['network']?['name']?.toString() ?? '')
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]'), '');
          final webChannel = (show['webChannel']?['name']?.toString() ?? '')
              .toLowerCase()
              .replaceAll(RegExp(r'[^a-z0-9]'), '');

          final candidate = network.isNotEmpty ? network : webChannel;
          // Jamás comparar si candidate está vacío (evita el bug brandKey.contains("") == true)
          if (candidate.length < 3) continue;

          if (candidate == identity.brandKey || candidate == identity.canonicalNameKey) {
            final airstamp = item['airstamp']?.toString() ?? '';
            final start = DateTime.tryParse(airstamp)?.toLocal();
            if (start == null) continue;

            final runtime = (item['runtime'] as int?) ?? 30;
            final stop = start.add(Duration(minutes: runtime));
            final title = item['name']?.toString() ?? show['name']?.toString() ?? 'Programa';
            final desc = show['summary']?.toString().replaceAll(RegExp(r'<[^>]*>'), '') ??
                'Emisión oficial de ${identity.cleanDisplayName}';

            matchedSlots.add(_XmlTvSlot(start: start, stop: stop, title: title, desc: desc));
          }
        }

        if (matchedSlots.length >= 3) {
          return matchedSlots;
        }
      }
    } catch (_) {}
    return [];
  }

  static List<String> _getOrderedMiTvCountries(String countryFeed, bool hasExplicit) {
    final code = countryFeed.toUpperCase();
    if (hasExplicit) {
      switch (code) {
        case 'CO':
          return ['co', 'pe', 'ar', 'cl', 'mx'];
        case 'AR':
          return ['ar', 'pe', 'co', 'cl', 'mx'];
        case 'CL':
          return ['cl', 'ar', 'pe', 'co', 'mx'];
        case 'MX':
          return ['mx', 'co', 'pe', 'ar', 'cl'];
        case 'PE':
          return ['pe', 'co', 'ar', 'cl', 'mx'];
      }
    }
    // Si el canal dice genérico "Latin America" (ej. ESPN 3 Latin America), en Perú
    // la señal cable/satélite corresponde al feed Sur/Andino (PE -> AR -> CO)
    return ['pe', 'co', 'ar', 'cl', 'mx'];
  }

  static List<String> _buildMiTvCandidateSlugs(CanonicalChannelIdentity identity) {
    final Set<String> slugs = {};

    const knownSlugs = <String, List<String>>{
      'discoverykids': ['discovery-kids', 'discovery-kids-hd'],
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
      'starchannel': ['star-channel', 'fox-channel'],
      'universal': ['universal-tv', 'universal-channel', 'universal'],
      'studiouniversal': ['studio-universal'],
      'axn': ['axn'],
      'sony': ['sony', 'sony-channel', 'canal-sony'],
      'fx': ['fx'],
      'amc': ['amc'],
      'paramount': ['paramount-network', 'paramount-channel', 'paramount'],
      'tnt': ['tnt'],
      'tntseries': ['tnt-series'],
      'tntnovelas': ['tnt-novelas'],
      'space': ['space'],
      'cinecanal': ['cinecanal'],
      'cinemax': ['cinemax'],
      'hbo': ['hbo'],
      'golden': ['golden', 'golden-multiplex'],
      'espn': ['espn', 'espn-hd'],
      'espn2': ['espn-2', 'espn2', 'espn-2-hd'],
      'espn3': ['espn-3', 'espn3', 'espn-3-hd'],
      'espn4': ['espn-4', 'espn-extra'],
      'espn5': ['espn-5'],
      'espn6': ['espn-6'],
      'espn7': ['espn-7'],
      'espnpremium': ['espn-premium'],
      'foxsports': ['fox-sports'],
      'foxsports2': ['fox-sports-2'],
      'foxsports3': ['fox-sports-3'],
      'dsports': ['directv-sports', 'dsports'],
      'winsports': ['win-sports', 'win-sports-plus'],
      'tycsports': ['tyc-sports'],
      'golperu': ['gol-peru', 'golperu'],
      'liga1max': ['liga-1-max', 'l1-max'],
    };

    if (knownSlugs.containsKey(identity.brandKey)) {
      slugs.addAll(knownSlugs[identity.brandKey]!);
    }

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
      }
    }

    return slugs.toList();
  }

  static List<String> _buildGatoTvCandidateSlugs(CanonicalChannelIdentity identity) {
    final Set<String> slugs = {};
    const gatoKnown = <String, List<String>>{
      'discoverykids': ['discovery_kids', 'discovery_kids_colombia', 'discovery_kids_sur'],
      'espn': ['espn_sur', 'espn_andino', 'espn_latinoamerica', 'espn'],
      'espn2': ['espn_2_sur', 'espn_2_andino', 'espn_2'],
      'espn3': ['espn_3_sur', 'espn_3_andino', 'espn_3_latinoamerica', 'espn_3'],
      'espn4': ['espn_4_sur', 'espn_4'],
      'cartoonnetwork': ['cartoon_network', 'cartoon_network_sur'],
      'disneychannel': ['disney_channel_sur', 'disney_channel'],
    };

    if (gatoKnown.containsKey(identity.brandKey)) {
      slugs.addAll(gatoKnown[identity.brandKey]!);
    }

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

  static bool _slugMatchesChannel(String foundSlug, CanonicalChannelIdentity identity) {
    final cleanFound = foundSlug.replaceAll('-', '').toLowerCase();
    final target = identity.brandKey.toLowerCase();
    if (cleanFound == target || cleanFound == identity.canonicalNameKey) return true;
    // Evitar confundir ESPN con ESPN 2 / ESPN 3 o Discovery con Discovery Kids
    if (RegExp(r'\d').allMatches(target).map((m) => m.group(0)).join() !=
        RegExp(r'\d').allMatches(cleanFound).map((m) => m.group(0)).join()) {
      return false;
    }
    if (target.contains('kids') != cleanFound.contains('kids')) return false;
    return cleanFound.contains(target) || target.contains(cleanFound);
  }

  static String _stripHtmlTags(String htmlText) {
    return htmlText
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Future<void> _probeHlsStreamTitle(CanonicalChannelIdentity identity) async {
    try {
      final urlToProbe = _channelToStreamUrlMap[identity.canonicalNameKey] ??
          _channelToStreamUrlMap[identity.rawName.toLowerCase()] ??
          '';
      if (!urlToProbe.startsWith('http')) return;

      final response =
          await http.get(Uri.parse(urlToProbe)).timeout(const Duration(seconds: 3));
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

  static void _enqueueChannelForBackgroundPrefetch(String channelName) {
    final trimmed = channelName.trim();
    if (trimmed.isEmpty) return;
    if (!_backgroundPrefetchQueue.contains(trimmed) && _backgroundPrefetchQueue.length < 80) {
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
      await Future.delayed(const Duration(seconds: 5));
      while (_backgroundPrefetchQueue.isNotEmpty) {
        final nextName = _backgroundPrefetchQueue.removeAt(0);
        final identity = normalizeChannel(nextName);
        final lookupKey = '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';
        if (!_webScrapedChannelsToday.contains(lookupKey) && !_hasExactCountrySlots(identity)) {
          await _fetchLiveInternetEpgForChannel(identity, saveToDisk: false);
          await Future.delayed(const Duration(milliseconds: 1400));
        }
      }
      await _saveXmlTvCacheToDisk();
    } catch (_) {
    } finally {
      _isRunningBackgroundPrefetch = false;
    }
  }

  // ===========================================================================
  // MÉTODOS DE INTEGRACIÓN CON GESTOR DE LISTAS M3U
  // ===========================================================================

  static Future<String?> extractAndSaveEpgUrlFromM3u(String m3uContent) async {
    if (m3uContent.isEmpty) return null;

    // Además de extraer url-tvg, registramos los tvg-id reales de cada canal en el M3U
    unawaited(Future.microtask(() => _registerChannelTvgIdsFromM3u(m3uContent)));

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
        _epgStatusMessage = 'EPG detectado en lista M3U';
        unawaited(syncAllEpgSources(forceNetwork: true));
        return primaryEpgUrl;
      }
    }
    return null;
  }

  /// Extrae tvg-id="Canal.co" directamente de las líneas #EXTINF del M3U
  static void _registerChannelTvgIdsFromM3u(String m3uContent) {
    try {
      final extInfRegex = RegExp(
        r'#EXTINF:[^\n]*?tvg-id="([^"]+)"[^\n]*?,([^\r\n]+)',
        caseSensitive: false,
      );
      for (final m in extInfRegex.allMatches(m3uContent)) {
        final tvgId = (m.group(1) ?? '').trim().toLowerCase();
        final rawTitle = (m.group(2) ?? '').trim();
        if (tvgId.isNotEmpty && rawTitle.isNotEmpty) {
          _channelToTvgIdMap[rawTitle.toLowerCase()] = tvgId;
        }
      }
    } catch (_) {}
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
    _epgStatusMessage = 'Sincronizando guía satelital regional...';

    int totalLoadedPrograms = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      final customUrl = (prefs.getString(_prefCustomEpgUrlKey) ?? '').trim();
      final autoM3uUrl = (prefs.getString(_prefAutoDetectedEpgUrlKey) ?? '').trim();
      final usePublicSatellite = prefs.getBool(_prefUsePublicSatelliteKey) ?? true;

      if (customUrl.isNotEmpty && customUrl.startsWith('http')) {
        totalLoadedPrograms += await loadXmlTvFromUrl(
          customUrl,
          saveToDiskWhenDone: false,
          sourceCountryHint: _deviceLocalCountry,
        );
      }

      if (autoM3uUrl.isNotEmpty &&
          autoM3uUrl.startsWith('http') &&
          autoM3uUrl != customUrl) {
        totalLoadedPrograms += await loadXmlTvFromUrl(
          autoM3uUrl,
          saveToDiskWhenDone: false,
          sourceCountryHint: _deviceLocalCountry,
        );
      }

      if (usePublicSatellite) {
        for (final src in _regionalXmlTvSources) {
          final url = src['url']!;
          final countryHint = src['country']!;
          final count = await loadXmlTvFromUrl(
            url,
            saveToDiskWhenDone: false,
            sourceCountryHint: countryHint,
          );
          if (count > 0) {
            totalLoadedPrograms += count;
            if (_activeEpgUrl.isEmpty) _activeEpgUrl = url;
          }
        }
      }

      await _saveXmlTvCacheToDisk();
      _lastXmlTvSync = DateTime.now();
      _epgStatusMessage = 'Guía EPG Activa (${_xmlTvCache.length} canales sincronizados)';
      epgUpdateNotifier.value++;
    } catch (_) {
      _epgStatusMessage = 'Guía EPG Activa (${_xmlTvCache.length} canales listos)';
    } finally {
      _isSyncingXmlTv = false;
    }
    return totalLoadedPrograms > 0 ? totalLoadedPrograms : _xmlTvCache.length;
  }

  static Future<void> clearEpgCache() async {
    _xmlTvCache.clear();
    _liveSportsCache.clear();
    _webScrapedChannelsToday.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefDiskCacheJsonKey);
    await prefs.remove(_prefDiskCacheTimeKey);
    _epgStatusMessage = 'Caché EPG limpiada por completo';
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

    _enqueueChannelForBackgroundPrefetch(originalName.isNotEmpty ? originalName : cleanName);
  }

  // ===========================================================================
  // NORMALIZADOR CANÓNICO DE CANALES Y DETECTOR PRECISO DE REGIÓN
  // ===========================================================================

  static CanonicalChannelIdentity normalizeChannel(
    String channelName, {
    String? explicitTvgId,
    String? fallbackCountryHint,
  }) {
    final trimmed = channelName.trim();
    final lowerLookup = trimmed.toLowerCase();

    final fullReferenceName = _channelToOriginalNameMap[lowerLookup] ?? trimmed;
    final lowerFull = fullReferenceName.toLowerCase();

    String rawTvgId = (explicitTvgId != null && explicitTvgId.trim().isNotEmpty)
        ? explicitTvgId.trim().toLowerCase()
        : (_channelToTvgIdMap[lowerLookup] ?? _channelToTvgIdMap[lowerFull] ?? '');

    String countryFeed = fallbackCountryHint ?? _deviceLocalCountry;
    bool hasExplicitCountry = false;

    if (rawTvgId.endsWith('.co') ||
        lowerFull.contains('colombia') ||
        lowerFull.contains('andino')) {
      countryFeed = 'CO';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.pe') ||
        lowerFull.contains('peru') ||
        lowerFull.contains('perú')) {
      countryFeed = 'PE';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.ar') ||
        lowerFull.contains('argentina') ||
        lowerFull.contains('cono sur') ||
        RegExp(r'\bsur\b').hasMatch(lowerFull)) {
      countryFeed = 'AR';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.cl') || lowerFull.contains('chile')) {
      countryFeed = 'CL';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.mx') ||
        lowerFull.contains('mexico') ||
        lowerFull.contains('méxico') ||
        lowerFull.contains('cono norte')) {
      countryFeed = 'MX';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.br') ||
        lowerFull.contains('brazil') ||
        lowerFull.contains('brasil')) {
      countryFeed = 'BR';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.nl') || lowerFull.contains('netherlands')) {
      countryFeed = 'NL';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.es') ||
        lowerFull.contains('spain') ||
        lowerFull.contains('españa') ||
        lowerFull.contains('espana')) {
      countryFeed = 'ES';
      hasExplicitCountry = true;
    } else if (rawTvgId.endsWith('.us') || lowerFull.contains('united states')) {
      countryFeed = 'US';
      hasExplicitCountry = true;
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
            r'\b(latin america|latinoamerica|latinoamérica|latam|argentina|colombia|mexico|méxico|peru|perú|chile|ecuador|venezuela|uruguay|paraguay|bolivia|spain|españa|espana|brazil|brasil|netherlands|united states|panregional|sur|norte|andino|feed|opcion\s*\d+|opción\s*\d+)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[()\-_•|:/\\]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final canonicalKey = cleaned.replaceAll(RegExp(r'[^a-z0-9]'), '');

    String brandKey = canonicalKey;
    if (lowerFull.contains('discovery kids') || canonicalKey.contains('discoverykids')) {
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
    } else if (lowerFull.contains('discovery') || canonicalKey == 'discovery') {
      brandKey = 'discoverychannel';
    } else if (lowerFull.contains('history 2') || canonicalKey.contains('history2')) {
      brandKey = 'history2';
    } else if (lowerFull.contains('history') || canonicalKey.contains('history')) {
      brandKey = 'history';
    } else if (lowerFull.contains('national geographic') ||
        lowerFull.contains('nat geo') ||
        lowerFull.contains('natgeo')) {
      brandKey = 'natgeo';
    } else if (lowerFull.contains('cartoonito') || lowerFull.contains('boomerang')) {
      brandKey = 'cartoonito';
    } else if (lowerFull.contains('cartoon network') ||
        canonicalKey.contains('cartoonnetwork')) {
      brandKey = 'cartoonnetwork';
    } else if (lowerFull.contains('nick jr') || canonicalKey.contains('nickjr')) {
      brandKey = 'nickjr';
    } else if (lowerFull.contains('nickelodeon') || canonicalKey.contains('nickelodeon')) {
      brandKey = 'nickelodeon';
    } else if (lowerFull.contains('disney junior') || lowerFull.contains('disney jr')) {
      brandKey = 'disneyjunior';
    } else if (lowerFull.contains('disney') || canonicalKey.contains('disney')) {
      brandKey = 'disneychannel';
    } else if (canonicalKey.contains('espnpremium') || canonicalKey.contains('espnpack')) {
      brandKey = 'espnpremium';
    } else if (canonicalKey.contains('espnextra') || canonicalKey.contains('espn4')) {
      brandKey = 'espn4';
    } else if (canonicalKey.contains('espn7')) {
      brandKey = 'espn7';
    } else if (canonicalKey.contains('espn6')) {
      brandKey = 'espn6';
    } else if (canonicalKey.contains('espn5')) {
      brandKey = 'espn5';
    } else if (canonicalKey.contains('espn3')) {
      brandKey = 'espn3';
    } else if (canonicalKey.contains('espn2')) {
      brandKey = 'espn2';
    } else if (canonicalKey.contains('espn')) {
      brandKey = 'espn';
    } else if (canonicalKey.contains('foxsports3')) {
      brandKey = 'foxsports3';
    } else if (canonicalKey.contains('foxsports2')) {
      brandKey = 'foxsports2';
    } else if (canonicalKey.contains('foxsports')) {
      brandKey = 'foxsports';
    } else if (canonicalKey.contains('dsports2') ||
        canonicalKey.contains('directvsports2')) {
      brandKey = 'dsports2';
    } else if (canonicalKey.contains('dsports') ||
        canonicalKey.contains('directvsports')) {
      brandKey = 'dsports';
    } else if (canonicalKey.contains('tycsports') || canonicalKey == 'tyc') {
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
      hasExplicitCountry: hasExplicitCountry,
    );
  }

  static void applyLiveFrameOcrText({
    required String channelName,
    required String rawScreenText,
    Duration validity = const Duration(minutes: 45),
  }) {
    final text = rawScreenText.trim();
    if (text.isEmpty) return;

    final identity = normalizeChannel(channelName);
    final now = DateTime.now();

    final scoreRegex = RegExp(r'\b([A-Z]{3})\s*(\d+)\s*[-–:]\s*(\d+)\s*([A-Z]{3})\b');
    final scoreMatch = scoreRegex.firstMatch(text);

    String detectedTitle = '';
    String detectedDesc =
        'Transmisión en directo verificada (${identity.countryFeed})';

    if (scoreMatch != null) {
      final teamA = scoreMatch.group(1)!;
      final goalsA = scoreMatch.group(2)!;
      final goalsB = scoreMatch.group(3)!;
      final teamB = scoreMatch.group(4)!;
      detectedTitle = '🔴 EN VIVO: $teamA $goalsA - $goalsB $teamB';
    } else if (text.length >= 4) {
      detectedTitle = text.split('\n').first.trim();
    }

    if (detectedTitle.isNotEmpty) {
      final slot = _XmlTvSlot(
        start: now.subtract(const Duration(minutes: 15)),
        stop: now.add(validity),
        title: detectedTitle,
        desc: detectedDesc,
      );
      _ocrFrameOverrideCache['${identity.brandKey}_${identity.countryFeed.toLowerCase()}'] = slot;
    }
  }

  /// Mantenido por compatibilidad con llamadas desde la UI, pero sin inyectar partidos falsos
  static Future<void> refreshRealTimeSportsEpg() async {
    if (_isFetchingSports) return;
    _isFetchingSports = true;
    try {
      // Limpiamos cualquier partido asignado artificialmente en versiones previas
      _liveSportsCache.clear();
      _lastSportsFetch = DateTime.now();
    } finally {
      _isFetchingSports = false;
    }
  }

  // ===========================================================================
  // PARSER XMLTV REGIONALIZADO SIN COLISIONES ENTRE PAÍSES
  // ===========================================================================

  static Future<int> loadXmlTvFromUrl(
    String xmlUrl, {
    bool saveToDiskWhenDone = true,
    String? sourceCountryHint,
  }) async {
    try {
      final uri = Uri.tryParse(xmlUrl.trim());
      if (uri == null) return 0;

      final response = await http.get(
        uri,
        headers: const {
          'User-Agent':
              'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36',
          'Accept': '*/*',
        },
      ).timeout(const Duration(seconds: 18));

      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return 0;

      List<int> bytes = response.bodyBytes;
      if (xmlUrl.toLowerCase().endsWith('.gz') ||
          (bytes.length > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b)) {
        try {
          bytes = gzip.decode(bytes);
        } catch (_) {}
      }

      final decodedXml = utf8.decode(bytes, allowMalformed: true);
      if (!decodedXml.contains('<programme')) return 0;

      final count = parseXmlTvContent(decodedXml, sourceCountryHint: sourceCountryHint);
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

  static int parseXmlTvContent(String xmlContent, {String? sourceCountryHint}) {
    int count = 0;
    try {
      final now = DateTime.now();
      final minTime = now.subtract(const Duration(hours: 4));
      final maxTime = now.add(const Duration(hours: 30));

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
            channelIdToIdentity[rawId] = normalizeChannel(
              dispName,
              explicitTvgId: rawId,
              fallbackCountryHint: sourceCountryHint,
            );
            break;
          }
        }
      }

      // Agrupamos primero por rawChannelId único del XML para no mezclar 2 canales de la misma marca
      final Map<String, List<_XmlTvSlot>> perRawChannelSlots = {};

      final progBlockRegex = RegExp(
        r'<programme\s+([^>]+)>([\s\S]*?)<\/programme>',
        caseSensitive: false,
      );
      final startAttrRegex = RegExp(r'start="([^"]+)"', caseSensitive: false);
      final stopAttrRegex = RegExp(r'stop="([^"]+)"', caseSensitive: false);
      final chanAttrRegex = RegExp(r'channel="([^"]+)"', caseSensitive: false);

      final titleRegex = RegExp(r'<title[^>]*>([\s\S]*?)<\/title>', caseSensitive: false);
      final descRegex = RegExp(r'<desc[^>]*>([\s\S]*?)<\/desc>', caseSensitive: false);

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

        final cleanTitle = _unescapeXml(titleMatch?.group(1) ?? '').trim();
        if (cleanTitle.isEmpty) continue;

        final cleanDesc =
            _unescapeXml(descMatch?.group(1) ?? 'Programación oficial en directo');

        perRawChannelSlots.putIfAbsent(rawChannelId, () => []).add(
              _XmlTvSlot(
                start: startDt,
                stop: stopDt,
                title: cleanTitle,
                desc: cleanDesc,
              ),
            );
        count++;
      }

      final localCountry = _deviceLocalCountry;

      // Indexar cada canal limpio y deduplicado sin aplastar otros países
      perRawChannelSlots.forEach((rawChannelId, rawList) {
        final cleanSlots = _deduplicateAndSortSlots(rawList);
        if (cleanSlots.isEmpty) return;

        // 1. Siempre guardar bajo el ID exacto del XMLTV (ej. discovery.kids.co)
        _xmlTvCache[rawChannelId] = cleanSlots;

        final identity = channelIdToIdentity[rawChannelId] ??
            normalizeChannel(
              rawChannelId,
              explicitTvgId: rawChannelId,
              fallbackCountryHint: sourceCountryHint,
            );

        if (identity.brandKey.isNotEmpty) {
          final regionalKey =
              '${identity.brandKey}_${identity.countryFeed.toLowerCase()}';

          // Solo reemplazar la llave regional si aún no existe o tiene más detalle
          if (!_xmlTvCache.containsKey(regionalKey) ||
              cleanSlots.length > (_xmlTvCache[regionalKey]?.length ?? 0)) {
            _xmlTvCache[regionalKey] = cleanSlots;
          }

          // La llave genérica (sin país) SOLO acepta feeds de nuestra misma región horaria (PE/CO)
          final isLocalPreferred = identity.countryFeed == localCountry ||
              (localCountry == 'PE' && identity.countryFeed == 'CO');
          if (isLocalPreferred || !_xmlTvCache.containsKey(identity.brandKey)) {
            if (identity.countryFeed != 'ES' &&
                identity.countryFeed != 'BR' &&
                identity.countryFeed != 'NL' &&
                identity.countryFeed != 'US') {
              _xmlTvCache[identity.brandKey] = cleanSlots;
              _xmlTvCache[identity.canonicalNameKey] = cleanSlots;
            }
          }
        }
      });
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
        if (savedKeys >= 450) break;
        final upcoming = entry.value
            .where((s) => s.stop.isAfter(now.subtract(const Duration(hours: 1))))
            .take(20)
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
              .where((s) => s.stop.isAfter(now.subtract(const Duration(hours: 1))))
              .toList();
          if (slots.isNotEmpty) {
            _xmlTvCache[key] = _deduplicateAndSortSlots(slots);
            restored++;
          }
        }
      });

      return restored > 0;
    } catch (_) {
      return false;
    }
  }

  /// Convierte fechas XMLTV ("20261025093000 -0300" o "+0000") a la hora exacta del dispositivo
  static DateTime? _parseXmlTvDate(String raw) {
    try {
      final trimmed = raw.trim();
      final match = RegExp(r'^(\d{12,14})\s*([+-]\d{4})?').firstMatch(trimmed);
      if (match == null) return null;

      final digits = match.group(1)!;
      final tzPart = match.group(2);

      final year = int.parse(digits.substring(0, 4));
      final month = int.parse(digits.substring(4, 6));
      final day = int.parse(digits.substring(6, 8));
      final hour = int.parse(digits.substring(8, 10));
      final minute = int.parse(digits.substring(10, 12));
      final second = digits.length >= 14 ? int.parse(digits.substring(12, 14)) : 0;

      if (tzPart != null && tzPart.length == 5) {
        final sign = tzPart.startsWith('-') ? -1 : 1;
        final tzHours = int.parse(tzPart.substring(1, 3));
        final tzMinutes = int.parse(tzPart.substring(3, 5));
        final totalOffsetMinutes = sign * ((tzHours * 60) + tzMinutes);

        final utcInstant = DateTime.utc(year, month, day, hour, minute, second)
            .subtract(Duration(minutes: totalOffsetMinutes));
        return utcInstant.toLocal();
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
  // MÉTODOS PÚBLICOS DE CONSULTA PARA LA INTERFAZ Y LAS ALARMAS
  // ===========================================================================

  static List<String> _buildLookupKeysForIdentity(CanonicalChannelIdentity identity) {
    final c = identity.countryFeed.toLowerCase();
    final List<String> keys = [
      if (identity.tvgIdKey.isNotEmpty) identity.tvgIdKey,
      '${identity.brandKey}_$c',
    ];

    // Si es un canal genérico "Latin America" sin país fijo en el nombre, buscamos en orden regional
    if (!identity.hasExplicitCountry) {
      keys.addAll([
        '${identity.brandKey}_pe',
        '${identity.brandKey}_co',
        '${identity.brandKey}_ar',
        '${identity.brandKey}_cl',
        identity.brandKey,
        identity.canonicalNameKey,
      ]);
    } else {
      // Si el canal dice explícitamente "Colombia", probamos CO y luego PE (mismo huso UTC-5)
      if (identity.countryFeed == 'CO') {
        keys.add('${identity.brandKey}_pe');
      } else if (identity.countryFeed == 'PE') {
        keys.add('${identity.brandKey}_co');
      } else if (identity.countryFeed == 'AR') {
        keys.add('${identity.brandKey}_cl');
      }
      keys.add(identity.brandKey);
    }
    return keys;
  }

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
        ? current.endTime!.add(const Duration(seconds: 30))
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

    final now = DateTime.now();
    final candidates = _buildLookupKeysForIdentity(identity);

    // Si tenemos la lista real de slots en caché, devolvemos la secuencia exacta sin huecos ni pisadas
    for (final key in candidates) {
      if (key.isNotEmpty && _xmlTvCache.containsKey(key)) {
        final slots = _xmlTvCache[key]!;
        final activeIdx = slots.indexWhere(
          (s) => !now.isBefore(s.start) && now.isBefore(s.stop),
        );
        if (activeIdx != -1) {
          final List<EpgProgram> realSchedule = [];
          for (int i = activeIdx; i < slots.length && realSchedule.length < 10; i++) {
            final slot = slots[i];
            final nextTitle = (i + 1 < slots.length)
                ? slots[i + 1].title
                : 'Continuación de programación';
            realSchedule.add(
              _formatSlotToProgram(
                slot: slot,
                slotTime: i == activeIdx ? now : slot.start,
                isCurrentSlot: i == activeIdx,
                nextTitleFallback: nextTitle,
                sourceLayer: 'verified_epg',
              ),
            );
          }
          if (realSchedule.isNotEmpty) return realSchedule;
        }
      }
    }

    // Mientras sincroniza los primeros segundos, mostramos bloques horarios limpios (sin nombres falsos)
    final List<EpgProgram> fallbackSchedule = [];
    DateTime cursorTime = DateTime(now.year, now.month, now.day, now.hour, now.minute >= 30 ? 30 : 0);

    for (int i = 0; i < 6; i++) {
      final prog = _buildProgramForSlot(
        channelName: channelName,
        category: category ?? '',
        explicitTvgId: tvgId,
        slotTime: i == 0 ? now : cursorTime,
        isCurrentSlot: i == 0,
      );
      fallbackSchedule.add(prog);
      cursorTime = (prog.endTime ?? cursorTime.add(const Duration(minutes: 30)));
    }

    return fallbackSchedule;
  }

  static EpgProgram _buildProgramForSlot({
    required String channelName,
    required String category,
    String? explicitTvgId,
    required DateTime slotTime,
    required bool isCurrentSlot,
  }) {
    final identity = normalizeChannel(channelName, explicitTvgId: explicitTvgId);
    final cleanName = channelName.trim().isEmpty ? 'Canal en Vivo' : channelName.trim();

    // 1. Título embebido en el propio stream HLS (si la señal lo envía)
    if (isCurrentSlot) {
      final ocrSlot =
          _ocrFrameOverrideCache['${identity.brandKey}_${identity.countryFeed.toLowerCase()}'];
      if (ocrSlot != null && slotTime.isBefore(ocrSlot.stop)) {
        return _formatSlotToProgram(
          slot: ocrSlot,
          slotTime: slotTime,
          isCurrentSlot: true,
          nextTitleFallback: 'Continuación en directo',
          sourceLayer: 'hls_live',
        );
      }
    }

    // 2. Parrilla real verificada (XMLTV Regional / Mi.tv / GatoTV)
    final candidates = _buildLookupKeysForIdentity(identity);
    for (final key in candidates) {
      if (key.isNotEmpty && _xmlTvCache.containsKey(key)) {
        final slots = _xmlTvCache[key]!;
        for (int i = 0; i < slots.length; i++) {
          final slot = slots[i];
          if (!slotTime.isBefore(slot.start) && slotTime.isBefore(slot.stop)) {
            final nextTitle = (i + 1 < slots.length)
                ? slots[i + 1].title
                : 'Siguiente programa';
            return _formatSlotToProgram(
              slot: slot,
              slotTime: slotTime,
              isCurrentSlot: isCurrentSlot,
              nextTitleFallback: nextTitle,
              sourceLayer: 'verified_epg',
            );
          }
        }
      }
    }

    // 3. Estado honesto mientras descarga la guía real (sin inventar programas engañosos)
    final DateTime blockStart = DateTime(
      slotTime.year,
      slotTime.month,
      slotTime.day,
      slotTime.hour,
      slotTime.minute >= 30 ? 30 : 0,
    );
    final DateTime blockEnd = blockStart.add(const Duration(minutes: 30));

    final String sH = blockStart.hour.toString().padLeft(2, '0');
    final String sM = blockStart.minute.toString().padLeft(2, '0');
    final String eH = blockEnd.hour.toString().padLeft(2, '0');
    final String eM = blockEnd.minute.toString().padLeft(2, '0');

    final int elapsedMinutes = slotTime.difference(blockStart).inMinutes.clamp(0, 30);
    final int remMinutes = isCurrentSlot ? (30 - elapsedMinutes).clamp(1, 30) : 30;
    final double progressVal =
        isCurrentSlot ? (elapsedMinutes / 30).clamp(0.05, 0.95) : 0.0;

    final syncingNow = isChannelSyncing(channelName) || _isSyncingXmlTv;

    return EpgProgram(
      title: syncingNow
          ? 'Sincronizando guía • ${identity.cleanDisplayName.toUpperCase()}'
          : 'En Vivo • $cleanName',
      subtitle: 'Señal ${identity.countryFeed} en directo',
      timeRange: '$sH:$sM - $eH:$eM',
      nextTitle: 'Programación continua (${identity.countryFeed})',
      progress: progressVal,
      remainingMinutes: remMinutes,
      startTime: blockStart,
      endTime: blockEnd,
      isLiveEvent: false,
      sourceLayer: 'syncing_placeholder',
    );
  }

  static EpgProgram _formatSlotToProgram({
    required _XmlTvSlot slot,
    required DateTime slotTime,
    required bool isCurrentSlot,
    required String nextTitleFallback,
    required String sourceLayer,
  }) {
    final totalMin = slot.stop.difference(slot.start).inMinutes.clamp(1, 480);
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
      remainingMinutes: (totalMin - elapsedMin).clamp(1, 480),
      startTime: slot.start,
      endTime: slot.stop,
      isLiveEvent: slot.title.startsWith('🔴'),
      sourceLayer: sourceLayer,
    );
  }

  static String _getChannelName(dynamic item) {
    if (item == null) return 'Canal en Vivo';
    if (item is String) return item;
    try {
      if (item.name != null && item.name.toString().isNotEmpty) {
        return item.name.toString();
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
    return '';
  }

  static String? _getChannelTvgId(dynamic item) {
    if (item == null || item is String) return null;
    try {
      if (item.tvgId != null && item.tvgId.toString().isNotEmpty) {
        return item.tvgId.toString();
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
    return null;
  }
}
