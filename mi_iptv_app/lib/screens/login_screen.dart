import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import '../services/language_service.dart';
import 'admin_panel_screen.dart';

class LoginScreen extends StatefulWidget {
  final void Function({Widget? directScreen}) onLoginSuccess;

  const LoginScreen({
    super.key,
    required this.onLoginSuccess,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _pinController = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;
  String _hardwareId = 'Cargando...';
  String? _errorMessage;

  // Escucha en tiempo real si el usuario está en espera de liberación de hardware
  StreamSubscription<UserModel?>? _userRealtimeSub;
  String? _pendingUserId;

  @override
  void initState() {
    super.initState();
    _loadHardwareId();
    LanguageService.init();
    AuthService.initializeAdminAccount();
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _pinController.dispose();
    _userRealtimeSub?.cancel();
    super.dispose();
  }

  Future<void> _loadHardwareId() async {
    final hw = await AuthService.getDeviceHardwareId();
    if (mounted) {
      setState(() {
        _hardwareId = hw;
      });
    }
  }

  Future<void> _doLogin() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final res = await AuthService.login(
      username: _usernameController.text,
      password: _passwordController.text,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
    });

    if (res.isSuccess) {
      if (res.user?.isAdmin == true) {
        _showAdminChoiceDialog();
      } else {
        widget.onLoginSuccess();
      }
    } else if (res.status == AuthStatus.hardwareMismatch && res.user != null) {
      _showHardwareLockDialog(res.user!);
    } else {
      setState(() {
        _errorMessage = res.message;
      });
    }
  }

  void _showAdminChoiceDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.admin_panel_settings, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text('Modo Administrador', style: TextStyle(color: Colors.white, fontSize: 18)),
          ],
        ),
        content: const Text(
          'Has iniciado sesión como Administrador. ¿A dónde deseas ingresar?',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          OutlinedButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onLoginSuccess();
            },
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24),
            ),
            child: const Text('Ver TV / Canales', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onLoginSuccess(directScreen: const AdminPanelScreen());
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E5FF),
              foregroundColor: Colors.black,
            ),
            child: const Text('Panel de Clientes & HW', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showHardwareLockDialog(UserModel user) {
    _pendingUserId = user.id;

    _userRealtimeSub?.cancel();
    _userRealtimeSub = AuthService.listenToUserRealtime(user.id).listen((updatedUser) {
      if (updatedUser != null && updatedUser.registeredHardwareId == null) {
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
        _doLogin();
      }
    });

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0E1320),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
              side: const BorderSide(color: Color(0xFFFF5252), width: 1.5),
            ),
            title: const Row(
              children: [
                Icon(Icons.phonelink_lock, color: Color(0xFFFF5252), size: 28),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Dispositivo No Vinculado',
                    style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Por seguridad y regla de oro anti-piratería, tu cuenta está blindada para 1 solo dispositivo y actualmente está ligada a otro equipo.',
                    style: TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Tu ID de este equipo:', style: TextStyle(color: Colors.white54, fontSize: 11)),
                        const SizedBox(height: 3),
                        SelectableText(
                          _hardwareId,
                          style: const TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    '¿Cambiaste de teléfono o TV Box?',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                  ),
                  const SizedBox(height: 8),

                  ElevatedButton.icon(
                    onPressed: () async {
                      final ok = await AuthService.requestHardwareReset(user.id);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: ok ? const Color(0xFF00C853) : Colors.red,
                            content: Text(
                              ok
                                  ? '⚡ Solicitud enviada al Administrador. Cuando lo apruebe, la app entrará sola en vivo.'
                                  : 'Error enviando solicitud.',
                            ),
                          ),
                        );
                      }
                    },
                    icon: const Icon(Icons.bolt, color: Colors.black),
                    label: const Text(
                      '1-Toque: Solicitar Cambio Express',
                      style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD600),
                      minimumSize: const Size(double.infinity, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),

                  const SizedBox(height: 10),

                  OutlinedButton.icon(
                    onPressed: () {
                      _showPinInputDialog(user.id);
                    },
                    icon: const Icon(Icons.pin, color: Color(0xFF00E5FF)),
                    label: const Text(
                      'Ingresar PIN de 4 dígitos (WhatsApp)',
                      style: TextStyle(color: Color(0xFF00E5FF), fontSize: 12),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF00E5FF)),
                      minimumSize: const Size(double.infinity, 40),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  _userRealtimeSub?.cancel();
                  Navigator.pop(ctx);
                },
                child: const Text('Cerrar', style: TextStyle(color: Colors.white60)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showPinInputDialog(String userId) {
    _pinController.clear();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('PIN Express de Desbloqueo', style: TextStyle(color: Colors.white, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Ingresa el PIN de 4 dígitos que te envió el Administrador:',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _pinController,
              keyboardType: TextInputType.number,
              maxLength: 4,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: Colors.white.withOpacity(0.08),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: () async {
              final pin = _pinController.text.trim();
              if (pin.length != 4) return;
              Navigator.pop(ctx);

              final res = await AuthService.unlockWithExpressPin(userId: userId, pin: pin);
              if (res.isSuccess) {
                if (mounted && Navigator.canPop(context)) {
                  Navigator.pop(context);
                }
                widget.onLoginSuccess();
              } else {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(backgroundColor: Colors.red, content: Text(res.message)),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
            child: const Text('Validar PIN', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  /// Diálogo selector de idiomas
  void _showLanguageSelectorDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101726),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: const BorderSide(color: Color(0xFF00E5FF), width: 1.2),
        ),
        title: Row(
          children: [
            const Icon(Icons.language, color: Color(0xFF00E5FF)),
            const SizedBox(width: 8),
            Text(
              LanguageService.tr('select_language'),
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: LanguageService.supportedLanguages.map((lang) {
            final isSelected = LanguageService.currentLanguage.value == lang['code'];
            return ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              leading: Text(lang['flag'] ?? '', style: const TextStyle(fontSize: 22)),
              title: Text(
                lang['name'] ?? '',
                style: TextStyle(
                  color: isSelected ? const Color(0xFF00E5FF) : Colors.white,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
              trailing: isSelected
                  ? const Icon(Icons.check_circle, color: Color(0xFF00E5FF), size: 20)
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                await LanguageService.setLanguage(lang['code'] ?? 'es');
                if (mounted) setState(() {});
              },
            );
          }).toList(),
        ),
      ),
    );
  }

  /// Botón visual flotante del idioma actual
  Widget _buildLanguageButton() {
    final currentCode = LanguageService.currentLanguage.value;
    final currentLang = LanguageService.supportedLanguages.firstWhere(
      (l) => l['code'] == currentCode,
      orElse: () => LanguageService.supportedLanguages.first,
    );

    return InkWell(
      onTap: () => _showLanguageSelectorDialog(context),
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF101726),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(currentLang['flag'] ?? '🌐', style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 6),
            Text(
              currentLang['name'] ?? '',
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
            ),
            const Icon(Icons.arrow_drop_down, color: Color(0xFF00E5FF), size: 18),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: LanguageService.currentLanguage,
      builder: (context, currentLangCode, _) {
        return Scaffold(
          backgroundColor: const Color(0xFF080C14),
          body: SafeArea(
            child: Stack(
              children: [
                // BOTÓN SELECTOR DE IDIOMA EN LA ESQUINA SUPERIOR DERECHA
                Positioned(
                  top: 14,
                  right: 18,
                  child: _buildLanguageButton(),
                ),

                Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 20),
                          Container(
                            width: 76,
                            height: 76,
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF00E5FF), Color(0xFF0055FF)],
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                              ),
                              borderRadius: BorderRadius.circular(20),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFF00E5FF).withOpacity(0.35),
                                  blurRadius: 20,
                                  offset: const Offset(0, 6),
                                ),
                              ],
                            ),
                            child: const Icon(Icons.live_tv_rounded, size: 44, color: Colors.black),
                          ),

                          const SizedBox(height: 16),
                          Text(
                            LanguageService.tr('login_title'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            LanguageService.tr('login_subtitle'),
                            style: const TextStyle(color: Colors.white54, fontSize: 13),
                            textAlign: TextAlign.center,
                          ),

                          const SizedBox(height: 28),

                          Container(
                            padding: const EdgeInsets.all(20),
                            decoration: BoxDecoration(
                              color: const Color(0xFF101726),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: Colors.white.withOpacity(0.08)),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.4),
                                  blurRadius: 16,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (_errorMessage != null) ...[
                                  Container(
                                    padding: const EdgeInsets.all(12),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFF5252).withOpacity(0.15),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(color: const Color(0xFFFF5252).withOpacity(0.4)),
                                    ),
                                    child: Row(
                                      children: [
                                        const Icon(Icons.error_outline, color: Color(0xFFFF5252), size: 20),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _errorMessage!,
                                            style: const TextStyle(color: Color(0xFFFF5252), fontSize: 12),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                ],

                                Text(
                                  LanguageService.tr('username'),
                                  style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _usernameController,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF00E5FF)),
                                    hintText: 'user@ejemplo.com',
                                    hintStyle: const TextStyle(color: Colors.white30),
                                    filled: true,
                                    fillColor: Colors.white.withOpacity(0.04),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                ),

                                const SizedBox(height: 16),

                                Text(
                                  LanguageService.tr('password'),
                                  style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                TextField(
                                  controller: _passwordController,
                                  obscureText: _obscurePassword,
                                  style: const TextStyle(color: Colors.white),
                                  decoration: InputDecoration(
                                    prefixIcon: const Icon(Icons.lock_outline, color: Color(0xFF00E5FF)),
                                    suffixIcon: IconButton(
                                      icon: Icon(
                                        _obscurePassword ? Icons.visibility_off : Icons.visibility,
                                        color: Colors.white38,
                                      ),
                                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                    ),
                                    hintText: '••••••••',
                                    hintStyle: const TextStyle(color: Colors.white30),
                                    filled: true,
                                    fillColor: Colors.white.withOpacity(0.04),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                                  ),
                                ),

                                const SizedBox(height: 22),

                                ElevatedButton(
                                  onPressed: _isLoading ? null : _doLogin,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF00E5FF),
                                    foregroundColor: Colors.black,
                                    minimumSize: const Size(double.infinity, 48),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    elevation: 4,
                                  ),
                                  child: _isLoading
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2.5),
                                        )
                                      : Text(
                                          LanguageService.tr('btn_login'),
                                          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900, letterSpacing: 1),
                                        ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.04),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.fingerprint, color: Colors.white38, size: 16),
                                const SizedBox(width: 6),
                                Text(
                                  'Hardware ID: $_hardwareId',
                                  style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}