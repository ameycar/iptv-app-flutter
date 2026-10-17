import 'package:flutter/material.dart';

class ZappingChannelOverlay extends StatefulWidget {
  final dynamic channel;
  final int channelIndex;
  final int totalChannels;
  final bool isPlaying;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrevious;

  const ZappingChannelOverlay({
    super.key,
    required this.channel,
    this.channelIndex = 0,
    this.totalChannels = 0,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrevious,
  });

  @override
  State<ZappingChannelOverlay> createState() => _ZappingChannelOverlayState();
}

class _ZappingChannelOverlayState extends State<ZappingChannelOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  String _getChannelName() {
    try {
      if (widget.channel.name != null &&
          widget.channel.name.toString().isNotEmpty) {
        return widget.channel.name.toString();
      }
    } catch (_) {}
    return 'Canal en Vivo';
  }

  String _getLogoUrl() {
    try {
      if (widget.channel.logoUrl != null) {
        return widget.channel.logoUrl.toString();
      }
    } catch (_) {}
    return '';
  }

  String _getCurrentProgramTitle() {
    try {
      if (widget.channel.currentProgram != null &&
          widget.channel.currentProgram.title != null) {
        return widget.channel.currentProgram.title.toString();
      }
    } catch (_) {}
    return 'Transmisión en Directo HD';
  }

  String _getNextProgramTitle() {
    try {
      if (widget.channel.nextProgram != null &&
          widget.channel.nextProgram.title != null) {
        return widget.channel.nextProgram.title.toString();
      }
    } catch (_) {}
    return 'Continuidad de Programación';
  }

  double _getProgress() {
    try {
      if (widget.channel.currentProgram != null &&
          widget.channel.currentProgram.progress != null) {
        final val = (widget.channel.currentProgram.progress as num).toDouble();
        return val.clamp(0.0, 1.0);
      }
    } catch (_) {}
    return 0.45;
  }

  String _getTimeFormatted() {
    try {
      if (widget.channel.currentProgram != null &&
          widget.channel.currentProgram.timeFormatted != null) {
        return widget.channel.currentProgram.timeFormatted.toString();
      }
    } catch (_) {}
    final now = DateTime.now();
    final start = now.hour.toString().padLeft(2, '0');
    final end = ((now.hour + 1) % 24).toString().padLeft(2, '0');
    return '$start:00 - $end:00';
  }

  @override
  Widget build(BuildContext context) {
    final channelNumber = (widget.channelIndex + 1).toString().padLeft(3, '0');
    final channelName = _getChannelName();
    final logoUrl = _getLogoUrl();
    final currentProgram = _getCurrentProgramTitle();
    final nextProgram = _getNextProgramTitle();
    final progress = _getProgress();
    final timeStr = _getTimeFormatted();

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF090D16).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.25),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fila 1: Número CH, Logo, Nombre del Canal, Badge EN VIVO y Play/Pause
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    'CH $channelNumber',
                    style: const TextStyle(
                      color: Color(0xFF00E5FF),
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 32,
                    height: 32,
                    color: const Color(0xFF131A29),
                    child: logoUrl.isNotEmpty
                        ? Image.network(
                            logoUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.tv,
                              color: Colors.white54,
                              size: 18,
                            ),
                          )
                        : const Icon(Icons.tv, color: Colors.white54, size: 18),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          channelName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'FHD',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (context, child) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF1744).withValues(
                          alpha: 0.2 + (_pulseController.value * 0.25),
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: const Color(0xFFFF1744).withValues(
                            alpha: 0.6 + (_pulseController.value * 0.4),
                          ),
                          width: 1,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, color: Color(0xFFFF1744), size: 6),
                          SizedBox(width: 4),
                          Text(
                            'EN VIVO',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.8,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(width: 4),
                IconButton(
                  icon: Icon(
                    widget.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: const Color(0xFF00E5FF),
                    size: 26,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: widget.onPlayPause,
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Fila 2: Programa Actual y Horario
            Row(
              children: [
                const Icon(Icons.play_arrow,
                    color: Color(0xFF00E5FF), size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    currentProgram,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  timeStr,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Barra de Progreso del Programa
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.white12,
                valueColor:
                    const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 6),

            // Fila 3: Siguiente Programa & Zapping Rápido CH- / CH+
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      const Text(
                        'A continuación: ',
                        style: TextStyle(
                          color: Color(0xFF00E5FF),
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Expanded(
                        child: Text(
                          nextProgram,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white60,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    InkWell(
                      onTap: widget.onPrevious,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.skip_previous,
                                color: Colors.white70, size: 14),
                            Text(' CH-',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 10)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: widget.onNext,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          children: [
                            Text('CH+ ',
                                style: TextStyle(
                                    color: Colors.white70, fontSize: 10)),
                            Icon(Icons.skip_next,
                                color: Colors.white70, size: 14),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}