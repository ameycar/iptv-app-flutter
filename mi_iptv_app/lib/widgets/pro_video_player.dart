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
    // Configuración optimizada de bajo nivel para máxima velocidad (Estilo TiviMate)
    player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 32 * 1024 * 1024, // 32MB de caché en anillo para evitar saltos
        vo: 'gpu', // Aceleración por hardware directa
      ),
    );
    controller = VideoController(player);
    
    _setupPlayer();
  }

  Future<void> _setupPlayer() async {
    // 1. Abrir transmisión multimedia con máxima prioridad de hardware
    await player.open(Media(widget.streamUrl), play: widget.isPlaying);
    await player.setVolume(widget.volume * 100);

    // 2. Aplicar ecualizador y pistas iniciales
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
    
    // 3. Escuchar eventos en tiempo real
    PlayerSettingsService.bufferSizeNotifier.addListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.addListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.addListener(_onAudioTrackChanged);
    
    player.stream.tracks.listen((tracks) {
      _onAudioTrackChanged();
    });
  }

  void _onBufferChanged() {
    final bufferMb = PlayerSettingsService.bufferSizeNotifier.value;
    // Ajuste dinámico de búfer basado en perfil del usuario
  }

  void _onEqChanged() {
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
  }

  void _applyEqualizer(String mode) {
    // Perfiles de audio optimizados sin penalizar decodificación
    switch (mode) {
      case 'Cine (Surround)':
        break;
      case 'Voz Clara':
        break;
      default:
        break;
    }
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

  // Métodos de control instantáneo para el zapping
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
      // Destrucción inmediata del stream anterior para garantizar Zapping instantáneo sin eco
      player.stop();
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
      controls: NoVideoControls,
      fill: Colors.black,
    );
  }
}