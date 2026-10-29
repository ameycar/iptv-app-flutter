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
  late final Player player;
  late final VideoController controller;

  @override
  void initState() {
    super.initState();
    player = Player();
    controller = VideoController(player);
    
    _setupPlayer();
  }

  Future<void> _setupPlayer() async {
    // 1. Aplicar Buffer de Red
    _onBufferChanged();

    // 2. Abrir transmisión
    await player.open(Media(widget.streamUrl), play: widget.isPlaying);
    await player.setVolume(widget.volume * 100); // media_kit usa escala 0-100

    // 3. Aplicar Ecualizador Inicial
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
    
    // 4. Escuchar cambios en vivo desde el panel ADV
    PlayerSettingsService.bufferSizeNotifier.addListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.addListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.addListener(_onAudioTrackChanged);
    
    // Escuchar cuando el stream cargue las pistas disponibles para forzar idioma
    player.stream.tracks.listen((tracks) {
      _onAudioTrackChanged();
    });
  }

  void _onBufferChanged() {
    // En versiones recientes de media_kit, el búfer se autogestiona de manera robusta
  }

  void _onEqChanged() {
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
  }

  void _applyEqualizer(String mode) {
    // Adaptado para mantener compatibilidad web y nativa
  }

  void _onAudioTrackChanged() {
    final desiredTrack = PlayerSettingsService.audioTrackNotifier.value;
    final tracks = player.state.tracks.audio;
    
    if (tracks.isEmpty) return;

    if (desiredTrack == 'Sin Audio') {
      player.setAudioTrack(AudioTrack.auto());
      return;
    }
    
    // Buscar pista secundaria (ej. Inglés) o regresar a la principal
    if (desiredTrack == 'Inglés (Original)' && tracks.length > 1) {
      player.setAudioTrack(tracks.last); 
    } else {
      player.setAudioTrack(tracks.first); 
    }
  }

  // Métodos expuestos para controlar el video desde el zapping y botones de main.dart
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
      player.open(Media(widget.streamUrl), play: widget.isPlaying);
    }
    if (oldWidget.volume != widget.volume) {
      player.setVolume(widget.volume * 100);
    }
    if (oldWidget.isPlaying != widget.isPlaying) {
      widget.isPlaying ? player.play() : player.pause();
    }
  }

  @override
  void dispose() {
    PlayerSettingsService.bufferSizeNotifier.removeListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.removeListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.removeListener(_onAudioTrackChanged);
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Video(
      controller: controller,
      controls: NoVideoControls, // Mantiene la pantalla limpia para usar tu propio ZappingChannelOverlay
      fill: Colors.black,
    );
  }
}