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
  VideoPlayerController? _videoPlayerController;
  bool _isVideoLoading = false;
  bool _isListeningVoice = false;
  bool _isFullScreenMode = false;
  bool _showOsd = true;

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
    if (_channels.isEmpty) return;
    setState(() {
      _selectedChannelIndex = (_selectedChannelIndex + 1) % _channels.length;
    });
    _initializeVideo(_channels[_selectedChannelIndex].streamUrl);
    _triggerOsdTimer();
  }

  void _previousChannel() {
    if (_channels.isEmpty) return;
    setState(() {
      _selectedChannelIndex = (_selectedChannelIndex - 1 < 0) ? _channels.length - 1 : _selectedChannelIndex - 1;
    });
    _initializeVideo(_channels[_selectedChannelIndex].streamUrl);
    _triggerOsdTimer();
  }

  void _triggerOsdTimer() {
    setState(() => _showOsd = true);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _isFullScreenMode) {
        setState(() => _showOsd = false);
      }
    });
  }

  // Asistente por Voz inteligente estilo Alexa
  void _startVoiceSearch() async {
    bool available = await _speech.initialize(
      onError: (_) => setState(() => _isListeningVoice = false),
    );

    if (available) {
      setState(() {
        _isListeningVoice = true;
        _voiceMessage = 'Escuchando tu comando...';
      });

      _speech.listen(
        localeId: 'es_ES',
        onResult: (val) {
          if (val.finalResult) {
            _processVoiceCommand(val.recognizedWords);
          }
        },
      );
    } else {
      _fallbackVoiceSimulation();
    }
  }

  void _fallbackVoiceSimulation() {
    setState(() {
      _isListeningVoice = true;
      _voiceMessage = 'Escuchando... Di un comando';
    });

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _processVoiceCommand('pon deportes');
      }
    });
  }

  void _processVoiceCommand(String query) {
    final lower = query.toLowerCase();
    String responseText = '';

    if (lower.contains('deporte') || lower.contains('fútbol')) {
      final index = _channels.indexWhere((c) => c.groupCategory == 'Deportes');
      if (index != -1) {
        setState(() => _selectedChannelIndex = index);
        _initializeVideo(_channels[index].streamUrl);
        responseText = 'Sintonizando deportes: ${_channels[index].name}';
      }
    } else if (lower.contains('noticia')) {
      final index = _channels.indexWhere((c) => c.groupCategory == 'Noticias');
      if (index != -1) {
        setState(() => _selectedChannelIndex = index);
        _initializeVideo(_channels[index].streamUrl);
        responseText = 'Sintonizando noticias en vivo';
      }
    } else {
      responseText = 'Comando: "$query". Sintonizando canal recomendado.';
      _nextChannel();
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

  // Diálogo para importar lista M3U (Fase 5)
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
    if (_selectedCategory == 'Todos') return _channels;
    return _channels.where((c) => c.groupCategory == _selectedCategory).toList();
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
          // 1. Barra superior translúcida con Glassmorphism
          _buildTopGlassBar(),

          // 2. Video con zapping por gestos
          _buildVideoPlayerSection(activeChannel),

          // 3. Banner EPG dinámico DirecTV
          _buildLiveEpgCard(),

          // 4. Selector horizontal de categorías
          _buildCategoryChips(),

          // 5. Lista de Canales con foco D-Pad
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
            child: _buildChannelListView(),
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
      child: Row(
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
                'EN VIVO: Gran Clásico de Liga (15:00 - 17:00)',
                style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 3),
          const Text(
            'Anterior: Resumen Previa | Siguiente: Noticiero Deportivo',
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

  Widget _buildChannelListView() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      itemCount: _filteredChannels.length,
      itemBuilder: (context, index) {
        final channel = _filteredChannels[index];
        final isSelected = _channels.indexOf(channel) == _selectedChannelIndex;

        return Focus(
          onKey: (node, event) {
            if (event is RawKeyDownEvent && event.logicalKey == LogicalKeyboardKey.select) {
              setState(() => _selectedChannelIndex = _channels.indexOf(channel));
              _initializeVideo(channel.streamUrl);
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
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF1E293B),
                    child: Text(
                      '${channel.number}',
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(
                    channel.name,
                    style: TextStyle(
                      color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: Text(
                    'Grupo: ${channel.groupCategory}',
                    style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 10),
                  ),
                  trailing: isSelected
                      ? const Icon(Icons.volume_up, color: Color(0xFF00E5FF), size: 18)
                      : null,
                  onTap: () {
                    setState(() => _selectedChannelIndex = _channels.indexOf(channel));
                    _initializeVideo(channel.streamUrl);
                  },
                ),
              );
            },
          ),
        );
      },
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
                          CircleAvatar(
                            backgroundColor: const Color(0xFF00E5FF),
                            child: Text(
                              activeChannel != null ? '${activeChannel.number}' : '1',
                              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
                            ),
                          ),
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
    super.dispose();
  }
}