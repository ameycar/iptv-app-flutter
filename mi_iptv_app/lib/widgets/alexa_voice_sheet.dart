import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../services/epg_service.dart';

class AlexaVoiceSheet extends StatefulWidget {
  final List<dynamic> channels;
  final String currentSection;
  final dynamic currentChannel;
  final Function(dynamic item) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onSectionChange;
  final Function(String section)? onNavigateSection;
  final Function(String category)? onCategorySelected;
  final bool isTvMode; // Nueva bandera inteligente

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
    this.isTvMode = false,
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
    // Detección automática: ¿Es un Smart TV (pantalla ancha horizontal) o un móvil?
    final size = MediaQuery.of(context).size;
    final bool isTv = size.width >= 900 && size.aspectRatio > 1.3;

    if (isTv) {
      // MODO SMART TV: Modal centrado para no atrapar el foco
      showDialog(
        context: context,
        builder: (ctx) => Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          child: AlexaVoiceSheet(
            channels: channels,
            currentSection: currentSection,
            currentChannel: currentChannel,
            onChannelSelected: onChannelSelected,
            onOpenEpg: onOpenEpg,
            onSectionChange: onSectionChange,
            onNavigateSection: onNavigateSection,
            onCategorySelected: onCategorySelected,
            isTvMode: true,
          ),
        ),
      );
    } else {
      // MODO MÓVIL ORIGINAL: Panel deslizable desde abajo
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
          isTvMode: false,
        ),
      );
    }
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

  // Nodos de foco exclusivos para TV
  final FocusNode _micFocusNode = FocusNode();
  final FocusNode _textFieldFocusNode = FocusNode();
  final FocusNode _sendBtnFocusNode = FocusNode();

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

    if (widget.isTvMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          FocusScope.of(context).requestFocus(_micFocusNode);
        }
      });
    }

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

  // MOTOR DE FILTRADO INTELIGENTE
  String _normalizeText(String text) {
    return text
        .toLowerCase()
        .trim()
        .replaceAll(RegExp(r'[áàäâ]'), 'a')
        .replaceAll(RegExp(r'[éèëê]'), 'e')
        .replaceAll(RegExp(r'[íìïî]'), 'i')
        .replaceAll(RegExp(r'[óòöô]'), 'o')
        .replaceAll(RegExp(r'[úùüû]'), 'u')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  // MOTOR DE FILTRADO INTELIGENTE (PRIORIDAD: CANAL EXACTO > EPG > TEMA/CATEGORÍA)
  void _processSmartFilterCommand(String rawQuery) {
    final clean = _normalizeText(rawQuery);
    if (clean.isEmpty) return;

    _stopVoiceListening();

    setState(() {
      _isProcessing = true;
      _statusText = 'BUSCANDO "$rawQuery"...';
    });

    if (clean.contains('guia') || clean.contains('epg') || clean.contains('programacion')) {
      Navigator.of(context).pop();
      widget.onOpenEpg?.call();
      return;
    }

    if (clean.contains('pelicula') || clean.contains('peliculas') || clean.contains('cine')) {
      widget.onSectionChange?.call('Películas');
    } else if (clean.contains('serie') || clean.contains('series')) {
      widget.onSectionChange?.call('Series');
    }

    // 1. Limpiar palabras de relleno manteniendo letras y números (ej: "espn 2")
    final queryWords = clean
        .replaceAll(
          RegExp(r'\b(coloca|pon|ponme|abre|busca|buscar|sintoniza|el|la|los|las|canal|canales|de|del|videos|por|favor|reproduce|mira|tv|ver|un|una|quiero|deseo|en|seccion|partido|partidos|estan|dando|pasando|hay)\b'),
          ' ',
        )
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

    final userTokens = queryWords
        .split(' ')
        .where((w) => w.length >= 2 || RegExp(r'^\d+$').hasMatch(w))
        .toList();

    // 2. NIVEL 1: Búsqueda DIRECTA por nombre de canal (ej: "espn 2", "fox sports", "cnn")
    if (queryWords.isNotEmpty &&
        queryWords != 'futbol' &&
        queryWords != 'deporte' &&
        queryWords != 'deportes' &&
        queryWords != 'noticias' &&
        queryWords != 'musica') {
      dynamic bestDirectMatch;
      int bestScore = 0;

      for (final c in widget.channels) {
        final normName = _normalizeText((c.name ?? '').toString());
        if (normName.isEmpty) continue;

        int score = 0;
        if (normName == queryWords) {
          score = 100;
        } else if (normName.contains(queryWords)) {
          // Prioriza coincidencia más cercana en longitud (ej: "espn 2" sobre "espn 2 extra")
          score = 90 - (normName.length - queryWords.length).clamp(0, 20);
        } else if (userTokens.isNotEmpty && userTokens.every((t) => normName.contains(t))) {
          score = 75;
        }

        if (score > bestScore) {
          bestScore = score;
          bestDirectMatch = c;
        }
      }

      if (bestDirectMatch != null) {
        Navigator.of(context).pop();
        widget.onChannelSelected(bestDirectMatch);
        return;
      }
    }

    // 3. NIVEL 2: Búsqueda por tema/categoría + Guía EPG (ej: "quiero ver un partido de fútbol")
    String? matchedCategory;
    List<String> topicKeywords = [];

    if (clean.contains('deporte') ||
        clean.contains('futbol') ||
        clean.contains('partido') ||
        clean.contains('gol') ||
        clean.contains('liga') ||
        clean.contains('champions')) {
      matchedCategory = 'Deportes';
      topicKeywords = [
        'futbol', 'deporte', 'sport', 'espn', 'fox', 'tnt', 'gol',
        'liga', 'tyc', 'dsports', 'directv', 'bein', 'dazn', 'win', 'movistar'
      ];
    } else if (clean.contains('noticia') || clean.contains('noticias') || clean.contains('actualidad')) {
      matchedCategory = 'Noticias';
      topicKeywords = ['noticia', 'news', 'cnn', 'rpp', 'canal n', 'bbc', 'telemundo', 'univision', '24h'];
    } else if (clean.contains('religios') || clean.contains('cristian') || clean.contains('iglesia') || clean.contains('dios')) {
      matchedCategory = 'Religiosos';
      topicKeywords = ['religio', 'cristian', 'iglesia', 'enlace', 'ewtn', 'fe'];
    } else if (clean.contains('musica') || clean.contains('cancion')) {
      matchedCategory = 'Música';
      topicKeywords = ['musica', 'music', 'htv', 'mtv', 'vh1', 'telehit'];
    } else if (clean.contains('infantil') || clean.contains('nino') || clean.contains('dibujo') || clean.contains('cartoon')) {
      matchedCategory = 'Infantil';
      topicKeywords = ['infantil', 'kids', 'disney', 'cartoon', 'nick', 'discovery kids'];
    } else if (clean.contains('entretenimiento') || clean.contains('variedades') || clean.contains('show')) {
      matchedCategory = 'Entretenimiento';
      topicKeywords = ['entretenimiento', 'variedades', 'star', 'warner', 'sony', 'tnt', 'axn'];
    }

    if (matchedCategory != null) {
      widget.onCategorySelected?.call(matchedCategory);
    }

    final fallbackTerms = <String>{
      ...userTokens,
      ...topicKeywords,
    }.toList();

    dynamic epgMatch;
    dynamic catMatch;

    for (final c in widget.channels) {
      final rawName = (c.name ?? '').toString();
      final normName = _normalizeText(rawName);
      String rawCat = '';
      try {
        rawCat = (c.groupCategory ?? '').toString();
      } catch (_) {}
      final normCat = _normalizeText(rawCat);

      try {
        final prog = EpgService.getCurrentProgram(rawName, rawCat);
        final normEpg = _normalizeText(prog.title);
        if (epgMatch == null && fallbackTerms.any((t) => normEpg.contains(t))) {
          epgMatch = c;
          break;
        }
      } catch (_) {}

      if (catMatch == null && fallbackTerms.any((t) => normName.contains(t) || normCat.contains(t))) {
        catMatch = c;
      }
    }

    final chosen = epgMatch ?? catMatch;
    if (chosen != null) {
      Navigator.of(context).pop();
      widget.onChannelSelected(chosen);
    } else {
      setState(() {
        _isProcessing = false;
        _statusText = matchedCategory != null
            ? 'Categoría "$matchedCategory" aplicada.'
            : 'No hallé "$rawQuery" en tus canales ni en la guía EPG.';
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
    _micFocusNode.dispose();
    _textFieldFocusNode.dispose();
    _sendBtnFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Construimos el contenido interno que se compartirá entre Móvil y TV
    Widget innerContent = FocusTraversalGroup(
      policy: WidgetOrderTraversalPolicy(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!widget.isTvMode) ...[
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 18),
          ],

          // BOTÓN MICRÓFONO
          Focus(
            focusNode: _micFocusNode,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.select ||
                      event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
                if (_isListening) {
                  _stopVoiceListening();
                } else {
                  _startVoiceListening();
                }
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Builder(builder: (context) {
              final hasFocus = Focus.of(context).hasFocus;
              return GestureDetector(
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
                      border: Border.all(
                        color: hasFocus ? Colors.white : Colors.transparent,
                        width: hasFocus ? 3 : 0,
                      ),
                      boxShadow: _isListening || hasFocus
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
              );
            }),
          ),
          const SizedBox(height: 12),

          Text(
            _statusText,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: _isProcessing ? const Color(0xFF00E5FF) : Colors.white70,
              fontSize: widget.isTvMode ? 15 : 13.5,
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
                    focusNode: _textFieldFocusNode,
                    style: TextStyle(color: Colors.white, fontSize: widget.isTvMode ? 16 : 14.5),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (val) {
                      if (val.trim().isNotEmpty) _processSmartFilterCommand(val);
                    },
                    decoration: InputDecoration(
                      hintText: 'Ej: deportes, noticias, htv...',
                      hintStyle: TextStyle(color: Colors.white30, fontSize: widget.isTvMode ? 14 : 13.5),
                      border: InputBorder.none,
                    ),
                  ),
                ),
                Focus(
                  focusNode: _sendBtnFocusNode,
                  onKeyEvent: (node, event) {
                    if (event is KeyDownEvent &&
                        (event.logicalKey == LogicalKeyboardKey.select ||
                            event.logicalKey == LogicalKeyboardKey.enter)) {
                      if (_textController.text.trim().isNotEmpty) {
                        _processSmartFilterCommand(_textController.text);
                      }
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: Builder(builder: (context) {
                    final hasFocus = Focus.of(context).hasFocus;
                    return Container(
                      decoration: BoxDecoration(
                        color: hasFocus ? const Color(0xFF00E5FF).withOpacity(0.2) : Colors.transparent,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: IconButton(
                        icon: Icon(Icons.send_rounded, color: hasFocus ? Colors.white : const Color(0xFF00E5FF)),
                        onPressed: () {
                          if (_textController.text.trim().isNotEmpty) {
                            _processSmartFilterCommand(_textController.text);
                          }
                        },
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ETIQUETAS DE FILTRADO INSTANTÁNEO
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              'Filtrado Rápido por Categoría:',
              style: TextStyle(color: Colors.white60, fontSize: widget.isTvMode ? 13 : 11.5, fontWeight: FontWeight.bold),
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

          // BOTONES DE ACCIÓN (Diferentes para TV y Móvil)
          if (widget.isTvMode)
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _buildActionBtn('Cerrar Búsqueda', isPrimary: false, onTap: () => Navigator.of(context).pop()),
              ],
            )
          else
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
    );

    // Renderizamos el contenedor final según el modo
    if (widget.isTvMode) {
      return Center(
        child: Container(
          width: 600,
          decoration: BoxDecoration(
            color: const Color(0xFF0C101D),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
            boxShadow: const [
              BoxShadow(color: Color(0x6600E5FF), blurRadius: 25, spreadRadius: -2)
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: innerContent,
        ),
      );
    } else {
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
          child: innerContent,
        ),
      );
    }
  }

  Widget _buildFilterChip(String label, String categoryKey) {
    if (widget.isTvMode) {
      return Builder(builder: (context) {
        return Focus(
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                (event.logicalKey == LogicalKeyboardKey.select ||
                    event.logicalKey == LogicalKeyboardKey.enter)) {
              _processSmartFilterCommand(categoryKey);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: Builder(builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return GestureDetector(
              onTap: () => _processSmartFilterCommand(categoryKey),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: BoxDecoration(
                  color: hasFocus ? const Color(0xFF00E5FF) : const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: hasFocus ? Colors.white : Colors.white12, width: hasFocus ? 2 : 1),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: hasFocus ? Colors.black : Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }),
        );
      });
    } else {
      // Formato original para móvil
      return ActionChip(
        label: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11)),
        backgroundColor: const Color(0xFF1E293B),
        side: const BorderSide(color: Colors.white12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onPressed: () => _processSmartFilterCommand(categoryKey),
      );
    }
  }

  Widget _buildActionBtn(String text, {required bool isPrimary, required VoidCallback onTap}) {
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                color: hasFocus
                    ? const Color(0xFF00E5FF)
                    : (isPrimary ? const Color(0xFF00E5FF) : Colors.transparent),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasFocus
                      ? Colors.white
                      : (isPrimary ? Colors.transparent : Colors.white24),
                  width: hasFocus ? 2 : 1,
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: hasFocus ? Colors.black : (isPrimary ? Colors.black : Colors.white60),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ),
          );
        }),
      );
    });
  }
}