import 'dart:async';
import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import '../models/channel_model.dart';
import '../widgets/pro_video_player.dart';
import '../widgets/focusable_tv_card.dart';
import '../widgets/tv_content_row.dart';
import '../widgets/zapping_channel_overlay.dart';
import '../services/m3u_sanitizer_service.dart';
import '../services/auth_service.dart';
import '../services/epg_service.dart';

class TvDashboardScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const TvDashboardScreen({super.key, this.onLogout});

  @override
  State<TvDashboardScreen> createState() => _TvDashboardScreenState();
}

class _TvDashboardScreenState extends State<TvDashboardScreen> {
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

  // VARIABLES DE SINCRONIZACIÓN DE PROGRESO Y LISTAS (Sin signos anidados)
  Timer? _progressSyncTimer;
  String? _currentStreamId;
  int _currentPlaybackPosition = 0;
  List<dynamic> _savedPlaylists = [];

  // VARIABLES DE PANTALLA COMPLETA Y OSD
  bool _isFullScreenMode = false;
  bool _showOsd = false;
  bool _isPlayerPaused = false;
  Timer? _osdHideTimer;

  String get _currentProfileId =>
      AuthService.currentActiveProfile?.id ??
      AuthService.currentUser?.id ??
      'default_profile';

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  // 1. CARGA DESDE SHAREDPREFERENCES O FIRESTORE
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

  // 2. DESCARGA Y SANEAMIENTO INTELIGENTE DE LA LISTA M3U
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
          }
        }
      }
    } catch (e) {
      debugPrint('Error descargando M3U en TV: $e');
    }
  }

  // 3. TEMPORIZADOR DE 5 SEGUNDOS PARA GUARDAR PROGRESO EN HIVE Y FIRESTORE
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

  // EL GATILLO DE REPRODUCCIÓN (Llamado desde los carruseles)
  void _playContent(ChannelModel channel) async {
    final int index = _channels.indexOf(channel);
    if (index != -1) {
      unawaited(_syncProgressToCloud());
      _currentPlaybackPosition = 0;

      setState(() {
        _selectedChannelIndex = index;
        _isFullScreenMode = true;
        _showOsd = true;
        _isPlayerPaused = false;
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
                if (key == LogicalKeyboardKey.arrowUp) {
                  _previousChannel();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowDown) {
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
              // 1. CAPA DE VIDEO (Fondo Absoluto)
              Positioned.fill(
                child: ProVideoPlayer(
                  streamUrl: _channels.isNotEmpty
                      ? _channels[_selectedChannelIndex].streamUrl
                      : '',
                  isPlaying: !_isPlayerPaused,
                ),
              ),

              if (!_isFullScreenMode) ...[
                // Oscurecimiento base para resaltar la UI
                Positioned.fill(
                  child: Container(color: Colors.black.withOpacity(0.4)),
                ),

                // 2. CAPA ÁREA PRINCIPAL (VOD & Inteligencia Artificial)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeOutCubic,
                  left: _isSidebarExpanded ? 260 : 90,
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: FocusTraversalGroup(
                      policy: WidgetOrderTraversalPolicy(),
                      child: _buildMainVODContent()),
                ),

                // 3. CAPA ZAPPING OVERLAY CON CANALES REALES EN VIVO
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

                // 4. CAPA SIDEBAR TRANSLÚCIDO E INTELIGENTE
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
                            child: Column(
                              crossAxisAlignment: _isSidebarExpanded
                                  ? CrossAxisAlignment.start
                                  : CrossAxisAlignment.center,
                              children: [
                                _isSidebarExpanded
                                    ? const Padding(
                                        padding: EdgeInsets.symmetric(
                                            horizontal: 16, vertical: 8),
                                        child: Text('AMEYCAR TV',
                                            style: TextStyle(
                                                color: Color(0xFF00E5FF),
                                                fontSize: 18,
                                                fontWeight: FontWeight.bold,
                                                letterSpacing: 1.2)),
                                      )
                                    : const Padding(
                                        padding: EdgeInsets.only(top: 8.0),
                                        child: Icon(Icons.tv_rounded,
                                            color: Color(0xFF00E5FF), size: 32),
                                      ),
                                const SizedBox(height: 32),
                                Expanded(
                                  child: ListView(
                                    children: [
                                      _buildSidebarItem(Icons.home_filled,
                                          'Inicio VIP', 'Inicio VIP'),
                                      _buildSidebarItem(Icons.live_tv,
                                          'Televisión', 'Televisión'),
                                      _buildSidebarItem(
                                          Icons.movie, 'Cine IA', 'Cine IA'),
                                      _buildSidebarItem(
                                          Icons.tv, 'Series', 'Series'),
                                      _buildSidebarItem(
                                          Icons.settings, 'Ajustes', 'Ajustes'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              // MODO CINE / PANTALLA COMPLETA CON OSD
              if (_isFullScreenMode && _showOsd && _channels.isNotEmpty)
                ZappingChannelOverlay(
                  channel: _channels[_selectedChannelIndex],
                  channelIndex: _selectedChannelIndex,
                  totalChannels: _channels.length,
                  isPlaying: !_isPlayerPaused,
                  isFullScreen: true,
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
                  onRewind15s: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('⏪ Retrocediendo -15s')));
                  },
                  onForward15s: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('⏩ Adelantando +15s')));
                  },
                  onOpenEpg: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Guía EPG Próximamente')));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- EL ÁREA DE CONTENIDO (CARRUSELES ALIMENTADOS POR EL PARSER REAL) ---
  Widget _buildMainVODContent() {
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
              child: Text(
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
            ),
            const SizedBox(height: 24),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: FocusTraversalGroup(
                  policy: WidgetOrderTraversalPolicy(),
                  child: _buildHeroBanner()),
            ),
            const SizedBox(height: 48),

            // Carrusel de Películas Reales
            if (_movies.isNotEmpty)
              FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: TvContentRow(
                  title: '🍿 Películas Premium',
                  items: _movies,
                  height: 240,
                  cardWidth: 160,
                  onItemTap: _playContent,
                ),
              ),
            if (_movies.isNotEmpty) const SizedBox(height: 32),

            // Carrusel de Series Reales (Formato ancho 16:9)
            if (_series.isNotEmpty)
              FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: TvContentRow(
                  title: '📺 Series Destacadas',
                  items: _series,
                  height: 160,
                  cardWidth: 280,
                  onItemTap: _playContent,
                ),
              ),
            if (_series.isNotEmpty) const SizedBox(height: 32),

            // Carrusel de Canales en Vivo
            if (_liveTv.isNotEmpty)
              FocusTraversalGroup(
                policy: WidgetOrderTraversalPolicy(),
                child: TvContentRow(
                  title: '🔴 Televisión en Vivo',
                  items: _liveTv,
                  height: 240,
                  cardWidth: 160,
                  onItemTap: _playContent,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroBanner() {
    final featuredTitle =
        _movies.isNotEmpty ? _movies.first.name : 'AMEYCAR ORIGINALS';
    final featuredDesc = _movies.isNotEmpty
        ? 'Estreno recomendado exclusivamente para ti.'
        : 'Disfruta de la mejor experiencia cinematográfica en casa.';

    return Container(
      height: 340,
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF131726), Color(0xFF0A0C14)],
        ),
        image: _movies.isNotEmpty && _movies.first.logoUrl.isNotEmpty
            ? DecorationImage(
                image: NetworkImage(_movies.first.logoUrl),
                fit: BoxFit.cover,
                colorFilter: ColorFilter.mode(
                    Colors.black.withOpacity(0.6), BlendMode.darken),
              )
            : null,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 25,
              offset: const Offset(0, 15)),
        ],
      ),
      child: Stack(
        children: [
          if (_movies.isEmpty || _movies.first.logoUrl.isEmpty) ...[
            Positioned(
              right: -60,
              top: -60,
              child: Icon(Icons.hub_outlined,
                  size: 400, color: const Color(0xFF00E5FF).withOpacity(0.04)),
            ),
            Positioned(
              right: 60,
              bottom: -40,
              child: Icon(Icons.movie_filter_rounded,
                  size: 250, color: Colors.deepPurpleAccent.withOpacity(0.05)),
            ),
          ],
          Padding(
            padding: const EdgeInsets.all(40.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.5)),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome,
                          color: Color(0xFF00E5FF), size: 16),
                      SizedBox(width: 8),
                      Text('Recomendación IA: 98% Afinidad',
                          style: TextStyle(
                              color: Color(0xFF00E5FF),
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              letterSpacing: 0.5)),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  featuredTitle,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 42,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2.5,
                      shadows: [Shadow(color: Colors.black, blurRadius: 10)]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 12),
                Text(
                  featuredDesc,
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 16,
                      height: 1.5,
                      shadows: [Shadow(color: Colors.black, blurRadius: 5)]),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    _buildHeroButton('Reproducir', Icons.play_arrow_rounded, true,
                        onTap: () {
                      if (_movies.isNotEmpty) {
                        _playContent(_movies.first);
                      }
                    }),
                    const SizedBox(width: 20),
                    _buildHeroButton(
                        'Más Información', Icons.info_outline_rounded, false),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeroButton(String text, IconData icon, bool isPrimary,
      {VoidCallback? onTap}) {
    return Builder(builder: (context) {
      return Focus(
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap ?? () => debugPrint('$text presionado'),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
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
                children: [
                  Icon(icon,
                      color: hasFocus
                          ? Colors.black
                          : (isPrimary ? Colors.black : Colors.white),
                      size: 26),
                  const SizedBox(width: 8),
                  Text(text,
                      style: TextStyle(
                          color: hasFocus
                              ? Colors.black
                              : (isPrimary ? Colors.black : Colors.white),
                          fontWeight: FontWeight.bold,
                          fontSize: 17)),
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
                    Text(
                      title,
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