import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import '../models/playlist_item.dart';
import '../services/ai_curator_service.dart';

class AlexaVoiceSheet extends StatefulWidget {
  final List<PlaylistItem> channels;
  final String currentSection; // 'live', 'movies', 'series'
  final Function(PlaylistItem item) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onNavigateSection;
  final Function(String query, String section)? onSearch;

  const AlexaVoiceSheet({
    super.key,
    required this.channels,
    this.currentSection = 'live',
    required this.onChannelSelected,
    this.onOpenEpg,
    this.onNavigateSection,
    this.onSearch,
  });

  static void show(
    BuildContext context, {
    required List<PlaylistItem> channels,
    required String currentSection,
    required Function(PlaylistItem item) onChannelSelected,
    VoidCallback? onOpenEpg,
    Function(String section)? onNavigateSection,
    Function(String query, String section)? onSearch,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AlexaVoiceSheet(
        channels: channels,
        currentSection: currentSection,
        onChannelSelected: onChannelSelected,
        onOpenEpg: onOpenEpg,
        onNavigateSection: onNavigateSection,
        onSearch: onSearch,
      ),
    );
  }

  @override
  State<AlexaVoiceSheet> createState() => _AlexaVoiceSheetState();
}

class _AlexaVoiceSheetState extends State<AlexaVoiceSheet> with SingleTickerProviderStateMixin {
  final stt.SpeechToText _speech = stt.SpeechToText();
  final FlutterTts _tts = FlutterTts();

  String _recognizedText = "Escuchando tu voz... Habla ahora";
  String _statusMessage = "MICRÓFONO ACTIVO";
  bool _isProcessing = false;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _initVoiceAndListen();
  }

  Future<void> _initVoiceAndListen() async {
    try {
      await _tts.setLanguage("es-ES");
      await _tts.setSpeechRate(0.55);

      final available = await _speech.initialize();
      if (available) {
        _playBeep();
        _speech.listen(
          localeId: 'es_ES',
          listenFor: const Duration(seconds: 8),
          pauseFor: const Duration(seconds: 2),
          onResult: (result) {
            if (!mounted) return;
            setState(() {
              _recognizedText = result.recognizedWords;
            });
            if (result.finalResult && result.recognizedWords.isNotEmpty) {
              _playBeep();
              _executeAICommand(result.recognizedWords);
            }
          },
        );
      }
    } catch (e) {
      print("Error STT: $e");
    }
  }

  void _playBeep() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
  }

  void _executeAICommand(String text) async {
    if (_isProcessing || text.trim().isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = "PROCESANDO CON INTELIGENCIA ARTIFICIAL...";
    });

    try {
      await _speech.stop();
    } catch (_) {}

    // Llamada al Cerebro de IA AICuratorService
    final result = await AICuratorService.interpretVoiceCommand(
      userVoicePrompt: text,
      availableItems: widget.channels,
      currentTab: widget.currentSection,
    );

    // Hablar la respuesta en voz alta
    if (result.speechResponse.isNotEmpty) {
      _tts.speak(result.speechResponse);
    }

    if (!mounted) return;

    // Cerrar el modal inmediatamente
    Navigator.of(context).pop();

    // Ejecutar la acción
    switch (result.action) {
      case AIActionType.playChannel:
        if (result.targetItem != null) {
          widget.onChannelSelected(result.targetItem!);
        }
        break;

      case AIActionType.openEPG:
        widget.onOpenEpg?.call();
        break;

      case AIActionType.switchTab:
        if (result.targetTab != null) {
          widget.onNavigateSection?.call(result.targetTab!);
        }
        break;

      case AIActionType.searchContent:
        if (widget.onSearch != null && result.searchQuery != null) {
          widget.onSearch!(result.searchQuery!, result.targetTab ?? widget.currentSection);
        }
        break;

      case AIActionType.speakOnly:
        break;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _speech.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Detección 100% infalible de sección
    final currentTabLower = widget.currentSection.toLowerCase().trim();
    final bool isMovies = currentTabLower == 'movies' || currentTabLower.contains('peli');
    final bool isSeries = currentTabLower == 'series' || currentTabLower.contains('seri');

    return Container(
      padding: const EdgeInsets.only(top: 12, bottom: 24, left: 20, right: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF0D121D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: Color(0xFF1E293B), width: 1.5)),
        boxShadow: [
          BoxShadow(color: Color(0x6600E5FF), blurRadius: 30, spreadRadius: -5)
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(10)),
          ),
          const SizedBox(height: 20),

          // Botón Micrófono Neón
          AnimatedBuilder(
            animation: _animController,
            builder: (context, child) {
              return Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(colors: [Color(0xFF00E5FF), Color(0xFF9D00FF)]),
                  boxShadow: [
                    BoxShadow(
                      color: _isProcessing
                          ? const Color(0xFF9D00FF).withOpacity(0.8)
                          : const Color(0xFF00E5FF).withOpacity(0.4 + (_animController.value * 0.4)),
                      blurRadius: 15 + (_animController.value * 20),
                      spreadRadius: 2 + (_animController.value * 4),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(_isProcessing ? Icons.auto_awesome : Icons.mic, size: 40, color: Colors.white),
                  onPressed: () {
                    if (!_isProcessing) _initVoiceAndListen();
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 14),

          Text(
            _statusMessage,
            style: const TextStyle(
              color: Color(0xFF00E5FF),
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),

          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF161F30),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF1E2D4A)),
            ),
            child: Text(
              '"$_recognizedText"',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 16),

          // Sugerencias Dinámicas Reales
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isMovies ? Icons.movie_filter : (isSeries ? Icons.tv_rounded : Icons.live_tv),
                size: 16,
                color: const Color(0xFF00E5FF),
              ),
              const SizedBox(width: 8),
              Text(
                isMovies
                    ? "Sugerencias para PELÍCULAS:"
                    : (isSeries ? "Sugerencias para SERIES:" : "Sugerencias para EN VIVO:"),
                style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),

          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: isMovies
                ? [
                    _buildSuggestionChip("🍿 Películas de Acción", "Películas de Acción"),
                    _buildSuggestionChip("⭐ Comedias", "Comedia"),
                    _buildSuggestionChip("📺 Ir a Canales en Vivo", "En Vivo"),
                  ]
                : (isSeries
                    ? [
                        _buildSuggestionChip("🎬 Series de Drama", "Series de Drama"),
                        _buildSuggestionChip("🔥 Estrenos y Temporadas", "Temporada"),
                        _buildSuggestionChip("📺 Ir a Canales en Vivo", "En Vivo"),
                      ]
                    : [
                        _buildSuggestionChip("⚽ ESPN Deportes", "ESPN"),
                        _buildSuggestionChip("📰 Canales de Noticias", "Noticias"),
                        _buildSuggestionChip("📅 Guía de Canales (EPG)", "Guía"),
                        _buildSuggestionChip("🍿 Ir a Películas", "Películas"),
                      ]),
          ),
          const SizedBox(height: 20),

          // Botones Cancelar y Ejecutar
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white60),
                  label: const Text("Cancelar", style: TextStyle(color: Colors.white60, fontSize: 15)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    if (_recognizedText.isNotEmpty && !_recognizedText.startsWith("Escuchando")) {
                      _executeAICommand(_recognizedText);
                    }
                  },
                  icon: const Icon(Icons.check, color: Colors.black),
                  label: const Text(
                    "Ejecutar",
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 15),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSuggestionChip(String label, String command) {
    return InkWell(
      onTap: () => _executeAICommand(command),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF334155)),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500)),
      ),
    );
  }
}