import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import 'models/channel_model.dart';
import 'services/m3u_sanitizer_service.dart';
import 'services/epg_service.dart';
import 'widgets/alexa_voice_sheet.dart';
import 'widgets/vod_grid_view.dart';
import 'widgets/zapping_channel_overlay.dart';

// SERVICIO NATIVO PARA ALARMAS Y RECORDATORIOS CON LA APP CERRADA
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    try {
      tz.initializeTimeZones();
    } catch (e) {
      debugPrint('Error inicializando timezones: $e');
    }

    const AndroidInitializationSettings androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initSettings =
        InitializationSettings(android: androidSettings);

    try {
      await _notificationsPlugin.initialize(initSettings);
    } catch (e) {
      debugPrint('Error inicializando FlutterLocalNotifications: $e');
    }
  }

  // Solicitud segura de permisos una vez que la pantalla ya está activa
  static Future<void> requestPermissionsSafely() async {
    try {
      final androidImpl = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        await androidImpl.requestNotificationsPermission();
        await androidImpl.requestExactAlarmsPermission();
      }
    } catch (e) {
      debugPrint('Error solicitando permisos de notificación: $e');
    }
  }

  static Future<void> scheduleAlarm({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    try {
      final difference = scheduledDate.difference(DateTime.now());
      final tz.TZDateTime tzScheduledDate =
          tz.TZDateTime.now(tz.local).add(difference);

      const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
        'epg_alarms_channel',
        'Alarmas de Programación TV',
        channelDescription: 'Avisos de inicio de programas en AmeycarTV',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
        enableVibration: true,
        fullScreenIntent: true,
        icon: '@mipmap/ic_launcher',
      );

      const NotificationDetails details =
          NotificationDetails(android: androidDetails);

      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        tzScheduledDate,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
      );
    } catch (e) {
      debugPrint('Error programando alarma local: $e');
    }
  }

  static Future<void> cancelAlarm(int id) async {
    try {
      await _notificationsPlugin.cancel(id);
    } catch (e) {
      debugPrint('Error cancelando alarma: $e');
    }
  }
}

void main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    try {
      await NotificationService.initialize();
    } catch (e) {
      debugPrint('Error seguro en NotificationService: $e');
    }
    runApp(const AmeycarTVApp());
  }, (error, stack) {
    debugPrint('Excepción capturada en arranque: $error');
  });
}

class AmeycarTVApp extends StatelessWidget {
  const AmeycarTVApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AMEYCAR TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF070A10),
        primaryColor: const Color(0xFF7B2CBF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF9D4EDD),
          secondary: Color(0xFF00E5FF),
          surface: Color(0xFF0F172A),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<ChannelModel> _channels = [];
  int _selectedChannelIndex = 0;
  String _selectedCategory = 'Todos';
  String _selectedSection = 'En Vivo'; // 'En Vivo', 'Películas', 'Series'
  
  VideoPlayerController? _videoPlayerController;
  bool _isVideoLoading = false;
  bool _hasVideoError = false;
  bool _isFullScreenMode = false;
  bool _showOsd = true;
  double _currentVolume = 1.0;

  // MOTOR TURBO-ZAPPING (ESTILO TIVIMATE / DIRECTV)
  final Map<String, VideoPlayerController> _prebufferedPool = {};
  final Set<String> _prebufferingInProgress = {};
  int _zappingToken = 0;
  Timer? _zappingDebounceTimer;
  Timer? _osdHideTimer;

  final Set<String> _activeAlarms = {};

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  Timer? _clockTimer;
  String _currentTime = '';

  @override
  void initState() {
    super.initState();
    _startClockTimer();
    _loadSavedChannels();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.requestPermissionsSafely();
    });
  }

  void _startClockTimer() {
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        _updateClock();
      }
    });
  }

  void _updateClock() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    setState(() {
      _currentTime = '$hour:$minute:$second';
    });
  }

  void _loadSavedChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedM3u = prefs.getString('saved_m3u_content');
      final lastIndex = prefs.getInt('last_played_channel_index') ?? 0;
      final savedAlarmsList = prefs.getStringList('saved_active_alarms') ?? [];
      _activeAlarms.addAll(savedAlarmsList);

      if (savedM3u != null && savedM3u.isNotEmpty) {
        _channels = M3USanitizerService.parseAndSanitize(savedM3u);
      } else {
        _channels = M3USanitizerService.getCuratedChannels();
      }

      if (_channels.isNotEmpty) {
        _selectedChannelIndex = (lastIndex < _channels.length && lastIndex >= 0) ? lastIndex : 0;
        _initializeVideo(_channels[_selectedChannelIndex].streamUrl);
        _triggerOsdTimer();
      }
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Error cargando canales: $e');
    }
  }

  // Liberación asíncrona en segundo plano (NUNCA bloquea el cambio de canal)
  void _disposeControllerInBackground(VideoPlayerController? controller) {
    if (controller == null) return;
    Future.microtask(() async {
      try {
        await controller.pause();
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    });
  }

  Uri _parseStreamUri(String rawUrl) {
    final url = rawUrl.trim();
    Uri? targetUri = Uri.tryParse(url);
    if (targetUri == null || !targetUri.hasScheme) {
      targetUri = Uri.parse(Uri.encodeFull(url));
    }
    return targetUri;
  }

  // Pre-carga silenciosa de los canales adyacentes (CH+ y CH-) estilo TiviMate
  void _warmUpAdjacentChannels() {
    if (!mounted) return;
    final list = _filteredChannels;
    if (list.length <= 1) return;

    final activeCh = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : null;
    if (activeCh == null) return;

    final curIdx = list.indexOf(activeCh);
    if (curIdx == -1) return;

    final nextIdx = (curIdx + 1) % list.length;
    final prevIdx = (curIdx - 1 < 0) ? list.length - 1 : curIdx - 1;

    final nextUrl = list[nextIdx].streamUrl.trim();
    final prevUrl = list[prevIdx].streamUrl.trim();
    final activeUrl = activeCh.streamUrl.trim();

    final desiredUrls = <String>{
      if (nextUrl.isNotEmpty && nextUrl != activeUrl) nextUrl,
      if (prevUrl.isNotEmpty && prevUrl != activeUrl) prevUrl,
    };

    // 1. Limpiar del pool cualquier canal que ya no sea vecino inmediato
    final existingKeys = _prebufferedPool.keys.toList();
    for (final key in existingKeys) {
      if (!desiredUrls.contains(key)) {
        final oldPre = _prebufferedPool.remove(key);
        _disposeControllerInBackground(oldPre);
      }
    }

    // 2. Pre-inicializar en silencio CH+ y CH-
    for (final targetUrl in desiredUrls) {
      if (_prebufferedPool.containsKey(targetUrl) ||
          _prebufferingInProgress.contains(targetUrl)) {
        continue;
      }

      _prebufferingInProgress.add(targetUrl);
      Future.microtask(() async {
        try {
          final uri = _parseStreamUri(targetUrl);
          final preController = VideoPlayerController.networkUrl(
            uri,
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
          await preController.initialize();
          await preController.setVolume(0.0);
          await preController.setLooping(true);
          await preController.pause();

          _prebufferingInProgress.remove(targetUrl);

          if (!mounted) {
            _disposeControllerInBackground(preController);
            return;
          }

          final currentActive = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
              ? _channels[_selectedChannelIndex].streamUrl.trim()
              : '';
          if (targetUrl == currentActive) {
            _disposeControllerInBackground(preController);
            return;
          }

          _prebufferedPool[targetUrl] = preController;
        } catch (_) {
          _prebufferingInProgress.remove(targetUrl);
        }
      });
    }
  }

  void _initializeVideo(String rawUrl) async {
    if (!mounted) return;
    final url = rawUrl.trim();
    final currentToken = ++_zappingToken;

    if (url.isEmpty) {
      setState(() {
        _isVideoLoading = false;
        _hasVideoError = true;
      });
      return;
    }

    // RUTA ULTRARRÁPIDA (0.05s): ¿El canal ya está pre-cargado en nuestro Pool TiviMate?
    final preloaded = _prebufferedPool.remove(url);
    if (preloaded != null && preloaded.value.isInitialized) {
      final oldController = _videoPlayerController;
      _videoPlayerController = preloaded;
      setState(() {
        _isVideoLoading = false;
        _hasVideoError = false;
      });

      _disposeControllerInBackground(oldController);

      try {
        await preloaded.setVolume(_currentVolume);
        await preloaded.play();
      } catch (_) {}

      _warmUpAdjacentChannels();
      return;
    } else if (preloaded != null) {
      _disposeControllerInBackground(preloaded);
    }

    // RUTA PARALELA NO BLOQUEANTE: Mostrar transición suave con logo y conectar de inmediato
    setState(() {
      _isVideoLoading = true;
      _hasVideoError = false;
    });

    final oldController = _videoPlayerController;
    _videoPlayerController = null;
    _disposeControllerInBackground(oldController);

    try {
      final targetUri = _parseStreamUri(url);
      final controller = VideoPlayerController.networkUrl(
        targetUri,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      await controller.initialize();

      if (!mounted || currentToken != _zappingToken) {
        _disposeControllerInBackground(controller);
        return;
      }

      _videoPlayerController = controller;
      await _videoPlayerController!.setVolume(_currentVolume);
      await _videoPlayerController!.play();
      await _videoPlayerController!.setLooping(true);

      if (mounted && currentToken == _zappingToken) {
        setState(() {
          _isVideoLoading = false;
          _hasVideoError = false;
        });
        _warmUpAdjacentChannels();
      }
    } catch (e) {
      debugPrint('Error reproduciendo stream ($url): $e');
      if (mounted && currentToken == _zappingToken) {
        setState(() {
          _isVideoLoading = false;
          _hasVideoError = true;
        });
      }
    }
  }

  void _nextChannel() {
    final currentList = _filteredChannels;
    if (currentList.isEmpty) return;
    final currentCh = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : null;
    if (currentCh == null) return;
    int curIdxInFiltered = currentList.indexOf(currentCh);
    int nextIdx = (curIdxInFiltered + 1) % currentList.length;
    _changeChannel(currentList[nextIdx]);
  }

  void _previousChannel() {
    final currentList = _filteredChannels;
    if (currentList.isEmpty) return;
    final currentCh = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : null;
    if (currentCh == null) return;
    int curIdxInFiltered = currentList.indexOf(currentCh);
    int prevIdx = (curIdxInFiltered - 1 < 0) ? currentList.length - 1 : curIdxInFiltered - 1;
    _changeChannel(currentList[prevIdx]);
  }

  void _changeChannel(ChannelModel ch) {
    int realIndex = _channels.indexOf(ch);
    if (realIndex == -1) {
      realIndex = _channels.indexWhere((c) =>
        c.streamUrl.trim() == ch.streamUrl.trim() ||
        c.name.trim().toLowerCase() == ch.name.trim().toLowerCase()
      );
    }
    if (realIndex == -1) {
      _channels.add(ch);
      realIndex = _channels.length - 1;
    }

    final targetUrl = ch.streamUrl.trim();
    final isReadyInPool = _prebufferedPool.containsKey(targetUrl) &&
        (_prebufferedPool[targetUrl]?.value.isInitialized ?? false);

    // Respuesta de UI en 0 milisegundos
    setState(() {
      _selectedChannelIndex = realIndex;
      _showOsd = true;
      _hasVideoError = false;
      if (!isReadyInPool) {
        _isVideoLoading = true;
      }
    });

    _triggerOsdTimer();

    // Guardar preferencia en segundo plano (sin bloquear el zapping)
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('last_played_channel_index', realIndex);
    });

    _zappingDebounceTimer?.cancel();
    if (isReadyInPool) {
      _initializeVideo(targetUrl);
    } else {
      _zappingDebounceTimer = Timer(const Duration(milliseconds: 90), () {
        if (mounted) {
          _initializeVideo(targetUrl);
        }
      });
    }
  }

  void _triggerOsdTimer() {
    _osdHideTimer?.cancel();
    if (!_showOsd) {
      setState(() => _showOsd = true);
    }
    _osdHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) {
        setState(() => _showOsd = false);
      }
    });
  }

  void _toggleOsd() {
    setState(() {
      _showOsd = !_showOsd;
      if (_showOsd) {
        _triggerOsdTimer();
      } else {
        _osdHideTimer?.cancel();
      }
    });
  }

  void _startVoiceSearch() {
    List<ChannelModel> searchPool;
    if (_selectedSection == 'Películas' && _movies.isNotEmpty) {
      searchPool = _movies;
    } else if (_selectedSection == 'Series' && _series.isNotEmpty) {
      searchPool = _series;
    } else {
      searchPool = _liveChannels.isNotEmpty ? _liveChannels : _channels;
    }

    AlexaVoiceSheet.show(
      context: context,
      channels: searchPool,
      currentChannel: _channels.isNotEmpty && _selectedChannelIndex < _channels.length
          ? _channels[_selectedChannelIndex]
          : null,
      onChannelSelected: (item) {
        if (item is ChannelModel) {
          if (item.isLive && _selectedSection != 'En Vivo') {
            setState(() => _selectedSection = 'En Vivo');
          } else if (item.isMovie && _selectedSection != 'Películas') {
            setState(() => _selectedSection = 'Películas');
          } else if (item.isSeries && _selectedSection != 'Series') {
            setState(() => _selectedSection = 'Series');
          }
          
          Future.delayed(const Duration(milliseconds: 150), () {
            if (mounted) {
              _changeChannel(item);
              if (item.isMovie || item.isSeries) {
                setState(() => _isFullScreenMode = true);
              }
            }
          });
        }
      },
      onCategorySelected: (cat) {
        setState(() {
          _selectedCategory = cat;
          _searchQuery = '';
          _searchController.clear();
        });
      },
      onSectionChange: (section) {
        setState(() {
          _selectedSection = section;
          _searchQuery = '';
          _searchController.clear();
        });
      },
    );
  }

  void _adjustVolume(bool up) {
    setState(() {
      if (up) {
        _currentVolume = (_currentVolume + 0.2).clamp(0.0, 1.0);
      } else {
        _currentVolume = (_currentVolume - 0.2).clamp(0.0, 1.0);
      }
      _videoPlayerController?.setVolume(_currentVolume);
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🔊 Volumen: ${(_currentVolume * 100).toInt()}%'),
        duration: const Duration(seconds: 1),
        backgroundColor: const Color(0xFF7B2CBF),
      ),
    );
  }

  DateTime? _parseProgramStartTime(String timeStr) {
    try {
      final clean = timeStr.trim();
      final parts = clean.split(':');
      if (parts.length >= 2) {
        int hour = int.parse(parts[0].trim());
        int minute = int.parse(parts[1].trim().split(' ')[0]);
        if (clean.toLowerCase().contains('pm') && hour < 12) hour += 12;
        if (clean.toLowerCase().contains('am') && hour == 12) hour = 0;

        final now = DateTime.now();
        DateTime scheduled = DateTime(now.year, now.month, now.day, hour, minute);
        if (scheduled.isBefore(now.subtract(const Duration(minutes: 1)))) {
          scheduled = scheduled.add(const Duration(days: 1));
        }
        return scheduled;
      }
    } catch (e) {
      debugPrint('Error parseando hora del programa: $e');
    }
    return null;
  }

  void _openActiveAlarmsManagerModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          final alarmsList = _activeAlarms.toList();

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF070A10).withOpacity(0.98),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: const Color(0xFFFFB703).withOpacity(0.5), width: 1.5),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: const Color(0x33FFB703),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.alarm_on, color: Color(0xFFFFB703), size: 22),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Recordatorios Activos',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            Text(
                              '${alarmsList.length} alarma${alarmsList.length == 1 ? '' : 's'} programada${alarmsList.length == 1 ? '' : 's'}',
                              style: const TextStyle(color: Color(0xFFFFB703), fontSize: 11),
                            ),
                          ],
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 24),

                if (alarmsList.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Column(
                        children: const [
                          Icon(Icons.notifications_off_outlined, color: Colors.white24, size: 48),
                          SizedBox(height: 12),
                          Text(
                            'No tienes recordatorios activos',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Entra a la Guía EPG de un canal para programar tus programas.',
                            style: TextStyle(color: Colors.white38, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: alarmsList.length,
                      itemBuilder: (context, index) {
                        final alarmId = alarmsList[index];
                        final parts = alarmId.split('-');
                        final channelName = parts.isNotEmpty ? parts[0] : 'Canal';
                        final programTitle = parts.length > 1 ? parts[1] : alarmId;
                        final programTime = parts.length > 2 ? parts[2] : '';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x33FFB703)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: const Color(0x227B2CBF),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: const Color(0xFF9D4EDD)),
                                ),
                                child: const Icon(Icons.alarm, color: Color(0xFFFFB703), size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      programTitle,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    const SizedBox(height: 2),
                                    Row(
                                      children: [
                                        Text(
                                          channelName,
                                          style: const TextStyle(color: Color(0xFFC77DFF), fontSize: 11, fontWeight: FontWeight.bold),
                                        ),
                                        if (programTime.isNotEmpty) ...[
                                          const Text('  •  ', style: TextStyle(color: Colors.white30, fontSize: 11)),
                                          Text(
                                            programTime,
                                            style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.redAccent.withOpacity(0.2),
                                  foregroundColor: Colors.redAccent,
                                  side: const BorderSide(color: Colors.redAccent, width: 1),
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                  visualDensity: VisualDensity.compact,
                                ),
                                icon: const Icon(Icons.alarm_off, size: 16),
                                label: const Text('Quitar', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                onPressed: () async {
                                  final int notificationId = alarmId.hashCode.abs() % 2147483647;
                                  await NotificationService.cancelAlarm(notificationId);
                                  
                                  setState(() {
                                    _activeAlarms.remove(alarmId);
                                  });
                                  setModalState(() {});

                                  final prefs = await SharedPreferences.getInstance();
                                  await prefs.setStringList('saved_active_alarms', _activeAlarms.toList());

                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('🔕 Alarma cancelada para "$programTitle"'),
                                        backgroundColor: Colors.redAccent,
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                  }
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  void _openEpgScheduleModal(ChannelModel channel) {
    final schedule = EpgService.getUpcomingPrograms(channel.name, channel.groupCategory);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalContext, setModalState) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
          decoration: BoxDecoration(
            color: const Color(0xFF070A10).withOpacity(0.98),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(color: const Color(0xFF9D4EDD).withOpacity(0.5), width: 1.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      _buildChannelLogo(channel, true),
                      const SizedBox(width: 12),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.name,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          Row(
                            children: [
                              const Text(
                                'Guía EPG en Tiempo Real',
                                style: TextStyle(color: Color(0xFFC77DFF), fontSize: 11),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '🕒 $_currentTime',
                                style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ],
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 20),
              
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Programas y Recordatorios:',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      _openActiveAlarmsManagerModal();
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: _activeAlarms.isNotEmpty ? const Color(0xFFFFB703) : Colors.white10,
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _activeAlarms.isNotEmpty ? Icons.notifications_active : Icons.notifications_none,
                            color: const Color(0xFFFFB703),
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${_activeAlarms.length} activas (Ver/Apagar)',
                            style: const TextStyle(color: Color(0xFFFFB703), fontSize: 11, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: schedule.length,
                  itemBuilder: (context, index) {
                    final prog = schedule[index];
                    final isNow = index == 0;
                    final alarmId = '${channel.name}-${prog.title}-${prog.timeFormatted}';
                    final hasAlarm = _activeAlarms.contains(alarmId);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isNow
                            ? const Color(0x337B2CBF)
                            : hasAlarm
                                ? const Color(0x22FFB703)
                                : const Color(0xFF131B2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isNow
                              ? const Color(0xFF9D4EDD)
                              : hasAlarm
                                  ? const Color(0xFFFFB703)
                                  : Colors.white10,
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: isNow ? Colors.redAccent : const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Text(
                              isNow ? 'EN VIVO' : prog.timeFormatted.split(' - ')[0],
                              style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  prog.title,
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                ),
                                Text(
                                  prog.timeFormatted,
                                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isNow
                                  ? Icons.play_circle
                                  : hasAlarm
                                      ? Icons.alarm_on
                                      : Icons.alarm_add,
                              color: isNow
                                  ? const Color(0xFF00E5FF)
                                  : hasAlarm
                                      ? const Color(0xFFFFB703)
                                      : Colors.white38,
                            ),
                            tooltip: isNow ? 'En emisión' : hasAlarm ? 'Desactivar Alarma' : 'Activar Alarma',
                            onPressed: () async {
                              if (!isNow) {
                                final prefs = await SharedPreferences.getInstance();
                                final startTimeStr = prog.timeFormatted.split(' - ')[0];
                                final targetTime = _parseProgramStartTime(startTimeStr);
                                final int notificationId = alarmId.hashCode.abs() % 2147483647;

                                if (hasAlarm) {
                                  await NotificationService.cancelAlarm(notificationId);
                                  setState(() {
                                    _activeAlarms.remove(alarmId);
                                  });
                                  setModalState(() {});
                                  await prefs.setStringList('saved_active_alarms', _activeAlarms.toList());

                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text('🔕 Alarma cancelada para "${prog.title}"'),
                                        backgroundColor: Colors.redAccent,
                                      ),
                                    );
                                  }
                                } else {
                                  if (targetTime != null) {
                                    await NotificationService.scheduleAlarm(
                                      id: notificationId,
                                      title: '⏰ ¡Comienza ${prog.title}!',
                                      body: 'En sintonía por ${channel.name}. Toca para abrir AmeycarTV.',
                                      scheduledDate: targetTime,
                                    );
                                  }

                                  setState(() {
                                    _activeAlarms.add(alarmId);
                                  });
                                  setModalState(() {});
                                  await prefs.setStringList('saved_active_alarms', _activeAlarms.toList());

                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          '⏰ ¡Alarma activada para "${prog.title}" a las $startTimeStr!\nSonará incluso con la app cerrada.',
                                        ),
                                        backgroundColor: const Color(0xFF7B2CBF),
                                        duration: const Duration(seconds: 3),
                                      ),
                                    );
                                  }
                                }
                              }
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openM3uDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 5, sigmaY: 5),
        child: AlertDialog(
          backgroundColor: const Color(0xFF0F172A).withOpacity(0.95),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF7B2CBF), width: 1.5),
          ),
          title: const Row(
            children: [
              Icon(Icons.playlist_play, color: Color(0xFFC77DFF)),
              SizedBox(width: 8),
              Text('Gestor de Listas M3U', style: TextStyle(color: Colors.white, fontSize: 16)),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Pega el enlace URL de tu lista M3U o M3U8 para sanitizar y cargar tus canales:',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                style: const TextStyle(color: Colors.white, fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'https://servidor.com/lista.m3u',
                  hintStyle: const TextStyle(color: Colors.white30),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7B2CBF)),
              onPressed: () async {
                final url = controller.text.trim();
                if (url.isNotEmpty) {
                  Navigator.pop(ctx);
                  _downloadAndSanitizeM3u(url);
                }
              },
              child: const Text('Cargar y Sanitizar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  void _downloadAndSanitizeM3u(String url) async {
    setState(() => _isVideoLoading = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Descargando y sanitizando lista M3U...')),
    );

    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        final parsed = M3USanitizerService.parseAndSanitize(res.body);
        if (parsed.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('saved_m3u_content', res.body);
          await prefs.setInt('last_played_channel_index', 0);

          setState(() {
            _channels = parsed;
            _selectedChannelIndex = 0;
            _searchQuery = '';
            _isSearching = false;
          });
          _initializeVideo(_channels[0].streamUrl);

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('¡${parsed.length} elementos sanitizados con éxito!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      setState(() => _isVideoLoading = false);
    }
  }

  List<ChannelModel> get _liveChannels => _channels.where((c) => c.isLive).toList();
  List<ChannelModel> get _movies => _channels.where((c) => c.isMovie).toList();
  List<ChannelModel> get _series => _channels.where((c) => c.isSeries).toList();

  List<String> get _categories {
    final list = _liveChannels.map((c) => c.groupCategory).toSet().toList();
    return ['Todos', ...list];
  }

  List<ChannelModel> get _filteredChannels {
    return _liveChannels.where((c) {
      final matchesCategory = _selectedCategory == 'Todos' || c.groupCategory == _selectedCategory;
      final matchesSearch = _searchQuery.isEmpty ||
          c.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          c.number.toString().contains(_searchQuery) ||
          c.groupCategory.toLowerCase().contains(_searchQuery.toLowerCase());

      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_isFullScreenMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isFullScreenMode) {
          setState(() => _isFullScreenMode = false);
        }
      },
      child: Scaffold(
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.arrowDown): _nextChannel,
            const SingleActivator(LogicalKeyboardKey.arrowUp): _previousChannel,
            const SingleActivator(LogicalKeyboardKey.channelDown): _nextChannel,
            const SingleActivator(LogicalKeyboardKey.channelUp): _previousChannel,
            const SingleActivator(LogicalKeyboardKey.pageDown): _nextChannel,
            const SingleActivator(LogicalKeyboardKey.pageUp): _previousChannel,
            const SingleActivator(LogicalKeyboardKey.select): () {
              setState(() => _isFullScreenMode = !_isFullScreenMode);
            },
          },
          child: Focus(
            autofocus: true,
            child: OrientationBuilder(
              builder: (context, orientation) {
                return orientation == Orientation.portrait
                    ? _buildPortraitLayout()
                    : _buildLandscapeLayout();
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    final activeChannel = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : null;

    if (_isFullScreenMode) {
      return _buildImmersivePlayer(activeChannel);
    }

    return SafeArea(
      child: Column(
        children: [
          _buildTopGlassBar(activeChannel),
          _buildSectionTabs(),

          if (_selectedSection == 'En Vivo') ...[
            _buildVideoPlayerSection(activeChannel),
            _buildLiveEpgCard(activeChannel),
            _buildCategoryChips(),
            Expanded(child: _buildChannelListView()),
          ] else if (_selectedSection == 'Películas') ...[
            Expanded(
              child: VodGridView(
                items: _movies,
                contentType: 'movie',
                searchQuery: _searchQuery,
                onPlayItem: (item) {
                  _changeChannel(item);
                  setState(() => _isFullScreenMode = true);
                },
              ),
            ),
          ] else ...[
            Expanded(
              child: VodGridView(
                items: _series,
                contentType: 'series',
                searchQuery: _searchQuery,
                onPlayItem: (item) {
                  _changeChannel(item);
                  setState(() => _isFullScreenMode = true);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLandscapeLayout() {
    final activeChannel = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : null;

    if (_isFullScreenMode) {
      return _buildImmersivePlayer(activeChannel);
    }

    return Row(
      children: [
        Container(
          width: 190,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.85),
            border: const Border(right: BorderSide(color: Color(0x337B2CBF))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 16, top: 20, bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'AMEYCAR TV',
                      style: TextStyle(
                        color: Color(0xFFC77DFF),
                        fontWeight: FontWeight.w900,
                        fontSize: 16,
                        letterSpacing: 1.2,
                      ),
                    ),
                    Text(
                      '🕒 $_currentTime',
                      style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
              _buildSideMenuItem(Icons.live_tv, 'En Vivo', () => setState(() => _selectedSection = 'En Vivo')),
              _buildSideMenuItem(Icons.movie, 'Películas', () => setState(() => _selectedSection = 'Películas')),
              _buildSideMenuItem(Icons.tv, 'Series', () => setState(() => _selectedSection = 'Series')),
              _buildSideMenuItem(Icons.calendar_month, 'Guía EPG', () {
                if (activeChannel != null) {
                  _openEpgScheduleModal(activeChannel);
                } else if (_channels.isNotEmpty) {
                  _openEpgScheduleModal(_channels.first);
                }
              }),
              _buildSideMenuItem(
                Icons.alarm,
                'Alarmas (${_activeAlarms.length})',
                _openActiveAlarmsManagerModal,
              ),
              const Divider(color: Colors.white12),
              _buildSideMenuItem(Icons.search, 'Buscar', () => setState(() => _isSearching = !_isSearching)),
              _buildSideMenuItem(Icons.mic, 'Asistente Alexa', _startVoiceSearch),
              _buildSideMenuItem(Icons.playlist_add, 'Listas M3U', _openM3uDialog),
            ],
          ),
        ),

        if (_selectedSection == 'En Vivo') ...[
          Expanded(
            flex: 3,
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x337B2CBF)),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildVideoPlayerSection(activeChannel),
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A).withOpacity(0.7),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  _buildSearchInputHeader(),
                  Expanded(child: _buildChannelListView()),
                ],
              ),
            ),
          ),
        ] else if (_selectedSection == 'Películas') ...[
          Expanded(
            child: VodGridView(
              items: _movies,
              contentType: 'movie',
              searchQuery: _searchQuery,
              onPlayItem: (item) {
                _changeChannel(item);
                setState(() => _isFullScreenMode = true);
              },
            ),
          ),
        ] else ...[
          Expanded(
            child: VodGridView(
              items: _series,
              contentType: 'series',
              searchQuery: _searchQuery,
              onPlayItem: (item) {
                _changeChannel(item);
                setState(() => _isFullScreenMode = true);
              },
            ),
          ),
        ],
      ],
    );
  }

  // BARRA SUPERIOR GLASS CON BADGE INTELIGENTE (ESPACIO CONSTANTE, NUNCA SE MONTA)
  Widget _buildTopGlassBar([ChannelModel? activeChannel]) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.85),
        border: const Border(bottom: BorderSide(color: Color(0x227B2CBF))),
      ),
      child: _isSearching
          ? _buildActiveSearchBar()
          : Row(
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'AMEYCAR TV',
                      style: TextStyle(
                        color: Color(0xFFC77DFF),
                        fontWeight: FontWeight.w900,
                        fontSize: 14,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.red, width: 0.8),
                      ),
                      child: Text(
                        _selectedSection == 'En Vivo' ? 'LIVE' : _selectedSection.toUpperCase(),
                        style: const TextStyle(color: Colors.red, fontSize: 8.5, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: const Color(0x3300E5FF)),
                      ),
                      child: Text(
                        _currentTime.isNotEmpty ? _currentTime : '--:--',
                        style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),

                const Spacer(),

                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: Badge(
                    isLabelVisible: _activeAlarms.isNotEmpty,
                    label: Text(
                      '${_activeAlarms.length}',
                      style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black),
                    ),
                    backgroundColor: const Color(0xFFFFB703),
                    child: const Icon(Icons.calendar_month, color: Color(0xFF00E5FF), size: 20),
                  ),
                  tooltip: _activeAlarms.isNotEmpty 
                      ? '${_activeAlarms.length} alarmas activas • Toca para abrir' 
                      : 'Guía EPG',
                  onPressed: () {
                    if (activeChannel != null) {
                      _openEpgScheduleModal(activeChannel);
                    } else if (_channels.isNotEmpty) {
                      _openEpgScheduleModal(_channels.first);
                    }
                  },
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.search, color: Color(0xFFC77DFF), size: 20),
                  tooltip: 'Buscar en $_selectedSection',
                  onPressed: () => setState(() => _isSearching = true),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: const Icon(Icons.playlist_add, color: Colors.white70, size: 20),
                  tooltip: 'Cargar M3U',
                  onPressed: _openM3uDialog,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: EdgeInsets.zero,
                  icon: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E5FF).withOpacity(0.5),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: const Icon(Icons.mic, color: Color(0xFF00E5FF), size: 18),
                  ),
                  tooltip: 'Asistente Alexa de Voz',
                  onPressed: _startVoiceSearch,
                ),
              ],
            ),
    );
  }

  Widget _buildActiveSearchBar() {
    return Row(
      children: [
        const Icon(Icons.search, color: Color(0xFFC77DFF), size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: TextField(
            controller: _searchController,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Buscar en $_selectedSection...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
              border: InputBorder.none,
              isDense: true,
            ),
            onChanged: (val) {
              setState(() => _searchQuery = val.trim());
            },
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.close, color: Colors.white54, size: 18),
          onPressed: () {
            setState(() {
              _isSearching = false;
              _searchQuery = '';
              _searchController.clear();
            });
          },
        ),
      ],
    );
  }

  Widget _buildSearchInputHeader() {
    if (!_isSearching) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: _buildActiveSearchBar(),
    );
  }

  Widget _buildSectionTabs() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: const Color(0xFF0F172A).withOpacity(0.5),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: ['En Vivo', 'Películas', 'Series'].map((section) {
          final isSelected = _selectedSection == section;
          return GestureDetector(
            onTap: () {
              setState(() {
                _selectedSection = section;
                _searchQuery = '';
                _searchController.clear();
              });
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: isSelected
                    ? const Border(bottom: BorderSide(color: Color(0xFFC77DFF), width: 2))
                    : null,
              ),
              child: Text(
                section,
                style: TextStyle(
                  color: isSelected ? const Color(0xFFC77DFF) : Colors.white54,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  // LIENZO DE TRANSICIÓN SUAVE CON LOGO Y EPG (CERO PANTALLA NEGRA)
  Widget _buildSmoothTuningTransition(ChannelModel? activeChannel) {
    if (activeChannel == null) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF)));
    }

    final currentProg = EpgService.getCurrentProgram(activeChannel.name, activeChannel.groupCategory);
    final chNum = activeChannel.number.toString().padLeft(3, '0');

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Color(0xFF070A10),
            Color(0xFF131B2E),
            Color(0xFF090D16),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F172A),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.45)),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF00E5FF).withOpacity(0.2),
                      blurRadius: 14,
                    ),
                  ],
                ),
                child: _buildChannelLogo(activeChannel, true),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E5FF).withOpacity(0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            'CH $chNum',
                            style: const TextStyle(
                              color: Color(0xFF00E5FF),
                              fontSize: 10,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        const SizedBox(
                          width: 11,
                          height: 11,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Color(0xFF00E5FF),
                          ),
                        ),
                        const SizedBox(width: 5),
                        const Text(
                          'SINTONIZANDO...',
                          style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      activeChannel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      currentProg.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildVideoPlayerSection(ChannelModel? activeChannel) {
    final isReady = !_isVideoLoading &&
        !_hasVideoError &&
        _videoPlayerController != null &&
        _videoPlayerController!.value.isInitialized;

    return GestureDetector(
      onTap: _toggleOsd,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -120) _nextChannel();
          if (details.primaryVelocity! > 120) _previousChannel();
        }
      },
      onDoubleTap: () {
        setState(() => _isFullScreenMode = !_isFullScreenMode);
      },
      child: Container(
        height: 215,
        width: double.infinity,
        color: const Color(0xFF070A10),
        child: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: isReady
                  ? Center(
                      key: ValueKey<String>(activeChannel?.streamUrl ?? 'video'),
                      child: AspectRatio(
                        aspectRatio: _videoPlayerController!.value.aspectRatio,
                        child: VideoPlayer(_videoPlayerController!),
                      ),
                    )
                  : _hasVideoError
                      ? Center(
                          key: const ValueKey<String>('error'),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.cloud_off, color: Colors.white38, size: 36),
                              const SizedBox(height: 6),
                              const Text(
                                'Señal no disponible temporalmente',
                                style: TextStyle(color: Colors.white54, fontSize: 12),
                              ),
                              const SizedBox(height: 8),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF7B2CBF),
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                ),
                                onPressed: () {
                                  if (activeChannel != null) _initializeVideo(activeChannel.streamUrl);
                                },
                                icon: const Icon(Icons.refresh, size: 16, color: Colors.white),
                                label: const Text('Reintentar', style: TextStyle(color: Colors.white, fontSize: 11)),
                              ),
                            ],
                          ),
                        )
                      : _buildSmoothTuningTransition(activeChannel),
            ),

            // MINI-OVERLAY DE ZAPPING PROFESIONAL (ESTILO TIVIMATE / DIRECTV)
            if (_showOsd && activeChannel != null)
              ZappingChannelOverlay(
                channel: activeChannel,
                channelIndex: _selectedChannelIndex,
                totalChannels: _channels.length,
                isPlaying: _videoPlayerController != null && _videoPlayerController!.value.isPlaying,
                onPlayPause: () {
                  if (_videoPlayerController != null) {
                    setState(() {
                      if (_videoPlayerController!.value.isPlaying) {
                        _videoPlayerController!.pause();
                      } else {
                        _videoPlayerController!.play();
                      }
                    });
                  }
                },
                onNext: _nextChannel,
                onPrevious: _previousChannel,
                onOpenEpg: () => _openEpgScheduleModal(activeChannel),
                onToggleFullScreen: () => setState(() => _isFullScreenMode = true),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveEpgCard(ChannelModel? activeChannel) {
    if (activeChannel == null) return const SizedBox.shrink();

    final currentProg = EpgService.getCurrentProgram(activeChannel.name, activeChannel.groupCategory);
    final nextProg = EpgService.getNextProgram(activeChannel.name, activeChannel.groupCategory);

    return InkWell(
      onTap: () => _openEpgScheduleModal(activeChannel),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF0F172A).withOpacity(0.9),
          border: const Border(bottom: BorderSide(color: Color(0x1F9D4EDD))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Icon(Icons.live_tv, color: Colors.redAccent, size: 14),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          currentProg.title,
                          style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  currentProg.timeFormatted,
                  style: const TextStyle(color: Color(0xFFC77DFF), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'A continuación: ${nextProg.title}',
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Quedan ${currentProg.remainingMinutes} min',
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: currentProg.progress,
                backgroundColor: const Color(0xFF1E293B),
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF9D4EDD)),
                minHeight: 3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryChips() {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = category == _selectedCategory;
          return GestureDetector(
            onTap: () => setState(() => _selectedCategory = category),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF7B2CBF) : const Color(0xFF1E293B).withOpacity(0.8),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? const Color(0xFFC77DFF) : Colors.white10,
                ),
              ),
              child: Center(
                child: Text(
                  category,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildChannelListView() {
    final list = _filteredChannels;

    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.search_off, color: Colors.white30, size: 40),
            const SizedBox(height: 8),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No se encontraron canales para "$_searchQuery"'
                  : 'No hay canales disponibles en esta categoría',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final channel = list[index];
        final isSelected = _channels.isNotEmpty &&
            _selectedChannelIndex < _channels.length &&
            _channels[_selectedChannelIndex].streamUrl == channel.streamUrl;

        return Focus(
          onKey: (node, event) {
            if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
              _changeChannel(channel);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(
            builder: (ctx) {
              final isFocused = Focus.of(ctx).hasFocus;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                decoration: BoxDecoration(
                  color: isFocused
                      ? const Color(0x339D4EDD)
                      : isSelected
                          ? const Color(0xFF1E293B).withOpacity(0.9)
                          : const Color(0xFF0F172A).withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isFocused
                        ? const Color(0xFFC77DFF)
                        : isSelected
                            ? const Color(0xFF9D4EDD)
                            : Colors.transparent,
                    width: isFocused ? 2 : 1,
                  ),
                ),
                child: ListTile(
                  dense: true,
                  leading: _buildChannelLogo(channel, isSelected),
                  title: Text(
                    channel.name,
                    style: TextStyle(
                      color: isSelected ? const Color(0xFFC77DFF) : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    'Grupo: ${channel.groupCategory} • ${channel.resolution}',
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.volume_up, color: Color(0xFFC77DFF), size: 18)
                      : null,
                  onTap: () => _changeChannel(channel),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildChannelLogo(ChannelModel channel, bool isSelected) {
    if (channel.logoUrl.isNotEmpty) {
      return Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.network(
            channel.logoUrl,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) => _buildFallbackAvatar(channel, isSelected),
          ),
        ),
      );
    }
    return _buildFallbackAvatar(channel, isSelected);
  }

  Widget _buildFallbackAvatar(ChannelModel channel, bool isSelected) {
    return CircleAvatar(
      radius: 16,
      backgroundColor: isSelected ? const Color(0xFF7B2CBF) : const Color(0xFF1E293B),
      child: Text(
        '${channel.number}',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildImmersivePlayer(ChannelModel? activeChannel) {
    final isReady = !_isVideoLoading &&
        !_hasVideoError &&
        _videoPlayerController != null &&
        _videoPlayerController!.value.isInitialized;

    return GestureDetector(
      onTap: _toggleOsd,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -120) _nextChannel();
          if (details.primaryVelocity! > 120) _previousChannel();
        }
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070A10),
        body: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: isReady
                  ? Center(
                      key: ValueKey<String>(activeChannel?.streamUrl ?? 'immersive_video'),
                      child: AspectRatio(
                        aspectRatio: _videoPlayerController!.value.aspectRatio,
                        child: VideoPlayer(_videoPlayerController!),
                      ),
                    )
                  : _hasVideoError
                      ? Center(
                          key: const ValueKey<String>('immersive_error'),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(Icons.error_outline, color: Colors.redAccent, size: 48),
                              const SizedBox(height: 12),
                              Text(
                                'No se pudo reproducir: ${activeChannel?.name ?? "Canal"}',
                                style: const TextStyle(color: Colors.white, fontSize: 14),
                              ),
                              const SizedBox(height: 12),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7B2CBF)),
                                onPressed: () {
                                  if (activeChannel != null) _initializeVideo(activeChannel.streamUrl);
                                },
                                icon: const Icon(Icons.refresh, color: Colors.white),
                                label: const Text('Reintentar', style: TextStyle(color: Colors.white)),
                              ),
                            ],
                          ),
                        )
                      : _buildSmoothTuningTransition(activeChannel),
            ),

            // OVERLAY EN PANTALLA COMPLETA
            if (_showOsd && activeChannel != null)
              Positioned(
                bottom: 16,
                left: 16,
                right: 16,
                child: ZappingChannelOverlay(
                  channel: activeChannel,
                  channelIndex: _selectedChannelIndex,
                  totalChannels: _channels.length,
                  isPlaying: _videoPlayerController != null && _videoPlayerController!.value.isPlaying,
                  onPlayPause: () {
                    if (_videoPlayerController != null) {
                      setState(() {
                        if (_videoPlayerController!.value.isPlaying) {
                          _videoPlayerController!.pause();
                        } else {
                          _videoPlayerController!.play();
                        }
                      });
                    }
                  },
                  onNext: _nextChannel,
                  onPrevious: _previousChannel,
                  onOpenEpg: () => _openEpgScheduleModal(activeChannel),
                  onToggleFullScreen: () => setState(() => _isFullScreenMode = false),
                ),
              ),

            // BOTÓN SALIR DE PANTALLA COMPLETA
            if (_showOsd)
              Positioned(
                top: 24,
                right: 24,
                child: IconButton(
                  icon: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white24),
                    ),
                    child: const Icon(Icons.fullscreen_exit, color: Colors.white, size: 22),
                  ),
                  onPressed: () => setState(() => _isFullScreenMode = false),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSideMenuItem(IconData icon, String title, VoidCallback onTap) {
    return ListTile(
      dense: true,
      leading: Icon(icon, color: const Color(0xFFC77DFF), size: 20),
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 12)),
      onTap: onTap,
    );
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _zappingDebounceTimer?.cancel();
    _osdHideTimer?.cancel();
    _videoPlayerController?.dispose();
    for (final pre in _prebufferedPool.values) {
      pre.dispose();
    }
    _prebufferedPool.clear();
    _searchController.dispose();
    super.dispose();
  }
}