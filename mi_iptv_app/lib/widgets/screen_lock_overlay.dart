import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class ScreenLockOverlay extends StatefulWidget {
  final VoidCallback onUnlock;

  const ScreenLockOverlay({
    super.key,
    required this.onUnlock,
  });

  @override
  State<ScreenLockOverlay> createState() => _ScreenLockOverlayState();
}

class _ScreenLockOverlayState extends State<ScreenLockOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _holdController;
  bool _showHint = true;
  bool _isHolding = false;
  Timer? _hideTimer;

  @override
  void initState() {
    super.initState();
    _holdController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          HapticFeedback.mediumImpact();
          widget.onUnlock();
        }
      });
    _scheduleHide();
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && !_isHolding) {
        setState(() => _showHint = false);
      }
    });
  }

  void _revealHint() {
    if (!mounted) return;
    if (!_showHint) {
      setState(() => _showHint = true);
    }
    _scheduleHide();
  }

  void _startHold() {
    _hideTimer?.cancel();
    setState(() {
      _showHint = true;
      _isHolding = true;
    });
    _holdController.forward();
  }

  void _cancelHold() {
    if (_holdController.status == AnimationStatus.completed) return;
    _holdController.reverse();
    if (mounted) {
      setState(() => _isHolding = false);
    }
    _scheduleHide();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _holdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _revealHint,
      onDoubleTap: _revealHint,
      onVerticalDragStart: (_) => _revealHint(),
      onHorizontalDragStart: (_) => _revealHint(),
      child: Container(
        color: Colors.transparent,
        child: SafeArea(
          child: Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 16),
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 220),
                opacity: _showHint ? 1.0 : 0.0,
                child: IgnorePointer(
                  ignoring: !_showHint,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) => _startHold(),
                    onTapUp: (_) => _cancelHold(),
                    onTapCancel: _cancelHold,
                    child: AnimatedBuilder(
                      animation: _holdController,
                      builder: (context, _) {
                        final progress = _holdController.value;
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 9,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xE60B1020),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(
                              color: _isHolding
                                  ? const Color(0xFF00E5FF)
                                  : const Color(0xFFFFD600),
                              width: 1.5,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black54,
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 22,
                                height: 22,
                                child: Stack(
                                  alignment: Alignment.center,
                                  children: [
                                    CircularProgressIndicator(
                                      value: progress,
                                      strokeWidth: 2.5,
                                      backgroundColor: Colors.white24,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                        Color(0xFF00E5FF),
                                      ),
                                    ),
                                    Icon(
                                      _isHolding
                                          ? Icons.lock_open_rounded
                                          : Icons.lock_rounded,
                                      color: _isHolding
                                          ? const Color(0xFF00E5FF)
                                          : const Color(0xFFFFD600),
                                      size: 13,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 9),
                              Text(
                                _isHolding
                                    ? 'Desbloqueando...'
                                    : 'Bloqueado • Mantén pulsado',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}