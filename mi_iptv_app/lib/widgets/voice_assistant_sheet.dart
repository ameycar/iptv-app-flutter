import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../models/playlist_item.dart';
import '../services/voice_nlp_service.dart';

class VoiceAssistantSheet extends StatefulWidget {
  final List<PlaylistItem> channels;
  final Function(PlaylistItem) onPlayChannel;
  final Function(String) onSwitchTab; // 'live', 'movies', 'series'
  final Function(String) onSearch;
  final VoidCallback onOpenEPG;

  const VoiceAssistantSheet({
    super.key,
    required this.channels,
    required this.onPlayChannel,
    required this.onSwitchTab,
    required this.onSearch,
    required this.onOpenEPG,
  });

  @override
  State<VoiceAssistantSheet> createState() => _VoiceAssistantSheetState();
}

class _VoiceAssistantSheetState extends State<VoiceAssistantSheet> with SingleTickerProviderStateMixin {
  late stt.SpeechToText _speech;
  bool _isListening = false;
  String _words = '';
  String _status = 'Escuchando tu voz... Habla ahora';
  VoiceIntentResult? _detectedResult;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _startListening();
  }

  @override
  void dispose() {
    _animController.dispose();
    _speech.stop();
    super.dispose();
  }

  void _startListening() async {
    bool available = await _speech.initialize(
      onError: (val) {
        if (mounted) {
          setState(() {
            _isListening = false;
            _status = 'No se detectó audio. Pulsa el botón para hablar.';
          });
        }
      },
    );

    if (available && mounted) {
      setState(() {
        _isListening = true;
        _status = 'Escuchando tu voz... Habla ahora';
        _words = '';
      });

      _speech.listen(
        localeId: 'es_ES',
        listenMode: stt.ListenMode.confirmation,
        onResult: (val) {
          if (mounted) {
            setState(() {
              _words = val.recognizedWords;
              if (_words.isNotEmpty) {
                _detectedResult = VoiceNLPService.processCommand(_words, widget.channels);
                _status = _detectedResult?.text ?? 'Procesando...';
              }
            });

            // Si reconoció la frase final, ejecutar automáticamente sin demoras
            if (val.finalResult && _detectedResult != null) {
              Future.delayed(const Duration(milliseconds: 600), () {
                _executeIntent(_detectedResult!);
              });
            }
          }
        },
      );
    } else {
      if (mounted) {
        setState(() {
          _isListening = false;
          _status = 'Permiso de micrófono requerido';
        });
      }
    }
  }

  void _executeIntent(VoiceIntentResult result) {
    if (!mounted) return;
    Navigator.pop(context);

    switch (result.type) {
      case VoiceIntentType.playChannel:
        if (result.targetChannel != null) {
          widget.onPlayChannel(result.targetChannel!);
        }
        break;
      case VoiceIntentType.switchTab:
        if (result.targetTab != null) {
          widget.onSwitchTab(result.targetTab!);
        }
        break;
      case VoiceIntentType.openEPG:
        widget.onOpenEPG();
        break;
      case VoiceIntentType.searchContent:
        if (result.searchQuery != null) {
          widget.onSearch(result.searchQuery!);
        }
        break;
      case VoiceIntentType.unknown:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: const BoxDecoration(
        color: Color(0xFF0F0F1E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 45,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 20),
          GestureDetector(
            onTap: () {
              if (_isListening) {
                _speech.stop();
                setState(() => _isListening = false);
              } else {
                _startListening();
              }
            },
            child: AnimatedBuilder(
              animation: _animController,
              builder: (context, child) {
                final scale = _isListening ? 1.0 + (_animController.value * 0.12) : 1.0;
                return Transform.scale(
                  scale: scale,
                  child: Container(
                    width: 85,
                    height: 85,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [Color(0xFF00E5FF), Color(0xFF651FFF)],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E5FF).withOpacity(_isListening ? 0.6 : 0.2),
                          blurRadius: _isListening ? 25 : 10,
                          spreadRadius: _isListening ? 5 : 1,
                        ),
                      ],
                    ),
                    child: Icon(
                      _isListening ? Icons.mic : Icons.mic_none,
                      color: Colors.white,
                      size: 44,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          Text(
            _words.isEmpty ? 'DI UN COMANDO O CANAL' : '"$_words"',
            style: const TextStyle(
              color: Colors.cyanAccent,
              fontSize: 15,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.1,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B36),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              _status,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 18),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _buildQuickAction('⚽ Buscar fútbol', () => _wordsSimulated('buscar futbol')),
                _buildQuickAction('📺 ESPN', () => _wordsSimulated('pon espn')),
                _buildQuickAction('🎬 Películas', () => _wordsSimulated('ver peliculas')),
                _buildQuickAction('📅 Abrir EPG', () => _wordsSimulated('abrir guia')),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close, color: Colors.white60),
                  label: const Text('Cancelar', style: TextStyle(color: Colors.white60)),
                ),
              ),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _detectedResult != null
                      ? () => _executeIntent(_detectedResult!)
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  icon: const Icon(Icons.check, size: 20),
                  label: const Text('Ejecutar', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _wordsSimulated(String phrase) {
    setState(() {
      _words = phrase;
      _detectedResult = VoiceNLPService.processCommand(phrase, widget.channels);
      _status = _detectedResult?.text ?? 'Listo';
    });
    if (_detectedResult != null) {
      Future.delayed(const Duration(milliseconds: 300), () {
        _executeIntent(_detectedResult!);
      });
    }
  }

  Widget _buildQuickAction(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8.0),
      child: ActionChip(
        backgroundColor: const Color(0xFF1F1F3D),
        label: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 12)),
        onPressed: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Colors.white12),
        ),
      ),
    );
  }
}