import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PlaybackHistoryItem {
  final String id;
  final String title;
  final String streamUrl;
  final String logoUrl;
  final int positionSeconds;
  final int totalDurationSeconds;
  final String category;
  final DateTime lastWatched;

  PlaybackHistoryItem({
    required this.id,
    required this.title,
    required this.streamUrl,
    required this.logoUrl,
    required this.positionSeconds,
    required this.totalDurationSeconds,
    required this.category,
    required this.lastWatched,
  });

  double get progressPercentage {
    if (totalDurationSeconds <= 0) return 0.0;
    final p = positionSeconds / totalDurationSeconds;
    return p.clamp(0.0, 1.0);
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'streamUrl': streamUrl,
    'logoUrl': logoUrl,
    'positionSeconds': positionSeconds,
    'totalDurationSeconds': totalDurationSeconds,
    'category': category,
    'lastWatched': lastWatched.toIso8601String(),
  };

  factory PlaybackHistoryItem.fromMap(Map<String, dynamic> map) => PlaybackHistoryItem(
    id: map['id'] ?? '',
    title: map['title'] ?? '',
    streamUrl: map['streamUrl'] ?? '',
    logoUrl: map['logoUrl'] ?? '',
    positionSeconds: map['positionSeconds'] ?? 0,
    totalDurationSeconds: map['totalDurationSeconds'] ?? 0,
    category: map['category'] ?? '',
    lastWatched: DateTime.tryParse(map['lastWatched'] ?? '') ?? DateTime.now(),
  );
}

class PlaybackHistoryService {
  static const String _baseKey = 'playback_history_';

  static Future<void> saveProgress({
    required String profileId,
    required String itemId,
    required String title,
    required String streamUrl,
    required String logoUrl,
    required int positionSeconds,
    required int totalDurationSeconds,
    required String category,
  }) async {
    // Si vio menos de 30 segundos o más del 95%, no saturamos el carrusel
    if (positionSeconds < 30) return;
    if (totalDurationSeconds > 0 && (positionSeconds / totalDurationSeconds) > 0.95) {
      await removeProgress(profileId, itemId);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final key = '$_baseKey$profileId';
    final history = await getHistory(profileId);

    history.removeWhere((item) => item.id == itemId || item.streamUrl == streamUrl);

    history.insert(
      0,
      PlaybackHistoryItem(
        id: itemId,
        title: title,
        streamUrl: streamUrl,
        logoUrl: logoUrl,
        positionSeconds: positionSeconds,
        totalDurationSeconds: totalDurationSeconds,
        category: category,
        lastWatched: DateTime.now(),
      ),
    );

    // Mantener solo los últimos 15 elementos
    final limited = history.take(15).toList();
    final encoded = jsonEncode(limited.map((e) => e.toMap()).toList());
    await prefs.setString(key, encoded);
  }

  static Future<List<PlaybackHistoryItem>> getHistory(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_baseKey$profileId');
    if (raw == null || raw.isEmpty) return [];
    try {
      final List list = jsonDecode(raw);
      return list.map((m) => PlaybackHistoryItem.fromMap(m)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> removeProgress(String profileId, String itemId) async {
    final prefs = await SharedPreferences.getInstance();
    final key = '$_baseKey$profileId';
    final history = await getHistory(profileId);
    history.removeWhere((item) => item.id == itemId);
    final encoded = jsonEncode(history.map((e) => e.toMap()).toList());
    await prefs.setString(key, encoded);
  }
}
