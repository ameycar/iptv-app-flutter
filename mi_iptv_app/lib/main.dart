import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'models/channel_model.dart';
import 'services/m3u_sanitizer_service.dart';

void main() {
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
        scaffoldBackgroundColor: const Color(0xFF0F141C),
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

  final String _defaultM3uList = '''
#EXTM3U
#EXTINF:-1 tvg-logo="" group-title="Deportes",1. Real Madrid vs Barcelona (HD)
https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4
#EXTINF:-1 tvg-logo="" group-title="Noticias",2. Noticias 24/7 Live
https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4
#EXTINF:-1 tvg-logo="" group-title="Entretenimiento",3. Cine Max Pro
https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4
#EXTINF:-1 tvg-logo="" group-title="Documentales",4. Discovery World
https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4
''';

  @override
  void initState() {
    super.initState();
    _channels = M3USanitizerService.parseAndSanitize(_defaultM3uList);
    if (_channels.isNotEmpty) {
      _initializeVideo(_channels[0].streamUrl);
    }
  }

  void _initializeVideo(String url) async {
    setState(() {
      _isVideoLoading = true;
    });

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
      setState(() {
        _isVideoLoading = false;
      });
    }
  }

  void _nextChannel() {
    if (_channels.isEmpty) return;
    setState(() {
      _selectedChannelIndex = (_selectedChannelIndex + 1) % _channels.length;
    });
    _initializeVideo(_channels[_selectedChannelIndex].streamUrl);
  }

  void _previousChannel() {
    if (_channels.isEmpty) return;
    setState(() {
      _selectedChannelIndex = (_selectedChannelIndex - 1 < 0) ? _channels.length - 1 : _selectedChannelIndex - 1;
    });
    _initializeVideo(_channels[_selectedChannelIndex].streamUrl);
  }

  void _startVoiceSearch() {
    setState(() => _isListeningVoice = true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('🎙️ Escuchando... "Pon el partido de fútbol en HD"'),
        duration: Duration(seconds: 3),
        backgroundColor: Colors.blueAccent,
      ),
    );

    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() {
          _isListeningVoice = false;
          _selectedChannelIndex = 0; 
        });
        _initializeVideo(_channels[0].streamUrl);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('⚽ IA: Sintonizando Real Madrid vs Barcelona (HD)'),
            backgroundColor: Colors.green,
          ),
        );
      }
    });
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
        },
        child: Focus(
          autofocus: true,
          child: OrientationBuilder(
            builder: (context, orientation) {
              return orientation == Orientation.portrait ? _buildPortraitLayout() : _buildLandscapeLayout();
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPortraitLayout() {
    final activeChannel = _channels.isNotEmpty ? _channels[_selectedChannelIndex] : null;

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('AMEYCAR TV', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold, fontSize: 18)),
                IconButton(
                  icon: Icon(_isListeningVoice ? Icons.mic : Icons.mic_none, color: _isListeningVoice ? Colors.redAccent : Colors.white),
                  onPressed: _startVoiceSearch,
                ),
              ],
            ),
          ),
          GestureDetector(
            onVerticalDragEnd: (details) {
              if (details.primaryVelocity! < 0) _nextChannel();
              else if (details.primaryVelocity! > 0) _previousChannel();
            },
            child: Container(
              height: 210,
              width: double.infinity,
              color: Colors.black,
              child: Stack(
                children: [
                  _isVideoLoading
                      ? const Center(child: CircularProgressIndicator(color: Colors.blueAccent))
                      : (_videoPlayerController != null && _videoPlayerController!.value.isInitialized)
                          ? Center(child: AspectRatio(aspectRatio: _videoPlayerController!.value.aspectRatio, child: VideoPlayer(_videoPlayerController!)))
                          : const Center(child: Icon(Icons.tv_off, color: Colors.white38, size: 48)),
                  Positioned(
                    bottom: 8,
                    left: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(6)),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Text(activeChannel?.name ?? '', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.alarm_add, color: Colors.amberAccent, size: 18),
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('⏰ Alarma de inicio programada')));
                            },
                          )
                        ],
                      ),
                    ),
                  )
                ],
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF131A24),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.live_tv, color: Colors.redAccent, size: 14),
                    SizedBox(width: 6),
                    Text('EN VIVO: Gran Clásico de Liga (15:00 - 17:00)', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ],
                ),
                SizedBox(height: 4),
                Text('Anterior: Resumen Previa | Siguiente: Noticiero Deportivo', style: TextStyle(color: Colors.white54, fontSize: 10)),
              ],
            ),
          ),
          Container(
            height: 44,
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _categories.length,
              itemBuilder: (context, index) {
                final category = _categories[index];
                final isSelected = category == _selectedCategory;
                return GestureDetector(
                  onTap: () => setState(() => _selectedCategory = category),
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(color: isSelected ? Colors.blueAccent : const Color(0xFF1C2738), borderRadius: BorderRadius.circular(16)),
                    child: Center(child: Text(category, style: TextStyle(color: isSelected ? Colors.white : Colors.white70, fontSize: 11))),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: _filteredChannels.length,
              itemBuilder: (context, index) {
                final channel = _filteredChannels[index];
                final isSelected = _channels.indexOf(channel) == _selectedChannelIndex;
                return ListTile(
                  tileColor: isSelected ? const Color(0xFF1C2738) : Colors.transparent,
                  leading: CircleAvatar(
                    backgroundColor: isSelected ? Colors.blueAccent : const Color(0xFF161C26),
                    child: Text('${_channels.indexOf(channel) + 1}', style: const TextStyle(color: Colors.white, fontSize: 11)),
                  ),
                  title: Text(channel.name, style: TextStyle(color: isSelected ? Colors.lightBlueAccent : Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                  subtitle: Text('Grupo: ${channel.groupCategory}', style: const TextStyle(color: Colors.white38, fontSize: 10)),
                  onTap: () {
                    setState(() => _selectedChannelIndex = _channels.indexOf(channel));
                    _initializeVideo(channel.streamUrl);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeLayout() {
    return Row(
      children: [
        Container(
          width: 150,
          color: const Color(0xFF161C26),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 14, top: 18, bottom: 12),
                child: Text('AMEYCAR TV', style: TextStyle(color: Colors.lightBlueAccent, fontWeight: FontWeight.bold, fontSize: 14)),
              ),
              ListTile(
                leading: const Icon(Icons.mic, color: Colors.blueAccent, size: 18),
                title: const Text('Asistente IA', style: TextStyle(color: Colors.white, fontSize: 11)),
                onTap: _startVoiceSearch,
              ),
            ],
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                flex: 3,
                child: Container(
                  margin: const EdgeInsets.all(6),
                  decoration: BoxDecoration(color: Colors.black, borderRadius: BorderRadius.circular(8)),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: _videoPlayerController != null && _videoPlayerController!.value.isInitialized
                        ? AspectRatio(aspectRatio: _videoPlayerController!.value.aspectRatio, child: VideoPlayer(_videoPlayerController!))
                        : const Center(child: Icon(Icons.tv_off, color: Colors.white38, size: 40)),
                  ),
                ),
              ),
              Expanded(
                flex: 2,
                child: ListView.builder(
                  itemCount: _channels.length,
                  itemBuilder: (context, index) {
                    final channel = _channels[index];
                    final isSelected = index == _selectedChannelIndex;
                    return ListTile(
                      dense: true,
                      tileColor: isSelected ? const Color(0xFF1C2738) : Colors.transparent,
                      title: Text(channel.name, style: TextStyle(color: isSelected ? Colors.lightBlueAccent : Colors.white, fontSize: 11)),
                      onTap: () {
                        setState(() => _selectedChannelIndex = index);
                        _initializeVideo(channel.streamUrl);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
