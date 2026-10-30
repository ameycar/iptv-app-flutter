import 'dart:async';
import 'package:flutter/foundation.dart';
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
  StreamSubscription? _tracksSub;
  int _switchToken = 0;

  @override
  void initState() {
    super.initState();
    
    // 1. Motor persistente con búfer dinámico
    final initialBufferMb = PlayerSettingsService.bufferSizeNotifier.value;
    player = Player(
      configuration: PlayerConfiguration(
        bufferSize: (initialBufferMb * 1024 * 1024).toInt(),
        vo: 'gpu',
      ),
    );

    controller = VideoController(
      player,
      configuration: const VideoControllerConfiguration(
        enableHardwareAcceleration: true,
      ),
    );

    _configureLowLatencyDecoder().then((_) {
      _tuneChannelFast(widget.streamUrl);
    });

    PlayerSettingsService.bufferSizeNotifier.addListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.addListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.addListener(_onAudioTrackChanged);

    // Escucha pasiva: solo actúa si el usuario eligió un idioma específico en el menú
    _tracksSub = player.stream.tracks.listen((tracks) {
      final desired = PlayerSettingsService.audioTrackNotifier.value;
      if (desired != 'Español (Predeterminado)' && desired.isNotEmpty) {
        _onAudioTrackChanged();
      }
    });
  }

  /// Configuración de bajo nivel estilo Decodificador / TiviMate
  Future<void> _configureLowLatencyDecoder() async {
    if (kIsWeb) return; // Protege la compilación Web de Netlify
    try {
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;

        // Decodificación por hardware pura (MediaCodec en Android / D3D11 en Windows)
        await native.setProperty('hwdec', 'auto-safe');
        
        // CERO espera de análisis: muestra el primer fotograma apenas llega el primer paquete
        await native.setProperty('demuxer-lavf-analyzeduration', '0');
        await native.setProperty('demuxer-lavf-probesize', '32768');
        await native.setProperty('demuxer-lavf-o', 'fflags=+nobuffer+fastseek+flush_packets');
        
        // Arranque instantáneo sin esperar a llenar todo el caché
        await native.setProperty('cache', 'yes');
        await native.setProperty('cache-pause', 'no');
        await native.setProperty('cache-pause-initial', 'no');
        
        // Bloqueo de pistas ADV / secundarias automáticas: fija siempre la pista #1 por defecto
        await native.setProperty('aid', '1');
        await native.setProperty('sid', 'no');

        // Reconexión automática ultrarrápida ante micro-cortes de IPTV
        await native.setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2',
        );
      }
    } catch (e) {
      debugPrint('Aviso config bajo nivel: $e');
    }
  }

  Future<void> _tuneChannelFast(String rawUrl) async {
    final url = rawUrl.trim();
    if (url.isEmpty) return;
    final token = ++_switchToken;

    try {
      await player.setVolume(widget.volume * 100);
      if (token != _switchToken || !mounted) return;

      // En libmpv, llamar a open() sobre el mismo Player corta el stream viejo en 0ms
      // y reutiliza el decodificador de hardware sin destruir la vista
      await player.open(
        Media(
          url,
          httpHeaders: const {
            'User-Agent': 'TiviMate/4.7.0 (Linux; Android 13) ExoPlayerLib/2.19.1',
            'Connection': 'keep-alive',
          },
        ),
        play: widget.isPlaying,
      );

      _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
    } catch (e) {
      debugPrint('Error sintonizando canal: $e');
    }
  }

  void _onBufferChanged() async {
    if (kIsWeb) return;
    try {
      if (player.platform is NativePlayer) {
        final mb = PlayerSettingsService.bufferSizeNotifier.value;
        final bytes = (mb * 1024 * 1024).toInt();
        await (player.platform as NativePlayer).setProperty('demuxer-max-bytes', '$bytes');
      }
    } catch (_) {}
  }

  void _onEqChanged() {
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
  }

  void _applyEqualizer(String mode) async {
    if (kIsWeb) return;
    try {
      if (player.platform is NativePlayer) {
        final native = player.platform as NativePlayer;
        switch (mode) {
          case 'Cine (Surround)':
            await native.setProperty('af', 'extrastereo=m=1.8');
            break;
          case 'Voz Clara':
            await native.setProperty('af', 'speechnorm=e=4:r=0.0001:l=1');
            break;
          case 'Graves Profundos':
            await native.setProperty('af', 'bass=g=6:f=110:w=0.6');
            break;
          case 'Música':
            await native.setProperty('af', 'anequalizer');
            break;
          default: // Plano
            await native.setProperty('af', '');
            break;
        }
      }
    } catch (_) {}
  }

  void _onAudioTrackChanged() {
    final desiredTrack = PlayerSettingsService.audioTrackNotifier.value;
    final tracks = player.state.tracks.audio;
    if (tracks.isEmpty) return;

    if (desiredTrack == 'Sin Audio') {
      player.setAudioTrack(AudioTrack.no());
      return;
    }

    for (var track in tracks) {
      final lang = (track.language ?? '').toLowerCase();
      final title = (track.title ?? '').toLowerCase();

      // Ignorar pistas de descripción visual (ADV) a menos que no haya otra
      if (title.contains('adv') || title.contains('descript')) continue;

      if (desiredTrack.contains('Inglés') &&
          (lang.contains('en') || title.contains('english') || title.contains('ingl'))) {
        player.setAudioTrack(track);
        return;
      } else if (desiredTrack.contains('Español') &&
          (lang.contains('es') || title.contains('span') || title.contains('espa') || title.contains('lat'))) {
        player.setAudioTrack(track);
        return;
      }
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
    if (oldWidget.streamUrl.trim() != widget.streamUrl.trim()) {
      _tuneChannelFast(widget.streamUrl);
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
    _tracksSub?.cancel();
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