import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/player_settings_service.dart';
import '../services/offline_whisper_subtitle_service.dart';

class ProVideoPlayer extends StatefulWidget {
  final String streamUrl;
  final double volume;
  final bool isPlaying;
  final String colorBlindMode; // Nuevo parámetro para daltonismo ('Normal', 'Protanopía', 'Deuteranopía', 'Tritanopía')

  const ProVideoPlayer({
    super.key,
    required this.streamUrl,
    this.volume = 1.0,
    this.isPlaying = true,
    this.colorBlindMode = 'Normal',
  });

  @override
  State<ProVideoPlayer> createState() => ProVideoPlayerState();
}

class ProVideoPlayerState extends State<ProVideoPlayer> {
  late final Player player;
  late final VideoController controller;
  StreamSubscription? _tracksSub;
  StreamSubscription? _subtitleTextSub;
  int _switchToken = 0;

  String _liveTranslatedCaption = '';
  bool _hasNativeTargetSubtitle = false;
  bool _hasEmbeddedSubtitleStream = false;
  final Map<String, String> _translationCache = {};

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
    PlayerSettingsService.subtitleTrackNotifier.addListener(_onSubtitleSettingChanged);

    _tracksSub = player.stream.tracks.listen((tracks) {
      final desired = PlayerSettingsService.audioTrackNotifier.value;
      if (desired != 'Español (Predeterminado)' && desired.isNotEmpty) {
        _onAudioTrackChanged();
      }

      // Sincronizar subtítulos y traducción en vivo según lo elegido en el botón CC
      _onSubtitleSettingChanged();
    });

    // Escucha el texto de subtítulos embebidos (CEA-608/WebVTT/SRT) y los traduce en tiempo real al idioma elegido
    _subtitleTextSub = player.stream.subtitle.listen((lines) {
      final chosenLang = PlayerSettingsService.subtitleTrackNotifier.value;
      if (chosenLang == 'Desactivado' || chosenLang.isEmpty) {
        if (_liveTranslatedCaption.isNotEmpty && mounted) {
          setState(() => _liveTranslatedCaption = '');
        }
        return;
      }

      final rawText = lines.where((l) => l.trim().isNotEmpty).join(' ').trim();
      if (rawText.isEmpty) {
        return;
      }

      _hasEmbeddedSubtitleStream = true;
      // Si el canal sí trae subtítulos embebidos reales, apagamos Whisper para ahorrar CPU/RAM
      if (OfflineWhisperSubtitleService.isRunning) {
        OfflineWhisperSubtitleService.stop();
      }
      _translateCaptionRealtime(rawText, chosenLang);
    });
  }

  /// Distingue con precisión si el stream es un archivo de Película/Serie VOD o un Canal en Vivo
  bool _isVodFileOrStream(String url) {
    final lower = url.toLowerCase().split('?').first;
    return lower.endsWith('.mp4') ||
        lower.endsWith('.mkv') ||
        lower.endsWith('.avi') ||
        lower.endsWith('.mov') ||
        lower.endsWith('.webm') ||
        lower.contains('/movie/') ||
        lower.contains('/movies/') ||
        lower.contains('/series/') ||
        lower.contains('/vod/') ||
        lower.contains('archive.org/') ||
        lower.contains('googleapis.com/');
  }

  /// Convierte enlaces de nodos directos de Archive.org al balanceador oficial para evitar bloqueo SSL
  String _normalizeArchiveAndSpacesUrl(String rawUrl) {
    var url = rawUrl.trim();
    if (url.contains(' ')) {
      url = url.replaceAll(' ', '%20');
    }
    final archiveNodeRegex = RegExp(
      r'^https?://ia\d+\.us\.archive\.org/\d+/items/(.+)$',
      caseSensitive: false,
    );
    final match = archiveNodeRegex.firstMatch(url);
    if (match != null && match.group(1) != null) {
      return 'https://archive.org/download/${match.group(1)!}';
    }
    if (url.startsWith('http://') && url.contains('archive.org/')) {
      url = url.replaceFirst('http://', 'https://');
    }
    return url;
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
        (platform as dynamic).setProperty('tls-verify', 'no');
        (platform as dynamic).setProperty('aid', '1');
        (platform as dynamic).setProperty('sid', 'auto');
        (platform as dynamic).setProperty('sub-auto', 'all');
        (platform as dynamic).setProperty(
          'stream-lavf-o',
          'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2,fflags=+nobuffer+fastseek+flush_packets',
        );
      }
    } catch (e) {
      debugPrint('Aviso config bajo nivel: $e');
    }
  }

  /// Mantiene 8 KB (8192) para canales en vivo y abre lectura rápida sin pausa bloqueante para Películas/Series VOD
  Future<void> _applyStreamModeProfile(String url) async {
    if (kIsWeb) return;
    try {
      var platform = player.platform;
      if (platform.runtimeType.toString().contains('NativePlayer')) {
        final isVod = _isVodFileOrStream(url);
        if (isVod) {
          await (platform as dynamic).setProperty('demuxer-lavf-analyzeduration', '5000000');
          await (platform as dynamic).setProperty('demuxer-lavf-probesize', '2097152');
          await (platform as dynamic).setProperty('cache-pause', 'no');
          await (platform as dynamic).setProperty('cache-pause-initial', 'no');
          await (platform as dynamic).setProperty('stream-buffer-size', '256k');
          await (platform as dynamic).setProperty('network-timeout', '20');
          await (platform as dynamic).setProperty(
            'stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=5',
          );
        } else {
          // Perfil original intacto de 8 KB (8192) para Canales en Vivo
          await (platform as dynamic).setProperty('profile', 'low-latency');
          await (platform as dynamic).setProperty('demuxer-lavf-analyzeduration', '0');
          await (platform as dynamic).setProperty('demuxer-lavf-probesize', '8192');
          await (platform as dynamic).setProperty('cache-pause', 'no');
          await (platform as dynamic).setProperty('cache-pause-initial', 'no');
          await (platform as dynamic).setProperty('stream-buffer-size', '4k');
          await (platform as dynamic).setProperty('network-timeout', '3');
          await (platform as dynamic).setProperty(
            'stream-lavf-o',
            'reconnect=1,reconnect_streamed=1,reconnect_delay_max=2,fflags=+nobuffer+fastseek+flush_packets',
          );
        }
      }
    } catch (e) {
      debugPrint('Aviso perfil dinámico Live/VOD: $e');
    }
  }

  Future<void> _tuneChannelFast(String rawUrl) async {
    final url = _normalizeArchiveAndSpacesUrl(rawUrl);
    if (url.isEmpty) return;

    final token = ++_switchToken;
    _hasEmbeddedSubtitleStream = false;
    OfflineWhisperSubtitleService.stop();

    try {
      await _applyStreamModeProfile(url);
      await player.setVolume(widget.volume * 100);
      if (token != _switchToken || !mounted) return;

      final isVod = _isVodFileOrStream(url);
      final headers = isVod
          ? const {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
              'Accept': '*/*',
            }
          : const {
              'User-Agent': 'TiviMate/4.7.0 (Linux; Android 13) ExoPlayerLib/2.19.1',
              'Connection': 'keep-alive',
            };

      await player.open(
        Media(
          url,
          httpHeaders: headers,
        ),
        play: widget.isPlaying,
      );

      _applyEqualizer(PlayerSettingsService.eqModeNotifier.value);
      _onSubtitleSettingChanged();
    } catch (e) {
      debugPrint('Error sintonizando canal: $e');
    }
  }

  void _onSubtitleSettingChanged() {
    final desiredSub = PlayerSettingsService.subtitleTrackNotifier.value;
    final subTracks = player.state.tracks.subtitle;

    if (desiredSub == 'Desactivado' || desiredSub.isEmpty) {
      OfflineWhisperSubtitleService.stop();
      player.setSubtitleTrack(SubtitleTrack.no());
      _hasNativeTargetSubtitle = false;
      if (mounted) {
        setState(() => _liveTranslatedCaption = '');
      }
      return;
    }

    final targetCode = _getLanguageCode(desiredSub);
    final keywords = _getLanguageKeywords(desiredSub);
    SubtitleTrack? matchedNativeTrack;
    SubtitleTrack? fallbackAnyTrack;

    for (var sub in subTracks) {
      if (sub.id == 'no' || sub.id == 'auto' || sub.id == '-1') continue;
      fallbackAnyTrack ??= sub;

      final lang = (sub.language ?? '').toLowerCase();
      final title = (sub.title ?? '').toLowerCase();
      if (keywords.any((k) => lang.contains(k) || title.contains(k))) {
        matchedNativeTrack = sub;
        break;
      }
    }

    if (matchedNativeTrack != null) {
      _hasNativeTargetSubtitle = true;
      player.setSubtitleTrack(matchedNativeTrack);
      _tryMatchAudioToLanguage(keywords);
      if (!_hasEmbeddedSubtitleStream) {
        _startOfflineWhisperCaptions(desiredSub, targetCode);
      }
    } else if (fallbackAnyTrack != null) {
      _hasNativeTargetSubtitle = false;
      player.setSubtitleTrack(fallbackAnyTrack);
      if (!_hasEmbeddedSubtitleStream) {
        _startOfflineWhisperCaptions(desiredSub, targetCode);
      }
    } else {
      _hasNativeTargetSubtitle = false;
      _tryMatchAudioToLanguage(keywords);
      _startOfflineWhisperCaptions(desiredSub, targetCode);
    }
  }

  void _tryMatchAudioToLanguage(List<String> keywords) {
    final audioTracks = player.state.tracks.audio;
    if (audioTracks.isEmpty) return;

    for (var track in audioTracks) {
      final lang = (track.language ?? '').toLowerCase();
      final title = (track.title ?? '').toLowerCase();
      if (title.contains('adv') || title.contains('descript')) continue;

      if (keywords.any((k) => lang.contains(k) || title.contains(k))) {
        player.setAudioTrack(track);
        return;
      }
    }
  }

  String _getLanguageCode(String langName) {
    final lower = langName.toLowerCase();
    if (lower.contains('ingl') || lower.contains('eng')) return 'en';
    if (lower.contains('port')) return 'pt';
    if (lower.contains('fran')) return 'fr';
    if (lower.contains('ital')) return 'it';
    if (lower.contains('alem') || lower.contains('deu')) return 'de';
    return 'es';
  }

  List<String> _getLanguageKeywords(String langName) {
    final lower = langName.toLowerCase();
    if (lower.contains('ingl') || lower.contains('eng')) {
      return ['en', 'eng', 'english', 'ingl'];
    } else if (lower.contains('port')) {
      return ['pt', 'por', 'portug', 'bra'];
    } else if (lower.contains('fran')) {
      return ['fr', 'fre', 'fra', 'french', 'fran'];
    } else if (lower.contains('ital')) {
      return ['it', 'ita', 'ital'];
    } else if (lower.contains('alem')) {
      return ['de', 'ger', 'deu', 'german', 'alem'];
    }
    return ['es', 'spa', 'español', 'spanish', 'lat'];
  }

  /// Traduce frases en tiempo real con caché en memoria para respuesta instantánea
  Future<String> _requestGoogleTranslation(String sourceText, String targetCode) async {
    final cacheKey = '$targetCode|$sourceText';
    if (_translationCache.containsKey(cacheKey)) {
      return _translationCache[cacheKey]!;
    }

    try {
      final uri = Uri.parse(
        'https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$targetCode&dt=t&q=${Uri.encodeComponent(sourceText)}',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        if (decoded is List && decoded.isNotEmpty && decoded[0] is List) {
          final buffer = StringBuffer();
          for (var part in decoded[0]) {
            if (part is List && part.isNotEmpty && part[0] != null) {
              buffer.write(part[0].toString());
            }
          }
          final translated = buffer.toString().trim();
          if (translated.isNotEmpty) {
            if (_translationCache.length > 200) {
              _translationCache.clear();
            }
            _translationCache[cacheKey] = translated;
            return translated;
          }
        }
      }
    } catch (_) {}
    return sourceText;
  }

  /// Traduce en tiempo real cualquier subtítulo embebido o transcrito por Whisper al idioma elegido
  Future<void> _translateCaptionRealtime(String sourceText, String targetLangLabel) async {
    final targetCode = _getLanguageCode(targetLangLabel);
    final translated = await _requestGoogleTranslation(sourceText, targetCode);
    if (mounted && PlayerSettingsService.subtitleTrackNotifier.value != 'Desactivado') {
      setState(() => _liveTranslatedCaption = translated);
    }
  }

  /// Inicia Whisper Offline (IA local) cuando el canal o película no trae subtítulos embebidos
  void _startOfflineWhisperCaptions(String langLabel, String targetCode) {
    if (OfflineWhisperSubtitleService.isRunning) return;

    OfflineWhisperSubtitleService.start(
      onStatus: (statusText) {
        if (!mounted ||
            PlayerSettingsService.subtitleTrackNotifier.value == 'Desactivado' ||
            _hasEmbeddedSubtitleStream) {
          return;
        }
        setState(() => _liveTranslatedCaption = statusText);
      },
      onTranscript: (spokenText) async {
        if (!mounted ||
            PlayerSettingsService.subtitleTrackNotifier.value == 'Desactivado' ||
            _hasEmbeddedSubtitleStream) {
          return;
        }
        final activeLang = PlayerSettingsService.subtitleTrackNotifier.value;
        final activeCode = _getLanguageCode(activeLang);
        final translated = await _requestGoogleTranslation(spokenText, activeCode);
        if (mounted &&
            PlayerSettingsService.subtitleTrackNotifier.value != 'Desactivado' &&
            !_hasEmbeddedSubtitleStream) {
          setState(() => _liveTranslatedCaption = translated);
        }
      },
    );
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
      } else if (desiredTrack.contains('Portugués') &&
          (lang.contains('pt') || lang.contains('por') || title.contains('port'))) {
        player.setAudioTrack(track);
        return;
      }
    }
  }

  void play() => player.play();
  void pause() => player.pause();

  void seekRelative(int seconds) {
    final currentPos = player.state.position;
    final target = currentPos + Duration(seconds: seconds);

    player.seek(target < Duration.zero ? Duration.zero : target).then((_) {
      if (widget.isPlaying) {
        player.play();
      }
    });
  }

  void jumpToLiveEdge() {
    _tuneChannelFast(widget.streamUrl);
    if (widget.isPlaying) {
      player.play();
    }
  }

  // 🎨 Filtros de matriz de color para Daltonismo
  ColorFilter _getColorBlindFilter(String mode) {
    switch (mode) {
      case 'Protanopía (Ceguera al rojo)':
        return const ColorFilter.matrix(<double>[
          0.567, 0.433, 0.0, 0.0, 0.0,
          0.558, 0.442, 0.0, 0.0, 0.0,
          0.0, 0.242, 0.758, 0.0, 0.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ]);
      case 'Deuteranopía (Ceguera al verde)':
        return const ColorFilter.matrix(<double>[
          0.625, 0.375, 0.0, 0.0, 0.0,
          0.7, 0.3, 0.0, 0.0, 0.0,
          0.0, 0.3, 0.7, 0.0, 0.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ]);
      case 'Tritanopía (Ceguera al azul)':
        return const ColorFilter.matrix(<double>[
          0.95, 0.05, 0.0, 0.0, 0.0,
          0.0, 0.433, 0.567, 0.0, 0.0,
          0.0, 0.475, 0.525, 0.0, 0.0,
          0.0, 0.0, 0.0, 1.0, 0.0,
        ]);
      default:
        return const ColorFilter.matrix(<double>[
          1, 0, 0, 0, 0,
          0, 1, 0, 0, 0,
          0, 0, 1, 0, 0,
          0, 0, 0, 1, 0,
        ]);
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
    OfflineWhisperSubtitleService.stop();
    _tracksSub?.cancel();
    _subtitleTextSub?.cancel();
    PlayerSettingsService.bufferSizeNotifier.removeListener(_onBufferChanged);
    PlayerSettingsService.eqModeNotifier.removeListener(_onEqChanged);
    PlayerSettingsService.audioTrackNotifier.removeListener(_onAudioTrackChanged);
    PlayerSettingsService.subtitleTrackNotifier.removeListener(_onSubtitleSettingChanged);
    player.stop();
    player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Aplicamos el filtro de daltonismo al componente de video en tiempo real + Overlay de Traducción CC en Vivo
    return Stack(
      fit: StackFit.expand,
      children: [
        ColorFiltered(
          colorFilter: _getColorBlindFilter(widget.colorBlindMode),
          child: Video(
            controller: controller,
            controls: NoVideoControls,
            fill: Colors.black,
          ),
        ),
        if (_liveTranslatedCaption.isNotEmpty)
          Positioned(
            left: 24,
            right: 24,
            bottom: 110,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.78),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withOpacity(0.6),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    _liveTranslatedCaption,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(
                          color: Colors.black,
                          blurRadius: 4,
                          offset: Offset(1, 1),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}