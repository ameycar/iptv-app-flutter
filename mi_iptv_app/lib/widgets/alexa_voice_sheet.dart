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
  String _recognizedText = "Escuchando... Di: 'Buscar partido', 'ESPN', 'Películas'...";
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

    _startListening();
  }

  void _startListening() {
    setState(() {
      _recognizedText = "Escuchando tu voz... Habla ahora";
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
      _statusMessage = "PROCESANDO CON INTELIGENCIA ARTIFICIAL...";
    });

    final result = _voiceService.processVoiceCommand(
      query: _recognizedText,
      channels: widget.channels,
      currentChannel: widget.currentChannel,
    );

    await _voiceService.speak(result.spokenResponse);

    if (!mounted) return;

    if (result.actionType == 'SECTION' && result.targetSection.isNotEmpty) {
      widget.onNavigateSection?.call(result.targetSection);
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.pop(context);
      });
    } else if (result.actionType == 'CHANNEL' && result.targetChannel != null) {
      widget.onChannelSelected(result.targetChannel);
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) Navigator.pop(context);
      });
    } else if (result.actionType == 'EPG') {
      widget.onOpenEpg?.call();
      Navigator.pop(context);
    } else {
      Future.delayed(const Duration(milliseconds: 1600), () {
        if (mounted) Navigator.pop(context);
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
          Container(
            width: 44,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 18),
          AnimatedBuilder(
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
          const SizedBox(height: 18),
          Text(
            _statusMessage,
            style: const TextStyle(
              color: Color(0xFF00E5FF),
              fontWeight: FontWeight.w900,
              fontSize: 12,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
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
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.center,
            children: [
              _buildChip("⚽ Buscar partido"),
              _buildChip("📺 ESPN"),
              _buildChip("🎬 Ver Películas"),
              _buildChip("📅 Abrir Guía EPG"),
            ],
          ),
          const SizedBox(height: 16),
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
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                ),
                onPressed: _handleCommandExecution,
                icon: const Icon(Icons.check, size: 20),
                label: const Text("Ejecutar", style: TextStyle(fontWeight: FontWeight.bold)),
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
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
        ),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
      ),
    );
  }
}