import 'package:flutter/material.dart';
import '../services/voice_assistant_service.dart';

class AlexaVoiceSheet extends StatefulWidget {
  final List<dynamic> channels;
  final dynamic currentChannel;
  final String currentSection; // 'LIVE', 'PELICULAS', 'SERIES'
  final Function(dynamic channel) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onNavigateSection;
  final Function(String query, String section)? onSearch;

  const AlexaVoiceSheet({
    super.key,
    required this.channels,
    this.currentChannel,
    this.currentSection = 'LIVE',
    required this.onChannelSelected,
    this.onOpenEpg,
    this.onNavigateSection,
    this.onSearch,
  });

  static void show(
    BuildContext context, {
    required List<dynamic> channels,
    dynamic currentChannel,
    String currentSection = 'LIVE',
    required Function(dynamic channel) onChannelSelected,
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
  final VoiceAssistantService _voiceService = VoiceAssistantService();
  String _recognizedText = "Escuchando... Di lo que deseas ver";
  String _statusMessage = "ASISTENTE INTELIGENTE AMEYCAR";
  bool _isProcessing = false;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);

    // Saludo personalizado si ya se conoce el nombre del usuario
    if (_voiceService.userName.isNotEmpty) {
      _statusMessage = "HOLA ${_voiceService.userName.toUpperCase()} • AMEYCAR AI";
    }

    _startListening();
  }

  void _startListening() {
    if (_isProcessing) return;

    setState(() {
      _recognizedText = "Escuchando tu voz... Habla ahora";
      _statusMessage = _voiceService.userName.isNotEmpty
          ? "ESCUCHANDO A ${_voiceService.userName.toUpperCase()}"
          : "MICRÓFONO ACTIVO";
      _isProcessing = false;
    });

    try {
      _voiceService.startListening(
        onWordsRecognized: (words) {
          if (mounted && !_isProcessing) {
            setState(() {
              _recognizedText = words;
            });
          }
        },
        onListeningComplete: () {
          if (mounted && !_isProcessing) {
            _handleCommandExecution();
          }
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = "TOCA EL MICRÓFONO PARA REINTENTAR";
        });
      }
    }
  }

  Future<void> _handleCommandExecution([String? explicitQuery]) async {
    if (_isProcessing) return;

    final queryToProcess = explicitQuery ?? _recognizedText;

    // Validación de texto reconocido
    if (queryToProcess.isEmpty ||
        queryToProcess.startsWith("Escuchando") ||
        queryToProcess == "...") {
      setState(() {
        _statusMessage = "NO SE DETECTÓ NINGÚN COMANDO";
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = "PROCESANDO CON INTELIGENCIA ARTIFICIAL...";
    });

    // 1. Liberar inmediatamente el micrófono
    try {
      _voiceService.stopListening();
    } catch (_) {}

    try {
      // 2. Procesar con el cerebro de IA contextual
      final result = _voiceService.processVoiceCommand(
        query: queryToProcess,
        channels: widget.channels,
        currentChannel: widget.currentChannel,
        currentSection: widget.currentSection,
      );

      // 3. Responder por voz en segundo plano SIN bloquear la ejecución
      // (Sin 'await' para que no congele la aplicación si el audio tarda)
      if (result.spokenResponse.isNotEmpty) {
        _voiceService
            .speak(result.spokenResponse)
            .timeout(const Duration(milliseconds: 1500), onTimeout: () {})
            .catchError((_) {});
      }

      if (!mounted) return;

      // 4. Ejecución de la acción según la intención detectada
      if (result.actionType == 'CHANNEL' && result.targetChannel != null) {
        final channelToPlay = result.targetChannel;
        setState(() {
          _statusMessage = "SINTONIZANDO CANAL...";
        });

        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;

        Navigator.pop(context);
        widget.onChannelSelected(channelToPlay);
      } else if (result.actionType == 'SECTION' && result.targetSection.isNotEmpty) {
        setState(() {
          _statusMessage = "ABRIENDO ${result.targetSection}...";
        });
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;

        Navigator.pop(context);
        widget.onNavigateSection?.call(result.targetSection);
      } else if (result.actionType == 'EPG') {
        setState(() {
          _statusMessage = "ABRIENDO GUÍA EPG...";
        });
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;

        Navigator.pop(context);
        widget.onOpenEpg?.call();
      } else if (result.actionType == 'SEARCH') {
        setState(() {
          _statusMessage = "BUSCANDO CONTENIDO...";
        });
        await Future.delayed(const Duration(milliseconds: 250));
        if (!mounted) return;

        Navigator.pop(context);
        if (widget.onSearch != null) {
          widget.onSearch!(result.searchQuery ?? queryToProcess, widget.currentSection);
        } else {
          widget.onNavigateSection?.call(result.targetSection);
        }
      } else {
        // Mensaje conversacional o nombre guardado
        setState(() {
          _isProcessing = false;
          _statusMessage = _voiceService.userName.isNotEmpty
              ? "¡HOLA ${_voiceService.userName.toUpperCase()}!"
              : "LISTO";
        });
        await Future.delayed(const Duration(milliseconds: 1000));
        if (mounted) {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      // 5. Plan de respaldo si falla processVoiceCommand:
      // Busca directamente el canal por nombre para que NUNCA se quede congelado
      dynamic matchedChannel;
      final q = queryToProcess.toLowerCase().trim();
      for (final ch in widget.channels) {
        try {
          final name = (ch.name ?? '').toString().toLowerCase();
          if (name.contains(q) || q.contains(name)) {
            matchedChannel = ch;
            break;
          }
        } catch (_) {}
      }

      if (matchedChannel != null && mounted) {
        Navigator.pop(context);
        widget.onChannelSelected(matchedChannel);
      } else {
        if (mounted) {
          setState(() {
            _isProcessing = false;
            _statusMessage = "COMANDO NO RECONOCIDO";
          });
          await Future.delayed(const Duration(milliseconds: 1000));
          if (mounted) {
            Navigator.pop(context);
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    try {
      _voiceService.stopListening();
    } catch (_) {}
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Obtenemos sugerencias dinámicas adaptadas a la sección actual
    final suggestions = _voiceService.getSuggestionsForContext(widget.currentSection);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
      decoration: BoxDecoration(
        color: const Color(0xFF070A10).withOpacity(0.98),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF00E5FF).withOpacity(0.25),
            blurRadius: 25,
            spreadRadius: 4,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barra superior de arrastre
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 18),

          // Botón / Animación de micrófono central interactivo
          GestureDetector(
            onTap: () {
              if (!_isProcessing) {
                _startListening();
              }
            },
            child: AnimatedBuilder(
              animation: _animController,
              builder: (context, child) {
                double scale = 1.0 + (_animController.value * 0.18);
                return Transform.scale(
                  scale: _isProcessing ? 1.0 : scale,
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: const RadialGradient(
                        colors: [
                          Color(0xFF00E5FF),
                          Color(0xFF0072FF),
                          Color(0xFF7B2CBF),
                        ],
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF00E5FF).withOpacity(0.6),
                          blurRadius: 20 * scale,
                          spreadRadius: 3,
                        )
                      ],
                    ),
                    child: Icon(
                      _isProcessing ? Icons.auto_awesome : Icons.mic,
                      color: Colors.black,
                      size: 36,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 18),

          // Estado del asistente
          Text(
            _statusMessage,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFF00E5FF),
              fontWeight: FontWeight.w900,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),

          // Cuadro de texto reconocido
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF131B2E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: Text(
              "\"$_recognizedText\"",
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
                height: 1.3,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Indicador de sección activa para sugerencias inteligentes
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.currentSection.toUpperCase().contains('PELICULA')
                    ? Icons.movie_outlined
                    : widget.currentSection.toUpperCase().contains('SERIE')
                        ? Icons.tv_outlined
                        : Icons.live_tv_outlined,
                color: const Color(0xFF00E5FF),
                size: 14,
              ),
              const SizedBox(width: 6),
              Text(
                "Sugerencias para ${widget.currentSection}:",
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Sugerencias rápidas (chips) dinámicas y contextuales
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: suggestions.map((item) {
              final label = item['label'] ?? '';
              final query = item['query'] ?? label;
              return _buildChip(label, query);
            }).toList(),
          ),
          const SizedBox(height: 18),

          // Botones inferiores de Cancelar / Ejecutar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: () {
                  try {
                    _voiceService.stopListening();
                  } catch (_) {}
                  Navigator.pop(context);
                },
                icon: const Icon(Icons.close, color: Colors.white60),
                label: const Text("Cancelar", style: TextStyle(color: Colors.white60)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: _isProcessing ? null : () => _handleCommandExecution(),
                icon: const Icon(Icons.check, size: 20),
                label: const Text("Ejecutar", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String label, String query) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () {
        if (_isProcessing) return;
        setState(() {
          _recognizedText = query;
        });
        _handleCommandExecution(query);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.35)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}