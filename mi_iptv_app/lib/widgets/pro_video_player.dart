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

    _tracksSub = player.stream.tracks.listen((tracks) {
      final desired = PlayerSettingsService.audioTrackNotifier.value;
      if (desired != 'Español (Predeterminado)' && desired.isNotEmpty) {
        _onAudioTrackChanged();
      }
    });
  }

  Future<void> _configureLowLatencyDecoder() async {
    if (kIsWeb) return; 
    try {
      var platform = player.platform;
      if (platform.runtimeType.toString().contains('NativePlayer')) {
        (platform as dynamic).setProperty('profile', 'low-latency');
        (platform as dynamic).setProperty('hwdec', 'mediacodec-copy');
        (platform as dynamic).setProperty('vd-lavc-threads', '4');
        (platform as dynamic).setProperty('demuxer-lavf-analyzeduration', '0');
        (platform as dynamic).setProperty('demuxer-lavf-probesize', '8192'); 
        (platform as dynamic).setProperty('cache', 'yes');
        (platform as dynamic).setProperty('cache-secs', '300'); 
        (platform as dynamic).setProperty('cache-pause', 'no');
        (platform as dynamic).setProperty('cache-pause-initial', 'no');
        (platform as dynamic).setProperty('stream-buffer-size', '4k'); 
        (platform as dynamic).setProperty('network-timeout', '3');
        (platform as dynamic).setProperty('aid', '1');
        (platform as dynamic).setProperty('sid', 'no');
        (platform as dynamic).setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2,fflags=+nobuffer+fastseek+flush_packets',
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
      var platform = player.platform;
      if (platform.runtimeType.toString().contains('NativePlayer')) {
        final mb = PlayerSettingsService.bufferSizeNotifier.value;
        final bytes = (mb * 1024 * 1024).toInt();
        await (platform as dynamic).setProperty('demuxer-max-bytes', '$bytes');
      }
    } catch (_) {}
  }

  void _onEqChanged() {
    _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
  }

  void _applyEqualizer(String mode) async {
    if (kIsWeb) return;
    try {
      var platform = player.platform;
      if (platform.runtimeType.toString().contains('NativePlayer')) {
        String afValue = '';
        switch (mode) {
          case 'Cine (Surround)':
            afValue = 'extrastereo=m=1.8';
            break;
          case 'Voz Clara':
            afValue = 'speechnorm=e=4:r=0.0001:l=1';
            break;
          case 'Graves Profundos':
            afValue = 'bass=g=6:f=110:w=0.6';
            break;
          case 'Música':
            afValue = 'anequalizer';
            break;
          default:
            afValue = '';
            break;
        }
        await (platform as dynamic).setProperty('af', afValue);
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

  // 🛠️ FIX 1: Obligar al motor a arrancar después del retroceso
  void seekRelative(int seconds) {
    final currentPos = player.state.position;
    final target = currentPos + Duration(seconds: seconds);
    
    player.seek(target < Duration.zero ? Duration.zero : target).then((_) {
      // Fuerza la reproducción inmediata para que no se quede pausado en el pasado
      if (widget.isPlaying) {
        player.play();
      }
    });
  }

  // 🚀 FIX 2: Crear el puente directo para volver al "En Vivo" real
  void jumpToLiveEdge() {
    // La forma más perfecta y sin lag de volver al vivo en IPTV es limpiar el buffer y resintonizar
    _tuneChannelFast(widget.streamUrl);
    if (widget.isPlaying) {
      player.play();
    }
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
