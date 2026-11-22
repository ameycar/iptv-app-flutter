import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OnboardingTutorialModal {
  static const String _seenKey = 'ameycar_onboarding_seen_v1';

  /// Se llama al iniciar HomeScreen o TvDashboardScreen.
  /// Solo muestra el tutorial automáticamente si es la primera vez en el dispositivo.
  static Future<void> showIfFirstTime(
    BuildContext context, {
    required bool isTv,
    VoidCallback? onOpenM3uManager,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final alreadySeen = prefs.getBool(_seenKey) ?? false;
      if (alreadySeen || !context.mounted) return;

      await prefs.setBool(_seenKey, true);
      if (!context.mounted) return;

      await show(
        context,
        isTv: isTv,
        onOpenM3uManager: onOpenM3uManager,
      );
    } catch (_) {}
  }

  /// Abre el tutorial manualmente en cualquier momento (desde Configuración).
  static Future<void> show(
    BuildContext context, {
    required bool isTv,
    VoidCallback? onOpenM3uManager,
  }) async {
    await showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withOpacity(0.84),
      builder: (ctx) => _OnboardingTutorialDialog(
        isTv: isTv,
        onOpenM3uManager: onOpenM3uManager,
      ),
    );
  }
}

class _OnboardingTutorialDialog extends StatefulWidget {
  final bool isTv;
  final VoidCallback? onOpenM3uManager;

  const _OnboardingTutorialDialog({
    required this.isTv,
    this.onOpenM3uManager,
  });

  @override
  State<_OnboardingTutorialDialog> createState() =>
      _OnboardingTutorialDialogState();
}

class _OnboardingTutorialDialogState extends State<_OnboardingTutorialDialog> {
  int _step = 0;

  // Sin signos < > anidados para evitar recortes al pegar en vscode.dev
  List get _pages => [
        {
          'badge': 'PASO 1 DE 3 • BIENVENIDO',
          'icon': Icons.live_tv_rounded,
          'accent': const Color(0xFF00E5FF),
          'title': 'Tu Reproductor IPTV de Élite',
          'description':
              'AMEYCAR TV es un reproductor multimedia ultrarrápido diseñado para tus propias listas M3U y enlaces legales compatibles.\n\nNo almacenamos ni vendemos contenido protegido; tú tienes el control total de tus fuentes.',
          'tip':
              '💡 Si aún no tienes lista propia, ya tienes canales de prueba cargados para explorar la app al instante.',
        },
        {
          'badge': 'PASO 2 DE 3 • TUS LISTAS M3U',
          'icon': Icons.cloud_sync_rounded,
          'accent': const Color(0xFFC77DFF),
          'title': 'Carga en Celular, Mira en tu TV',
          'description':
              'Pegar enlaces largos con el control remoto del televisor es incómodo. Por eso tus listas M3U se sincronizan en la nube con tu cuenta:\n\n1. Agrega tu enlace M3U desde el celular o desde Ajustes.\n2. Al abrir tu Smart TV con la misma cuenta, tus canales y películas aparecen solos.',
          'tip':
              '⚡ Puedes guardar hasta 5 listas M3U distintas y cambiar entre ellas con un toque.',
        },
        {
          'badge': 'PASO 3 DE 3 • CONTROLES INTELIGENTES',
          'icon': widget.isTv
              ? Icons.settings_remote_rounded
              : Icons.touch_app_rounded,
          'accent': const Color(0xFFFFD600),
          'title': widget.isTv
              ? 'Domina tu Control Remoto'
              : 'Gestos y Herramientas VIP',
          'description': widget.isTv
              ? '• Flecha Izquierda (◀): Abre el menú lateral (Televisión, Cine & Series, Traductor CC y Ajustes).\n• Flechas Arriba / Abajo (▲▼): Abre el carrusel rápido de canales.\n• Botón OK / Enter: Muestra controles de pausa, retroceso, DVR y guía EPG.'
              : '• Desliza Arriba / Abajo sobre el video para cambiar de canal al instante.\n• Doble toque en el video para pantalla completa.\n• Usa Mando TV & Cast para controlar tu Smart TV desde el celular.',
          'tip':
              '🎓 Puedes volver a abrir esta guía cuando quieras desde Configuración > Ver Tutorial.',
        },
      ];

  void _nextOrFinish() {
    if (_step < _pages.length - 1) {
      setState(() => _step++);
    } else {
      Navigator.of(context).pop();
    }
  }

  void _prevStep() {
    if (_step > 0) {
      setState(() => _step--);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map page = _pages[_step] as Map;
    final Color accent = page['accent'] as Color;
    final bool isLast = _step == _pages.length - 1;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): _nextOrFinish,
        const SingleActivator(LogicalKeyboardKey.arrowLeft): _prevStep,
      },
      child: Dialog(
        backgroundColor: const Color(0xFF0F172A),
        insetPadding: EdgeInsets.symmetric(
          horizontal: widget.isTv ? 120 : 18,
          vertical: 24,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: accent.withOpacity(0.65), width: 1.6),
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.isTv ? 680 : 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.16),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: accent.withOpacity(0.5)),
                      ),
                      child: Text(
                        page['badge'] as String,
                        style: TextStyle(
                          color: accent,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text(
                        'Saltar',
                        style: TextStyle(
                          color: Colors.white54,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: accent.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: accent.withOpacity(0.45)),
                      ),
                      child: Icon(
                        page['icon'] as IconData,
                        color: accent,
                        size: widget.isTv ? 34 : 28,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        page['title'] as String,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: widget.isTv ? 22 : 18.5,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  page['description'] as String,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.88),
                    fontSize: widget.isTv ? 15 : 13.5,
                    height: 1.48,
                  ),
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFF162036),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    page['tip'] as String,
                    style: TextStyle(
                      color: const Color(0xFF00E5FF),
                      fontSize: widget.isTv ? 13.5 : 12,
                      fontWeight: FontWeight.w600,
                      height: 1.35,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Row(
                      children: List.generate(_pages.length, (i) {
                        final active = i == _step;
                        return AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          margin: const EdgeInsets.only(right: 6),
                          width: active ? 22 : 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: active ? accent : Colors.white24,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        );
                      }),
                    ),
                    const Spacer(),
                    if (_step > 0) ...[
                      TextButton(
                        onPressed: _prevStep,
                        child: const Text(
                          'Anterior',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (isLast && widget.onOpenM3uManager != null) ...[
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFF00E5FF),
                          side: const BorderSide(color: Color(0xFF00E5FF)),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          widget.onOpenM3uManager?.call();
                        },
                        icon: const Icon(Icons.playlist_add, size: 18),
                        label: const Text(
                          'Cargar Lista M3U',
                          style: TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    ElevatedButton(
                      autofocus: true,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: accent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      onPressed: _nextOrFinish,
                      child: Text(
                        isLast ? '¡Empezar!' : 'Siguiente',
                        style: const TextStyle(
                          fontWeight: FontWeight.w900,
                          fontSize: 13.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}