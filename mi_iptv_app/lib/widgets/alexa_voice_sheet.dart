import 'dart:async';
import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

class AlexaVoiceSheet extends StatefulWidget {
  final List<dynamic> channels;
  final String currentSection;
  final dynamic currentChannel;
  final Function(dynamic item) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onSectionChange;
  final Function(String section)? onNavigateSection;
  final Function(String category)? onCategorySelected;

  const AlexaVoiceSheet({
    super.key,
    required this.channels,
    this.currentSection = 'En Vivo',
    this.currentChannel,
    required this.onChannelSelected,
    this.onOpenEpg,
    this.onSectionChange,
    this.onNavigateSection,
    this.onCategorySelected,
  });

  static void show({
    required BuildContext context,
    required List<dynamic> channels,
    String currentSection = 'En Vivo',
    dynamic currentChannel,
    required Function(dynamic item) onChannelSelected,
    VoidCallback? onOpenEpg,
    Function(String section)? onSectionChange,
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
        onSectionChange: onSectionChange,
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
  String _statusText = 'Escuchando tu voz... Habla ahora';
  bool _isProcessing = false;
  late TextEditingController _textController;

  late AnimationController _animController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _speech = stt.SpeechToText();
    _textController = TextEditingController();

    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    _initVoiceEngine();
  }

  void _initVoiceEngine() async {
    try {
      bool available = await _speech.initialize(
        onStatus: (status) {
          if (!mounted) return;
          if (status == 'listening') {
            setState(() {
              _isListening = true;
              if (!_isProcessing) _statusText = 'MICRÓFONO AMEYCAR ACTIVO';
            });
          } else if (status == 'notListening' || status == 'done') {
            setState(() {
              _isListening = false;
              if (!_isProcessing && _recognizedText.isEmpty && _textController.text.isEmpty) {
                _statusText = 'Escribe o presiona el micrófono';
              }
            });
          }
        },
        onError: (_) {
          if (!mounted) return;
          setState(() {
            _isListening = false;
            _statusText = 'Escribe o presiona el micrófono';
          });
        },
      );

      if (available && mounted) {
        _startVoiceListening();
      } else if (mounted) {
        setState(() => _statusText = 'Escribe o presiona el micrófono');
      }
    } catch (_) {
      if (mounted) setState(() => _statusText = 'Escribe lo que deseas ver');
    }
  }

  void _startVoiceListening() async {
    try {
      _recognizedText = '';
      setState(() {
        _isListening = true;
        _isProcessing = false;
        _statusText = 'Escuchando tu voz... Habla ahora';
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
          if (result.finalResult && result.recognizedWords.trim().isNotEmpty) {
            _processSmartFilterCommand(result.recognizedWords);
          }
        },
      );
    } catch (_) {
      if (mounted) setState(() => _isListening = false);
    }
  }

  void _stopVoiceListening() async {
    try {
      await _speech.stop();
    } catch (_) {}
    if (mounted) setState(() => _isListening = false);
  }

  // MOTOR DE FILTRADO INTELIGENTE POR SECCIONES Y CANALES
  void _processSmartFilterCommand(String rawQuery) {
    final clean = rawQuery.trim().toLowerCase();
    if (clean.isEmpty) return;

    _stopVoiceListening();

    setState(() {
      _isProcessing = true;
      _statusText = 'FILTRANDO CATEGORÍA Y CANAL...';
    });

    // 1. Acceso a Guía EPG
    if (clean.contains('guia') || clean.contains('guía') || clean.contains('epg') || clean.contains('programacion')) {
      Navigator.of(context).pop();
      widget.onOpenEpg?.call();
      return;
    }

    // 2. FILTRADO RÁPIDO POR SECCIÓN / ETIQUETA (Deportes, Noticias, Religiosos, Música, Entretenimiento)
    String? matchedCategory;
    if (clean.contains('deporte') || clean.contains('futbol') || clean.contains('fútbol') || clean.contains('espn') || clean.contains('fox')) {
      matchedCategory = 'Deportes';
    } else if (clean.contains('noticia') || clean.contains('noticias') || clean.contains('actualidad') || clean.contains('cnn')) {
      matchedCategory = 'Noticias';
    } else if (clean.contains('religios') || clean.contains('cristian') || clean.contains('iglesia') || clean.contains('dios') || clean.contains('oración')) {
      matchedCategory = 'Religious';
    } else if (clean.contains('musica') || clean.contains('música') || clean.contains('video') || clean.contains('htv') || clean.contains('audio')) {
      matchedCategory = 'Música';
    } else if (clean.contains('entretenimiento') || clean.contains('variedades') || clean.contains('show')) {
      matchedCategory = 'Entretenimiento';
    }

    if (matchedCategory != null) {
      widget.onCategorySelected?.call(matchedCategory);
    }

    // 3. AISLAR EL NOMBRE DEL CANAL (Limpiando palabras de relleno)
    final queryWords = clean
        .replaceAll(RegExp(r'\b(coloca|pon|abre|busca|el|la|los|las|canal|de|videos|por|favor|reproduce|mira|tv|ver|un|una|quiero|en|la|seccion)\b'), '')
        .trim();

    final searchKey = queryWords.isNotEmpty ? queryWords : clean;

    // 4. BÚSQUEDA PRECISA EN LA LISTA
    dynamic foundChannel;
    try {
      foundChannel = widget.channels.firstWhere((c) {
        final name = (c.name ?? '').toString().toLowerCase();
        return name.contains(searchKey) || searchKey.contains(name);
      });
    } catch (_) {
      final words = searchKey.split(' ').where((w) => w.length > 1).toList();
      for (final word in words) {
        try {
          foundChannel = widget.channels.firstWhere((c) {
            final name = (c.name ?? '').toString().toLowerCase();
            return name.contains(word);
          });
          if (foundChannel != null) break;
        } catch (_) {}
      }
    }

    if (foundChannel != null) {
      Navigator.of(context).pop();
      widget.onChannelSelected(foundChannel);
    } else {
      setState(() {
        _isProcessing = false;
        _statusText = matchedCategory != null
            ? 'Categoría "$matchedCategory" aplicada con éxito.'
            : 'No hallé el canal "$rawQuery". Prueba con otra palabra.';
      });
    }
  }

  @override
  void dispose() {
    try {
      _speech.stop();
    } catch (_) {}
    _animController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0C101D),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          border: Border(top: BorderSide(color: Color(0xFF00E5FF), width: 1.5)),
          boxShadow: [
            BoxShadow(color: Color(0x6600E5FF), blurRadius: 25, spreadRadius: -2)
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),

            // BOTÓN MICRÓFONO FUTURISTA AMEYCAR
            GestureDetector(
              onTap: () {
                if (_isListening) {
                  _stopVoiceListening();
                } else {
                  _startVoiceListening();
                }
              },
              child: ScaleTransition(
                scale: _isListening ? _scaleAnimation : const AlwaysStoppedAnimation(1.0),
                child: Container(
                  width: 74,
                  height: 74,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      colors: _isListening
                          ? [const Color(0xFF00E5FF), const Color(0xFF7B2CBF)]
                          : [const Color(0xFF1E293B), const Color(0xFF334155)],
                    ),
                    boxShadow: _isListening
                        ? [const BoxShadow(color: Color(0x5500E5FF), blurRadius: 20, spreadRadius: 3)]
                        : [],
                  ),
                  child: Icon(
                    _isListening ? Icons.mic : Icons.mic_none_rounded,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            Text(
              _statusText,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _isProcessing ? const Color(0xFF00E5FF) : Colors.white70,
                fontSize: 13.5,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 14),

            // CAJA DE TEXTO INTELIGENTE
            Container(
              decoration: BoxDecoration(
                color: const Color(0xFF131B2E),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.white12),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 14),
                  Expanded(
                    child: TextField(
                      controller: _textController,
                      style: const TextStyle(color: Colors.white, fontSize: 14.5),
                      textInputAction: TextInputAction.search,
                      onSubmitted: (val) {
                        if (val.trim().isNotEmpty) _processSmartFilterCommand(val);
                      },
                      decoration: const InputDecoration(
                        hintText: 'Ej: deportes, noticias, htv, espn...',
                        hintStyle: TextStyle(color: Colors.white30, fontSize: 13.5),
                        border: InputBorder.none,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send_rounded, color: Color(0xFF00E5FF)),
                    onPressed: () {
                      if (_textController.text.trim().isNotEmpty) {
                        _processSmartFilterCommand(_textController.text);
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ETIQUETAS DE FILTRADO INSTANTÁNEO POR SECCIONES
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Filtrado Rápido por Categoría:',
                style: TextStyle(color: Colors.white60, fontSize: 11.5, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _buildFilterChip('⚽ Deportes', 'deportes'),
                _buildFilterChip('📰 Noticias', 'noticias'),
                _buildFilterChip('🎵 Música', 'música'),
                _buildFilterChip('⛪ Religiosos', 'religiosos'),
                _buildFilterChip('🍿 Entretenimiento', 'entretenimiento'),
              ],
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
                        _processSmartFilterCommand(_textController.text);
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

  Widget _buildFilterChip(String label, String categoryKey) {
    return ActionChip(
      label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
      backgroundColor: const Color(0xFF1E293B),
      side: const BorderSide(color: Colors.white12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      onPressed: () => _processSmartFilterCommand(categoryKey),
    );
  }
}
