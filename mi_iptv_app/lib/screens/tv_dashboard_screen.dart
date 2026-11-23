import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import '../models/channel_model.dart';
import '../widgets/pro_video_player.dart';
import '../widgets/focusable_tv_card.dart';
import '../widgets/zapping_channel_overlay.dart';
import '../widgets/pin_dialog.dart';
import '../widgets/alexa_voice_sheet.dart';
import '../widgets/onboarding_tutorial_modal.dart';
import '../widgets/live_chat_overlay.dart';
import '../services/remote_control_service.dart';
import '../services/m3u_sanitizer_service.dart';
import '../services/auth_service.dart';
import '../services/epg_service.dart';
import '../services/dvr_recording_service.dart';
import '../services/parental_service.dart';
import '../services/player_settings_service.dart';
import '../services/app_update_guard.dart';
import '../utils/premium_manager.dart';
import 'profile_selector_screen.dart';
import 'remote_control_screen.dart';
import 'family_panel_screen.dart';
import 'tv_vod_details_screen.dart';

List<ChannelModel> _parseM3uInBackgroundTv(String rawM3u) {
  return M3USanitizerService.parseAndSanitize(rawM3u);
}
class TvDashboardScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const TvDashboardScreen({super.key, this.onLogout});

  @override
  State<TvDashboardScreen> createState() => _TvDashboardScreenState();
}

class _TvDashboardScreenState extends State<TvDashboardScreen> {
  final GlobalKey<ProVideoPlayerState> _playerKey = GlobalKey<ProVideoPlayerState>();
  final FocusScopeNode _tvFocusScope = FocusScopeNode();
  final FocusNode _sidebarFocusNode = FocusNode();
  final FocusNode _zappingFocusNode = FocusNode();
  final FocusScopeNode _channelDrawerFocusNode = FocusScopeNode();
  final TextEditingController _tvSearchCtrl = TextEditingController();

  bool _isChannelDrawerOpen = false;
  bool _osdInteractive = false;
  String _selectedLiveCategory = 'Todos';
  String _tvChannelSearchQuery = '';
  final Set<String> _favoriteChannelUrls = {};
  static const MethodChannel _deviceChannel = MethodChannel('ameycar.tv/device');
  bool _showLiveChat = false;
  bool _autoStartOnBoot = true;
  bool _hasOverlayPermission = false;
  double _currentVolume = 1.0;
  double _volumeBeforeMute = 1.0;
  StreamSubscription? _cloudPlaylistSub;

  bool _isSidebarExpanded = false;
  bool _isZappingOverlayVisible = false;
  Timer? _zappingHideTimer;

  // Por defecto iniciamos en el modo Televisión
  String _selectedSection = 'Televisión';

  // Pestañas y filtros para el Catálogo de Cine & Series (VOD)
  String _selectedVodTab = 'Películas';
  String _selectedVodCategory = 'Todos';

  // LISTAS DE CONTENIDO REAL
  List<ChannelModel> _channels = [];
  List<ChannelModel> _movies = [];
  List<ChannelModel> _series = [];
  List<ChannelModel> _liveTv = [];

  int _selectedChannelIndex = 0;

  // VARIABLES DE SINCRONIZACIÓN DE PROGRESO Y LISTAS
  Timer? _progressSyncTimer;
  String? _currentStreamId;
  int _currentPlaybackPosition = 0;
  List<dynamic> _savedPlaylists = [];

  // VARIABLES DE DVR Y OSD (La pantalla siempre es Full Screen ahora)
  bool _showOsd = false;
  bool _isPlayerPaused = false;
  bool _isBehindLive = false;
  bool _isPlayingDvrRecording = false;
  String? _activeDvrTitle;
  String? _activeDvrFilePath;
  Timer? _osdHideTimer;

  // VARIABLES DE CONFIGURACIÓN Y PERFIL
  String _selectedLanguage = 'Español (Latinoamérica)';
  String _selectedColorBlindMode = 'Normal';
  int _customAvatarIdx = 0;
  String _hardwareId = 'Cargando...';
  final Set<String> _activeAlarms = {};
  Timer? _clockTimer;
  final ValueNotifier<String> _currentTimeNotifier = ValueNotifier<String>('');

  // VARIABLES DE ANUNCIOS GLOBALES EN TIEMPO REAL
  StreamSubscription? _globalAnnouncementSub;
  String _activeGlobalAnnouncement = '';
  String _activeGlobalAnnouncementTitle = '';
  String _lastDismissedAnnouncementId = '';

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
    EpgService.ensureInitialized();
    PlayerSettingsService.initialize();
    ParentalService.getHiddenMenuItems().then((_) {
      if (mounted) setState(() {});
    });
    ParentalService.getProfanityFilterEnabled();
    _startClockTimer();
    _loadInitialPreferences();
    _loadChannels();
    _listenToGlobalAnnouncements();
    _startCloudPlaylistsRealtimeListener();
    _startListeningRemoteTvCommands();
    _checkAutoStartAndOverlayStatus(promptIfMissing: true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      OnboardingTutorialModal.showIfFirstTime(
        context,
        isTv: true,
        onOpenM3uManager: _openM3uDialog,
      );
    });
  }

  void _listenToGlobalAnnouncements() {
    if (!AuthService.isFirebaseAvailable) return;
    try {
      _globalAnnouncementSub = FirebaseFirestore.instance
          .collection('app_config')
          .doc('global_announcement')
          .snapshots()
          .listen((doc) {
        if (!doc.exists || !mounted) return;
        final data = doc.data();
        if (data == null) return;

        final bool isActive = data['active'] == true || data['isActive'] == true;
        final String msg = (data['message'] ?? data['text'] ?? data['body'] ?? '').toString().trim();
        final String title = (data['title'] ?? '📢 ANUNCIO OFICIAL AMEYCAR TV').toString().trim();
        final String id = (data['id'] ?? data['timestamp']?.toString() ?? msg).toString();

        if (isActive && msg.isNotEmpty && id != _lastDismissedAnnouncementId) {
          setState(() {
            _activeGlobalAnnouncement = msg;
            _activeGlobalAnnouncementTitle = title;
          });
        } else if (!isActive && mounted) {
          setState(() {
            _activeGlobalAnnouncement = '';
          });
        }
      }, onError: (_) {});
    } catch (_) {}
  }

  void _startClockTimer() {
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) _updateClock();
    });
  }

  void _updateClock() {
    final now = DateTime.now();
    final h = now.hour.toString().padLeft(2, '0');
    final m = now.minute.toString().padLeft(2, '0');
    final s = now.second.toString().padLeft(2, '0');
    _currentTimeNotifier.value = '$h:$m:$s';
  }

  Future<void> _loadInitialPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hw = await AuthService.getDeviceHardwareId();
      final alarms =
          prefs.getStringList('saved_active_alarms_$_currentProfileId') ?? [];
      final favs =
          prefs.getStringList('favorite_channels_$_currentProfileId') ??
              prefs.getStringList('favorite_channels') ??
              [];
      if (mounted) {
        setState(() {
          _selectedLanguage =
              prefs.getString('app_lang') ?? 'Español (Latinoamérica)';
          _selectedColorBlindMode =
              prefs.getString('color_blind_mode') ?? 'Normal';
          _customAvatarIdx =
              prefs.getInt('custom_avatar_$_currentProfileId') ?? 0;
          _hardwareId = hw;
          _activeAlarms
            ..clear()
            ..addAll(alarms);
          _favoriteChannelUrls
            ..clear()
            ..addAll(favs);
        });
      }
    } catch (_) {}
  }

  bool _isChannelFavorite(ChannelModel channel) {
    return _favoriteChannelUrls.contains(channel.streamUrl);
  }

  Future<void> _toggleFavoriteChannel(ChannelModel channel) async {
    final prefs = await SharedPreferences.getInstance();
    final wasFav = _favoriteChannelUrls.contains(channel.streamUrl);
    setState(() {
      if (wasFav) {
        _favoriteChannelUrls.remove(channel.streamUrl);
      } else {
        _favoriteChannelUrls.add(channel.streamUrl);
      }
    });
    final list = _favoriteChannelUrls.toList();
    await prefs.setStringList('favorite_channels_$_currentProfileId', list);
    await prefs.setStringList('favorite_channels', list);
    if (_showOsd) _triggerOsdTimer();
    if (mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            wasFav
                ? '☆ "${channel.name}" quitado de Favoritos'
                : '⭐ "${channel.name}" agregado a Favoritos',
            style: const TextStyle(
                fontWeight: FontWeight.bold, color: Colors.black),
          ),
          backgroundColor:
              wasFav ? Colors.white70 : const Color(0xFFFFD600),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
          width: 420,
        ),
      );
    }
  }

  void _openChannelDrawer() {
    _osdHideTimer?.cancel();
    _zappingHideTimer?.cancel();
    setState(() {
      _selectedSection = 'Televisión';
      _showOsd = false;
      _osdInteractive = false;
      _isZappingOverlayVisible = false;
      _isSidebarExpanded = false;
      _isChannelDrawerOpen = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusScope.of(context).requestFocus(_channelDrawerFocusNode);
        _channelDrawerFocusNode.nextFocus();
      }
    });
  }

  void _closeChannelDrawer() {
    setState(() => _isChannelDrawerOpen = false);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        FocusScope.of(context).requestFocus(_tvFocusScope);
      }
    });
  }

  Future<void> _loadChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      bool loadedFromCloud = false;
      final user = AuthService.currentUser;

      if (user != null && AuthService.isFirebaseAvailable) {
        try {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.id)
              .get();
          final data = doc.data();
          final rawCloud = data?['m3u_playlists_$_currentProfileId'] ??
              data?['m3u_playlists'];

          if (rawCloud is List && rawCloud.isNotEmpty) {
            final List<dynamic> cloudList = [];
            for (final item in rawCloud) {
              if (item is Map) {
                cloudList.add(Map<String, dynamic>.from(item));
              }
            }
            _savedPlaylists = cloudList;
            await prefs.setString(
                'm3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
            loadedFromCloud = true;
          }
        } catch (e) {
          debugPrint('Aviso leyendo M3U desde la nube en TV: $e');
        }
      }

      if (!loadedFromCloud) {
        final rawLists = prefs.getString('m3u_lists_$_currentProfileId');
        if (rawLists != null && rawLists.isNotEmpty) {
          final decoded = jsonDecode(rawLists);
          if (decoded is List) {
            final List<dynamic> localList = [];
            for (final item in decoded) {
              if (item is Map) {
                localList.add(Map<String, dynamic>.from(item));
              }
            }
            _savedPlaylists = localList;
          }
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
            await prefs.setString(
                'm3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
          }
        }
      }

      Map<String, dynamic>? activePlaylist;
      for (final pl in _savedPlaylists) {
        if (pl is Map && pl['isActive'] == true) {
          activePlaylist = Map<String, dynamic>.from(pl);
          break;
        }
      }

      String? savedM3u;
      if (activePlaylist != null) {
        final plId = activePlaylist['id']?.toString() ?? '';
        savedM3u = prefs.getString('m3u_cache_$plId');

        if (savedM3u == null || savedM3u.trim().isEmpty) {
          final activeUrl = (activePlaylist['url'] ?? '').toString().trim();
          if (activeUrl.isNotEmpty) {
            await _downloadAndSanitizeM3u(
              activeUrl,
              playlistId: plId,
              playlistName: activePlaylist['name']?.toString(),
            );
            return;
          }
        }
      } else {
        savedM3u = prefs.getString('saved_m3u_content');
      }

      List<ChannelModel> loadedChannels = [];
      if (savedM3u != null && savedM3u.isNotEmpty) {
        unawaited(EpgService.extractAndSaveEpgUrlFromM3u(savedM3u));
        loadedChannels = await compute(_parseM3uInBackgroundTv, savedM3u);
      } else {
        loadedChannels = M3USanitizerService.getCuratedChannels();
      }

      if (mounted) {
        final int lastIndex = prefs.getInt('last_played_channel_index') ?? 0;
        setState(() {
          _channels = loadedChannels;
          _movies = _channels.where((c) => c.contentType == 'movie').toList();
          _series = _channels.where((c) => c.contentType == 'series').toList();
          _liveTv = _channels.where((c) => c.contentType == 'live').toList();

          if (_channels.isNotEmpty) {
            _selectedChannelIndex =
                (lastIndex < _channels.length && lastIndex >= 0) ? lastIndex : 0;
            _startProgressSync(_channels[_selectedChannelIndex].streamUrl);
          }
        });
      }
    } catch (e) {
      debugPrint("Error cargando canales reales en TV: $e");
    }
  }

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

  Future<void> _downloadAndSanitizeM3u(
    String url, {
    String? playlistId,
    String? playlistName,
  }) async {
    try {
      final res = await http.get(Uri.parse(url));
      if (res.statusCode == 200) {
        await EpgService.extractAndSaveEpgUrlFromM3u(res.body);
        final parsed = await compute(_parseM3uInBackgroundTv, res.body);
        if (parsed.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          try {
            await prefs.setString('saved_m3u_url', url);
            await prefs.setString('saved_m3u_content', res.body);
            if (playlistId != null && playlistId.isNotEmpty) {
              await prefs.setString('m3u_cache_$playlistId', res.body);
            }
          } catch (storageError) {
            debugPrint('Aviso de almacenamiento en TV: $storageError');
          }
          await prefs.setInt('last_played_channel_index', 0);

          if (mounted) {
            setState(() {
              _channels = parsed;
              _movies = _channels.where((c) => c.contentType == 'movie').toList();
              _series = _channels.where((c) => c.contentType == 'series').toList();
              _liveTv = _channels.where((c) => c.contentType == 'live').toList();
              _selectedChannelIndex = 0;
            });
            _startProgressSync(_channels[0].streamUrl);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('¡${parsed.length} elementos sincronizados en "${playlistName ?? "Lista"}"!'),
                backgroundColor: const Color(0xFF00C853),
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint('Error descargando M3U en TV: $e');
    }
  }

  void _startProgressSync(String streamUrl) {
    _currentStreamId = streamUrl;
    _progressSyncTimer?.cancel();

    _progressSyncTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_currentStreamId != null) {
        _currentPlaybackPosition += 5;
        try {
          final box = Hive.box('watch_progress_box');
          await box.put(_currentStreamId, {
            'position': _currentPlaybackPosition,
            'updated_at': DateTime.now().millisecondsSinceEpoch,
          });
        } catch (_) {}
      }
    });
  }

  Future<void> _syncProgressToCloud() async {
    if (_currentStreamId == null) return;
    try {
      final box = Hive.box('watch_progress_box');
      final localData = box.get(_currentStreamId);

      if (localData != null) {
        final user = AuthService.currentUser;
        if (user != null && AuthService.isFirebaseAvailable) {
          final safeDocId = Uri.encodeComponent(_currentStreamId!);
          await FirebaseFirestore.instance
              .collection('users')
              .doc(user.id)
              .collection('watch_history')
              .doc(safeDocId)
              .set({
            'stream_url': _currentStreamId,
            'position': localData['position'] ?? _currentPlaybackPosition,
            'last_updated': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      }
    } catch (_) {}
  }

  void _playContent(ChannelModel channel) async {
    if (channel.contentType == 'movie' || channel.contentType == 'series') {
      final bool? playNow = await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TvVodDetailsScreen(item: channel),
        ),
      );

      if (playNow != true) {
        return;
      }
    }

    int index = _channels.indexWhere((c) => c.id == channel.id && c.streamUrl == channel.streamUrl);
    if (index == -1) {
      index = _channels.indexOf(channel);
    }
    if (index == -1) {
      setState(() {
        _channels.add(channel);
        index = _channels.length - 1;
      });
    }

    if (index != -1) {
      unawaited(_syncProgressToCloud());
      _currentPlaybackPosition = 0;

      setState(() {
        _selectedSection = 'Televisión';
        _selectedChannelIndex = index;
        _isChannelDrawerOpen = false;
        _isSidebarExpanded = false;
        _isZappingOverlayVisible = false;
        _showOsd = true;
        _osdInteractive = false;
        _isPlayerPaused = false;
        _isBehindLive = false;
        _isPlayingDvrRecording = false;
        _activeDvrTitle = null;
        _activeDvrFilePath = null;
      });
      FocusScope.of(context).requestFocus(_tvFocusScope);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_played_channel_index', index);
      _startProgressSync(channel.streamUrl);
      _triggerOsdTimer();

      if (mounted) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '▶ Reproduciendo: ${channel.name}',
              style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
            ),
            backgroundColor: const Color(0xFF00E5FF),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
            width: 400,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    }
  }

  void _startVoiceSearch() {
    List<ChannelModel> searchPool;
    if (_selectedSection == 'Cine IA' && (_movies.isNotEmpty || _series.isNotEmpty)) {
      searchPool = [..._movies, ..._series];
    } else if (_selectedSection == 'Series' && _series.isNotEmpty) {
      searchPool = _series;
    } else {
      searchPool = _channels;
    }

    AlexaVoiceSheet.show(
      context: context,
      channels: searchPool,
      currentSection: _selectedSection,
      currentChannel: _channels.isNotEmpty && _selectedChannelIndex < _channels.length
          ? _channels[_selectedChannelIndex]
          : null,
      onChannelSelected: (item) {
        if (item is ChannelModel) {
          _playContent(item);
        }
      },
      onOpenEpg: () {
        if (_channels.isNotEmpty && _selectedChannelIndex < _channels.length) {
          _openTvEpgModal(_channels[_selectedChannelIndex]);
        }
      },
      onCategorySelected: (cat) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Aplicando filtro: $cat'),
            backgroundColor: const Color(0xFF7B2CBF),
          ),
        );
      },
    );
  }

  Future<void> _seekRelativeSeconds(int deltaSeconds) async {
    final activeCh = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    void executeSeek() {
      _triggerOsdTimer();
      try {
        _playerKey.currentState?.seekRelative(deltaSeconds);
        if (mounted) {
          setState(() {
            if (deltaSeconds < 0) {
              _isBehindLive = true;
              _isPlayerPaused = false;
            }
          });
          ScaffoldMessenger.of(context).clearSnackBars();
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                deltaSeconds < 0
                    ? '⏪ Retrocediendo ${deltaSeconds.abs()}s...'
                    : '⏩ Adelantando +${deltaSeconds}s...',
              ),
              duration: const Duration(milliseconds: 900),
              backgroundColor: const Color(0xFF1E293B),
            ),
          );
        }
      } catch (_) {}
    }

    // BLOQUEO PREMIUM: Si retrocede (delta < 0) en TV en Vivo, pide VIP
    if (deltaSeconds < 0 && activeCh?.contentType == 'live') {
      PremiumManager.runIfPremium(context, action: executeSeek);
    } else {
      executeSeek();
    }
  }

  Future<void> _executeSeekRelative(int deltaSeconds) async {
    _triggerOsdTimer();
    try {
      _playerKey.currentState?.seekRelative(deltaSeconds);
      if (mounted) {
        setState(() {
          if (deltaSeconds < 0) {
            _isBehindLive = true;
            _isPlayerPaused = false;
          }
        });
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              deltaSeconds < 0
                  ? '⏪ Retrocediendo ${deltaSeconds.abs()}s...'
                  : '⏩ Adelantando +${deltaSeconds}s...',
            ),
            duration: const Duration(milliseconds: 900),
            backgroundColor: const Color(0xFF1E293B),
          ),
        );
      }
    } catch (_) {}
  }

  void _jumpBackToLiveStream() {
    if (_channels.isEmpty) return;
    final activeCh = _channels[_selectedChannelIndex];
    setState(() {
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrTitle = null;
      _activeDvrFilePath = null;
      _isPlayerPaused = false;
    });
    _playerKey.currentState?.jumpToLiveEdge();
    _triggerOsdTimer();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('⚡ Volviendo a la señal EN VIVO de ${activeCh.name}'),
        duration: const Duration(seconds: 2),
        backgroundColor: const Color(0xFF00C853),
      ),
    );
  }

  Future<void> _toggleManualDvrRecording(ChannelModel? activeChannel) async {
    PremiumManager.runIfPremium(context, action: () async {
      if (activeChannel == null || kIsWeb) return;

      if (DvrRecordingService.isRecordingNotifier.value) {
        final savedItem = await DvrRecordingService.stopRecording();
        if (mounted) {
          setState(() {});
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                savedItem != null
                    ? '✅ Grabación guardada: "${savedItem.programTitle}"'
                    : '⚠️ Grabación detenida.',
              ),
              backgroundColor: const Color(0xFF1B2C0F),
            ),
          );
        }
      } else {
        final currentProg = EpgService.getCurrentProgram(
            activeChannel.name, activeChannel.groupCategory);
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
                    ? '🔴 Grabando "${currentProg.title}" (Máx 60m)...'
                    : '❌ Error al iniciar grabación.',
              ),
              backgroundColor: started ? const Color(0xFF4A0E0E) : Colors.red,
            ),
          );
        }
      }
    });
  }

  void _toggleOsd({bool interactive = true}) {
    setState(() {
      if (_showOsd && _osdInteractive) {
        _showOsd = false;
        _osdInteractive = false;
        _osdHideTimer?.cancel();
        FocusScope.of(context).requestFocus(_tvFocusScope);
      } else {
        _showOsd = true;
        _osdInteractive = interactive;
        _triggerOsdTimer();
      }
    });
  }

  void _closeOsd() {
    _osdHideTimer?.cancel();
    setState(() {
      _showOsd = false;
      _osdInteractive = false;
    });
    FocusScope.of(context).requestFocus(_tvFocusScope);
  }

  void _triggerOsdTimer() {
    _osdHideTimer?.cancel();
    _osdHideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() {
          _showOsd = false;
          _osdInteractive = false;
        });
        if (!_isChannelDrawerOpen && !_isSidebarExpanded) {
          FocusScope.of(context).requestFocus(_tvFocusScope);
        }
      }
    });
  }

  void _nextChannel() {
    if (_channels.isEmpty) return;
    unawaited(_syncProgressToCloud());
    _currentPlaybackPosition = 0;
    final int total = _channels.length;
    final int nextIndex = (_selectedChannelIndex + 1).remainder(total);
    setState(() {
      _selectedChannelIndex = nextIndex;
      _isPlayerPaused = false;
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrFilePath = null;
      _showOsd = true;
      _osdInteractive = false;
    });
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('last_played_channel_index', nextIndex);
    });
    _triggerOsdTimer();
    _startProgressSync(_channels[nextIndex].streamUrl);
  }

  void _previousChannel() {
    if (_channels.isEmpty) return;
    unawaited(_syncProgressToCloud());
    _currentPlaybackPosition = 0;
    final int total = _channels.length;
    final int prevIndex =
        (_selectedChannelIndex - 1 < 0) ? total - 1 : _selectedChannelIndex - 1;
    setState(() {
      _selectedChannelIndex = prevIndex;
      _isPlayerPaused = false;
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrFilePath = null;
      _showOsd = true;
      _osdInteractive = false;
    });
    SharedPreferences.getInstance().then((prefs) {
      prefs.setInt('last_played_channel_index', prevIndex);
    });
    _triggerOsdTimer();
    _startProgressSync(_channels[prevIndex].streamUrl);
  }

  // --- AUTO-INICIO AL ENCENDER TV Y PERMISO DE SUPERPOSICIÓN ---
  Future<void> _checkAutoStartAndOverlayStatus(
      {bool promptIfMissing = false}) async {
    if (kIsWeb) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('auto_start_on_boot') ?? true;
      if (!prefs.containsKey('auto_start_on_boot')) {
        await prefs.setBool('auto_start_on_boot', true);
      }

      bool canOverlay = true;
      if (defaultTargetPlatform == TargetPlatform.android) {
        try {
          canOverlay =
              await _deviceChannel.invokeMethod<bool>('canDrawOverlays') ??
                  false;
        } catch (_) {}
      }

      if (mounted) {
        setState(() {
          _autoStartOnBoot = enabled;
          _hasOverlayPermission = canOverlay;
        });
      }

      if (promptIfMissing &&
          enabled &&
          !canOverlay &&
          defaultTargetPlatform == TargetPlatform.android) {
        final alreadyPrompted =
            prefs.getBool('overlay_permission_prompted_v1') ?? false;
        if (!alreadyPrompted) {
          await prefs.setBool('overlay_permission_prompted_v1', true);
          Future.delayed(const Duration(seconds: 3), () {
            if (mounted && !_hasOverlayPermission) {
              _openAutoStartSettingsModal();
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _setAutoStartOnBoot(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_start_on_boot', enabled);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _deviceChannel
            .invokeMethod('setAutoStartEnabled', {'enabled': enabled});
      } catch (_) {}
    }
    if (mounted) {
      setState(() => _autoStartOnBoot = enabled);
    }
  }

  void _openAutoStartSettingsModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Dialog(
          backgroundColor: const Color(0xFF0E1320),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
          ),
          child: Container(
            width: 560,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.power_settings_new_rounded,
                        color: Color(0xFF00E676), size: 30),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Auto-inicio al Encender TV y Superposición',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Abre AMEYCAR TV automáticamente al encender tu televisor y sintoniza el último canal que estabas viendo.',
                  style: TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 14),
                SwitchListTile(
                  activeColor: const Color(0xFF00E676),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Iniciar automáticamente al encender el TV',
                    style: TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                  subtitle: Text(
                    _autoStartOnBoot
                        ? 'Activado (puedes desactivarlo cuando desees)'
                        : 'Desactivado',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  value: _autoStartOnBoot,
                  onChanged: (val) async {
                    await _setAutoStartOnBoot(val);
                    setModalState(() {});
                  },
                ),
                const Divider(color: Colors.white12, height: 20),
                Row(
                  children: [
                    Icon(
                      _hasOverlayPermission
                          ? Icons.verified_rounded
                          : Icons.warning_amber_rounded,
                      color: _hasOverlayPermission
                          ? const Color(0xFF00E676)
                          : const Color(0xFFFFD600),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _hasOverlayPermission
                            ? 'Permiso de superposición concedido ✓'
                            : 'Android TV 10+ requiere activar "Mostrar sobre otras apps" para que inicie sola al encender.',
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12.5),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () async {
                        await _checkAutoStartAndOverlayStatus();
                        setModalState(() {});
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('Cerrar',
                          style: TextStyle(color: Colors.white70)),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E5FF),
                        foregroundColor: Colors.black,
                      ),
                      icon: const Icon(Icons.layers_rounded, size: 18),
                      label: Text(
                        _hasOverlayPermission
                            ? 'Revisar Permiso'
                            : 'Activar Superposición',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      onPressed: () async {
                        try {
                          await _deviceChannel
                              .invokeMethod('requestOverlayPermission');
                        } catch (_) {}
                        await Future.delayed(const Duration(milliseconds: 800));
                        await _checkAutoStartAndOverlayStatus();
                        setModalState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // --- SINCRONIZACIÓN EN TIEMPO REAL DE LISTAS M3U Y PARENTAL DESDE CELULAR/NUBE ---
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

      // Sincronizar cambios parentales en vivo (Ocultar chat / Filtro groserías)
      if (data['hidden_menu_items'] is List) {
        final hidden =
            (data['hidden_menu_items'] as List).map((e) => e.toString()).toList();
        ParentalService.hiddenItemsNotifier.value = hidden;
        if (hidden.contains('chat') && _showLiveChat && mounted) {
          setState(() => _showLiveChat = false);
        }
      }
      if (data.containsKey('chat_profanity_filter')) {
        ParentalService.profanityFilterNotifier.value =
            data['chat_profanity_filter'] != false;
      }

      // Sincronizar listas M3U agregadas o cambiadas desde el celular o la web
      final rawCloud =
          data['m3u_playlists_$_currentProfileId'] ?? data['m3u_playlists'];
      if (rawCloud is! List || rawCloud.isEmpty) return;

      final List incoming = [];
      for (final item in rawCloud) {
        if (item is Map) incoming.add(Map<String, dynamic>.from(item));
      }
      if (incoming.isEmpty) return;

      String currentActiveUrl = '';
      for (final l in _savedPlaylists) {
        if (l is Map && l['isActive'] == true) {
          currentActiveUrl = (l['url'] ?? '').toString().trim();
          break;
        }
      }

      Map<String, dynamic>? incomingActive;
      for (final l in incoming) {
        if (l is Map && l['isActive'] == true) {
          incomingActive = Map<String, dynamic>.from(l);
          break;
        }
      }
      final activeMap =
          incomingActive ?? Map<String, dynamic>.from(incoming.first as Map);
      final incomingUrl = (activeMap['url'] ?? '').toString().trim();

      if (incomingUrl.isNotEmpty &&
          (incomingUrl != currentActiveUrl || _channels.length <= 2)) {
        _savedPlaylists = incoming;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'm3u_lists_$_currentProfileId', jsonEncode(_savedPlaylists));
        await _downloadAndSanitizeM3u(
          incomingUrl,
          playlistId: activeMap['id']?.toString(),
          playlistName: activeMap['name']?.toString(),
        );
      }
      }
    }, onError: (_) {});
  }

  // --- RECEPTOR EN VIVO DEL MANDO A DISTANCIA DESDE EL CELULAR ---
  void _startListeningRemoteTvCommands() {
    RemoteControlService.listenToCommands(
      onCommandReceived: (command, extra) async {
        if (!mounted) return;
        final activeCh =
            _channels.isNotEmpty && _selectedChannelIndex < _channels.length
                ? _channels[_selectedChannelIndex]
                : null;

        switch (command) {
          case 'channel_next':
            _nextChannel();
            break;
          case 'channel_prev':
            _previousChannel();
            break;
          case 'play_pause':
            setState(() => _isPlayerPaused = !_isPlayerPaused);
            if (_showOsd) _triggerOsdTimer();
            break;
          case 'play':
            setState(() => _isPlayerPaused = false);
            break;
          case 'pause':
            setState(() {
              _isPlayerPaused = true;
              _isBehindLive = true;
            });
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
          case 'toggle_rec':
            await _toggleManualDvrRecording(activeCh);
            break;
          case 'toggle_osd':
            _toggleOsd(interactive: true);
            break;
          case 'open_channels':
            if (_isChannelDrawerOpen) {
              _closeChannelDrawer();
            } else {
              _openChannelDrawer();
            }
            break;
          case 'toggle_chat':
            if (!ParentalService.isChatHiddenSync()) {
              setState(() {
                _showLiveChat = !_showLiveChat;
                if (_showLiveChat) {
                  _showOsd = false;
                  _osdInteractive = false;
                }
              });
            }
            break;
          case 'toggle_favorite':
            if (activeCh != null) {
              await _toggleFavoriteChannel(activeCh);
            }
            break;
          case 'toggle_fullscreen':
            setState(() {
              _selectedSection = 'Televisión';
              _isChannelDrawerOpen = false;
              _isSidebarExpanded = false;
              _showOsd = false;
              _osdInteractive = false;
              _showLiveChat = false;
            });
            FocusScope.of(context).requestFocus(_tvFocusScope);
            break;
          case 'vol_up':
            setState(() {
              _currentVolume = (_currentVolume + 0.15).clamp(0.0, 1.0);
            });
            break;
          case 'vol_down':
            setState(() {
              _currentVolume = (_currentVolume - 0.15).clamp(0.0, 1.0);
            });
            break;
          case 'mute_toggle':
            setState(() {
              if (_currentVolume > 0.01) {
                _volumeBeforeMute = _currentVolume;
                _currentVolume = 0.0;
              } else {
                _currentVolume =
                    _volumeBeforeMute > 0.05 ? _volumeBeforeMute : 1.0;
              }
            });
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
                  (c) => c.name.toLowerCase() == name.toLowerCase());
            }
            if (idx != -1) {
              _playContent(_channels[idx]);
            }
            break;
        }
      },
    );
  }

  void _triggerZappingOverlay() {
    setState(() => _isZappingOverlayVisible = true);
    FocusScope.of(context).requestFocus(_zappingFocusNode);

    _zappingHideTimer?.cancel();
    _zappingHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _isZappingOverlayVisible = false);
        // Regresa el foco al TV cuando desaparece el carrusel
        if (FocusScope.of(context).focusedChild == _zappingFocusNode) {
          FocusScope.of(context).requestFocus(_tvFocusScope);
        }
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _progressSyncTimer?.cancel();
    _globalAnnouncementSub?.cancel();
    unawaited(_syncProgressToCloud());
    _zappingHideTimer?.cancel();
    _osdHideTimer?.cancel();
    _tvFocusScope.dispose();
    _sidebarFocusNode.dispose();
    _zappingFocusNode.dispose();
    _currentTimeNotifier.dispose();
    _channelDrawerFocusNode.dispose();
    _cloudPlaylistSub?.cancel();
    RemoteControlService.dispose();
    _tvSearchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeChannel = _channels.isNotEmpty
        ? _channels[_selectedChannelIndex]
        : null;

    final bool isTvMode = _selectedSection == 'Televisión';

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (_showLiveChat) {
            setState(() => _showLiveChat = false);
            FocusScope.of(context).requestFocus(_tvFocusScope);
          } else if (_isChannelDrawerOpen) {
            _closeChannelDrawer();
          } else if (_isSidebarExpanded) {
            setState(() => _isSidebarExpanded = false);
            FocusScope.of(context).requestFocus(_tvFocusScope);
          } else if (isTvMode && _showOsd) {
            _closeOsd();
          } else if (!isTvMode) {
            setState(() => _selectedSection = 'Televisión');
            FocusScope.of(context).requestFocus(_tvFocusScope);
          }
        }
      },
      child: FocusScope(
        node: _tvFocusScope,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            final key = event.logicalKey;

            if (!isTvMode) return KeyEventResult.ignored;
           if (_isSidebarExpanded || _isChannelDrawerOpen || _showLiveChat) {
            return KeyEventResult.ignored;
            }

            // Botones físicos CH+ / CH- del control remoto SIEMPRE cambian canal al instante
            if (key == LogicalKeyboardKey.channelUp ||
                key == LogicalKeyboardKey.pageUp) {
              _nextChannel();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.channelDown ||
                key == LogicalKeyboardKey.pageDown) {
              _previousChannel();
              return KeyEventResult.handled;
            }

            // Si el OSD ya está interactivo, dejamos que las flechas naveguen sus botones
            if (_showOsd && _osdInteractive) {
              return KeyEventResult.ignored;
            }

            // En pantalla completa limpia:
            // OK / Enter -> Abre OSD interactivo con foco directo en PLAY/PAUSA
            if (key == LogicalKeyboardKey.select ||
                key == LogicalKeyboardKey.enter ||
                key == LogicalKeyboardKey.gameButtonA) {
              setState(() {
                _showOsd = true;
                _osdInteractive = true;
              });
              _triggerOsdTimer();
              return KeyEventResult.handled;
            }

            // Flecha Arriba / Abajo -> Zapping instantáneo tipo TiviMate
            if (key == LogicalKeyboardKey.arrowUp) {
              _nextChannel();
              return KeyEventResult.handled;
            }
            if (key == LogicalKeyboardKey.arrowDown) {
              _previousChannel();
              return KeyEventResult.handled;
            }

            // Flecha Izquierda -> Abre el Panel de Canales (Categorías + Favoritos + Buscador)
            if (key == LogicalKeyboardKey.arrowLeft) {
              _openChannelDrawer();
              return KeyEventResult.handled;
            }

            // Flecha Derecha -> Abre OSD interactivo rápido
            if (key == LogicalKeyboardKey.arrowRight) {
              setState(() {
                _showOsd = true;
                _osdInteractive = true;
              });
              _triggerOsdTimer();
              return KeyEventResult.handled;
            }

            if (key == LogicalKeyboardKey.mediaPlayPause) {
              final activeCh =
                  _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;
              if (activeCh?.contentType == 'live') {
                PremiumManager.runIfPremium(context, action: () {
                  setState(() => _isPlayerPaused = !_isPlayerPaused);
                  if (_showOsd) _triggerOsdTimer();
                });
              } else {
                setState(() => _isPlayerPaused = !_isPlayerPaused);
              }
              return KeyEventResult.handled;
            }
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF070A10),
          body: Stack(
            children: [
              // 1. EL CORAZÓN: Reproductor siempre de fondo a pantalla completa
              
              Positioned.fill(
                child: RepaintBoundary(
                  child: ProVideoPlayer(
                    key: _playerKey,
                    streamUrl: (_isPlayingDvrRecording && _activeDvrFilePath != null)
                        ? _activeDvrFilePath!
                        : (activeChannel?.streamUrl ?? ''),
                        volume: _currentVolume,
                    isPlaying: !_isPlayerPaused,
                    colorBlindMode: _selectedColorBlindMode,
                  ),
                ),
              ),

              // 2. DIMMER DE FONDO (Oscurece si abres Ajustes, Cine & Series o el Sidebar)
              if (!isTvMode || _isSidebarExpanded)
                Positioned.fill(
                  child: Container(
                    color: Colors.black.withOpacity(_selectedSection == 'Cine IA' ? 0.85 : 0.55),
                  ),
                ),

              // 3A. CAPA DE CATÁLOGO CINE & SERIES (VOD)
              if (_selectedSection == 'Cine IA')
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: _isSidebarExpanded ? 250 : 85,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(),
                    child: _buildVodCatalogContent(),
                  ),
                ),

              // 3B. CAPA DE AJUSTES
              if (_selectedSection == 'Ajustes')
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: _isSidebarExpanded ? 260 : 90,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: FocusTraversalGroup(
                    policy: ReadingOrderTraversalPolicy(), // INYECCIÓN PARA SMART TV
                    child: _buildTvSettingsContent(),
                  ),
                ),

              // 3C. BANNER DE ANUNCIO GLOBAL EN TIEMPO REAL
              if (_activeGlobalAnnouncement.isNotEmpty)
                Positioned(
                  top: 18,
                  left: _isSidebarExpanded ? 260 : 95,
                  right: 24,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF1A103C), Color(0xFF0F172A)],
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFFFD600), width: 1.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.65),
                          blurRadius: 16,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.campaign_rounded, color: Color(0xFFFFD600), size: 30),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                _activeGlobalAnnouncementTitle,
                                style: const TextStyle(
                                  color: Color(0xFFFFD600),
                                  fontWeight: FontWeight.w900,
                                  fontSize: 13,
                                  letterSpacing: 0.6,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _activeGlobalAnnouncement,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _lastDismissedAnnouncementId = _activeGlobalAnnouncement;
                              _activeGlobalAnnouncement = '';
                            });
                          },
                          icon: const Icon(Icons.close, color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),

              // 4. OVERLAY DE ZAPPING (Riel Inferior de Canales)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                bottom: _isZappingOverlayVisible ? 0 : -200,
                left: _isSidebarExpanded ? 240 : 70,
                right: 0,
                height: 160,
                child: ClipRRect(
                  borderRadius:
                      const BorderRadius.only(topLeft: Radius.circular(24)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Focus(
                      focusNode: _zappingFocusNode,
                      onKeyEvent: (node, event) {
                        if (event is KeyDownEvent) {
                          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
                              event.logicalKey == LogicalKeyboardKey.arrowDown) {
                            setState(() => _isZappingOverlayVisible = false);
                            FocusScope.of(context).requestFocus(_tvFocusScope);
                            return KeyEventResult.handled;
                          }
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.65),
                          border: Border(
                              top: BorderSide(
                                  color: Colors.white.withOpacity(0.1),
                                  width: 1)),
                        ),
                        padding:
                            const EdgeInsets.only(top: 16, bottom: 16, left: 16),
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: _liveTv.length,
                          itemBuilder: (context, index) {
                            final liveChannel = _liveTv[index];
                            final isCurrentPlaying = _channels.isNotEmpty &&
                                _channels[_selectedChannelIndex].id ==
                                    liveChannel.id;

                            return Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: FocusableTvCard(
                                focusedScale: 1.1,
                                focusedBorderColor: const Color(0xFF00E5FF),
                                onTap: () {
                                  _triggerZappingOverlay();
                                  _playContent(liveChannel);
                                },
                                child: Container(
                                  width: 180,
                                  decoration: BoxDecoration(
                                    border: isCurrentPlaying
                                        ? Border.all(
                                            color: const Color(0xFF00E5FF)
                                                .withOpacity(0.5),
                                            width: 2)
                                        : null,
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        const Color(0xFF1E2336),
                                        Colors.black.withOpacity(0.8)
                                      ],
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      if (liveChannel.logoUrl.isNotEmpty)
                                        Center(
                                          child: Padding(
                                            padding:
                                                const EdgeInsets.all(24.0),
                                            child: Image.network(
                                                liveChannel.logoUrl,
                                                cacheWidth: 160,
                                                filterQuality: FilterQuality.low,
                                                errorBuilder: (c, e, s) =>
                                                    const Icon(Icons.tv,
                                                        color: Colors.white24,
                                                        size: 48)),
                                          ),
                                        )
                                      else
                                        const Center(
                                            child: Icon(Icons.tv,
                                                color: Colors.white24,
                                                size: 48)),
                                      Positioned(
                                        bottom: 12,
                                        left: 12,
                                        right: 12,
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                                'CH ${liveChannel.number}',
                                                style: const TextStyle(
                                                    color: Color(0xFF00E5FF),
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight.bold)),
                                            Text(liveChannel.name,
                                                maxLines: 1,
                                                overflow:
                                                    TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 14,
                                                    fontWeight:
                                                        FontWeight.w600)),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              // 5. SIDEBAR (Menú Lateral Inteligente - oculto en TV Full Screen)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeInOut,
                left: (isTvMode && !_isSidebarExpanded) ? -90 : 0,
                top: 0,
                bottom: 0,
                width: _isSidebarExpanded ? 240 : 75,
                child: ExcludeFocus(
                  excluding: isTvMode && !_isSidebarExpanded,
                  child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                      topRight: Radius.circular(16),
                      bottomRight: Radius.circular(16)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: FocusTraversalGroup(
                      policy: WidgetOrderTraversalPolicy(),
                      child: Focus(
                        focusNode: _sidebarFocusNode,
                        onKeyEvent: (node, event) {
                          // MAGIA: El puente de escape. Si tocas la derecha en el menú, se cierra y vuelves a la TV.
                          if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
                            setState(() => _isSidebarExpanded = false);
                            FocusScope.of(context).requestFocus(_tvFocusScope);
                            return KeyEventResult.handled;
                          }
                          return KeyEventResult.ignored;
                        },
                        onFocusChange: (hasFocus) {
                          if (mounted) {
                            setState(() => _isSidebarExpanded = hasFocus);
                            // INYECCIÓN PARA SMART TV:
                            // Si el menú recibe el foco, lo obligamos a bajar al primer botón.
                            if (hasFocus && _sidebarFocusNode.hasPrimaryFocus) {
                              _sidebarFocusNode.nextFocus();
                            }
                          }
                        },
                        child: Container(
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.65),
                            border: Border(
                                right: BorderSide(
                                    color: Colors.white.withOpacity(0.15),
                                    width: 1)),
                          ),
                          padding: const EdgeInsets.symmetric(
                              vertical: 24, horizontal: 10),
                          child: SingleChildScrollView(
                            physics: const BouncingScrollPhysics(),
                            child: Column(
                              crossAxisAlignment: _isSidebarExpanded
                                  ? CrossAxisAlignment.start
                                  : CrossAxisAlignment.center,
                              children: [
                                _isSidebarExpanded
                                    ? Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 14, vertical: 6),
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            const Text('AMEYCAR TV',
                                                style: TextStyle(
                                                    color: Color(0xFF00E5FF),
                                                    fontSize: 18,
                                                    fontWeight: FontWeight.w900,
                                                    letterSpacing: 1.2)),
                                            const SizedBox(height: 2),
                                           ValueListenableBuilder<String>(
                                              valueListenable: _currentTimeNotifier,
                                              builder: (_, time, __) => Text(
                                                '🕒 $time',
                                                style: const TextStyle(
                                                    color: Color(0xFFC77DFF),
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.bold),
                                              ),
                                            ),
                                          ],
                                        ),
                                      )
                                    : const Padding(
                                        padding: EdgeInsets.only(top: 8.0),
                                        child: Icon(Icons.tv_rounded,
                                            color: Color(0xFF00E5FF), size: 32),
                                      ),
                                const SizedBox(height: 28),
                                const Divider(color: Colors.white12, height: 16),

                                // BOTONES DE NAVEGACIÓN
                                _buildSidebarItem(Icons.live_tv, 'Televisión', 'Televisión', onTapOverride: () {
                                  setState(() {
                                    _selectedSection = 'Televisión';
                                    _isSidebarExpanded = false;
                                  });
                                  FocusScope.of(context).requestFocus(_tvFocusScope);
                                }),
                                _buildSidebarItem(Icons.search, 'Búsqueda IA', 'Búsqueda IA', onTapOverride: _startVoiceSearch),
                                _buildSidebarItem(Icons.movie, 'Cine & Series', 'Cine IA', onTapOverride: () {
                                  setState(() {
                                    _selectedSection = 'Cine IA';
                                    _selectedVodTab = _movies.isNotEmpty || _series.isEmpty ? 'Películas' : 'Series';
                                    _selectedVodCategory = 'Todos';
                                    _isSidebarExpanded = false;
                                  });
                                }),
                                _buildSidebarItem(Icons.closed_caption_rounded, 'Traductor CC', 'CC', onTapOverride: () {
                                  setState(() => _isSidebarExpanded = false);
                                  PlayerSettingsService.showLiveCcLanguageModal(context);
                                }),
                                _buildSidebarItem(Icons.settings, 'Ajustes', 'Ajustes', onTapOverride: () {
                                  setState(() {
                                    _selectedSection = 'Ajustes';
                                    _isSidebarExpanded = false;
                                  });
                                }),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              ),

              // 6. OSD OVERLAY (Aparece al presionar OK o Flechas)
              // 5B. PANEL LATERAL DE CANALES ESTILO TIVIMATE / SMARTPHONE
              if (isTvMode && _isChannelDrawerOpen)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 680,
                  child: _buildTvChannelDrawer(),
                ),

              // 5C. CHAT EN VIVO EN SMART TV (Oculto si Control Parental desactiva el chat)
              if (isTvMode &&
                  _showLiveChat &&
                  !_isChannelDrawerOpen &&
                  activeChannel != null &&
                  !ParentalService.isChatHiddenSync())
                Positioned.fill(
                  child: LiveChatOverlay(
                    channelId: activeChannel.name
                        .replaceAll(RegExp(r'[^a-zA-Z0-9_]'), '_'),
                    channelName: activeChannel.name,
                    isTvMode: true,
                    onClose: () {
                      setState(() => _showLiveChat = false);
                      FocusScope.of(context).requestFocus(_tvFocusScope);
                    },
                  ),
                ),

              // 6. OSD OVERLAY (Banner rápido al zapear / Interactivo al pulsar OK)
              if (isTvMode &&
                  _showOsd &&
                  !_isChannelDrawerOpen &&
                  !_showLiveChat &&
                  activeChannel != null)
                ExcludeFocus(
                  excluding: !_osdInteractive,
                  child: ZappingChannelOverlay(
                    channel: activeChannel,
                    channelIndex: _selectedChannelIndex,
                    totalChannels: _channels.length,
                    isPlaying: !_isPlayerPaused,
                    isFullScreen: true,
                    isBehindLive: _isBehindLive,
                    isPlayingDvrRecording: _isPlayingDvrRecording,
                    dvrRecordingTitle: _activeDvrTitle,
                    isFavorite: _isChannelFavorite(activeChannel),
                    isChatOpen: _showLiveChat,
                    autoFocusControls: _osdInteractive,
                    onUserInteraction: _triggerOsdTimer,
                    onClose: _closeOsd,
                    onToggleFavorite: () =>
                        _toggleFavoriteChannel(activeChannel),
                    onOpenChannelList: _openChannelDrawer,
                    onToggleChat: ParentalService.isChatHiddenSync()
                        ? null
                        : () {
                            setState(() {
                              _showLiveChat = !_showLiveChat;
                              if (_showLiveChat) {
                                _showOsd = false;
                                _osdInteractive = false;
                              }
                            });
                          },
                    onPlayPause: () {
                      if (activeChannel.contentType == 'live') {
                        PremiumManager.runIfPremium(context, action: () {
                          setState(() => _isPlayerPaused = !_isPlayerPaused);
                          _triggerOsdTimer();
                        });
                      } else {
                        setState(() => _isPlayerPaused = !_isPlayerPaused);
                        _triggerOsdTimer();
                      }
                    },
                    onNext: _nextChannel,
                    onPrevious: _previousChannel,
                    onSearch: _openChannelDrawer,
                    onRewind15s: () => _seekRelativeSeconds(-15),
                    onForward15s: () => _seekRelativeSeconds(15),
                    onJumpToLive: _jumpBackToLiveStream,
                    onToggleRecord: () =>
                        _toggleManualDvrRecording(activeChannel),
                    onOpenEpg: () => _openTvEpgModal(activeChannel),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
  /// Panel lateral estilo TiviMate / Smartphone: Buscador + Categorías + Favoritos + Lista de Canales
  Widget _buildTvChannelDrawer() {
    final List<ChannelModel> basePool =
        _liveTv.isNotEmpty ? _liveTv : _channels;

    final Set<String> catSet = {'Todos', '⭐ Favoritos'};
    for (final ch in basePool) {
      final g = ch.groupCategory.trim();
      if (g.isNotEmpty) catSet.add(g);
    }
    final List<String> categories = catSet.toList();

    final query = _tvChannelSearchQuery.trim().toLowerCase();
    final List<ChannelModel> filteredChannels;
    if (query.isNotEmpty) {
      // Búsqueda global por nombre (igual que en el celular)
      filteredChannels = _channels.where((c) {
        return c.name.toLowerCase().contains(query) ||
            c.groupCategory.toLowerCase().contains(query);
      }).toList();
    } else if (_selectedLiveCategory == '⭐ Favoritos') {
      filteredChannels =
          _channels.where((c) => _favoriteChannelUrls.contains(c.streamUrl)).toList();
    } else if (_selectedLiveCategory == 'Todos') {
      filteredChannels = basePool;
    } else {
      filteredChannels = basePool
          .where((c) => c.groupCategory.trim() == _selectedLiveCategory)
          .toList();
    }

    return ClipRRect(
      borderRadius: const BorderRadius.only(
        topRight: Radius.circular(22),
        bottomRight: Radius.circular(22),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: FocusScope(
          node: _channelDrawerFocusNode,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.escape ||
                    event.logicalKey == LogicalKeyboardKey.goBack)) {
              _closeChannelDrawer();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF080D18).withOpacity(0.92),
              border: Border(
                right: BorderSide(
                  color: const Color(0xFF00E5FF).withOpacity(0.45),
                  width: 1.5,
                ),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
            child: Column(
              children: [
                // Cabecera: Menú Principal + Buscador + Voz IA + Cerrar a Pantalla Completa
                Row(
                  children: [
                    FocusableTvCard(
                      focusedScale: 1.06,
                      focusedBorderColor: const Color(0xFF00E5FF),
                      onTap: () {
                        setState(() {
                          _isChannelDrawerOpen = false;
                          _isSidebarExpanded = true;
                        });
                        FocusScope.of(context).requestFocus(_sidebarFocusNode);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161F33),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white12),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.menu_rounded,
                                color: Color(0xFF00E5FF), size: 20),
                            SizedBox(width: 6),
                            Text('Menú',
                                style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _tvSearchCtrl,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        onChanged: (val) =>
                            setState(() => _tvChannelSearchQuery = val),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Buscar canal por nombre (Ej: ESPN, FOX...)',
                          hintStyle: const TextStyle(
                              color: Colors.white38, fontSize: 13),
                          prefixIcon: const Icon(Icons.search,
                              color: Color(0xFF00E5FF), size: 20),
                          suffixIcon: _tvChannelSearchQuery.isNotEmpty
                              ? IconButton(
                                  icon: const Icon(Icons.clear,
                                      color: Colors.white60, size: 18),
                                  onPressed: () {
                                    _tvSearchCtrl.clear();
                                    setState(() => _tvChannelSearchQuery = '');
                                  },
                                )
                              : null,
                          filled: true,
                          fillColor: const Color(0xFF111827),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide(
                                color: const Color(0xFF00E5FF).withOpacity(0.35)),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: const BorderSide(
                                color: Color(0xFF00E5FF), width: 1.8),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FocusableTvCard(
                      focusedScale: 1.06,
                      focusedBorderColor: const Color(0xFF00E5FF),
                      onTap: () {
                        _closeChannelDrawer();
                        _startVoiceSearch();
                      },
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7B2CBF).withOpacity(0.45),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color: const Color(0xFFC77DFF).withOpacity(0.6)),
                        ),
                        child: const Icon(Icons.mic_rounded,
                            color: Colors.white, size: 20),
                      ),
                    ),
                    const SizedBox(width: 8),
                    FocusableTvCard(
                      focusedScale: 1.06,
                      focusedBorderColor: const Color(0xFF00E5FF),
                      onTap: _closeChannelDrawer,
                      child: Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.fullscreen_rounded,
                            color: Colors.white, size: 20),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Cuerpo en 2 columnas: Izquierda Categorías | Derecha Canales
                Expanded(
                  child: Row(
                    children: [
                      // Columna 1: Categorías + Favoritos
                      SizedBox(
                        width: 215,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.only(left: 6, bottom: 8),
                              child: Text(
                                'CATEGORÍAS',
                                style: TextStyle(
                                  color: Color(0xFF00E5FF),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ),
                            Expanded(
                              child: ListView.builder(
                                itemCount: categories.length,
                                itemExtent: 46,
                                itemBuilder: (context, index) {
                                  final cat = categories[index];
                                  final isSelected = query.isEmpty &&
                                      _selectedLiveCategory == cat;
                                  final isFavCat = cat == '⭐ Favoritos';
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: FocusableTvCard(
                                      focusedScale: 1.03,
                                      focusedBorderColor: isFavCat
                                          ? const Color(0xFFFFD600)
                                          : const Color(0xFF00E5FF),
                                      onTap: () {
                                        _tvSearchCtrl.clear();
                                        setState(() {
                                          _tvChannelSearchQuery = '';
                                          _selectedLiveCategory = cat;
                                        });
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 12),
                                        alignment: Alignment.centerLeft,
                                        decoration: BoxDecoration(
                                          color: isSelected
                                              ? (isFavCat
                                                  ? const Color(0xFFFFD600)
                                                      .withOpacity(0.25)
                                                  : const Color(0xFF00E5FF)
                                                      .withOpacity(0.22))
                                              : const Color(0xFF111827),
                                          borderRadius:
                                              BorderRadius.circular(10),
                                          border: Border.all(
                                            color: isSelected
                                                ? (isFavCat
                                                    ? const Color(0xFFFFD600)
                                                    : const Color(0xFF00E5FF))
                                                : Colors.white10,
                                          ),
                                        ),
                                        child: Text(
                                          isFavCat
                                              ? '$cat (${_favoriteChannelUrls.length})'
                                              : cat,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: isFavCat
                                                ? const Color(0xFFFFD600)
                                                : (isSelected
                                                    ? Colors.white
                                                    : Colors.white70),
                                            fontWeight: isSelected || isFavCat
                                                ? FontWeight.bold
                                                : FontWeight.w500,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      ),
                      const VerticalDivider(color: Colors.white12, width: 20),

                      // Columna 2: Lista de Canales Filtrados
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(left: 4, bottom: 8),
                              child: Text(
                                query.isNotEmpty
                                    ? 'RESULTADOS PARA "$query" (${filteredChannels.length})'
                                    : '${_selectedLiveCategory.toUpperCase()} (${filteredChannels.length})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.8,
                                ),
                              ),
                            ),
                            Expanded(
                              child: filteredChannels.isEmpty
                                  ? Center(
                                      child: Text(
                                        _selectedLiveCategory == '⭐ Favoritos'
                                            ? 'Aún no tienes canales en Favoritos.\nPulsa OK viendo un canal y elige ⭐ FAVORITO.'
                                            : 'No se encontraron canales con ese filtro.',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                            color: Colors.white54, fontSize: 13),
                                      ),
                                    )
                                  : ListView.builder(
                                      itemCount: filteredChannels.length,
                                      itemExtent: 64,
                                      itemBuilder: (context, index) {
                                        final ch = filteredChannels[index];
                                        final isPlayingNow =
                                            _channels.isNotEmpty &&
                                                _channels[_selectedChannelIndex]
                                                        .streamUrl ==
                                                    ch.streamUrl;
                                        final isFav = _isChannelFavorite(ch);

                                        return Padding(
                                          padding:
                                              const EdgeInsets.only(bottom: 6),
                                          child: FocusableTvCard(
                                            focusedScale: 1.02,
                                            focusedBorderColor:
                                                const Color(0xFF00E5FF),
                                            onTap: () => _playContent(ch),
                                            child: Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      horizontal: 10),
                                              decoration: BoxDecoration(
                                                color: isPlayingNow
                                                    ? const Color(0xFF00E5FF)
                                                        .withOpacity(0.18)
                                                    : const Color(0xFF111827),
                                                borderRadius:
                                                    BorderRadius.circular(10),
                                                border: Border.all(
                                                  color: isPlayingNow
                                                      ? const Color(0xFF00E5FF)
                                                      : Colors.white10,
                                                ),
                                              ),
                                              child: Row(
                                                children: [
                                                  ClipRRect(
                                                    borderRadius:
                                                        BorderRadius.circular(6),
                                                    child: Container(
                                                      width: 38,
                                                      height: 38,
                                                      color: Colors.black38,
                                                      child: ch.logoUrl.isNotEmpty
                                                          ? Image.network(
                                                              ch.logoUrl,
                                                              fit: BoxFit.contain,
                                                              cacheWidth: 80,
                                                              filterQuality:
                                                                  FilterQuality
                                                                      .low,
                                                              errorBuilder: (_,
                                                                      __, ___) =>
                                                                  const Icon(
                                                                      Icons.tv,
                                                                      color: Colors
                                                                          .white38,
                                                                      size: 20),
                                                            )
                                                          : const Icon(Icons.tv,
                                                              color: Colors
                                                                  .white38,
                                                              size: 20),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 10),
                                                  Expanded(
                                                    child: Column(
                                                      mainAxisAlignment:
                                                          MainAxisAlignment
                                                              .center,
                                                      crossAxisAlignment:
                                                          CrossAxisAlignment
                                                              .start,
                                                      children: [
                                                        Text(
                                                          ch.name,
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: const TextStyle(
                                                            color: Colors.white,
                                                            fontSize: 13.5,
                                                            fontWeight:
                                                                FontWeight.bold,
                                                          ),
                                                        ),
                                                        Text(
                                                          '${ch.groupCategory} • ${ch.resolution}',
                                                          maxLines: 1,
                                                          overflow: TextOverflow
                                                              .ellipsis,
                                                          style: const TextStyle(
                                                            color:
                                                                Colors.white54,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  if (isFav)
                                                    const Padding(
                                                      padding: EdgeInsets.only(
                                                          right: 6),
                                                      child: Icon(
                                                        Icons.star_rounded,
                                                        color:
                                                            Color(0xFFFFD600),
                                                        size: 18,
                                                      ),
                                                    ),
                                                  if (isPlayingNow)
                                                    const Icon(
                                                      Icons.play_arrow_rounded,
                                                      color: Color(0xFF00E5FF),
                                                      size: 22,
                                                    ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
  /// Construye el Catálogo Visual de Películas y Series (VOD)
  Widget _buildVodCatalogContent() {
    final List<ChannelModel> currentPool = _selectedVodTab == 'Películas'
        ? _movies
        : (_selectedVodTab == 'Series' ? _series : _liveTv);

    final Set<String> categorySet = {'Todos'};
    for (final item in currentPool) {
      if (item.groupCategory.trim().isNotEmpty) {
        categorySet.add(item.groupCategory.trim());
      }
    }
    final List<String> categories = categorySet.toList();

    final List<ChannelModel> filteredItems = _selectedVodCategory == 'Todos'
        ? currentPool
        : currentPool.where((c) => c.groupCategory.trim() == _selectedVodCategory).toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 28, 32, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.movie_filter_rounded, color: Color(0xFF00E5FF), size: 32),
              const SizedBox(width: 12),
              const Text(
                'Catálogo Cine & Series VOD',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const Spacer(),
              _buildVodTabButton('En Vivo (${_liveTv.length})', 'En Vivo'),
              const SizedBox(width: 10),
              _buildVodTabButton('Películas (${_movies.length})', 'Películas'),
              const SizedBox(width: 10),
              _buildVodTabButton('Series (${_series.length})', 'Series'),
              const SizedBox(width: 14),
              FocusableTvCard(
                focusedScale: 1.06,
                focusedBorderColor: const Color(0xFF00E5FF),
                onTap: () => PlayerSettingsService.showLiveCcLanguageModal(context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.closed_caption, color: Color(0xFF00E5FF), size: 18),
                      SizedBox(width: 6),
                      Text('CC Idioma', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final cat = categories[index];
                final isSelected = _selectedVodCategory == cat;
                return FocusableTvCard(
                  focusedScale: 1.05,
                  focusedBorderColor: const Color(0xFF00E5FF),
                  onTap: () {
                    setState(() => _selectedVodCategory = cat);
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF161F33),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Center(
                      child: Text(
                        cat,
                        style: TextStyle(
                          color: isSelected ? Colors.black : Colors.white70,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 20),
          Expanded(
            child: filteredItems.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.videocam_off_outlined, color: Colors.white38, size: 54),
                        const SizedBox(height: 12),
                        Text(
                          'No hay elementos en "$_selectedVodTab" dentro de tu lista activa.\nPuedes agregar o sincronizar tu lista VOD desde Ajustes > Gestor Multi-Lista M3U.',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white60, fontSize: 14),
                        ),
                      ],
                    ),
                  )
                : GridView.builder(
                    physics: const BouncingScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: 18,
                      crossAxisSpacing: 18,
                      childAspectRatio: 0.68,
                    ),
                    itemCount: filteredItems.length,
                    itemBuilder: (context, index) {
                      final item = filteredItems[index];
                      return FocusableTvCard(
                        focusedScale: 1.05,
                        focusedBorderColor: const Color(0xFF00E5FF),
                        onTap: () => _playContent(item),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF111827),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: Colors.white12),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    if (item.logoUrl.isNotEmpty)
                                      Image.network(
                                        item.logoUrl,
                                        fit: BoxFit.cover,
                                        cacheWidth: 260,
                                        filterQuality: FilterQuality.low,
                                        errorBuilder: (_, __, ___) => Container(
                                          color: const Color(0xFF161F33),
                                          child: const Icon(Icons.movie_creation_outlined,
                                              color: Color(0xFF00E5FF), size: 42),
                                        ),
                                      )
                                    else
                                      Container(
                                        color: const Color(0xFF161F33),
                                        child: const Icon(Icons.movie_creation_outlined,
                                            color: Color(0xFF00E5FF), size: 42),
                                      ),
                                    Positioned(
                                      top: 8,
                                      right: 8,
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: Colors.black87,
                                          borderRadius: BorderRadius.circular(6),
                                          border: Border.all(color: const Color(0xFF00E5FF), width: 0.8),
                                        ),
                                        child: Text(
                                          item.resolution,
                                          style: const TextStyle(
                                            color: Color(0xFF00E5FF),
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      item.groupCategory,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white54,
                                        fontSize: 11,
                                      ),
                                    ),
                                  ],
                                ),
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
  }

  Widget _buildVodTabButton(String label, String tabValue) {
    final bool isSelected = _selectedVodTab == tabValue;
    return FocusableTvCard(
      focusedScale: 1.05,
      focusedBorderColor: const Color(0xFF00E5FF),
      onTap: () {
        if (tabValue == 'En Vivo') {
          setState(() {
            _selectedSection = 'Televisión';
          });
        } else {
          setState(() {
            _selectedVodTab = tabValue;
            _selectedVodCategory = 'Todos';
          });
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFF7B2CBF) : const Color(0xFF161F33),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFF00E5FF) : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.white70,
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }

  Widget _buildTvSettingsContent() {
    final user = AuthService.currentActiveProfile ?? AuthService.currentUser;
    final rootUser = AuthService.currentUser;
    final int daysLeft = rootUser?.daysRemaining ?? 0;

    return SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(28, 32, 36, 80),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF161F36), Color(0xFF0D1324)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: const Color(0xFF00E5FF).withOpacity(0.35), width: 1.5),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.5),
                    blurRadius: 20,
                    offset: const Offset(0, 8)),
              ],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.15),
                    shape: BoxShape.circle,
                    border: Border.all(color: const Color(0xFF00E5FF)),
                  ),
                  child: const Icon(Icons.settings_suggest_rounded,
                      color: Color(0xFF00E5FF), size: 36),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Centro de Configuración',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD600),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              rootUser?.isAdmin == true
                                  ? 'MASTER ADMIN'
                                  : 'PLAN VIP',
                              style: const TextStyle(
                                color: Colors.black,
                                fontWeight: FontWeight.w900,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Sesión activa: ${user?.username ?? "Usuario"}  •  $daysLeft días restantes  •  ID Equipo: $_hardwareId',
                        style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 14,
                            fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),

          FocusTraversalGroup(
            policy: ReadingOrderTraversalPolicy(),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 18,
              crossAxisSpacing: 18,
              childAspectRatio: 2.35,
              children: [
                if (rootUser?.isAdmin == true)
                  _buildTvSettingsCard(
                    icon: Icons.campaign_rounded,
                    color: const Color(0xFFFFD600),
                    title: 'Publicar Anuncio Global (En Vivo)',
                    subtitle: 'Enviar comunicado instantáneo a todas las pantallas',
                    onTap: _openGlobalAnnouncementPublisherModal,
                  ),
                  if (rootUser?.isAdmin == true)
                  _buildTvSettingsCard(
                    icon: Icons.system_update_rounded,
                    color: const Color(0xFF00E5FF),
                    title: 'Control de Versiones Google Play',
                    subtitle: 'Definir build mínimo obligatorio para usuarios',
                    onTap: () =>
                        AppUpdateGuard.showAdminVersionControlModal(context),
                  ),
                  if (!kIsWeb)
                  _buildTvSettingsCard(
                    icon: Icons.power_settings_new_rounded,
                    color: _autoStartOnBoot
                        ? const Color(0xFF00E676)
                        : Colors.white54,
                    title: 'Auto-inicio TV y Superposición',
                    subtitle: _autoStartOnBoot
                        ? (_hasOverlayPermission
                            ? 'Activo • Permiso concedido ✓'
                            : 'Activo • Falta activar permiso de superposición')
                        : 'Desactivado (toca para activar)',
                    onTap: _openAutoStartSettingsModal,
                  ),
                _buildTvSettingsCard(
                  icon: Icons.closed_caption_rounded,
                  color: const Color(0xFF00E5FF),
                  title: 'Subtítulos y Traducción CC en Vivo',
                  subtitle: 'Modo actual: ${PlayerSettingsService.subtitleTrackNotifier.value}',
                  onTap: () async {
                    await PlayerSettingsService.showLiveCcLanguageModal(context);
                    if (mounted) setState(() {});
                  },
                ),
                _buildTvSettingsCard(
                  icon: Icons.confirmation_number_outlined,
                  color: const Color(0xFF00E676),
                  title: 'Renovar Suscripción / Canjear PIN',
                  subtitle: 'Activar PIN 24/7 o ver medios de pago oficiales',
                  onTap: _showRenewSubscriptionModal,
                ),
                if (!ParentalService.isMenuItemHiddenSync('remote'))
                  _buildTvSettingsCard(
                    icon: Icons.settings_remote,
                    color: const Color(0xFF00E5FF),
                    title: 'Mando a Distancia TV & Cast',
                    subtitle: 'Vincular y controlar Smart TV desde tu celular',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const RemoteControlScreen()),
                      );
                    },
                  ),
                if (!kIsWeb)
                  _buildTvSettingsCard(
                    icon: Icons.fiber_smart_record,
                    color: const Color(0xFFFF1744),
                    title:
                        'Mis Grabaciones DVR (${DvrRecordingService.recordings.length})',
                    subtitle: 'Ver programas grabados o liberar memoria',
                    onTap: _openDvrRecordingsVaultModal,
                  ),
                if (!ParentalService.isMenuItemHiddenSync('referral'))
                  _buildTvSettingsCard(
                    icon: Icons.card_giftcard,
                    color: const Color(0xFFFFD600),
                    title: 'Círculo AMEYCAR (+15 Días Gratis)',
                    subtitle: 'Comparte tu código de invitación automático',
                    onTap: _showReferralClubModal,
                  ),
                _buildTvSettingsCard(
                  icon: Icons.remove_red_eye_rounded,
                  color: const Color(0xFF00E5FF),
                  title: 'Accesibilidad (Daltonismo)',
                  subtitle: 'Modo actual: $_selectedColorBlindMode',
                  onTap: _showColorBlindSelectorDialog,
                ),
                _buildTvSettingsCard(
                  icon: Icons.person_outline,
                  color: const Color(0xFF00E5FF),
                  title: 'Editar Perfil, Avatar y Hardware',
                  subtitle: 'Personalizar avatar y ver ID de equipo TV',
                  onTap: _showAccountProfileModal,
                ),
                if (!ParentalService.isMenuItemHiddenSync('parental'))
                  _buildTvSettingsCard(
                    icon: Icons.lock_outline_rounded,
                    color: Colors.amberAccent,
                    title: 'Control Parental & PIN',
                    subtitle: 'Bloquear categorías, menú y hora de sueño',
                    onTap: _openParentalManagerDialog,
                  ),
                if (!ParentalService.isMenuItemHiddenSync('m3u'))
                  _buildTvSettingsCard(
                    icon: Icons.playlist_play,
                    color: const Color(0xFF9D4EDD),
                    title:
                        'Gestor Multi-Lista M3U (${_savedPlaylists.length}/5)',
                    subtitle: 'Sincronizado en la nube entre Celular y TV',
                    onTap: _openM3uDialog,
                  ),
                _buildTvSettingsCard(
                  icon: Icons.alarm_on,
                  color: const Color(0xFFFFB703),
                  title: 'Mis Alarmas Programadas (${_activeAlarms.length})',
                  subtitle: 'Ver o cancelar recordatorios de programas',
                  onTap: _openActiveAlarmsManagerModal,
                ),
                if (AuthService.isFamilyAdmin)
                  _buildTvSettingsCard(
                    icon: Icons.family_restroom,
                    color: const Color(0xFFC77DFF),
                    title: 'Gestión de Grupo Familiar',
                    subtitle: 'Administrar las pantallas de tu familia',
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                FamilyPanelScreen(onLogout: widget.onLogout)),
                      ).then((_) {
                        if (mounted) setState(() {});
                      });
                    },
                  ),
                if (!ParentalService.isMenuItemHiddenSync('support'))
                  _buildTvSettingsCard(
                    icon: Icons.headset_mic,
                    color: const Color(0xFF00E676),
                    title: 'Soporte Directo / Contactar al CEO',
                    subtitle: 'Atención inmediata por WhatsApp oficial',
                    onTap: _openSupportMenu,
                  ),
                _buildTvSettingsCard(
                  icon: Icons.language,
                  color: Colors.amberAccent,
                  title: 'Idioma de la Interfaz',
                  subtitle: 'Actual: $_selectedLanguage',
                  onTap: _showLanguageSelectorDialog,
                ),
                _buildTvSettingsCard(
                  icon: Icons.school_rounded,
                  color: const Color(0xFF00E5FF),
                  title: 'Ver Tutorial / Guía Rápida',
                  subtitle: 'Guía de control remoto, listas M3U en nube y funciones',
                  onTap: () {
                    OnboardingTutorialModal.show(
                      context,
                      isTv: true,
                      onOpenM3uManager: _openM3uDialog,
                    );
                  },
                ),
                _buildTvSettingsCard(
                  icon: Icons.switch_account,
                  color: const Color(0xFFC77DFF),
                  title: 'Cambiar de Perfil / Pantalla',
                  subtitle: 'Volver a "¿Quién está viendo hoy?"',
                  onTap: () {
                    if (AuthService.currentUser?.isPartOfFamily == true) {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ProfileSelectorScreen(
                            onLogout: widget.onLogout,
                            onProfileSelected: () {
                              Navigator.pop(context);
                              _loadInitialPreferences();
                              _loadChannels();
                            },
                          ),
                        ),
                      );
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Esta cuenta es individual. Usa "Cerrar Sesión Segura" para cambiar de cuenta.'),
                          backgroundColor: Color(0xFF7B2CBF),
                        ),
                      );
                    }
                  },
                ),
                _buildTvSettingsCard(
                  icon: Icons.logout,
                  color: Colors.redAccent,
                  title: 'Cerrar Sesión Segura',
                  subtitle: 'Salir de la cuenta actual en este Smart TV',
                  onTap: () async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        backgroundColor: const Color(0xFF131A29),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                            side: const BorderSide(color: Colors.redAccent)),
                        title: const Text('¿Cerrar Sesión en este TV?',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        content: const Text(
                            'Tendrás que volver a ingresar tus credenciales para entrar.',
                            style: TextStyle(color: Colors.white70)),
                        actions: [
                          TextButton(
                            autofocus: true,
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancelar',
                                style: TextStyle(color: Colors.white70)),
                          ),
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.redAccent,
                                foregroundColor: Colors.white),
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Sí, Salir Ahora',
                                style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    );

                    if (confirm == true) {
                      await AuthService.logout();
                      widget.onLogout?.call();
                    }
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Modal de Administración para Publicar o Desactivar Anuncios Globales en Tiempo Real
  void _openGlobalAnnouncementPublisherModal() {
    final titleCtrl = TextEditingController(
      text: _activeGlobalAnnouncementTitle.isNotEmpty
          ? _activeGlobalAnnouncementTitle
          : '📢 COMUNICADO OFICIAL AMEYCAR TV',
    );
    final msgCtrl = TextEditingController(text: _activeGlobalAnnouncement);
    bool isPublishing = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Dialog(
          backgroundColor: const Color(0xFF0E1320),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
            side: const BorderSide(color: Color(0xFFFFD600), width: 1.5),
          ),
          child: Container(
            width: 560,
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.campaign_rounded, color: Color(0xFFFFD600), size: 30),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        'Publicar Anuncio Global en Vivo',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.pop(ctx),
                      icon: const Icon(Icons.close, color: Colors.white70),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: titleCtrl,
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'Título del Anuncio',
                    labelStyle: const TextStyle(color: Color(0xFFFFD600)),
                    filled: true,
                    fillColor: Colors.black26,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: msgCtrl,
                  maxLines: 3,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Mensaje para todos los usuarios conectados',
                    hintText: 'Ej: Nuevas películas 4K agregadas al catálogo esta noche...',
                    hintStyle: const TextStyle(color: Colors.white30),
                    labelStyle: const TextStyle(color: Colors.white70),
                    filled: true,
                    fillColor: Colors.black26,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          side: const BorderSide(color: Colors.redAccent),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.visibility_off),
                        label: const Text('QUITAR ANUNCIO ACTIVO'),
                        onPressed: isPublishing
                            ? null
                            : () async {
                                setModalState(() => isPublishing = true);
                                try {
                                  if (AuthService.isFirebaseAvailable) {
                                    await FirebaseFirestore.instance
                                        .collection('app_config')
                                        .doc('global_announcement')
                                        .set({
                                      'active': false,
                                      'isActive': false,
                                      'message': '',
                                      'updatedAt': FieldValue.serverTimestamp(),
                                    }, SetOptions(merge: true));
                                  }
                                } catch (_) {}
                                if (mounted) {
                                  setState(() => _activeGlobalAnnouncement = '');
                                }
                                setModalState(() => isPublishing = false);
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFFD600),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                        ),
                        icon: const Icon(Icons.send_rounded),
                        label: Text(
                          isPublishing ? 'PUBLICANDO...' : 'PUBLICAR AHORA',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                        onPressed: isPublishing
                            ? null
                            : () async {
                                final text = msgCtrl.text.trim();
                                final title = titleCtrl.text.trim().isEmpty
                                    ? '📢 ANUNCIO OFICIAL AMEYCAR TV'
                                    : titleCtrl.text.trim();
                                if (text.isEmpty) return;

                                setModalState(() => isPublishing = true);
                                final nowId = 'ann_${DateTime.now().millisecondsSinceEpoch}';
                                final payload = {
                                  'id': nowId,
                                  'title': title,
                                  'message': text,
                                  'text': text,
                                  'body': text,
                                  'active': true,
                                  'isActive': true,
                                  'author': AuthService.currentUser?.username ?? 'Admin',
                                  'timestamp': DateTime.now().millisecondsSinceEpoch,
                                  'createdAt': FieldValue.serverTimestamp(),
                                };

                                try {
                                  if (AuthService.isFirebaseAvailable) {
                                    await FirebaseFirestore.instance
                                        .collection('app_config')
                                        .doc('global_announcement')
                                        .set(payload, SetOptions(merge: true));
                                    await FirebaseFirestore.instance
                                        .collection('global_announcements')
                                        .doc(nowId)
                                        .set(payload);
                                  }
                                } catch (e) {
                                  debugPrint('Aviso publicando anuncio en Firestore: $e');
                                }

                                if (mounted) {
                                  setState(() {
                                    _lastDismissedAnnouncementId = '';
                                    _activeGlobalAnnouncementTitle = title;
                                    _activeGlobalAnnouncement = text;
                                  });
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('📢 ¡Anuncio Global publicado en vivo para todos los dispositivos!'),
                                      backgroundColor: Color(0xFF00C853),
                                    ),
                                  );
                                }
                                setModalState(() => isPublishing = false);
                                if (ctx.mounted) Navigator.pop(ctx);
                              },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTvSettingsCard({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return FocusableTvCard(
      focusedScale: 1.04,
      focusedBorderColor: color,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: const Color(0xFF111827).withOpacity(0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.1)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: color.withOpacity(0.16),
                shape: BoxShape.circle,
                border: Border.all(color: color.withOpacity(0.5)),
              ),
              child: Icon(icon, color: color, size: 26),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white60,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: Colors.white38, size: 22),
          ],
        ),
      ),
    );
  }

  void _openTvEpgModal(ChannelModel channel) {
    final schedule =
        EpgService.getUpcomingPrograms(channel.name, channel.groupCategory);

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Dialog(
          backgroundColor: const Color(0xFF0B0F19),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
          ),
          child: Container(
            width: 720,
            height: 520,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7B2CBF).withOpacity(0.25),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(Icons.calendar_month,
                          color: Color(0xFF00E5FF), size: 28),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900),
                          ),
                          Text(
                            'Guía EPG Interactiva en Tiempo Real • 🕒 ${_currentTimeNotifier.value}',
                            style: const TextStyle(
                                color: Color(0xFF00E5FF),
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    FocusableTvCard(
                      focusedScale: 1.08,
                      onTap: () => Navigator.pop(ctx),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Text('Cerrar',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ],
                ),
                const Divider(color: Colors.white12, height: 26),
                Expanded(
                  child: ListView.builder(
                    itemCount: schedule.length,
                    itemBuilder: (context, index) {
                      final prog = schedule[index];
                      final isNow = index == 0;
                      final alarmId =
                          '${channel.name}||${prog.title}||${prog.timeFormatted}||${channel.streamUrl}';
                      final hasAlarm = _activeAlarms.contains(alarmId);

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: FocusableTvCard(
                          focusedScale: 1.02,
                          focusedBorderColor: const Color(0xFF00E5FF),
                          onTap: () async {
                            if (isNow) {
                              Navigator.pop(ctx);
                              _playContent(channel);
                            } else {
                              final prefs =
                                  await SharedPreferences.getInstance();
                              setState(() {
                                if (hasAlarm) {
                                  _activeAlarms.remove(alarmId);
                                } else {
                                  _activeAlarms.add(alarmId);
                                }
                              });
                              setModalState(() {});
                              await prefs.setStringList('saved_active_alarms_$_currentProfileId', _activeAlarms.toList());
                            }
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 14),
                            decoration: BoxDecoration(
                              color: isNow
                                  ? const Color(0xFF231B45)
                                  : const Color(0xFF131B2E),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: isNow
                                    ? const Color(0xFF9D4EDD)
                                    : (hasAlarm
                                        ? const Color(0xFFFFB703)
                                        : Colors.white10),
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 5),
                                  decoration: BoxDecoration(
                                    color: isNow
                                        ? Colors.redAccent
                                        : Colors.white12,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    isNow
                                        ? 'EN VIVO'
                                        : prog.timeFormatted.split(' - ').first,
                                    style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        prog.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        prog.timeFormatted,
                                        style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                Icon(
                                  isNow
                                      ? Icons.play_circle_fill
                                      : (hasAlarm
                                          ? Icons.alarm_on
                                          : Icons.alarm_add),
                                  color: isNow
                                      ? const Color(0xFF00E5FF)
                                      : (hasAlarm
                                          ? const Color(0xFFFFB703)
                                          : Colors.white54),
                                  size: 28,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
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

  void _showRenewSubscriptionModal() {
    final pinCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    bool isProcessing = false;
    final bool showBanks = _canSeePaymentBanks;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Dialog(
          backgroundColor: const Color(0xFF0E1320),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
          ),
          child: Container(
            width: 680,
            padding: const EdgeInsets.all(24),
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
                          const Icon(Icons.stars,
                              color: Color(0xFFFFD700), size: 28),
                          const SizedBox(width: 10),
                          Text(
                            showBanks
                                ? 'Renovación de Suscripción VIP'
                                : 'Canjear PIN de Activación',
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w900),
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: refCtrl,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(
                        color: Color(0xFFFFD600), fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.card_giftcard,
                          color: Color(0xFFFFD600)),
                      hintText:
                          '¿Te invitó un amigo? Código de invitación (Opcional)',
                      hintStyle: const TextStyle(color: Colors.white38),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: pinCtrl,
                          textCapitalization: TextCapitalization.characters,
                          style: const TextStyle(
                              color: Colors.white,
                              letterSpacing: 1.5,
                              fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            hintText: 'Ingresa tu PIN: AMEY-30D-XXXX',
                            hintStyle: const TextStyle(color: Colors.white24),
                            filled: true,
                            fillColor: Colors.black38,
                            border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 24, vertical: 18),
                        ),
                        onPressed: isProcessing
                            ? null
                            : () async {
                                final code = pinCtrl.text.trim();
                                if (code.isEmpty) return;
                                setModalState(() => isProcessing = true);
                                final res =
                                    await AuthService.redeemActivationPin(code);
                                setModalState(() => isProcessing = false);
                                if (mounted) {
                                  Navigator.pop(ctx);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(res.message),
                                      backgroundColor: res.isSuccess
                                          ? const Color(0xFF00C853)
                                          : Colors.redAccent,
                                    ),
                                  );
                                  if (res.isSuccess) setState(() {});
                                }
                              },
                        child: const Text('CANJEAR PIN',
                            style: TextStyle(fontWeight: FontWeight.w900)),
                      ),
                    ],
                  ),
                  if (showBanks) ...[
                    const SizedBox(height: 20),
                    const Text('Medios Oficiales de Pago (Cero Comisiones):',
                        style: TextStyle(
                            color: Color(0xFF00E5FF),
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    _buildPaymentRow(
                        'Yape Perú', '905823660 • Titular: CARLOS ACOSTA'),
                    _buildPaymentRow('BCP Soles',
                        '19194759620085 • Titular: ACOSTA NN CARLOS RAFAEL'),
                    _buildPaymentRow('Binance Pay (USDT)', 'Pay ID: 214778098'),
                    _buildPaymentRow('PayPal', 'carlos_87_21@hotmail.com'),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentRow(String title, String detail) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          Text(detail, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  void _openDvrRecordingsVaultModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          final recs = DvrRecordingService.recordings;
          return Dialog(
            backgroundColor: const Color(0xFF0B0F19),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFFFF1744), width: 1.5),
            ),
            child: Container(
              width: 640,
              height: 440,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.fiber_smart_record,
                              color: Color(0xFFFF1744), size: 28),
                          SizedBox(width: 10),
                          Text('Mis Grabaciones DVR',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold)),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.pop(ctx),
                      ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 24),
                  if (recs.isEmpty)
                    const Expanded(
                      child: Center(
                        child: Text(
                          'Aún no tienes grabaciones guardadas en este TV.\nUsa el botón 🔴 REC en el reproductor para grabar.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 14),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        itemCount: recs.length,
                        itemBuilder: (context, index) {
                          final item = recs[index];
                          return ListTile(
                            leading: const Icon(Icons.play_circle_fill,
                                color: Color(0xFF00E5FF), size: 32),
                            title: Text(item.programTitle,
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold)),
                            subtitle: Text(
                                '${item.channelName} • ${item.formattedDuration} • ${item.sizeMb.toStringAsFixed(1)} MB',
                                style: const TextStyle(color: Colors.white60)),
                            trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  color: Colors.redAccent),
                              onPressed: () async {
                                await DvrRecordingService.deleteRecording(
                                    item.id);
                                setModalState(() {});
                                if (mounted) setState(() {});
                              },
                            ),
                            onTap: () {
                              Navigator.pop(ctx);
                              final file = File(item.filePath);
                              if (file.existsSync()) {
                                setState(() {
                                  _selectedSection = 'Televisión';
                                  _isPlayingDvrRecording = true;
                                  _isBehindLive = true;
                                  _activeDvrTitle =
                                      '🔴 DVR: ${item.programTitle}';
                                  _activeDvrFilePath = item.filePath;
                                  _showOsd = true;
                                });
                                _triggerOsdTimer();
                              }
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          );
        },
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
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.id)
            .get();
        final data = doc.data() ?? {};
        if (data['referralCode'] != null &&
            data['referralCode'].toString().isNotEmpty) {
          refCode = data['referralCode'].toString();
        }
        invitedCount =
            (data['referralsCount'] is int) ? data['referralsCount'] as int : 0;
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
        title: const Text('🎁 Círculo AMEYCAR (+15 Días Gratis)',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Comparte tu código con amigos. Cuando canjeen su PIN ingresando tu código, recibirás +15 días gratis automáticamente.',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withOpacity(0.15),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFFD600)),
              ),
              child: Column(
                children: [
                  Text(refCode,
                      style: const TextStyle(
                          color: Color(0xFFFFD600),
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.5)),
                  const SizedBox(height: 4),
                  Text('Amigos invitados: $invitedCount (+${invitedCount * 15} días)',
                      style:
                          const TextStyle(color: Colors.white70, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cerrar',
                style: TextStyle(color: Color(0xFF00E5FF))),
          ),
        ],
      ),
    );
  }

  void _showColorBlindSelectorDialog() {
    final modes = [
      'Normal',
      'Protanopía (Ceguera al rojo)',
      'Deuteranopía (Ceguera al verde)',
      'Tritanopía (Ceguera al azul)',
    ];

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Accesibilidad e Inclusión (Daltonismo)',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: modes.map((m) {
              final sel = _selectedColorBlindMode == m;
              return ListTile(
                leading: Icon(
                  sel ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: const Color(0xFF00E5FF),
                ),
                title: Text(m, style: const TextStyle(color: Colors.white)),
                onTap: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('color_blind_mode', m);
                  await PlayerSettingsService.setColorFilter(m);
                  setState(() => _selectedColorBlindMode = m);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  void _showAccountProfileModal() {
    final user = AuthService.currentUser;
    final avatarIcons = [
      Icons.person,
      Icons.stars,
      Icons.movie,
      Icons.sports_soccer,
      Icons.rocket_launch
    ];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => AlertDialog(
          backgroundColor: const Color(0xFF101726),
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF00E5FF))),
          title: Text('Perfil: ${user?.username ?? "Usuario VIP"}',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Selecciona tu Avatar en TV:',
                    style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: List.generate(avatarIcons.length, (i) {
                    final sel = _customAvatarIdx == i;
                    return FocusableTvCard(
                      focusedScale: 1.15,
                      onTap: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setInt(
                            'custom_avatar_$_currentProfileId', i);
                        setState(() => _customAvatarIdx = i);
                        setModalState(() {});
                      },
                      child: CircleAvatar(
                        radius: 24,
                        backgroundColor:
                            sel ? const Color(0xFF00E5FF) : Colors.white10,
                        child: Icon(avatarIcons[i],
                            color: sel ? Colors.black : Colors.white70),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 18),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          'Estado: ACTIVO • Días restantes: ${user?.daysRemaining ?? 0}',
                          style: const TextStyle(color: Colors.white)),
                      const SizedBox(height: 6),
                      Text('Hardware ID TV: $_hardwareId',
                          style: const TextStyle(
                              color: Color(0xFF00E5FF),
                              fontFamily: 'monospace')),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Listo',
                  style: TextStyle(color: Color(0xFF00E5FF))),
            ),
          ],
        ),
      ),
    );
  }

  void _openParentalManagerDialog() {
    final categories = _channels
        .map((c) => c.groupCategory.isEmpty ? 'General' : c.groupCategory)
        .toSet()
        .toList();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setParentalState) {
          return FutureBuilder(
            future: Future.wait([
              ParentalService.getLockedCategories(),
              ParentalService.getSleepSchedule(),
              ParentalService.getHiddenMenuItems(),
              ParentalService.getProfanityFilterEnabled(),
            ]),
            builder: (context, AsyncSnapshot<List<dynamic>> snapshot) {
              final lockedCats = (snapshot.data?[0] as List<String>?) ?? [];
              final sleepData =
                  (snapshot.data?[1] as Map<String, dynamic>?) ??
                      {'enabled': false, 'startH': 22, 'startM': 0, 'endH': 6, 'endM': 0};
              final hiddenItems =
                  List<String>.from((snapshot.data?[2] as List<String>?) ?? []);
              final profanityFilterOn = (snapshot.data?[3] as bool?) ?? true;
              final sleepEnabled = sleepData['enabled'] as bool;
              final isChatHidden = hiddenItems.contains('chat');

              return Dialog(
                backgroundColor: const Color(0xFF111827),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Colors.amberAccent, width: 1.5),
                ),
                child: Container(
                  width: 620,
                  height: 580,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.shield, color: Colors.amberAccent, size: 28),
                              SizedBox(width: 10),
                              Text('Control Parental & PIN en Nube',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold)),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white70),
                            onPressed: () => Navigator.pop(ctx),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        dense: true,
                        activeColor: const Color(0xFF00E676),
                        title: const Text('Filtro de Groserías en Chat en Vivo',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        subtitle: const Text(
                            'Censura automáticamente palabras obscenas en la sala',
                            style: TextStyle(color: Colors.white60, fontSize: 12)),
                        value: profanityFilterOn,
                        onChanged: (val) async {
                          await ParentalService.setProfanityFilterEnabled(val);
                          setParentalState(() {});
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        activeColor: Colors.amberAccent,
                        title: const Text('Ocultar Chat en Vivo (Modo Niños)',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        subtitle: const Text(
                            'Desactiva por completo el chat y botones en TV y Celular',
                            style: TextStyle(color: Colors.white60, fontSize: 12)),
                        value: isChatHidden,
                        onChanged: (hide) async {
                          if (hide) {
                            if (!hiddenItems.contains('chat')) {
                              hiddenItems.add('chat');
                            }
                            if (_showLiveChat && mounted) {
                              setState(() => _showLiveChat = false);
                            }
                          } else {
                            hiddenItems.remove('chat');
                          }
                          await ParentalService.setHiddenMenuItems(hiddenItems);
                          setParentalState(() {});
                          setState(() {});
                        },
                      ),
                      SwitchListTile(
                        dense: true,
                        activeColor: const Color(0xFF00E5FF),
                        title: const Text('Hora de Sueño (Apagado Nocturno)',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        subtitle: const Text(
                            'Bloquea la reproducción en horario nocturno',
                            style: TextStyle(color: Colors.white60, fontSize: 12)),
                        value: sleepEnabled,
                        onChanged: (val) async {
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
                      const Divider(color: Colors.white12),
                      const Text('Categorías Bloqueadas con PIN:',
                          style: TextStyle(
                              color: Colors.amberAccent,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      Expanded(
                        child: ListView.builder(
                          itemCount: categories.length,
                          itemBuilder: (context, index) {
                            final cat = categories[index];
                            final isLocked = lockedCats.contains(cat);
                            return SwitchListTile(
                              activeColor: Colors.amberAccent,
                              title: Text(cat,
                                  style: const TextStyle(color: Colors.white)),
                              value: isLocked,
                              onChanged: (_) async {
                                await ParentalService.toggleCategoryLock(cat);
                                setParentalState(() {});
                                setState(() {});
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.amberAccent,
                              foregroundColor: Colors.black),
                          icon: const Icon(Icons.pin),
                          label: const Text('Cambiar PIN Parental (4 dígitos)',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          onPressed: () async {
                            final newPin = await showDialog<String>(
                              context: context,
                              builder: (_) => const PinDialog(
                                  title: 'Nuevo PIN Parental (4 dígitos)'),
                            );
                            if (newPin != null && newPin.length == 4) {
                              await ParentalService.setPin(newPin);
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('PIN Parental actualizado.'),
                                    backgroundColor: Color(0xFF00C853),
                                  ),
                                );
                              }
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  void _openM3uDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final listNameCtrl = TextEditingController();
    final m3uCtrl = TextEditingController();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          final isPremium = PremiumManager.isPremium;
          final maxLists = isPremium ? 5 : 1;

          return Dialog(
            backgroundColor: const Color(0xFF0F172A),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF9D4EDD), width: 1.5),
            ),
            child: Container(
              width: 640,
              padding: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Gestor Multi-Lista M3U (${_savedPlaylists.length}/$maxLists)',
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.bold),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70),
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    ..._savedPlaylists.map((pl) {
                      final isActive = pl['isActive'] == true;
                      return ListTile(
                        leading: Icon(
                          isActive
                              ? Icons.radio_button_checked
                              : Icons.radio_button_off,
                          color: const Color(0xFF00E5FF),
                        ),
                        title: Text(pl['name']?.toString() ?? 'Lista M3U',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        subtitle: Text(pl['url']?.toString() ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54)),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.redAccent),
                          onPressed: () async {
                            _savedPlaylists
                                .removeWhere((item) => item['id'] == pl['id']);
                            await prefs.setString('m3u_lists_$_currentProfileId',
                                jsonEncode(_savedPlaylists));
                            await _syncPlaylistsToCloud();
                            setModalState(() {});
                            _loadChannels();
                          },
                        ),
                        onTap: () async {
                          for (var item in _savedPlaylists) {
                            item['isActive'] = (item['id'] == pl['id']);
                          }
                          await prefs.setString('m3u_lists_$_currentProfileId',
                              jsonEncode(_savedPlaylists));
                          await _syncPlaylistsToCloud();
                          if (ctx.mounted) Navigator.pop(ctx);
                          _downloadAndSanitizeM3u(
                            pl['url'].toString(),
                            playlistId: pl['id']?.toString(),
                            playlistName: pl['name']?.toString(),
                          );
                        },
                      );
                    }),
                    if (_savedPlaylists.length < maxLists) ...[
                      const Divider(color: Colors.white12, height: 24),
                      TextField(
                        controller: listNameCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'Nombre de la Lista',
                          labelStyle: TextStyle(color: Colors.white60),
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: m3uCtrl,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'URL de la Lista M3U (http://...)',
                          labelStyle: TextStyle(color: Colors.white60),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00E5FF),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                          icon: const Icon(Icons.cloud_download),
                          label: const Text('GUARDAR Y SINCRONIZAR EN NUBE',
                              style: TextStyle(fontWeight: FontWeight.w900)),
                          onPressed: () async {
                            final url = m3uCtrl.text.trim();
                            if (url.isEmpty) return;
                            final name = listNameCtrl.text.trim().isEmpty
                                ? 'Lista ${_savedPlaylists.length + 1}'
                                : listNameCtrl.text.trim();
                            final newId =
                                'pl_${DateTime.now().millisecondsSinceEpoch}';
                            for (var item in _savedPlaylists) {
                              item['isActive'] = false;
                            }
                            _savedPlaylists.add({
                              'id': newId,
                              'name': name,
                              'url': url,
                              'isActive': true,
                            });
                            await prefs.setString(
                                'm3u_lists_$_currentProfileId',
                                jsonEncode(_savedPlaylists));
                            await _syncPlaylistsToCloud();
                            if (ctx.mounted) Navigator.pop(ctx);
                            _downloadAndSanitizeM3u(url,
                                playlistId: newId, playlistName: name);
                          },
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _openActiveAlarmsManagerModal() {
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) {
          final list = _activeAlarms.toList();
          return AlertDialog(
            backgroundColor: const Color(0xFF0B0F19),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFFFFB703)),
            ),
            title: const Text('⏰ Mis Alarmas Programadas',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
            content: SizedBox(
              width: 500,
              height: 320,
              child: list.isEmpty
                  ? const Center(
                      child: Text('No tienes alarmas programadas actualmente.',
                          style: TextStyle(color: Colors.white60)))
                  : ListView.builder(
                      itemCount: list.length,
                      itemBuilder: (context, index) {
                        final raw = list[index];
                        final parts = raw.split('||');
                        final chName = parts.isNotEmpty ? parts[0] : 'Canal';
                        final progTitle =
                            parts.length > 1 ? parts[1] : 'Programa';
                        final timeStr = parts.length > 2 ? parts[2] : '';
                        return ListTile(
                          leading: const Icon(Icons.alarm_on,
                              color: Color(0xFFFFB703)),
                          title: Text(progTitle,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold)),
                          subtitle: Text('$chName • $timeStr',
                              style:
                                  const TextStyle(color: Color(0xFF00E5FF))),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline,
                                color: Colors.redAccent),
                            onPressed: () async {
                              setState(() => _activeAlarms.remove(raw));
                              setModalState(() {});
                              final prefs =
                                  await SharedPreferences.getInstance();
                              await prefs.setStringList('saved_active_alarms_$_currentProfileId',
                                  _activeAlarms.toList());
                            },
                          ),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar',
                    style: TextStyle(color: Color(0xFF00E5FF))),
              ),
            ],
          );
        },
      ),
    );
  }

  void _openSupportMenu() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF00E676)),
        ),
        title: const Row(
          children: [
            Icon(Icons.support_agent, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text('Soporte Directo & CEO (WhatsApp)',
                style: TextStyle(
                    color: Colors.white, fontWeight: FontWeight.bold)),
          ],
        ),
        content: const Text(
          'Atención Oficial VIP 24/7:\nWhatsApp Oficial CEO: +51 905 823 660\n\nPuedes escribirnos desde tu celular mencionando tu usuario para renovaciones, soporte de canales o liberación de Hardware ID.',
          style: TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Entendido',
                style: TextStyle(color: Color(0xFF00E5FF))),
          ),
        ],
      ),
    );
  }

  void _showLanguageSelectorDialog() {
    final langs = [
      'Español (Latinoamérica)',
      'English (US)',
      'Português (Brasil)'
    ];
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Idioma de la Interfaz y Audio/CC',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: langs.map((l) {
              final sel = _selectedLanguage == l;
              return ListTile(
                leading: Icon(
                  sel ? Icons.radio_button_checked : Icons.radio_button_off,
                  color: const Color(0xFF00E5FF),
                ),
                title: Text(l, style: const TextStyle(color: Colors.white)),
                onTap: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('app_lang', l);
                  await prefs.setString('selected_language', l);
                  if (l.contains('English')) {
                    await PlayerSettingsService.setAudioTrack('Inglés');
                    if (PlayerSettingsService.subtitleTrackNotifier.value != 'Desactivado') {
                      await PlayerSettingsService.setSubtitleTrack('Inglés');
                    }
                  } else if (l.contains('Português')) {
                    await PlayerSettingsService.setAudioTrack('Portugués');
                    if (PlayerSettingsService.subtitleTrackNotifier.value != 'Desactivado') {
                      await PlayerSettingsService.setSubtitleTrack('Portugués');
                    }
                  } else {
                    await PlayerSettingsService.setAudioTrack('Español (Predeterminado)');
                    if (PlayerSettingsService.subtitleTrackNotifier.value != 'Desactivado') {
                      await PlayerSettingsService.setSubtitleTrack('Español');
                    }
                  }
                  setState(() => _selectedLanguage = l);
                  if (ctx.mounted) Navigator.pop(ctx);
                },
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  // Se modificó para recibir una función personalizada si es necesario
  Widget _buildSidebarItem(IconData icon, String title, String section, {VoidCallback? onTapOverride}) {
    final isSelected = _selectedSection == section;
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            if (onTapOverride != null) {
              onTapOverride();
            } else {
              setState(() => _selectedSection = section);
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        onFocusChange: (hasFocus) {
          if (hasFocus) {
            Scrollable.ensureVisible(context, duration: const Duration(milliseconds: 200));
          }
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTapOverride ?? () {
              setState(() => _selectedSection = section);
            },
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
              decoration: BoxDecoration(
                color: hasFocus
                    ? const Color(0xFF00E5FF).withOpacity(0.25)
                    : (isSelected
                        ? Colors.white.withOpacity(0.12)
                        : Colors.transparent),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color:
                      hasFocus ? const Color(0xFF00E5FF) : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Row(
                mainAxisAlignment: _isSidebarExpanded
                    ? MainAxisAlignment.start
                    : MainAxisAlignment.center,
                children: [
                  Icon(icon,
                      color: hasFocus || isSelected
                          ? const Color(0xFF00E5FF)
                          : Colors.white60,
                      size: 24),
                  if (_isSidebarExpanded) ...[
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasFocus || isSelected
                              ? Colors.white
                              : Colors.white60,
                          fontWeight: hasFocus || isSelected
                              ? FontWeight.bold
                              : FontWeight.normal,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }),
      );
    });
  }
}