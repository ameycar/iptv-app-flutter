import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:speech_to_text/speech_to_text.dart';

/// Motor de Subtítulos Automáticos en Vivo (0 USD) usando el reconocedor nativo de Android
/// Corre fuera de la memoria de Flutter para evitar cierres con video 1080p en media_kit.
class OfflineWhisperSubtitleService {
  static final SpeechToText _speech = SpeechToText();
  static bool _isInitialized = false;
  static bool _isRunning = false;
  static int _sessionToken = 0;
  static Timer? _restartTimer;
  static DateTime _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
  static String _lastEmittedText = '';

  static bool get isRunning => _isRunning;

  /// Inicia la escucha continua en vivo y envía el texto reconocido al traductor del reproductor
  static Future<void> start({
    required void Function(String statusText) onStatus,
    required void Function(String transcribedText) onTranscript,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      onStatus('Subtítulos automáticos disponibles solo en Android.');
      return;
    }

    stop();
    final int currentToken = ++_sessionToken;
    _isRunning = true;
    _lastEmittedText = '';

    try {
      // 1. Verificar permiso de micrófono
      final permStatus = await Permission.microphone.request();
      if (!_isValidSession(currentToken)) return;

      if (!permStatus.isGranted) {
        _isRunning = false;
        onStatus('Activa el permiso de micrófono para usar Subtítulos Automáticos.');
        return;
      }

      // 2. Inicializar motor nativo de reconocimiento de voz de Android (solo una vez)
      if (!_isInitialized) {
        onStatus('Iniciando motor de subtítulos en vivo...');
        _isInitialized = await _speech.initialize(
          onStatus: (status) {
            if (!_isValidSession(currentToken)) return;
            if (status == 'done' || status == 'notListening') {
              _scheduleRestart(currentToken, onStatus, onTranscript);
            }
          },
          onError: (error) {
            debugPrint('Aviso motor de subtítulos: ${error.errorMsg}');
            if (!_isValidSession(currentToken)) return;
            _scheduleRestart(currentToken, onStatus, onTranscript, delayMs: 1000);
          },
        );
      }

      if (!_isValidSession(currentToken)) return;

      if (!_isInitialized) {
        _isRunning = false;
        onStatus('Servicio de voz no disponible en este dispositivo.');
        return;
      }

      onStatus('🎙️ Escuchando audio en vivo...');
      await _startListeningCycle(currentToken, onStatus, onTranscript);
    } catch (e) {
      debugPrint('Error iniciando subtítulos en vivo: $e');
      if (_isValidSession(currentToken)) {
        onStatus('No se pudo iniciar el motor de subtítulos.');
      }
      _isRunning = false;
    }
  }

  static Future<void> _startListeningCycle(
    int token,
    void Function(String statusText) onStatus,
    void Function(String transcribedText) onTranscript,
  ) async {
    if (!_isValidSession(token)) return;

    try {
      if (_speech.isListening) {
        await _speech.stop();
      }
      if (!_isValidSession(token)) return;

      await _speech.listen(
        onResult: (result) {
          if (!_isValidSession(token)) return;
          final raw = result.recognizedWords.trim();
          if (raw.isEmpty) return;

          final compact = _keepRecentWindow(raw);
          if (compact.isEmpty || compact == _lastEmittedText) return;

          final now = DateTime.now();
          final elapsedMs = now.difference(_lastEmitAt).inMilliseconds;

          // Emitir inmediatamente al cerrar frase o cada 600ms para traducción fluida en vivo
          if (result.finalResult || elapsedMs >= 600) {
            _lastEmitAt = now;
            _lastEmittedText = compact;
            onTranscript(compact);
          }
        },
        listenFor: const Duration(seconds: 55),
        pauseFor: const Duration(seconds: 6),
        listenOptions: SpeechListenOptions(
          partialResults: true,
          cancelOnError: false,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (e) {
      debugPrint('Aviso ciclo de escucha subtítulos: $e');
      if (_isValidSession(token)) {
        _scheduleRestart(token, onStatus, onTranscript, delayMs: 1200);
      }
    }
  }

  static void _scheduleRestart(
    int token,
    void Function(String statusText) onStatus,
    void Function(String transcribedText) onTranscript, {
    int delayMs = 600,
  }) {
    _restartTimer?.cancel();
    _restartTimer = Timer(Duration(milliseconds: delayMs), () {
      if (_isValidSession(token) && !_speech.isListening) {
        _startListeningCycle(token, onStatus, onTranscript);
      }
    });
  }

  /// Mantiene solo las últimas palabras (~110 caracteres) para que el subtítulo sea legible en pantalla
  static String _keepRecentWindow(String text) {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.length <= 110) return cleaned;

    final tail = cleaned.substring(cleaned.length - 110);
    final firstSpace = tail.indexOf(' ');
    if (firstSpace > 0 && firstSpace < tail.length - 1) {
      return tail.substring(firstSpace + 1).trim();
    }
    return tail.trim();
  }

  /// Detiene inmediatamente el reconocimiento de voz
  static void stop() {
    _isRunning = false;
    _sessionToken++;
    _restartTimer?.cancel();
    _restartTimer = null;
    try {
      if (_speech.isListening) {
        _speech.stop();
      }
    } catch (_) {}
  }

  static bool _isValidSession(int token) => _isRunning && token == _sessionToken;
}
