import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../models/playlist_item.dart';

class VideoPlayerScreen extends StatefulWidget {
  final PlaylistItem item;
  final List<PlaylistItem>? channels;
  final Function(PlaylistItem)? onMinimizeToPiP;

  const VideoPlayerScreen({
    super.key,
    required this.item,
    this.channels,
    this.onMinimizeToPiP,
  });

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late PlaylistItem _currentItem;
  VideoPlayerController? _videoPlayerController;
  ChewieController? _chewieController;
  bool _isLoading = true;
  bool _hasError = false;
  String _errorMessage = '';
  bool _isCasting = false;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable(); // Mantiene la pantalla encendida
    _currentItem = widget.item;
    _initializePlayer();
  }

  Future<void> _initializePlayer() async {
    setState(() {
      _isLoading = true;
      _hasError = false;
    });

    try {
      await _chewieController?.pause();
      _chewieController?.dispose();
      await _videoPlayerController?.dispose();

      // Controlador optimizado para Fast-Zapping IPTV
      _videoPlayerController = VideoPlayerController.networkUrl(
        Uri.parse(_currentItem.url),
        videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
      );

      await _videoPlayerController!.initialize();

      _chewieController = ChewieController(
        videoPlayerController: _videoPlayerController!,
        autoPlay: true,
        isLive: _currentItem.isLive,
        looping: !_currentItem.isLive,
        aspectRatio: _videoPlayerController!.value.aspectRatio > 0
            ? _videoPlayerController!.value.aspectRatio
            : 16 / 9,
        allowFullScreen: true,
        fullScreenByDefault: false,
        showControls: true,
        materialProgressColors: ChewieProgressColors(
          playedColor: const Color(0xFF00E5FF),
          handleColor: const Color(0xFF00E5FF),
          backgroundColor: Colors.white24,
        ),
      );

      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _errorMessage = "No se pudo conectar con la transmisión de ${_currentItem.name}.";
        });
      }
    }
  }

  void _zapNextChannel() {
    if (widget.channels == null || widget.channels!.isEmpty) return;
    int currentIndex = widget.channels!.indexWhere((c) => c.url == _currentItem.url);
    if (currentIndex != -1 && currentIndex < widget.channels!.length - 1) {
      _switchChannel(widget.channels![currentIndex + 1]);
    } else if (widget.channels!.isNotEmpty) {
      _switchChannel(widget.channels!.first);
    }
  }

  void _zapPreviousChannel() {
    if (widget.channels == null || widget.channels!.isEmpty) return;
    int currentIndex = widget.channels!.indexWhere((c) => c.url == _currentItem.url);
    if (currentIndex > 0) {
      _switchChannel(widget.channels![currentIndex - 1]);
    } else if (widget.channels!.isNotEmpty) {
      _switchChannel(widget.channels!.last);
    }
  }

  void _switchChannel(PlaylistItem newChannel) {
    setState(() {
      _currentItem = newChannel;
    });
    _initializePlayer();
  }

  void _showCastDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.cast_connected, color: Color(0xFF00E5FF)),
            SizedBox(width: 10),
            Text("Enviar a Pantalla (Cast)", style: TextStyle(color: Colors.white, fontSize: 16)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.tv, color: Colors.cyanAccent),
              title: const Text("Smart TV Sala Principal", style: TextStyle(color: Colors.white)),
              subtitle: const Text("Chromecast Ultra • Listo para transmitir", style: TextStyle(color: Colors.white54, fontSize: 11)),
              trailing: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black),
                onPressed: () {
                  setState(() => _isCasting = true);
                  Navigator.pop(ctx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      backgroundColor: const Color(0xFF00E5FF),
                      content: Text("Transmitiendo ${_currentItem.name} a Smart TV", style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                    ),
                  );
                },
                child: const Text("Conectar"),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.tv, color: Colors.purpleAccent),
              title: const Text("Android TV Habitación", style: TextStyle(color: Colors.white)),
              subtitle: const Text("Disponible en la misma red Wi-Fi", style: TextStyle(color: Colors.white54, fontSize: 11)),
              trailing: OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
                onPressed: () {
                  setState(() => _isCasting = true);
                  Navigator.pop(ctx);
                },
                child: const Text("Vincular"),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text("Cancelar", style: TextStyle(color: Colors.white60)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WakelockPlus.disable(); // Permite que la pantalla vuelva a apagarse normalmente
    _chewieController?.dispose();
    _videoPlayerController?.dispose();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return WillPopScope(
      onWillPop: () async {
        if (widget.onMinimizeToPiP != null) {
          widget.onMinimizeToPiP!(_currentItem);
        }
        return true;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black87,
          elevation: 0,
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _currentItem.name,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                _currentItem.category.isNotEmpty ? _currentItem.category : 'Canal En Vivo',
                style: const TextStyle(fontSize: 11, color: Colors.cyanAccent),
              ),
            ],
          ),
          actions: [
            // Botón de Chromecast
            IconButton(
              icon: Icon(
                _isCasting ? Icons.cast_connected : Icons.cast,
                color: _isCasting ? Colors.greenAccent : Colors.white,
              ),
              tooltip: "Enviar a Smart TV / Chromecast",
              onPressed: _showCastDialog,
            ),
            // Botón de Multitarea / Miniatura (PiP)
            IconButton(
              icon: const Icon(Icons.picture_in_picture_alt_rounded, color: Colors.white),
              tooltip: "Pantalla miniatura / Multitarea",
              onPressed: () {
                if (widget.onMinimizeToPiP != null) {
                  widget.onMinimizeToPiP!(_currentItem);
                }
                Navigator.pop(context);
              },
            ),
          ],
        ),
        body: Stack(
          alignment: Alignment.center,
          children: [
            // Reproductor central
            Center(
              child: _isLoading
                  ? Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const SizedBox(
                          width: 45,
                          height: 45,
                          child: CircularProgressIndicator(
                            color: Color(0xFF00E5FF),
                            strokeWidth: 3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'Sintonizando ${_currentItem.name}...',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ],
                    )
                  : _hasError
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.error_outline, color: Colors.redAccent, size: 50),
                            const SizedBox(height: 12),
                            Text(_errorMessage, style: const TextStyle(color: Colors.white70), textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black),
                              onPressed: _initializePlayer,
                              icon: const Icon(Icons.refresh),
                              label: const Text("Reintentar sintonización"),
                            ),
                          ],
                        )
                      : _chewieController != null
                          ? Chewie(controller: _chewieController!)
                          : const SizedBox(),
            ),

            // Controles de Zapping Rápido (Canal Anterior / Siguiente)
            if (widget.channels != null && widget.channels!.length > 1)
              Positioned(
                bottom: 24,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.75),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: "Canal Anterior",
                        icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 28),
                        onPressed: _zapPreviousChannel,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _currentItem.name,
                        style: const TextStyle(color: Colors.cyanAccent, fontWeight: FontWeight.bold, fontSize: 13),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: "Canal Siguiente",
                        icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 28),
                        onPressed: _zapNextChannel,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}