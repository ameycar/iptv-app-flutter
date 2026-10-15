import 'package:flutter/material.dart';
import '../services/voice_assistant_service.dart';
import '../services/voice_nlp_service.dart';

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
  String _recognizedText = "Escuchando... Di: 'ESPN', 'Guía', o una película";
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

    _startListening();
  }

  void _startListening() {
    if (_isProcessing) return;

    setState(() {
      _recognizedText = "Escuchando tu voz... Habla ahora";
      _statusMessage = "MICRÓFONO ACTIVO";
      _isProcessing = false;
    });

    _voiceService.listen(
      onResult: (text, isFinal) {
        if (!mounted) return;
        setState(() {
          _recognizedText = text;
        });
      },
      onListeningComplete: () {
        if (mounted && _recognizedText.isNotEmpty && !_recognizedText.startsWith("Escuchando")) {
          _handleCommandExecution(_recognizedText);
        }
      },
    );
  }

  void _handleCommandExecution(String command) async {
    if (_isProcessing || command.trim().isEmpty) return;

    setState(() {
      _isProcessing = true;
      _statusMessage = "EJECUTANDO ORDEN...";
    });

    await _voiceService.stop();

    // Procesa el comando con la IA inteligente
    final result = await _voiceService.processVoiceCommand(
      command,
      widget.channels,
      currentChannel: widget.currentChannel,
      contextSection: widget.currentSection,
    );

    // Hablar la respuesta en segundo plano (sin bloquear)
    _voiceService.speak(result.spokenResponse);

    if (!mounted) return;

    // 1. Cerrar el modal de voz de inmediato
    Navigator.of(context).pop();

    // 2. Ejecutar la acción según la intención detectada
    switch (result.type) {
      case VoiceIntentType.playChannel:
        if (result.targetChannel != null) {
          widget.onChannelSelected(result.targetChannel);
        }
        break;

      case VoiceIntentType.openEPG:
        widget.onOpenEpg?.call();
        break;

      case VoiceIntentType.switchTab:
        if (result.targetTab != null) {
          widget.onNavigateSection?.call(result.targetTab!);
        }
        break;

      case VoiceIntentType.searchContent:
        if (widget.onSearch != null && result.searchQuery != null) {
          widget.onSearch!(result.searchQuery!, widget.currentSection);
        } else if (result.targetChannel != null) {
          widget.onChannelSelected(result.targetChannel);
        }
        break;

      case VoiceIntentType.unknown:
      default:
        // Si no está seguro, buscar en la sección actual
        if (widget.onSearch != null) {
          widget.onSearch!(command, widget.currentSection);
        }
        break;
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _voiceService.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isMovies = widget.currentSection.toUpperCase().contains('PELI');
    final bool isSeries = widget.currentSection.toUpperCase().contains('SERI');

    return Container(
      padding: const EdgeInsets.only(top: 12, bottom: 24, left: 20, right: 20),
      decoration: const BoxDecoration(
        color: Color(0xFF0D121D),
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(
          top: BorderSide(color: Color(0xFF1E293B), width: 1.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x6600E5FF),
            blurRadius: 30,
            spreadRadius: -5,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Tirador superior
          Container(
            width: 44,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(10),
            ),
          ),
          const SizedBox(height: 20),

          // Botón del Micrófono con Pulso Neón
          AnimatedBuilder(
            animation: _animController,
            builder: (context, child) {
              return Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [Color(0xFF00E5FF), Color(0xFF9D00FF)],
                  ),
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
                  icon: Icon(
                    _isProcessing ? Icons.auto_awesome : Icons.mic,
                    size: 40,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    if (_isProcessing) return;
                    _startListening();
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 14),

          // Estado del Asistente
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

          // Cuadro de texto reconocido
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
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Sugerencias Dinámicas basadas en la pestaña activa
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isMovies ? Icons.movie : (isSeries ? Icons.tv : Icons.live_tv),
                size: 14,
                color: const Color(0xFF00E5FF),
              ),
              const SizedBox(width: 6),
              Text(
                isMovies
                    ? "Sugerencias para PELÍCULAS:"
                    : (isSeries ? "Sugerencias para SERIES:" : "Sugerencias para EN VIVO:"),
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Botones de Sugerencia
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: isMovies
                ? [
                    _buildSuggestionChip("🍿 Películas de Acción", "Películas de Acción"),
                    _buildSuggestionChip("⭐ Más Populares", "Populares"),
                    _buildSuggestionChip("📺 Ver Canales en Vivo", "En Vivo"),
                  ]
                : (isSeries
                    ? [
                        _buildSuggestionChip("🎬 Series de Drama", "Series de Drama"),
                        _buildSuggestionChip("🔥 Nuevos Episodios", "Nuevos"),
                        _buildSuggestionChip("📺 Ver Canales en Vivo", "En Vivo"),
                      ]
                    : [
                        _buildSuggestionChip("⚽ ESPN Deportes", "ESPN"),
                        _buildSuggestionChip("📰 Canales de Noticias", "Noticias"),
                        _buildSuggestionChip("📅 Guía de Canales (EPG)", "Guía"),
                        _buildSuggestionChip("🍿 Ir a Películas", "Películas"),
                      ]),
          ),
          const SizedBox(height: 20),

          // Botones Inferiores: Cancelar y Ejecutar
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close, color: Colors.white60),
                  label: const Text(
                    "Cancelar",
                    style: TextStyle(color: Colors.white60, fontSize: 15),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    if (_recognizedText.isNotEmpty && !_recognizedText.startsWith("Escuchando")) {
                      _handleCommandExecution(_recognizedText);
                    }
                  },
                  icon: const Icon(Icons.check, color: Colors.black),
                  label: const Text(
                    "Ejecutar",
                    style: TextStyle(
                      color: Colors.black,
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
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
      onTap: () => _handleCommandExecution(command),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF334155)),
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