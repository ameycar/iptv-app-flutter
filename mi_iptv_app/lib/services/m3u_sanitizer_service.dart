import 'dart:convert';
import '../models/channel_model.dart';

class M3USanitizerService {
  /// Limpia y estructura el contenido M3U bruto
  static List<ChannelModel> parseAndSanitize(String rawM3u) {
    final List<ChannelModel> sanitizedChannels = [];
    final lines = const LineSplitter().convert(rawM3u);

    String tempName = 'Canal sin nombre';
    String tempLogo = '';
    String tempGroup = 'General';
    int channelCounter = 1;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('#EXTINF:')) {
        // Sanitizar título
        final commaIndex = line.lastIndexOf(',');
        if (commaIndex != -1) {
          tempName = line.substring(commaIndex + 1).trim();
        }

        // Extraer Logo si existe
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
        tempLogo = logoMatch?.group(1) ?? '';

        // Extraer Grupo/Categoría
        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
        tempGroup = groupMatch?.group(1) ?? 'General';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        // Sanitizar URL: eliminar espacios, tabulaciones y saltos no válidos
        String cleanUrl = line.replaceAll(RegExp(r'\s+'), '');

        if (cleanUrl.startsWith('http://') || cleanUrl.startsWith('https://')) {
          sanitizedChannels.add(
            ChannelModel(
              id: 'ch_$channelCounter',
              name: tempName.isEmpty ? 'Canal $channelCounter' : tempName,
              streamUrl: cleanUrl,
              logoUrl: tempLogo,
              groupCategory: tempGroup,
              isValid: true,
            ),
          );
          channelCounter++;
        }
      }
    }

    return sanitizedChannels;
  }
}
