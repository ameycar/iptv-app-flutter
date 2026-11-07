import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class FocusableTvCard extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final double focusedScale;
  final Color focusedBorderColor;
  final EdgeInsetsGeometry padding;

  const FocusableTvCard({
    super.key,
    required this.child,
    required this.onTap,
    this.focusedScale = 1.08,
    this.focusedBorderColor = const Color(0xFF00E5FF),
    this.padding = EdgeInsets.zero,
  });

  @override
  State<FocusableTvCard> createState() => _FocusableTvCardState();
}

class _FocusableTvCardState extends State<FocusableTvCard> {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: widget.padding,
      child: Focus(
        onKeyEvent: (node, event) {
          // Captura el botón "OK" / "Enter" del control remoto de la TV
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            
            return GestureDetector(
              onTap: widget.onTap,
              child: AnimatedScale(
                scale: hasFocus ? widget.focusedScale : 1.0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutCubic,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasFocus ? widget.focusedBorderColor : Colors.transparent,
                      width: hasFocus ? 3.0 : 0.0,
                    ),
                    boxShadow: hasFocus
                        ? [
                            BoxShadow(
                              color: widget.focusedBorderColor.withOpacity(0.6),
                              blurRadius: 15,
                              spreadRadius: 2,
                            )
                          ]
                        : [],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(9),
                    child: widget.child,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}