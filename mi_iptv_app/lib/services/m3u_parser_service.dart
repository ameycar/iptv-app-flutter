import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/playlist_item.dart';
import 'ai_curator_service.dart';
import 'epg_service.dart';

class M3UParserService {
  static Future<List<PlaylistItem>> fetchAndParseM3U(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Error al descargar la lista M3U');
    }

    // Inicializa en segundo plano los conectores EPG en vivo (Deportes + XMLTV)
    EpgService.ensureInitialized();

    final lines = LineSplitter.split(response.body).toList();
    List<PlaylistItem> items = [];

    String currentName = '';
    String currentLogo = '';
    String currentCategory = '';
    String currentTvgId = '';
    String currentTvgName = '';

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();

      if (line.startsWith('#EXTM3U')) {
        // Si la lista M3U trae una URL de guía XMLTV en la cabecera, la carga en segundo plano
        final xmlUrlMatch = RegExp(
          r'(?:x-tvg-url|url-tvg)="([^"]+)"',
          caseSensitive: false,
        ).firstMatch(line);
        if (xmlUrlMatch != null) {
          final rawUrls = xmlUrlMatch.group(1) ?? '';
          for (final xmlUrl in rawUrls.split(',')) {
            if (xmlUrl.trim().isNotEmpty) {
              EpgService.loadXmlTvFromUrl(xmlUrl.trim());
            }
          }
        }
      } else if (line.startsWith('#EXTINF:')) {
        final logoMatch = RegExp(r'tvg-logo="([^"]*)"', caseSensitive: false).firstMatch(line);
        currentLogo = logoMatch?.group(1) ?? '';

        final groupMatch = RegExp(r'group-title="([^"]*)"', caseSensitive: false).firstMatch(line);
        currentCategory = groupMatch?.group(1) ?? '';

        final idMatch = RegExp(r'tvg-id="([^"]*)"', caseSensitive: false).firstMatch(line);
        currentTvgId = idMatch?.group(1) ?? '';

        final tvgNameMatch = RegExp(r'tvg-name="([^"]*)"', caseSensitive: false).firstMatch(line);
        currentTvgName = tvgNameMatch?.group(1) ?? '';

        final parts = line.split(',');
        currentName = parts.length > 1 ? parts.sublist(1).join(',').trim() : 'Canal';
      } else if (line.isNotEmpty && !line.startsWith('#')) {
        final cleanName = AICuratorService.cleanChannelName(currentName);
        final cleanCat = AICuratorService.normalizeCategory(currentCategory, cleanName);

        // Registra el tvg-id oficial y el nombre original en el Normalizador Canónico de Doble Llave
        EpgService.registerChannelMetadata(
          cleanName: cleanName,
          originalName: currentName,
          tvgId: currentTvgId,
          tvgName: currentTvgName,
          category: cleanCat,
        );

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
        currentTvgId = '';
        currentTvgName = '';
      }
    }

    return items;
  }
}