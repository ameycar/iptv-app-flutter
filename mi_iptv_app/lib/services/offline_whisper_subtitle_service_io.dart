import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:whisper_flutter_new/whisper_flutter_new.dart';

/// Motor de Subtítulos IA Local (Whisper Offline) con seguro de RAM para Smart TV / TV Box
class OfflineWhisperSubtitleService {
  static const MethodChannel _audioChannel = MethodChannel('ameycar.tv/audio_capture');
  static const int _minSafeRamMb = 1500;

  static Whisper? _whisperInstance;
  static bool _isRunning = false;
  static int _sessionToken = 0;

  static bool get isRunning => _isRunning;

  /// Inicia el bucle de escucha y transcripción local con Whisper Tiny (0 USD en APIs)
  static Future<void> start({
    required void Function(String statusText) onStatus,
    required void Function(String transcribedText) onTranscript,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      onStatus('Subtítulos IA Offline disponibles solo en Android.');
      return;
    }

    stop();
    final int currentToken = ++_sessionToken;
    _isRunning = true;

    try {
      // 1. Seguro anti-crasheo para TV Boxes con poca memoria RAM
      final int totalRamMb = await _getTotalRamMb();
      if (!_isValidSession(currentToken)) return;

      if (totalRamMb < _minSafeRamMb) {
        _isRunning = false;
        onStatus('⚠️ Memoria RAM insuficiente (${totalRamMb}MB) para IA Offline.');
        return;
      }

      // 2. Permiso de audio para capturar el sonido que sale del dispositivo
      final permStatus = await Permission.microphone.request();
      if (!_isValidSession(currentToken)) return;

      if (!permStatus.isGranted) {
        _isRunning = false;
        onStatus('Activa el permiso de micrófono para usar Subtítulos IA Offline.');
        return;
      }

      // 3. Inicializar o descargar modelo Whisper Tiny (solo la primera vez)
      if (_whisperInstance == null) {
        onStatus('Cargando IA Offline (Whisper Tiny)...');
        final supportDir = await getApplicationSupportDirectory();
        final modelDir = Directory('${supportDir.path}/whisper_models');
        if (!modelDir.existsSync()) {
          modelDir.createSync(recursive: true);
        }

        _whisperInstance = Whisper(
          model: WhisperModel.tiny,
          modelDir: modelDir.path,
          downloadHost: 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main',
        );
      }

      if (!_isValidSession(currentToken)) return;
      onStatus('🎙️ IA Offline escuchando audio...');

      // 4. Bucle continuo de captura WAV (3.5 s) -> Transcripción local Whisper
      while (_isValidSession(currentToken)) {
        final String? wavPath = await _captureAudioChunk(durationMs: 3500);
        if (!_isValidSession(currentToken)) break;

        if (wavPath == null || wavPath.isEmpty) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }

        try {
          final response = await _whisperInstance!.transcribe(
            transcribeRequest: TranscribeRequest(
              audio: wavPath,
              isTranslate: false,
              isNoTimestamps: true,
              splitOnWord: false,
            ),
          );

          if (!_isValidSession(currentToken)) break;

          final cleaned = _sanitizeWhisperText(response.text);
          if (cleaned.isNotEmpty) {
            onTranscript(cleaned);
          }
        } catch (e) {
          debugPrint('Aviso transcripción Whisper Offline: $e');
          await Future.delayed(const Duration(milliseconds: 800));
        }
      }
    } catch (e) {
      debugPrint('Error en OfflineWhisperSubtitleService: $e');
      if (_isValidSession(currentToken)) {
        onStatus('No se pudo iniciar Whisper Offline.');
      }
      _isRunning = false;
    }
  }

  /// Detiene inmediatamente la captura y transcripción para liberar CPU/RAM
  static void stop() {
    _isRunning = false;
    _sessionToken++;
  }

  static bool _isValidSession(int token) => _isRunning && token == _sessionToken;

  static Future<int> _getTotalRamMb() async {
    try {
      final res = await _audioChannel
          .invokeMethod('getTotalRamMb')
          .timeout(const Duration(seconds: 2));
      if (res is int) return res;
    } catch (_) {}
    return 2048;
  }

  static Future<String?> _captureAudioChunk({int durationMs = 3500}) async {
    try {
      final res = await _audioChannel.invokeMethod('captureAudioChunk', {
        'durationMs': durationMs,
      }).timeout(Duration(milliseconds: durationMs + 3000));
      return res?.toString();
    } catch (e) {
      debugPrint('Error capturando bloque WAV: $e');
      return null;
    }
  }

  /// Limpia etiquetas de silencio o música que Whisper suele emitir cuando nadie habla
  static String _sanitizeWhisperText(String raw) {
    var text = raw
        .replaceAll(RegExp(r'\[[^\]]*\]'), '')
        .replaceAll(RegExp(r'\([^\)]*\)'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final lower = text.toLowerCase();
    const ignoredHallucinations = {
      '',
      '.',
      '...',
      'gracias.',
      'gracias por ver.',
      'subtítulos realizados por la comunidad de amara.org',
      'thank you.',
      'thanks for watching.',
      'you',
    };

    if (text.length < 3 || ignoredHallucinations.contains(lower)) {
      return '';
    }
    return text;
  }
}