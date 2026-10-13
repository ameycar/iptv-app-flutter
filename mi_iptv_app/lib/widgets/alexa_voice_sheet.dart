import 'package:flutter/material.dart';
import '../services/voice_assistant_service.dart';

class AlexaVoiceSheet extends StatefulWidget {
  final List<dynamic> channels;
  final dynamic currentChannel;
  final Function(dynamic channel) onChannelSelected;
  final VoidCallback? onOpenEpg;
  final Function(String section)? onNavigateSection;

  const AlexaVoiceSheet({
    super.key,
    required this.channels,
    required this.currentChannel,
    required this.onChannelSelected,
    this.onOpenEpg,
    this.onNavigateSection,
  });

  static void show(
    BuildContext context, {
    required List<dynamic> channels,
    dynamic currentChannel,
    required Function(dynamic channel) onChannelSelected,
    VoidCallback? onOpenEpg,
    Function(String section)? onNavigateSection,
  }) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => AlexaVoiceSheet(
        channels: channels,
        currentChannel: currentChannel,
        onChannelSelected: onChannelSelected,
        onOpenEpg: onOpenEpg,
        onNavigateSection: onNavigateSection,
      ),
    );
  }

  @override
  State<AlexaVoiceSheet> createState() => _AlexaVoiceSheetState();
}

class _AlexaVoiceSheetState extends State<AlexaVoiceSheet> with SingleTickerProviderStateMixin {
  final VoiceAssistantService _voiceService = VoiceAssistantService();
  String _recognizedText = "Escuchando tu voz... Habla ahora";
  String _statusMessage = "ASISTENTE INTELIGENTE AMEYCAR";
  bool _isProcessing = false;
  late AnimationController _animController;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);

    _startListening();
  }

  void _startListening() {
    setState(() {
      _recognizedText = "Escuchando... Di: 'Buscar partido en HD', 'Peppa Pig', 'Ver Guía', etc.";
      _statusMessage = "MICRÓFONO ACTIVO";
      _isProcessing = false;
    });

    _voiceService.startListening(
      onWordsRecognized: (words) {
        if (mounted) {
          setState(() {
            _recognizedText = words;
          });
        }
      },
      onListeningComplete: () {
        if (mounted) {
          _handleCommandExecution();
        }
      },
    );
  }

  Future<void> _handleCommandExecution() async {
    if (_recognizedText.isEmpty || _recognizedText.startsWith("Escuchando")) {
      setState(() {
        _statusMessage = "No se detectó ningún comando";
      });
      return;
    }

    setState(() {
      _isProcessing = true;
      _statusMessage = "ANALIZANDO CANALES Y CALIDAD HD...";
    });

    final result = _voiceService.processVoiceCommand(
      query: _recognizedText,
      channels: widget.channels,
      currentChannel: widget.currentChannel,
    );

    // Hablar la respuesta por voz al usuario
    await _voiceService.speak(result.spokenResponse);

    if (!mounted) return;

    if (result.actionType == 'CHANNEL' && result.targetChannel != null) {
      widget.onChannelSelected(result.targetChannel);
      Future.delayed(const Duration(milliseconds: 1300), () {
        if (mounted) Navigator.pop(context);
      });
    } else if (result.actionType == 'EPG') {
      widget.onOpenEpg?.call();
      Navigator.pop(context);
    } else if (result.actionType == 'NAV_MOVIES') {
      widget.onNavigateSection?.call('Películas');
      Navigator.pop(context);
    } else if (result.actionType == 'NAV_SERIES') {
      widget.onNavigateSection?.call('Series');
      Navigator.pop(context);
    } else if (result.actionType == 'NAV_LIVE') {
      widget.onNavigateSection?.call('En Vivo');
      Navigator.pop(context);
    } else {
      setState(() {
        _isProcessing = false;
        _statusMessage = "COMANDO FINALIZADO";
      });
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _voiceService.stopListening();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 26),
      decoration: BoxDecoration(
        color: const Color(0xFF090B14).withOpacity(0.98),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border.all(color: const Color(0xFF7B2CBF).withOpacity(0.6), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF7B2CBF).withOpacity(0.35),
            blurRadius: 30,
            spreadRadius: 4,
          )
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Barra superior
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 22),

          // Anillo estilo Alexa con ondas moradas y cian concéntricas
          AnimatedBuilder(
            animation: _animController,
            builder: (context, child) {
              double scale = 1.0 + (_animController.value * 0.16);
              double glow = _animController.value;

              return SizedBox(
                width: 100,
                height: 100,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Onda exterior morada
                    Container(
                      width: 96 * scale,
                      height: 96 * scale,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF9D4EDD).withOpacity(0.5 - (glow * 0.2)),
                          width: 2.5,
                        ),
                      ),
                    ),
                    // Onda intermedia cian
                    Container(
                      width: 82 * (1.0 + (glow * 0.08)),
                      height: 82 * (1.0 + (glow * 0.08)),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF00E5FF).withOpacity(0.6),
                          width: 2,
                        ),
                      ),
                    ),
                    // Esfera central con gradiente Alexa Morado - Azul
                    Container(
                      width: 68,
                      height: 68,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(
                          colors: [
                            Color(0xFFC77DFF),
                            Color(0xFF7B2CBF),
                            Color(0xFF240046),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF9D4EDD).withOpacity(0.8),
                            blurRadius: 22 * scale,
                            spreadRadius: 2,
                          )
                        ],
                      ),
                      child: Icon(
                        _isProcessing ? Icons.auto_awesome : Icons.mic,
                        color: Colors.white,
                        size: 32,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),

          // Estado del Asistente
          Text(
            _statusMessage,
            style: const TextStyle(
              color: Color(0xFFC77DFF),
              fontWeight: FontWeight.w900,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),

          // Transcripción en vivo
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: const Color(0xFF131726),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: const Color(0xFF7B2CBF).withOpacity(0.3)),
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

          // Chips de búsqueda rápida sugeridos
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _buildChip("⚽ Partido en HD"),
              _buildChip("🐷 Peppa Pig"),
              _buildChip("🎬 Ver Películas"),
              _buildChip("📅 Ver Guía EPG"),
            ],
          ),
          const SizedBox(height: 18),

          // Botones inferiores
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white60),
                label: const Text("Cancelar", style: TextStyle(color: Colors.white60)),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF7B2CBF),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: _handleCommandExecution,
                icon: const Icon(Icons.check, size: 20),
                label: const Text("Ejecutar ya", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChip(String text) {
    return InkWell(
      onTap: () {
        setState(() {
          _recognizedText = text.replaceAll(RegExp(r'[^\w\s]'), '').trim();
        });
        _handleCommandExecution();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF1B1E32),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF9D4EDD).withOpacity(0.4)),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }
}