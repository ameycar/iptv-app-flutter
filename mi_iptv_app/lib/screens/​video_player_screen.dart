import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import '../models/playlist_item.dart';

class VideoPlayerScreen extends StatefulWidget {
  final PlaylistItem item;

  const VideoPlayerScreen({super.key, required this.item});

  @override
  State<VideoPlayerScreen> createState() => _VideoPlayerScreenState();
}

class _VideoPlayerScreenState extends State<VideoPlayerScreen> {
  late VideoPlayerController _videoPlayerController;
  ChewieController? _chewieController;

  @override
  void initState() {
    super.initState();
    _initializePlayer();
  }

  void _initializePlayer() async {
    _videoPlayerController = VideoPlayerController.networkUrl(Uri.parse(widget.item.url));
    await _videoPlayerController.initialize();

    _chewieController = ChewieController(
      videoPlayerController: _videoPlayerController,
      autoPlay: true,
      looping: widget.item.isLive ? false : true,
      isLive: widget.item.isLive,
      aspectRatio: _videoPlayerController.value.aspectRatio,
      allowFullScreen: true,
      colors: ChewieProgressColors(
        playedColor: Colors.deepPurpleAccent,
        handleColor: Colors.deepPurpleAccent,
        backgroundColor: Colors.grey,
      ),
    );

    setState(() {});
  }

  @override
  void dispose() {
    _videoPlayerController.dispose();
    _chewieController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(widget.item.name),
        backgroundColor: Colors.transparent,
      ),
      body: Center(
        child: _chewieController != null && _chewieController!.videoPlayerController.value.isInitialized
            ? Chewie(controller: _chewieController!)
            : const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(color: Colors.deepPurpleAccent),
                  SizedBox(height: 16),
                  Text('Conectando a la transmisión...', style: TextStyle(color: Colors.white54)),
                ],
              ),
      ),
    );
  }
}
