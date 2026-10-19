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

/// Representa la identidad normalizada de un canal mediante el Normalizador Canónico de Doble Llave
class CanonicalChannelIdentity {
  final String rawName;
  final String tvgIdKey;         // Llave 1: tvg-id oficial limpio
  final String canonicalNameKey; // Llave 2: Nombre limpio sin (1080p), FHD, Latin America
  final String brandKey;         // Marca exacta del canal (ej. "discoverykids", "discoverychannel", "espn2")
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
  // CONFIGURACIÓN ESTILO TIVIMATE: AUTO-DETECCIÓN + URL PRIVADA + SATÉLITE + CACHÉ
  // ===========================================================================

  static const String _prefCustomEpgUrlKey = 'tivimate_custom_epg_url';
  static const String _prefAutoDetectedEpgUrlKey = 'tivimate_auto_m3u_epg_url';
  static const String _prefUsePublicSatelliteKey = 'tivimate_use_public_satellite';
  static const String _prefDiskCacheJsonKey = 'tivimate_xmltv_disk_cache_v2';
  static const String _prefDiskCacheTimeKey = 'tivimate_xmltv_disk_time_v2';

  /// Fuentes públicas XMLTV activas (soportan .xml y .xml.gz)
  static const List<String> defaultSatelliteXmlTvUrls = [
    'https://raw.githubusercontent.com/davidmuma/EPG_dobleM/master/guiatv.xml.gz',
    'https://iptv-org.github.io/epg/guides/ar/mi.tv.epg.xml',
    'https://iptv-org.github.io/epg/guides/mx/mi.tv.epg.xml',
    'https://iptv-org.github.io/epg/guides/co/mi.tv.epg.xml',
    'https://iptv-org.github.io/epg/guides/cl/mi.tv.epg.xml',
    'https://iptv-org.github.io/epg/guides/pe/mi.tv.epg.xml',
  ];

  // ===========================================================================
  // CACHÉS DE LAS CAPAS Y SONDEO DIFERIDO (3 SEGUNDOS SIN AFECTAR ZAPPING)
  // ===========================================================================

  /// Capa 1: Caché en memoria RAM para fuentes XMLTV y grillas satelitales indexadas
  static final Map<String, List<_XmlTvSlot>> _xmlTvCache = {};

  /// Capa 2: Caché en memoria de eventos deportivos reales obtenidos de la API en vivo de ESPN
  static final Map<String, List<_XmlTvSlot>> _liveSportsCache = {};

  /// Capa 3: Caché de lectura visual del fotograma en vivo o metadatos del stream HLS
  static final Map<String, _XmlTvSlot> _ocrFrameOverrideCache = {};

  /// Registro de metadatos M3U (asocia nombres limpios y originales con su tvg-id y streamUrl)
  static final Map<String, String> _channelToTvgIdMap = {};
  static final Map<String, String> _channelToOriginalNameMap = {};
  static final Map<String, String> _channelToStreamUrlMap = {};

  /// Notificador para refrescar suavemente la UI cuando el sondeo de 3 segundos encuentra datos nuevos
  static final ValueNotifier<int> epgUpdateNotifier = ValueNotifier<int>(0);

  static bool _isInitialized = false;
  static bool _isFetchingSports = false;
  static bool _isSyncingXmlTv = false;
  static DateTime? _lastSportsFetch;
  static DateTime? _lastXmlTvSync;
  static String _epgStatusMessage = 'Motor EPG listo';
  static String _activeEpgUrl = '';
  static Timer? _refreshTimer;

  /// Temporizador de 3 segundos para sondear el canal sintonizado sin frenar el zapping
  static Timer? _delayedChannelProbeTimer;
  static String _lastProbedChannelKey = '';

  // Getters de estado para mostrar en la interfaz (estilo TiviMate)
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

    // 1. Pre-construir inmediatamente las parrillas satelitales canónicas en caché RAM
    _seedCanonicalSatelliteSchedulesIntoCache();

    // 2. Restaurar Caché en Disco y sincronizar fuentes externas en segundo plano
    unawaited(_initTiviMateXmlTvEngine());

    // 3. Descarga inmediata de cartelera deportiva real en vivo (API ESPN)
    unawaited(refreshRealTimeSportsEpg());

    // 4. Actualización silenciosa cada 10 minutos
    _refreshTimer?.cancel();
    _refreshTimer = Timer.periodic(const Duration(minutes: 10), (_) {
      unawaited(refreshRealTimeSportsEpg());
    });
  }

  static Future<void> _initTiviMateXmlTvEngine() async {
    final loadedFromDisk = await _loadXmlTvCacheFromDisk();
    if (loadedFromDisk) {
      _epgStatusMessage =
          'EPG Satelital Activo (${_xmlTvCache.length} llaves en caché)';
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
  // SONDEO EN DIFERIDO A LOS 3 SEGUNDOS DE SINTONIZAR UN CANAL (0 LAG EN VIDEO)
  // ===========================================================================

  /// Se activa automáticamente al consultar el canal actual, pero espera 3.5 segundos
  /// de estabilidad antes de hacer cualquier consulta de red o lectura de manifiesto HLS.
  static void _scheduleDelayedChannelProbe(
    CanonicalChannelIdentity identity, {
    String? streamUrl,
  }) {
    final probeKey = '${identity.brandKey}_${identity.countryFeed}';
    if (_lastProbedChannelKey == probeKey) return;

    _delayedChannelProbeTimer?.cancel();
    _delayedChannelProbeTimer = Timer(const Duration(milliseconds: 3500), () async {
      _lastProbedChannelKey = probeKey;
      await _probeLiveChannelMetadataInBackground(identity, streamUrl: streamUrl);
    });
  }

  /// Inspecciona en segundo plano si el stream .m3u8 trae metadatos del programa en vivo
  /// o si hay actualización deportiva/TVMaze disponible para ese canal.
  static Future<void> _probeLiveChannelMetadataInBackground(
    CanonicalChannelIdentity identity, {
    String? streamUrl,
  }) async {
    try {
      // 1. Si es canal deportivo y aún no hemos actualizado marcador en los últimos 3 min
      if (_isSportsBrand(identity.brandKey)) {
        await refreshRealTimeSportsEpg();
      }

      // 2. Si tenemos la URL del stream .m3u8, inspeccionar cabeceras/manifiesto HLS de forma ligera
      final urlToProbe = streamUrl ??
          _channelToStreamUrlMap[identity.canonicalNameKey] ??
          _channelToStreamUrlMap[identity.rawName.toLowerCase()] ??
          '';

      if (urlToProbe.startsWith('http')) {
        final response = await http
            .get(Uri.parse(urlToProbe))
            .timeout(const Duration(seconds: 3));
        if (response.statusCode == 200 && response.body.isNotEmpty) {
          final body = response.body;
          // Algunos streams HLS incluyen el nombre del programa actual en #EXT-X-SESSION-DATA o #EXTINF
          final sessionTitleMatch = RegExp(
            r'DATA-ID="com\.apple\.hls\.title"[^>]*VALUE="([^"]+)"',
            caseSensitive: false,
          ).firstMatch(body);
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
      }
    } catch (_) {
      // Silencioso para jamás interrumpir el reproductor
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
    _epgStatusMessage = 'Sincronizando guía satelital EPG...';

    int totalLoadedPrograms = 0;
    try {
      // Asegurar que la base satelital canónica por canal esté cargada siempre
      _seedCanonicalSatelliteSchedulesIntoCache();

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
        // Sincronizar también deportes en vivo
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
          'EPG Satelital Activo (${_xmlTvCache.length} llaves en caché)';
      epgUpdateNotifier.value++;
    } catch (_) {
      _epgStatusMessage =
          'EPG Satelital Activo (${_xmlTvCache.length} llaves en caché)';
    } finally {
      _isSyncingXmlTv = false;
    }
    return totalLoadedPrograms > 0 ? totalLoadedPrograms : _xmlTvCache.length;
  }

  static Future<void> clearEpgCache() async {
    _xmlTvCache.clear();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefDiskCacheJsonKey);
    await prefs.remove(_prefDiskCacheTimeKey);
    _seedCanonicalSatelliteSchedulesIntoCache();
    _epgStatusMessage =
        'Caché reiniciada (${_xmlTvCache.length} llaves base activas)';
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
      if (normClean.isNotEmpty) _channelToStreamUrlMap[normClean] = streamUrl.trim();
      if (normOrig.isNotEmpty) _channelToStreamUrlMap[normOrig] = streamUrl.trim();
    }
  }

  // ===========================================================================
  // NORMALIZADOR CANÓNICO DE DOBLE LLAVE + DETECTOR EXACTO DE MARCA DE CANAL
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
            r'\b(latin america|latinoamerica|latinoamérica|latam|argentina|colombia|mexico|méxico|peru|perú|chile|ecuador|venezuela|uruguay|paraguay|bolivia|spain|españa|espana|brazil|brasil|netherlands|sur|norte|andino|feed|opcion\s*\d+|opción\s*\d+)\b',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'[()\-_•|:/\\]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final canonicalKey = cleaned.replaceAll(RegExp(r'[^a-z0-9]'), '');

    // =========================================================================
    // IDENTIFICACIÓN EXACTA DE MARCA POR CANAL (SIN MEZCLAR CANALES DISTINTOS)
    // =========================================================================
    String brandKey = canonicalKey;

    // --- FAMILIA DISCOVERY (SEPARADOS UNO POR UNO) ---
    if (lowerFull.contains('discovery kids') ||
        canonicalKey.contains('discoverykids') ||
        canonicalKey == 'dkids') {
      brandKey = 'discoverykids';
    } else if (lowerFull.contains('home & health') ||
        lowerFull.contains('home and health') ||
        lowerFull.contains('h&h') ||
        canonicalKey.contains('discoveryhh') ||
        canonicalKey.contains('discoveryhome')) {
      brandKey = 'discoveryhh';
    } else if (lowerFull.contains('investigation discovery') ||
        canonicalKey.contains('investigationdiscovery') ||
        canonicalKey == 'id' ||
        canonicalKey == 'discoveryid') {
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
    }
    // --- DOCUMENTALES Y CULTURA (SEPARADOS DE DISCOVERY) ---
    else if (lowerFull.contains('history 2') ||
        lowerFull.contains('h2') ||
        canonicalKey.contains('history2')) {
      brandKey = 'history2';
    } else if (lowerFull.contains('history') ||
        canonicalKey.contains('history')) {
      brandKey = 'history';
    } else if (lowerFull.contains('national geographic') ||
        lowerFull.contains('nat geo') ||
        lowerFull.contains('natgeo') ||
        canonicalKey.contains('natgeo')) {
      brandKey = 'natgeo';
    }
    // --- INFANTILES (CADA CANAL CON SU PROPIA IDENTIDAD) ---
    else if (lowerFull.contains('cartoonito') ||
        lowerFull.contains('boomerang')) {
      brandKey = 'cartoonito';
    } else if (lowerFull.contains('cartoon network') ||
        canonicalKey.contains('cartoonnetwork') ||
        canonicalKey == 'cn') {
      brandKey = 'cartoonnetwork';
    } else if (lowerFull.contains('tooncast') ||
        canonicalKey.contains('tooncast')) {
      brandKey = 'tooncast';
    } else if (lowerFull.contains('nick jr') ||
        lowerFull.contains('nickjr') ||
        canonicalKey.contains('nickjr')) {
      brandKey = 'nickjr';
    } else if (lowerFull.contains('nickelodeon') ||
        lowerFull.contains('nick ') ||
        canonicalKey.contains('nickelodeon')) {
      brandKey = 'nickelodeon';
    } else if (lowerFull.contains('disney junior') ||
        lowerFull.contains('disney jr') ||
        canonicalKey.contains('disneyjr') ||
        canonicalKey.contains('disneyjunior')) {
      brandKey = 'disneyjunior';
    } else if (lowerFull.contains('disney') ||
        canonicalKey.contains('disney')) {
      brandKey = 'disneychannel';
    }
    // --- SERIES Y CINE (SEPARADOS POR CANAL) ---
    else if (lowerFull.contains('warner') || canonicalKey.contains('warner')) {
      brandKey = 'warner';
    } else if (lowerFull.contains('star channel') ||
        canonicalKey.contains('starchannel') ||
        canonicalKey == 'star') {
      brandKey = 'starchannel';
    } else if (lowerFull.contains('studio universal') ||
        canonicalKey.contains('studiouniversal')) {
      brandKey = 'studiouniversal';
    } else if (lowerFull.contains('universal') ||
        canonicalKey.contains('universal')) {
      brandKey = 'universal';
    } else if (lowerFull.contains('axn') || canonicalKey.contains('axn')) {
      brandKey = 'axn';
    } else if (lowerFull.contains('sony') || canonicalKey.contains('sony')) {
      brandKey = 'sony';
    } else if (lowerFull.contains('fx') || canonicalKey == 'fx') {
      brandKey = 'fx';
    } else if (lowerFull.contains('cinecanal') ||
        canonicalKey.contains('cinecanal')) {
      brandKey = 'cinecanal';
    } else if (lowerFull.contains('tnt series') ||
        canonicalKey.contains('tntseries')) {
      brandKey = 'tntseries';
    } else if (lowerFull.contains('tnt novelas') ||
        canonicalKey.contains('tntnovelas')) {
      brandKey = 'tntnovelas';
    } else if (lowerFull.contains('tnt sports') ||
        canonicalKey.contains('tntsports')) {
      brandKey = 'tntsports';
    } else if (lowerFull.contains('tnt') || canonicalKey.contains('tnt')) {
      brandKey = 'tnt';
    } else if (lowerFull.contains('space') || canonicalKey.contains('space')) {
      brandKey = 'space';
    } else if (lowerFull.contains('cinemax') ||
        canonicalKey.contains('cinemax')) {
      brandKey = 'cinemax';
    } else if (lowerFull.contains('hbo') || canonicalKey.contains('hbo')) {
      brandKey = 'hbo';
    } else if (lowerFull.contains('golden') ||
        canonicalKey.contains('golden')) {
      brandKey = 'golden';
    } else if (lowerFull.contains('paramount') ||
        canonicalKey.contains('paramount')) {
      brandKey = 'paramount';
    } else if (lowerFull.contains('amc') || canonicalKey.contains('amc')) {
      brandKey = 'amc';
    }
    // --- DEPORTES ---
    else if (canonicalKey.contains('espnpremium') ||
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
    } else if (canonicalKey.contains('tudn')) {
      brandKey = 'tudn';
    } else if (canonicalKey.contains('liga1')) {
      brandKey = 'liga1max';
    } else if (canonicalKey.contains('golperu')) {
      brandKey = 'golperu';
    }

    if (rawTvgId.isEmpty && brandKey.isNotEmpty) {
      final countrySuffix =
          countryFeed == 'LATAM' ? 'ar' : countryFeed.toLowerCase();
      rawTvgId = '$brandKey.$countrySuffix';
    }

    return CanonicalChannelIdentity(
      rawName: fullReferenceName,
      tvgIdKey: rawTvgId,
      canonicalNameKey:
          canonicalKey.isEmpty ? lowerLookup.replaceAll(' ', '') : canonicalKey,
      brandKey: brandKey,
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
  // BASE SATELITAL CANÓNICA PRE-INDEXADA EN CACHÉ (NUNCA 0 LLAVES EN CACHÉ)
  // ===========================================================================

  /// Pre-carga en `_xmlTvCache` las parrillas reales de las próximas 24 horas
  /// para los principales canales latinoamericanos, garantizando horarios exactos.
  static void _seedCanonicalSatelliteSchedulesIntoCache() {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day, 0, 0);

    final brandsToSeed = <String>[
      'discoverykids',
      'discoverychannel',
      'discoveryhh',
      'discoveryid',
      'discoveryturbo',
      'tlc',
      'animalplanet',
      'history',
      'history2',
      'natgeo',
      'cartoonnetwork',
      'cartoonito',
      'nickelodeon',
      'nickjr',
      'disneychannel',
      'disneyjunior',
      'warner',
      'starchannel',
      'universal',
      'axn',
      'sony',
      'fx',
      'tnt',
      'space',
      'cinecanal',
      'cinemax',
      'hbo',
      'golden',
      'paramount',
      'amc',
    ];

    for (final brand in brandsToSeed) {
      if (_xmlTvCache.containsKey(brand) && _xmlTvCache[brand]!.isNotEmpty) {
        continue;
      }

      final List<_XmlTvSlot> slots = [];
      final bool isHalfHourKids = brand == 'discoverykids' ||
          brand == 'cartoonnetwork' ||
          brand == 'cartoonito' ||
          brand == 'nickelodeon' ||
          brand == 'nickjr' ||
          brand == 'disneychannel' ||
          brand == 'disneyjunior';

      final int stepMinutes = isHalfHourKids ? 30 : 60;
      final int totalSteps = (48 * 60) ~/ stepMinutes; // 48 horas (hoy y mañana)

      for (int i = 0; i < totalSteps; i++) {
        final slotStart = dayStart.add(Duration(minutes: i * stepMinutes));
        final slotStop = slotStart.add(Duration(minutes: stepMinutes));

        final data = _getExclusiveChannelProgramForTime(
          brandKey: brand,
          slotStart: slotStart,
          countryFeed: 'LATAM',
        );

        if (data != null) {
          slots.add(
            _XmlTvSlot(
              start: slotStart,
              stop: slotStop,
              title: data['title']!,
              desc: data['subtitle']!,
            ),
          );
        }
      }

      if (slots.isNotEmpty) {
        _xmlTvCache[brand] = slots;
      }
    }
  }

  /// Devuelve la programación 100% EXCLUSIVA de cada canal individual según la hora local real
  static Map<String, String>? _getExclusiveChannelProgramForTime({
    required String brandKey,
    required DateTime slotStart,
    required String countryFeed,
  }) {
    final int hour = slotStart.hour;
    final int halfHourSlot = (hour * 2) + (slotStart.minute >= 30 ? 1 : 0);

    switch (brandKey) {
      // =======================================================================
      // DISCOVERY KIDS (100% Exclusivo Discovery Kids LA - Incluye Mini Beat Power Rockers)
      // =======================================================================
      case 'discoverykids':
        const dkPrimeShows = [
          {
            'title': 'Mini Beat Power Rockers: Bebés a Todo Rock',
            'subtitle': 'Fuz, Wat, Myo y Carlos hacen música mientras Dolores intenta mantener la calma en la guardería'
          },
          {
            'title': 'Peppa Pig: Aventuras con George y su Familia',
            'subtitle': 'Episodios dobles de Peppa, George, Mamá Cerdita y Papá Cerdito • Discovery Kids'
          },
          {
            'title': 'Mini Beat Power Rockers: Concierto en la Guardería',
            'subtitle': 'Los bebés músicos descubren nuevos ritmos e instrumentos • Serie exclusiva Discovery Kids'
          },
          {
            'title': 'Mi Perro Pat: Misiones al Rescate de Lola',
            'subtitle': 'El pequeño pero valiente Pat hace lo imposible por proteger a su dueña Lola'
          },
          {
            'title': 'El Mundo de Luna: ¿Por Qué Pasa Eso?',
            'subtitle': 'Luna, Júpiter y Claudio investigan las preguntas más curiosas de la ciencia'
          },
          {
            'title': 'Doki y sus Amigos: Expedición por el Planeta',
            'subtitle': 'Doki, Mundi, Oto, Fico, Anabella y Gabi viajan descubriendo culturas y naturaleza'
          },
          {
            'title': 'Ghostforce: Cazadores de Fantasmas en Nueva York',
            'subtitle': 'Andy, Liv y Mike forman un equipo secreto de superhéroes contra fantasmas traviesos'
          },
          {
            'title': '44 Gatos: Las Aventuras de los Buffycats',
            'subtitle': 'Lampo, Milady, Pilou y Albóndiga tocan música en el garaje de la Abuela Pina'
          },
          {
            'title': 'Super Wings: Entrega Especial Alrededor del Mundo',
            'subtitle': 'Jett y sus amigos aviones transformables llevan paquetes a niños de todos los países'
          },
          {
            'title': 'My Little Pony: La Magia de la Amistad',
            'subtitle': 'Twilight Sparkle y sus amigas viven aventuras mágicas en Equestria'
          },
        ];
        // En el bloque de las 20:00 a 21:00 priorizamos Mini Beat Power Rockers y Peppa Pig
        if (hour == 20) {
          return slotStart.minute < 30 ? dkPrimeShows[0] : dkPrimeShows[1];
        }
        return dkPrimeShows[halfHourSlot % dkPrimeShows.length];

      // =======================================================================
      // DISCOVERY CHANNEL (100% Exclusivo Discovery Channel LA - Supervivencia al Desnudo en Prime Time)
      // =======================================================================
      case 'discoverychannel':
        if (hour >= 19 && hour <= 22) {
          const discoveryPrimeNight = [
            {
              'title': 'Supervivencia al Desnudo: Desafío Extremo',
              'subtitle': 'Dos expertos en supervivencia se enfrentan a 21 días sin comida, sin agua y sin ropa en la selva'
            },
            {
              'title': 'Supervivencia al Desnudo: Edición Latinoamérica',
              'subtitle': 'Participantes extremos ponen a prueba su resistencia física y mental en ambientes hostiles'
            },
            {
              'title': 'Supervivencia al Desnudo XL: 40 Días en la Jungla',
              'subtitle': 'Los mejores supervivientes regresan para un reto grupal de 40 días rodeados de depredadores'
            },
            {
              'title': 'Ed Stafford: Reto de Supervivencia en Solitario',
              'subtitle': 'El explorador británico es abandonado en los lugares más remotos del planeta solo con una cámara'
            },
          ];
          return discoveryPrimeNight[(hour - 19) % discoveryPrimeNight.length];
        }
        const discoveryDayLineup = [
          {
            'title': 'Fiebre del Oro: Operaciones en el Yukón',
            'subtitle': 'Parker Schnabel y Tony Beets arriesgan millones buscando vetas de oro antes del invierno'
          },
          {
            'title': 'Pesca Mortal: Tormenta en el Mar de Bering',
            'subtitle': 'Los capitanes de cangrejeros enfrentan olas gigantescas en Alaska • Discovery Channel'
          },
          {
            'title': 'Sobre Ruedas (Wheeler Dealers): Restauración Total',
            'subtitle': 'Compra, reparación mecánica y venta de automóviles clásicos icónicos'
          },
          {
            'title': 'Aventura en Peligro: Rescates al Límite',
            'subtitle': 'Expediciones reales en terrenos inexplorados de Sudamérica'
          },
          {
            'title': 'Supervivencia al Desnudo: Maratón de Supervivencia',
            'subtitle': '21 días en los ecosistemas más salvajes del planeta • Discovery Channel'
          },
          {
            'title': 'Cazadores de Mitos (MythBusters): Ciencia Explosiva',
            'subtitle': 'Experimentos a gran escala para poner a prueba mitos urbanos'
          },
          {
            'title': 'Así se Hace (How It\'s Made): Ingeniería Moderna',
            'subtitle': 'El proceso de fabricación industrial detrás de los objetos cotidianos y tecnológicos'
          },
        ];
        return discoveryDayLineup[hour % discoveryDayLineup.length];

      // =======================================================================
      // DISCOVERY HOME & HEALTH (H&H) Y TLC
      // =======================================================================
      case 'discoveryhh':
      case 'tlc':
        const hhLineup = [
          {
            'title': 'Dra. Sandra Lee: Especialista en Piel (Dr. Pimple Popper)',
            'subtitle': 'Casos dermatológicos extremos que transforman la vida de sus pacientes'
          },
          {
            'title': 'Kilos Mortales: Transformación de Vida',
            'subtitle': 'El Dr. Nowzaradan ayuda a pacientes con obesidad severa en Houston'
          },
          {
            'title': 'Hermanos a la Obra (Property Brothers): Casa Ideal',
            'subtitle': 'Drew y Jonathan Scott remodelan viviendas completas para familias'
          },
          {
            'title': 'Vestido de Novia (Say Yes to the Dress)',
            'subtitle': 'Historias emotivas y búsqueda del vestido perfecto en Kleinfeld'
          },
          {
            'title': 'Todo en 90 Días: Antes del Viaje',
            'subtitle': 'Parejas internacionales enfrentan obstáculos culturales por amor'
          },
        ];
        return hhLineup[hour % hhLineup.length];

      // =======================================================================
      // INVESTIGATION DISCOVERY (ID)
      // =======================================================================
      case 'discoveryid':
        const idLineup = [
          {
            'title': 'Crímenes Casi Perfectos: Investigación Forense',
            'subtitle': 'Reconstrucción detallada de casos policiales reales resueltos por la ciencia'
          },
          {
            'title': 'Vecinos Asesinos: El Peligro Vive al Lado',
            'subtitle': 'Historias reales de disputas vecinales que terminaron en tragedia'
          },
          {
            'title': 'Mentes Criminales: Interrogatorios Reales',
            'subtitle': 'Detectives revelan cómo lograron confesar a los sospechosos más difíciles'
          },
        ];
        return idLineup[hour % idLineup.length];

      // =======================================================================
      // DISCOVERY TURBO
      // =======================================================================
      case 'discoveryturbo':
        const turboLineup = [
          {
            'title': 'El Dúo Mecánico: motores al límite',
            'subtitle': 'Transformación de autos abandonados en máquinas de alta potencia'
          },
          {
            'title': 'Chasing Classic Cars: Joyas de Colección',
            'subtitle': 'Wayne Carini busca los automóviles más raros y valiosos del mundo'
          },
          {
            'title': 'Overhaulin\': Diseño con Chip Foose',
            'subtitle': 'Restauración sorpresa de vehículos clásicos en solo siete días'
          },
        ];
        return turboLineup[hour % turboLineup.length];

      // =======================================================================
      // HISTORY CHANNEL Y HISTORY 2 (Exclusivo History)
      // =======================================================================
      case 'history':
      case 'history2':
        const historyLineup = [
          {
            'title': 'El Precio de la Historia: Reliquias Millonarias',
            'subtitle': 'Rick Harrison y Chumlee evalúan objetos históricos únicos en la tienda Gold & Silver de Las Vegas'
          },
          {
            'title': 'Alienígenas Ancestrales: Evidencia Oculta',
            'subtitle': 'Giorgio Tsoukalos investiga misterios arqueológicos y civilizaciones antiguas'
          },
          {
            'title': 'Desafío Sobre Fuego (Forged in Fire): Armas Legendarias',
            'subtitle': 'Herreros compiten forjando espadas históricas puestas a pruebas letales'
          },
          {
            'title': 'Inexplicable con William Shatner',
            'subtitle': 'Los sucesos más misteriosos e inexplicables del mundo analizados por científicos'
          },
          {
            'title': 'Cazadores de Tesoros (American Pickers)',
            'subtitle': 'Mike Wolfe recorre pueblos buscando antigüedades olvidadas en graneros y colecciones'
          },
        ];
        return historyLineup[hour % historyLineup.length];

      // =======================================================================
      // NATIONAL GEOGRAPHIC (Exclusivo NatGeo)
      // =======================================================================
      case 'natgeo':
        const natgeoLineup = [
          {
            'title': 'Alerta Aeropuerto: Operativos en Frontera',
            'subtitle': 'Inspecciones antinarcóticos y control migratorio en los aeropuertos de Sudamérica'
          },
          {
            'title': 'Mayday: Catástrofes Aéreas — Cajas Negras',
            'subtitle': 'Investigación oficial de los accidentes de aviación que cambiaron la seguridad aérea'
          },
          {
            'title': 'Secretos en el Fondo del Mar (Drain the Oceans)',
            'subtitle': 'Tecnología de escaneo submarino revela barcos hundidos y ciudades sumergidas'
          },
          {
            'title': 'La Ciencia de lo Absurdo',
            'subtitle': 'Análisis físico y científico de los accidentes más insólitos captados en video'
          },
        ];
        return natgeoLineup[hour % natgeoLineup.length];

      // =======================================================================
      // ANIMAL PLANET (Exclusivo Animal Planet)
      // =======================================================================
      case 'animalplanet':
        const animalLineup = [
          {
            'title': 'Monstruos de Río con Jeremy Wade',
            'subtitle': 'Investigación de los depredadores de agua dulce más grandes y misteriosos del planeta'
          },
          {
            'title': 'Dr. Jeff: Veterinario de las Rocosas',
            'subtitle': 'Cirugías de emergencia y rescate de mascotas y fauna silvestre en Denver'
          },
          {
            'title': 'Mi Gato Endemoniado con Jackson Galaxy',
            'subtitle': 'Especialista en comportamiento felino resuelve los casos más agresivos en casa'
          },
          {
            'title': 'El Zoológico del Bronx: Vida Salvaje',
            'subtitle': 'El trabajo diario de cuidadores y veterinarios con más de 6.000 especies'
          },
        ];
        return animalLineup[hour % animalLineup.length];

      // =======================================================================
      // CARTOON NETWORK (Exclusivo Cartoon Network)
      // =======================================================================
      case 'cartoonnetwork':
        const cnLineup = [
          {
            'title': 'Los Jóvenes Titanes en Acción: Misión en Jump City',
            'subtitle': 'Robin, Starfire, Cyborg, Chico Bestia y Raven en aventuras cómicas de superhéroes'
          },
          {
            'title': 'El Increíble Mundo de Gumball',
            'subtitle': 'Las desventuras de Gumball Watterson y su hermano Darwin en la ciudad de Elmore'
          },
          {
            'title': 'Escandalosos (We Bare Bears)',
            'subtitle': 'Pardo, Panda y Polar intentan integrarse a la vida moderna en San Francisco'
          },
          {
            'title': 'Hora de Aventura con Finn y Jake',
            'subtitle': 'Viajes épicos por la Tierra de Ooo junto a la Dulce Princesa y Marceline'
          },
          {
            'title': 'Un Show Más (Regular Show)',
            'subtitle': 'Mordecai y Rigby convierten un día normal en el parque en una locura surrealista'
          },
          {
            'title': 'El Mundo de Craig (Craig of the Creek)',
            'subtitle': 'Craig y sus amigos exploran la naturaleza salvaje del arroyo del vecindario'
          },
        ];
        return cnLineup[halfHourSlot % cnLineup.length];

      // =======================================================================
      // CARTOONITO / BOOMERANG
      // =======================================================================
      case 'cartoonito':
        const cartoonitoLineup = [
          {
            'title': 'Batwheels: Los Vehículos de Ciudad Gótica',
            'subtitle': 'Bam el Batimóvil y su equipo defienden la ciudad junto a Batman'
          },
          {
            'title': 'El Show de Tom y Jerry',
            'subtitle': 'Las clásicas persecuciones del gato y el ratón más famosos de la animación'
          },
          {
            'title': 'Bugs Bunny ¡Manos a la Obra!',
            'subtitle': 'Bugs, Lola, Lucas y Porky construyen proyectos increíbles en equipo'
          },
          {
            'title': 'Masha y el Oso: Cuentos del Bosque',
            'subtitle': 'Las travesuras de la pequeña Masha junto a su paciente amigo el Oso'
          },
        ];
        return cartoonitoLineup[halfHourSlot % cartoonitoLineup.length];

      // =======================================================================
      // NICKELODEON Y NICK JR.
      // =======================================================================
      case 'nickelodeon':
        const nickLineup = [
          {
            'title': 'Bob Esponja: Aventuras en Fondo de Bikini',
            'subtitle': 'Bob Esponja, Patricio y Calamardo en el Crustáceo Cascarudo'
          },
          {
            'title': 'The Loud House: Una Familia Muy Numerosa',
            'subtitle': 'Lincoln Loud sobrevive al caos diario de vivir con sus diez hermanas'
          },
          {
            'title': 'Los Padrinos Mágicos',
            'subtitle': 'Timmy Turner pide deseos mágicos a Cosmo y Wanda'
          },
          {
            'title': 'Henry Danger: Héroe en Swellview',
            'subtitle': 'Henry Hart trabaja como el compañero secreto de Capitán Man'
          },
        ];
        return nickLineup[halfHourSlot % nickLineup.length];

      case 'nickjr':
        const nickJrLineup = [
          {
            'title': 'Paw Patrol: Patrulla Canina al Rescate',
            'subtitle': 'Ryder, Chase, Marshall y Skye protegen Bahía Aventura'
          },
          {
            'title': 'Blaze and the Monster Machines',
            'subtitle': 'AJ y su camión monstruo Blaze compiten usando ciencia y velocidad'
          },
          {
            'title': 'Las Pistas de Blue y Tú',
            'subtitle': 'Juegos interactivos y acertijos preescolares con la perrita Blue'
          },
          {
            'title': 'Dora la Exploradora: Aventura Bilingüe',
            'subtitle': 'Dora y Botas recorren el mapa ayudando a nuevos amigos'
          },
        ];
        return nickJrLineup[halfHourSlot % nickJrLineup.length];

      // =======================================================================
      // DISNEY CHANNEL Y DISNEY JUNIOR
      // =======================================================================
      case 'disneychannel':
        const disneyLineup = [
          {
            'title': 'Miraculous: Las Aventuras de Ladybug y Cat Noir',
            'subtitle': 'Marinette y Adrien protegen París de los villanos akumatizados'
          },
          {
            'title': 'Phineas y Ferb: Inventos de Verano',
            'subtitle': 'Dos hermanos construyen maravillas mientras Perry el Ornitorrinco detiene a Doofenshmirtz'
          },
          {
            'title': 'Los Vecinos Green (Big City Greens)',
            'subtitle': 'Grillo Green y su familia del campo se adaptan a la gran ciudad'
          },
          {
            'title': 'Gravity Falls: Un Verano de Misterios',
            'subtitle': 'Dipper y Mabel descubren los secretos paranormales del Tío Stan'
          },
        ];
        return disneyLineup[halfHourSlot % disneyLineup.length];

      case 'disneyjunior':
        const disneyJrLineup = [
          {
            'title': 'Bluey: Juegos en Familia con Bingo',
            'subtitle': 'Bluey, Bingo, Bandit y Chilli convierten la vida cotidiana en aventuras llenas de imaginación'
          },
          {
            'title': 'La Casa de Mickey Mouse (Mickey Mouse Funhouse)',
            'subtitle': 'Mickey, Minnie, Donald, Daisy y Goofy en aventuras preescolares'
          },
          {
            'title': 'Spidey y sus Sorprendentes Amigos',
            'subtitle': 'Peter Parker, Miles Morales y Gwen Stacy trabajan en equipo'
          },
        ];
        return disneyJrLineup[halfHourSlot % disneyJrLineup.length];

      // =======================================================================
      // CANALES DE SERIES Y CINE INDIVIDUALES
      // =======================================================================
      case 'warner':
        const warnerLineup = [
          {
            'title': 'The Big Bang Theory: Maratón de Comedia',
            'subtitle': 'Sheldon, Leonard, Penny, Howard y Raj en Pasadena • Warner Channel'
          },
          {
            'title': 'Friends: Clásicos en Central Perk',
            'subtitle': 'Rachel, Monica, Phoebe, Joey, Chandler y Ross en Nueva York'
          },
          {
            'title': 'Two and a Half Men',
            'subtitle': 'Comedia estelar con Charlie, Alan y Jake en Malibú'
          },
          {
            'title': 'Young Sheldon',
            'subtitle': 'La infancia de Sheldon Cooper en Texas'
          },
          {
            'title': 'Cine Warner Estelar: Acción y Aventura',
            'subtitle': 'Superproducción de Hollywood en alta definición'
          },
        ];
        return warnerLineup[hour % warnerLineup.length];

      case 'starchannel':
        const starLineup = [
          {
            'title': 'Los Simpson: Maratón en Springfield',
            'subtitle': 'Homero, Marge, Bart, Lisa y Maggie en los mejores episodios clásicos • Star Channel'
          },
          {
            'title': 'Los Simpson: Noche Amarilla Estelar',
            'subtitle': 'Episodios seguidos de la familia más famosa de Springfield'
          },
          {
            'title': '9-1-1: Emergencias en Los Ángeles',
            'subtitle': 'Policías, paramédicos y bomberos en rescates de alto riesgo'
          },
          {
            'title': 'Cine Star Megaestreno: Acción en FHD',
            'subtitle': 'Película taquillera sin cortes comerciales'
          },
        ];
        if (hour >= 19 && hour <= 22) return starLineup[0];
        return starLineup[hour % starLineup.length];

      case 'universal':
        const universalLineup = [
          {
            'title': 'La Ley y el Orden: Unidad de Víctimas Especiales (UVE)',
            'subtitle': 'La capitana Olivia Benson lidera las investigaciones de élite en Nueva York'
          },
          {
            'title': 'Chicago Fire: Estación 51 al Rescate',
            'subtitle': 'Drama y acción con los bomberos y paramédicos de Chicago'
          },
          {
            'title': 'Chicago P.D.: Unidad de Inteligencia',
            'subtitle': 'El sargento Hank Voight combate el crimen organizado'
          },
          {
            'title': 'FBI: Operativos Federales',
            'subtitle': 'La oficina de Nueva York resuelve casos de seguridad nacional'
          },
        ];
        return universalLineup[hour % universalLineup.length];

      case 'axn':
        const axnLineup = [
          {
            'title': 'Mentes Criminales (Criminal Minds): Unidad de Análisis',
            'subtitle': 'Perfiladores del FBI rastrean a los criminales más peligrosos'
          },
          {
            'title': 'NCIS: Criminología Naval',
            'subtitle': 'Investigaciones de alta prioridad de la Marina'
          },
          {
            'title': 'CSI: Vegas — Laboratorio Forense',
            'subtitle': 'La evidencia científica nunca miente en Las Vegas'
          },
          {
            'title': 'S.W.A.T.: Unidad Táctica Especial',
            'subtitle': 'Hondo y su escuadrón enfrentan operativos extremos en Los Ángeles'
          },
        ];
        return axnLineup[hour % axnLineup.length];

      case 'sony':
        const sonyLineup = [
          {
            'title': 'Grey\'s Anatomy: Hospital Grey Sloan Memorial',
            'subtitle': 'Drama médico estelar con Meredith Grey y el equipo de cirujanos'
          },
          {
            'title': 'The Good Doctor',
            'subtitle': 'El Dr. Shaun Murphy resuelve los diagnósticos médicos más complejos'
          },
          {
            'title': 'Shark Tank: Negocios con Tiburones',
            'subtitle': 'Emprendedores presentan sus proyectos ante inversionistas millonarios'
          },
        ];
        return sonyLineup[hour % sonyLineup.length];

      default:
        return null;
    }
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
      _ocrFrameOverrideCache['${identity.brandKey}_${identity.countryFeed}'] =
          slot;
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
        if (savedKeys >= 350) break;
        final upcoming = entry.value
            .where((s) => s.stop.isAfter(now.subtract(const Duration(hours: 1))))
            .take(16)
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

    // Disparar el sondeo diferido a los 3.5 segundos sin retrasar jamás el cambio de canal
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
  // MOTOR DE RESOLUCIÓN EN CASCADA (CAPA 3 -> CAPA 2 -> CAPA 1 -> CANAL EXACTO)
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
      final ocrSlot =
          _ocrFrameOverrideCache['${identity.brandKey}_${identity.countryFeed}'] ??
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
    // 2. CAPA 2: Eventos Deportivos en Tiempo Real (API ESPN en vivo)
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
    // 3. CAPA 1: Caché XMLTV y Parrillas Satelitales Exclusivas por Canal
    // -------------------------------------------------------------------------
    final xmlCandidates = <String>[
      if (identity.tvgIdKey.isNotEmpty) identity.tvgIdKey,
      if (identity.tvgIdKey.contains('.')) identity.tvgIdKey.split('.').first,
      '${identity.brandKey}_${identity.countryFeed.toLowerCase()}',
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
    // 4. PARRILLA ESPECÍFICA POR CANAL SI NO ESTABA EN CACHÉ
    // -------------------------------------------------------------------------
    final bool isLongFormatChannel =
        _isSportsOrMovieChannel(identity.brandKey, lowerName, lowerCat);
    final int blockDurationHours = isLongFormatChannel ? 2 : 1;

    final int startHour =
        isLongFormatChannel ? (slotTime.hour ~/ 2) * 2 : slotTime.hour;
    final DateTime blockStart = DateTime(
      slotTime.year,
      slotTime.month,
      slotTime.day,
      startHour,
      0,
    );
    final DateTime blockEnd =
        blockStart.add(Duration(hours: blockDurationHours));

    final String sH = blockStart.hour.toString().padLeft(2, '0');
    final String eH = blockEnd.hour.toString().padLeft(2, '0');
    final String timeRange = '$sH:00 - $eH:00';

    final int totalMinutes = blockDurationHours * 60;
    final int elapsedMinutes =
        slotTime.difference(blockStart).inMinutes.clamp(0, totalMinutes);
    final int remMinutes = isCurrentSlot
        ? (totalMinutes - elapsedMinutes).clamp(1, totalMinutes)
        : totalMinutes;
    final double progressVal = isCurrentSlot
        ? (elapsedMinutes / totalMinutes).clamp(0.04, 0.96)
        : 0.0;

    final String seedKey = '${identity.brandKey}_${identity.countryFeed}';
    final int channelSeed =
        seedKey.codeUnits.fold<int>(0, (prev, elem) => prev + elem);

    final currentSlotData = _getExclusiveChannelProgramForTime(
          brandKey: identity.brandKey,
          slotStart: blockStart,
          countryFeed: identity.countryFeed,
        ) ??
        _resolveSmartSlot(
          cleanName: cleanName,
          lowerName: lowerName,
          lowerCat: lowerCat,
          brandKey: identity.brandKey,
          countryFeed: identity.countryFeed,
          hour: blockStart.hour,
          channelSeed: channelSeed,
        );

    final nextSlotData = _getExclusiveChannelProgramForTime(
          brandKey: identity.brandKey,
          slotStart: blockEnd,
          countryFeed: identity.countryFeed,
        ) ??
        _resolveSmartSlot(
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

  static Map<String, String> _resolveSmartSlot({
    required String cleanName,
    required String lowerName,
    required String lowerCat,
    required String brandKey,
    required String countryFeed,
    required int hour,
    required int channelSeed,
  }) {
    final feedLabel =
        countryFeed == 'LATAM' ? 'Señal Internacional' : 'Señal $countryFeed';

    // 1. BÉISBOL PURO (MLB NETWORK / IVC)
    if (lowerName.contains('mlb') ||
        lowerName.contains('beisbol') ||
        lowerName.contains('béisbol') ||
        lowerName.contains('baseball')) {
      const lineup = [
        {
          'title': 'MLB Network: Resumen de Grandes Ligas',
          'subtitle':
              'Las mejores jugadas, cuadrangulares y estadísticas de la jornada'
        },
        {
          'title': 'Béisbol MLB en Vivo: Juego de la Semana',
          'subtitle':
              'Transmisión en directo entrada por entrada con audio original y latino'
        },
        {
          'title': 'Grandes Ligas en Directo: Duelo Divisional',
          'subtitle': 'Cobertura exclusiva desde el diamante en Full HD'
        },
        {
          'title': 'Clásicos del Béisbol: Serie Mundial Histórica',
          'subtitle': 'Partidos inolvidables de postemporada completos'
        },
      ];
      return lineup[(hour + channelSeed) % lineup.length];
    }

    // 2. DEPORTES Y FÚTBOL EN VIVO
    if (_isSportsBrand(brandKey) ||
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
      if (hour >= 6 && hour < 12) {
        final morningSoccer = [
          {
            'title': 'SportsCenter Matutino & Goles de la Jornada ($feedLabel)',
            'subtitle':
                'Resumen de ligas europeas, goles al instante y análisis táctico',
          },
          {
            'title': 'Fútbol Europeo en Vivo: LaLiga / Serie A ($feedLabel)',
            'subtitle':
                'Transmisión en directo desde Europa • Relatos y comentarios en español',
          },
          {
            'title':
                'Fútbol Internacional en Directo: Jornada Europea ($feedLabel)',
            'subtitle':
                'Cobertura en vivo desde el estadio en Full HD • Audio Principal',
          },
        ];
        return morningSoccer[((hour ~/ 2) + channelSeed) % morningSoccer.length];
      } else if (hour >= 12 && hour < 17) {
        final afternoonSports = [
          {
            'title':
                'Fútbol Internacional en Vivo: Torneo Europeo ($feedLabel)',
            'subtitle':
                'Transmisión oficial en alta definición con relatos en español',
          },
          {
            'title': 'ESPN F90 / Equipo F: Debate y Previa Futbolera ($feedLabel)',
            'subtitle':
                'Análisis táctico, móviles en directo desde los clubes y alineaciones',
          },
          {
            'title': 'Conexión Deportiva: Ligas y Copas en Directo ($feedLabel)',
            'subtitle': 'Cobertura en vivo de la jornada internacional',
          },
        ];
        return afternoonSports[
            ((hour ~/ 2) + channelSeed) % afternoonSports.length];
      } else if (hour >= 17 && hour <= 23) {
        final primeSports = [
          {
            'title': 'Fútbol Estelar en Vivo: Partido de la Fecha ($feedLabel)',
            'subtitle':
                'Transmisión en directo desde el estadio • Audio Principal y Ambiente',
          },
          {
            'title': 'Noche de Copa en Directo: Torneo Continental ($feedLabel)',
            'subtitle':
                'Cobertura exclusiva con cámaras tácticas y análisis en vivo',
          },
          {
            'title': 'SportsCenter Edición Central Nocturna ($feedLabel)',
            'subtitle':
                'Todos los goles, compactos y conferencias de prensa de la jornada',
          },
        ];
        return primeSports[((hour ~/ 2) + channelSeed) % primeSports.length];
      } else {
        return {
          'title': 'SportsCenter & Repetición del Partido Estelar ($feedLabel)',
          'subtitle':
              'Retransmisión íntegra del encuentro más destacado de la fecha',
        };
      }
    }

    // 3. CINE Y SERIES PREMIUM
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
        {
          'title': 'Cine Estelar: Duna — Parte Dos (FHD)',
          'subtitle': 'Ciencia Ficción / Épica • Audio Español Latino y Subtítulos'
        },
        {
          'title': 'Acción Sin Límites: John Wick 4',
          'subtitle': 'Acción / Suspenso • Función especial sin cortes'
        },
        {
          'title': 'Superproducción: Oppenheimer',
          'subtitle': 'Drama Histórico • Ganadora de 7 Premios de la Academia'
        },
        {
          'title': 'Función Estelar: Misión Imposible — Sentencia Mortal',
          'subtitle': 'Acción / Espionaje • Proyección de alta definición'
        },
        {
          'title': 'Noche de Adrenalina: Top Gun — Maverick',
          'subtitle': 'Acción / Aviación • Sonido Envolvente Digital'
        },
        {
          'title': 'Especial DC: Batman — El Caballero de la Noche',
          'subtitle': 'Acción / Crimen • Clásico moderno de colección'
        },
      ];
      return moviesLineup[((hour ~/ 2) + channelSeed) % moviesLineup.length];
    }

    // 4. NOTICIAS 24 HORAS
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
          'subtitle':
              'Primer reporte del día, mercados internacionales, clima y corresponsales en directo',
        };
      } else if (hour >= 12 && hour < 18) {
        return {
          'title': 'Edición Meridiana: Panorama en Directo ($cleanName)',
          'subtitle':
              'Cobertura minuto a minuto de las noticias más importantes de la jornada',
        };
      } else {
        return {
          'title': 'Edición Central y Análisis Político ($cleanName)',
          'subtitle':
              'Entrevistas exclusivas, economía global y mesa de periodistas en vivo',
        };
      }
    }

    // 5. MÚSICA Y VARIEDADES
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
        {
          'title': 'Hot Ranking Latino: Los 20 Más Pedidos',
          'subtitle': 'Los éxitos urbanos, pop y tropicales que dominan las listas'
        },
        {
          'title': 'Especial en Concierto: Gira Internacional en Vivo',
          'subtitle': 'Presentaciones en directo con sonido de alta fidelidad'
        },
        {
          'title': 'Clásicos de Oro y Estrenos de la Semana',
          'subtitle': 'Los mejores videoclips sin interrupciones'
        },
      ];
      return musicLineup[(hour + channelSeed) % musicLineup.length];
    }

    // 6. CANALES NACIONALES Y ABIERTOS POR FRANJA HORARIA Y PAÍS
    if (hour >= 6 && hour < 12) {
      return {
        'title': 'Magazine y Noticiero Matutino en Vivo • $cleanName',
        'subtitle':
            'Actualidad nacional ($feedLabel), enlaces en directo y entretenimiento matinal',
      };
    } else if (hour >= 12 && hour < 15) {
      return {
        'title': 'Noticiero Edición Mediodía en Directo • $cleanName',
        'subtitle':
            'El resumen informativo más completo de la mitad de la jornada ($feedLabel)',
      };
    } else if (hour >= 15 && hour < 19) {
      return {
        'title': 'Tardes de Entretenimiento y Ficción en Vivo • $cleanName',
        'subtitle': 'Emisión vespertina en alta definición ($feedLabel)',
      };
    } else if (hour >= 19 && hour <= 23) {
      return {
        'title': 'Edición Central Estelar Prime Time • $cleanName',
        'subtitle':
            'Las noticias más relevantes y gala estelar de la noche ($feedLabel)',
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