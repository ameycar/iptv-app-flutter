import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/ai_curator_service.dart';

class AlexaVoiceSheet extends StatefulWidget {
  final List<dynamic> channels;
  final String currentSection;
  final dynamic currentChannel;
  final Function(dynamic item) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onNavigateSection;
  final Function(String category)? onCategorySelected;

  const AlexaVoiceSheet({
    super.key,
    required this.channels,
    this.currentSection = 'En Vivo',
    this.currentChannel,
    required this.onChannelSelected,
    this.onOpenEpg,
    this.onNavigateSection,
    this.onCategorySelected,
  });

  // Firma exacta que llama main.dart (context posicional + onOpenEpg + onNavigateSection)
  static void show(
    BuildContext context, {
    required List<dynamic> channels,
    String currentSection = 'En Vivo',
    dynamic currentChannel,
    required Function(dynamic item) onChannelSelected,
    VoidCallback? onOpenEpg,
    Function(String section)? onNavigateSection,
    Function(String category)? onCategorySelected,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AlexaVoiceSheet(
        channels: channels,
        currentSection: currentSection,
        currentChannel: currentChannel,
        onChannelSelected: onChannelSelected,
        onOpenEpg: onOpenEpg,
        onNavigateSection: onNavigateSection,
        onCategorySelected: onCategorySelected,
      ),
    );
  }

  @override
  State<AlexaVoiceSheet> createState() => _AlexaVoiceSheetState();
}

class _AlexaVoiceSheetState extends State<AlexaVoiceSheet> with SingleTickerProviderStateMixin {
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _recognizedText = '';
  String _aiStatus = 'Escuchando tu voz... Habla ahora';
  bool _isProcessing = false;
  late TextEditingController _textController;

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _textController = TextEditingController();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.25).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    _initSpeechSafely();
  }

  void _initSpeechSafely() async {
    try {
      bool available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'listening') {
            setState(() {
              _isListening = true;
              if (!_isProcessing) _aiStatus = 'MICRÓFONO ACTIVO';
            });
          } else if (status == 'notListening' || status == 'done') {
            setState(() {
              _isListening = false;
              if (!_isProcessing && _recognizedText.isEmpty && _textController.text.isEmpty) {
                _aiStatus = 'Escribe o presiona el micrófono para hablar';
              }
            });
          }
        },
        onError: (err) {
          if (!mounted) return;
          setState(() {
            _isListening = false;
            _aiStatus = 'Escribe o presiona el micrófono para hablar';
          });
        },
      );

      if (available && mounted) {
        _startListening();
      } else if (mounted) {
        setState(() => _aiStatus = 'Escribe o presiona el micrófono para hablar');
      }
    } catch (_) {
      if (mounted) setState(() => _aiStatus = 'Escribe lo que deseas ver');
    }
  }

  void _startListening() async {
    try {
      _recognizedText = '';
      setState(() {
        _isListening = true;
        _isProcessing = false;
        _aiStatus = 'Escuchando tu voz... Habla ahora';
      });

      await _speech.listen(
        localeId: 'es_ES',
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
        onResult: (result) {
          if (!mounted) return;
          setState(() {
            _recognizedText = result.recognizedWords;
            _textController.text = _recognizedText;
          });
        },
      );
    } catch (_) {
      if (mounted) setState(() => _isListening = false);
    }
  }

  void _stopListening() async {
    try {
      await _speech.stop();
    } catch (_) {}
    if (mounted) setState(() => _isListening = false);
  }

  void _executeAICommand(String query) async {
    final clean = query.trim();
    if (clean.isEmpty) return;

    _stopListening();

    setState(() {
      _isProcessing = true;
      _aiStatus = 'SINTONIZANDO AL INSTANTE...';
    });

    final result = await AICuratorService.interpretVoiceCommand(
      userVoicePrompt: clean,
      channels: widget.channels,
      currentSection: widget.currentSection,
      currentChannel: widget.currentChannel,
    );

    if (!mounted) return;

    switch (result.action) {
      case AIActionType.playChannel:
        if (result.item != null) {
          Navigator.of(context).pop();
          widget.onChannelSelected(result.item);
        }
        break;

      case AIActionType.openEPG:
        Navigator.of(context).pop();
        widget.onOpenEpg?.call();
        break;

      case AIActionType.switchTab:
        if (result.targetSection != null) {
          Navigator.of(context).pop();
          widget.onNavigateSection?.call(result.targetSection!);
        }
        break;

      case AIActionType.searchContent:
      case AIActionType.speakOnly:
      default:
        setState(() {
          _isProcessing = false;
          _aiStatus = result.message.isNotEmpty
              ? result.message
              : 'No encontré "$clean". Prueba con otro nombre.';
        });
        break;
    }
  }

  @override
  void dispose() {
    try {
      _speech.stop();
    } catch (_) {}
    _pulseController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isMovies = widget.currentSection.toLowerCase().contains('pel') ||
                     widget.currentSection.toLowerCase().contains('mov');
    final isSeries = widget.currentSection.toLowerCase().contains('ser');

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0F1424),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          boxShadow: [
            BoxShadow(color: Color(0x8000E5FF), blurRadius: 20, spreadRadius: -2)
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white24,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),

            GestureDetector(
              onTap: () {
                if (_isListening) {
                  _stopListening();
                } else {
                  _startListening();
                }
              },
              child: ScaleTransition(
                scale: _isListening ? _pulseAnimation : const AlwaysStoppedAnimation(1.0),
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: _isListening
                          ? [const Color(0xFF00E5FF), const Color(0xFFBD00FF)]
                          : [const Color(0xFF1E2942), const Color(0xFF2A3B5C)],
                    ),
                    boxShadow: _isListening
                        ? [const BoxShadow(color: Color(0x6600E5FF), blurRadius: 18, spreadRadius: 4)]
                        : [],
                  ),
                  child: Icon(
                    _isListening ? Icons.mic : Icons.mic_none_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            Text(
              _aiStatus,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isProcessing
                    ? const Color(0xFF00E5FF)
                    : (_aiStatus.contains('No encontré') ? Colors.orangeAccent : Colors.white70),
                fontSize: 13,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 14),

            // Cuadro de texto con botón Enviar (>) activo y Tecla Enter
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF161F36),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _isProcessing ? const Color(0xFF00E5FF) : Colors.white12,
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(color: Colors.white, fontSize: 15),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (val) {
                        if (val.trim().isNotEmpty) _executeAICommand(val);
                      },
                      decoration: const InputDecoration(
                        hintText: 'Ej: espn 2, béisbol, cine, noticias...',
                        hintStyle: TextStyle(color: Colors.white30, fontSize: 14),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_rounded, color: Color(0xFF00E5FF)),
                    onPressed: () {
                      if (_textController.text.trim().isNotEmpty) {
                        _executeAICommand(_textController.text);
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            Row(
              children: [
                Icon(
                  isMovies ? Icons.movie_outlined : (isSeries ? Icons.tv : Icons.live_tv),
                  color: const Color(0xFF00E5FF),
                  size: 16,
                ),
                const SizedBox(width: 8),
                Text(
                  isMovies
                      ? 'Sugerencias para PELÍCULAS:'
                      : (isSeries ? 'Sugerencias para SERIES:' : 'Sugerencias para EN VIVO:'),
                  style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 10),

            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: isMovies
                  ? [
                      _buildChip('🍿 Películas de Acción', 'película de acción'),
                      _buildChip('⭐ Comedias', 'comedia'),
                      _buildChip('📺 Ir a Canales en Vivo', 'en vivo'),
                    ]
                  : (isSeries
                      ? [
                          _buildChip('🔥 Series Populares', 'series'),
                          _buildChip('🔍 Drama', 'drama'),
                          _buildChip('📺 Ir a Canales en Vivo', 'en vivo'),
                        ]
                      : [
                          _buildChip('⚽ Deportes en Vivo', 'deportes'),
                          _buildChip('📰 Canales de Noticias', 'noticias'),
                          _buildChip('🎵 Música en Directo', 'música'),
                          _buildChip('📅 Guía de Canales (EPG)', 'guia'),
                        ]),
            ),
            const SizedBox(height: 20),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white60,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('Cancelar'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () {
                      if (_textController.text.trim().isNotEmpty) {
                        _executeAICommand(_textController.text);
                      } else if (_recognizedText.trim().isNotEmpty) {
                        _executeAICommand(_recognizedText);
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text('✓ Ejecutar', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChip(String label, String command) {
    return ActionChip(
      label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
      backgroundColor: const Color(0xFF1E293B),
      side: const BorderSide(color: Colors.white12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onPressed: () => _executeAICommand(command),
    );
  }
}