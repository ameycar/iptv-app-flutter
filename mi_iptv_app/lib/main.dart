import 'dart:convert';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'models/channel_model.dart';
import 'services/m3u_sanitizer_service.dart';

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
  bool _isListeningVoice = false;
  bool _isFullScreenMode = false;
  bool _showOsd = true;

  // Buscador por texto con Lupita
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  // Asistente de Voz y TTS
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  String _voiceMessage = '';

  @override
  void initState() {
    super.initState();
    _initTts();
    _loadSavedChannels();
  }

  void _initTts() async {
    await _tts.setLanguage('es-ES');
    await _tts.setSpeechRate(0.5);
  }

  void _loadSavedChannels() async {
    final prefs = await SharedPreferences.getInstance();
    final savedM3u = prefs.getString('saved_m3u_content');

    if (savedM3u != null && savedM3u.isNotEmpty) {
      _channels = M3USanitizerService.parseAndSanitize(savedM3u);
    } else {
      _channels = M3USanitizerService.getCuratedChannels();
    }

    if (_channels.isNotEmpty) {
      _initializeVideo(_channels[0].streamUrl);
    }
    setState(() {});
  }

  void _initializeVideo(String url) async {
    setState(() => _isVideoLoading = true);
    _videoPlayerController?.dispose();
    _videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(url));

    try {
      await _videoPlayerController!.initialize();
      _videoPlayerController!.play();
      _videoPlayerController!.setLooping(true);
    } catch (e) {
      debugPrint('Error reproduciendo video: $e');
    }

    if (mounted) {
      setState(() => _isVideoLoading = false);
    }
  }

  void _nextChannel() {
    final currentList = _filteredChannels;
    if (currentList.isEmpty) return;
    final currentCh = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;
    int curIdxInFiltered = currentList.indexOf(currentCh!);
    int nextIdx = (curIdxInFiltered + 1) % currentList.length;
    _changeChannel(currentList[nextIdx]);
  }

  void _previousChannel() {
    final currentList = _filteredChannels;
    if (currentList.isEmpty) return;
    final currentCh = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;
    int curIdxInFiltered = currentList.indexOf(currentCh!);
    int prevIdx = (curIdxInFiltered - 1 < 0) ? currentList.length - 1 : curIdxInFiltered - 1;
    _changeChannel(currentList[prevIdx]);
  }

  void _changeChannel(ChannelModel ch) {
    final realIndex = _channels.indexOf(ch);
    if (realIndex != -1) {
      setState(() => _selectedChannelIndex = realIndex);
      _initializeVideo(ch.streamUrl);
      _triggerOsdTimer();
    }
  }

  void _triggerOsdTimer() {
    setState(() => _showOsd = true);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _isFullScreenMode) {
        setState(() => _showOsd = false);
      }
    });
  }

  // Asistente de Voz Dinámico (Busca de verdad en tu lista M3U)
  void _startVoiceSearch() async {
    bool available = await _speech.initialize(
      onError: (_) => setState(() => _isListeningVoice = false),
    );

    if (available) {
      setState(() {
        _isListeningVoice = true;
        _voiceMessage = 'Escuchando... Di el nombre, número o grupo del canal';
      });

      _speech.listen(
        localeId: 'es_ES',
        onResult: (val) {
          if (val.finalResult) {
            _processDynamicVoiceCommand(val.recognizedWords);
          }
        },
      );
    } else {
      _showVoiceTextPrompt();
    }
  }

  void _showVoiceTextPrompt() {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0F172A),
        title: const Row(
          children: [
            Icon(Icons.mic, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('Comando por Voz o Texto', style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'Ej: ESPN, canal 58, noticias, clan...',
            hintStyle: TextStyle(color: Colors.white30),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            onPressed: () {
              Navigator.pop(ctx);
              _processDynamicVoiceCommand(textController.text.trim());
            },
            child: const Text('Ejecutar', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _processDynamicVoiceCommand(String query) {
    if (query.trim().isEmpty) return;
    final lower = query.toLowerCase().trim();
    ChannelModel? matchedChannel;

    // 1. Buscar por número exacto: "canal 58", "58"
    final numberMatch = RegExp(r'\d+').firstMatch(lower);
    if (numberMatch != null) {
      final num = int.tryParse(numberMatch.group(0)!);
      if (num != null) {
        matchedChannel = _channels.firstWhere(
          (c) => c.number == num || c.name.contains('$num'),
          orElse: () => _channels.first,
        );
      }
    }

    // 2. Buscar por coincidencia de nombre: "espn", "clan", "axn", "real madrid"
    if (matchedChannel == null) {
      for (final ch in _channels) {
        final chLower = ch.name.toLowerCase();
        final words = lower.split(' ').where((w) => w.length > 2);
        for (final word in words) {
          if (chLower.contains(word)) {
            matchedChannel = ch;
            break;
          }
        }
        if (matchedChannel != null) break;
      }
    }

    // 3. Buscar por categoría: "deportes", "noticias", "infantil"
    if (matchedChannel == null) {
      matchedChannel = _channels.firstWhere(
        (c) => c.groupCategory.toLowerCase().contains(lower),
        orElse: () => _channels.first,
      );
    }

    String responseText = '';
    if (matchedChannel != null) {
      _changeChannel(matchedChannel);
      responseText = 'Sintonizando: ${matchedChannel.name}';
    } else {
      responseText = 'No encontré un canal para "$query"';
    }

    setState(() {
      _voiceMessage = responseText;
      _isListeningVoice = false;
    });

    _tts.speak(responseText);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('🎙️ Alexa: $responseText'),
        backgroundColor: const Color(0xFF00E5FF),
      ),
    );
  }

  // Gestor de Listas M3U
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

          setState(() {
            _channels = parsed;
            _selectedChannelIndex = 0;
            _searchQuery = '';
            _isSearching = false;
          });
          _initializeVideo(_channels[0].streamUrl);

          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('¡${parsed.length} canales sanitizados con éxito!'),
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

  List<String> get _categories {
    final groups = _channels.map((c) => c.groupCategory).toSet().toList();
    return ['Todos', ...groups];
  }

  List<ChannelModel> get _filteredChannels {
    return _channels.where((c) {
      // Filtro por categoría
      final matchesCategory = _selectedCategory == 'Todos' || c.groupCategory == _selectedCategory;
      // Filtro por texto de búsqueda
      final matchesSearch = _searchQuery.isEmpty ||
          c.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
          c.number.toString().contains(_searchQuery) ||
          c.groupCategory.toLowerCase().contains(_searchQuery.toLowerCase());

      return matchesCategory && matchesSearch;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
    );
  }

  // VISTA VERTICAL (MÓVIL)
  Widget _buildPortraitLayout() {
    final activeChannel = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    if (_isFullScreenMode) {
      return _buildImmersivePlayer(activeChannel);
    }

    return SafeArea(
      child: Column(
        children: [
          // 1. Barra superior translúcida con Lupita y Micrófono
          _buildTopGlassBar(),

          // 2. Video con zapping por gestos
          _buildVideoPlayerSection(activeChannel),

          // 3. Pestañas principales de navegación (En Vivo | Películas | Series)
          _buildSectionTabs(),

          // 4. Banner EPG dinámico DirecTV
          _buildLiveEpgCard(),

          // 5. Selector horizontal de categorías
          _buildCategoryChips(),

          // 6. Lista de Canales con Logos y D-Pad
          Expanded(
            child: _buildChannelListView(),
          ),
        ],
      ),
    );
  }

  // VISTA HORIZONTAL (ANDROID TV / TIVIGLASS)
  Widget _buildLandscapeLayout() {
    final activeChannel = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    if (_isFullScreenMode) {
      return _buildImmersivePlayer(activeChannel);
    }

    return Row(
      children: [
        // Panel lateral izquierdo traslúcido
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
              _buildSideMenuItem(Icons.search, 'Buscar Canal', () {
                setState(() => _isSearching = !_isSearching);
              }),
              _buildSideMenuItem(Icons.mic, 'Asistente IA', _startVoiceSearch),
              _buildSideMenuItem(Icons.playlist_add, 'Listas M3U', _openM3uDialog),
              _buildSideMenuItem(Icons.fullscreen, 'Pantalla Completa', () {
                setState(() => _isFullScreenMode = true);
              }),
            ],
          ),
        ),

        // Video principal (Flex 3)
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

        // Lista de canales a la derecha (Flex 2)
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
                      child: const Text('LIVE', style: TextStyle(color: Colors.red, fontSize: 9, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                Row(
                  children: [
                    // Lupita de búsqueda
                    IconButton(
                      icon: const Icon(Icons.search, color: Color(0xFF00E5FF), size: 22),
                      onPressed: () => setState(() => _isSearching = true),
                    ),
                    IconButton(
                      icon: const Icon(Icons.playlist_add, color: Colors.white70, size: 22),
                      onPressed: _openM3uDialog,
                    ),
                    IconButton(
                      icon: Icon(
                        _isListeningVoice ? Icons.mic : Icons.mic_none,
                        color: _isListeningVoice ? Colors.redAccent : const Color(0xFF00E5FF),
                        size: 24,
                      ),
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
              hintText: 'Buscar por canal o número...',
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

            // OSD inferior del reproductor
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
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('⏰ Recordatorio de evento programado')),
                                );
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

  Widget _buildLiveEpgCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0F172A).withOpacity(0.9),
        border: const Border(bottom: BorderSide(color: Color(0x1F00E5FF))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.live_tv, color: Colors.redAccent, size: 14),
              SizedBox(width: 6),
              Text(
                'EN VIVO: Programación en Tiempo Real',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 3),
          const Text(
            'Señal Oficial HLS • Calidad Automática Adaptativa',
            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: const LinearProgressIndicator(
              value: 0.65,
              backgroundColor: Color(0xFF1E293B),
              valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
              minHeight: 3,
            ),
          ),
        ],
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

  // Lista de canales con carga de logos reales y fallback
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

  // Widget para renderizar el logo real del canal o fallback numérico
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

  // Reproductor Inmersivo Pantalla Completa
  Widget _buildImmersivePlayer(ChannelModel? activeChannel) {
    return GestureDetector(
      onTap: () => setState(() => _showOsd = !_showOsd),
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

            // OSD Flotante con efecto traslúcido
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
    _speech.stop();
    _tts.stop();
    _searchController.dispose();
    super.dispose();
  }
}