import 'dart:async';
import 'dart:convert';
import '../models/channel_model.dart';
import 'epg_service.dart';

class M3USanitizerService {
  /// Limpia y separa con precisión: Canales de TV (.m3u8) vs Películas/Series VOD (.mp4, /movie/)
  /// Y registra automáticamente el EPG (url-tvg / x-tvg-url) y los tvg-id estilo TiviMate
  static List<ChannelModel> parseAndSanitize(String rawM3u) {
    // Asegura que el motor EPG (Caché en Disco + Satélite + Deportes en Vivo) esté activo
    EpgService.ensureInitialized();

    final List<ChannelModel> sanitizedChannels = [];
    final cleanContent = rawM3u
        .replaceAll('\uFEFF', '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    // 1. Auto-detección estilo TiviMate del enlace EPG en la cabecera del M3U
    unawaited(EpgService.extractAndSaveEpgUrlFromM3u(cleanContent));

    final lines = const LineSplitter().convert(cleanContent);

    String rawOriginalName = 'Canal sin nombre';
    String tempName = 'Canal sin nombre';
    String tempLogo = '';
    String tempGroup = 'General';
    String tempTvgId = '';
    String tempTvgName = '';
    bool awaitingUrlAfterExtInf = false;
    int channelCounter = 1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase().startsWith('#EXTM3U')) {
        unawaited(EpgService.extractAndSaveEpgUrlFromM3u(line));
      } else if (line.toUpperCase().startsWith('#EXTINF:')) {
        awaitingUrlAfterExtInf = true;

        final logoMatch = RegExp(r'tvg-logo="([^"]*)"', caseSensitive: false).firstMatch(line);
        tempLogo = logoMatch?.group(1)?.trim() ?? '';

        final groupMatch = RegExp(r'group-title="([^"]*)"', caseSensitive: false).firstMatch(line);
        tempGroup = groupMatch?.group(1)?.trim() ?? 'General';

        final idMatch = RegExp(r'tvg-id="([^"]*)"', caseSensitive: false).firstMatch(line);
        tempTvgId = idMatch?.group(1)?.trim() ?? '';

        final tvgNameMatch = RegExp(r'tvg-name="([^"]*)"', caseSensitive: false).firstMatch(line);
        tempTvgName = tvgNameMatch?.group(1)?.trim() ?? '';

        final extractedTitle = _extractTitleAfterAttributes(line);
        if (extractedTitle.isNotEmpty) {
          rawOriginalName = extractedTitle;
        } else if (tempTvgName.isNotEmpty) {
          rawOriginalName = tempTvgName;
        } else {
          rawOriginalName = 'Canal $channelCounter';
        }

        tempName = _cleanChannelTitle(rawOriginalName);
      } else if (line.toUpperCase().startsWith('#EXTGRP:')) {
        final grp = line.substring(8).trim();
        if (grp.isNotEmpty && tempGroup == 'General') {
          tempGroup = grp;
        }
      } else if (!line.startsWith('#')) {
        final lowerLine = line.toLowerCase();
        final isUrl = lowerLine.startsWith('http://') ||
            lowerLine.startsWith('https://') ||
            lowerLine.startsWith('rtmp://') ||
            lowerLine.startsWith('rtsp://') ||
            lowerLine.startsWith('mms://');

        // Si en el M3U hubo un salto de línea accidental entre #EXTINF y el nombre de la película, lo rescata aquí
        if (!isUrl && awaitingUrlAfterExtInf) {
          final continuationTitle = line.replaceAll(RegExp(r'^,+\s*'), '').trim();
          if (continuationTitle.isNotEmpty) {
            rawOriginalName = continuationTitle;
            tempName = _cleanChannelTitle(rawOriginalName);
          }
          continue;
        }

        if (isUrl) {
          String cleanUrl = _normalizeStreamUrl(line);

          // Respaldo inteligente para que nunca quede como "Canal sin nombre"
          if (tempName == 'Canal sin nombre' || tempName.startsWith('Canal ')) {
            if (tempTvgName.isNotEmpty) {
              rawOriginalName = tempTvgName;
              tempName = _cleanChannelTitle(rawOriginalName);
            } else {
              final urlFallbackName = _extractNameFromUrl(cleanUrl);
              if (urlFallbackName.isNotEmpty) {
                rawOriginalName = urlFallbackName;
                tempName = _cleanChannelTitle(rawOriginalName);
              }
            }
          }

          final contentType = _determineContentType(tempName, tempGroup, cleanUrl);
          final category = _determineCategory(tempName, tempGroup, contentType);
          final year = _extractYear(tempName);
          final finalChannelName = tempName.isEmpty ? 'Elemento $channelCounter' : tempName;

          // 2. Registrar en el Normalizador Canónico de Doble Llave de EpgService
          // Así el banner sabe el tvg-id exacto y el país original (Argentina, México, Colombia, España, etc.)
          EpgService.registerChannelMetadata(
            cleanName: finalChannelName,
            originalName: rawOriginalName,
            tvgId: tempTvgId,
            tvgName: tempTvgName,
            category: category,
          );

          sanitizedChannels.add(
            ChannelModel(
              id: 'item_$channelCounter',
              number: channelCounter,
              name: finalChannelName,
              streamUrl: cleanUrl,
              logoUrl: tempLogo,
              groupCategory: category,
              resolution: _detectResolution(rawOriginalName, cleanUrl),
              contentType: contentType,
              year: year,
              rating: contentType == 'live' ? 'HD' : '8.5',
              isValid: true,
            ),
          );
          channelCounter++;

          // Resetear variables temporales para el siguiente canal
          rawOriginalName = 'Canal sin nombre';
          tempName = 'Canal sin nombre';
          tempLogo = '';
          tempGroup = 'General';
          tempTvgId = '';
          tempTvgName = '';
          awaitingUrlAfterExtInf = false;
        }
      }
    }

    return sanitizedChannels.isNotEmpty ? sanitizedChannels : getCuratedChannels();
  }

  /// Extrae el título después de la coma de cierre de #EXTINF ignorando comas dentro de comillas
  static String _extractTitleAfterAttributes(String extInfLine) {
    bool inQuotes = false;
    int lastValidComma = -1;

    for (int i = 0; i < extInfLine.length; i++) {
      final char = extInfLine[i];
      if (char == '"') {
        inQuotes = !inQuotes;
      } else if (char == ',' && !inQuotes) {
        lastValidComma = i;
      }
    }

    if (lastValidComma != -1 && lastValidComma < extInfLine.length - 1) {
      return extInfLine.substring(lastValidComma + 1).trim();
    }
    return '';
  }

  /// Limpia la URL codificando espacios en %20 y asegurando HTTPS en Archive.org
  static String _normalizeStreamUrl(String rawUrl) {
    var trimmed = rawUrl.trim();
    if (trimmed.contains(' ')) {
      trimmed = trimmed.replaceAll(' ', '%20');
    }
    if (trimmed.startsWith('http://') && trimmed.contains('archive.org/')) {
      trimmed = trimmed.replaceFirst('http://', 'https://');
    }
    return trimmed;
  }

  /// Extrae el nombre de la película desde el archivo de la URL si el M3U no traía título
  static String _extractNameFromUrl(String url) {
    try {
      final uri = Uri.parse(url);
      if (uri.pathSegments.isNotEmpty) {
        String lastSeg = Uri.decodeComponent(uri.pathSegments.last);
        lastSeg = lastSeg.replaceAll(
          RegExp(r'\.(mp4|mkv|avi|mov|webm|m3u8|ts|mpd)$', caseSensitive: false),
          '',
        );
        lastSeg = lastSeg.replaceAll(RegExp(r'[_.-]+'), ' ').trim();
        final lower = lastSeg.toLowerCase();
        if (lastSeg.length > 2 &&
            lower != 'master' &&
            lower != 'playlist' &&
            lower != 'index' &&
            !lower.startsWith('24h')) {
          return lastSeg;
        }
      }
    } catch (_) {}
    return '';
  }

  /// CLASIFICADOR ESTRICTO: NO confunde canales continuos con películas bajo demanda
  static String _determineContentType(String name, String group, String url) {
    final lowerUrl = url.toLowerCase();
    final lowerName = name.toLowerCase();
    final lowerGroup = group.toLowerCase();

    final isVODExtension = lowerUrl.endsWith('.mp4') ||
        lowerUrl.endsWith('.mkv') ||
        lowerUrl.endsWith('.avi') ||
        lowerUrl.endsWith('.mov') ||
        lowerUrl.endsWith('.webm');
    final isXtreamMovie = lowerUrl.contains('/movie/') ||
        lowerUrl.contains('/movies/') ||
        lowerUrl.contains('/vod/');
    final isXtreamSeries = lowerUrl.contains('/series/');
    final hasEpisodeFormat = RegExp(
      r'\b(?:s\d+\s*e\d+|t\d+\s*e\d+|[st]\d+.*[ec]\d+)\b',
      caseSensitive: false,
    ).hasMatch(name);

    // 1. Series VOD reales (archivos de series, formato de capítulo S01E01 o grupo explícito Series)
    if (isXtreamSeries ||
        hasEpisodeFormat ||
        ((lowerGroup == 'series' || lowerGroup.startsWith('serie')) &&
            !lowerGroup.contains('24/7'))) {
      return 'series';
    }

    // 2. Películas VOD reales (archivos de video específicos)
    if (isVODExtension || isXtreamMovie) {
      return 'movie';
    }

    // Si el grupo dice Películas o VOD explícitamente (y no es un canal 24/7)
    if ((lowerGroup == 'peliculas' ||
            lowerGroup == 'películas' ||
            lowerGroup == 'movies' ||
            lowerGroup.startsWith('vod') ||
            lowerGroup.contains('vod |') ||
            lowerGroup.contains('vod:')) &&
        !lowerGroup.contains('24/7') &&
        !lowerName.contains('24/7')) {
      return 'movie';
    }

    // 3. Todo lo demás (.m3u8, canales 24/7 de cine como 4ever Cinema, Pluto, etc.) son CANALES EN VIVO
    return 'live';
  }

  static String _extractYear(String title) {
    final match = RegExp(r'\((\d{4})\)|\[(\d{4})\]|\b(19\d\d|20\d\d)\b').firstMatch(title);
    return match?.group(1) ?? match?.group(2) ?? match?.group(3) ?? '';
  }

  static String _cleanChannelTitle(String title) {
    var clean = title;
    clean = clean.replaceAll(RegExp(r'^\[[^\]]+\]\s*'), '');
    clean = clean.replaceAll(RegExp(r'^\|[^\|]+\|\s*'), '');
    clean = clean.replaceAll(RegExp(r'\s*\[(?:HD|FHD|4K|UHD|SD|HEVC)\]', caseSensitive: false), '');
    clean = clean.replaceAll(RegExp(r'\s*\((?:HD|FHD|4K|UHD|SD|HEVC)\)', caseSensitive: false), '');
    clean = clean.replaceAll(RegExp(r'^[-_•*~]+\s*'), '');
    return clean.trim().isEmpty ? title : clean.trim();
  }

  static String _determineCategory(String name, String rawGroup, String contentType) {
    final lowerGroup = rawGroup.toLowerCase();
    final lowerName = name.toLowerCase();

    if (contentType == 'movie') {
      if (lowerGroup.contains('accion') || lowerName.contains('accion')) return 'Acción';
      if (lowerGroup.contains('terror') || lowerGroup.contains('horror')) return 'Terror';
      if (lowerGroup.contains('comedia') || lowerName.contains('comedia')) return 'Comedia';
      if (lowerGroup.contains('animacion') || lowerName.contains('infantil')) return 'Animación';
      if (lowerGroup.contains('ciencia') || lowerName.contains('ficcion')) return 'Ciencia Ficción';
      return rawGroup.isNotEmpty && rawGroup != 'General' ? rawGroup : 'Películas';
    }

    if (contentType == 'series') {
      return rawGroup.isNotEmpty && rawGroup != 'General' ? rawGroup : 'Series';
    }

    // Categorías de Canales en Vivo
    if (lowerGroup.contains('deport') || lowerGroup.contains('sport') || lowerGroup.contains('futbol')) return 'Deportes';
    if (lowerGroup.contains('noticia') || lowerGroup.contains('news')) return 'Noticias';
    if (lowerGroup.contains('cine') || lowerGroup.contains('movie') || lowerGroup.contains('film')) return 'Cine & Series 24/7';
    if (lowerGroup.contains('docu') || lowerGroup.contains('cultura')) return 'Documentales';
    if (lowerGroup.contains('infantil') || lowerGroup.contains('kid')) return 'Infantil';
    if (lowerGroup.contains('music')) return 'Música';

    return rawGroup.isNotEmpty && rawGroup != 'General' ? rawGroup : 'Entretenimiento';
  }

  static String _detectResolution(String name, String url) {
    final combined = '$name $url'.toLowerCase();
    if (combined.contains('4k') || combined.contains('uhd')) return '4K UHD';
    if (combined.contains('720') || combined.contains('hd')) return '720p HD';
    return '1080p FHD';
  }

  static List<ChannelModel> getCuratedChannels() {
    return [
      ChannelModel(
        id: 'live_1',
        number: 1,
        name: 'ESPN Deportes en Vivo',
        streamUrl: 'https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8',
        logoUrl: '',
        groupCategory: 'Deportes',
        resolution: '1080p FHD',
        contentType: 'live',
        isFavorite: true,
      ),
      ChannelModel(
        id: 'live_2',
        number: 2,
        name: 'Noticias 24 Horas',
        streamUrl: 'https://rtvelivestream.akamaized.net/rtvesec/24h/24h_main.m3u8',
        logoUrl: '',
        groupCategory: 'Noticias',
        resolution: '1080p FHD',
        contentType: 'live',
      ),
      ChannelModel(
        id: 'mov_1',
        number: 101,
        name: 'Big Buck Bunny (Animación 4K)',
        streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/c/c5/Big_buck_bunny_poster_big.jpg',
        groupCategory: 'Animación',
        resolution: '4K UHD',
        contentType: 'movie',
        year: '2023',
        rating: '8.8',
      ),
      ChannelModel(
        id: 'mov_2',
        number: 102,
        name: 'Tears of Steel (Ciencia Ficción)',
        streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/TearsOfSteel.mp4',
        logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/e/e0/Tears_of_Steel_poster.jpg/400px-Tears_of_Steel_poster.jpg',
        groupCategory: 'Ciencia Ficción',
        resolution: '1080p FHD',
        contentType: 'movie',
        year: '2024',
        rating: '9.1',
      ),
      ChannelModel(
        id: 'mov_3',
        number: 103,
        name: 'Sylvanian Families: El Regalo de Freya',
        streamUrl: 'https://ia902200.us.archive.org/26/items/Peliculas-wii/Sylvanian%20Families%20La%20Pelicula%20-%20El%20regalo%20de%20Freya.mp4',
        logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/c/c5/Big_buck_bunny_poster_big.jpg',
        groupCategory: 'Animación',
        resolution: '1080p FHD',
        contentType: 'movie',
        year: '2023',
        rating: '8.9',
      ),
      ChannelModel(
        id: 'ser_1',
        number: 201,
        name: 'Sintel: Crónicas del Dragón S01 E01',
        streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4',
        logoUrl: 'https://upload.wikimedia.org/wikipedia/commons/thumb/8/8f/Sintel_poster.jpg/400px-Sintel_poster.jpg',
        groupCategory: 'Aventura',
        resolution: '1080p FHD',
        contentType: 'series',
        year: '2024',
        rating: '9.0',
      ),
    ];
  }
}