import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/playlist_item.dart';
import 'ai_curator_service.dart';

class M3UParserService {
  static Future<List<PlaylistItem>> fetchAndParseM3U(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Error al descargar la lista M3U');
    }

    final lines = LineSplitter.split(response.body).toList();
    List<PlaylistItem> items = [];

    String currentName = '';
    String currentLogo = '';
    String currentCategory = '';

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('#EXTINF:')) {
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"').firstMatch(line);
        currentLogo = logoMatch?.group(1) ?? '';

        final groupMatch = RegExp(r'group-title="([^"]*)"').firstMatch(line);
        currentCategory = groupMatch?.group(1) ?? '';

        final parts = line.split(',');
        currentName = parts.length > 1 ? parts.sublist(1).join(',') : 'Canal';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final cleanName = AICuratorService.cleanChannelName(currentName);
        final cleanCat = AICuratorService.normalizeCategory(currentCategory, cleanName);

        items.add(
          PlaylistItem(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: cleanName,
            originalName: currentName,
            url: line,
            logoUrl: currentLogo.isNotEmpty ? currentLogo : null,
            category: cleanCat,
          ),
        );

        currentName = '';
        currentLogo = '';
        currentCategory = '';
      }
    }

    return items;
  }
}
