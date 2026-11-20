import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/player_settings_service.dart';

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
  static const MethodChannel _deviceChannel = MethodChannel('ameycar.tv/device');

  late final Player player;
  late final VideoController controller;
  StreamSubscription? _tracksSub;
  StreamSubscription? _subtitleTextSub;
  Timer? _noSubtitleCheckTimer;
  Timer? _hideHintTimer;
  int _switchToken = 0;

  String _liveTranslatedCaption = '';
  bool _hasNativeTargetSubtitle = false;
  bool _hasEmbeddedSubtitleStream = false;
  bool _showNoSubtitleHint = false;
  bool _triedVodSidecarSubtitle = false;
  final Map<String, String> _translationCache = {};

  bool get _isAndroidNative =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
      _noSubtitleCheckTimer?.cancel();
      _hideHintTimer?.cancel();
      if (_showNoSubtitleHint && mounted) {
        setState(() => _showNoSubtitleHint = false);
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
    _triedVodSidecarSubtitle = false;
    _noSubtitleCheckTimer?.cancel();
    _hideHintTimer?.cancel();
    if (mounted && (_liveTranslatedCaption.isNotEmpty || _showNoSubtitleHint)) {
      setState(() {
        _liveTranslatedCaption = '';
        _showNoSubtitleHint = false;
      });
    }

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

    _noSubtitleCheckTimer?.cancel();
    _hideHintTimer?.cancel();

    if (desiredSub == 'Desactivado' || desiredSub.isEmpty) {
      player.setSubtitleTrack(SubtitleTrack.no());
      _hasNativeTargetSubtitle = false;
      if (mounted) {
        setState(() {
          _liveTranslatedCaption = '';
          _showNoSubtitleHint = false;
        });
      }
      return;
    }

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
      if (mounted && _showNoSubtitleHint) {
        setState(() => _showNoSubtitleHint = false);
      }
    } else if (fallbackAnyTrack != null) {
      _hasNativeTargetSubtitle = false;
      player.setSubtitleTrack(fallbackAnyTrack);
      if (mounted && _showNoSubtitleHint) {
        setState(() => _showNoSubtitleHint = false);
      }
    } else {
      _hasNativeTargetSubtitle = false;
      _tryMatchAudioToLanguage(keywords);
      _scheduleNoSubtitleCheck(_switchToken);
    }
  }

  /// Verifica si existe un archivo .srt / .vtt junto al video VOD; si no hay pistas, muestra un aviso temporal
  void _scheduleNoSubtitleCheck(int token) {
    _noSubtitleCheckTimer?.cancel();
    _noSubtitleCheckTimer = Timer(const Duration(seconds: 4), () async {
      if (!mounted ||
          token != _switchToken ||
          PlayerSettingsService.subtitleTrackNotifier.value == 'Desactivado' ||
          _hasEmbeddedSubtitleStream) {
        return;
      }

      // Intentar cargar subtítulo externo (.srt / .vtt) si es una película/serie VOD
      final normalizedUrl = _normalizeArchiveAndSpacesUrl(widget.streamUrl);
      if (_isVodFileOrStream(normalizedUrl) && !_triedVodSidecarSubtitle) {
        _triedVodSidecarSubtitle = true;
        final loadedExternal = await _tryLoadVodSidecarSubtitle(normalizedUrl);
        if (loadedExternal) return;
      }

      if (!mounted ||
          token != _switchToken ||
          PlayerSettingsService.subtitleTrackNotifier.value == 'Desactivado' ||
          _hasEmbeddedSubtitleStream) {
        return;
      }

      setState(() => _showNoSubtitleHint = true);

      // Ocultar el aviso automáticamente después de 8 segundos para no estorbar el video
      _hideHintTimer?.cancel();
      _hideHintTimer = Timer(const Duration(seconds: 8), () {
        if (mounted && _showNoSubtitleHint) {
          setState(() => _showNoSubtitleHint = false);
        }
      });
    });
  }

  /// Busca automáticamente un archivo .srt o .vtt con el mismo nombre del archivo VOD
  Future<bool> _tryLoadVodSidecarSubtitle(String videoUrl) async {
    try {
      final cleanUrl = videoUrl.split('?').first;
      final dotIndex = cleanUrl.lastIndexOf('.');
      if (dotIndex <= cleanUrl.lastIndexOf('/')) return false;

      final baseUrl = cleanUrl.substring(0, dotIndex);
      final candidates = [
        '$baseUrl.es.srt',
        '$baseUrl.srt',
        '$baseUrl.es.vtt',
        '$baseUrl.vtt',
        '$baseUrl.en.srt',
      ];

      for (final subUrl in candidates) {
        try {
          final res = await http
              .head(Uri.parse(subUrl))
              .timeout(const Duration(seconds: 2));
          if (res.statusCode == 200) {
            await player.setSubtitleTrack(SubtitleTrack.uri(subUrl));
            return true;
          }
        } catch (_) {}
      }
    } catch (_) {}
    return false;
  }

  Future<void> _openAndroidLiveCaptionSettings() async {
    if (!_isAndroidNative) return;
    try {
      await _deviceChannel.invokeMethod('openCaptionSettings');
    } catch (e) {
      debugPrint('No se pudo abrir ajustes de subtítulos Android: $e');
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

  /// Traduce en tiempo real cualquier subtítulo embebido del canal o película al idioma elegido
  Future<void> _translateCaptionRealtime(String sourceText, String targetLangLabel) async {
    final targetCode = _getLanguageCode(targetLangLabel);
    final translated = await _requestGoogleTranslation(sourceText, targetCode);
    if (mounted && PlayerSettingsService.subtitleTrackNotifier.value != 'Desactivado') {
      setState(() => _liveTranslatedCaption = translated);
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
    _noSubtitleCheckTimer?.cancel();
    _hideHintTimer?.cancel();
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
            bottom: 24,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
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
          )
        else if (_showNoSubtitleHint)
          Positioned(
            left: 20,
            right: 20,
            bottom: 24,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.84),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: const Color(0xFF00E5FF).withOpacity(0.5),
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Flexible(
                      child: Text(
                        'Este canal no incluye pista de subtítulos.',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (_isAndroidNative) ...[
                      const SizedBox(width: 10),
                      TextButton(
                        onPressed: _openAndroidLiveCaptionSettings,
                        style: TextButton.styleFrom(
                          backgroundColor: const Color(0xFF00E5FF).withOpacity(0.18),
                          foregroundColor: const Color(0xFF00E5FF),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: const Text(
                          'Subtítulos Android',
                          style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                    const SizedBox(width: 4),
                    GestureDetector(
                      onTap: () => setState(() => _showNoSubtitleHint = false),
                      child: const Icon(Icons.close, color: Colors.white70, size: 18),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}