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
import 'package:url_launcher/url_launcher.dart';

import '../models/channel_model.dart';
import '../widgets/pro_video_player.dart';
import '../widgets/focusable_tv_card.dart';
import '../widgets/tv_content_row.dart';
import '../widgets/zapping_channel_overlay.dart';
import '../widgets/pin_dialog.dart';
import '../widgets/alexa_voice_sheet.dart';
import '../services/m3u_sanitizer_service.dart';
import '../services/auth_service.dart';
import '../services/epg_service.dart';
import '../services/dvr_recording_service.dart';
import '../services/parental_service.dart';
import '../utils/premium_manager.dart';
import 'profile_selector_screen.dart';
import 'remote_control_screen.dart';
import 'family_panel_screen.dart';
import 'tv_vod_details_screen.dart';

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

  bool _isSidebarExpanded = false;
  bool _isZappingOverlayVisible = false;
  Timer? _zappingHideTimer;

  String _selectedSection = 'Inicio VIP';

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

  // VARIABLES DE PANTALLA COMPLETA, DVR Y OSD
  bool _isFullScreenMode = false;
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
  String _currentTime = '';

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
    _startClockTimer();
    _loadInitialPreferences();
    _loadChannels();
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
    setState(() {
      _currentTime = '$h:$m:$s';
    });
  }

  Future<void> _loadInitialPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hw = await AuthService.getDeviceHardwareId();
      final alarms = prefs.getStringList('saved_active_alarms_$_currentProfileId') ?? [];
      if (mounted) {
        setState(() {
          _selectedLanguage = prefs.getString('app_lang') ?? 'Español (Latinoamérica)';
          _selectedColorBlindMode = prefs.getString('color_blind_mode') ?? 'Normal';
          _customAvatarIdx = prefs.getInt('custom_avatar_$_currentProfileId') ?? 0;
          _hardwareId = hw;
          _activeAlarms
            ..clear()
            ..addAll(alarms);
        });
      }
    } catch (_) {}
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
        loadedChannels = M3USanitizerService.parseAndSanitize(savedM3u);
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
        final parsed = M3USanitizerService.parseAndSanitize(res.body);
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
                content: Text('¡${parsed.length} canales sincronizados en "${playlistName ?? "Lista"}"!'),
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

    final int index = _channels.indexOf(channel);
    if (index != -1) {
      unawaited(_syncProgressToCloud());
      _currentPlaybackPosition = 0;

      setState(() {
        _selectedChannelIndex = index;
        _isFullScreenMode = true;
        _showOsd = true;
        _isPlayerPaused = false;
        _isBehindLive = false;
        _isPlayingDvrRecording = false;
        _activeDvrTitle = null;
        _activeDvrFilePath = null;
      });

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
    if (_selectedSection == 'Cine IA' && _movies.isNotEmpty) {
      searchPool = _movies;
    } else if (_selectedSection == 'Series' && _series.isNotEmpty) {
      searchPool = _series;
    } else {
      searchPool = _liveTv.isNotEmpty ? _liveTv : _channels;
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

  void _triggerOsdTimer() {
    _osdHideTimer?.cancel();
    _osdHideTimer = Timer(const Duration(seconds: 6), () {
      if (mounted) {
        setState(() => _showOsd = false);
      }
    });
  }

  void _nextChannel() {
    if (_channels.isEmpty) return;
    unawaited(_syncProgressToCloud());
    _currentPlaybackPosition = 0;
    final int total = _channels.length;
    setState(() {
      _selectedChannelIndex = (_selectedChannelIndex + 1).remainder(total);
      _isPlayerPaused = false;
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrFilePath = null;
      _showOsd = true;
    });
    _triggerOsdTimer();
    _startProgressSync(_channels[_selectedChannelIndex].streamUrl);
  }

  void _previousChannel() {
    if (_channels.isEmpty) return;
    unawaited(_syncProgressToCloud());
    _currentPlaybackPosition = 0;
    final int total = _channels.length;
    setState(() {
      _selectedChannelIndex = (_selectedChannelIndex - 1 < 0)
          ? total - 1
          : _selectedChannelIndex - 1;
      _isPlayerPaused = false;
      _isBehindLive = false;
      _isPlayingDvrRecording = false;
      _activeDvrFilePath = null;
      _showOsd = true;
    });
    _triggerOsdTimer();
    _startProgressSync(_channels[_selectedChannelIndex].streamUrl);
  }

  void _triggerZappingOverlay() {
    setState(() => _isZappingOverlayVisible = true);
    FocusScope.of(context).requestFocus(_zappingFocusNode);

    _zappingHideTimer?.cancel();
    _zappingHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _isZappingOverlayVisible = false);
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    _progressSyncTimer?.cancel();
    unawaited(_syncProgressToCloud());
    _zappingHideTimer?.cancel();
    _osdHideTimer?.cancel();
    _tvFocusScope.dispose();
    _sidebarFocusNode.dispose();
    _zappingFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final activeChannel = _channels.isNotEmpty
        ? _channels[_selectedChannelIndex]
        : null;

    return PopScope(
      canPop: !_isFullScreenMode,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && _isFullScreenMode) {
          setState(() {
            _isFullScreenMode = false;
            _showOsd = false;
          });
        }
      },
      child: FocusScope(
        node: _tvFocusScope,
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent) {
            final key = event.logicalKey;

            if (_isFullScreenMode) {
              if (key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.gameButtonA) {
                if (!_showOsd) {
                  _toggleOsd();
                  return KeyEventResult.handled;
                }
              }

              if (!_showOsd) {
                if (key == LogicalKeyboardKey.arrowUp ||
                    key == LogicalKeyboardKey.channelUp) {
                  _previousChannel();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowDown ||
                    key == LogicalKeyboardKey.channelDown) {
                  _nextChannel();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowLeft ||
                    key == LogicalKeyboardKey.arrowRight) {
                  _toggleOsd();
                  return KeyEventResult.handled;
                }
              }

              if (key == LogicalKeyboardKey.mediaPlayPause) {
                setState(() => _isPlayerPaused = !_isPlayerPaused);
                return KeyEventResult.handled;
              }
            }
          }
          return KeyEventResult.ignored;
        },
        child: Scaffold(
          backgroundColor: const Color(0xFF070A10),
          body: Stack(
            children: [
              Positioned.fill(
                child: ProVideoPlayer(
                  key: _playerKey,
                  streamUrl: (_isPlayingDvrRecording && _activeDvrFilePath != null)
                      ? _activeDvrFilePath!
                      : (activeChannel?.streamUrl ?? ''),
                  isPlaying: !_isPlayerPaused,
                  colorBlindMode: _selectedColorBlindMode,
                ),
              ),

              if (!_isFullScreenMode) ...[
                Positioned.fill(
                  child: Container(
                    color: _selectedSection == 'Ajustes'
                        ? const Color(0xFF070A10).withOpacity(0.88)
                        : Colors.black.withOpacity(0.45),
                  ),
                ),

                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: _isSidebarExpanded ? 260 : 90,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: FocusTraversalGroup(
                    policy: WidgetOrderTraversalPolicy(),
                    child: _selectedSection == 'Ajustes'
                        ? _buildTvSettingsContent()
                        : _buildMainVODContent(),
                  ),
                ),

                Positioned(
                  top: 32,
                  right: 32,
                  child: _buildSearchButton(),
                ),

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
                        child: Focus(
                          focusNode: _zappingFocusNode,
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

                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: _isSidebarExpanded ? 240 : 75,
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
                          onFocusChange: (hasFocus) {
                            if (mounted) {
                              setState(() => _isSidebarExpanded = hasFocus);
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
                                              Text('🕒 $_currentTime',
                                                  style: const TextStyle(
                                                      color: Color(0xFFC77DFF),
                                                      fontSize: 11,
                                                      fontWeight:
                                                          FontWeight.bold)),
                                            ],
                                          ),
                                        )
                                      : const Padding(
                                          padding: EdgeInsets.only(top: 8.0),
                                          child: Icon(Icons.tv_rounded,
                                              color: Color(0xFF00E5FF), size: 32),
                                        ),
                                  const SizedBox(height: 28),
                                  Builder(builder: (context) {
                                    return Focus(
                                      onKeyEvent: (node, event) {
                                        if (event is KeyDownEvent &&
                                            (event.logicalKey == LogicalKeyboardKey.select ||
                                                event.logicalKey == LogicalKeyboardKey.enter ||
                                                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
                                          _startVoiceSearch();
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
                                          onTap: _startVoiceSearch,
                                          child: AnimatedContainer(
                                            duration: const Duration(milliseconds: 150),
                                            margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                                            decoration: BoxDecoration(
                                              color: hasFocus
                                                  ? const Color(0xFF00E5FF).withOpacity(0.25)
                                                  : Colors.transparent,
                                              borderRadius: BorderRadius.circular(10),
                                              border: Border.all(
                                                color: hasFocus ? const Color(0xFF00E5FF) : Colors.transparent,
                                                width: 2,
                                              ),
                                            ),
                                            child: Row(
                                              mainAxisAlignment: _isSidebarExpanded
                                                  ? MainAxisAlignment.start
                                                  : MainAxisAlignment.center,
                                              children: [
                                                Icon(Icons.mic,
                                                    color: hasFocus ? const Color(0xFF00E5FF) : Colors.white60,
                                                    size: 24),
                                                if (_isSidebarExpanded) ...[
                                                  const SizedBox(width: 16),
                                                  Expanded(
                                                    child: Text(
                                                      'Búsqueda IA',
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
                                                      style: TextStyle(
                                                        color: hasFocus ? Colors.white : Colors.white60,
                                                        fontWeight: hasFocus ? FontWeight.bold : FontWeight.normal,
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
                                  }),
                                  const Divider(color: Colors.white12, height: 16),
                                  _buildSidebarItem(Icons.home_filled, 'Inicio VIP', 'Inicio VIP'),
                                  _buildSidebarItem(Icons.live_tv, 'Televisión', 'Televisión'),
                                  _buildSidebarItem(Icons.movie, 'Cine IA', 'Cine IA'),
                                  _buildSidebarItem(Icons.tv, 'Series', 'Series'),
                                  _buildSidebarItem(Icons.settings, 'Ajustes', 'Ajustes'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              if (_isFullScreenMode && _showOsd && activeChannel != null)
                ZappingChannelOverlay(
                  channel: activeChannel,
                  channelIndex: _selectedChannelIndex,
                  totalChannels: _channels.length,
                  isPlaying: !_isPlayerPaused,
                  isFullScreen: true,
                  isBehindLive: _isBehindLive,
                  isPlayingDvrRecording: _isPlayingDvrRecording,
                  dvrRecordingTitle: _activeDvrTitle,
                  onPlayPause: () {
                    setState(() => _isPlayerPaused = !_isPlayerPaused);
                    _triggerOsdTimer();
                  },
                  onNext: _nextChannel,
                  onPrevious: _previousChannel,
                  onToggleFullScreen: () => setState(() {
                    _isFullScreenMode = false;
                    _showOsd = false;
                  }),
                  onRewind15s: () => _seekRelativeSeconds(-15),
                  onForward15s: () => _seekRelativeSeconds(15),
                  onJumpToLive: _jumpBackToLiveStream,
                  onToggleRecord: () => _toggleManualDvrRecording(activeChannel),
                  onOpenEpg: () => _openTvEpgModal(activeChannel),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSearchButton() {
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            _startVoiceSearch();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: _startVoiceSearch,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: hasFocus ? const Color(0xFF00E5FF) : Colors.black.withOpacity(0.6),
                shape: BoxShape.circle,
                border: Border.all(
                  color: hasFocus ? Colors.white : Colors.white38,
                  width: hasFocus ? 2 : 1,
                ),
                boxShadow: hasFocus
                    ? [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.6), blurRadius: 15)]
                    : [],
              ),
              child: Icon(
                Icons.search,
                color: hasFocus ? Colors.black : Colors.white,
                size: 28,
              ),
            ),
          );
        }),
      );
    });
  }

  Widget _buildMainVODContent() {
    final bool showAll = _selectedSection == 'Inicio VIP';
    final bool showLiveOnly = _selectedSection == 'Televisión';
    final bool showMoviesOnly = _selectedSection == 'Cine IA';
    final bool showSeriesOnly = _selectedSection == 'Series';

    return SingleChildScrollView(
      clipBehavior: Clip.none,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(top: 32.0, bottom: 80.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    _selectedSection,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 38,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.5,
                      shadows: [
                        Shadow(
                            color: Colors.black87,
                            blurRadius: 15,
                            offset: Offset(0, 5))
                      ],
                    ),
                  ),
                  if (_channels.isNotEmpty)
                    FocusTraversalGroup(
                      policy: WidgetOrderTraversalPolicy(),
                      child: _buildHeroButton(
                        'Ver Canal Actual',
                        Icons.fullscreen_rounded,
                        false,
                        onTap: () {
                          setState(() {
                            _isFullScreenMode = true;
                            _showOsd = true;
                          });
                          _triggerOsdTimer();
                        },
                      ),
                    ),
                ],
              ),
            ),
            
            const SizedBox(height: 40), 

            if ((showAll || showLiveOnly) && _liveTv.isNotEmpty) ...[
              FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: TvContentRow(
                  title: '🔴 Televisión en Vivo (${_liveTv.length})',
                  items: _liveTv,
                  height: 220,
                  cardWidth: 165,
                  onItemTap: _playContent,
                ),
              ),
              const SizedBox(height: 32),
            ],

            if ((showAll || showMoviesOnly) && _movies.isNotEmpty) ...[
              FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: TvContentRow(
                  title: '🍿 Películas Premium (${_movies.length})',
                  items: _movies,
                  height: 240,
                  cardWidth: 160,
                  onItemTap: _playContent,
                ),
              ),
              const SizedBox(height: 32),
            ],

            if ((showAll || showSeriesOnly) && _series.isNotEmpty) ...[
              FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: TvContentRow(
                  title: '📺 Series Destacadas (${_series.length})',
                  items: _series,
                  height: 165,
                  cardWidth: 270,
                  onItemTap: _playContent,
                ),
              ),
              const SizedBox(height: 32),
            ],
          ],
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
            policy: WidgetOrderTraversalPolicy(),
            child: GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 18,
              crossAxisSpacing: 18,
              childAspectRatio: 2.35,
              children: [
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
                            'Guía EPG Interactiva en Tiempo Real • 🕒 $_currentTime',
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
                                  _isPlayingDvrRecording = true;
                                  _isBehindLive = true;
                                  _activeDvrTitle =
                                      '🔴 DVR: ${item.programTitle}';
                                  _activeDvrFilePath = item.filePath;
                                  _isFullScreenMode = true;
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
            ]),
            builder: (context, AsyncSnapshot<List<dynamic>> snapshot) {
              final lockedCats = (snapshot.data?[0] as List<String>?) ?? [];
              final sleepData =
                  (snapshot.data?[1] as Map<String, dynamic>?) ??
                      {'enabled': false, 'startH': 22, 'startM': 0, 'endH': 6, 'endM': 0};
              final sleepEnabled = sleepData['enabled'] as bool;

              return Dialog(
                backgroundColor: const Color(0xFF111827),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: const BorderSide(color: Colors.amberAccent, width: 1.5),
                ),
                child: Container(
                  width: 600,
                  height: 500,
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
                      const SizedBox(height: 12),
                      SwitchListTile(
                        activeColor: const Color(0xFF00E5FF),
                        title: const Text('Hora de Sueño (Apagado Nocturno)',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                        subtitle: const Text(
                            'Bloquea la reproducción en horario nocturno',
                            style: TextStyle(color: Colors.white60)),
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
                              await prefs.setStringList('saved_active_alarms',
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
        title: const Text('Idioma de la Interfaz',
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

  Widget _buildHeroButton(String text, IconData icon, bool isPrimary,
      {VoidCallback? onTap}) {
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            onTap?.call();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap ?? () => debugPrint('$text presionado'),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: hasFocus
                    ? const Color(0xFF00E5FF)
                    : (isPrimary ? Colors.white : Colors.white.withOpacity(0.08)),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: hasFocus
                      ? Colors.white
                      : (isPrimary
                          ? Colors.transparent
                          : Colors.white.withOpacity(0.2)),
                  width: hasFocus ? 3 : 1,
                ),
                boxShadow: hasFocus
                    ? [
                        BoxShadow(
                            color: const Color(0xFF00E5FF).withOpacity(0.6),
                            blurRadius: 20)
                      ]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon,
                      color: hasFocus
                          ? Colors.black
                          : (isPrimary ? Colors.black : Colors.white),
                      size: 24),
                  const SizedBox(width: 8),
                  Text(text,
                      style: TextStyle(
                          color: hasFocus
                              ? Colors.black
                              : (isPrimary ? Colors.black : Colors.white),
                          fontWeight: FontWeight.bold,
                          fontSize: 15)),
                ],
              ),
            ),
          );
        }),
      );
    });
  }

  Widget _buildSidebarItem(IconData icon, String title, String section) {
    final isSelected = _selectedSection == section;
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            setState(() => _selectedSection = section);
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
            onTap: () {
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