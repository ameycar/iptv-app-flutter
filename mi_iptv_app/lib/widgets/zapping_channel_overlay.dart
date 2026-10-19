import 'package:flutter/material.dart';
import '../services/epg_service.dart';

class ZappingChannelOverlay extends StatefulWidget {
  final dynamic channel;
  final int channelIndex;
  final int totalChannels;
  final bool isPlaying;
  final bool isFullScreen;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback? onOpenEpg;
  final VoidCallback? onToggleFullScreen;

  const ZappingChannelOverlay({
    super.key,
    required this.channel,
    this.channelIndex = 0,
    this.totalChannels = 0,
    required this.isPlaying,
    this.isFullScreen = false,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrevious,
    this.onOpenEpg,
    this.onToggleFullScreen,
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

  String _getGroupCategory() {
    try {
      if (widget.channel.groupCategory != null &&
          widget.channel.groupCategory.toString().isNotEmpty) {
        return widget.channel.groupCategory.toString();
      }
    } catch (_) {}
    return 'General';
  }

  String _getLogoUrl() {
    try {
      if (widget.channel.logoUrl != null) {
        return widget.channel.logoUrl.toString();
      }
    } catch (_) {}
    return '';
  }

  String _getResolution() {
    try {
      if (widget.channel.resolution != null &&
          widget.channel.resolution.toString().isNotEmpty) {
        return widget.channel.resolution.toString();
      }
    } catch (_) {}
    return 'FHD';
  }

  @override
  Widget build(BuildContext context) {
    final channelNumber = (widget.channelIndex + 1).toString().padLeft(3, '0');
    final channelName = _getChannelName();
    final groupCat = _getGroupCategory();
    final logoUrl = _getLogoUrl();
    final resolution = _getResolution();

    // Sincronización directa con EpgService (Capa 1 XMLTV + Capa 2 ESPN Live + Capa 3 OCR)
    final currentProg = EpgService.getCurrentProgram(channelName, groupCat);
    final nextProg = EpgService.getNextProgram(channelName, groupCat);

    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF090D16).withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: const Color(0xFF00E5FF).withValues(alpha: 0.30),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.65),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Fila 1: Número CH, Logo, Nombre del Canal, Badge EN VIVO, Play/Pause y Pantalla Completa
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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
                      fontSize: 11,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    width: 28,
                    height: 28,
                    color: const Color(0xFF131A29),
                    child: logoUrl.isNotEmpty
                        ? Image.network(
                            logoUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.tv,
                              color: Colors.white54,
                              size: 16,
                            ),
                          )
                        : const Icon(Icons.tv, color: Colors.white54, size: 16),
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
                            fontSize: 13,
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.white12,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          resolution,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 8.5,
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
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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
                          SizedBox(width: 3),
                          Text(
                            'EN VIVO',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 8.5,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: Icon(
                    widget.isPlaying
                        ? Icons.pause_circle_filled
                        : Icons.play_circle_filled,
                    color: const Color(0xFF00E5FF),
                    size: 24,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: widget.onPlayPause,
                ),
                if (widget.onToggleFullScreen != null) ...[
                  const SizedBox(width: 6),
                  InkWell(
                    onTap: widget.onToggleFullScreen,
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF7B2CBF).withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: const Color(0xFFC77DFF), width: 1),
                      ),
                      child: Icon(
                        widget.isFullScreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),

            // Fila 2: Programa Actual Sincronizado y Horario
            Row(
              children: [
                const Icon(Icons.play_arrow, color: Color(0xFF00E5FF), size: 14),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    currentProg.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  currentProg.timeFormatted,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),

            // Barra de Progreso del Programa
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: currentProg.progress.clamp(0.0, 1.0),
                backgroundColor: Colors.white12,
                valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                minHeight: 3,
              ),
            ),
            const SizedBox(height: 6),

            // Fila 3: Siguiente Programa + Botón EPG + Botones CH- / CH+
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
                          nextProg.title,
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
                    if (widget.onOpenEpg != null) ...[
                      InkWell(
                        onTap: widget.onOpenEpg,
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF7B2CBF).withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: const Color(0xFFC77DFF).withValues(alpha: 0.6),
                            ),
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.calendar_month, color: Color(0xFFFFB703), size: 12),
                              SizedBox(width: 3),
                              Text(
                                'EPG',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 5),
                    ],
                    InkWell(
                      onTap: widget.onPrevious,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.skip_previous, color: Colors.white70, size: 13),
                            Text(' CH-', style: TextStyle(color: Colors.white70, fontSize: 9.5)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    InkWell(
                      onTap: widget.onNext,
                      borderRadius: BorderRadius.circular(6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.white10,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Row(
                          children: [
                            Text('CH+ ', style: TextStyle(color: Colors.white70, fontSize: 9.5)),
                            Icon(Icons.skip_next, color: Colors.white70, size: 13),
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