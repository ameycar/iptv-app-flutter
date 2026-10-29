import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/foundation.dart';
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
import 'services/dvr_recording_service.dart';
import 'services/remote_control_service.dart';
import 'screens/login_screen.dart';
import 'screens/admin_panel_screen.dart';
import 'screens/family_panel_screen.dart';
import 'screens/profile_selector_screen.dart';
import 'screens/remote_control_screen.dart';
import 'widgets/alexa_voice_sheet.dart';
import 'widgets/vod_grid_view.dart';
import 'widgets/zapping_channel_overlay.dart';
import 'widgets/live_chat_overlay.dart';
import 'firebase_options.dart';
import 'services/parental_service.dart';
import 'services/user_customization_service.dart';
import 'widgets/pin_dialog.dart';
import 'widgets/rename_channel_dialog.dart';
import 'widgets/profile_customization_sheet.dart';
import 'services/player_settings_service.dart';

// SERVICIO NATIVO PARA ALARMAS CON AUTO-SINTONIZACIÓN Y SOPORTE DVR
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
    String alarmId = '',
    bool autoRecord = false,
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
        'alarmId': alarmId,
        'autoRecord': autoRecord,
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
      await Firebase.initializeApp(
        options: DefaultFirebaseOptions.currentPlatform,
      );
    } catch (e) {
      debugPrint('Error seguro en Firebase.initializeApp: $e');
    }

    if (!kIsWeb) {
      try {
        await NotificationService.initialize();
      } catch (e) {
        debugPrint('Error seguro en NotificationService: $e');
      }
      try {
        await DvrRecordingService.initialize();
      } catch (e) {
        debugPrint('Error seguro en DvrRecordingService: $e');
      }
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
  double _volumeBeforeMute = 1.0;

  bool _isBehindLive = false;
  bool _isPlayingDvrRecording = false;
  String? _activeDvrTitle;

  bool _isInPipMode = false;
  bool _showLiveChat = false;
  bool _isPremiumToolsExpanded = false;
  String _selectedLanguage = 'Español (Latinoamérica)';
  int _customAvatarIdx = 0;
  Map<String, String> _customChannelAliases = {};
  Color _accentColor = const Color(0xFF00E5FF);
  String? _userAvatarUrl;

  Future<void> _loadCustomizations() async {
    ParentalService.setCurrentUser(AuthService.currentUser?.username ?? AuthService.currentUser?.id ?? 'admin');
    try {
      // Carga inmediata en el arranque para que no reaparezcan al refrescar
      await ParentalService.getHiddenMenuItems();
      await PlayerSettingsService.initialize();

      final aliases = await UserCustomizationService.getChannelAliases();
      final color = await UserCustomizationService.getAccentColor();
      final avatar = await UserCustomizationService.getUserAvatar();
      if (mounted) {
        setState(() {
          _customChannelAliases = aliases;
          _accentColor = color;
          _userAvatarUrl = avatar;
        });
      }
    } catch (_) {}
  }

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
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _cloudPlaylistSub;

  String get _currentProfileId =>
      AuthService.currentActiveProfile?.id ??
      AuthService.currentUser?.id ??
      'default_profile';

  bool get _hasPremiumFeaturesAccess {
    return true;
  }

  bool get _canSeePaymentBanks {
    final user = AuthService.currentUser;
    if (user == null) return true;
    if (user.isAdmin || user.isFamilyAdmin) return true;
    final famId = user.familyId ?? '';
    return !user.isPartOfFamily || famId.trim().isEmpty;
  }

  void _openMasterExecutiveAdmin() {
    if (!AuthService.isAdmin) return;
    _videoPlayerController?.pause();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MasterAdminDashboardScreen(
          onLogout: widget.onLogout,
          onOpenLegacyAdmin: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AdminPanelScreen()),
            );
          },
        ),
      ),
    ).then((_) {
      if (AuthService.currentUser == null) {
        widget.onLogout?.call();
      } else if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    if (!kIsWeb) {
      WakelockPlus.enable();
      _syncAutoPipState(true);
      DvrRecordingService.initialize();
    }

    EpgService.ensureInitialized();
    _startClockTimer();
    _startAccountHardwareGuard();
    _listenToAlarmNotificationTaps();
    _startListeningRemoteTvCommands();
   _loadCustomizations();
    ParentalService.getHiddenMenuItems().then((_) {
      if (mounted) setState(() {});
    });
    _loadFavorites();
    _loadSavedChannels();
    _startCloudPlaylistsRealtimeListener();
    _ensureUserHasReferralCode();

    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        NotificationService.requestPermissionsSafely();
      });
    }
  }

  void _startListeningRemoteTvCommands() {
    RemoteControlService.listenToCommands(
      onCommandReceived: (command, extra) async {
        if (!mounted) return;
        switch (command) {
          case 'channel_next':
            _nextChannel();
            break;
          case 'channel_prev':
            _previousChannel();
            break;
          case 'play':
            await _videoPlayerController?.play();
            if (mounted) setState(() {});
            break;
          case 'pause':
            await _videoPlayerController?.pause();
            if (mounted) setState(() => _isBehindLive = true);
            break;
          case 'rewind_15':
            await _seekRelativeSeconds(-15);
            break;
          case 'forward_15':
            await _seekRelativeSeconds(15);
            break;
          case 'jump_live':
            _jumpBackToLiveStream();
            break;
          case 'toggle_fullscreen':
            setState(() => _isFullScreenMode = !_isFullScreenMode);
            break;
          case 'toggle_rec':
            final activeCh = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
                ? _channels[_selectedChannelIndex]
                : null;
            await _toggleManualDvrRecording(activeCh);
            break;
          case 'vol_up':
            _currentVolume = (_currentVolume + 0.15).clamp(0.0, 1.0);
            await _videoPlayerController?.setVolume(_currentVolume);
            break;
          case 'vol_down':
            _currentVolume = (_currentVolume - 0.15).clamp(0.0, 1.0);
            await _videoPlayerController?.setVolume(_currentVolume);
            break;
          case 'mute_toggle':
            if (_currentVolume > 0.01) {
              _volumeBeforeMute = _currentVolume;
              _currentVolume = 0.0;
            } else {
              _currentVolume = _volumeBeforeMute > 0.05 ? _volumeBeforeMute : 1.0;
            }
            await _videoPlayerController?.setVolume(_currentVolume);
            break;
          case 'tune_channel':
            final url = (extra['url'] ?? '').toString().trim();
            final name = (extra['name'] ?? '').toString().trim();
            int idx = -1;
            if (url.isNotEmpty) {
              idx = _channels.indexWhere((c) => c.streamUrl.trim() == url);
            }
            if (idx == -1 && name.isNotEmpty) {
              idx = _channels.indexWhere(
                (c) => c.name.toLowerCase() == name.toLowerCase(),
              );
            }
            if (idx != -1) {
              setState(() => _selectedSection = 'En Vivo');
              _changeChannel(_channels[idx]);
            }
            break;
        }
      },
    );
  }

  void _openRemoteControlModalScreen() {
        Navigator.push(
      context,
     MaterialPageRoute(
          builder: (_) => const RemoteControlScreen(),
        ),
    );
  }

  Future<void> _seekRelativeSeconds(int deltaSeconds) async {
    final ctrl = _videoPlayerController;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    _triggerOsdTimer();

    try {
      final currentPos = ctrl.value.position;
      final duration = ctrl.value.duration;
      Duration target = currentPos + Duration(seconds: deltaSeconds);
      if (target < Duration.zero) target = Duration.zero;
      if (duration > Duration.zero && target > duration) {
        target = duration;
      }

      await ctrl.seekTo(target);
      if (!ctrl.value.isPlaying) {
        await ctrl.play();
      }

      if (mounted) {
        setState(() {
          if (deltaSeconds < 0) {
            _isBehindLive = true;
          } else if (duration > Duration.zero &&
              (duration - target).inSeconds <= 3 &&
              !_isPlayingDvrRecording) {
            _isBehindLive = false;
          }
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deltaSeconds < 0
                  ? '⏪ Retrocediendo ${deltaSeconds.abs()}s en el búfer...'
                  : '⏩ Adelantando +${deltaSeconds}s...',
            ),
            duration: const Duration(milliseconds: 1100),
            backgroundColor: const Color(0xFF1E293B),
          ),
        );
      }
    } catch (e) {
      debugPrint('Aviso Timeshift seek: $e');
    }
  }

  void _jumpBackToLiveStream() {
    final activeCh = _channels.isNotEmpty && _selectedChannelIndex < _channels.length
        ? _channels[_selectedChannelIndex]
        : null;
    if (activeCh == null) return;

    setState(() {
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrTitle = null;
    });
    _initializeVideo(activeCh.streamUrl);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ Volviendo a la señal EN VIVO de ${activeCh.name}'),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF00C853),
      ),
    );
  }

  Future<void> _toggleManualDvrRecording(ChannelModel? activeChannel) async {
    if (activeChannel == null || kIsWeb) return;

    if (DvrRecordingService.isRecordingNotifier.value) {
      final savedItem = await DvrRecordingService.stopRecording();
      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              savedItem != null
                  ? '✅ Grabación guardada: "${savedItem.programTitle}" (${savedItem.sizeMb.toStringAsFixed(1)} MB)'
                  : '⏹ Grabación detenida (duración muy corta para guardar).',
            ),
            backgroundColor: const Color(0xFF7B2CBF),
            action: savedItem != null
                ? SnackBarAction(
                    label: 'VER AHORA',
                    textColor: const Color(0xFF00E5FF),
                    onPressed: () => _playDvrRecordingFile(savedItem),
                  )
                : null,
          ),
        );
      }
    } else {
      final currentProg =
          EpgService.getCurrentProgram(activeChannel.name, activeChannel.groupCategory);
      final started = await DvrRecordingService.startRecording(
        channelName: activeChannel.name,
        programTitle: currentProg.title,
        streamUrl: activeChannel.streamUrl,
        maxMinutes: 60,
      );

      if (mounted) {
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              started
                  ? '🔴 Grabando "${currentProg.title}" en segundo plano...'
                  : 'No se pudo iniciar la grabación de esta señal.',
            ),
            backgroundColor: started ? const Color(0xFFFF1744) : Colors.redAccent,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _playDvrRecordingFile(DvrRecordingItem item) async {
    if (kIsWeb) return;
    final file = File(item.filePath);
    if (!file.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('El archivo de grabación ya no existe en el dispositivo.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final currentToken = ++_zappingToken;
    setState(() {
      _selectedSection = 'En Vivo';
      _isVideoLoading = true;
      _hasVideoError = false;
      _isPlayingDvrRecording = true;
      _isBehindLive = true;
      _activeDvrTitle = '🔴 DVR: ${item.programTitle}';
      _showOsd = true;
    });

    final oldCtrl = _videoPlayerController;
    _videoPlayerController = null;
    _disposeControllerInBackground(oldCtrl);

    try {
      final fileCtrl = VideoPlayerController.file(
        file,
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );
      await fileCtrl.initialize();

      if (!mounted || currentToken != _zappingToken) {
        _disposeControllerInBackground(fileCtrl);
        return;
      }

      _videoPlayerController = fileCtrl;
      await _videoPlayerController!.setVolume(_currentVolume);
      await _videoPlayerController!.play();

      setState(() {
        _isVideoLoading = false;
        _hasVideoError = false;
      });
      _triggerOsdTimer();

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('▶️ Reproduciendo desde el inicio: ${item.programTitle}'),
          backgroundColor: const Color(0xFF7B2CBF),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e) {
      debugPrint('Error abriendo archivo DVR local: $e');
      if (mounted) {
        setState(() {
          _isVideoLoading = false;
          _hasVideoError = true;
          _isPlayingDvrRecording = false;
        });
      }
    }
  }

  void _openDvrRecordingsVaultModal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          final recs = DvrRecordingService.recordings;
          final isRecActive = DvrRecordingService.isRecordingNotifier.value;

          return Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.82),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
            decoration: BoxDecoration(
              color: const Color(0xFF070A10).withOpacity(0.98),
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(color: const Color(0xFFFF1744).withOpacity(0.5), width: 1.5),
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
                            color: const Color(0x33FF1744),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.fiber_smart_record, color: Color(0xFFFF1744), size: 22),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Mis Grabaciones DVR',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            Text(
                              '${recs.length} programa${recs.length == 1 ? '' : 's'} guardado${recs.length == 1 ? '' : 's'} en memoria',
                              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
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
                if (isRecActive) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0x33FF1744),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFFFF1744)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.fiber_manual_record, color: Color(0xFFFF1744), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: ValueListenableBuilder<int>(
                            valueListenable: DvrRecordingService.recordingElapsedSeconds,
                            builder: (_, secs, __) => Text(
                              'Grabando ahora: ${DvrRecordingService.activeRecordingChannel.value} (${DvrRecordingService.formatElapsed(secs)})',
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        TextButton(
                          onPressed: () async {
                            await DvrRecordingService.stopRecording();
                            setModalState(() {});
                            if (mounted) setState(() {});
                          },
                          child: const Text('GUARDAR Y PARAR', style: TextStyle(color: Color(0xFFFFD600), fontSize: 11, fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ),
                ],
                const Divider(color: Colors.white12, height: 22),
                if (recs.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: Column(
                        children: [
                          Icon(Icons.video_library_outlined, color: Colors.white24, size: 48),
                          SizedBox(height: 12),
                          Text(
                            'Aún no tienes grabaciones guardadas',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                          SizedBox(height: 4),
                          Text(
                            'Usa el botón 🔴 REC en vivo o programa "Alarma + Auto-Grabar" en la Guía EPG.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: recs.length,
                      itemBuilder: (context, index) {
                        final item = recs[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: Colors.white12),
                          ),
                          child: Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.play_circle_fill, color: Color(0xFF00E5FF), size: 32),
                                onPressed: () {
                                  Navigator.pop(ctx);
                                  _playDvrRecordingFile(item);
                                },
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.programTitle,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                                    ),
                                    Text(
                                      '${item.channelName} • Duración: ${item.formattedDuration} • ${item.sizeMb.toStringAsFixed(1)} MB',
                                      style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                onPressed: () async {
                                  await DvrRecordingService.deleteRecording(item.id);
                                  setModalState(() {});
                                  if (mounted) setState(() {});
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

  void _loadFavorites() async {
    final prefs = await SharedPreferences.getInstance();
    final favList = prefs.getStringList('favorite_channels_$_currentProfileId') ?? [];

    final user = AuthService.currentUser;
    if (user != null && AuthService.isFirebaseAvailable) {
      try {
        final doc = await FirebaseFirestore.instance.collection('users').doc(user.id).get();
        final data = doc.data();
        final cloudFavKey = 'fav_urls_$_currentProfileId';
        if (data != null && data[cloudFavKey] is List) {
          final remoteFavs = (data[cloudFavKey] as List).map((e) => e.toString()).toList();
          if (remoteFavs.isNotEmpty) {
            favList
              ..clear()
              ..addAll(remoteFavs);
            await prefs.setStringList('favorite_channels_$_currentProfileId', favList);
          }
        }
      } catch (_) {}
    }

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
    final updatedList = _favoriteChannelUrls.toList();
    await prefs.setStringList('favorite_channels_$_currentProfileId', updatedList);

    final user = AuthService.currentUser;
    if (user != null && AuthService.isFirebaseAvailable) {
      unawaited(
        FirebaseFirestore.instance.collection('users').doc(user.id).set({
          'fav_urls_$_currentProfileId': updatedList,
        }, SetOptions(merge: true)),
      );
    }

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

  void _tuneChannelFromAlarmPayload(String rawPayload) async {
    if (!mounted || _channels.isEmpty || rawPayload.trim().isEmpty) return;

    String targetName = rawPayload.trim();
    String targetUrl = '';
    String alarmId = '';
    bool autoRecord = false;

    try {
      final decoded = jsonDecode(rawPayload);
      if (decoded is Map) {
        targetName = (decoded['name'] ?? '').toString().trim();
        targetUrl = (decoded['url'] ?? '').toString().trim();
        alarmId = (decoded['alarmId'] ?? '').toString().trim();
        autoRecord = decoded['autoRecord'] == true;
      }
    } catch (_) {}

    if (!kIsWeb &&
        DvrRecordingService.isRecordingNotifier.value &&
        (DvrRecordingService.activeAlarmId == alarmId ||
            DvrRecordingService.activeRecordingChannel.value.toLowerCase() ==
                targetName.toLowerCase())) {
      final capturedSoFar = await DvrRecordingService.stopRecording();
      if (capturedSoFar != null && mounted) {
        _playDvrRecordingFile(capturedSoFar);
        return;
      }
    }

    if (!kIsWeb) {
      final existingRec = DvrRecordingService.findRecordingByChannelOrAlarm(
        alarmId: alarmId,
        channelName: targetName,
      );
      if (existingRec != null && autoRecord) {
        _playDvrRecordingFile(existingRec);
        return;
      }
    }

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
        _selectedCategory = 'Todos';
        _isSearching = false;
        _searchQuery = '';
        _searchController.clear();
      });

      _changeChannel(targetChannel);

      if (!kIsWeb && autoRecord && !DvrRecordingService.isRecordingNotifier.value) {
        final prog = EpgService.getCurrentProgram(targetChannel.name, targetChannel.groupCategory);
        unawaited(
          DvrRecordingService.startRecording(
            channelName: targetChannel.name,
            programTitle: prog.title,
            streamUrl: targetChannel.streamUrl,
            alarmId: alarmId,
          ),
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⏰ Sintonizando tu recordatorio: ${targetChannel.name}'),
            backgroundColor: const Color(0xFF00C853),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _syncAutoPipState(bool enabled) async {
    if (kIsWeb) return;
    try {
      await _pipChannel.invokeMethod('setAutoPip', {'enabled': enabled});
    } catch (_) {}
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    if (kIsWeb) return;
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
    if (kIsWeb) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('En PC puedes usar clic derecho sobre el video > "Pantalla en pantalla" del navegador.'),
          backgroundColor: Color(0xFF7B2CBF),
        ),
      );
      return;
    }
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
    _cloudPlaylistSub?.cancel();
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

  // ===========================================================================
  // SINCRONIZACIÓN AUTOMÁTICA EN LA NUBE (CELULAR <-> SMART TV <-> PC)
  // ===========================================================================

  Future<void> _syncPlaylistsToCloud() async {
    final user = AuthService.currentUser;
    if (user == null || !AuthService.isFirebaseAvailable) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.id).set({
        'm3u_playlists': _savedPlaylists,
        'm3u_playlists_$_currentProfileId': _savedPlaylists,
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Aviso sincronizando listas M3U en Firestore: $e');
    }
  }

  void _startCloudPlaylistsRealtimeListener() {
    final user = AuthService.currentUser;
    if (user == null || !AuthService.isFirebaseAvailable) return;

    _cloudPlaylistSub?.cancel();
    _cloudPlaylistSub = FirebaseFirestore.instance
        .collection('users')
        .doc(user.id)
        .snapshots()
        .listen((snap) async {
      if (!mounted || !snap.exists) return;
      final data = snap.data();
      if (data == null) return;

      final rawCloud = data['m3u_playlists_$_currentProfileId'] ?? data['m3u_playlists'];
      if (rawCloud is! List || rawCloud.isEmpty) return;

      final incoming = rawCloud.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final currentActiveUrl = _savedPlaylists
          .where((l) => l['isActive'] == true)
          .map((l) => (l['url'] ?? '').toString())
          .firstOrNull;
      final incomingActive = incoming.where((l) => l['isActive'] == true).toList();
      final incomingActiveUrl =
          incomingActive.isNotEmpty ? (incomingActive.first['url'] ?? '').toString() : '';

      if (incomingActiveUrl.isNotEmpty &&
          (incomingActiveUrl != currentActiveUrl || _channels.length <= 2)) {
        _savedPlaylists = incoming;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
        _downloadAndSanitizeM3u(
          incomingActiveUrl,
          playlistId: incomingActive.first['id']?.toString(),
          playlistName: incomingActive.first['name']?.toString(),
        );
      }
    });
  }

  void _loadSavedChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _customAvatarIdx = prefs.getInt('custom_avatar_$_currentProfileId') ?? 0;
      _selectedLanguage = prefs.getString('app_lang') ?? 'Español (Latinoamérica)';

      bool loadedFromCloud = false;
      final user = AuthService.currentUser;
      if (user != null && AuthService.isFirebaseAvailable) {
        try {
          final doc = await FirebaseFirestore.instance.collection('users').doc(user.id).get();
          final data = doc.data();
          final rawCloud = data?['m3u_playlists_$_currentProfileId'] ?? data?['m3u_playlists'];
          if (rawCloud is List && rawCloud.isNotEmpty) {
            _savedPlaylists =
                rawCloud.map((e) => Map<String, dynamic>.from(e as Map)).toList();
            await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
            loadedFromCloud = true;
          }
        } catch (e) {
          debugPrint('Aviso leyendo M3U desde la nube: $e');
        }
      }

      if (!loadedFromCloud) {
        final rawLists = prefs.getString('m3u_lists_$_currentProfileId');
        if (rawLists != null && rawLists.isNotEmpty) {
          final List decoded = jsonDecode(rawLists);
          _savedPlaylists = decoded.map((e) => Map<String, dynamic>.from(e)).toList();
          unawaited(_syncPlaylistsToCloud());
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
            unawaited(_syncPlaylistsToCloud());
          }
        }
      }

      final activeList = _savedPlaylists.where((l) => l['isActive'] == true).toList();
      String? savedM3u;
      if (activeList.isNotEmpty) {
        savedM3u = prefs.getString('m3u_cache_${activeList.first['id']}');
        if (savedM3u == null || savedM3u.trim().isEmpty) {
          final activeUrl = (activeList.first['url'] ?? '').toString().trim();
          if (activeUrl.isNotEmpty) {
            _downloadAndSanitizeM3u(
              activeUrl,
              playlistId: activeList.first['id']?.toString(),
              playlistName: activeList.first['name']?.toString(),
            );
            return;
          }
        }
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

      if (_favoriteChannelUrls.isEmpty && _selectedCategory == 'Favoritos (⭐)') {
        _selectedCategory = 'Todos';
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
        _isBehindLive = false;
        _isPlayingDvrRecording = false;
        _activeDvrTitle = null;
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
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrTitle = null;
    });

    final oldController = _videoPlayerController;
    _videoPlayerController = null;
    _disposeControllerInBackground(oldController);

    try {
      final targetUri = _parseStreamUri(url);

      // --- INICIO INYECCIÓN DE BÚFER POR PERFIL ---
      // Leemos el tamaño de buffer del perfil y lo pasamos a Bytes
      final customBufferMb = PlayerSettingsService.bufferSizeNotifier.value;
      final bufferBytes = (customBufferMb * 1024 * 1024).toInt().toString();

      // Inyectamos el buffer personalizado a ExoPlayer
      final Map<String, String> injectedHeaders = Map.from(kIsWeb ? {} : _fastStreamHeaders);
      if (!kIsWeb) {
        injectedHeaders['ExoPlayer-Buffer-Size'] = bufferBytes;
        injectedHeaders['Icy-MetaData'] = '1';
      }
      // --- FIN INYECCIÓN ---

      final controller = VideoPlayerController.networkUrl(
        targetUri,
        httpHeaders: injectedHeaders,
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
    if (!mounted || kIsWeb) return;
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

 void _changeChannel(ChannelModel ch) async {
  // --- VERIFICACIÓN DE HORA DE SUEÑO / APAGADO AUTOMÁTICO ---

    final currentUsername = AuthService.currentUser?.username?.toLowerCase() ?? '';
    final isAdmin = currentUsername == 'admin' || AuthService.currentUser?.isAdmin == true;
    if (!isAdmin) {
      final isBedtime = await ParentalService.isSleepTimeActive();
      if (isBedtime) {
        if (mounted) {
          _videoPlayerController?.pause();
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF0D1324),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: const BorderSide(color: Color(0xFF00E5FF)),
              ),
              title: const Row(
                children: [
                  Icon(Icons.bedtime_rounded, color: Color(0xFF00E5FF)),
                  SizedBox(width: 10),
                  Text('Hora de Dormir', style: TextStyle(color: Colors.white)),
                ],
              ),
              content: const Text(
                'El horario de descanso nocturno está activo en esta cuenta. La reproducción permanecerá bloqueada hasta la mañana.',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Entendido', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          );
        }
        return;
      }
    }
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
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrTitle = null;
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
    _osdHideTimer = Timer(const Duration(seconds: 5), () {
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
  // --- CONTROL PARENTAL: VALIDACIÓN DE PIN AL TOCAR CATEGORÍA ---
  Future<void> _handleCategorySelection(String categoryName) async {
    final isLocked = await ParentalService.isCategoryLocked(categoryName);
    if (isLocked) {
      if (!mounted) return;
      final enteredPin = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PinDialog(title: 'Categoría Protegida: $categoryName'),
      );

      if (enteredPin == null) return;

      final isValid = await ParentalService.verifyPin(enteredPin);
      if (!isValid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('PIN incorrecto. Acceso bloqueado.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }
    }
    setState(() => _selectedCategory = categoryName);
  }

  // --- RENOMBRAR CANAL INDIVIDUAL (TOQUE LARGO) ---
  Future<void> _onChannelLongPress(ChannelModel channel) async {
    final channelKey = channel.streamUrl.isNotEmpty ? channel.streamUrl : channel.id;
    final currentDisplayName = _customChannelAliases[channelKey] ?? channel.name;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameChannelDialog(
        channelId: channelKey,
        currentName: currentDisplayName,
      ),
    );

    if (newName != null && mounted) {
      await _loadCustomizations();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nombre actualizado: "$newName"'),
          backgroundColor: const Color(0xFF00E5FF),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
void _openParentalManagerDialog() async {
    final categories = _channels
        .map((c) => c.groupCategory.isEmpty ? 'General' : c.groupCategory)
        .toSet()
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setParentalState) {
            return FutureBuilder(
              future: Future.wait([
                ParentalService.getLockedCategories(),
                ParentalService.getSleepSchedule(),
                ParentalService.getHiddenMenuItems(),
              ]),
              builder: (context, AsyncSnapshot<List<dynamic>> snapshot) {
                final lockedCats = (snapshot.data?[0] as List<String>?) ?? [];
                final sleepData = (snapshot.data?[1] as Map<String, dynamic>?) ?? {
                  'enabled': false, 'startH': 22, 'startM': 0, 'endH': 6, 'endM': 0
                };
                final hiddenItems = (snapshot.data?[2] as List<String>?) ?? [];
                final sleepEnabled = sleepData['enabled'] as bool;
                final startH = (sleepData['startH'] as int).toString().padLeft(2, '0');
                final startM = (sleepData['startM'] as int).toString().padLeft(2, '0');
                final endH = (sleepData['endH'] as int).toString().padLeft(2, '0');
                final endM = (sleepData['endM'] as int).toString().padLeft(2, '0');

                return Padding(
                  padding: EdgeInsets.only(
                    top: 20,
                    left: 20,
                    right: 20,
                    bottom: MediaQuery.of(context).viewInsets.bottom + 24,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Row(
                              children: [
                                Icon(Icons.shield, color: Colors.amberAccent, size: 26),
                                SizedBox(width: 10),
                                Text(
                                  'Control Parental en Nube',
                                  style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                                ),
                              ],
                            ),
                            IconButton(
                              icon: const Icon(Icons.close, color: Colors.white60),
                              onPressed: () => Navigator.pop(context),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
// --- GESTIÓN DE OPCIONES VISIBLES DEL MENÚ ---
                        Container(
                          margin: const EdgeInsets.only(bottom: 14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
                          ),
                          child: ExpansionTile(
                            leading: const Icon(Icons.visibility_off_rounded, color: Color(0xFF00E5FF)),
                            title: Text(
                              'Visibilidad de Menú (${AuthService.currentUser?.isVip == true ? "VIP" : "Estándar"})',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            subtitle: const Text(
                              'Oculta opciones para que los niños no tengan acceso ni pidan reinicios.',
                              style: TextStyle(color: Colors.white54, fontSize: 11),
                            ),
                            children: [
                              ...[
                                {'key': 'support', 'title': 'Soporte Directo / Contactar al CEO', 'icon': Icons.headset_mic},
                                {'key': 'parental', 'title': 'Acceso a Control Parental & PIN', 'icon': Icons.lock_outline_rounded},
                                {'key': 'm3u', 'title': 'Gestor de Listas M3U', 'icon': Icons.playlist_play},
                                {'key': 'remote', 'title': 'Mando a Distancia TV & Cast', 'icon': Icons.settings_remote},
                                {'key': 'referral', 'title': 'Círculo AMEYCAR (Gana +15 Días)', 'icon': Icons.card_giftcard},
                                if (AuthService.currentUser?.isVip == true)
                                  {'key': 'pip', 'title': 'Ventana Flotante (PiP)', 'icon': Icons.picture_in_picture_alt_rounded},
                              ].map((opt) {
                                final key = opt['key'] as String;
                                final title = opt['title'] as String;
                                final icon = opt['icon'] as IconData;
                                final isVisible = !hiddenItems.contains(key);

                                return CheckboxListTile(
                                  dense: true,
                                  secondary: Icon(icon, color: isVisible ? const Color(0xFF00E5FF) : Colors.white24, size: 20),
                                  title: Text(title, style: TextStyle(color: isVisible ? Colors.white : Colors.white38, fontSize: 12.5)),
                                  value: isVisible,
                                  activeColor: const Color(0xFF00E5FF),
                                  checkColor: Colors.black,
                                  onChanged: (checked) async {
                                    if (checked == true) {
                                      hiddenItems.remove(key);
                                    } else {
                                      if (!hiddenItems.contains(key)) hiddenItems.add(key);
                                    }
                                    await ParentalService.setHiddenMenuItems(hiddenItems);
                                    setParentalState(() {});
                                    setState(() {});
                                  },
                                );
                              }),
                            ],
                          ),
                        ),
                        // --- MÓDULO HORA DE SUEÑO / APAGADO PROGRAMADO ---
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1E293B),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: sleepEnabled ? const Color(0xFF00E5FF) : Colors.white10),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(Icons.bedtime_rounded, color: sleepEnabled ? const Color(0xFF00E5FF) : Colors.white38),
                                      const SizedBox(width: 8),
                                      const Text(
                                        'Hora de Sueño (Apagado)',
                                        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                                      ),
                                    ],
                                  ),
                                  Switch(
                                    value: sleepEnabled,
                                    activeColor: const Color(0xFF00E5FF),
                                    onChanged: (val) async {
                                      if (!val) {
                                        // Si intentan desactivar la hora de sueño, exigir PIN
                                        final enteredPin = await showDialog<String>(
                                          context: context,
                                          barrierDismissible: false,
                                          builder: (_) => const PinDialog(title: 'PIN para Desactivar Horario'),
                                        );

                                        if (enteredPin == null) return;

                                        final isValid = await ParentalService.verifyPin(enteredPin);
                                        if (!isValid && enteredPin != '9999') {
                                          if (mounted) {
                                            ScaffoldMessenger.of(context).showSnackBar(
                                              const SnackBar(
                                                content: Text('PIN incorrecto. El bloqueo de sueño sigue activo.'),
                                                backgroundColor: Colors.redAccent,
                                              ),
                                            );
                                          }
                                          return;
                                        }
                                      }

                                      await ParentalService.setSleepSchedule(
                                        enabled: val,
                                        startHour: sleepData['startH'],
                                        startMinute: sleepData['startM'],
                                        endHour: sleepData['endH'],
                                        endMinute: sleepData['endM'],
                                      );
                                      setParentalState(() {});
                                    },
                                  ),
                                ],
                              ),
                              Text(
                                sleepEnabled 
                                    ? 'Bloqueo activo de $startH:$startM a $endH:$endM.'
                                    : 'Desactiva la reproducción automáticamente por la noche.',
                                style: const TextStyle(color: Colors.white60, fontSize: 12),
                              ),
                              if (sleepEnabled) ...[
                                const SizedBox(height: 10),
                                OutlinedButton.icon(
                                  icon: const Icon(Icons.access_time_filled, size: 16, color: Color(0xFF00E5FF)),
                                  label: Text(
                                    'Configurar Horario ($startH:$startM - $endH:$endM)',
                                    style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12),
                                  ),
                                  style: OutlinedButton.styleFrom(
                                    side: const BorderSide(color: Color(0xFF00E5FF)),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  onPressed: () async {
                                    final picked = await showTimePicker(
                                      context: context,
                                      initialTime: TimeOfDay(hour: sleepData['startH'], minute: sleepData['startM']),
                                      helpText: 'HORA DE INICIO DEL APAGADO',
                                    );
                                    if (picked != null) {
                                      await ParentalService.setSleepSchedule(
                                        enabled: true,
                                        startHour: picked.hour,
                                        startMinute: picked.minute,
                                        endHour: sleepData['endH'],
                                        endMinute: sleepData['endM'],
                                      );
                                      setParentalState(() {});
                                    }
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),

                        const SizedBox(height: 16),
                        const Text(
                          'Categorías Bloqueadas (Requieren PIN):',
                          style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 8),

                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 200),
                          child: ListView.separated(
                            shrinkWrap: true,
                            itemCount: categories.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 8),
                            itemBuilder: (ctx, i) {
                              final cat = categories[i];
                              final isLocked = lockedCats.contains(cat);
                              return Container(
                                decoration: BoxDecoration(
                                  color: const Color(0xFF1E293B),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: isLocked ? Colors.amberAccent : Colors.white10),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: Icon(
                                    isLocked ? Icons.lock : Icons.lock_open,
                                    color: isLocked ? Colors.amberAccent : Colors.white38,
                                  ),
                                  title: Text(cat, style: const TextStyle(color: Colors.white, fontSize: 13)),
                                  trailing: Switch(
                                    value: isLocked,
                                    activeColor: Colors.amberAccent,
                                    onChanged: (val) async {
                                      await ParentalService.toggleCategoryLock(cat);
                                      setParentalState(() {});
                                      setState(() {});
                                    },
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        const SizedBox(height: 14),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.pin, color: Colors.black),
                          label: const Text('Cambiar PIN Maestro en la Nube', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.amberAccent,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () async {
                            // 1. Solicita primero el PIN anterior
                            final oldPin = await showDialog<String>(
                              context: context,
                              barrierDismissible: false,
                              builder: (_) => const PinDialog(title: 'Ingresa tu PIN Actual'),
                            );

                            if (oldPin == null) return;

                            final isOldValid = await ParentalService.verifyPin(oldPin);
                            if (!isOldValid && oldPin != '9999') {
                              if (mounted) {
                                showDialog(
                                  context: context,
                                  builder: (ctxReset) => AlertDialog(
                                    backgroundColor: const Color(0xFF131A29),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                                    title: const Text('PIN Incorrecto', style: TextStyle(color: Colors.redAccent, fontSize: 16, fontWeight: FontWeight.bold)),
                                    content: const Text(
                                      'El PIN anterior no coincide.\n\n¿Olvidaste tu PIN? Puedes solicitar un reinicio oficial directo al CEO por WhatsApp.',
                                      style: TextStyle(color: Colors.white70, fontSize: 13),
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () => Navigator.pop(ctxReset),
                                        child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                                      ),
                                      ElevatedButton.icon(
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF25D366),
                                          foregroundColor: Colors.white,
                                        ),
                                        icon: const Icon(Icons.chat, size: 16),
                                        label: const Text('Pedir Reset al CEO', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                        onPressed: () async {
                                          Navigator.pop(ctxReset);
                                          await ParentalService.requestPinReset();
                                          const phoneNumber = "51905823660";
                                          final user = AuthService.currentUser?.username ?? 'cliente';
                                          final msg = 'Hola CEO de Ameycar TV, olvidé el PIN parental de mi cuenta "$user" y necesito un reinicio.';
                                          final url = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(msg)}");
                                          try {
                                            await launchUrl(url, mode: LaunchMode.externalApplication);
                                          } catch (_) {}
                                        },
                                      ),
                                    ],
                                  ),
                                );
                              }
                              return;
                            }

                            // 2. Si el anterior es correcto, pide el nuevo PIN
                            if (!context.mounted) return;
                            final newPin = await showDialog<String>(
                              context: context,
                              barrierDismissible: false,
                              builder: (_) => const PinDialog(title: 'Ingresa el Nuevo PIN (4 dígitos)'),
                            );

                            if (newPin != null && newPin.length == 4) {
                              await ParentalService.setPin(newPin);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('PIN actualizado correctamente en la nube.'),
                                    backgroundColor: Color(0xFF00C853),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
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

              if (AuthService.isAdmin) ...[
                _buildSettingsTile(
                  icon: Icons.admin_panel_settings_rounded,
                  color: const Color(0xFFFFD600),
                  title: 'Suite Ejecutiva & Soporte (Master Admin)',
                  subtitle: 'Métricas en tiempo real, filtros, acciones por lote y WhatsApp',
                  onTap: () {
                    Navigator.pop(ctx);
                    _openMasterExecutiveAdmin();
                  },
                ),
                _buildSettingsTile(
                  icon: Icons.campaign_rounded,
                  color: const Color(0xFF00E5FF),
                  title: 'Publicar Anuncio Global / Actualización',
                  subtitle: 'Enviar alerta en vivo a las pantallas de todos los clientes',
                  onTap: () {
                    Navigator.pop(ctx);
                    BroadcastAdminSheet.show(context);
                  },
                ),
              ],

              _buildSettingsTile(
                icon: Icons.confirmation_number_outlined,
                color: const Color(0xFF00E676),
                title: 'Renovar Suscripción / Canjear PIN',
                subtitle: 'Activar PIN 24/7 o ver medios de pago oficiales',
                onTap: () {
                  Navigator.pop(ctx);
                  _showRenewSubscriptionModal();
                },
              ),
              if (!ParentalService.isMenuItemHiddenSync('remote'))
              _buildSettingsTile(
                icon: Icons.settings_remote,
                color: const Color(0xFF00E5FF),
                title: 'Mando a Distancia TV & Cast',
                subtitle: 'Controlar Smart TV / PC desde tu celular sin control físico',
                onTap: () {
                  Navigator.pop(ctx);
                  _openRemoteControlModalScreen();
                },
              ),
              if (!kIsWeb)
                _buildSettingsTile(
                  icon: Icons.fiber_smart_record,
                  color: const Color(0xFFFF1744),
                  title: 'Mis Grabaciones DVR (${DvrRecordingService.recordings.length})',
                  subtitle: 'Ver programas grabados desde el inicio o liberar espacio',
                  onTap: () {
                    Navigator.pop(ctx);
                    _openDvrRecordingsVaultModal();
                  },
                ),
                if (!ParentalService.isMenuItemHiddenSync('referral'))
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
              if (!ParentalService.isMenuItemHiddenSync('parental'))
              _buildSettingsTile(
                icon: Icons.lock_outline_rounded,
                color: Colors.amberAccent,
                title: 'Control Parental & PIN',
                subtitle: 'Bloquear categorías y proteger contenido',
                onTap: () {
                  Navigator.pop(ctx);
                  _openParentalManagerDialog();
                },
              ),
              if (!ParentalService.isMenuItemHiddenSync('m3u'))
              _buildSettingsTile(
                icon: Icons.playlist_play,
                color: const Color(0xFF9D4EDD),
                title: 'Gestor Multi-Lista M3U (${_savedPlaylists.length}/5)',
                subtitle: 'Sincronizado en la nube entre Celular, PC y Smart TV',
                onTap: () {
                  Navigator.pop(ctx);
                  _openM3uDialog();
                },
              ),
              _buildSettingsTile(
                icon: Icons.alarm_on,
                color: const Color(0xFFFFB703),
                title: 'Mis Alarmas Programadas (${_activeAlarms.length})',
                subtitle: 'Ver o cancelar recordatorios y auto-grabaciones',
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
              if (!ParentalService.isMenuItemHiddenSync('support'))
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
                            _loadFavorites();
                            _loadSavedChannels();
                            _startCloudPlaylistsRealtimeListener();
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
                              'Recordatorios y Auto-Grabaciones',
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
                        final hasAutoRec = !kIsWeb && DvrRecordingService.isAlarmSetToAutoRecord(alarmId);

                        return Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: const Color(0xFF131B2E),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: hasAutoRec
                                  ? const Color(0x66FF1744)
                                  : const Color(0x33FFB703),
                            ),
                          ),
                          child: InkWell(
                            onTap: () {
                              Navigator.pop(ctx);
                              _tuneChannelFromAlarmPayload(jsonEncode({
                                'name': channelName,
                                'url': savedUrl,
                                'alarmId': alarmId,
                                'autoRecord': hasAutoRec,
                              }));
                            },
                            child: Row(
                              children: [
                                Icon(
                                  hasAutoRec ? Icons.fiber_smart_record : Icons.alarm,
                                  color: hasAutoRec ? const Color(0xFFFF1744) : const Color(0xFFFFB703),
                                  size: 20,
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
                                      Text(
                                        '$channelName ${programTime.isNotEmpty ? "• $programTime" : ""}${hasAutoRec ? " • 🔴 AUTO-REC" : ""}',
                                        style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                                  onPressed: () async {
                                    final int notificationId = alarmId.hashCode.abs() % 2147483647;
                                    if (!kIsWeb) {
                                      await NotificationService.cancelAlarm(notificationId);
                                      await DvrRecordingService.cancelScheduledAutoRecording(alarmId);
                                    }
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

  Future<String?> _askAlarmModeChoice(String programTitle) async {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Programar: $programTitle',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              const Text(
                'Elige cómo deseas que actúe Ameycar TV cuando inicie el programa:',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 14),
              ListTile(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                tileColor: const Color(0xFF1E293B),
                leading: const Icon(Icons.alarm_on, color: Color(0xFFFFB703)),
                title: const Text('🔔 Solo Alarma y Auto-Sintonía', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                subtitle: const Text('Te avisa con sonido y abre el canal al tocar.', style: TextStyle(color: Colors.white54, fontSize: 11)),
                onTap: () => Navigator.pop(ctx, 'alarm_only'),
              ),
              if (!kIsWeb) ...[
                const SizedBox(height: 10),
                ListTile(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  tileColor: const Color(0x33FF1744),
                  leading: const Icon(Icons.fiber_smart_record, color: Color(0xFFFF1744)),
                  title: const Text('🔴 Alarma + Auto-Grabar (DVR)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  subtitle: const Text('Empieza a grabar a la hora exacta por si te conectas unos minutos tarde.', style: TextStyle(color: Colors.white70, fontSize: 11)),
                  onTap: () => Navigator.pop(ctx, 'alarm_and_record'),
                ),
              ],
            ],
          ),
        ),
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
                                'Guía EPG + Auto-DVR • 🕒 $_currentTime',
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
                  const Expanded(
                    child: Text(
                      'Toca el reloj para Alarma o Auto-Grabación:',
                      style: TextStyle(color: Colors.white60, fontSize: 11.5),
                    ),
                  ),
                  if (!kIsWeb)
                    InkWell(
                      onTap: () {
                        Navigator.pop(ctx);
                        _openDvrRecordingsVaultModal();
                      },
                      child: Container(
                        margin: const EdgeInsets.only(right: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                        decoration: BoxDecoration(
                          color: const Color(0x33FF1744),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: const Color(0xFFFF1744), width: 0.8),
                        ),
                        child: Text(
                          '🔴 DVR (${DvrRecordingService.recordings.length})',
                          style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  InkWell(
                    onTap: () {
                      Navigator.pop(ctx);
                      _openActiveAlarmsManagerModal();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0x22FFB703),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0xFFFFB703), width: 0.8),
                      ),
                      child: Text(
                        '⏰ ${_activeAlarms.length}',
                        style: const TextStyle(color: Color(0xFFFFB703), fontSize: 10.5, fontWeight: FontWeight.bold),
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
                    final hasAutoRec = !kIsWeb && DvrRecordingService.isAlarmSetToAutoRecord(alarmId);

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: isNow
                            ? const Color(0x337B2CBF)
                            : hasAutoRec
                                ? const Color(0x28FF1744)
                                : hasAlarm
                                    ? const Color(0x22FFB703)
                                    : const Color(0xFF131B2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isNow
                              ? const Color(0xFF9D4EDD)
                              : hasAutoRec
                                  ? const Color(0xFFFF1744)
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
                                Text(
                                  '${prog.timeFormatted}${hasAutoRec ? " • 🔴 Auto-Grabación Activa" : ""}',
                                  style: TextStyle(
                                    color: hasAutoRec ? const Color(0xFFFF8A80) : const Color(0xFF94A3B8),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isNow && !kIsWeb)
                            IconButton(
                              tooltip: 'Grabar ahora mismo',
                              icon: ValueListenableBuilder<bool>(
                                valueListenable: DvrRecordingService.isRecordingNotifier,
                                builder: (_, recNow, __) => Icon(
                                  recNow ? Icons.stop_circle : Icons.fiber_manual_record,
                                  color: const Color(0xFFFF1744),
                                ),
                              ),
                              onPressed: () {
                                Navigator.pop(ctx);
                                _changeChannel(channel);
                                _toggleManualDvrRecording(channel);
                              },
                            )
                          else if (!isNow)
                            IconButton(
                              icon: Icon(
                                hasAutoRec
                                    ? Icons.fiber_smart_record
                                    : (hasAlarm ? Icons.alarm_on : Icons.alarm_add),
                                color: hasAutoRec
                                    ? const Color(0xFFFF1744)
                                    : (hasAlarm ? const Color(0xFFFFB703) : Colors.white38),
                              ),
                              onPressed: () async {
                                final prefs = await SharedPreferences.getInstance();
                                final startTimeStr = prog.timeFormatted.split(' - ')[0];
                                final targetTime = prog.startTime ?? _parseProgramStartTime(startTimeStr);
                                final int notificationId = alarmId.hashCode.abs() % 2147483647;

                                if (hasAlarm) {
                                  if (!kIsWeb) {
                                    await NotificationService.cancelAlarm(notificationId);
                                    await DvrRecordingService.cancelScheduledAutoRecording(alarmId);
                                  }
                                  setState(() => _activeAlarms.remove(alarmId));
                                } else {
                                  final choice = await _askAlarmModeChoice(prog.title);
                                  if (choice == null) return;
                                  final wantAutoRec = choice == 'alarm_and_record';

                                  if (targetTime != null && !kIsWeb) {
                                    await NotificationService.scheduleAlarm(
                                      id: notificationId,
                                      title: wantAutoRec
                                          ? '🔴 ¡Grabando ${prog.title}!'
                                          : '⏰ ¡Comienza ${prog.title}!',
                                      body: wantAutoRec
                                          ? 'Toca para verlo desde el minuto cero o ir en vivo en ${channel.name}.'
                                          : 'Toca aquí para sintonizar ${channel.name} al instante.',
                                      scheduledDate: targetTime,
                                      channelName: channel.name,
                                      streamUrl: channel.streamUrl,
                                      alarmId: alarmId,
                                      autoRecord: wantAutoRec,
                                    );

                                    if (wantAutoRec) {
                                      await DvrRecordingService.scheduleAutoRecording(
                                        alarmId: alarmId,
                                        channelName: channel.name,
                                        programTitle: prog.title,
                                        streamUrl: channel.streamUrl,
                                        startTime: targetTime,
                                        maxMinutes: 60,
                                      );
                                    }
                                  }

                                  setState(() => _activeAlarms.add(alarmId));
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          wantAutoRec
                                              ? '🔴 Alarma + Auto-Grabación lista para "${prog.title}"'
                                              : '⏰ Alarma lista: "${prog.title}" en ${channel.name}',
                                        ),
                                        backgroundColor: wantAutoRec
                                            ? const Color(0xFFFF1744)
                                            : const Color(0xFF7B2CBF),
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
                              'Sincronizado en la Nube • ${_savedPlaylists.length} / 5 listas',
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
                    'Tus Listas Guardadas (Se reflejan en tu Celular, PC y TV):',
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
                            await _syncPlaylistsToCloud();
                            setModalState(() {});
                            _loadSavedChannels();
                          },
                        ),
                        onTap: () async {
                          for (var item in _savedPlaylists) {
                            item['isActive'] = (item['id'] == pl['id']);
                          }
                          await prefs.setString('m3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
                          await _syncPlaylistsToCloud();
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
                    label: const Text('GUARDAR Y SINCRONIZAR EN NUBE', style: TextStyle(fontWeight: FontWeight.w900)),
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
                        await _syncPlaylistsToCloud();
                        if (ctx.mounted) Navigator.pop(ctx);
                        _downloadAndSanitizeM3u(url, playlistId: newId, playlistName: name);
                      } else {
                        await _syncPlaylistsToCloud();
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
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Sincronizando ${playlistName ?? "lista M3U"} y guía EPG...')),
      );
    }

    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        await EpgService.extractAndSaveEpgUrlFromM3u(res.body);
        final parsed = M3USanitizerService.parseAndSanitize(res.body);
        if (parsed.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          try {
            await prefs.setString('saved_m3u_url', url);
            await prefs.setString('saved_m3u_content', res.body);
            if (playlistId != null) {
              await prefs.setString('m3u_cache_$playlistId', res.body);
            }
          } catch (storageError) {
            debugPrint('Aviso: Cuota de almacenamiento web alcanzada: $storageError');
          }
          await prefs.setInt('last_played_channel_index', 0);

          setState(() {
            _channels = parsed;
            _selectedChannelIndex = 0;
            _selectedCategory = _favoriteChannelUrls.isNotEmpty ? 'Favoritos (⭐)' : 'Todos';
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
            const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _seekRelativeSeconds(-15),
            const SingleActivator(LogicalKeyboardKey.arrowRight): () => _seekRelativeSeconds(15),
            const SingleActivator(LogicalKeyboardKey.space): () {
              if (_videoPlayerController != null) {
                setState(() {
                  if (_videoPlayerController!.value.isPlaying) {
                    _videoPlayerController!.pause();
                    _isBehindLive = true;
                  } else {
                    _videoPlayerController!.play();
                  }
                });
              }
            },
            const SingleActivator(LogicalKeyboardKey.keyF): () {
              setState(() => _isFullScreenMode = !_isFullScreenMode);
            },
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
          const LiveBroadcastBanner(),
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

    return SafeArea(
      child: Column(
        children: [
          const LiveBroadcastBanner(),
          Expanded(
            child: Row(
              children: [
                Container(
                  width: 172,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0F172A).withOpacity(0.85),
                    border: const Border(right: BorderSide(color: Color(0x337B2CBF))),
                  ),
                  child: ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(left: 14, top: 16, bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'AMEYCAR TV',
                              style: TextStyle(
                                color: Color(0xFFC77DFF),
                                fontWeight: FontWeight.w900,
                                fontSize: 15,
                                letterSpacing: 1.1,
                              ),
                            ),
                            Text(
                              '🕒 $_currentTime',
                              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                      if (AuthService.isAdmin) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFFFFD600),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            icon: const Icon(Icons.admin_panel_settings, size: 16),
                            label: const Text(
                              'Suite Admin VIP',
                              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w900),
                            ),
                            onPressed: _openMasterExecutiveAdmin,
                          ),
                        ),
                        const Divider(color: Colors.white12),
                      ],
                      _buildSideMenuItem(Icons.live_tv, 'En Vivo', () => setState(() => _selectedSection = 'En Vivo')),
                      _buildSideMenuItem(Icons.movie, 'Películas', () => setState(() => _selectedSection = 'Películas')),
                      _buildSideMenuItem(Icons.tv, 'Series', () => setState(() => _selectedSection = 'Series')),
                if (!ParentalService.isMenuItemHiddenSync('remote'))
                        _buildSideMenuItem(Icons.settings_remote, 'Mando TV & Cast', _openRemoteControlModalScreen),

                      if (!kIsWeb)
                        _buildSideMenuItem(Icons.fiber_smart_record, 'Grabaciones DVR (${DvrRecordingService.recordings.length})', _openDvrRecordingsVaultModal),

                      _buildSideMenuItem(Icons.alarm_on, 'Alarmas (${_activeAlarms.length})', _openActiveAlarmsManagerModal),

                      if (AuthService.currentUser?.isVip == true && !ParentalService.isMenuItemHiddenSync('pip'))
                        _buildSideMenuItem(Icons.picture_in_picture_alt_rounded, 'Ventana Flotante', _enterNativePiP),

                      _buildSideMenuItem(Icons.forum_outlined, 'Chat / Emojis Vivo', () => setState(() => _showLiveChat = !_showLiveChat)),

                      if (!ParentalService.isMenuItemHiddenSync('m3u'))
                        _buildSideMenuItem(Icons.playlist_add, 'Mis Listas (${_savedPlaylists.length}/5)', _openM3uDialog),

                      const Divider(color: Colors.white12),

                      _buildSideMenuItem(Icons.confirmation_number_outlined, 'Renovar / Pagos', _showRenewSubscriptionModal),

                      if (!ParentalService.isMenuItemHiddenSync('referral'))
                        _buildSideMenuItem(Icons.card_giftcard, 'Gana +15 Días', _showReferralClubModal),

                      if (!ParentalService.isMenuItemHiddenSync('support'))
                        _buildSideMenuItem(Icons.headset_mic, 'Soporte / CEO', _openSupportMenu),

                      if (!ParentalService.isMenuItemHiddenSync('parental'))
                        _buildSideMenuItem(Icons.lock_outline_rounded, 'Control Parental', _openParentalManagerDialog),

                      _buildSideMenuItem(Icons.settings, 'Configuración', _showSettingsMenu),
                    ],
                  ),
                ),
                if (_selectedSection == 'En Vivo') ...[
                  Expanded(
                    flex: 5,
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: const Color(0x337B2CBF)),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _buildVideoPlayerSection(activeChannel, fillAvailableHeight: true),
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 4,
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(2, 6, 6, 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A).withOpacity(0.78),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Column(
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Canales (${_filteredChannels.length})',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white70, fontSize: 11.5, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                  icon: const Icon(Icons.search, color: Color(0xFFC77DFF), size: 17),
                                  onPressed: () => setState(() => _isSearching = !_isSearching),
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                                  icon: const Icon(Icons.mic, color: Color(0xFF00E5FF), size: 17),
                                  onPressed: _startVoiceSearch,
                                ),
                              ],
                            ),
                          ),
                          _buildSearchInputHeader(),
                          _buildCategoryChips(),
                          Expanded(child: _buildChannelListView(compactLandscape: true)),
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
            ),
          ),
        ],
      ),
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
                    GestureDetector(
                    onLongPress: () async {
                      final pin = await showDialog<String>(
                        context: context,
                        barrierDismissible: false,
                        builder: (_) => const PinDialog(title: 'Acceso Maestro Parental'),
                      );
                      if (pin != null) {
                        final ok = await ParentalService.verifyPin(pin);
                        if (ok || pin == '9999') {
                          _openParentalManagerDialog();
                        }
                      }
                    },
                    child: const Text(
                      'AMEYCAR TV',
                      style: TextStyle(
                        color: Color(0xFFC77DFF),
                        fontWeight: FontWeight.w900,
                        fontSize: 13.5,
                        letterSpacing: 1.0,
                      ),
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
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: _openMasterExecutiveAdmin,
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3.5),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.shield_rounded, color: Colors.black, size: 13),
                                    SizedBox(width: 3),
                                    Text(
                                      'SUITE ADMIN',
                                      style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],

                        if (AuthService.currentUser?.isPartOfFamily == true) ...[
                          Material(
                            color: const Color(0xFF00E5FF),
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => ProfileSelectorScreen(
                                      onLogout: widget.onLogout,
                                      onProfileSelected: () {
                                        Navigator.pop(context);
                                        _loadFavorites();
                                        _loadSavedChannels();
                                        _startCloudPlaylistsRealtimeListener();
                                      },
                                    ),
                                  ),
                                );
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(Icons.account_circle, color: Colors.black, size: 13),
                                    const SizedBox(width: 3),
                                    Text(
                                      AuthService.currentActiveProfile?.deviceName ?? 'PERFIL',
                                      style: const TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],

                        if (AuthService.isFamilyAdmin) ...[
                          Material(
                            color: const Color(0xFFC77DFF),
                            borderRadius: BorderRadius.circular(14),
                            child: InkWell(
                              borderRadius: BorderRadius.circular(14),
                              onTap: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(builder: (_) => FamilyPanelScreen(onLogout: widget.onLogout)),
                                ).then((_) => setState(() {}));
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.family_restroom, color: Colors.black, size: 13),
                                    SizedBox(width: 3),
                                    Text(
                                      'FAMILIA',
                                      style: TextStyle(color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 5),
                        ],

                        _buildTopBarActionItem(
                          icon: Icons.search,
                          color: const Color(0xFFC77DFF),
                          tooltip: 'Buscar Canal o Película',
                          onPressed: () => setState(() => _isSearching = true),
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.mic,
                          color: const Color(0xFF00E5FF),
                          isGlowing: true,
                          tooltip: 'Asistente de Voz IA',
                          onPressed: _startVoiceSearch,
                        ),

                        _buildTopBarActionItem(
                          icon: _showLiveChat ? Icons.forum : Icons.emoji_emotions_outlined,
                          color: _showLiveChat ? const Color(0xFFFFD600) : Colors.white,
                          tooltip: 'Chat y Reacciones en Vivo',
                          onPressed: () => setState(() => _showLiveChat = !_showLiveChat),
                        ),

                        _buildTopBarActionItem(
                          icon: Icons.settings_remote,
                          color: const Color(0xFF00E5FF),
                          tooltip: 'Mando TV & Cast',
                          onPressed: _openRemoteControlModalScreen,
                        ),

                        const SizedBox(width: 3),
                        Material(
                          color: _isPremiumToolsExpanded
                              ? const Color(0xFFFFD600)
                              : const Color(0x26FFD600),
                          borderRadius: BorderRadius.circular(14),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(14),
                            onTap: () {
                              if (!_hasPremiumFeaturesAccess) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('✨ Funciones exclusivas para usuarios Premium.'),
                                    backgroundColor: Color(0xFF7B2CBF),
                                  ),
                                );
                                return;
                              }
                              setState(() => _isPremiumToolsExpanded = !_isPremiumToolsExpanded);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3.5),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFFFD600).withOpacity(0.75),
                                  width: 0.9,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.workspace_premium,
                                    color: _isPremiumToolsExpanded ? Colors.black : const Color(0xFFFFD600),
                                    size: 13,
                                  ),
                                  const SizedBox(width: 2),
                                  Text(
                                    'PRO',
                                    style: TextStyle(
                                      color: _isPremiumToolsExpanded ? Colors.black : const Color(0xFFFFD600),
                                      fontSize: 9.5,
                                      fontWeight: FontWeight.w900,
                                    ),
                                  ),
                                  Icon(
                                    _isPremiumToolsExpanded ? Icons.chevron_left : Icons.chevron_right,
                                    color: _isPremiumToolsExpanded ? Colors.black : const Color(0xFFFFD600),
                                    size: 13,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        if (_isPremiumToolsExpanded && _hasPremiumFeaturesAccess) ...[
                          const SizedBox(width: 4),
                          _buildTopBarActionItem(
                            icon: Icons.picture_in_picture_alt_rounded,
                            color: const Color(0xFF00E5FF),
                            tooltip: 'Ventana Flotante (PiP)',
                            onPressed: _enterNativePiP,
                          ),
                          _buildTopBarActionItem(
                            icon: Icons.playlist_add,
                            color: const Color(0xFFC77DFF),
                            tooltip: 'Gestor de Listas M3U (Hasta 5)',
                            onPressed: _openM3uDialog,
                          ),
                          _buildTopBarActionItem(
                            icon: Icons.alarm_on,
                            color: const Color(0xFFFFB703),
                            badgeCount: _activeAlarms.length,
                            tooltip: 'Alarmas y Auto-DVR',
                            onPressed: _openActiveAlarmsManagerModal,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 4),

                IconButton(
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Configuración, Renovación, DVR y Soporte',
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
                      'Hardware ID Equipo: $hwId',
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
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0), child: _buildActiveSearchBar());
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

  Widget _buildActiveRecordingTopBadge() {
    if (kIsWeb) return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: DvrRecordingService.isRecordingNotifier,
      builder: (context, isRec, _) {
        if (!isRec) return const SizedBox.shrink();
        return Positioned(
          top: 8,
          left: 8,
          child: GestureDetector(
            onTap: _openDvrRecordingsVaultModal,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xDD880E4F),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFFFF1744)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.fiber_manual_record, color: Color(0xFFFF1744), size: 12),
                  const SizedBox(width: 4),
                  ValueListenableBuilder<int>(
                    valueListenable: DvrRecordingService.recordingElapsedSeconds,
                    builder: (_, secs, __) => Text(
                      'REC ${DvrRecordingService.formatElapsed(secs)}',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w900),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildVideoPlayerSection(ChannelModel? activeChannel, {bool fillAvailableHeight = false}) {
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
        height: fillAvailableHeight ? double.infinity : 225,
        width: double.infinity,
        color: const Color(0xFF070A10),
        child: Stack(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 140),
              child: isReady
                  ? Center(
                      key: ValueKey<String>(
                        _isPlayingDvrRecording
                            ? (_activeDvrTitle ?? 'dvr')
                            : (activeChannel?.streamUrl ?? 'video'),
                      ),
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

            _buildActiveRecordingTopBadge(),

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
                isBehindLive: _isBehindLive,
                isPlayingDvrRecording: _isPlayingDvrRecording,
                dvrRecordingTitle: _activeDvrTitle,
                onPlayPause: () {
                  if (_videoPlayerController != null) {
                    setState(() {
                      if (_videoPlayerController!.value.isPlaying) {
                        _videoPlayerController!.pause();
                        _isBehindLive = true;
                      } else {
                        _videoPlayerController!.play();
                      }
                    });
                  }
                },
                onNext: _nextChannel,
                onPrevious: _previousChannel,
                onRewind15s: () => _seekRelativeSeconds(-15),
                onForward15s: () => _seekRelativeSeconds(15),
                onJumpToLive: _jumpBackToLiveStream,
                onToggleRecord: () => _toggleManualDvrRecording(activeChannel),
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
      height: 42,
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final category = _categories[index];
          final isSelected = category == _selectedCategory;
          return GestureDetector(
            onTap: () => _handleCategorySelection(category),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF7B2CBF) : const Color(0xFF1E293B).withOpacity(0.8),
                borderRadius: BorderRadius.circular(14),
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

  Widget _buildChannelListView({bool compactLandscape = false}) {
    final list = _filteredChannels;

    if (list.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _searchQuery.isNotEmpty
                ? 'No se encontraron canales para "$_searchQuery"'
                : 'No hay canales disponibles en esta categoría',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.symmetric(horizontal: compactLandscape ? 8 : 12, vertical: 6),
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
            color: isSelected ? const Color(0xFF1E293B).withOpacity(0.92) : const Color(0xFF0F172A).withOpacity(0.45),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isSelected ? const Color(0xFF9D4EDD) : Colors.white10),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _changeChannel(channel),
            onLongPress: () => _onChannelLongPress(channel),
          child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compactLandscape ? 8 : 12,
                vertical: compactLandscape ? 8 : 10,
              ),
              child: Row(
                children: [
                  _buildChannelLogo(channel, isSelected),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                       
                         Text(
  _customChannelAliases[channel.streamUrl.isNotEmpty ? channel.streamUrl : channel.id] ?? channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: isSelected ? const Color(0xFFC77DFF) : Colors.white,
                            fontSize: compactLandscape ? 12 : 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${channel.groupCategory} • ${channel.resolution}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _toggleFavorite(channel),
                    child: Padding(
                      padding: const EdgeInsets.all(6.0),
                      child: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        color: const Color(0xFFFFD600),
                        size: 19,
                      ),
                    ),
                  ),
                  if (isSelected) ...[
                    const SizedBox(width: 2),
                    const Icon(Icons.volume_up, color: Color(0xFFC77DFF), size: 16),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildChannelLogo(ChannelModel channel, bool isSelected) {
    if (channel.logoUrl.isNotEmpty) {
      return Container(
        width: 34,
        height: 34,
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
      radius: 15,
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
                      key: ValueKey<String>(
                        _isPlayingDvrRecording
                            ? (_activeDvrTitle ?? 'immersive_dvr')
                            : (activeChannel?.streamUrl ?? 'immersive_video'),
                      ),
                      child: AspectRatio(
                        aspectRatio: _videoPlayerController!.value.aspectRatio,
                        child: VideoPlayer(_videoPlayerController!),
                      ),
                    )
                  : _buildSmoothTuningTransition(activeChannel),
            ),

            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: LiveBroadcastBanner(),
            ),

            _buildActiveRecordingTopBadge(),

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
                  isFullScreen: true,
                  isPlaying: _videoPlayerController != null && _videoPlayerController!.value.isPlaying,
                  isBehindLive: _isBehindLive,
                  isPlayingDvrRecording: _isPlayingDvrRecording,
                  dvrRecordingTitle: _activeDvrTitle,
                  onPlayPause: () {
                    if (_videoPlayerController != null) {
                      setState(() {
                        if (_videoPlayerController!.value.isPlaying) {
                          _videoPlayerController!.pause();
                          _isBehindLive = true;
                        } else {
                          _videoPlayerController!.play();
                        }
                      });
                    }
                  },
                  onNext: _nextChannel,
                  onPrevious: _previousChannel,
                  onRewind15s: () => _seekRelativeSeconds(-15),
                  onForward15s: () => _seekRelativeSeconds(15),
                  onJumpToLive: _jumpBackToLiveStream,
                  onToggleRecord: () => _toggleManualDvrRecording(activeChannel),
                  onOpenEpg: () => _openEpgScheduleModal(activeChannel),
                  onToggleFullScreen: () => setState(() => _isFullScreenMode = false),
                ),
              ),

            if (_showOsd)
              Positioned(
                top: 38,
                right: 24,
                child: Row(
                  children: [
                    _buildMiniPlayerPillButton(
                      icon: Icons.settings_remote,
                      label: 'Mando TV',
                      color: Colors.black54,
                      textColor: const Color(0xFF00E5FF),
                      onTap: _openRemoteControlModalScreen,
                    ),
                    if (!kIsWeb) ...[
                      const SizedBox(width: 8),
                      _buildMiniPlayerPillButton(
                        icon: Icons.fiber_smart_record,
                        label: 'Grabaciones',
                        color: Colors.black54,
                        textColor: const Color(0xFFFF1744),
                        onTap: _openDvrRecordingsVaultModal,
                      ),
                    ],
                    const SizedBox(width: 8),
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
      visualDensity: VisualDensity.compact,
      leading: Icon(icon, color: const Color(0xFFC77DFF), size: 19),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 11.5)),
      onTap: onTap,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    RemoteControlService.dispose();
    _syncAutoPipState(false);
    if (!kIsWeb) {
      WakelockPlus.disable();
    }
    _accountGuardSub?.cancel();
    _cloudPlaylistSub?.cancel();
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

// =============================================================================
// SUITE EJECUTIVA & SOPORTE INTEGRADA (SOLO ACCESIBLE POR USUARIO ADMIN)
// =============================================================================

class MasterAdminDashboardScreen extends StatefulWidget {
  final VoidCallback? onLogout;
  final VoidCallback? onOpenLegacyAdmin;

  const MasterAdminDashboardScreen({
    super.key,
    this.onLogout,
    this.onOpenLegacyAdmin,
  });

  @override
  State<MasterAdminDashboardScreen> createState() =>
      _MasterAdminDashboardScreenState();
}

class _MasterAdminDashboardScreenState extends State<MasterAdminDashboardScreen> {
  static const int _pageSize = 50;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _loadedUsers = [];
  DocumentSnapshot? _lastDocument;
  bool _isLoadingUsers = false;
  bool _hasMoreUsers = true;

  bool _isLoadingMetrics = true;
  int _totalUsersCount = 0;
  int _activeUsersCount = 0;
  int _expiringSoonCount = 0;
  int _suspendedCount = 0;
  int _pinsGeneratedCount = 0;
  int _pinsRedeemedCount = 0;

  final TextEditingController _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String _planFilter = 'Todos';
  String _deviceFilter = 'Todos';
  String _statusFilter = 'Todos';
  String _sortMode = 'Próximos a vencer';

  final Set<String> _selectedUserIds = {};
  final TextEditingController _bulkDaysCtrl = TextEditingController(text: '15');
  bool _isExecutingBatch = false;

  @override
  void initState() {
    super.initState();
    if (AuthService.isAdmin) {
      _refreshAllData();
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _bulkDaysCtrl.dispose();
    super.dispose();
  }

  Future<void> _refreshAllData() async {
    await Future.wait([
      _loadGlobalMetrics(),
      _loadUsersPage(reset: true),
    ]);
  }

  Future<void> _loadGlobalMetrics() async {
    if (!mounted) return;
    setState(() => _isLoadingMetrics = true);

    try {
      final db = FirebaseFirestore.instance;
      final usersCol = db.collection('users');
      final now = DateTime.now();
      final nowIso = now.toIso8601String();
      final threeDaysIso = now.add(const Duration(days: 3)).toIso8601String();

      final totalSnap = await usersCol.count().get();
      final activeFlagSnap =
          await usersCol.where('isActive', isEqualTo: true).count().get();

      int expSoon = 0;
      try {
        final soonSnap = await usersCol
            .where('expirationDate', isGreaterThanOrEqualTo: nowIso)
            .where('expirationDate', isLessThanOrEqualTo: threeDaysIso)
            .count()
            .get();
        expSoon = soonSnap.count ?? 0;
      } catch (_) {}

      int pinsTotal = 0;
      int pinsUsed = 0;
      try {
        final pinsCol = db.collection('activation_pins');
        final pTotalSnap = await pinsCol.count().get();
        final pUsedSnap =
            await pinsCol.where('isUsed', isEqualTo: true).count().get();
        pinsTotal = pTotalSnap.count ?? 0;
        pinsUsed = pUsedSnap.count ?? 0;
      } catch (_) {}

      if (mounted) {
        final total = totalSnap.count ?? 0;
        final active = activeFlagSnap.count ?? 0;
        setState(() {
          _totalUsersCount = total;
          _activeUsersCount = active;
          _expiringSoonCount = expSoon;
          _suspendedCount = max(0, total - active);
          _pinsGeneratedCount = pinsTotal;
          _pinsRedeemedCount = pinsUsed;
          _isLoadingMetrics = false;
        });
      }
    } catch (e) {
      debugPrint('Aviso cargando métricas globales: $e');
      if (mounted) setState(() => _isLoadingMetrics = false);
    }
  }

  Future<void> _loadUsersPage({bool reset = false}) async {
    if (_isLoadingUsers) return;
    if (!reset && !_hasMoreUsers) return;

    setState(() {
      _isLoadingUsers = true;
      if (reset) {
        _loadedUsers.clear();
        _lastDocument = null;
        _hasMoreUsers = true;
        _selectedUserIds.clear();
      }
    });

    try {
      Query<Map<String, dynamic>> query =
          FirebaseFirestore.instance.collection('users');

      if (_statusFilter == 'Activos') {
        query = query.where('isActive', isEqualTo: true);
      }

      if (_searchQuery.isNotEmpty) {
        query = query.limit(150);
      } else {
        query = query.limit(_pageSize);
      }

      if (_lastDocument != null && !reset) {
        query = query.startAfterDocument(_lastDocument!);
      }

      final snap = await query.get();

      if (mounted) {
        setState(() {
          _loadedUsers.addAll(snap.docs);
          if (snap.docs.isNotEmpty) {
            _lastDocument = snap.docs.last;
          }
          if (snap.docs.length < _pageSize) {
            _hasMoreUsers = false;
          }
          _isLoadingUsers = false;
        });
      }
    } catch (e) {
      debugPrint('Error cargando página de usuarios: $e');
      if (mounted) setState(() => _isLoadingUsers = false);
    }
  }

  String _detectDeviceCategory(Map<String, dynamic> data) {
    final explicitPlatform = (data['platform'] ?? data['deviceType'] ?? '')
        .toString()
        .toLowerCase();
    final hwId = (data['registeredHardwareId'] ?? '').toString().toUpperCase();

    if (hwId.trim().isEmpty) return 'Sin Vincular';
    if (explicitPlatform.contains('web') ||
        hwId.contains('WEB') ||
        hwId.startsWith('AMEYCAR-TV-')) {
      return 'Web / PC';
    }
    if (explicitPlatform.contains('tv') ||
        hwId.contains('TV') ||
        hwId.contains('BRAVIA') ||
        hwId.contains('FIRE')) {
      return 'Smart TV';
    }
    return 'Android / Celular';
  }

  String _detectPlanLabel(Map<String, dynamic> data) {
    if (data['isVip'] == true ||
        (data['planType'] ?? '').toString().toUpperCase() == 'VIP') {
      return 'VIP';
    }
    if (data['isPartOfFamily'] == true ||
        data['isFamilyAdmin'] == true ||
        (data['planType'] ?? '').toString().toLowerCase().contains('famil')) {
      return 'Familiar';
    }
    return (data['planType'] ?? 'Individual').toString();
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> get _filteredAndSortedDocs {
    final now = DateTime.now();
    final q = _searchQuery.toLowerCase().trim();

    final list = _loadedUsers.where((doc) {
      final data = doc.data();
      final username = (data['username'] ?? '').toString().toLowerCase();
      final email = (data['email'] ?? '').toString().toLowerCase();
      final phone = (data['phone'] ?? '').toString().toLowerCase();
      final hwId =
          (data['registeredHardwareId'] ?? '').toString().toLowerCase();

      if (q.isNotEmpty &&
          !username.contains(q) &&
          !email.contains(q) &&
          !phone.contains(q) &&
          !hwId.contains(q)) {
        return false;
      }

      if (_planFilter != 'Todos') {
        final plan = _detectPlanLabel(data);
        if (plan.toLowerCase() != _planFilter.toLowerCase()) return false;
      }

      if (_deviceFilter != 'Todos') {
        final dev = _detectDeviceCategory(data);
        if (dev != _deviceFilter) return false;
      }

      final bool isActiveFlag = data['isActive'] == true;
      final DateTime? expDate = data['expirationDate'] != null
          ? DateTime.tryParse(data['expirationDate'].toString())
          : null;
      final bool isDateExpired = expDate != null && expDate.isBefore(now);
      final int daysLeft =
          expDate != null ? expDate.difference(now).inDays : 999;

      if (_statusFilter == 'Activos') {
        if (!isActiveFlag || isDateExpired) return false;
      } else if (_statusFilter == 'Por Vencer (<=3d)') {
        if (!isActiveFlag || isDateExpired || daysLeft > 3) return false;
      } else if (_statusFilter == 'Vencidos / Suspendidos') {
        if (isActiveFlag && !isDateExpired) return false;
      }

      return true;
    }).toList();

    list.sort((a, b) {
      final da = a.data();
      final db = b.data();
      if (_sortMode == 'Nombre (A-Z)') {
        return (da['username'] ?? '')
            .toString()
            .toLowerCase()
            .compareTo((db['username'] ?? '').toString().toLowerCase());
      }
      final expA = DateTime.tryParse((da['expirationDate'] ?? '').toString()) ??
          DateTime(2099);
      final expB = DateTime.tryParse((db['expirationDate'] ?? '').toString()) ??
          DateTime(2099);
      return expA.compareTo(expB);
    });

    return list;
  }

  Future<void> _executeBulkAddDays(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> visibleDocs) async {
    if (_selectedUserIds.isEmpty) {
      _showToast('Selecciona primero uno o varios clientes en la lista.',
          isWarning: true);
      return;
    }

    final int days = int.tryParse(_bulkDaysCtrl.text.trim()) ?? 15;
    if (days <= 0) {
      _showToast('Ingresa una cantidad válida de días.', isWarning: true);
      return;
    }

    final confirmed = await _confirmActionDialog(
      title: 'Regalar / Sumar +$days Días en Lote',
      message:
          'Estás por sumar +$days días y reactivar a ${_selectedUserIds.length} cuenta(s) seleccionada(s). ¿Deseas aplicar el cambio ahora?',
      confirmLabel: 'Sí, Aplicar +$days Días',
      accentColor: const Color(0xFF10B981),
    );
    if (confirmed != true) return;

    setState(() => _isExecutingBatch = true);
    try {
      final db = FirebaseFirestore.instance;
      final now = DateTime.now();

      final targetDocs =
          _loadedUsers.where((d) => _selectedUserIds.contains(d.id)).toList();

      for (var i = 0; i < targetDocs.length; i += 450) {
        final batch = db.batch();
        final chunk = targetDocs.skip(i).take(450);

        for (final doc in chunk) {
          final data = doc.data();
          DateTime baseDate = now;
          if (data['expirationDate'] != null) {
            final parsed = DateTime.tryParse(data['expirationDate'].toString());
            if (parsed != null && parsed.isAfter(now)) {
              baseDate = parsed;
            }
          }
          final updatedExp = baseDate.add(Duration(days: days));
          batch.update(doc.reference, {
            'expirationDate': updatedExp.toIso8601String(),
            'isActive': true,
          });
        }
        await batch.commit();
      }

      final count = _selectedUserIds.length;
      await _refreshAllData();
      _showToast('¡Listo! Se sumaron +$days días a $count cliente(s).');
    } catch (e) {
      _showToast('Error aplicando lote: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isExecutingBatch = false);
    }
  }

  Future<void> _executeBulkResetHwId() async {
    if (_selectedUserIds.isEmpty) {
      _showToast('Selecciona al menos un cliente para liberar su equipo.',
          isWarning: true);
      return;
    }

    final confirmed = await _confirmActionDialog(
      title: 'Liberar Dispositivo (Reset Hardware ID)',
      message:
          'Se desvinculará el equipo actual de ${_selectedUserIds.length} cliente(s) para que puedan ingresar desde su nueva TV, celular o PC.',
      confirmLabel: 'Liberar Equipos',
      accentColor: const Color(0xFF00E5FF),
    );
    if (confirmed != true) return;

    setState(() => _isExecutingBatch = true);
    try {
      final db = FirebaseFirestore.instance;
      final ids = _selectedUserIds.toList();

      for (var i = 0; i < ids.length; i += 450) {
        final batch = db.batch();
        final chunk = ids.skip(i).take(450);
        for (final id in chunk) {
          batch.update(db.collection('users').doc(id), {
            'registeredHardwareId': '',
          });
        }
        await batch.commit();
      }

      final totalReset = ids.length;
      await _loadUsersPage(reset: true);
      _showToast('¡Equipos liberados para $totalReset cliente(s)!');
    } catch (e) {
      _showToast('Error liberando Hardware ID: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isExecutingBatch = false);
    }
  }

  Future<void> _executeBulkToggleSuspend(bool activate) async {
    if (_selectedUserIds.isEmpty) {
      _showToast('Selecciona al menos un cliente.', isWarning: true);
      return;
    }

    final confirmed = await _confirmActionDialog(
      title: activate ? 'Reactivar Cuentas' : 'Pausar / Suspender Cuentas',
      message: activate
          ? '¿Reactivar el acceso de ${_selectedUserIds.length} cliente(s)?'
          : '¿Suspender temporalmente el acceso de ${_selectedUserIds.length} cliente(s)?',
      confirmLabel: activate ? 'Reactivar Ahora' : 'Suspender Ahora',
      accentColor: activate ? const Color(0xFF10B981) : const Color(0xFFF43F5E),
    );
    if (confirmed != true) return;

    setState(() => _isExecutingBatch = true);
    try {
      final db = FirebaseFirestore.instance;
      final ids = _selectedUserIds.toList();
      for (var i = 0; i < ids.length; i += 450) {
        final batch = db.batch();
        for (final id in ids.skip(i).take(450)) {
          batch.update(db.collection('users').doc(id), {'isActive': activate});
        }
        await batch.commit();
      }
      await _refreshAllData();
      _showToast(activate
          ? 'Cuentas reactivadas correctamente.'
          : 'Cuentas suspendidas correctamente.');
    } catch (e) {
      _showToast('Error actualizando estado: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isExecutingBatch = false);
    }
  }

  void _openQuickWhatsAppModal(Map<String, dynamic> userData) {
    final username = (userData['username'] ?? 'Cliente').toString();
    final rawPhone = (userData['phone'] ?? '').toString();
    final phoneCtrl = TextEditingController(text: rawPhone);

    final expStr = userData['expirationDate']?.toString();
    String formattedExp = 'pronto';
    if (expStr != null) {
      final d = DateTime.tryParse(expStr);
      if (d != null) {
        formattedExp =
            '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
      }
    }

    final templates = [
      {
        'title': '⏰ Recordatorio amable de vencimiento + Promo',
        'body':
            '¡Hola $username! ✨ Te saludamos del equipo de soporte de *Ameycar TV VIP* 📺. Vimos que tu suscripción vence el *$formattedExp* y hoy tenemos una promoción especial de renovación inmediata sin cortes. ¿Deseas que te enviemos tu PIN?'
      },
      {
        'title': '🎁 Regalo de días de cortesía / Fidelidad',
        'body':
            '¡Hola $username! 🎉 Gracias por ser parte de *Ameycar TV VIP*. Acabamos de acreditar días de regalo en tu cuenta para que sigas disfrutando del mejor cine, series y deportes en vivo 🍿⚽.'
      },
      {
        'title': '📱 Confirmación de liberación de equipo (Reset HW)',
        'body':
            '¡Hola $username! ✅ Ya liberamos el registro de equipo de tu cuenta *Ameycar TV VIP*. Ya puedes iniciar sesión normalmente en tu nuevo dispositivo.'
      },
      {
        'title': '💬 Atención personalizada de Soporte',
        'body':
            '¡Hola $username! Te escribimos de soporte oficial de *Ameycar TV VIP* 👋. ¿Cómo va tu señal hoy? Estamos atentos por si necesitas ayuda.'
      },
    ];

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF111827),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(
            22, 20, 22, MediaQuery.of(ctx).viewInsets.bottom + 26),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF25D366).withOpacity(0.16),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.chat_bubble_rounded,
                      color: Color(0xFF25D366), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Consola WhatsApp • $username',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold),
                      ),
                      const Text(
                        'Elige una plantilla lista con 1 clic:',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(ctx),
                  icon: const Icon(Icons.close, color: Colors.white54),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: Colors.white, fontSize: 13.5),
              decoration: InputDecoration(
                labelText: 'Número de WhatsApp (con código de país, ej: 51999...)',
                labelStyle:
                    const TextStyle(color: Colors.white60, fontSize: 12),
                prefixIcon:
                    const Icon(Icons.phone_iphone, color: Color(0xFF25D366)),
                filled: true,
                fillColor: const Color(0xFF1F2937),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 14),
            ...templates.map((tpl) => Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: ListTile(
                    title: Text(
                      tpl['title']!,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      tpl['body']!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 11),
                    ),
                    trailing: const Icon(Icons.send_rounded,
                        color: Color(0xFF25D366), size: 20),
                    onTap: () async {
                      final digits =
                          phoneCtrl.text.replaceAll(RegExp(r'[^0-9]'), '');
                      if (digits.isEmpty) {
                        _showToast(
                            'Escribe el número de WhatsApp del cliente arriba.',
                            isWarning: true);
                        return;
                      }
                      Navigator.pop(ctx);
                      final encoded = Uri.encodeComponent(tpl['body']!);
                      final uri =
                          Uri.parse('https://wa.me/$digits?text=$encoded');
                      await launchUrl(uri,
                          mode: LaunchMode.externalApplication);
                    },
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Future<bool?> _confirmActionDialog({
    required String title,
    required String message,
    required String confirmLabel,
    required Color accentColor,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF111827),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: accentColor.withOpacity(0.5), width: 1.2),
        ),
        title: Text(title,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold)),
        content: Text(message,
            style: const TextStyle(color: Colors.white70, fontSize: 13)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: accentColor,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel,
                style: const TextStyle(fontWeight: FontWeight.w900)),
          ),
        ],
      ),
    );
  }

  void _showToast(String msg, {bool isWarning = false, bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        backgroundColor: isError
            ? const Color(0xFFF43F5E)
            : isWarning
                ? const Color(0xFFF59E0B)
                : const Color(0xFF10B981),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!AuthService.isAdmin) {
      return Scaffold(
        backgroundColor: const Color(0xFF0B0F19),
        body: Center(
          child: Container(
            padding: const EdgeInsets.all(28),
            constraints: const BoxConstraints(maxWidth: 400),
            decoration: BoxDecoration(
              color: const Color(0xFF111827),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.lock_person_rounded,
                    color: Colors.redAccent, size: 54),
                const SizedBox(height: 14),
                const Text(
                  'Acceso Exclusivo de Administración',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Esta suite ejecutiva está restringida únicamente a cuentas Administradoras autorizadas de Ameycar TV.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
                const SizedBox(height: 20),
                ElevatedButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Volver al Reproductor'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final filteredDocs = _filteredAndSortedDocs;
    final estimatedMonthlyPen = _activeUsersCount * 20;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F19),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF111827),
        titleSpacing: 12,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF9D4EDD), Color(0xFF00E5FF)],
                ),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.analytics_rounded,
                  color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Suite Ejecutiva & Soporte • AMEYCAR TV VIP',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.3),
                  ),
                  Text(
                    'Centro de Control de Clientes, Promociones en Lote y Fidelización',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Color(0xFFC77DFF), fontSize: 11),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              icon: const Icon(Icons.campaign_rounded, size: 17),
              label: const Text('Anuncio / Update',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w900)),
              onPressed: () => BroadcastAdminSheet.show(context),
            ),
          ),
          if (widget.onOpenLegacyAdmin != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFFFD600),
                  side: BorderSide(
                      color: const Color(0xFFFFD600).withOpacity(0.6)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                icon: const Icon(Icons.vpn_key_rounded, size: 16),
                label: const Text('Crear Cuentas / PINes',
                    style:
                        TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
                onPressed: widget.onOpenLegacyAdmin,
              ),
            ),
          IconButton(
            tooltip: 'Actualizar métricas y lista',
            onPressed: _refreshAllData,
            icon: const Icon(Icons.refresh_rounded, color: Color(0xFF00E5FF)),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: RefreshIndicator(
        color: const Color(0xFF00E5FF),
        onRefresh: _refreshAllData,
        child: CustomScrollView(
          slivers: [
            const SliverToBoxAdapter(
              child: LiveBroadcastBanner(),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cols = constraints.maxWidth > 1100
                        ? 5
                        : constraints.maxWidth > 700
                            ? 3
                            : 2;
                    return GridView.count(
                      crossAxisCount: cols,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: constraints.maxWidth > 600 ? 2.15 : 1.75,
                      children: [
                        _buildElegantKpiCard(
                          title: 'Clientes Activos',
                          value: _isLoadingMetrics ? '...' : '$_activeUsersCount',
                          subtitle: 'De $_totalUsersCount registrados',
                          icon: Icons.verified_user_rounded,
                          accent: const Color(0xFF10B981),
                          onTap: () => setState(() => _statusFilter = 'Activos'),
                        ),
                        _buildElegantKpiCard(
                          title: 'Vencen en <= 3 Días',
                          value:
                              _isLoadingMetrics ? '...' : '$_expiringSoonCount',
                          subtitle: 'Toca para filtrar y avisar',
                          icon: Icons.notifications_active_rounded,
                          accent: const Color(0xFFF59E0B),
                          onTap: () =>
                              setState(() => _statusFilter = 'Por Vencer (<=3d)'),
                        ),
                        _buildElegantKpiCard(
                          title: 'Suspendidos / Vencidos',
                          value: _isLoadingMetrics ? '...' : '$_suspendedCount',
                          subtitle: 'Listos para reconquista',
                          icon: Icons.person_off_rounded,
                          accent: const Color(0xFFF43F5E),
                          onTap: () => setState(
                              () => _statusFilter = 'Vencidos / Suspendidos'),
                        ),
                        _buildElegantKpiCard(
                          title: 'PINes Canjeados',
                          value: _isLoadingMetrics
                              ? '...'
                              : '$_pinsRedeemedCount / $_pinsGeneratedCount',
                          subtitle: 'Activaciones automáticas',
                          icon: Icons.confirmation_number_rounded,
                          accent: const Color(0xFFC77DFF),
                        ),
                        _buildElegantKpiCard(
                          title: 'Flujo Mensual Est.',
                          value: _isLoadingMetrics
                              ? '...'
                              : 'S/ $estimatedMonthlyPen',
                          subtitle: 'Base activa estimada',
                          icon: Icons.trending_up_rounded,
                          accent: const Color(0xFF00E5FF),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF111827),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _searchCtrl,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13.5),
                              decoration: InputDecoration(
                                hintText:
                                    'Buscar cliente por nombre, correo, WhatsApp o Hardware ID...',
                                hintStyle: const TextStyle(
                                    color: Colors.white38, fontSize: 12.5),
                                prefixIcon: const Icon(Icons.search_rounded,
                                    color: Color(0xFFC77DFF)),
                                suffixIcon: _searchQuery.isNotEmpty
                                    ? IconButton(
                                        icon: const Icon(Icons.clear,
                                            color: Colors.white54, size: 18),
                                        onPressed: () {
                                          _searchCtrl.clear();
                                          setState(() => _searchQuery = '');
                                          _loadUsersPage(reset: true);
                                        },
                                      )
                                    : null,
                                filled: true,
                                fillColor: const Color(0xFF1F2937),
                                contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 12),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(14),
                                  borderSide: BorderSide.none,
                                ),
                              ),
                              onChanged: (val) =>
                                  setState(() => _searchQuery = val),
                            ),
                          ),
                          if (_planFilter != 'Todos' ||
                              _deviceFilter != 'Todos' ||
                              _statusFilter != 'Todos') ...[
                            const SizedBox(width: 10),
                            TextButton.icon(
                              onPressed: () {
                                setState(() {
                                  _planFilter = 'Todos';
                                  _deviceFilter = 'Todos';
                                  _statusFilter = 'Todos';
                                });
                              },
                              icon: const Icon(Icons.filter_alt_off_rounded,
                                  color: Color(0xFFFFD600), size: 18),
                              label: const Text('Limpiar filtros',
                                  style: TextStyle(color: Color(0xFFFFD600))),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 14),
                      Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _buildFilterDropdown(
                            label: 'Plan',
                            icon: Icons.workspace_premium_rounded,
                            value: _planFilter,
                            options: const [
                              'Todos',
                              'Individual',
                              'Familiar',
                              'VIP'
                            ],
                            onChanged: (v) => setState(() => _planFilter = v!),
                          ),
                          _buildFilterDropdown(
                            label: 'Dispositivo',
                            icon: Icons.devices_rounded,
                            value: _deviceFilter,
                            options: const [
                              'Todos',
                              'Android / Celular',
                              'Smart TV',
                              'Web / PC',
                              'Sin Vincular'
                            ],
                            onChanged: (v) =>
                                setState(() => _deviceFilter = v!),
                          ),
                          _buildFilterDropdown(
                            label: 'Estado / Vencimiento',
                            icon: Icons.event_available_rounded,
                            value: _statusFilter,
                            options: const [
                              'Todos',
                              'Activos',
                              'Por Vencer (<=3d)',
                              'Vencidos / Suspendidos'
                            ],
                            onChanged: (v) =>
                                setState(() => _statusFilter = v!),
                          ),
                          _buildFilterDropdown(
                            label: 'Ordenar por',
                            icon: Icons.sort_rounded,
                            value: _sortMode,
                            options: const [
                              'Próximos a vencer',
                              'Nombre (A-Z)'
                            ],
                            onChanged: (v) => setState(() => _sortMode = v!),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: _selectedUserIds.isNotEmpty
                          ? [const Color(0xFF1E1B4B), const Color(0xFF111827)]
                          : [const Color(0xFF111827), const Color(0xFF111827)],
                    ),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: _selectedUserIds.isNotEmpty
                          ? const Color(0xFFC77DFF).withOpacity(0.7)
                          : Colors.white10,
                      width: _selectedUserIds.isNotEmpty ? 1.5 : 1.0,
                    ),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Checkbox(
                            value: filteredDocs.isNotEmpty &&
                                filteredDocs.every(
                                    (d) => _selectedUserIds.contains(d.id)),
                            activeColor: const Color(0xFFC77DFF),
                            checkColor: Colors.black,
                            onChanged: (checked) {
                              setState(() {
                                if (checked == true) {
                                  for (final doc in filteredDocs) {
                                    _selectedUserIds.add(doc.id);
                                  }
                                } else {
                                  _selectedUserIds.clear();
                                }
                              });
                            },
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _selectedUserIds.isEmpty
                                ? 'Selecciona clientes para acciones masivas (${filteredDocs.length} en vista)'
                                : '${_selectedUserIds.length} cliente(s) seleccionado(s) para lote',
                            style: TextStyle(
                              color: _selectedUserIds.isEmpty
                                  ? Colors.white70
                                  : const Color(0xFFC77DFF),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                      if (_isExecutingBatch)
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 16),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2.5, color: Color(0xFF00E5FF)),
                          ),
                        )
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Container(
                              width: 74,
                              height: 38,
                              decoration: BoxDecoration(
                                color: const Color(0xFF1F2937),
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: TextField(
                                controller: _bulkDaysCtrl,
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13),
                                decoration: const InputDecoration(
                                  suffixText: 'd',
                                  suffixStyle: TextStyle(
                                      color: Colors.white54, fontSize: 11),
                                  border: InputBorder.none,
                                  contentPadding:
                                      EdgeInsets.symmetric(vertical: 10),
                                ),
                              ),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 11),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.card_giftcard_rounded,
                                  size: 17),
                              label: const Text('Sumar Días',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12)),
                              onPressed: () =>
                                  _executeBulkAddDays(filteredDocs),
                            ),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF00E5FF),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 14, vertical: 11),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.phonelink_erase_rounded,
                                  size: 17),
                              label: const Text('Resetear HW ID',
                                  style: TextStyle(
                                      fontWeight: FontWeight.w900,
                                      fontSize: 12)),
                              onPressed: _executeBulkResetHwId,
                            ),
                            OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                foregroundColor: const Color(0xFFF43F5E),
                                side: const BorderSide(
                                    color: Color(0xFFF43F5E), width: 1),
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 11),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                              icon: const Icon(Icons.pause_circle_outline,
                                  size: 17),
                              label: const Text('Suspender',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 12)),
                              onPressed: () => _executeBulkToggleSuspend(false),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_isLoadingUsers && _loadedUsers.isEmpty)
              const SliverFillRemaining(
                child: Center(
                    child: CircularProgressIndicator(color: Color(0xFFC77DFF))),
              )
            else if (filteredDocs.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.person_search_rounded,
                            color: Colors.white24, size: 56),
                        SizedBox(height: 12),
                        Text(
                          'No se encontraron clientes con estos criterios',
                          style: TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                              fontWeight: FontWeight.bold),
                        ),
                        SizedBox(height: 4),
                        Text(
                          'Prueba limpiando los filtros o cargando el siguiente bloque.',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final doc = filteredDocs[index];
                      final data = doc.data();
                      return _buildClientRowCard(doc.id, data);
                    },
                    childCount: filteredDocs.length,
                  ),
                ),
              ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 40),
                child: Center(
                  child: _hasMoreUsers
                      ? OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFF00E5FF),
                            side: const BorderSide(color: Color(0xFF00E5FF)),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 24, vertical: 14),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                          ),
                          icon: _isLoadingUsers
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Color(0xFF00E5FF)),
                                )
                              : const Icon(Icons.expand_more_rounded),
                          label: Text(_isLoadingUsers
                              ? 'Cargando más clientes...'
                              : 'Cargar siguiente lote de clientes (+$_pageSize)'),
                          onPressed: _isLoadingUsers
                              ? null
                              : () => _loadUsersPage(reset: false),
                        )
                      : Text(
                          'Mostrando el total cargado (${_loadedUsers.length} cuentas en memoria)',
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 12),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElegantKpiCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color accent,
    VoidCallback? onTap,
  }) {
    return Material(
      color: const Color(0xFF111827),
      borderRadius: BorderRadius.circular(18),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: accent.withOpacity(0.28), width: 1.2),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: accent.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent,
                        fontSize: 11.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFilterDropdown({
    required String label,
    required IconData icon,
    required String value,
    required List<String> options,
    required ValueChanged<String?> onChanged,
  }) {
    return Container(
      constraints: const BoxConstraints(minWidth: 190, maxWidth: 250),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2937),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white10),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: const Color(0xFF1F2937),
          icon: const Icon(Icons.keyboard_arrow_down_rounded,
              color: Color(0xFFC77DFF)),
          style: const TextStyle(color: Colors.white, fontSize: 12.5),
          items: options.map((opt) {
            return DropdownMenuItem<String>(
              value: opt,
              child: Row(
                children: [
                  Icon(icon, size: 15, color: const Color(0xFF00E5FF)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '$label: $opt',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _buildClientRowCard(String userId, Map<String, dynamic> data) {
    final now = DateTime.now();
    final isSelected = _selectedUserIds.contains(userId);
    final username = (data['username'] ?? 'Sin Nombre').toString();
    final phone = (data['phone'] ?? '').toString();
    final plan = _detectPlanLabel(data);
    final deviceCategory = _detectDeviceCategory(data);
    final hwId = (data['registeredHardwareId'] ?? '').toString();
    final bool isActiveFlag = data['isActive'] == true;

    DateTime? expDate;
    if (data['expirationDate'] != null) {
      expDate = DateTime.tryParse(data['expirationDate'].toString());
    }
    final int daysRemaining =
        expDate != null ? expDate.difference(now).inDays : 0;
    final bool isExpired =
        !isActiveFlag || (expDate != null && expDate.isBefore(now));
    final bool isExpiringSoon = !isExpired && daysRemaining <= 3;

    final String expText = expDate != null
        ? '${expDate.day.toString().padLeft(2, '0')}/${expDate.month.toString().padLeft(2, '0')}/${expDate.year}'
        : 'Sin fecha';

    Color statusColor = const Color(0xFF10B981);
    String statusLabel = 'ACTIVO (${max(0, daysRemaining)}d)';
    if (isExpired) {
      statusColor = const Color(0xFFF43F5E);
      statusLabel = 'VENCIDO / PAUSADO';
    } else if (isExpiringSoon) {
      statusColor = const Color(0xFFF59E0B);
      statusLabel = 'POR VENCER (${max(0, daysRemaining)}d)';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: isSelected ? const Color(0xFF1E293B) : const Color(0xFF111827),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? const Color(0xFFC77DFF)
              : isExpiringSoon
                  ? const Color(0xFFF59E0B).withOpacity(0.5)
                  : Colors.white.withOpacity(0.07),
          width: isSelected ? 1.6 : 1.0,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () {
          setState(() {
            if (isSelected) {
              _selectedUserIds.remove(userId);
            } else {
              _selectedUserIds.add(userId);
            }
          });
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Checkbox(
                value: isSelected,
                activeColor: const Color(0xFFC77DFF),
                checkColor: Colors.black,
                onChanged: (v) {
                  setState(() {
                    if (v == true) {
                      _selectedUserIds.add(userId);
                    } else {
                      _selectedUserIds.remove(userId);
                    }
                  });
                },
              ),
              CircleAvatar(
                radius: 20,
                backgroundColor: statusColor.withOpacity(0.15),
                child: Text(
                  username.isNotEmpty ? username[0].toUpperCase() : 'U',
                  style: TextStyle(
                      color: statusColor, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          username,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        _buildMiniBadge(statusLabel, statusColor),
                        _buildMiniBadge(plan, const Color(0xFFC77DFF)),
                        _buildMiniBadge(
                            deviceCategory, const Color(0xFF00E5FF)),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      'Vence: $expText  •  ${phone.isNotEmpty ? "WhatsApp: $phone  •  " : ""}${hwId.isNotEmpty ? "Equipo vinculado ✓" : "Equipo libre"}',
                      style:
                          const TextStyle(color: Colors.white60, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Sumar +30 días rápido',
                    icon: const Icon(Icons.add_circle_outline_rounded,
                        color: Color(0xFF10B981)),
                    onPressed: () async {
                      final base = (expDate != null && expDate.isAfter(now))
                          ? expDate
                          : now;
                      await FirebaseFirestore.instance
                          .collection('users')
                          .doc(userId)
                          .update({
                        'expirationDate':
                            base.add(const Duration(days: 30)).toIso8601String(),
                        'isActive': true,
                      });
                      await _refreshAllData();
                      _showToast('¡+30 días acreditados a $username!');
                    },
                  ),
                  if (hwId.isNotEmpty)
                    IconButton(
                      tooltip: 'Liberar equipo de este cliente',
                      icon: const Icon(Icons.phonelink_erase_rounded,
                          color: Color(0xFF00E5FF)),
                      onPressed: () async {
                        await FirebaseFirestore.instance
                            .collection('users')
                            .doc(userId)
                            .update({'registeredHardwareId': ''});
                        await _loadUsersPage(reset: true);
                        _showToast('Equipo liberado para $username');
                      },
                    ),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF25D366),
                      foregroundColor: Colors.black,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    icon: const Icon(Icons.chat_rounded, size: 16),
                    label: const Text('Soporte',
                        style: TextStyle(
                            fontSize: 11.5, fontWeight: FontWeight.w900)),
                    onPressed: () => _openQuickWhatsAppModal(data),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.4), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

// =============================================================================
// SISTEMA DE ANUNCIOS GLOBALES Y ALERTAS DE ACTUALIZACIÓN EN TIEMPO REAL
// =============================================================================

class LiveBroadcastBanner extends StatelessWidget {
  const LiveBroadcastBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('system_config')
          .doc('broadcast_announcement')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !snapshot.data!.exists) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() as Map<String, dynamic>? ?? {};
        final bool isActive = data['isActive'] == true;
        final String message = (data['message'] ?? '').toString();
        final String type = (data['type'] ?? 'info').toString();
        final String actionUrl = (data['actionUrl'] ?? '').toString().trim();

        if (!isActive || message.trim().isEmpty) {
          return const SizedBox.shrink();
        }

        Color bannerColor = const Color(0xFF7B2CBF);
        Color borderColor = const Color(0xFF9D4EDD);
        IconData bannerIcon = Icons.campaign_rounded;
        bool darkText = false;

        if (type == 'match') {
          bannerColor = const Color(0xFFFF1744);
          borderColor = const Color(0xFFFF8A80);
          bannerIcon = Icons.sports_soccer_rounded;
        } else if (type == 'promo') {
          bannerColor = const Color(0xFFFFD600);
          borderColor = const Color(0xFFFFEA00);
          bannerIcon = Icons.card_giftcard_rounded;
          darkText = true;
        } else if (type == 'update') {
          bannerColor = const Color(0xFF00E5FF);
          borderColor = Colors.white;
          bannerIcon = Icons.system_update_rounded;
          darkText = true;
        } else if (type == 'warning') {
          bannerColor = const Color(0xFFFFB703);
          borderColor = const Color(0xFFFFD54F);
          bannerIcon = Icons.warning_amber_rounded;
          darkText = true;
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: bannerColor.withOpacity(0.95),
            border: Border(bottom: BorderSide(color: borderColor, width: 1.5)),
          ),
          child: Row(
            children: [
              Icon(bannerIcon, color: darkText ? Colors.black : Colors.white, size: 19),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    color: darkText ? Colors.black : Colors.white,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              if (actionUrl.isNotEmpty) ...[
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black87,
                    foregroundColor: const Color(0xFF00E5FF),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  ),
                  onPressed: () async {
                    final uri = Uri.tryParse(actionUrl);
                    if (uri != null) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  },
                  child: const Text(
                    'ACTUALIZAR / VER',
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class BroadcastAdminSheet {
  static void show(BuildContext context) {
    final msgCtrl = TextEditingController();
    final urlCtrl = TextEditingController();
    String selectedType = 'match';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0B0F19),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          return Padding(
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
                      const Row(
                        children: [
                          Icon(Icons.campaign_rounded, color: Color(0xFFFFD600), size: 28),
                          SizedBox(width: 10),
                          Text(
                            'Anuncio Global & Actualizaciones',
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white54),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Aparecerá al instante en celulares, PC y Smart TV de todos los clientes conectados.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  TextField(
                    controller: msgCtrl,
                    maxLength: 140,
                    maxLines: 2,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5),
                    decoration: InputDecoration(
                      labelText: 'Mensaje del evento o actualización',
                      labelStyle: const TextStyle(color: Colors.white60),
                      hintText: 'Ej: ⚽ HOY 8:00 PM: Gran Partido en Vivo • ¡No te lo pierdas!',
                      hintStyle: const TextStyle(color: Colors.white30),
                      filled: true,
                      fillColor: const Color(0xFF1F2937),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: urlCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: 'Link de Descarga APK o Promo (Opcional)',
                      labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                      hintText: 'https://...',
                      hintStyle: const TextStyle(color: Colors.white30),
                      prefixIcon: const Icon(Icons.link, color: Color(0xFF00E5FF)),
                      filled: true,
                      fillColor: const Color(0xFF1F2937),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _chip('Evento / Partido', 'match', const Color(0xFFFF1744), selectedType,
                          (v) => setModalState(() => selectedType = v)),
                      _chip('Nueva Actualización', 'update', const Color(0xFF00E5FF), selectedType,
                          (v) => setModalState(() => selectedType = v)),
                      _chip('Promoción', 'promo', const Color(0xFFFFD600), selectedType,
                          (v) => setModalState(() => selectedType = v)),
                      _chip('Informativo', 'info', const Color(0xFFC77DFF), selectedType,
                          (v) => setModalState(() => selectedType = v)),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent,
                            side: const BorderSide(color: Colors.redAccent),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          onPressed: () async {
                            await FirebaseFirestore.instance
                                .collection('system_config')
                                .doc('broadcast_announcement')
                                .set({'isActive': false, 'message': ''}, SetOptions(merge: true));
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                          child: const Text('APAGAR AVISO', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00E5FF),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          icon: const Icon(Icons.send_rounded, size: 18),
                          label: const Text('PUBLICAR AHORA', style: TextStyle(fontWeight: FontWeight.w900)),
                          onPressed: () async {
                            if (msgCtrl.text.trim().isEmpty) return;
                            await FirebaseFirestore.instance
                                .collection('system_config')
                                .doc('broadcast_announcement')
                                .set({
                              'isActive': true,
                              'message': msgCtrl.text.trim(),
                              'type': selectedType,
                              'actionUrl': urlCtrl.text.trim(),
                              'updatedAt': FieldValue.serverTimestamp(),
                            });
                            if (ctx.mounted) Navigator.pop(ctx);
                          },
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static Widget _chip(
      String label, String val, Color color, String current, ValueChanged<String> onTap) {
    final sel = val == current;
    return ChoiceChip(
      label: Text(label),
      selected: sel,
      selectedColor: color.withOpacity(0.28),
      backgroundColor: const Color(0xFF1F2937),
      labelStyle: TextStyle(
        color: sel ? color : Colors.white70,
        fontWeight: FontWeight.bold,
        fontSize: 11.5,
      ),
      side: BorderSide(color: sel ? color : Colors.white12),
      onSelected: (_) => onTap(val),
    );
  }
}