import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'models/channel_model.dart';
import 'services/m3u_sanitizer_service.dart';
import 'services/epg_service.dart';
import 'widgets/alexa_voice_sheet.dart';
import 'widgets/vod_grid_view.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AmeycarTVApp());
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
        primaryColor: const Color(0xFF00E5FF),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFFFFB703),
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
  bool _isFullScreenMode = false;
  bool _showOsd = true;

  final Set<String> _activeAlarms = {};

  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadSavedChannels();
  }

  void _loadSavedChannels() async {
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
    setState(() {});
  }

  void _initializeVideo(String url) async {
    if (!mounted) return;
    setState(() => _isVideoLoading = true);

    final oldController = _videoPlayerController;
    _videoPlayerController = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: false),
    );

    oldController?.dispose();

    try {
      await _videoPlayerController!.initialize();
      if (mounted) {
        _videoPlayerController!.play();
        _videoPlayerController!.setLooping(true);
        setState(() => _isVideoLoading = false);
      }
    } catch (e) {
      debugPrint('Error reproduciendo video: $e');
      if (mounted) {
        setState(() => _isVideoLoading = false);
      }
    }
  }

  void _nextChannel() {
    final currentList = _filteredChannels;
    if (currentList.isEmpty) return;
    final currentCh = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;
    if (currentCh == null) return;
    int curIdxInFiltered = currentList.indexOf(currentCh);
    int nextIdx = (curIdxInFiltered + 1) % currentList.length;
    _changeChannel(currentList[nextIdx]);
  }

  void _previousChannel() {
    final currentList = _filteredChannels;
    if (currentList.isEmpty) return;
    final currentCh = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;
    if (currentCh == null) return;
    int curIdxInFiltered = currentList.indexOf(currentCh);
    int prevIdx = (curIdxInFiltered - 1 < 0) ? currentList.length - 1 : curIdxInFiltered - 1;
    _changeChannel(currentList[prevIdx]);
  }

  void _changeChannel(ChannelModel ch) async {
    final realIndex = _channels.indexOf(ch);
    if (realIndex != -1) {
      setState(() {
        _selectedChannelIndex = realIndex;
        _showOsd = true;
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('last_played_channel_index', realIndex);

      _initializeVideo(ch.streamUrl);
      _triggerOsdTimer();
    }
  }

  void _triggerOsdTimer() {
    setState(() => _showOsd = true);
    Future.delayed(const Duration(seconds: 4), () {
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
      }
    });
  }

  void _startVoiceSearch() {
    AlexaVoiceSheet.show(
      context,
      channels: _channels,
      currentChannel: _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null,
      onChannelSelected: (channel) {
        if (channel is ChannelModel) {
          _changeChannel(channel);
        }
      },
      onOpenEpg: () {
        final ch = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;
        if (ch != null) _openEpgScheduleModal(ch);
      },
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
            border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4), width: 1.5),
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
                          const Text(
                            'Guía de Programación en Tiempo Real',
                            style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
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
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E293B),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '🔔 ${_activeAlarms.length} activas',
                      style: const TextStyle(color: Color(0xFFFFB703), fontSize: 11, fontWeight: FontWeight.bold),
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
                            ? const Color(0x3300E5FF)
                            : hasAlarm
                                ? const Color(0x22FFB703)
                                : const Color(0xFF131B2E),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isNow
                              ? const Color(0xFF00E5FF)
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
                                setState(() {
                                  if (hasAlarm) {
                                    _activeAlarms.remove(alarmId);
                                  } else {
                                    _activeAlarms.add(alarmId);
                                  }
                                });
                                setModalState(() {});
                                await prefs.setStringList('saved_active_alarms', _activeAlarms.toList());

                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(hasAlarm
                                        ? '🔕 Alarma cancelada para "${prog.title}"'
                                        : '⏰ ¡Alarma activada para "${prog.title}" a las ${prog.timeFormatted.split(' - ')[0]}!'),
                                    backgroundColor: hasAlarm ? Colors.redAccent : const Color(0xFF00E5FF),
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
            side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
          ),
          title: const Row(
            children: [
              Icon(Icons.playlist_play, color: Color(0xFF00E5FF)),
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
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
              onPressed: () async {
                final url = controller.text.trim();
                if (url.isNotEmpty) {
                  Navigator.pop(ctx);
                  _downloadAndSanitizeM3u(url);
                }
              },
              child: const Text('Cargar y Sanitizar', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
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

  // Filtros por sección VOD
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
    final activeChannel = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    if (_isFullScreenMode) {
      return _buildImmersivePlayer(activeChannel);
    }

    return SafeArea(
      child: Column(
        children: [
          _buildTopGlassBar(),
          _buildSectionTabs(),

          // Si está en 'En Vivo', muestra el reproductor y la lista de TV
          if (_selectedSection == 'En Vivo') ...[
            _buildVideoPlayerSection(activeChannel),
            _buildLiveEpgCard(activeChannel),
            _buildCategoryChips(),
            Expanded(child: _buildChannelListView()),
          ]
          // Si está en 'Películas', muestra la cuadrícula estilo Netflix
          else if (_selectedSection == 'Películas') ...[
            Expanded(
              child: VodGridView(
                items: _movies,
                contentType: 'movie',
                onPlayItem: (item) {
                  _changeChannel(item);
                  setState(() => _isFullScreenMode = true);
                },
              ),
            ),
          ]
          // Si está en 'Series', muestra la cuadrícula de series
          else ...[
            Expanded(
              child: VodGridView(
                items: _series,
                contentType: 'series',
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
    final activeChannel = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    if (_isFullScreenMode) {
      return _buildImmersivePlayer(activeChannel);
    }

    return Row(
      children: [
        Container(
          width: 180,
          decoration: BoxDecoration(
            color: const Color(0xFF0F172A).withOpacity(0.85),
            border: const Border(right: BorderSide(color: Color(0x3300E5FF))),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 16, top: 20, bottom: 16),
                child: Text(
                  'AMEYCAR TV',
                  style: TextStyle(
                    color: Color(0xFF00E5FF),
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              _buildSideMenuItem(Icons.live_tv, 'En Vivo', () => setState(() => _selectedSection = 'En Vivo')),
              _buildSideMenuItem(Icons.movie, 'Películas', () => setState(() => _selectedSection = 'Películas')),
              _buildSideMenuItem(Icons.tv, 'Series', () => setState(() => _selectedSection = 'Series')),
              const Divider(color: Colors.white12),
              _buildSideMenuItem(Icons.search, 'Buscar', () => setState(() => _isSearching = !_isSearching)),
              _buildSideMenuItem(Icons.mic, 'Asistente IA', _startVoiceSearch),
              _buildSideMenuItem(Icons.playlist_add, 'Listas M3U', _openM3uDialog),
            ],
          ),
        ),

        // Contenido dinámico según la sección seleccionada
        if (_selectedSection == 'En Vivo') ...[
          Expanded(
            flex: 3,
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0x3300E5FF)),
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

  Widget _buildTopGlassBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.8),
        border: const Border(bottom: BorderSide(color: Color(0x2200E5FF))),
      ),
      child: _isSearching
          ? _buildActiveSearchBar()
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text(
                      'AMEYCAR TV',
                      style: TextStyle(
                        color: Color(0xFF00E5FF),
                        fontWeight: FontWeight.w900,
                        fontSize: 18,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.red),
                      ),
                      child: Text(
                        _selectedSection == 'En Vivo' ? 'LIVE' : _selectedSection.toUpperCase(),
                        style: const TextStyle(color: Colors.red, fontSize: 9, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.search, color: Color(0xFF00E5FF), size: 22),
                      tooltip: 'Buscar',
                      onPressed: () => setState(() => _isSearching = true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.playlist_add, color: Colors.white70, size: 22),
                      tooltip: 'Cargar lista M3U',
                      onPressed: _openM3uDialog,
                    ),
                    IconButton(
                      icon: const Icon(Icons.mic, color: Color(0xFF00E5FF), size: 24),
                      tooltip: 'Asistente de Voz',
                      onPressed: _startVoiceSearch,
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildActiveSearchBar() {
    return Row(
      children: [
        const Icon(Icons.search, color: Color(0xFF00E5FF), size: 20),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: _searchController,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: const InputDecoration(
              hintText: 'Buscar por nombre o número...',
              hintStyle: TextStyle(color: Colors.white38),
              border: InputBorder.none,
              isDense: true,
            ),
            onChanged: (val) {
              setState(() => _searchQuery = val.trim());
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, color: Colors.white54, size: 20),
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
            onTap: () => setState(() => _selectedSection = section),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                border: isSelected
                    ? const Border(bottom: BorderSide(color: Color(0xFF00E5FF), width: 2))
                    : null,
              ),
              child: Text(
                section,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF00E5FF) : Colors.white54,
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

  Widget _buildVideoPlayerSection(ChannelModel? activeChannel) {
    return GestureDetector(
      onTap: _toggleOsd,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! < -150) _nextChannel();
        if (details.primaryVelocity! > 150) _previousChannel();
      },
      onDoubleTap: () {
        setState(() => _isFullScreenMode = !_isFullScreenMode);
      },
      child: Container(
        height: 215,
        width: double.infinity,
        color: Colors.black,
        child: Stack(
          children: [
            _isVideoLoading
                ? const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF)))
                : (_videoPlayerController != null && _videoPlayerController!.value.isInitialized)
                    ? Center(child: AspectRatio(aspectRatio: _videoPlayerController!.value.aspectRatio, child: VideoPlayer(_videoPlayerController!)))
                    : const Center(child: Icon(Icons.tv_off, color: Colors.white38, size: 48)),

            if (_showOsd)
              Positioned(
                bottom: 8,
                left: 8,
                right: 8,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      color: Colors.black.withOpacity(0.65),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(
                              activeChannel != null ? '${activeChannel.number}. ${activeChannel.name}' : '',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          Row(
                            children: [
                              IconButton(
                                icon: const Icon(Icons.fullscreen, color: Colors.white70, size: 20),
                                onPressed: () => setState(() => _isFullScreenMode = true),
                              ),
                              IconButton(
                                icon: const Icon(Icons.alarm_add, color: Color(0xFFFFB703), size: 20),
                                onPressed: () {
                                  if (activeChannel != null) _openEpgScheduleModal(activeChannel);
                                },
                              ),
                            ],
                          )
                        ],
                      ),
                    ),
                  ),
                ),
              )
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
          border: const Border(bottom: BorderSide(color: Color(0x1F00E5FF))),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Icon(Icons.live_tv, color: Colors.redAccent, size: 14),
                    const SizedBox(width: 6),
                    Text(
                      currentProg.title,
                      style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
                Text(
                  currentProg.timeFormatted,
                  style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'A continuación: ${nextProg.title}',
                  style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
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
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
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
                color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF1E293B).withOpacity(0.8),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: isSelected ? const Color(0xFF00E5FF) : Colors.white10,
                ),
              ),
              child: Center(
                child: Text(
                  category,
                  style: TextStyle(
                    color: isSelected ? Colors.black : Colors.white70,
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
        final isSelected = _channels.indexOf(channel) == _selectedChannelIndex;

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
                      ? const Color(0x3300E5FF)
                      : isSelected
                          ? const Color(0xFF1E293B).withOpacity(0.9)
                          : const Color(0xFF0F172A).withOpacity(0.4),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isFocused
                        ? const Color(0xFF00E5FF)
                        : isSelected
                            ? const Color(0x8800E5FF)
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
                      color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    'Grupo: ${channel.groupCategory} • ${channel.resolution}',
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.volume_up, color: Color(0xFF00E5FF), size: 18)
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
      backgroundColor: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF1E293B),
      child: Text(
        '${channel.number}',
        style: TextStyle(
          color: isSelected ? Colors.black : Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildImmersivePlayer(ChannelModel? activeChannel) {
    return GestureDetector(
      onTap: _toggleOsd,
      onVerticalDragEnd: (details) {
        if (details.primaryVelocity! < -150) _nextChannel();
        if (details.primaryVelocity! > 150) _previousChannel();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Center(
              child: _videoPlayerController != null && _videoPlayerController!.value.isInitialized
                  ? AspectRatio(aspectRatio: _videoPlayerController!.value.aspectRatio, child: VideoPlayer(_videoPlayerController!))
                  : const CircularProgressIndicator(color: Color(0xFF00E5FF)),
            ),
            if (_showOsd)
              Positioned(
                bottom: 24,
                left: 24,
                right: 24,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      color: Colors.black.withOpacity(0.75),
                      child: Row(
                        children: [
                          _buildChannelLogo(activeChannel ?? _channels.first, true),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  activeChannel?.name ?? '',
                                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                Text(
                                  '${activeChannel?.groupCategory} • EN VIVO HLS',
                                  style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.fullscreen_exit, color: Colors.white, size: 26),
                            onPressed: () => setState(() => _isFullScreenMode = false),
                          ),
                        ],
                      ),
                    ),
                  ),
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
      leading: Icon(icon, color: const Color(0xFF00E5FF), size: 20),
      title: Text(title, style: const TextStyle(color: Colors.white, fontSize: 12)),
      onTap: onTap,
    );
  }

  @override
  void dispose() {
    _videoPlayerController?.dispose();
    _searchController.dispose();
    super.dispose();
  }
}