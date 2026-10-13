import 'dart:convert';
import '../models/channel_model.dart';

class M3USanitizerService {
  /// Limpia, categoriza y clasifica automáticamente en TV, Películas y Series
  static List<ChannelModel> parseAndSanitize(String rawM3u) {
    final List<ChannelModel> sanitizedChannels = [];
    final cleanContent = rawM3u.replaceAll('\uFEFF', '').replaceAll('\r\n', '\n');
    final lines = const LineSplitter().convert(cleanContent);

    String tempName = 'Canal sin nombre';
    String tempLogo = '';
    String tempGroup = 'General';
    int channelCounter = 1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.toUpperCase().startsWith('#EXTINF:')) {
        // 1. Extraer nombre tras la coma
        final commaIndex = line.lastIndexOf(',');
        if (commaIndex != -1 && commaIndex < line.length - 1) {
          tempName = line.substring(commaIndex + 1).trim();
        }

        // 2. Extraer Logo
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"', caseSensitive: false).firstMatch(line);
        tempLogo = logoMatch?.group(1)?.trim() ?? '';

        // 3. Extraer Grupo
        final groupMatch = RegExp(r'group-title="([^"]*)"', caseSensitive: false).firstMatch(line);
        tempGroup = groupMatch?.group(1)?.trim() ?? 'General';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        // Sanitizar URL
        String cleanUrl = line.replaceAll(RegExp(r'\s+'), '');

        if (cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://')) {
          final contentType = _determineContentType(tempName, tempGroup, cleanUrl);
          final cleanTitle = _cleanChannelTitle(tempName);
          final category = _determineCategory(cleanTitle, tempGroup, contentType);
          final year = _extractYear(tempName);

          sanitizedChannels.add(
            ChannelModel(
              id: 'item_$channelCounter',
              number: channelCounter,
              name: cleanTitle.isEmpty ? 'Elemento $channelCounter' : cleanTitle,
              streamUrl: cleanUrl,
              logoUrl: tempLogo,
              groupCategory: category,
              resolution: _detectResolution(tempName, cleanUrl),
              contentType: contentType,
              year: year,
              rating: contentType == 'live' ? 'HD' : '8.5',
              isValid: true,
            ),
          );
          channelCounter++;
        }
      }
    }

    return sanitizedChannels.isNotEmpty ? sanitizedChannels : getCuratedChannels();
  }

  /// CLASIFICADOR INTELIGENTE DE CONTENIDO
  static String _determineContentType(String name, String group, String url) {
    final lowerName = name.toLowerCase();
    final lowerGroup = group.toLowerCase();
    final lowerUrl = url.toLowerCase();

    // 1. Es Serie si tiene formato de temporada/capítulo o el grupo lo dice
    final isSeriesPattern = RegExp(r'[st]\d+.*[ec]\d+', caseSensitive: false).hasMatch(name) ||
        lowerName.contains('temporada') ||
        lowerName.contains('season') ||
        lowerName.contains('capitulo') ||
        lowerName.contains('episodio');

    if (isSeriesPattern || lowerGroup.contains('serie') || lowerGroup.contains('series')) {
      return 'series';
    }

    // 2. Es Película si el archivo es VOD (.mp4, .mkv) o el grupo/nombre es de cine
    final isVideoFile = lowerUrl.endsWith('.mp4') || lowerUrl.endsWith('.mkv') || lowerUrl.endsWith('.avi');
    final isMovieGroup = lowerGroup.contains('pelicula') ||
        lowerGroup.contains('película') ||
        lowerGroup.contains('movie') ||
        lowerGroup.contains('vod') ||
        lowerGroup.contains('cine') ||
        lowerGroup.contains('estreno');

    if (isVideoFile || isMovieGroup) {
      return 'movie';
    }

    // 3. Por defecto es Canal en Vivo (TV streaming HLS/TS)
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
      if (lowerGroup.contains('animacion') || lowerGroup.contains('infantil')) return 'Animación';
      if (lowerGroup.contains('ciencia') || lowerGroup.contains('ficcion')) return 'Ciencia Ficción';
      return rawGroup.isNotEmpty && rawGroup != 'General' ? rawGroup : 'Cine Estelar';
    }

    if (contentType == 'series') {
      return rawGroup.isNotEmpty && rawGroup != 'General' ? rawGroup : 'Series Populares';
    }

    // Categorías de TV en Vivo
    if (lowerGroup.contains('deport') || lowerGroup.contains('sport') || lowerGroup.contains('futbol')) return 'Deportes';
    if (lowerGroup.contains('noticia') || lowerGroup.contains('news')) return 'Noticias';
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

  /// Canales y Películas de prueba estables y legales
  static List<ChannelModel> getCuratedChannels() {
    return [
      // Canales de TV
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
      // Películas (VOD)
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
      // Series
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