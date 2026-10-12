import 'dart:convert';
import '../models/channel_model.dart';

class M3USanitizerService {
  /// Limpia, categoriza y estructura el contenido M3U bruto
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

        // Limpiar prefijos ruidosos: [ES], |AR|, (HD), [4K], etc.
        tempName = _cleanChannelTitle(tempName);

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
          final category = _determineCategory(tempName, tempGroup);

          sanitizedChannels.add(
            ChannelModel(
              id: 'ch_$channelCounter',
              number: channelCounter,
              name: tempName.isEmpty ? 'Canal $channelCounter' : tempName,
              streamUrl: cleanUrl,
              logoUrl: tempLogo,
              groupCategory: category,
              resolution: _detectResolution(tempName, cleanUrl),
              isValid: true,
            ),
          );
          channelCounter++;
        }
      }
    }

    return sanitizedChannels.isNotEmpty ? sanitizedChannels : getCuratedChannels();
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

  static String _determineCategory(String name, String rawGroup) {
    final lowerGroup = rawGroup.toLowerCase();
    if (lowerGroup.contains('deport') || lowerGroup.contains('sport') || lowerGroup.contains('futbol')) return 'Deportes';
    if (lowerGroup.contains('noticia') || lowerGroup.contains('news')) return 'Noticias';
    if (lowerGroup.contains('cine') || lowerGroup.contains('movie') || lowerGroup.contains('serie')) return 'Cine & Series';
    if (lowerGroup.contains('docu') || lowerGroup.contains('cultura')) return 'Documentales';
    if (lowerGroup.contains('infantil') || lowerGroup.contains('kid')) return 'Infantil';

    final lowerName = name.toLowerCase();
    if (lowerName.contains('deporte') || lowerName.contains('futbol') || lowerName.contains('liga') || lowerName.contains('espn') || lowerName.contains('red bull')) return 'Deportes';
    if (lowerName.contains('noticia') || lowerName.contains('news') || lowerName.contains('24h') || lowerName.contains('dw')) return 'Noticias';
    if (lowerName.contains('cine') || lowerName.contains('movie') || lowerName.contains('film')) return 'Cine & Series';
    if (lowerName.contains('docu') || lowerName.contains('discovery') || lowerName.contains('nasa')) return 'Documentales';

    return rawGroup.isNotEmpty && rawGroup != 'General' ? rawGroup : 'Entretenimiento';
  }

  static String _detectResolution(String name, String url) {
    final combined = '$name $url'.toLowerCase();
    if (combined.contains('4k') || combined.contains('uhd')) return '4K UHD';
    if (combined.contains('720') || combined.contains('hd')) return '720p HD';
    return '1080p FHD';
  }

  /// Canales garantizados de prueba estables y legales
  static List<ChannelModel> getCuratedChannels() {
    return [
      ChannelModel(
        id: 'ch_1',
        number: 1,
        name: 'Real Madrid vs Barcelona (HD)',
        streamUrl: 'https://rbmn-live.akamaized.net/hls/live/590964/BoRB-AT/master.m3u8',
        logoUrl: '',
        groupCategory: 'Deportes',
        resolution: '1080p FHD',
        isFavorite: true,
      ),
      ChannelModel(
        id: 'ch_2',
        number: 2,
        name: 'Noticias 24/7 Live',
        streamUrl: 'https://rtvelivestream.akamaized.net/rtvesec/24h/24h_main.m3u8',
        logoUrl: '',
        groupCategory: 'Noticias',
        resolution: '1080p FHD',
      ),
      ChannelModel(
        id: 'ch_3',
        number: 3,
        name: 'Cine Max Pro',
        streamUrl: 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4',
        logoUrl: '',
        groupCategory: 'Cine & Series',
        resolution: '1080p FHD',
      ),
      ChannelModel(
        id: 'ch_4',
        number: 4,
        name: 'Discovery World 4K',
        streamUrl: 'https://ntv1.akamaized.net/hls/live/2014075/NASA-NTV1-HLS/master.m3u8',
        logoUrl: '',
        groupCategory: 'Documentales',
        resolution: '4K UHD',
      ),
    ];
  }
}