import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/player_settings_service.dart';

class ProVideoPlayer extends StatefulWidget {
  final String streamUrl;
  final double volume;
  final bool isPlaying;

  const ProVideoPlayer({
    super.key,
    required this.streamUrl,
    this.volume = 1.0,
    this.isPlaying = true,
  });

  @override
  State<ProVideoPlayer> createState() => ProVideoPlayerState();
}

class ProVideoPlayerState extends State<ProVideoPlayer> {
  late Player player;
  late VideoController controller;

  @override
  void initState() {
    super.initState();
    _initNewPlayer(widget.streamUrl);
  }

  void _initNewPlayer(String url) {
    // Instancia limpia con búfer optimizado para arranque inmediato sin eco
    player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 2 * 1024 * 1024, // Búfer compacto de 2MB para evitar retardo
        vo: 'gpu',
      ),
    );
    controller = VideoController(player);

    player.open(Media(url), play: widget.isPlaying);
    player.setVolume(widget.volume * 100);

    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
    
    PlayerSettingsService.bufferSizeNotifier.addListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.addListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.addListener(_onAudioTrackChanged);
    
    player.stream.tracks.listen((tracks) {
      _onAudioTrackChanged();
    });
  }

  void _onBufferChanged() {}

  void _onEqChanged() {
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
  }

  void _applyEqualizer(String mode) {
    // Perfiles de audio limpios
  }

  void _onAudioTrackChanged() {
    final desiredTrack = PlayerSettingsService.audioTrackNotifier.value;
    final tracks = player.state.tracks.audio;
    if (tracks.isEmpty) return;

    if (desiredTrack == 'Sin Audio') {
      player.setAudioTrack(AudioTrack.no());
      return;
    }
    
    bool trackFound = false;
    for (var track in tracks) {
      final lang = (track.language ?? '').toLowerCase();
      final title = (track.title ?? '').toLowerCase();
      
      if (desiredTrack.contains('Inglés') && (lang.contains('en') || title.contains('english'))) {
        player.setAudioTrack(track);
        trackFound = true;
        break;
      } else if (desiredTrack.contains('Español') && (lang.contains('es') || title.contains('spanish'))) {
        player.setAudioTrack(track);
        trackFound = true;
        break;
      }
    }

    if (!trackFound && tracks.isNotEmpty) {
      player.setAudioTrack(tracks.first);
    }
  }

  void play() => player.play();
  void pause() => player.pause();
  void seekRelative(int seconds) {
    final target = player.state.position + Duration(seconds: seconds);
    player.seek(target);
  }

  @override
  void didUpdateWidget(ProVideoPlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streamUrl != widget.streamUrl) {
      // DESTRUCCIÓN Y RECONSTRUCCIÓN TOTAL: Mata cualquier residuo de audio anterior al instante
      PlayerSettingsService.bufferSizeNotifier.removeListener(_onBufferChanged);
      PlayerSettingsService.eqModeNotifier.removeListener(_onEqChanged);
      PlayerSettingsService.audioTrackNotifier.removeListener(_onAudioTrackChanged);
      
      final oldPlayer = player;
      _initNewPlayer(widget.streamUrl);
      setState(() {});

      Future.microtask(() async {
        try {
          await oldPlayer.stop();
          await oldPlayer.dispose();
        } catch (_) {}
      });
    } else {
      if (oldWidget.volume != widget.volume) {
        player.setVolume(widget.volume * 100);
      }
      if (oldWidget.isPlaying != widget.isPlaying) {
        widget.isPlaying ? player.play() : player.pause();
      }
    }
  }

  @override
  void dispose() {
    PlayerSettingsService.bufferSizeNotifier.removeListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.removeListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.removeListener(_onAudioTrackChanged);
    player.stop();
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Video(
      controller: controller,
      controls: NoVideoControls,
      fill: Colors.black,
    );
  }
}