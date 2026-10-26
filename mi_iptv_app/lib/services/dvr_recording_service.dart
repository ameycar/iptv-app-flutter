import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

class DvrRecordingItem {
  final String id;
  final String alarmId;
  final String channelName;
  final String programTitle;
  final String filePath;
  final DateTime createdAt;
  final int durationSeconds;
  final int sizeBytes;
  final bool isCompleted;

  const DvrRecordingItem({
    required this.id,
    this.alarmId = '',
    required this.channelName,
    required this.programTitle,
    required this.filePath,
    required this.createdAt,
    required this.durationSeconds,
    required this.sizeBytes,
    this.isCompleted = true,
  });

  double get sizeMb => sizeBytes / (1024 * 1024);

  String get formattedDuration {
    final mins = (durationSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (durationSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'alarmId': alarmId,
        'channelName': channelName,
        'programTitle': programTitle,
        'filePath': filePath,
        'createdAt': createdAt.toIso8601String(),
        'durationSeconds': durationSeconds,
        'sizeBytes': sizeBytes,
        'isCompleted': isCompleted,
      };

  factory DvrRecordingItem.fromJson(Map<String, dynamic> json) =>
      DvrRecordingItem(
        id: (json['id'] ?? '').toString(),
        alarmId: (json['alarmId'] ?? '').toString(),
        channelName: (json['channelName'] ?? 'Canal').toString(),
        programTitle: (json['programTitle'] ?? 'Grabación DVR').toString(),
        filePath: (json['filePath'] ?? '').toString(),
        createdAt: DateTime.tryParse((json['createdAt'] ?? '').toString()) ??
            DateTime.now(),
        durationSeconds: (json['durationSeconds'] as int?) ?? 0,
        sizeBytes: (json['sizeBytes'] as int?) ?? 0,
        isCompleted: (json['isCompleted'] as bool?) ?? true,
      );
}

class ScheduledDvrTask {
  final String alarmId;
  final String channelName;
  final String programTitle;
  final String streamUrl;
  final DateTime startTime;
  final int maxMinutes;
  bool triggered;

  ScheduledDvrTask({
    required this.alarmId,
    required this.channelName,
    required this.programTitle,
    required this.streamUrl,
    required this.startTime,
    this.maxMinutes = 60,
    this.triggered = false,
  });

  Map<String, dynamic> toJson() => {
        'alarmId': alarmId,
        'channelName': channelName,
        'programTitle': programTitle,
        'streamUrl': streamUrl,
        'startTime': startTime.toIso8601String(),
        'maxMinutes': maxMinutes,
        'triggered': triggered,
      };

  factory ScheduledDvrTask.fromJson(Map<String, dynamic> json) =>
      ScheduledDvrTask(
        alarmId: (json['alarmId'] ?? '').toString(),
        channelName: (json['channelName'] ?? '').toString(),
        programTitle: (json['programTitle'] ?? '').toString(),
        streamUrl: (json['streamUrl'] ?? '').toString(),
        startTime: DateTime.tryParse((json['startTime'] ?? '').toString()) ??
            DateTime.now(),
        maxMinutes: (json['maxMinutes'] as int?) ?? 60,
        triggered: (json['triggered'] as bool?) ?? false,
      );
}

class DvrRecordingService {
  static const String _prefsRecordingsKey = 'ameycar_dvr_recordings_v2';
  static const String _prefsScheduledTasksKey = 'ameycar_dvr_scheduled_v2';

  static final ValueNotifier<bool> isRecordingNotifier =
      ValueNotifier<bool>(false);
  static final ValueNotifier<int> recordingElapsedSeconds =
      ValueNotifier<int>(0);
  static final ValueNotifier<String> activeRecordingChannel =
      ValueNotifier<String>('');
  static final ValueNotifier<int> recordingsCountNotifier =
      ValueNotifier<int>(0);

  static List<DvrRecordingItem> _recordings = [];
  static List<ScheduledDvrTask> _scheduledTasks = [];

  static Timer? _watchdogTimer;
  static Timer? _elapsedTimer;
  static bool _abortRequested = false;
  static http.Client? _activeHttpClient;
  static IOSink? _activeFileSink;
  static File? _activeOutputFile;
  static DateTime? _recordingStartedAt;
  static String _currentChannelName = '';
  static String _currentProgramTitle = '';
  static String _currentAlarmId = '';

  static List<DvrRecordingItem> get recordings =>
      List.unmodifiable(_recordings);

  static File? get activeRecordingFile => _activeOutputFile;
  static String get activeAlarmId => _currentAlarmId;

  static bool isAlarmSetToAutoRecord(String alarmId) {
    return _scheduledTasks.any((t) => t.alarmId == alarmId && !t.triggered);
  }

  static DvrRecordingItem? findRecordingByChannelOrAlarm({
    String? alarmId,
    String? channelName,
  }) {
    if (alarmId != null && alarmId.isNotEmpty) {
      for (final r in _recordings) {
        if (r.alarmId == alarmId && File(r.filePath).existsSync()) {
          return r;
        }
      }
    }
    if (channelName != null && channelName.isNotEmpty) {
      final lower = channelName.toLowerCase();
      final recentCutoff = DateTime.now().subtract(const Duration(hours: 3));
      for (final r in _recordings) {
        if (r.channelName.toLowerCase() == lower &&
            r.createdAt.isAfter(recentCutoff) &&
            File(r.filePath).existsSync()) {
          return r;
        }
      }
    }
    return null;
  }

  static Future<Directory> _resolveStorageDirectory() async {
    // En Android, parent de systemTemp apunta al directorio privado persistente de la app (/data/user/0/<pkg>/)
    try {
      final baseParent = Directory.systemTemp.parent;
      final persistentDir = Directory('${baseParent.path}/app_flutter/ameycar_dvr');
      await persistentDir.create(recursive: true);
      return persistentDir;
    } catch (_) {
      final fallbackDir = Directory('${Directory.systemTemp.path}/ameycar_dvr');
      await fallbackDir.create(recursive: true);
      return fallbackDir;
    }
  }

  static Future<void> initialize() async {
    await _loadSavedState();
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer.periodic(const Duration(seconds: 15), (_) {
      _checkScheduledAutoRecordings();
    });
  }

  static Future<void> _loadSavedState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final rawRecs = prefs.getString(_prefsRecordingsKey);
      if (rawRecs != null && rawRecs.isNotEmpty) {
        final List list = jsonDecode(rawRecs);
        _recordings = list
            .map((e) => DvrRecordingItem.fromJson(Map<String, dynamic>.from(e)))
            .where((item) => File(item.filePath).existsSync())
            .toList();
        recordingsCountNotifier.value = _recordings.length;
      }

      final rawTasks = prefs.getString(_prefsScheduledTasksKey);
      if (rawTasks != null && rawTasks.isNotEmpty) {
        final List list = jsonDecode(rawTasks);
        final now = DateTime.now();
        _scheduledTasks = list
            .map((e) => ScheduledDvrTask.fromJson(Map<String, dynamic>.from(e)))
            .where((t) =>
                t.startTime.isAfter(now.subtract(const Duration(minutes: 45))))
            .toList();
      }
    } catch (e) {
      debugPrint('Aviso cargando estado DVR: $e');
    }
  }

  static Future<void> _persistState() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsRecordingsKey,
        jsonEncode(_recordings.map((e) => e.toJson()).toList()),
      );
      await prefs.setString(
        _prefsScheduledTasksKey,
        jsonEncode(_scheduledTasks.map((e) => e.toJson()).toList()),
      );
      recordingsCountNotifier.value = _recordings.length;
    } catch (_) {}
  }

  static Future<void> scheduleAutoRecording({
    required String alarmId,
    required String channelName,
    required String programTitle,
    required String streamUrl,
    required DateTime startTime,
    int maxMinutes = 60,
  }) async {
    _scheduledTasks.removeWhere((t) => t.alarmId == alarmId);
    _scheduledTasks.add(
      ScheduledDvrTask(
        alarmId: alarmId,
        channelName: channelName,
        programTitle: programTitle,
        streamUrl: streamUrl,
        startTime: startTime,
        maxMinutes: maxMinutes,
      ),
    );
    await _persistState();
  }

  static Future<void> cancelScheduledAutoRecording(String alarmId) async {
    _scheduledTasks.removeWhere((t) => t.alarmId == alarmId);
    await _persistState();
  }

  static void _checkScheduledAutoRecordings() {
    if (isRecordingNotifier.value) return;
    final now = DateTime.now();

    for (final task in _scheduledTasks) {
      if (task.triggered) continue;
      final diffSeconds = now.difference(task.startTime).inSeconds;
      // Inicia desde 20 segundos antes de la hora exacta hasta 25 minutos después
      if (diffSeconds >= -20 && diffSeconds <= 1500) {
        task.triggered = true;
        unawaited(_persistState());
        unawaited(
          startRecording(
            channelName: task.channelName,
            programTitle: task.programTitle,
            streamUrl: task.streamUrl,
            alarmId: task.alarmId,
            maxMinutes: task.maxMinutes,
          ),
        );
        break;
      }
    }
  }

  static String formatElapsed(int totalSeconds) {
    final mins = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    final secs = (totalSeconds % 60).toString().padLeft(2, '0');
    return '$mins:$secs';
  }

  static Future<bool> startRecording({
    required String channelName,
    required String programTitle,
    required String streamUrl,
    String alarmId = '',
    int maxMinutes = 60,
  }) async {
    if (isRecordingNotifier.value) return false;
    final cleanUrl = streamUrl.trim();
    if (cleanUrl.isEmpty) return false;

    try {
      final dvrDir = await _resolveStorageDirectory();
      final id = 'rec_${DateTime.now().millisecondsSinceEpoch}';
      final filePath = '${dvrDir.path}/$id.ts';
      final file = File(filePath);
      final sink = file.openWrite();

      _abortRequested = false;
      _activeOutputFile = file;
      _activeFileSink = sink;
      _recordingStartedAt = DateTime.now();
      _currentChannelName = channelName;
      _currentProgramTitle = programTitle;
      _currentAlarmId = alarmId;

      activeRecordingChannel.value = channelName;
      recordingElapsedSeconds.value = 0;
      isRecordingNotifier.value = true;

      _elapsedTimer?.cancel();
      _elapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_recordingStartedAt != null) {
          final elapsed =
              DateTime.now().difference(_recordingStartedAt!).inSeconds;
          recordingElapsedSeconds.value = elapsed;
          if (elapsed >= maxMinutes * 60) {
            stopRecording();
          }
        }
      });

      if (cleanUrl.toLowerCase().contains('.m3u8')) {
        unawaited(_recordHlsStreamLoop(cleanUrl, sink));
      } else {
        unawaited(_recordDirectTsStream(cleanUrl, sink));
      }

      return true;
    } catch (e) {
      debugPrint('Error iniciando grabación DVR: $e');
      await _cleanupActiveRecording(saveFile: false);
      return false;
    }
  }

  static Future<void> _recordHlsStreamLoop(String masterUrl, IOSink sink) async {
    final client = http.Client();
    _activeHttpClient = client;
    final Set<String> downloadedSegments = {};
    String targetPlaylistUrl = masterUrl;

    const headers = {
      'User-Agent': 'AmeycarTV/2.0 (Linux; Android 13) ExoPlayerLib/2.19.1',
      'Connection': 'keep-alive',
    };

    try {
      while (!_abortRequested) {
        final res = await client
            .get(Uri.parse(targetPlaylistUrl), headers: headers)
            .timeout(const Duration(seconds: 8));

        if (res.statusCode != 200 || _abortRequested) break;

        final body = res.body;
        final baseUri = Uri.parse(targetPlaylistUrl);
        final lines = body
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();

        // Si es Master Playlist con sub-variantes .m3u8, resolvemos la variante activa
        final subPlaylistLine = lines.firstWhere(
          (l) => !l.startsWith('#') && l.contains('.m3u8'),
          orElse: () => '',
        );

        if (subPlaylistLine.isNotEmpty) {
          targetPlaylistUrl = baseUri.resolve(subPlaylistLine).toString();
          continue;
        }

        final segmentLines = lines.where((l) => !l.startsWith('#')).toList();

        final toProcess = downloadedSegments.isEmpty && segmentLines.length > 4
            ? segmentLines.sublist(segmentLines.length - 4)
            : segmentLines;

        for (final seg in toProcess) {
          if (_abortRequested) break;
          final segUrl = baseUri.resolve(seg).toString();
          if (downloadedSegments.contains(segUrl)) continue;

          downloadedSegments.add(segUrl);
          if (downloadedSegments.length > 300) {
            downloadedSegments.remove(downloadedSegments.first);
          }

          try {
            final segRes = await client
                .get(Uri.parse(segUrl), headers: headers)
                .timeout(const Duration(seconds: 8));
            if (segRes.statusCode == 200 && segRes.bodyBytes.isNotEmpty) {
              sink.add(segRes.bodyBytes);
            }
          } catch (_) {}
        }

        await Future.delayed(const Duration(seconds: 3));
      }
    } catch (e) {
      debugPrint('Aviso cierre bucle HLS DVR: $e');
    } finally {
      if (isRecordingNotifier.value) {
        await stopRecording();
      }
    }
  }

  static Future<void> _recordDirectTsStream(String url, IOSink sink) async {
    final client = http.Client();
    _activeHttpClient = client;
    try {
      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll({
        'User-Agent': 'AmeycarTV/2.0 (Linux; Android 13) ExoPlayerLib/2.19.1',
      });
      final streamed =
          await client.send(req).timeout(const Duration(seconds: 10));
      await for (final chunk in streamed.stream) {
        if (_abortRequested) break;
        sink.add(chunk);
      }
    } catch (e) {
      debugPrint('Aviso stream directo DVR: $e');
    } finally {
      if (isRecordingNotifier.value) {
        await stopRecording();
      }
    }
  }

  static Future<DvrRecordingItem?> stopRecording() async {
    if (!isRecordingNotifier.value) return null;
    _abortRequested = true;
    return await _cleanupActiveRecording(saveFile: true);
  }

  static Future<DvrRecordingItem?> _cleanupActiveRecording({
    required bool saveFile,
  }) async {
    _elapsedTimer?.cancel();
    _elapsedTimer = null;

    try {
      _activeHttpClient?.close();
    } catch (_) {}
    _activeHttpClient = null;

    try {
      await _activeFileSink?.flush();
      await _activeFileSink?.close();
    } catch (_) {}
    _activeFileSink = null;

    final file = _activeOutputFile;
    _activeOutputFile = null;

    final started = _recordingStartedAt ?? DateTime.now();
    final elapsed = DateTime.now().difference(started).inSeconds;
    final savedChannel = _currentChannelName;
    final savedProgram = _currentProgramTitle;
    final savedAlarmId = _currentAlarmId;

    isRecordingNotifier.value = false;
    activeRecordingChannel.value = '';
    recordingElapsedSeconds.value = 0;
    _currentAlarmId = '';

    if (saveFile && file != null && file.existsSync()) {
      final bytes = file.lengthSync();
      if (bytes > 128 * 1024) {
        final item = DvrRecordingItem(
          id: 'rec_${started.millisecondsSinceEpoch}',
          alarmId: savedAlarmId,
          channelName: savedChannel,
          programTitle: savedProgram,
          filePath: file.path,
          createdAt: started,
          durationSeconds: elapsed > 0 ? elapsed : 1,
          sizeBytes: bytes,
        );
        _recordings.insert(0, item);
        await _persistState();
        return item;
      } else {
        try {
          file.deleteSync();
        } catch (_) {}
      }
    }
    return null;
  }

  static Future<void> deleteRecording(String id) async {
    final idx = _recordings.indexWhere((r) => r.id == id);
    if (idx != -1) {
      final item = _recordings.removeAt(idx);
      try {
        final f = File(item.filePath);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
      await _persistState();
    }
  }
}