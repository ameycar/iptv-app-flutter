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
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'models/channel_model.dart';
import 'models/user_model.dart';
import 'services/m3u_sanitizer_service.dart';
import 'services/epg_service.dart';
import 'services/auth_service.dart';
import 'screens/login_screen.dart';
import 'screens/admin_panel_screen.dart';
import 'screens/family_panel_screen.dart';
import 'screens/profile_selector_screen.dart';
import 'widgets/alexa_voice_sheet.dart';
import 'widgets/vod_grid_view.dart';
import 'widgets/zapping_channel_overlay.dart';
import 'widgets/live_chat_overlay.dart';

// SERVICIO NATIVO PARA ALARMAS CON AUTO-SINTONIZACIÓN EXACTA DE CANAL
class NotificationService {
  static final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static final StreamController<String> alarmPayloadStream =
      StreamController<String>.broadcast();

  static String? pendingLaunchPayload;

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
      await _notificationsPlugin.initialize(
        initSettings,
        onDidReceiveNotificationResponse: (NotificationResponse response) {
          final payload = response.payload;
          if (payload != null && payload.trim().isNotEmpty) {
            pendingLaunchPayload = payload;
            alarmPayloadStream.add(payload);
          }
        },
      );

      final launchDetails =
          await _notificationsPlugin.getNotificationAppLaunchDetails();
      if (launchDetails != null && launchDetails.didNotificationLaunchApp) {
        final payload = launchDetails.notificationResponse?.payload;
        if (payload != null && payload.trim().isNotEmpty) {
          pendingLaunchPayload = payload;
        }
      }
    } catch (e) {
      debugPrint('Error inicializando FlutterLocalNotifications: $e');
    }
  }

  static String? consumePendingPayload() {
    final temp = pendingLaunchPayload;
    pendingLaunchPayload = null;
    return temp;
  }

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
    required String channelName,
    required String streamUrl,
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

      final String encodedPayload = jsonEncode({
        'name': channelName,
        'url': streamUrl,
      });

      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        tzScheduledDate,
        details,
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: encodedPayload,
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
      await Firebase.initializeApp();
    } catch (e) {
      debugPrint('Error seguro en Firebase.initializeApp: $e');
    }
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

class AmeycarTVApp extends StatefulWidget {
  const AmeycarTVApp({super.key});

  @override
  State<AmeycarTVApp> createState() => _AmeycarTVAppState();
}

class _AmeycarTVAppState extends State<AmeycarTVApp> {
  bool _isCheckingAuth = true;
  bool _isAuthenticated = false;
  bool _hasSelectedProfile = false;
  Widget? _customDirectScreen;

  @override
  void initState() {
    super.initState();
    _verifyInitialSession();
  }

  Future<void> _verifyInitialSession() async {
    try {
      final res = await AuthService.checkAutoLogin();
      if (mounted) {
        final bool launchedFromAlarm =
            NotificationService.pendingLaunchPayload != null;
        setState(() {
          _isAuthenticated = res != null;
          _hasSelectedProfile = launchedFromAlarm;
          _customDirectScreen = null;
          _isCheckingAuth = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isAuthenticated = false;
          _hasSelectedProfile = false;
          _customDirectScreen = null;
          _isCheckingAuth = false;
        });
      }
    }
  }

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
      home: _isCheckingAuth
          ? const Scaffold(
              backgroundColor: Color(0xFF070A10),
              body: Center(
                child: CircularProgressIndicator(color: Color(0xFF00E5FF)),
              ),
            )
          : _isAuthenticated
              ? (_customDirectScreen != null)
                  ? _customDirectScreen!
                  : (AuthService.currentUser?.isPartOfFamily == true && !_hasSelectedProfile)
                      ? ProfileSelectorScreen(
                          onLogout: () {
                            setState(() {
                              _isAuthenticated = false;
                              _hasSelectedProfile = false;
                              _customDirectScreen = null;
                            });
                          },
                          onProfileSelected: () {
                            setState(() {
                              _hasSelectedProfile = true;
                              _customDirectScreen = null;
                            });
                          },
                        )
                      : HomeScreen(
                          onLogout: () {
                            setState(() {
                              _isAuthenticated = false;
                              _hasSelectedProfile = false;
                              _customDirectScreen = null;
                            });
                          },
                        )
              : LoginScreen(
                  onLoginSuccess: ({Widget? directScreen}) {
                    setState(() {
                      _isAuthenticated = true;
                      _hasSelectedProfile = false;
                      _customDirectScreen = directScreen;
                    });
                  },
                ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const HomeScreen({super.key, this.onLogout});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  static const MethodChannel _pipChannel = MethodChannel('ameycar.tv/pip');

  List<ChannelModel> _channels = [];
  int _selectedChannelIndex = 0;
  String _selectedCategory = 'Favoritos (⭐)';
  String _selectedSection = 'En Vivo';

  VideoPlayerController? _videoPlayerController;
  bool _isVideoLoading = false;
  bool _hasVideoError = false;
  bool _isFullScreenMode = false;
  bool _showOsd = true;
  double _currentVolume = 1.0;

  bool _isInPipMode = false;
  bool _showLiveChat = false;
  String _selectedLanguage = 'Español (Latinoamérica)';
  int _customAvatarIdx = 0;

  List<Map<String, dynamic>> _savedPlaylists = [];
  final Set<String> _favoriteChannelUrls = {};

  final Map<String, VideoPlayerController> _prebufferedPool = {};
  final Set<String> _prebufferingInProgress = {};
  int _zappingToken = 0;
  Timer? _osdHideTimer;

  static const Map<String, String> _fastStreamHeaders = {
    'User-Agent': 'AmeycarTV/2.0 (Linux; Android 13) ExoPlayerLib/2.19.1',
    'Connection': 'keep-alive',
  };

  final Set<String> _activeAlarms = {};

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  Timer? _clockTimer;
  String _currentTime = '';

  StreamSubscription<UserModel?>? _accountGuardSub;
  StreamSubscription<String>? _alarmTapSub;

  String get _currentProfileId =>
      AuthService.currentActiveProfile?.id ??
      AuthService.currentUser?.id ??
      'default_profile';

  bool get _canSeePaymentBanks {
    final user = AuthService.currentUser;
    if (user == null) return true;
    if (user.isAdmin || user.isFamilyAdmin) return true;
    final famId = user.familyId ?? '';
    return !user.isPartOfFamily || famId.trim().isEmpty;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable();
    _syncAutoPipState(true);

    EpgService.ensureInitialized();
    _startClockTimer();
    _startAccountHardwareGuard();
    _listenToAlarmNotificationTaps();
    _loadFavorites();
    _loadSavedChannels();
    _ensureUserHasReferralCode();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationService.requestPermissionsSafely();
    });
  }

  void _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favList = prefs.getStringList('favorite_channels_$_currentProfileId') ?? [];
    if (mounted) {
      setState(() {
        _favoriteChannelUrls
          ..clear()
          ..addAll(favList);
      });
    }
  }

  void _toggleFavorite(ChannelModel channel) async {
    final url = channel.streamUrl.trim();
    setState(() {
      if (_favoriteChannelUrls.contains(url)) {
        _favoriteChannelUrls.remove(url);
      } else {
        _favoriteChannelUrls.add(url);
      }
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('favorite_channels_$_currentProfileId', _favoriteChannelUrls.toList());

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_favoriteChannelUrls.contains(url)
              ? '⭐ ¡Canal agregado a favoritos!'
              : '🗑️ Canal removido de favoritos'),
          duration: const Duration(seconds: 1),
          backgroundColor: const Color(0xFF7B2CBF),
        ),
      );
    }
  }

  void _listenToAlarmNotificationTaps() {
    _alarmTapSub?.cancel();
    _alarmTapSub = NotificationService.alarmPayloadStream.stream.listen((payload) {
      NotificationService.consumePendingPayload();
      _tuneChannelFromAlarmPayload(payload);
    });
  }

  void _tuneChannelFromAlarmPayload(String rawPayload) {
    if (!mounted || _channels.isEmpty || rawPayload.trim().isEmpty) return;

    String targetName = rawPayload.trim();
    String targetUrl = '';

    try {
      final decoded = jsonDecode(rawPayload);
      if (decoded is Map) {
        targetName = (decoded['name'] ?? '').toString().trim();
        targetUrl = (decoded['url'] ?? '').toString().trim();
      }
    } catch (_) {}

    int foundIndex = -1;

    if (targetUrl.isNotEmpty) {
      foundIndex = _channels.indexWhere((c) => c.streamUrl.trim() == targetUrl);
    }

    if (foundIndex == -1 && targetName.isNotEmpty) {
      final lowerExact = targetName.toLowerCase();
      foundIndex = _channels.indexWhere((c) => c.name.trim().toLowerCase() == lowerExact);
    }

    if (foundIndex == -1 && targetName.isNotEmpty) {
      final lowerPart = targetName.toLowerCase();
      foundIndex = _channels.indexWhere((c) => c.name.toLowerCase().contains(lowerPart));
    }

    if (foundIndex != -1) {
      final targetChannel = _channels[foundIndex];
      setState(() {
        _selectedSection = 'En Vivo';
        _selectedCategory = 'Favoritos (⭐)';
        _isSearching = false;
        _searchQuery = '';
        _searchController.clear();
      });

      _changeChannel(targetChannel);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⏰ Sintonizando tu recordatorio: ${targetChannel.name}'),
          backgroundColor: const Color(0xFF00C853),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  Future<void> _syncAutoPipState(bool enabled) async {
    try {
      await _pipChannel.invokeMethod('setAutoPip', {'enabled': enabled});
    } catch (_) {}
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final size = MediaQuery.of(context).size;
      final bool looksLikePip = size.height < 320 && size.width < 560;
      if (looksLikePip != _isInPipMode) {
        setState(() => _isInPipMode = looksLikePip);
      }
    });
  }

  Future<void> _ensureUserHasReferralCode() async {
    final user = AuthService.currentUser;
    if (user == null || !AuthService.isFirebaseAvailable) return;
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(user.id).get();
      if (doc.exists) {
        final data = doc.data() ?? {};
        if (data['referralCode'] == null || data['referralCode'].toString().isEmpty) {
          final clean = user.username.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
          final suffix = user.id.hashCode.abs().toString().padLeft(4, '0').substring(0, 4);
          final generated = 'AMEY-$clean-$suffix';
          await FirebaseFirestore.instance.collection('users').doc(user.id).set(
            {'referralCode': generated},
            SetOptions(merge: true),
          );
        }
      }
    } catch (e) {
      debugPrint('Aviso generando referralCode automático: $e');
    }
  }

  Future<void> _enterNativePiP() async {
    try {
      final bool? entered = await _pipChannel.invokeMethod<bool>('enterPip');
      if (entered == true && mounted) {
        setState(() => _isInPipMode = true);
      } else if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Activa "Imagen en imagen" en los ajustes de tu teléfono para flotar el video.'),
            backgroundColor: Color(0xFF7B2CBF),
          ),
        );
      }
    } catch (e) {
      debugPrint('Aviso PiP nativo: $e');
    }
  }

  void _startAccountHardwareGuard() async {
    final user = AuthService.currentUser;
    if (user == null || user.isAdmin) return;
    final myHwId = await AuthService.getDeviceHardwareId();

    _accountGuardSub?.cancel();
    _accountGuardSub = AuthService.listenToUserRealtime(user.id).listen((liveUser) async {
      if (!mounted) return;
      if (liveUser == null || !liveUser.isActive || liveUser.isExpired) {
        await _forceLogoutWithReason('Tu cuenta ha sido suspendida o ha vencido.');
        return;
      }
      final boundHw = liveUser.registeredHardwareId;
      if (boundHw != null && boundHw.isNotEmpty && boundHw != myHwId) {
        await _forceLogoutWithReason('Sesión cerrada: Esta cuenta se vinculó a un nuevo dispositivo autorizado.');
      }
    });
  }

  Future<void> _forceLogoutWithReason(String reason) async {
    _accountGuardSub?.cancel();
    _videoPlayerController?.pause();
    await _syncAutoPipState(false);
    await AuthService.logout();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(reason),
        backgroundColor: Colors.redAccent,
        duration: const Duration(seconds: 4),
      ),
    );
    widget.onLogout?.call();
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
      _customAvatarIdx = prefs.getInt('custom_avatar_$_currentProfileId') ?? 0;
      _selectedLanguage = prefs.getString('app_lang') ?? 'Español (Latinoamérica)';

      final rawLists = prefs.getString('m3u_lists_$_currentProfileId');
      if (rawLists != null && rawLists.isNotEmpty) {
        final List decoded = jsonDecode(rawLists);
        _savedPlaylists = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
      } else {
        final legacyUrl = prefs.getString('saved_m3u_url') ?? '';
        if (legacyUrl.isNotEmpty) {
          _savedPlaylists = [
            {
              'id': 'pl_1',
              'name': 'Lista Principal',
              'url': legacyUrl,
              'isActive': true,
            }
          ];
          await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
        }
      }

      final activeList = _savedPlaylists.where((l) => l['isActive'] == true).toList();
      String? savedM3u;
      if (activeList.isNotEmpty) {
        savedM3u = prefs.getString('m3u_cache_${activeList.first['id']}') ??
            prefs.getString('saved_m3u_content');
      } else {
        savedM3u = prefs.getString('saved_m3u_content');
      }

      final lastIndex = prefs.getInt('last_played_channel_index') ?? 0;
      final savedAlarmsList = prefs.getStringList('saved_active_alarms') ?? [];
      _activeAlarms
        ..clear()
        ..addAll(savedAlarmsList);

      if (savedM3u != null && savedM3u.isNotEmpty) {
        unawaited(EpgService.extractAndSaveEpgUrlFromM3u(savedM3u));
        _channels = M3USanitizerService.parseAndSanitize(savedM3u);
      } else {
        _channels = M3USanitizerService.getCuratedChannels();
      }

      final pendingAlarmPayload = NotificationService.consumePendingPayload();
      if (pendingAlarmPayload != null && _channels.isNotEmpty) {
        if (mounted) setState(() {});
        _tuneChannelFromAlarmPayload(pendingAlarmPayload);
        return;
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
        httpHeaders: _fastStreamHeaders,
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

    final existingKeys = _prebufferedPool.keys.toList();
    for (final key in existingKeys) {
      if (!desiredUrls.contains(key)) {
        final oldPre = _prebufferedPool.remove(key);
        _disposeControllerInBackground(oldPre);
      }
    }

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
            httpHeaders: _fastStreamHeaders,
            videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
          );
          await preController.initialize();
          await preController.setVolume(0.0);
          await preController.setLooping(true);
          await preController.play();
          await Future.delayed(const Duration(milliseconds: 100));
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
          c.name.trim().toLowerCase() == ch.name.trim().toLowerCase());
    }
    if (realIndex == -1) {
      _channels.add(ch);
      realIndex = _channels.length - 1;
    }

    final targetUrl = ch.streamUrl.trim();
    final isReadyInPool = _prebufferedPool.containsKey(targetUrl) &&
        (_prebufferedPool[targetUrl]?.value.isInitialized ?? false);

    setState(() {
      _selectedChannelIndex = realIndex;
      _showOsd = true;
      _hasVideoError = false;
      if (!isReadyInPool) {
        _isVideoLoading = true;
      }
    });

    _triggerOsdTimer();

    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('last_played_channel_index', realIndex);
    });

    _initializeVideo(targetUrl);
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
          final match = _categories.firstWhere(
            (existing) => existing.toLowerCase().contains(cat.toLowerCase()) ||
                cat.toLowerCase().contains(existing.toLowerCase()),
            orElse: () => 'Favoritos (⭐)',
          );
          _selectedCategory = match;
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
      onOpenEpg: () {
        if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
          _openEpgScheduleModal(_channels[_selectedChannelIndex]);
        }
      },
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

  void _showSettingsMenu() {
    final user = AuthService.currentActiveProfile ?? AuthService.currentUser;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Icon(Icons.settings, color: Color(0xFF00E5FF), size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Centro de Configuración',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
                        ),
                        Text(
                          'Sesión activa: ${user?.username ?? "Usuario"} • ${user?.daysRemaining ?? 0} días restantes',
                          style: const TextStyle(color: Colors.white60, fontSize: 11.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              _buildSettingsTile(
                icon: Icons.card_giftcard,
                color: const Color(0xFFFFD600),
                title: 'Círculo AMEYCAR (Gana +15 Días Gratis)',
                subtitle: 'Comparte tu código de invitación automático',
                onTap: () {
                  Navigator.pop(ctx);
                  _showReferralClubModal();
                },
              ),
              _buildSettingsTile(
                icon: Icons.person_outline,
                color: const Color(0xFF00E5FF),
                title: 'Editar Perfil, Avatar y Hardware',
                subtitle: 'Personalizar foto de perfil y ver ID de equipo',
                onTap: () {
                  Navigator.pop(ctx);
                  _showAccountProfileModal();
                },
              ),
              _buildSettingsTile(
                icon: Icons.playlist_play,
                color: const Color(0xFF9D4EDD),
                title: 'Gestor Multi-Lista M3U (${_savedPlaylists.length}/5)',
                subtitle: 'Administrar hasta 5 listas de canales y Guía EPG',
                onTap: () {
                  Navigator.pop(ctx);
                  _openM3uDialog();
                },
              ),
              _buildSettingsTile(
                icon: Icons.alarm_on,
                color: const Color(0xFFFFB703),
                title: 'Mis Alarmas Programadas (${_activeAlarms.length})',
                subtitle: 'Ver o cancelar recordatorios activos',
                onTap: () {
                  Navigator.pop(ctx);
                  _openActiveAlarmsManagerModal();
                },
              ),
              _buildSettingsTile(
                icon: Icons.picture_in_picture_alt_rounded,
                color: Colors.cyanAccent,
                title: 'Activar Pantalla Flotante (PiP)',
                subtitle: 'Minimizar video redimensionable sobre otras apps',
                onTap: () {
                  Navigator.pop(ctx);
                  _enterNativePiP();
                },
              ),
              _buildSettingsTile(
                icon: Icons.headset_mic,
                color: const Color(0xFF00E676),
                title: 'Soporte Directo / Contactar al CEO',
                subtitle: 'Atención inmediata por WhatsApp oficial',
                onTap: () {
                  Navigator.pop(ctx);
                  _openSupportMenu();
                },
              ),
              _buildSettingsTile(
                icon: Icons.language,
                color: Colors.amberAccent,
                title: 'Idioma de la Interfaz',
                subtitle: 'Actual: $_selectedLanguage',
                onTap: () {
                  Navigator.pop(ctx);
                  _showLanguageSelectorDialog();
                },
              ),
              _buildSettingsTile(
                icon: Icons.switch_account,
                color: const Color(0xFFC77DFF),
                title: 'Cambiar de Perfil / Cuenta',
                subtitle: AuthService.currentUser?.isPartOfFamily == true
                    ? 'Volver al selector "¿Quién está viendo hoy?"'
                    : 'Cambiar a otra cuenta de usuario',
                onTap: () async {
                  Navigator.pop(ctx);
                  if (AuthService.currentUser?.isPartOfFamily == true) {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ProfileSelectorScreen(
                          onLogout: widget.onLogout,
                          onProfileSelected: () {
                            Navigator.pop(context);
                            _loadSavedChannels();
                          },
                        ),
                      ),
                    );
                  } else {
                    _videoPlayerController?.pause();
                    await _syncAutoPipState(false);
                    await AuthService.logout();
                    widget.onLogout?.call();
                  }
                },
              ),
              const Divider(color: Colors.white12, height: 22),
              _buildSettingsTile(
                icon: Icons.logout,
                color: Colors.redAccent,
                title: 'Cerrar Sesión Segura',
                subtitle: 'Salir de la cuenta actual en este dispositivo',
                onTap: () async {
                  Navigator.pop(ctx);
                  _videoPlayerController?.pause();
                  await _syncAutoPipState(false);
                  await AuthService.logout();
                  widget.onLogout?.call();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 2),
      leading: Container(
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11.5)),
      trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white24, size: 14),
      onTap: onTap,
    );
  }

  void _showLanguageSelectorDialog() {
    final langs = ['Español (Latinoamérica)', 'English (US)', 'Português (Brasil)'];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Seleccionar Idioma', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: langs.map((l) {
            final sel = _selectedLanguage == l;
            return ListTile(
              leading: Icon(sel ? Icons.radio_button_checked : Icons.radio_button_off, color: const Color(0xFF00E5FF)),
              title: Text(l, style: const TextStyle(color: Colors.white, fontSize: 13.5)),
              onTap: () async {
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('app_lang', l);
                setState(() => _selectedLanguage = l);
                if (ctx.mounted) Navigator.pop(ctx);
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  void _showReferralClubModal() async {
    final user = AuthService.currentUser;
    if (user == null) return;

    String refCode = 'AMEY-${user.username.toUpperCase()}-VIP';
    int invitedCount = 0;

    if (AuthService.isFirebaseAvailable) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.id).get();
        if (doc.exists) {
          final data = doc.data() ?? {};
          if (data['referralCode'] != null && data['referralCode'].toString().isNotEmpty) {
            refCode = data['referralCode'].toString();
          }
          invitedCount = (data['referralsCount'] is int) ? data['referralsCount'] as int : 0;
        }
      } catch (_) {}
    }

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFFFFD600), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.card_giftcard, color: Color(0xFFFFD600)),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Círculo AMEYCAR (+15 Días)',
                style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Comparte tu código único con tus amigos. Cada vez que un amigo active su plan e ingrese tu código al canjear su PIN, el sistema te sumará +15 DÍAS GRATIS automáticamente.',
              style: TextStyle(color: Colors.white70, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withOpacity(0.14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFD600)),
              ),
              child: Column(
                children: [
                  Text(
                    refCode,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFFFD600),
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.8,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Amigos invitados con éxito: $invitedCount (+${invitedCount * 15} días ganados)',
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFD600),
              foregroundColor: Colors.black,
            ),
            icon: const Icon(Icons.share, size: 16),
            label: const Text('Copiar Invitación', style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () {
              final shareMsg =
                  '¡Te invito a ver TV en vivo, fútbol y cine en AMEYCAR TV! 🍿⚽\nUsa mi código de invitación *$refCode* al activar tu cuenta.';
              Clipboard.setData(ClipboardData(text: shareMsg));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('¡Invitación copiada! Pégala en WhatsApp para tus amigos.'),
                  backgroundColor: Color(0xFF00E676),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  void _openSupportMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.support_agent, color: Color(0xFF00E5FF), size: 28),
                SizedBox(width: 10),
                Text(
                  'Soporte Directo & CEO',
                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Selecciona tu consulta para abrir chat directo en WhatsApp:',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 16),
            _buildSupportOption(
              icon: Icons.verified,
              title: 'Contactar directamente al CEO (Ameycar)',
              subtitle: 'Atención VIP, alianzas o consultas especiales',
              message: 'Hola CEO de Ameycar TV, mi usuario es "${AuthService.currentUser?.username ?? "cliente"}" y deseo comunicarme directamente contigo.',
            ),
            const SizedBox(height: 10),
            _buildSupportOption(
              icon: Icons.autorenew,
              title: 'Renovar o activar suscripción',
              subtitle: 'Adquirir PIN o validar comprobante de pago',
              message: 'Hola Ameycar TV, deseo renovar mi cuenta (${AuthService.currentUser?.username ?? "cliente"}).',
            ),
            const SizedBox(height: 10),
            _buildSupportOption(
              icon: Icons.wifi_tethering_error_rounded,
              title: 'Reportar señal o pedir Reset HW',
              subtitle: 'Soporte técnico inmediato en mi pantalla',
              message: 'Hola soporte Ameycar TV, necesito ayuda técnica con mi usuario (${AuthService.currentUser?.username ?? "cliente"}).',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSupportOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required String message,
  }) {
    return InkWell(
      onTap: () async {
        Navigator.pop(context);
        const phoneNumber = "51905823660";
        final url = Uri.parse("whatsapp://send?phone=$phoneNumber&text=${Uri.encodeComponent(message)}");
        try {
          if (await canLaunchUrl(url)) {
            await launchUrl(url);
          } else {
            final webUrl = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(message)}");
            await launchUrl(webUrl, mode: LaunchMode.externalApplication);
          }
        } catch (e) {
          debugPrint("Error abriendo WhatsApp: $e");
        }
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF00E5FF).withOpacity(0.12), shape: BoxShape.circle),
              child: Icon(icon, color: const Color(0xFF00E5FF), size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 14),
          ],
        ),
      ),
    );
  }

  Future<String?> _processAutomaticReferralReward(String rawRefCode) async {
    final code = rawRefCode.trim().toUpperCase();
    if (code.isEmpty || !AuthService.isFirebaseAvailable) return null;

    final currentUser = AuthService.currentUser;
    if (currentUser == null) return null;

    try {
      final myDoc = await FirebaseFirestore.instance.collection('users').doc(currentUser.id).get();
      if (myDoc.exists && (myDoc.data()?['alreadyUsedReferral'] == true)) {
        return 'Nota: Tu cuenta ya utilizó un código de invitación anteriormente.';
      }

      final query = await FirebaseFirestore.instance
          .collection('users')
          .where('referralCode', isEqualTo: code)
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        return 'Código de referido no encontrado (tu PIN sí fue aplicado).';
      }

      final inviterDoc = query.docs.first;
      if (inviterDoc.id == currentUser.id) {
        return 'No puedes usar tu propio código de invitación.';
      }

      final inviterData = inviterDoc.data();
      DateTime baseExp = DateTime.now();
      if (inviterData['expirationDate'] != null) {
        final parsed = DateTime.tryParse(inviterData['expirationDate'].toString());
        if (parsed != null && parsed.isAfter(DateTime.now())) {
          baseExp = parsed;
        }
      }

      final newInviterExp = baseExp.add(const Duration(days: 15));
      final prevCount = (inviterData['referralsCount'] is int) ? inviterData['referralsCount'] as int : 0;

      await FirebaseFirestore.instance.collection('users').doc(inviterDoc.id).update({
        'expirationDate': newInviterExp.toIso8601String(),
        'isActive': true,
        'referralsCount': prevCount + 1,
      });

      await FirebaseFirestore.instance.collection('users').doc(currentUser.id).set({
        'alreadyUsedReferral': true,
        'referredByCode': code,
        'referredByUser': inviterData['username'] ?? '',
      }, SetOptions(merge: true));

      return '🎁 ¡Tu amigo "${inviterData['username'] ?? 'Embajador'}" acaba de recibir +15 DÍAS GRATIS automáticamente!';
    } catch (e) {
      debugPrint('Error procesando recompensa automática: $e');
      return null;
    }
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
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.notifications_off_outlined, color: Colors.white24, size: 48),
                          SizedBox(height: 12),
                          Text(
                            'No tienes recordatorios activos',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
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
                        final parts = alarmId.split('||');
                        final channelName = parts.isNotEmpty ? parts[0] : alarmId.split('-').first;
                        final programTitle = parts.length > 1
                            ? parts[1]
                            : (alarmId.split('-').length > 1 ? alarmId.split('-')[1] : alarmId);
                        final programTime = parts.length > 2
                            ? parts[2]
                            : (alarmId.split('-').length > 2 ? alarmId.split('-')[2] : '');
                        final savedUrl = parts.length > 3 ? parts[3] : '';

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: const Color(0x33FFB703)),
                          ),
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(ctx);
                              _tuneChannelFromAlarmPayload(jsonEncode({
                                'name': channelName,
                                'url': savedUrl,
                              }));
                            },
                            child: Row(
                              children: [
                                const Icon(Icons.alarm, color: Color(0xFFFFB703), size: 20),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        programTitle,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                      ),
                                      Text(
                                        '$channelName ${programTime.isNotEmpty ? "• $programTime" : ""}',
                                        style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  onPressed: () async {
                                    final int notificationId = alarmId.hashCode.abs() % 2147483647;
                                    await NotificationService.cancelAlarm(notificationId);
                                    setState(() => _activeAlarms.remove(alarmId));
                                    setModalState(() {});
                                    final prefs = await SharedPreferences.getInstance();
                                    await prefs.setStringList('saved_active_alarms', _activeAlarms.toList());
                                  },
                                ),
                              ],
                            ),
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
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
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
                  Expanded(
                    child: Row(
                      children: [
                        _buildChannelLogo(channel, true),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                channel.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15.5),
                              ),
                              Text(
                                'Guía EPG en Tiempo Real • 🕒 $_currentTime',
                                style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white54),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(color: Colors.white12, height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Toca el reloj para programar auto-sintonía:',
                    style: TextStyle(color: Colors.white60, fontSize: 11.5),
                  ),
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      _openActiveAlarmsManagerModal();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0x22FFB703),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFFB703), width: 0.8),
                      ),
                      child: Text(
                        '⏰ ${_activeAlarms.length} activas',
                        style: const TextStyle(color: Color(0xFFFFB703), fontSize: 11, fontWeight: FontWeight.bold),
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
                    final alarmId =
                        '${channel.name}||${prog.title}||${prog.timeFormatted}||${channel.streamUrl}';
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
                                Text(prog.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                                Text(prog.timeFormatted, style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11)),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              isNow ? Icons.play_circle : (hasAlarm ? Icons.alarm_on : Icons.alarm_add),
                              color: isNow ? const Color(0xFF00E5FF) : (hasAlarm ? const Color(0xFFFFB703) : Colors.white38),
                            ),
                            onPressed: () async {
                              if (isNow) {
                                Navigator.pop(ctx);
                                _changeChannel(channel);
                                return;
                              }
                              final prefs = await SharedPreferences.getInstance();
                              final startTimeStr = prog.timeFormatted.split(' - ')[0];
                              final targetTime = _parseProgramStartTime(startTimeStr);
                              final int notificationId = alarmId.hashCode.abs() % 2147483647;

                              if (hasAlarm) {
                                await NotificationService.cancelAlarm(notificationId);
                                setState(() => _activeAlarms.remove(alarmId));
                              } else {
                                if (targetTime != null) {
                                  await NotificationService.scheduleAlarm(
                                    id: notificationId,
                                    title: '⏰ ¡Comienza ${prog.title}!',
                                    body: 'Toca aquí para sintonizar ${channel.name} al instante.',
                                    scheduledDate: targetTime,
                                    channelName: channel.name,
                                    streamUrl: channel.streamUrl,
                                  );
                                }
                                setState(() => _activeAlarms.add(alarmId));
                                if (mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('⏰ Alarma lista: "${prog.title}" en ${channel.name}'),
                                      backgroundColor: const Color(0xFF7B2CBF),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                }
                              }
                              setModalState(() {});
                              await prefs.setStringList('saved_active_alarms', _activeAlarms.toList());
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

  void _openM3uDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCustomEpgUrl = await EpgService.getCustomEpgUrl();
    bool usePublicSatellite = await EpgService.getUsePublicSatelliteConnector();

    final listNameCtrl = TextEditingController();
    final m3uController = TextEditingController();
    final epgController = TextEditingController(text: savedCustomEpgUrl);

    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.playlist_play_rounded, color: Color(0xFF00E5FF), size: 28),
                        const SizedBox(width: 10),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Gestor AMEYCAR: Listas M3U & EPG',
                              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
                            ),
                            Text(
                              'Listas guardadas en este perfil: ${_savedPlaylists.length} / 5',
                              style: const TextStyle(color: Color(0xFFC77DFF), fontSize: 11.5, fontWeight: FontWeight.bold),
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
                const SizedBox(height: 12),

                if (_savedPlaylists.isNotEmpty) ...[
                  const Text(
                    'Tus Listas Guardadas (Toca una para activarla):',
                    style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  ..._savedPlaylists.map((pl) {
                    final bool isActive = pl['isActive'] == true;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: isActive ? const Color(0xFF7B2CBF).withOpacity(0.25) : const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isActive ? const Color(0xFF00E5FF) : Colors.white10,
                          width: isActive ? 1.5 : 1,
                        ),
                      ),
                      child: ListTile(
                        dense: true,
                        leading: Icon(
                          isActive ? Icons.radio_button_checked : Icons.radio_button_off,
                          color: isActive ? const Color(0xFF00E5FF) : Colors.white38,
                        ),
                        title: Text(
                          pl['name'] ?? 'Lista M3U',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        subtitle: Text(
                          pl['url'] ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 19),
                          onPressed: () async {
                            _savedPlaylists.removeWhere((item) => item['id'] == pl['id']);
                            if (_savedPlaylists.isNotEmpty && !_savedPlaylists.any((x) => x['isActive'] == true)) {
                              _savedPlaylists.first['isActive'] = true;
                            }
                            await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
                            await prefs.remove('m3u_cache_${pl['id']}');
                            setModalState(() {});
                            _loadSavedChannels();
                          },
                        ),
                        onTap: () async {
                          for (var item in _savedPlaylists) {
                            item['isActive'] = (item['id'] == pl['id']);
                          }
                          await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
                          if (ctx.mounted) Navigator.pop(ctx);
                          _downloadAndSanitizeM3u(pl['url'], playlistId: pl['id'], playlistName: pl['name']);
                        },
                      ),
                    );
                  }),
                  const Divider(color: Colors.white12, height: 22),
                ],

                if (_savedPlaylists.length < 5) ...[
                  Text(
                    'Agregar Nueva Lista (${_savedPlaylists.length + 1} de 5):',
                    style: const TextStyle(color: Color(0xFF00E676), fontSize: 12.5, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: listNameCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'Nombre de la Lista (Ej: Deportes Premium, Cine 4K)',
                      labelStyle: const TextStyle(color: Colors.white60, fontSize: 11.5),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: m3uController,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      labelText: 'Enlace M3U / M3U8 (http://...)',
                      labelStyle: const TextStyle(color: Colors.white60, fontSize: 11.5),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ] else
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.amber.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'Has alcanzado el máximo de 5 listas guardadas. Elimina alguna arriba si deseas agregar otra.',
                      style: TextStyle(color: Colors.amber, fontSize: 11.5),
                    ),
                  ),

                const SizedBox(height: 14),
                const Text(
                  'Guía EPG XMLTV (Opcional):',
                  style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: epgController,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                  decoration: InputDecoration(
                    hintText: 'https://proveedor.com/xmltv.xml.gz',
                    hintStyle: const TextStyle(color: Colors.white30, fontSize: 11.5),
                    filled: true,
                    fillColor: const Color(0xFF1E293B),
                    isDense: true,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  activeColor: const Color(0xFF00E5FF),
                  title: const Text(
                    'Conector Satelital EPG Automático',
                    style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  value: usePublicSatellite,
                  onChanged: (val) async {
                    setModalState(() => usePublicSatellite = val);
                    await EpgService.setUsePublicSatelliteConnector(val);
                  },
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('GUARDAR Y CARGAR LISTA', style: TextStyle(fontWeight: FontWeight.w900)),
                    onPressed: () async {
                      final url = m3uController.text.trim();
                      final name = listNameCtrl.text.trim().isEmpty
                          ? 'Lista ${_savedPlaylists.length + 1}'
                          : listNameCtrl.text.trim();
                      final customEpg = epgController.text.trim();

                      await EpgService.setCustomEpgUrl(customEpg, syncImmediately: true);

                      if (url.isNotEmpty && _savedPlaylists.length < 5) {
                        final newId = 'pl_${DateTime.now().millisecondsSinceEpoch}';
                        for (var item in _savedPlaylists) {
                          item['isActive'] = false;
                        }
                        _savedPlaylists.add({
                          'id': newId,
                          'name': name,
                          'url': url,
                          'isActive': true,
                        });
                        await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
                        await prefs.setString('saved_m3u_url', url);
                        if (ctx.mounted) Navigator.pop(ctx);
                        _downloadAndSanitizeM3u(url, playlistId: newId, playlistName: name);
                      } else {
                        if (ctx.mounted) Navigator.pop(ctx);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _downloadAndSanitizeM3u(String url, {String? playlistId, String? playlistName}) async {
    setState(() => _isVideoLoading = true);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Sincronizando ${playlistName ?? "lista M3U"} y guía EPG...')),
    );

    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        await EpgService.extractAndSaveEpgUrlFromM3u(res.body);
        final parsed = M3USanitizerService.parseAndSanitize(res.body);
        if (parsed.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('saved_m3u_content', res.body);
          await prefs.setString('saved_m3u_url', url);
          if (playlistId != null) {
            await prefs.setString('m3u_cache_$playlistId', res.body);
          }
          await prefs.setInt('last_played_channel_index', 0);

          setState(() {
            _channels = parsed;
            _selectedChannelIndex = 0;
            _searchQuery = '';
            _isSearching = false;
          });
          _initializeVideo(_channels[0].streamUrl);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('¡${parsed.length} canales activados en "${playlistName ?? "Lista"}"!'),
                backgroundColor: const Color(0xFF00C853),
              ),
            );
          }
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al cargar lista: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isVideoLoading = false);
    }
  }

  List<ChannelModel> get _liveChannels => _channels.where((c) => c.isLive).toList();
  List<ChannelModel> get _movies => _channels.where((c) => c.isMovie).toList();
  List<ChannelModel> get _series => _channels.where((c) => c.isSeries).toList();

  List<String> get _categories {
    final list = _liveChannels.map((c) => c.groupCategory).toSet().toList();
    return ['Favoritos (⭐)', 'Todos', ...list];
  }

  List<ChannelModel> get _filteredChannels {
    return _liveChannels.where((c) {
      final isFavCategory = _selectedCategory == 'Favoritos (⭐)';
      final matchesCategory = isFavCategory
          ? _favoriteChannelUrls.contains(c.streamUrl.trim())
          : (_selectedCategory == 'Todos' || c.groupCategory == _selectedCategory);

      final matchesSearch = _searchQuery.isEmpty ||
          c.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          c.number.toString().contains(_searchQuery) ||
          c.groupCategory.toLowerCase().contains(_searchQuery.toLowerCase());

      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInPipMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: (_videoPlayerController != null && _videoPlayerController!.value.isInitialized)
              ? AspectRatio(
                  aspectRatio: _videoPlayerController!.value.aspectRatio,
                  child: VideoPlayer(_videoPlayerController!),
                )
              : const CircularProgressIndicator(color: Color(0xFF00E5FF)),
        ),
      );
    }

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
          width: 195,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.85),
            border: const Border(right: BorderSide(color: Color(0x337B2CBF))),
          ),
          child: ListView(
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
              _buildSideMenuItem(Icons.alarm_on, 'Alarmas (${_activeAlarms.length})', _openActiveAlarmsManagerModal),
              _buildSideMenuItem(Icons.picture_in_picture_alt_rounded, 'Ventana Flotante', _enterNativePiP),
              _buildSideMenuItem(Icons.forum_outlined, 'Chat / Emojis Vivo', () => setState(() => _showLiveChat = !_showLiveChat)),
              _buildSideMenuItem(Icons.playlist_add, 'Mis Listas (${_savedPlaylists.length}/5)', _openM3uDialog),
              const Divider(color: Colors.white12),
              _buildSideMenuItem(Icons.confirmation_number_outlined, 'Renovar / Pagos', _showRenewSubscriptionModal),
              _buildSideMenuItem(Icons.card_giftcard, 'Gana +15 Días', _showReferralClubModal),
              _buildSideMenuItem(Icons.headset_mic, 'Soporte / CEO', _openSupportMenu),
              _buildSideMenuItem(Icons.settings, 'Configuración', _showSettingsMenu),
              if (AuthService.isAdmin)
                _buildSideMenuItem(Icons.admin_panel_settings, 'Panel Admin VIP', () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
                  );
                }),
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

  Widget _buildTopGlassBar([ChannelModel? activeChannel]) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.92),
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
                    const SizedBox(width: 4),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.red, width: 0.8),
                      ),
                      child: Text(
                        _selectedSection == 'En Vivo' ? 'LIVE' : _selectedSection.toUpperCase(),
                        style: const TextStyle(color: Colors.red, fontSize: 8, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (AuthService.isAdmin) ...[
                          Material(
                            color: const Color(0xFFFFD600),
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
                                ).then((_) {
                                  if (AuthService.currentUser == null) widget.onLogout?.call();
                                });
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.shield, color: Colors.black, size: 14),
                                    SizedBox(width: 4),
                                    Text(
                                      'ADMIN',
                                      style: TextStyle(color: Colors.black, fontSize: 10.5, fontWeight: FontWeight.w900),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],

                        if (AuthService.currentUser?.isPartOfFamily == true) ...[
                          Material(
                            color: const Color(0xFF00E5FF),
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ProfileSelectorScreen(
                                      onLogout: widget.onLogout,
                                      onProfileSelected: () {
                                        Navigator.pop(context);
                                        _loadSavedChannels();
                                      },
                                    ),
                                  ),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.account_circle, color: Colors.black, size: 14),
                                    const SizedBox(width: 4),
                                    Text(
                                      AuthService.currentActiveProfile?.deviceName ?? 'PERFIL',
                                      style: const TextStyle(color: Colors.black, fontSize: 10.5, fontWeight: FontWeight.w900),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],

                        if (AuthService.isFamilyAdmin) ...[
                          Material(
                            color: const Color(0xFFC77DFF),
                            borderRadius: BorderRadius.circular(16),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(16),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => FamilyPanelScreen(onLogout: widget.onLogout)),
                                ).then((_) => setState(() {}));
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.family_restroom, color: Colors.black, size: 14),
                                    SizedBox(width: 4),
                                    Text(
                                      'FAMILIA',
                                      style: TextStyle(color: Colors.black, fontSize: 10.5, fontWeight: FontWeight.w900),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],

                        Material(
                          color: const Color(0xFF00E676),
                          borderRadius: BorderRadius.circular(16),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(16),
                            onTap: _showRenewSubscriptionModal,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.confirmation_number_outlined, color: Colors.black, size: 14),
                                  SizedBox(width: 4),
                                  Text(
                                    'RENOVAR',
                                    style: TextStyle(color: Colors.black, fontSize: 10.5, fontWeight: FontWeight.w900),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),

                        _buildTopBarActionItem(
                          icon: Icons.picture_in_picture_alt_rounded,
                          color: const Color(0xFF00E5FF),
                          tooltip: 'Ventana Flotante (PiP)',
                          onPressed: _enterNativePiP,
                        ),

                        _buildTopBarActionItem(
                          icon: _showLiveChat ? Icons.forum : Icons.forum_outlined,
                          color: _showLiveChat ? const Color(0xFFFFD600) : Colors.white70,
                          tooltip: 'Chat y Emojis en Vivo',
                          onPressed: () => setState(() => _showLiveChat = !_showLiveChat),
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.playlist_add,
                          color: const Color(0xFF00E5FF),
                          tooltip: 'Gestor de Listas M3U (Hasta 5)',
                          onPressed: _openM3uDialog,
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.alarm_on,
                          color: Colors.white,
                          badgeCount: _activeAlarms.length,
                          tooltip: 'Alarmas Activas',
                          onPressed: _openActiveAlarmsManagerModal,
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.search,
                          color: const Color(0xFFC77DFF),
                          tooltip: 'Buscar',
                          onPressed: () => setState(() => _isSearching = true),
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.mic,
                          color: const Color(0xFF00E5FF),
                          isGlowing: true,
                          tooltip: 'Asistente de Voz',
                          onPressed: _startVoiceSearch,
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.headset_mic,
                          color: const Color(0xFF00E676),
                          tooltip: 'Soporte y Contacto CEO',
                          onPressed: _openSupportMenu,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 4),

                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Configuración y Ajustes',
                  icon: const Icon(Icons.settings, color: Colors.white, size: 20),
                  onPressed: _showSettingsMenu,
                ),
              ],
            ),
    );
  }

  Widget _buildTopBarActionItem({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
    int badgeCount = 0,
    bool isGlowing = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            child: isGlowing
                ? Container(
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: color.withOpacity(0.5), blurRadius: 6)],
                    ),
                    child: Icon(icon, color: color, size: 17),
                  )
                : badgeCount > 0
                    ? Badge(
                        label: Text(
                          '$badgeCount',
                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.black),
                        ),
                        backgroundColor: const Color(0xFFFFB703),
                        child: Icon(icon, color: color, size: 18),
                      )
                    : Icon(icon, color: color, size: 18),
          ),
        ),
      ),
    );
  }

  void _showRenewSubscriptionModal() {
    final pinCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    bool isProcessing = false;
    final bool showBanks = _canSeePaymentBanks;
    final currentUser = AuthService.currentActiveProfile ?? AuthService.currentUser;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1320),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.88),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 18,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(showBanks ? Icons.stars : Icons.confirmation_number, color: const Color(0xFFFFD700), size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        showBanks ? 'Renovación de Suscripción VIP' : 'Canjear PIN de Activación',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  showBanks
                      ? 'Extiende tu cuenta individual o familiar sin comisiones.'
                      : 'Ingresa el PIN proporcionado por el titular de tu grupo familiar.',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131A29),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.45), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.confirmation_number, color: Color(0xFF00E5FF), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Activación Automática 24/7 con PIN',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: refCtrl,
                        textCapitalization: TextCapitalization.characters,
                        style: const TextStyle(color: Color(0xFFFFD600), fontSize: 12.5, fontWeight: FontWeight.bold),
                        decoration: InputDecoration(
                          prefixIcon: const Icon(Icons.card_giftcard, color: Color(0xFFFFD600), size: 18),
                          hintText: '¿Te invitó un amigo? Pon su código aquí (Opcional)',
                          hintStyle: const TextStyle(color: Colors.white38, fontSize: 11.5, fontWeight: FontWeight.normal),
                          filled: true,
                          fillColor: Colors.black26,
                          isDense: true,
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: pinCtrl,
                              style: const TextStyle(color: Colors.white, letterSpacing: 1.5, fontWeight: FontWeight.bold),
                              textCapitalization: TextCapitalization.characters,
                              decoration: InputDecoration(
                                hintText: 'PIN: AMEY-30D-XXXX',
                                hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 0),
                                filled: true,
                                fillColor: Colors.black38,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: isProcessing
                                ? null
                                : () async {
                                    final code = pinCtrl.text.trim();
                                    if (code.isEmpty) return;
                                    setModalState(() => isProcessing = true);
                                    final res = await AuthService.redeemActivationPin(code);

                                    String? bonusMsg;
                                    if (res.isSuccess && refCtrl.text.trim().isNotEmpty) {
                                      bonusMsg = await _processAutomaticReferralReward(refCtrl.text.trim());
                                    }

                                    setModalState(() => isProcessing = false);
                                    if (mounted) {
                                      Navigator.pop(ctx);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(bonusMsg != null ? '${res.message}\n$bonusMsg' : res.message),
                                          backgroundColor: res.isSuccess ? const Color(0xFF00C853) : Colors.redAccent,
                                          duration: const Duration(seconds: 5),
                                        ),
                                      );
                                      if (res.isSuccess) setState(() {});
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('Canjear', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                if (showBanks) ...[
                  const SizedBox(height: 18),
                  const Row(
                    children: [
                      Text('🇵🇪 ', style: TextStyle(fontSize: 16)),
                      Text('Pago Nacional (Cero Comisiones):', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentTile(
                    icon: Icons.phone_android,
                    color: const Color(0xFF7B2CBF),
                    title: 'Yape',
                    subtitle: '931573805 • Titular: CARLOS ACOSTA',
                    copyText: '931573805',
                  ),
                  const SizedBox(height: 8),
                  _buildPaymentTile(
                    icon: Icons.account_balance,
                    color: const Color(0xFFFF7043),
                    title: 'BCP - Cuenta Soles',
                    subtitle: '19194759620085 • Titular: ACOSTA NN CARLOS RAFAEL',
                    copyText: '19194759620085',
                  ),
                  const SizedBox(height: 18),
                  const Row(
                    children: [
                      Text('🌎 ', style: TextStyle(fontSize: 16)),
                      Text('Pago Internacional:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentTile(
                    icon: Icons.currency_bitcoin,
                    color: const Color(0xFFFFD700),
                    title: 'Binance Pay (USDT - Inmediato)',
                    subtitle: 'Pay ID: 214778098',
                    copyText: '214778098',
                  ),
                  const SizedBox(height: 8),
                  _buildPaymentTile(
                    icon: Icons.account_balance_wallet,
                    color: const Color(0xFF0072FF),
                    title: 'PayPal',
                    subtitle: 'carlos_87_21@hotmail.com',
                    copyText: 'carlos_87_21@hotmail.com',
                  ),
                  const SizedBox(height: 18),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E283D),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF25D366).withOpacity(0.5), width: 1.5),
                    ),
                    child: Column(
                      children: [
                        const Text(
                          '¿Ya realizaste el pago? Envía tu comprobante y recibe tu PIN al instante:',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white70, fontSize: 11.5),
                        ),
                        const SizedBox(height: 10),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.chat, color: Colors.white, size: 16),
                          label: const Text('Enviar Voucher por WhatsApp', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () async {
                            final refInfo = refCtrl.text.trim().isNotEmpty
                                ? ' | Invitado con código: ${refCtrl.text.trim().toUpperCase()}'
                                : '';
                            final msg =
                                '¡Hola! He realizado una transferencia hoy para renovar mi plan. Mi usuario es: ${currentUser?.username ?? "cliente"}$refInfo. Adjunto mi voucher de pago.';
                            Clipboard.setData(ClipboardData(text: msg));

                            const phoneNumber = "51905823660";
                            final url = Uri.parse("whatsapp://send?phone=$phoneNumber&text=${Uri.encodeComponent(msg)}");
                            try {
                              if (await canLaunchUrl(url)) {
                                await launchUrl(url);
                              } else {
                                final webUrl = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(msg)}");
                                await launchUrl(webUrl, mode: LaunchMode.externalApplication);
                              }
                            } catch (_) {}
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String copyText,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: color.withOpacity(0.2), borderRadius: BorderRadius.circular(8)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, color: Color(0xFF00E5FF), size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copyText));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¡Copiado: $copyText!'), duration: const Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
    );
  }

  void _showAccountProfileModal() async {
    final user = AuthService.currentUser;
    final hwId = await AuthService.getDeviceHardwareId();
    final avatarIcons = [Icons.person, Icons.stars, Icons.movie, Icons.sports_soccer, Icons.rocket_launch];
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: const Color(0xFF7B2CBF),
                    child: Icon(avatarIcons[_customAvatarIdx % avatarIcons.length], color: Colors.white),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Perfil: ${user?.username ?? "Invitado"}',
                      style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (user?.isVip == true)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(color: const Color(0xFFFFD600), borderRadius: BorderRadius.circular(6)),
                      child: const Text('VIP', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w900, fontSize: 11)),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              const Text('Elegir Ícono / Foto de Perfil:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: List.generate(avatarIcons.length, (i) {
                  final sel = _customAvatarIdx == i;
                  return GestureDetector(
                    onTap: () async {
                      final prefs = await SharedPreferences.getInstance();
                      await prefs.setInt('custom_avatar_$_currentProfileId', i);
                      setState(() => _customAvatarIdx = i);
                      setModalState(() {});
                    },
                    child: CircleAvatar(
                      radius: 22,
                      backgroundColor: sel ? const Color(0xFF00E5FF) : Colors.white10,
                      child: Icon(avatarIcons[i], color: sel ? Colors.black : Colors.white70),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Estado: ${user?.isActive == true ? "ACTIVO" : "INACTIVO"} • Días restantes: ${user?.daysRemaining ?? 0}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Hardware ID Celular: $hwId',
                      style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontFamily: 'monospace'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    _videoPlayerController?.pause();
                    await _syncAutoPipState(false);
                    await AuthService.logout();
                    widget.onLogout?.call();
                  },
                  icon: const Icon(Icons.logout, color: Color(0xFFFF5252), size: 18),
                  label: const Text('Cerrar Sesión', style: TextStyle(color: Color(0xFFFF5252))),
                  style: OutlinedButton.styleFrom(side: const BorderSide(color: Color(0xFFFF5252))),
                ),
              ),
            ],
          ),
        ),
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
            onChanged: (val) => setState(() => _searchQuery = val.trim()),
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
    return Padding(padding: const EdgeInsets.all(8.0), child: _buildActiveSearchBar());
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
                border: isSelected ? const Border(bottom: BorderSide(color: Color(0xFFC77DFF), width: 2)) : null,
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
          colors: [Color(0xFF070A10), Color(0xFF131B2E), Color(0xFF090D16)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF0F172A),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.45)),
              ),
              child: _buildChannelLogo(activeChannel, true),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('CH $chNum • SINTONIZANDO...', style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 10, fontWeight: FontWeight.w900)),
                  const SizedBox(height: 4),
                  Text(activeChannel.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
                  Text(currentProg.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPlayerSection(ChannelModel? activeChannel) {
    final isReady = !_isVideoLoading &&
        !_hasVideoError &&
        _videoPlayerController != null &&
        _videoPlayerController!.value.isInitialized;

    final safeChannelId = (activeChannel?.name ?? 'general').replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

    return GestureDetector(
      onTap: _toggleOsd,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity != null) {
          if (details.primaryVelocity! < -120) _nextChannel();
          if (details.primaryVelocity! > 120) _previousChannel();
        }
      },
      onDoubleTap: () => setState(() => _isFullScreenMode = !_isFullScreenMode),
      child: Container(
        height: 225,
        width: double.infinity,
        color: const Color(0xFF070A10),
        child: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
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
                              const Text('Señal no disponible temporalmente', style: TextStyle(color: Colors.white54, fontSize: 12)),
                              const SizedBox(height: 8),
                              ElevatedButton.icon(
                                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF7B2CBF)),
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

            if (_showLiveChat && activeChannel != null)
              Positioned.fill(
                child: LiveChatOverlay(
                  channelId: safeChannelId,
                  channelName: activeChannel.name,
                ),
              ),

            if (_showOsd && activeChannel != null && !_showLiveChat)
              ZappingChannelOverlay(
                channel: activeChannel,
                channelIndex: _selectedChannelIndex,
                totalChannels: _channels.length,
                isPlaying: _videoPlayerController != null && _videoPlayerController!.value.isPlaying,
                onPlayPause: () {
                  if (_videoPlayerController != null) {
                    setState(() {
                      _videoPlayerController!.value.isPlaying
                          ? _videoPlayerController!.pause()
                          : _videoPlayerController!.play();
                    });
                  }
                },
                onNext: _nextChannel,
                onPrevious: _previousChannel,
                onOpenEpg: () => _openEpgScheduleModal(activeChannel),
                onToggleFullScreen: () => setState(() => _isFullScreenMode = true),
              ),

            if (_showOsd)
              Positioned(
                top: 8,
                right: 8,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMiniPlayerPillButton(
                      icon: _showLiveChat ? Icons.forum : Icons.emoji_emotions_outlined,
                      label: _showLiveChat ? 'Cerrar Chat' : 'Vivo 💬',
                      color: _showLiveChat ? const Color(0xFFFFD600) : Colors.black54,
                      textColor: _showLiveChat ? Colors.black : Colors.white,
                      onTap: () => setState(() => _showLiveChat = !_showLiveChat),
                    ),
                    const SizedBox(width: 6),
                    _buildMiniPlayerPillButton(
                      icon: Icons.picture_in_picture_alt_rounded,
                      label: 'Flotar',
                      color: Colors.black54,
                      textColor: const Color(0xFF00E5FF),
                      onTap: _enterNativePiP,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniPlayerPillButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: textColor, size: 14),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: textColor, fontSize: 10.5, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveEpgCard(ChannelModel? activeChannel) {
    if (activeChannel == null) return const SizedBox.shrink();

    return ValueListenableBuilder<int>(
      valueListenable: EpgService.epgUpdateNotifier,
      builder: (context, _, __) {
        final currentProg = EpgService.getCurrentProgram(activeChannel.name, activeChannel.groupCategory);
        final nextProg = EpgService.getNextProgram(activeChannel.name, activeChannel.groupCategory);
        final isSyncing = EpgService.isChannelSyncing(activeChannel.name);

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
                          Icon(
                            isSyncing ? Icons.radar : Icons.live_tv,
                            color: isSyncing ? const Color(0xFFFFB703) : Colors.redAccent,
                            size: 14,
                          ),
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
                    Text(currentProg.timeFormatted, style: const TextStyle(color: Color(0xFFC77DFF), fontSize: 11, fontWeight: FontWeight.bold)),
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
                    Text('Quedan ${currentProg.remainingMinutes} min', style: const TextStyle(color: Colors.white54, fontSize: 10)),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: currentProg.progress,
                    backgroundColor: const Color(0xFF1E293B),
                    valueColor: AlwaysStoppedAnimation<Color>(isSyncing ? const Color(0xFFFFB703) : const Color(0xFF9D4EDD)),
                    minHeight: 3,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
                border: Border.all(color: isSelected ? const Color(0xFFC77DFF) : Colors.white10),
              ),
              child: Center(
                child: Text(
                  category,
                  style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal),
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
        child: Text(
          _searchQuery.isNotEmpty
              ? 'No se encontraron canales para "$_searchQuery"'
              : 'No hay canales disponibles en esta categoría',
          style: const TextStyle(color: Colors.white54, fontSize: 12),
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
        final isFav = _favoriteChannelUrls.contains(channel.streamUrl.trim());

        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: isSelected ? const Color(0xFF1E293B).withOpacity(0.9) : const Color(0xFF0F172A).withOpacity(0.4),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isSelected ? const Color(0xFF9D4EDD) : Colors.transparent),
          ),
          child: ListTile(
            dense: true,
            leading: _buildChannelLogo(channel, isSelected),
            title: Text(
              channel.name,
              style: TextStyle(color: isSelected ? const Color(0xFFC77DFF) : Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
            ),
            subtitle: Text('Grupo: ${channel.groupCategory} • ${channel.resolution}', style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10)),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: Icon(
                    isFav ? Icons.star : Icons.star_border,
                    color: const Color(0xFFFFD600),
                    size: 20,
                  ),
                  onPressed: () => _toggleFavorite(channel),
                ),
                if (isSelected)
                  const Icon(Icons.volume_up, color: Color(0xFFC77DFF), size: 18),
              ],
            ),
            onTap: () => _changeChannel(channel),
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
        decoration: BoxDecoration(color: Colors.black.withOpacity(0.4), borderRadius: BorderRadius.circular(6)),
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
      child: Text('${channel.number}', style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)),
    );
  }

  Widget _buildImmersivePlayer(ChannelModel? activeChannel) {
    final isReady = !_isVideoLoading &&
        !_hasVideoError &&
        _videoPlayerController != null &&
        _videoPlayerController!.value.isInitialized;

    final safeChannelId = (activeChannel?.name ?? 'general').replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_');

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
              duration: const Duration(milliseconds: 140),
              child: isReady
                  ? Center(
                      key: ValueKey<String>(activeChannel?.streamUrl ?? 'immersive_video'),
                      child: AspectRatio(
                        aspectRatio: _videoPlayerController!.value.aspectRatio,
                        child: VideoPlayer(_videoPlayerController!),
                      ),
                    )
                  : _buildSmoothTuningTransition(activeChannel),
            ),

            if (_showLiveChat && activeChannel != null)
              Positioned.fill(
                child: LiveChatOverlay(
                  channelId: safeChannelId,
                  channelName: activeChannel.name,
                ),
              ),

            if (_showOsd && activeChannel != null && !_showLiveChat)
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
                        _videoPlayerController!.value.isPlaying
                            ? _videoPlayerController!.pause()
                            : _videoPlayerController!.play();
                      });
                    }
                  },
                  onNext: _nextChannel,
                  onPrevious: _previousChannel,
                  onOpenEpg: () => _openEpgScheduleModal(activeChannel),
                  onToggleFullScreen: () => setState(() => _isFullScreenMode = false),
                ),
              ),

            if (_showOsd)
              Positioned(
                top: 24,
                right: 24,
                child: Row(
                  children: [
                    _buildMiniPlayerPillButton(
                      icon: Icons.forum,
                      label: _showLiveChat ? 'Ocultar Chat' : 'Chat Vivo 🔥',
                      color: _showLiveChat ? const Color(0xFFFFD600) : Colors.black54,
                      textColor: _showLiveChat ? Colors.black : Colors.white,
                      onTap: () => setState(() => _showLiveChat = !_showLiveChat),
                    ),
                    const SizedBox(width: 8),
                    _buildMiniPlayerPillButton(
                      icon: Icons.picture_in_picture_alt_rounded,
                      label: 'PiP Flotante',
                      color: Colors.black54,
                      textColor: const Color(0xFF00E5FF),
                      onTap: _enterNativePiP,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
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
                  ],
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
    WidgetsBinding.instance.removeObserver(this);
    _syncAutoPipState(false);
    WakelockPlus.disable();
    _accountGuardSub?.cancel();
    _alarmTapSub?.cancel();
    _clockTimer?.cancel();
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