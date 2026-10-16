import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:flutter_tts/flutter_tts.dart';
import '../services/ai_curator_service.dart';

class AlexaVoiceSheet extends StatefulWidget {
  final List<dynamic> channels;
  final dynamic currentChannel;
  final String currentSection;
  final Function(dynamic item) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onNavigateSection;
  final Function(String query, String section)? onSearch;

  const AlexaVoiceSheet({
    super.key,
    required this.channels,
    this.currentChannel,
    this.currentSection = 'En Vivo',
    required this.onChannelSelected,
    this.onOpenEpg,
    this.onNavigateSection,
    this.onSearch,
  });

  static void show(
    BuildContext context, {
    required List<dynamic> channels,
    dynamic currentChannel,
    String currentSection = 'En Vivo',
    required Function(dynamic item) onChannelSelected,
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
        currentChannel: currentChannel,
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
  final TextEditingController _textEditingController = TextEditingController();

  String _recognizedText = "Escuchando tu voz... Habla ahora";
  String _statusMessage = "MICRÓFONO ACTIVO";
  bool _isProcessing = false;
  late AnimationController _animController;
  Timer? _silenceTimer;

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
      await _tts.setSpeechRate(0.55);

      final available = await _speech.initialize(
        onError: (e) {
          debugPrint("STT Error: $e");
          if (mounted) setState(() => _statusMessage = "ESCRIBE TU BÚSQUEDA ABAJO");
        },
        onStatus: (status) {
          if (status == "done" || status == "notListening") {
            _onSilenceTimeout();
          }
        },
      );

      if (available) {
        _playBeep();
        final systemLoc = await _speech.systemLocale();
        String targetLocale = systemLoc?.localeId ?? 'es_419';

        await _speech.listen(
          localeId: targetLocale,
          listenFor: const Duration(seconds: 10),
          pauseFor: const Duration(milliseconds: 1200),
          partialResults: true,
          cancelOnError: false,
          onResult: (result) {
            if (!mounted) return;
            final words = result.recognizedWords.trim();
            if (words.isNotEmpty) {
              setState(() {
                _recognizedText = words;
                _textEditingController.text = words;
              });

              _silenceTimer?.cancel();
              _silenceTimer = Timer(const Duration(milliseconds: 750), () {
                if (!_isProcessing && _recognizedText.length > 2) {
                  _executeCommand(_recognizedText);
                }
              });
            }

            if (result.finalResult && words.length > 1) {
              _silenceTimer?.cancel();
              _executeCommand(words);
            }
          },
        );
      }
    } catch (e) {
      debugPrint("Error STT: $e");
    }
  }

  void _onSilenceTimeout() {
    if (!_isProcessing &&
        _recognizedText.isNotEmpty &&
        !_recognizedText.startsWith("Escuchando") &&
        _recognizedText.trim().length > 1) {
      _executeCommand(_recognizedText);
    }
  }

  void _playBeep() {
    HapticFeedback.mediumImpact();
    SystemSound.play(SystemSoundType.click);
  }

  // EJECUCIÓN INMEDIATA SIN BLOQUEOS
  void _executeCommand(String text) async {
    final clean = text.trim();
    if (_isProcessing || clean.isEmpty || clean.startsWith("Escuchando")) {
      return;
    }

    _silenceTimer?.cancel();
    _speech.stop();

    setState(() {
      _isProcessing = true;
      _statusMessage = "SINTONIZANDO...";
    });

    _playBeep();

    // 1. CERRAR EL MODAL PRIMERO PARA NO TRABAR LA INTERFAZ
    if (mounted) {
      Navigator.of(context).pop();
    }

    // 2. INTERPRETAR Y EJECUTAR
    final result = await AICuratorService.interpretVoiceCommand(
      userVoicePrompt: clean,
      availableItems: widget.channels,
      currentTab: widget.currentSection,
    );

    if (result.speechResponse.isNotEmpty) {
      _tts.speak(result.speechResponse);
    }

    switch (result.action) {
      case AIActionType.playChannel:
        if (result.targetItem != null) {
          widget.onChannelSelected(result.targetItem);
        }
        break;

      case AIActionType.openEPG:
        widget.onOpenEpg?.call();
        break;

      case AIActionType.switchTab:
        if (result.targetTab != null) {
          final tabName = result.targetTab == 'movies'
              ? 'Películas'
              : result.targetTab == 'series'
                  ? 'Series'
                  : 'En Vivo';
          widget.onNavigateSection?.call(tabName);
        }
        break;

      case AIActionType.searchContent:
        if (widget.onSearch != null && result.searchQuery != null) {
          final cleanSec = widget.currentSection.toLowerCase().replaceAll('í', 'i');
          final targetSection = (result.targetTab == 'movies' || cleanSec.contains('peli'))
              ? 'Películas'
              : (result.targetTab == 'series' || cleanSec.contains('seri'))
                  ? 'Series'
                  : 'En Vivo';
          widget.onSearch!(result.searchQuery!, targetSection);
        }
        break;

      case AIActionType.speakOnly:
        break;
    }
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _animController.dispose();
    _speech.stop();
    _textEditingController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cleanSec = widget.currentSection.toLowerCase().replaceAll('í', 'i').trim();
    final bool isMovies = cleanSec.contains('peli') || cleanSec == 'movies' || cleanSec == '1';
    final bool isSeries = cleanSec.contains('seri') || cleanSec == 'series' || cleanSec == '2';

    return Container(
      padding: EdgeInsets.only(
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        left: 20,
        right: 20,
      ),
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
          const SizedBox(height: 16),

          // Botón Micrófono Neón
          AnimatedBuilder(
            animation: _animController,
            builder: (context, child) {
              return Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(colors: [Color(0xFF00E5FF), Color(0xFF9D00FF)]),
                  boxShadow: [
                    BoxShadow(
                      color: _isProcessing
                          ? const Color(0xFF9D00FF).withOpacity(0.8)
                          : const Color(0xFF00E5FF).withOpacity(0.3 + (_animController.value * 0.4)),
                      blurRadius: 15 + (_animController.value * 15),
                      spreadRadius: 2 + (_animController.value * 3),
                    ),
                  ],
                ),
                child: IconButton(
                  icon: Icon(_isProcessing ? Icons.auto_awesome : Icons.mic, size: 38, color: Colors.white),
                  onPressed: () {
                    if (!_isProcessing) {
                      setState(() {
                        _recognizedText = "Escuchando tu voz... Habla ahora";
                      });
                      _initVoiceAndListen();
                    }
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 12),

          Text(
            _statusMessage,
            style: const TextStyle(
              color: Color(0xFF00E5FF),
              fontSize: 11,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),

          // Caja de texto con botón Enviar activo
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF161F30),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _textEditingController,
                    style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                    decoration: InputDecoration(
                      hintText: _recognizedText,
                      hintStyle: TextStyle(
                        color: _recognizedText.startsWith("Escuchando") ? Colors.white54 : Colors.white,
                        fontSize: 15,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (val) {
                      if (val.trim().isNotEmpty) _executeCommand(val.trim());
                    },
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.send_rounded, color: Color(0xFF00E5FF), size: 22),
                  tooltip: 'Enviar y Sintonizar',
                  onPressed: () {
                    final txt = _textEditingController.text.trim().isNotEmpty
                        ? _textEditingController.text.trim()
                        : _recognizedText;
                    if (txt.isNotEmpty && !txt.startsWith("Escuchando")) {
                      _executeCommand(txt);
                    }
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),

          // TÍTULO DINÁMICO
          Text(
            isMovies
                ? "Sugerencias para PELÍCULAS:"
                : (isSeries ? "Sugerencias para SERIES:" : "Sugerencias para EN VIVO:"),
            style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),

          // CHIPS DINÁMICOS
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: isMovies
                ? [
                    _buildChip("🍿 Películas de Acción", "Películas de Acción"),
                    _buildChip("⭐ Comedias", "Comedia"),
                    _buildChip("📺 Ir a Canales en Vivo", "En Vivo"),
                  ]
                : (isSeries
                    ? [
                        _buildChip("🎬 Series de Drama", "Series de Drama"),
                        _buildChip("🔥 Estrenos y Temporadas", "Temporadas"),
                        _buildChip("📺 Ir a Canales en Vivo", "En Vivo"),
                      ]
                    : [
                        _buildChip("⚽ Deportes en Vivo", "Deportes"),
                        _buildChip("🎵 HTV Música", "HTV"),
                        _buildChip("📰 Canales de Noticias", "Noticias"),
                        _buildChip("📅 Guía de Canales (EPG)", "Guía"),
                      ]),
          ),
          const SizedBox(height: 18),

          // Botones Cancelar y Ejecutar
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white60),
                  label: const Text("Cancelar", style: TextStyle(color: Colors.white60, fontSize: 14)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onPressed: () {
                    final txt = _textEditingController.text.trim().isNotEmpty
                        ? _textEditingController.text.trim()
                        : _recognizedText;
                    if (txt.isNotEmpty && !txt.startsWith("Escuchando")) {
                      _executeCommand(txt);
                    }
                  },
                  icon: const Icon(Icons.check, color: Colors.black, size: 18),
                  label: const Text(
                    "Ejecutar",
                    style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label, String command) {
    return InkWell(
      onTap: () => _executeCommand(command),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
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
