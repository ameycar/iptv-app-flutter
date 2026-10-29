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
          child: Container(
            margin: const EdgeInsets.all(8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                // Fila 1: Número CH, Logo, Nombre del Canal, Badge EN VIVO / DVR, Play/Pause y Pantalla Completa
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
                        widget.isPlayingDvrRecording ? 'DVR' : 'CH $channelNumber',
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
                        final Color badgeColor = widget.isPlayingDvrRecording
                            ? const Color(0xFF9D4EDD)
                            : widget.isBehindLive
                                ? const Color(0xFFFFB703)
                                : (isSyncing
                                    ? const Color(0xFFFFB703)
                                    : const Color(0xFFFF1744));

                        final String badgeLabel = widget.isPlayingDvrRecording
                            ? 'GRABACIÓN'
                            : widget.isBehindLive
                                ? 'DIFERIDO'
                                : (isSyncing ? 'SINCRONIZANDO...' : 'EN VIVO');

                        return GestureDetector(
                          onTap: (widget.isBehindLive || widget.isPlayingDvrRecording)
                              ? widget.onJumpToLive
                              : null,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(
                                alpha: 0.2 + (_pulseController.value * 0.25),
                              ),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: badgeColor.withValues(
                                  alpha: 0.6 + (_pulseController.value * 0.4),
                                ),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.circle, color: badgeColor, size: 6),
                                const SizedBox(width: 3),
                                Text(
                                  badgeLabel,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 8.5,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
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
                const SizedBox(height: 5),

                // Fila 2: Programa Actual (o título de grabación DVR) y Horario
                Row(
                  children: [
                    Icon(
                      widget.isPlayingDvrRecording ? Icons.fiber_smart_record : Icons.play_arrow,
                      color: const Color(0xFF00E5FF),
                      size: 14,
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
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.isPlayingDvrRecording ? 'DESDE INICIO' : currentProg.timeFormatted,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),

                // Barra de Progreso
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: currentProg.progress.clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      isSyncing ? const Color(0xFFFFB703) : const Color(0xFF00E5FF),
                    ),
                    minHeight: 3,
                  ),
                ),
                const SizedBox(height: 6),

                // Fila 3: Controles Timeshift (-15s / +15s / IR A VIVO) + REC + EPG + CH- / CH+
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
                          onTap: widget.onRewind15s!,
                        ),
                        const SizedBox(width: 5),
                      ],
                      if (widget.onForward15s != null) ...[
                        _buildCompactControlChip(
                          icon: Icons.forward_10,
                          label: '+15s',
                          borderColor: Colors.white24,
                          bgColor: Colors.white10,
                          onTap: widget.onForward15s!,
                        ),
                        const SizedBox(width: 5),
                      ],
                      if ((widget.isBehindLive || widget.isPlayingDvrRecording) &&
                          widget.onJumpToLive != null) ...[
                        _buildCompactControlChip(
                          icon: Icons.bolt,
                          label: 'IR A VIVO',
                          borderColor: const Color(0xFF00E5FF),
                          bgColor: const Color(0xFF00E5FF).withValues(alpha: 0.22),
                          iconColor: const Color(0xFF00E5FF),
                          onTap: widget.onJumpToLive!,
                        ),
                        const SizedBox(width: 5),
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
                                  ? const Color(0xFFFF1744).withValues(alpha: 0.40)
                                  : const Color(0xFFFF1744).withValues(alpha: 0.16),
                              iconColor: const Color(0xFFFF1744),
                              onTap: widget.onToggleRecord!,
                            );
                          },
                        ),
                        const SizedBox(width: 5),
                      ],
                      if (widget.onOpenEpg != null) ...[
                        _buildCompactControlChip(
                          icon: Icons.calendar_month,
                          label: 'EPG',
                          borderColor: const Color(0xFFC77DFF).withValues(alpha: 0.6),
                          bgColor: const Color(0xFF7B2CBF).withValues(alpha: 0.35),
                          iconColor: const Color(0xFFFFB703),
                          onTap: widget.onOpenEpg!,
                        ),
                        const SizedBox(width: 5),
                      ],
_buildCompactControlChip(
                     icon: Icons.settings_input_component,
                     label: 'ADV',
                     borderColor: const Color(0xFF00E5FF).withValues(alpha: 0.6),
                     bgColor: const Color(0xFF00E5FF).withValues(alpha: 0.2),
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
                   const SizedBox(width: 5),
                      
                      _buildCompactControlChip(
                        icon: Icons.skip_previous,
                        label: 'CH-',
                        borderColor: Colors.white12,
                        bgColor: Colors.white10,
                        onTap: widget.onPrevious,
                      ),
                      const SizedBox(width: 5),
                      _buildCompactControlChip(
                        icon: Icons.skip_next,
                        label: 'CH+',
                        borderColor: Colors.white12,
                        bgColor: Colors.white10,
                        onTap: widget.onNext,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Sig: ${nextProg.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white60, fontSize: 9.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCompactControlChip({
    required IconData icon,
    required String label,
    required Color borderColor,
    required Color bgColor,
    required VoidCallback onTap,
    Color iconColor = Colors.white70,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: iconColor, size: 12.5),
            const SizedBox(width: 3),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9.5,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}