import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class PinDialog extends StatefulWidget {
  final String title;
  const PinDialog({super.key, required this.title});

  @override
  State<PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<PinDialog> {
  String _pin = '';

  void _submit() {
    if (_pin.length == 4) {
      Navigator.pop(context, _pin); // Devuelve el PIN ingresado
    } else {
      // Vibración de error si intenta enviar incompleto
      HapticFeedback.heavyImpact();
    }
  }

  void _addDigit(String digit) {
    if (_pin.length < 4) {
      setState(() {
        _pin += digit;
      });
      HapticFeedback.lightImpact();
      
      // Auto-submit inteligente al completar los 4 dígitos
      if (_pin.length == 4) {
        Future.delayed(const Duration(milliseconds: 250), _submit);
      }
    }
  }

  void _removeDigit() {
    if (_pin.isNotEmpty) {
      setState(() {
        _pin = _pin.substring(0, _pin.length - 1);
      });
      HapticFeedback.mediumImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Center(
        child: Container(
          width: 400, // Ancho fijo para mantener estética en TV y Móvil
          decoration: BoxDecoration(
            color: const Color(0xFF0D1324),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00E5FF).withOpacity(0.2),
                blurRadius: 30,
                spreadRadius: -5,
              )
            ],
          ),
          padding: const EdgeInsets.all(28.0),
          child: FocusTraversalGroup(
            policy: WidgetOrderTraversalPolicy(),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ÍCONO Y TÍTULO
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF7C2CBF).withOpacity(0.2),
                    border: Border.all(color: const Color(0xFF7C2CBF)),
                  ),
                  child: const Icon(Icons.lock_rounded, color: Color(0xFF00E5FF), size: 36),
                ),
                const SizedBox(height: 16),
                Text(
                  widget.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Ingresa tu PIN de 4 dígitos',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white60, fontSize: 13),
                ),
                const SizedBox(height: 24),

                // INDICADORES VISUALES DEL PIN (Puntitos)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(4, (index) {
                    final isFilled = index < _pin.length;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      margin: const EdgeInsets.symmetric(horizontal: 10),
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isFilled ? const Color(0xFF00E5FF) : const Color(0xFF070A10),
                        border: Border.all(
                          color: isFilled ? const Color(0xFF00E5FF) : Colors.white24,
                          width: 2,
                        ),
                        boxShadow: isFilled
                            ? [const BoxShadow(color: Color(0xFF00E5FF), blurRadius: 10)]
                            : [],
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 32),

                // PAD NUMÉRICO EN PANTALLA (Navegable con cruceta)
                Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildNumButton('1', autofocus: true), // Foco inicial aquí
                        _buildNumButton('2'),
                        _buildNumButton('3'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildNumButton('4'),
                        _buildNumButton('5'),
                        _buildNumButton('6'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _buildNumButton('7'),
                        _buildNumButton('8'),
                        _buildNumButton('9'),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        // Botón invisible para alinear el 0 al centro
                        const SizedBox(width: 65, height: 65),
                        _buildNumButton('0'),
                        _buildIconButton(Icons.backspace_rounded, _removeDigit),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 32),

                // BOTONES DE ACCIÓN (Originales)
                Row(
                  children: [
                    Expanded(
                      child: _buildActionBtn(
                        'Cancelar',
                        isPrimary: false,
                        onTap: () => Navigator.pop(context, null),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildActionBtn(
                        'Entrar',
                        isPrimary: true,
                        onTap: _submit,
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

  // CONSTRUCTOR DEL BOTÓN NUMÉRICO
  Widget _buildNumButton(String digit, {bool autofocus = false}) {
    return Builder(builder: (context) {
      return Focus(
        autofocus: autofocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA ||
                  event.logicalKey.keyLabel == digit)) { // También detecta si presionan el número en el teclado de la PC
            _addDigit(digit);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: () => _addDigit(digit),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 65,
              height: 65,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasFocus ? const Color(0xFF00E5FF) : const Color(0xFF131B2E),
                border: Border.all(
                  color: hasFocus ? Colors.white : Colors.white12,
                  width: hasFocus ? 2 : 1,
                ),
                boxShadow: hasFocus
                    ? [const BoxShadow(color: Color(0xFF00E5FF), blurRadius: 15)]
                    : [],
              ),
              child: Text(
                digit,
                style: TextStyle(
                  color: hasFocus ? Colors.black : Colors.white,
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          );
        }),
      );
    });
  }

  // CONSTRUCTOR DEL BOTÓN DE BORRAR (ÍCONO)
  Widget _buildIconButton(IconData icon, VoidCallback onTap) {
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA ||
                  event.logicalKey == LogicalKeyboardKey.backspace)) { // Detecta tecla Backspace de PC
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 65,
              height: 65,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hasFocus ? Colors.redAccent : Colors.transparent,
                border: Border.all(
                  color: hasFocus ? Colors.white : Colors.transparent,
                  width: hasFocus ? 2 : 0,
                ),
                boxShadow: hasFocus
                    ? [const BoxShadow(color: Colors.redAccent, blurRadius: 15)]
                    : [],
              ),
              child: Icon(
                icon,
                color: hasFocus ? Colors.white : Colors.white54,
                size: 28,
              ),
            ),
          );
        }),
      );
    });
  }

  // CONSTRUCTOR DE LOS BOTONES DE ACCIÓN (Cancelar / Entrar)
  Widget _buildActionBtn(String text, {required bool isPrimary, required VoidCallback onTap}) {
    return Builder(builder: (context) {
      return Focus(
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(vertical: 14),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hasFocus
                    ? (isPrimary ? const Color(0xFF00E5FF) : Colors.white24)
                    : (isPrimary ? const Color(0xFF00E5FF) : Colors.transparent),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasFocus
                      ? Colors.white
                      : (isPrimary ? Colors.transparent : Colors.white24),
                  width: hasFocus ? 2 : 1,
                ),
              ),
              child: Text(
                text,
                style: TextStyle(
                  color: hasFocus
                      ? (isPrimary ? Colors.black : Colors.white)
                      : (isPrimary ? Colors.black : Colors.white60),
                  fontWeight: FontWeight.w900,
                  fontSize: 15,
                ),
              ),
            ),
          );
        }),
      );
    });
  }
}