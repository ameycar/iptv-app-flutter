import 'dart:async';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import 'voice_nlp_service.dart';

class VoiceAssistantService {
  static final VoiceAssistantService _instance = VoiceAssistantService._internal();
  factory VoiceAssistantService() => _instance;
  VoiceAssistantService._internal();

  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();
  bool _isInit = false;

  Future<bool> init() async {
    if (_isInit) return true;
    try {
      _isInit = await _speech.initialize(
        onError: (err) => print('Error STT: $err'),
        onStatus: (status) => print('Status STT: $status'),
      );
      await _tts.setLanguage("es-ES");
      await _tts.setSpeechRate(0.55); // Habla rápido y fluido estilo Alexa
      await _tts.setVolume(1.0);
    } catch (e) {
      print("Error al inicializar servicios de voz: $e");
    }
    return _isInit;
  }

  /// Hace el sonido "PIP" y vibración inmediata
  void playBeepSound() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
  }

  /// Escuchar voz del usuario
  Future<void> listen({
    required Function(String text, bool isFinal) onResult,
    required Function() onListeningComplete,
  }) async {
    final hasInit = await init();
    if (!hasInit) return;

    // Sonido PIP al empezar
    playBeepSound();

    await _speech.listen(
      localeId: 'es_ES',
      cancelOnError: true,
      partialResults: true,
      listenFor: const Duration(seconds: 7),
      pauseFor: const Duration(seconds: 2),
      onResult: (result) {
        onResult(result.recognizedWords, result.finalResult);
        if (result.finalResult) {
          playBeepSound(); // Sonido PIP al terminar de escuchar
          onListeningComplete();
        }
      },
    );
  }

  Future<void> stop() async {
    try {
      await _speech.stop();
    } catch (_) {}
  }

  /// Habla sin bloquear la aplicación (Fuego y olvido)
  void speak(String text) {
    if (text.isEmpty) return;
    try {
      _tts.speak(text);
    } catch (_) {}
  }

  /// Procesa con el motor inteligente protegido contra bloqueos
  Future<VoiceIntentResult> processVoiceCommand(
    String command,
    List<dynamic> channels, {
    dynamic currentChannel,
    String contextSection = 'LIVE',
  }) async {
    // Si viene vacío
    if (command.trim().isEmpty) {
      return VoiceIntentResult(
        type: VoiceIntentType.unknown,
        text: command,
        spokenResponse: "No pude escuchar lo que dijiste.",
      );
    }

    try {
      // Ejecución instantánea con timeout de seguridad
      return await Future.value(
        VoiceNLPService.processCommand(
          command,
          channels,
          currentSection: contextSection,
        ),
      ).timeout(
        const Duration(milliseconds: 800),
        onTimeout: () {
          // Si por alguna razón tarda más de 800ms, hace búsqueda directa
          return VoiceIntentResult(
            type: VoiceIntentType.searchContent,
            text: command,
            searchQuery: command,
            spokenResponse: "Buscando $command",
          );
        },
      );
    } catch (e) {
      return VoiceIntentResult(
        type: VoiceIntentType.searchContent,
        text: command,
        searchQuery: command,
        spokenResponse: "Buscando $command",
      );
    }
  }
}