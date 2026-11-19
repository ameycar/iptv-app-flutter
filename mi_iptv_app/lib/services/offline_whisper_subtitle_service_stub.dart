/// Stub para Flutter Web: evita importar dart:ffi al compilar para navegadores
class OfflineWhisperSubtitleService {
  static bool get isRunning => false;

  static Future<void> start({
    required void Function(String statusText) onStatus,
    required void Function(String transcribedText) onTranscript,
  }) async {
    onStatus('Subtítulos IA Offline disponibles solo en la app Android / Smart TV.');
  }

  static void stop() {}
}