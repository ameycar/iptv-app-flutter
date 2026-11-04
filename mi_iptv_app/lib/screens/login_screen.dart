import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart'; 
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

    final isTvDevice = MediaQuery.of(context).size.width > 900; 
    final deviceTypeName = isTvDevice ? 'Smart TV / TV Box' : 'Celular / Móvil';

    final res = await AuthService.login(
      username: _usernameController.text,
      password: _passwordController.text,
    );

    if (!mounted) return;

    if (res.isSuccess && res.user != null && !res.user!.isAdmin) {
      final familyId = res.user!.effectiveFamilyId;
      final canAccess = await AuthService.validateDeviceScreenLimit(familyId, deviceTypeName);
      
      if (!canAccess) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Límite alcanzado: Ya tienes el cupo máximo de pantallas conectadas (1 Celular y 1 TV). Cierra sesión en el otro equipo para ingresar aquí.';
        });
        return;
      }
    }

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

  void _openSupportMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.support_agent, color: Color(0xFF00E5FF), size: 28),
                  SizedBox(width: 10),
                  Text(
                    'Soporte Técnico Directo',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Selecciona el motivo de tu consulta. Te atenderemos vía WhatsApp.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 20),
              
              _buildSupportOption(
                icon: Icons.autorenew,
                title: 'Renovar o recuperar mi servicio',
                subtitle: 'Si tu proveedor anterior ya no responde',
                message: 'Hola Ameycar TV, mi proveedor original ya no me atiende y deseo renovar mi perfil directamente con ustedes.',
              ),
              const SizedBox(height: 10),
              _buildSupportOption(
                icon: Icons.wifi_tethering_error_rounded,
                title: 'Reportar problema de conexión',
                subtitle: 'Fallas técnicas o cortes de señal',
                message: 'Hola equipo, estoy experimentando fallas de conexión en mi dispositivo.',
              ),
              const SizedBox(height: 10),
              _buildSupportOption(
                icon: Icons.add_to_queue,
                title: 'Solicitar acceso nuevo',
                subtitle: 'Quiero contratar el servicio',
                message: 'Hola, me interesa contratar un plan para ingresar a la plataforma.',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSupportOption({required IconData icon, required String title, required String subtitle, required String message}) {
    // CAMBIO: ElevatedButton nativo para soportar D-Pad en el menú WhatsApp
    return ElevatedButton(
      onPressed: () async {
        Navigator.pop(context); 
        final phoneNumber = "51905823660"; 
        final url = Uri.parse("whatsapp://send?phone=$phoneNumber&text=${Uri.encodeComponent(message)}");
        
        try {
          if (await canLaunchUrl(url)) {
            await launchUrl(url);
          } else {
             final webUrl = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(message)}");
             await launchUrl(webUrl, mode: LaunchMode.externalApplication);
          }
        } catch (e) {
          debugPrint("Error al abrir WhatsApp: $e");
        }
      },
      style: ButtonStyle(
        padding: MaterialStateProperty.all(const EdgeInsets.all(12)),
        backgroundColor: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.focused)) return const Color(0xFF00E5FF);
          return const Color(0xFF1E293B);
        }),
        shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
        side: MaterialStateProperty.resolveWith((states) {
          if (states.contains(MaterialState.focused)) return const BorderSide(color: Colors.white, width: 2);
          return const BorderSide(color: Colors.white10, width: 1);
        }),
        elevation: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? 10.0 : 0.0),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Colors.black.withOpacity(0.2), shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                Text(subtitle, style: const TextStyle(color: Colors.white70, fontSize: 11)),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_ios, color: Colors.white54, size: 14),
        ],
      ),
    );
  }

  void _showRegisterModal() {
    final nameCtrl = TextEditingController();
    final lastNameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    bool isRegistering = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Padding(
          padding: EdgeInsets.only(
            left: 20, right: 20, top: 20,
            bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.badge, color: Color(0xFF00E5FF), size: 40),
              const SizedBox(height: 10),
              const Text(
                'Registro de Cliente',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 6),
              const Text(
                'Ingresa tus datos. El sistema generará tu usuario de acceso automáticamente.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: nameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Nombre',
                        labelStyle: const TextStyle(color: Colors.white54),
                        prefixIcon: const Icon(Icons.person, color: Color(0xFFC77DFF)),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: lastNameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Apellido',
                        labelStyle: const TextStyle(color: Colors.white54),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passCtrl,
                obscureText: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Crea una Contraseña (mínimo 4 dígitos)',
                  labelStyle: const TextStyle(color: Colors.white54),
                  prefixIcon: const Icon(Icons.lock, color: Color(0xFF00E5FF)),
                  filled: true,
                  fillColor: const Color(0xFF1E293B),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                  focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2)),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  style: ButtonStyle(
                    backgroundColor: MaterialStateProperty.resolveWith((states) {
                      if (states.contains(MaterialState.focused)) return Colors.white;
                      return const Color(0xFF00E5FF);
                    }),
                    foregroundColor: MaterialStateProperty.all(Colors.black),
                    shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                    side: MaterialStateProperty.resolveWith((states) {
                      if (states.contains(MaterialState.focused)) return const BorderSide(color: Color(0xFF00E5FF), width: 3);
                      return BorderSide.none;
                    }),
                  ),
                  onPressed: isRegistering
                      ? null
                      : () async {
                          if (nameCtrl.text.trim().isEmpty || lastNameCtrl.text.trim().isEmpty || passCtrl.text.trim().isEmpty) return;
                          
                          setModalState(() => isRegistering = true);
                          
                          final res = await AuthService.registerUser(
                            nameCtrl.text.trim(),
                            lastNameCtrl.text.trim(),
                            passCtrl.text.trim(),
                          );
                          
                          setModalState(() => isRegistering = false);
                          
                          if (mounted) {
                            Navigator.pop(ctx);
                            
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(res.message, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                                backgroundColor: res.isSuccess ? const Color(0xFF00C853) : Colors.redAccent,
                                duration: const Duration(seconds: 6),
                              ),
                            );
                            
                            if (res.isSuccess && res.user != null) {
                              setState(() {
                                _usernameController.text = res.user!.username;
                                _passwordController.text = passCtrl.text.trim();
                              });
                            }
                          }
                        },
                  child: isRegistering
                      ? const CircularProgressIndicator(color: Colors.black)
                      : const Text('GENERAR MI ACCESO', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
            style: ButtonStyle(
              side: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const BorderSide(color: Color(0xFF00E5FF), width: 2) : const BorderSide(color: Colors.white24)),
              foregroundColor: MaterialStateProperty.all(Colors.white),
            ),
            child: const Text('Ver TV / Canales'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              widget.onLoginSuccess(directScreen: const AdminPanelScreen());
            },
            style: ButtonStyle(
              backgroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? Colors.white : const Color(0xFF00E5FF)),
              foregroundColor: MaterialStateProperty.all(Colors.black),
            ),
            child: const Text('Panel de Clientes', style: TextStyle(fontWeight: FontWeight.bold)),
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
                    'Por seguridad y regla anti-piratería, tu cuenta está configurada para máximo 2 pantallas simultáneas (1 Celular y 1 Smart TV).',
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
                    '¿Cambiaste de dispositivo?',
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
                    style: ButtonStyle(
                      backgroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? Colors.white : const Color(0xFFFFD600)),
                      foregroundColor: MaterialStateProperty.all(Colors.black),
                      minimumSize: MaterialStateProperty.all(const Size(double.infinity, 40)),
                      shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
                    style: ButtonStyle(
                      side: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const BorderSide(color: Colors.white, width: 2) : const BorderSide(color: Color(0xFF00E5FF))),
                      minimumSize: MaterialStateProperty.all(const Size(double.infinity, 40)),
                      shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
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
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: ButtonStyle(foregroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? Colors.white : Colors.white54)),
            child: const Text('Cancelar'),
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
            style: ButtonStyle(
              backgroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? Colors.white : const Color(0xFF00E5FF)),
              foregroundColor: MaterialStateProperty.all(Colors.black),
            ),
            child: const Text('Validar PIN', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

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

  Widget _buildLanguageButton() {
    final currentCode = LanguageService.currentLanguage.value;
    final currentLang = LanguageService.supportedLanguages.firstWhere(
      (l) => l['code'] == currentCode,
      orElse: () => LanguageService.supportedLanguages.first,
    );

    // CAMBIO: Botón TV friendly para el idioma
    return OutlinedButton.icon(
      onPressed: () => _showLanguageSelectorDialog(context),
      icon: Text(currentLang['flag'] ?? '🌐', style: const TextStyle(fontSize: 15)),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            currentLang['name'] ?? '',
            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
          ),
          const Icon(Icons.arrow_drop_down, color: Color(0xFF00E5FF), size: 18),
        ],
      ),
      style: ButtonStyle(
        backgroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const Color(0xFF00E5FF).withOpacity(0.3) : const Color(0xFF101726)),
        side: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const BorderSide(color: Color(0xFF00E5FF), width: 2) : BorderSide(color: const Color(0xFF00E5FF).withOpacity(0.5))),
        shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(20))),
        padding: MaterialStateProperty.all(const EdgeInsets.symmetric(horizontal: 10, vertical: 6)),
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
                                // CAMBIO: TextField con FocusedBorder nativo
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
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2)),
                                  ),
                                ),

                                const SizedBox(height: 16),

                                Text(
                                  LanguageService.tr('password'),
                                  style: const TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
                                ),
                                const SizedBox(height: 6),
                                // CAMBIO: TextField con FocusedBorder nativo
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
                                    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF00E5FF), width: 2)),
                                  ),
                                ),

                                const SizedBox(height: 22),

                                // CAMBIO: ElevatedButton nativo que se ilumina con el D-Pad
                                ElevatedButton(
                                  onPressed: _isLoading ? null : _doLogin,
                                  style: ButtonStyle(
                                    minimumSize: MaterialStateProperty.all(const Size(double.infinity, 48)),
                                    shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                    backgroundColor: MaterialStateProperty.resolveWith((states) {
                                      if (states.contains(MaterialState.disabled)) return Colors.grey;
                                      if (states.contains(MaterialState.focused)) return Colors.white; 
                                      return const Color(0xFF00E5FF);
                                    }),
                                    foregroundColor: MaterialStateProperty.all(Colors.black),
                                    side: MaterialStateProperty.resolveWith((states) {
                                      if (states.contains(MaterialState.focused)) return const BorderSide(color: Color(0xFF00E5FF), width: 3);
                                      return BorderSide.none;
                                    }),
                                    elevation: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? 20.0 : 4.0),
                                    shadowColor: MaterialStateProperty.all(const Color(0xFF00E5FF)),
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
                                
                                const SizedBox(height: 16),
                                
                                // CAMBIO: Botón TV friendly para Crear Cuenta (Reemplazo el InkWell)
                                OutlinedButton.icon(
                                  onPressed: _showRegisterModal,
                                  icon: const Icon(Icons.person_add_alt_1_rounded),
                                  label: const Text('¿No tienes cuenta? Crea una Gratis'),
                                  style: ButtonStyle(
                                    minimumSize: MaterialStateProperty.all(const Size(double.infinity, 46)),
                                    shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
                                    backgroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const Color(0xFF00E5FF) : const Color(0xFF00E5FF).withOpacity(0.1)),
                                    foregroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? Colors.black : const Color(0xFF00E5FF)),
                                    side: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const BorderSide(color: Colors.white, width: 2) : BorderSide(color: const Color(0xFF00E5FF).withOpacity(0.5))),
                                    elevation: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? 15.0 : 0.0),
                                  ),
                                ),
                                
                                const SizedBox(height: 16), 

                                // CAMBIO: TextButton actualizado para captar Foco D-Pad
                                Center(
                                  child: TextButton.icon(
                                    onPressed: _openSupportMenu,
                                    icon: const Icon(Icons.support_agent, size: 18),
                                    label: const Text('¿Necesitas acceso o renovar? Contáctanos', style: TextStyle(fontSize: 12)),
                                    style: ButtonStyle(
                                      foregroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const Color(0xFF00E5FF) : Colors.white70),
                                      backgroundColor: MaterialStateProperty.resolveWith((states) => states.contains(MaterialState.focused) ? const Color(0xFF00E5FF).withOpacity(0.1) : Colors.transparent),
                                      shape: MaterialStateProperty.all(RoundedRectangleBorder(borderRadius: BorderRadius.circular(8))),
                                    ),
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