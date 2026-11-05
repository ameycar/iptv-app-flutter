import 'dart:ui'; // REQUERIDO PARA EL EFECTO BLUR ESTÉTICO
import 'package:flutter/material.dart';
import '../services/epg_service.dart';
import '../services/dvr_recording_service.dart';
import 'advanced_player_settings_sheet.dart';

class ZappingChannelOverlay extends StatefulWidget {
  final dynamic channel;
  final int channelIndex;
  final int totalChannels;
  final bool isPlaying;
  final bool isFullScreen;
  final bool isBehindLive;
  final bool isPlayingDvrRecording;
  final String? dvrRecordingTitle;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback? onOpenEpg;
  final VoidCallback? onToggleFullScreen;
  final VoidCallback? onRewind15s;
  final VoidCallback? onForward15s;
  final VoidCallback? onJumpToLive;
  final VoidCallback? onToggleRecord;

  const ZappingChannelOverlay({
    super.key,
    required this.channel,
    this.channelIndex = 0,
    this.totalChannels = 0,
    required this.isPlaying,
    this.isFullScreen = false,
    this.isBehindLive = false,
    this.isPlayingDvrRecording = false,
    this.dvrRecordingTitle,
    required this.onPlayPause,
    required this.onNext,
    required this.onPrevious,
    this.onOpenEpg,
    this.onToggleFullScreen,
    this.onRewind15s,
    this.onForward15s,
    this.onJumpToLive,
    this.onToggleRecord,
  });

  @override
  State<ZappingChannelOverlay> createState() => _ZappingChannelOverlayState();
}

class _ZappingChannelOverlayState extends State<ZappingChannelOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  
  bool _isManuallyBehindLive = false;

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

    return ValueListenableBuilder<int>(
      valueListenable: EpgService.epgUpdateNotifier,
      builder: (context, _, __) {
        final currentProg = EpgService.getCurrentProgram(channelName, groupCat);
        final nextProg = EpgService.getNextProgram(channelName, groupCat);
        final isSyncing = EpgService.isChannelSyncing(channelName);

        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            // AJUSTE: Empuja el overlay bien abajo (solo 6px de margen inferior)
            padding: const EdgeInsets.only(left: 8, right: 8, bottom: 6),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: BackdropFilter(
                // AJUSTE: Efecto cristal difuminado (Premium)
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: Container(
                  // AJUSTE: Padding interno ultracompacto
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF090D16).withOpacity(0.65), // Más transparente
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: const Color(0xFF00E5FF).withOpacity(0.20),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Fila 1: Número CH, Logo, Nombre del Canal
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF00E5FF).withOpacity(0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFF00E5FF).withOpacity(0.5),
                                width: 0.8,
                              ),
                            ),
                            child: Text(
                              widget.isPlayingDvrRecording ? 'DVR' : 'CH $channelNumber',
                              style: const TextStyle(
                                color: Color(0xFF00E5FF),
                                fontWeight: FontWeight.w900,
                                fontSize: 10, // REDUCIDO
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ClipRRect(
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 24, // LOGO MÁS PEQUEÑO
                              height: 24,
                              color: const Color(0xFF131A29),
                              child: logoUrl.isNotEmpty
                                  ? Image.network(
                                      logoUrl,
                                      fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const Icon(
                                        Icons.tv,
                                        color: Colors.white54,
                                        size: 14,
                                      ),
                                    )
                                  : const Icon(Icons.tv, color: Colors.white54, size: 14),
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
                                      fontSize: 13, // REDUCIDO
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
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
                                      fontSize: 8.5, // REDUCIDO
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
                              final Color badgeColor = widget.isPlayingDvrRecording
                                  ? const Color(0xFF9D4EDD)
                                  : (widget.isBehindLive || _isManuallyBehindLive)
                                      ? const Color(0xFFFFB703)
                                      : (isSyncing
                                          ? const Color(0xFFFFB703)
                                          : const Color(0xFFFF1744));

                              final String badgeLabel = widget.isPlayingDvrRecording
                                  ? 'GRABACIÓN'
                                  : (widget.isBehindLive || _isManuallyBehindLive)
                                      ? 'DIFERIDO'
                                      : (isSyncing ? 'SINCRONIZANDO...' : 'EN VIVO');

                              final bool isClickable = widget.isBehindLive || widget.isPlayingDvrRecording || _isManuallyBehindLive;

                              return Focus(
                                canRequestFocus: isClickable,
                                child: Builder(
                                  builder: (context) {
                                    final hasFocus = Focus.of(context).hasFocus;
                                    return GestureDetector(
                                      onTap: isClickable
                                          ? () {
                                              if (widget.onJumpToLive != null) {
                                                widget.onJumpToLive!();
                                                setState(() {
                                                  _isManuallyBehindLive = false;
                                                });
                                              }
                                            }
                                          : null,
                                      child: AnimatedContainer(
                                        duration: const Duration(milliseconds: 150),
                                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: hasFocus 
                                              ? badgeColor 
                                              : badgeColor.withOpacity(0.2 + (_pulseController.value * 0.25)),
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: hasFocus ? Colors.white : badgeColor.withOpacity(0.6 + (_pulseController.value * 0.4)),
                                            width: hasFocus ? 1.5 : 0.8,
                                          ),
                                          boxShadow: hasFocus ? [BoxShadow(color: badgeColor.withOpacity(0.8), blurRadius: 10)] : [],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(Icons.circle, color: hasFocus ? Colors.black : badgeColor, size: 6),
                                            const SizedBox(width: 3),
                                            Text(
                                              badgeLabel,
                                              style: TextStyle(
                                                color: hasFocus ? Colors.black : Colors.white,
                                                fontSize: 8.5,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  }
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
                          
                          Focus(
                            child: Builder(
                              builder: (context) {
                                final hasFocus = Focus.of(context).hasFocus;
                                return AnimatedContainer(
                                  duration: const Duration(milliseconds: 150),
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(color: hasFocus ? const Color(0xFF00E5FF) : Colors.transparent, width: 2),
                                    boxShadow: hasFocus ? [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.8), blurRadius: 12)] : [],
                                  ),
                                  child: IconButton(
                                    icon: Icon(
                                      widget.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled,
                                      color: hasFocus ? Colors.white : const Color(0xFF00E5FF),
                                      size: 26, // REDUCIDO
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(),
                                    onPressed: widget.onPlayPause,
                                  ),
                                );
                              }
                            ),
                          ),
                          
                          if (widget.onToggleFullScreen != null) ...[
                            const SizedBox(width: 6),
                            Focus(
                              child: Builder(
                                builder: (context) {
                                  final hasFocus = Focus.of(context).hasFocus;
                                  return InkWell(
                                    onTap: widget.onToggleFullScreen,
                                    borderRadius: BorderRadius.circular(6),
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 150),
                                      padding: const EdgeInsets.all(5),
                                      decoration: BoxDecoration(
                                        color: hasFocus ? const Color(0xFFC77DFF) : const Color(0xFF7B2CBF).withOpacity(0.35),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: hasFocus ? Colors.white : const Color(0xFFC77DFF), width: hasFocus ? 1.5 : 0.8),
                                        boxShadow: hasFocus ? [BoxShadow(color: const Color(0xFFC77DFF).withOpacity(0.8), blurRadius: 10)] : [],
                                      ),
                                      child: Icon(
                                        widget.isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                                        color: hasFocus ? Colors.black : Colors.white,
                                        size: 16, // REDUCIDO
                                      ),
                                    ),
                                  );
                                }
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6), // Menos espacio

                      // Fila 2: Programa y Horario
                      Row(
                        children: [
                          Icon(
                            widget.isPlayingDvrRecording ? Icons.fiber_smart_record : Icons.play_arrow,
                            color: const Color(0xFF00E5FF),
                            size: 12,
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: Text(
                              widget.isPlayingDvrRecording
                                  ? (widget.dvrRecordingTitle ?? currentProg.title)
                                  : currentProg.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 11, // REDUCIDO
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            widget.isPlayingDvrRecording ? 'DESDE INICIO' : currentProg.timeFormatted,
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 10, // REDUCIDO
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4), // Menos espacio

                      // Barra de Progreso super delgada
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: currentProg.progress.clamp(0.0, 1.0),
                          backgroundColor: Colors.white12,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            isSyncing ? const Color(0xFFFFB703) : const Color(0xFF00E5FF),
                          ),
                          minHeight: 2.5, // MUY DELGADA Y ELEGANTE
                        ),
                      ),
                      const SizedBox(height: 8), // Menos espacio

                      // Fila 3: Controles Timeshift y Opciones
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            if (widget.onRewind15s != null) ...[
                              _buildCompactControlChip(
                                icon: Icons.replay_10,
                                label: '-15s',
                                borderColor: Colors.white24,
                                bgColor: Colors.white10,
                                onTap: () {
                                  widget.onRewind15s!();
                                  setState(() {
                                    _isManuallyBehindLive = true;
                                  });
                                },
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (widget.onForward15s != null) ...[
                              _buildCompactControlChip(
                                icon: Icons.forward_10,
                                label: '+15s',
                                borderColor: Colors.white24,
                                bgColor: Colors.white10,
                                onTap: () {
                                  widget.onForward15s!();
                                },
                              ),
                              const SizedBox(width: 6),
                            ],
                            if ((widget.isBehindLive || widget.isPlayingDvrRecording || _isManuallyBehindLive) &&
                                widget.onJumpToLive != null) ...[
                              _buildCompactControlChip(
                                icon: Icons.bolt,
                                label: 'IR A VIVO',
                                borderColor: const Color(0xFF00E5FF),
                                bgColor: const Color(0xFF00E5FF).withOpacity(0.22),
                                iconColor: const Color(0xFF00E5FF),
                                onTap: () {
                                  widget.onJumpToLive!();
                                  setState(() {
                                    _isManuallyBehindLive = false;
                                  });
                                },
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (widget.onToggleRecord != null && !widget.isPlayingDvrRecording) ...[
                              ValueListenableBuilder<bool>(
                                valueListenable: DvrRecordingService.isRecordingNotifier,
                                builder: (context, isRec, _) {
                                  return _buildCompactControlChip(
                                    icon: isRec ? Icons.stop_circle : Icons.fiber_manual_record,
                                    label: isRec ? 'STOP' : 'REC',
                                    borderColor: const Color(0xFFFF1744),
                                    bgColor: isRec
                                        ? const Color(0xFFFF1744).withOpacity(0.40)
                                        : const Color(0xFFFF1744).withOpacity(0.16),
                                    iconColor: const Color(0xFFFF1744),
                                    onTap: widget.onToggleRecord!,
                                  );
                                },
                              ),
                              const SizedBox(width: 6),
                            ],
                            if (widget.onOpenEpg != null) ...[
                              _buildCompactControlChip(
                                icon: Icons.calendar_month,
                                label: 'EPG',
                                borderColor: const Color(0xFFC77DFF).withOpacity(0.6),
                                bgColor: const Color(0xFF7B2CBF).withOpacity(0.35),
                                iconColor: const Color(0xFFFFB703),
                                onTap: widget.onOpenEpg!,
                              ),
                              const SizedBox(width: 6),
                            ],
                            _buildCompactControlChip(
                              icon: Icons.closed_caption,
                              label: 'CC',
                              borderColor: Colors.white24,
                              bgColor: Colors.white10,
                              onTap: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('CC: Los subtítulos automáticos se activarán si el canal los incluye.'),
                                    duration: Duration(seconds: 2),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 6),
                            _buildCompactControlChip(
                              icon: Icons.settings_input_component,
                              label: 'ADV',
                              borderColor: const Color(0xFF00E5FF).withOpacity(0.6),
                              bgColor: const Color(0xFF00E5FF).withOpacity(0.2),
                              iconColor: const Color(0xFF00E5FF),
                              onTap: () {
                                showModalBottomSheet(
                                  context: context,
                                  backgroundColor: Colors.transparent,
                                  isScrollControlled: true,
                                  builder: (context) => const AdvancedPlayerSettingsSheet(),
                                );
                              },
                            ),
                            const SizedBox(width: 6),
                            _buildCompactControlChip(
                              icon: Icons.skip_previous,
                              label: 'CH-',
                              borderColor: Colors.white12,
                              bgColor: Colors.white10,
                              onTap: () {
                                widget.onPrevious();
                                setState(() { _isManuallyBehindLive = false; }); 
                              },
                            ),
                            const SizedBox(width: 6),
                            _buildCompactControlChip(
                              icon: Icons.skip_next,
                              label: 'CH+',
                              borderColor: Colors.white12,
                              bgColor: Colors.white10,
                              onTap: () {
                                widget.onNext();
                                setState(() { _isManuallyBehindLive = false; }); 
                              },
                            ),
                            const SizedBox(width: 10),
                            Text(
                              'Sig: ${nextProg.title}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Colors.white54, fontSize: 9.5), // REDUCIDO
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // BOTÓN "CHIP" ESTILIZADO Y ULTRA COMPACTO
  Widget _buildCompactControlChip({
    required IconData icon,
    required String label,
    required Color borderColor,
    required Color bgColor,
    required VoidCallback onTap,
    Color iconColor = Colors.white70,
  }) {
    return Focus(
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          
          final effectiveBgColor = hasFocus ? Colors.white : bgColor;
          final effectiveBorderColor = hasFocus ? const Color(0xFF00E5FF) : borderColor;
          final effectiveIconColor = hasFocus ? Colors.black : iconColor;
          final effectiveTextColor = hasFocus ? Colors.black : Colors.white;

          return InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              // AJUSTE: Padding mínimo y bordes ovalados para parecer "pastillas" pequeñas
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: effectiveBgColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: effectiveBorderColor, width: hasFocus ? 1.5 : 0.8),
                boxShadow: hasFocus ? [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.6), blurRadius: 8)] : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: effectiveIconColor, size: 12), // ÍCONO MINIATURA
                  const SizedBox(width: 3),
                  Text(
                    label,
                    style: TextStyle(
                      color: effectiveTextColor,
                      fontSize: 9.5, // TEXTO MINIATURA Y ELEGANTE
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      ),
    );
  }
}