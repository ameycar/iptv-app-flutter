import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import 'family_panel_screen.dart';

class ProfileSelectorScreen extends StatefulWidget {
  final VoidCallback? onLogout;
  final VoidCallback? onProfileSelected;

  const ProfileSelectorScreen({
    super.key,
    this.onLogout,
    this.onProfileSelected,
  });

  @override
  State<ProfileSelectorScreen> createState() => _ProfileSelectorScreenState();
}

class _ProfileSelectorScreenState extends State<ProfileSelectorScreen> {
  UserModel? get _currentUser => AuthService.currentUser;
  bool _isManageMode = false;

  bool get _canSeePaymentBanks {
    final u = _currentUser;
    if (u == null) return false;
    return u.isFamilyAdmin || !u.isPartOfFamily || (u.familyId == null || u.familyId!.isEmpty);
  }

  static const List<Map<String, dynamic>> _avatarStyles = [
    {
      'icon': Icons.stars,
      'name': 'Jefe / VIP',
      'colors': [Color(0xFF7B2CBF), Color(0xFFFFD700)],
    },
    {
      'icon': Icons.tv,
      'name': 'Smart TV',
      'colors': [Color(0xFF0072FF), Color(0xFF00E5FF)],
    },
    {
      'icon': Icons.movie_filter,
      'name': 'Cinefilo',
      'colors': [Color(0xFF8E2DE2), Color(0xFFF000FF)],
    },
    {
      'icon': Icons.child_care,
      'name': 'Kids',
      'colors': [Color(0xFFF7971E), Color(0xFFFFD200)],
    },
    {
      'icon': Icons.sports_esports,
      'name': 'Gamer',
      'colors': [Color(0xFF00B09B), Color(0xFF96C93D)],
    },
    {
      'icon': Icons.live_tv,
      'name': 'Deportes',
      'colors': [Color(0xFFFF416C), Color(0xFFFF4B2B)],
    },
  ];

  void _finishProfileSelection() {
    if (widget.onProfileSelected != null) {
      widget.onProfileSelected!();
    } else if (Navigator.canPop(context)) {
      Navigator.pop(context, true);
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
                message: 'Hola Ameycar TV, deseo renovar o activar mi perfil directamente con ustedes.',
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
                title: 'Solicitar pantallas adicionales',
                subtitle: 'Ampliar plan familiar',
                message: 'Hola, me interesa ampliar mi plan y adquirir pantallas adicionales.',
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSupportOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required String message,
  }) {
    return InkWell(
      onTap: () async {
        Navigator.pop(context);
        const phoneNumber = "51905823660";
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
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF00E5FF).withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, color: const Color(0xFF00E5FF), size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 14),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final familyId = _currentUser?.effectiveFamilyId ?? '';
    final bool isHeadUser = _currentUser?.isFamilyAdmin ?? false;
    final bool canSeeBanks = _canSeePaymentBanks;

    return Scaffold(
      backgroundColor: const Color(0xFF070A10),
      body: SafeArea(
        child: StreamBuilder<List<UserModel>>(
          stream: AuthService.getFamilyMembersStream(familyId),
          builder: (context, snapshot) {
            final members = (snapshot.data != null && snapshot.data!.isNotEmpty)
                ? snapshot.data!
                : [_currentUser ?? _dummyUser()];
            final usedScreens = members.length;
            const maxScreens = 5;
            final canAddMore = usedScreens < maxScreens && isHeadUser;

            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7B2CBF).withOpacity(0.3),
                              shape: BoxShape.circle,
                              border: Border.all(color: const Color(0xFFC77DFF)),
                            ),
                            child: Icon(
                              isHeadUser ? Icons.family_restroom : Icons.person,
                              color: const Color(0xFFC77DFF),
                              size: 18,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                isHeadUser
                                    ? 'FAMILIA ${_currentUser?.username.toUpperCase() ?? ""}'
                                    : (_currentUser?.username.toUpperCase() ?? 'MI CUENTA'),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w900,
                                  fontSize: 14,
                                  letterSpacing: 0.8,
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    _currentUser?.isVip == true ? 'PLAN VIP' : 'PLAN ESTÁNDAR',
                                    style: TextStyle(
                                      color: _currentUser?.isVip == true ? const Color(0xFFFFD700) : const Color(0xFF00E5FF),
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    '• ${_currentUser?.daysRemaining ?? 0} días restantes',
                                    style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ],
                      ),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.headset_mic, color: Color(0xFF00E5FF), size: 22),
                            tooltip: 'Soporte Directo',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            onPressed: _openSupportMenu,
                          ),
                          const SizedBox(width: 12),
                          if (isHeadUser)
                            OutlinedButton.icon(
                              onPressed: () {
                                setState(() {
                                  _isManageMode = !_isManageMode;
                                });
                              },
                              icon: Icon(
                                _isManageMode ? Icons.check : Icons.edit,
                                size: 14,
                                color: _isManageMode ? const Color(0xFF00E676) : Colors.white70,
                              ),
                              label: Text(
                                _isManageMode ? 'Listo' : 'Editar',
                                style: TextStyle(
                                  color: _isManageMode ? const Color(0xFF00E676) : Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: OutlinedButton.styleFrom(
                                side: BorderSide(
                                  color: _isManageMode ? const Color(0xFF00E676) : Colors.white24,
                                ),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                const Spacer(flex: 1),
                const Text(
                  '¿Quién está viendo hoy?',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _isManageMode
                      ? 'Toca un perfil para cambiar nombre, PIN o liberar su equipo'
                      : 'Selecciona tu pantalla para iniciar la transmisión',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Center(
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 20,
                      alignment: WrapAlignment.center,
                      children: [
                        ...members.map((member) => _buildProfileItem(member)),
                        if (canAddMore) _buildAddProfileButton(context, familyId, usedScreens),
                      ],
                    ),
                  ),
                ),
                const Spacer(flex: 2),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF101726),
                    border: Border(top: BorderSide(color: Colors.white10)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.confirmation_number, color: Color(0xFF00E676), size: 16),
                        label: Text(
                          canSeeBanks ? 'Renovar Plan' : 'Canjear PIN',
                          style: const TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        onPressed: () => _showPaymentOptionsModal(context, isHead: canSeeBanks),
                      ),
                      if (isHeadUser)
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => FamilyPanelScreen(onLogout: widget.onLogout),
                              ),
                            );
                          },
                          icon: const Icon(Icons.phonelink_setup, size: 15),
                          label: const Text('Equipos y Dispositivos', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF7B2CBF),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          ),
                        ),
                      IconButton(
                        icon: const Icon(Icons.power_settings_new, color: Colors.white54, size: 20),
                        tooltip: 'Cerrar Sesión',
                        onPressed: () async {
                          await AuthService.logout();
                          if (mounted) widget.onLogout?.call();
                        },
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildProfileItem(UserModel member) {
    final avatar = _avatarStyles[member.avatarIndex % _avatarStyles.length];
    final bool isHead = member.isFamilyAdmin;
    final bool hasPinLock = isHead || (member.pinCode != null && member.pinCode!.isNotEmpty);

    String displayName = (member.deviceName != null && member.deviceName!.isNotEmpty)
        ? member.deviceName!
        : member.username;

    if (displayName.toLowerCase().contains('dispositivo') || displayName.trim().isEmpty) {
      displayName = isHead ? member.username.toUpperCase() : member.username;
    }

    return GestureDetector(
      onTap: () {
        if (_isManageMode) {
          _showEditProfileModal(member);
        } else {
          _handleProfileSelection(member);
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: (avatar['colors'] as List<Color>),
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: (avatar['colors'][0] as Color).withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                  border: Border.all(
                    color: isHead ? const Color(0xFFFFD700) : Colors.white24,
                    width: isHead ? 2.5 : 1.5,
                  ),
                ),
                child: Icon(
                  avatar['icon'] as IconData,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              if (_isManageMode)
                Container(
                  width: 76,
                  height: 76,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.55),
                  ),
                  child: const Icon(Icons.edit, color: Colors.white, size: 26),
                ),
              if (hasPinLock && !_isManageMode)
                Positioned(
                  top: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Color(0xFF131A29),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.lock,
                      color: isHead ? const Color(0xFFFFD700) : Colors.white70,
                      size: 14,
                    ),
                  ),
                ),
              if (isHead)
                Positioned(
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFD700),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'JEFE',
                      style: TextStyle(color: Colors.black, fontSize: 8.5, fontWeight: FontWeight.w900),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 84,
            child: Text(
              displayName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            member.isVip ? 'VIP' : 'Estándar',
            style: TextStyle(
              color: member.isVip ? const Color(0xFFFFD700) : Colors.white38,
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  void _handleProfileSelection(UserModel member) {
    final bool isHead = member.isFamilyAdmin;
    final bool hasPin = member.pinCode != null && member.pinCode!.isNotEmpty;

    if (isHead) {
      _showProfilePasswordDialog(member, isHead: true);
      return;
    }

    if (AuthService.currentActiveProfile?.id == member.id) {
      AuthService.setActiveProfile(member);
      _finishProfileSelection();
      return;
    }

    if (hasPin) {
      _showProfilePasswordDialog(member, isHead: false);
    } else {
      AuthService.setActiveProfile(member);
      _finishProfileSelection();
    }
  }

  void _showProfilePasswordDialog(UserModel member, {required bool isHead}) {
    final passCtrl = TextEditingController();
    String? errorText;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF101726),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(
              color: isHead ? const Color(0xFFFFD700) : const Color(0xFF7B2CBF),
              width: 1.5,
            ),
          ),
          title: Row(
            children: [
              Icon(Icons.lock, color: isHead ? const Color(0xFFFFD700) : const Color(0xFF00E5FF)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isHead ? 'Perfil Jefe (Protegido)' : 'Perfil Privado: ${member.deviceName ?? member.username}',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isHead
                    ? 'Ingresa tu PIN de 4 dígitos o la contraseña de tu cuenta:'
                    : 'Ingresa el PIN de 4 dígitos asignado a este perfil:',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: passCtrl,
                obscureText: true,
                autofocus: true,
                keyboardType: TextInputType.text,
                style: const TextStyle(color: Colors.white, letterSpacing: 2),
                decoration: InputDecoration(
                  hintText: isHead ? 'PIN o Contraseña' : 'PIN (4 dígitos)',
                  hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 0),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                  errorText: errorText,
                ),
              ),
              if (!isHead) ...[
                const SizedBox(height: 8),
                const Text(
                  'El Jefe de Familia también puede acceder con su clave.',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar', style: TextStyle(color: Colors.white60)),
            ),
            ElevatedButton(
              onPressed: () {
                final input = passCtrl.text.trim();
                bool isAuthorized = false;

                if (isHead) {
                  final hasPin = member.pinCode != null && member.pinCode!.isNotEmpty;
                  final matchPin = hasPin && member.pinCode == input;
                  final matchPassword = member.password == input;
                  isAuthorized = matchPin || matchPassword;
                } else {
                  final matchPin = member.pinCode != null && member.pinCode == input;
                  final matchHeadPass = _currentUser?.password == input;
                  final matchHeadPin = _currentUser?.pinCode != null && _currentUser?.pinCode == input;
                  isAuthorized = matchPin || matchHeadPass || matchHeadPin;
                }

                if (isAuthorized) {
                  Navigator.pop(ctx);
                  AuthService.setActiveProfile(member);
                  _finishProfileSelection();
                } else {
                  setDialogState(() {
                    errorText = isHead ? 'Contraseña o PIN de Jefe incorrecto' : 'PIN incorrecto';
                  });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: isHead ? const Color(0xFFFFD700) : const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
              ),
              child: const Text('Acceder', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddProfileButton(BuildContext context, String familyId, int currentUsed) {
    return GestureDetector(
      onTap: () => _showAddProfileModal(context, familyId, currentUsed),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFF131A29),
              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 1.8),
            ),
            child: const Icon(Icons.add, color: Color(0xFF00E5FF), size: 36),
          ),
          const SizedBox(height: 8),
          const SizedBox(
            width: 84,
            child: Text(
              'Agregar Pantalla',
              textAlign: TextAlign.center,
              maxLines: 1,
              style: TextStyle(
                color: Color(0xFF00E5FF),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${5 - currentUsed} libres',
            style: const TextStyle(color: Colors.white38, fontSize: 9.5),
          ),
        ],
      ),
    );
  }

  void _showAddProfileModal(BuildContext context, String familyId, int currentUsed) {
    final nameCtrl = TextEditingController();
    final pinCtrl = TextEditingController();
    int selectedAvatar = (currentUsed % _avatarStyles.length);
    bool isVip = _currentUser?.isVip ?? false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModal) => Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.tv, color: Color(0xFF00E5FF)),
                  const SizedBox(width: 8),
                  Text(
                    'Nueva Pantalla (${currentUsed + 1} de 5)',
                    style: const TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Nombre del Perfil (Ej: TV Sala, Habitación, Juan)',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: pinCtrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                style: const TextStyle(color: Colors.white, letterSpacing: 2),
                decoration: InputDecoration(
                  labelText: 'PIN de Privacidad (Opcional - 4 dígitos)',
                  labelStyle: const TextStyle(color: Colors.white60),
                  counterText: '',
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 10),
              const Text('Selecciona el Avatar:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 8),
              SizedBox(
                height: 56,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: _avatarStyles.length,
                  itemBuilder: (ctx, i) {
                    final item = _avatarStyles[i];
                    final isSel = selectedAvatar == i;
                    return GestureDetector(
                      onTap: () => setModal(() => selectedAvatar = i),
                      child: Container(
                        margin: const EdgeInsets.only(right: 10),
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(colors: item['colors'] as List<Color>),
                          border: Border.all(
                            color: isSel ? Colors.white : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                        child: Icon(item['icon'] as IconData, color: Colors.white, size: 24),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Habilitar Acceso VIP a este Perfil', style: TextStyle(color: Colors.white, fontSize: 13)),
                subtitle: const Text('Canales 4K, películas y series', style: TextStyle(color: Colors.white38, fontSize: 11)),
                value: isVip,
                activeColor: Colors.amber,
                onChanged: (v) => setModal(() => isVip = v),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton(
                  onPressed: () async {
                    final name = nameCtrl.text.trim();
                    if (name.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Escribe un nombre para este perfil.')),
                      );
                      return;
                    }

                    final randomSuffix = Random().nextInt(900) + 100;
                    final username = '${_currentUser?.username ?? "user"}_p${currentUsed + 1}_$randomSuffix';
                    final password = 'tv$randomSuffix';
                    final pin = pinCtrl.text.trim();

                    try {
                      await AuthService.addFamilyMember(
                        familyId: familyId,
                        username: username,
                        password: password,
                        memberName: name,
                        overrideVip: isVip,
                        avatarIndex: selectedAvatar,
                        pinCode: pin.isNotEmpty ? pin : null,
                      );
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('¡Pantalla "$name" creada exitosamente!')),
                        );
                      }
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
                        );
                      }
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E5FF),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Crear Perfil', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditProfileModal(UserModel member) {
    String defaultName = (member.deviceName != null && member.deviceName!.isNotEmpty)
        ? member.deviceName!
        : member.username;

    if (member.isFamilyAdmin && (defaultName.toLowerCase().contains('dispositivo') || defaultName.isEmpty)) {
      defaultName = member.username.toUpperCase();
    }

    final nameCtrl = TextEditingController(text: defaultName);
    final pinCtrl = TextEditingController(text: member.pinCode ?? '');
    final bool isHead = member.isFamilyAdmin;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.edit, color: isHead ? const Color(0xFFFFD700) : const Color(0xFFC77DFF)),
                const SizedBox(width: 8),
                Text(
                  isHead ? 'Configurar Perfil del Jefe' : 'Editar: $defaultName',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: isHead ? 'Nombre del Jefe (Ej: Papá, Juan)' : 'Nombre de la Pantalla',
                labelStyle: const TextStyle(color: Colors.white60),
                filled: true,
                fillColor: const Color(0xFF131A29),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pinCtrl,
              keyboardType: TextInputType.number,
              maxLength: 4,
              style: const TextStyle(color: Colors.white, letterSpacing: 2),
              decoration: InputDecoration(
                labelText: isHead ? 'PIN Rápido del Jefe (4 dígitos)' : 'PIN de Bloqueo Privado (4 dígitos - Opcional)',
                hintText: isHead ? 'Ej: 1985 (Si lo dejas vacío, usará tu contraseña)' : 'Dejar vacío si no deseas pedir PIN',
                hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 0),
                counterText: '',
                labelStyle: const TextStyle(color: Colors.white60),
                filled: true,
                fillColor: const Color(0xFF131A29),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                if (!isHead)
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.phonelink_erase, size: 14, color: Colors.orangeAccent),
                      label: const Text('Liberar Equipo', style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                      onPressed: () async {
                        Navigator.pop(ctx);
                        await AuthService.adminResetHardware(member.id);
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Dispositivo liberado.')),
                          );
                        }
                      },
                    ),
                  ),
                if (!isHead) const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      final updates = <String, dynamic>{
                        'deviceName': nameCtrl.text.trim(),
                        'pinCode': pinCtrl.text.trim().isNotEmpty ? pinCtrl.text.trim() : null,
                      };
                      await AuthService.updateClientUser(member.id, updates);
                      if (mounted) setState(() {});
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isHead ? const Color(0xFFFFD700) : const Color(0xFF00E5FF),
                      foregroundColor: Colors.black,
                    ),
                    child: const Text('Guardar'),
                  ),
                ),
              ],
            ),
            if (!isHead) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: TextButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16, color: Colors.redAccent),
                  label: const Text('Eliminar Perfil (Liberar cupo de pantalla)', style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    await AuthService.deleteClientUser(member.id);
                    if (mounted) setState(() {});
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _showPaymentOptionsModal(BuildContext context, {required bool isHead}) {
    final pinCtrl = TextEditingController();
    final refCtrl = TextEditingController();
    bool isProcessing = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1320),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 18,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Icon(isHead ? Icons.stars : Icons.confirmation_number, color: const Color(0xFFFFD700), size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isHead ? 'Renovación de Suscripción' : 'Canjear PIN de Activación',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isHead
                      ? 'Métodos seguros para extender tu plan sin comisiones.'
                      : 'Ingresa el código proporcionado por el titular para activar tu pantalla.',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131A29),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.confirmation_number, color: Color(0xFF00E5FF), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Ingresar PIN de Acceso',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Si recibiste un PIN de activación de tu proveedor, ingrésalo aquí:',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: pinCtrl,
                              style: const TextStyle(color: Colors.white, letterSpacing: 1.5, fontWeight: FontWeight.bold),
                              textCapitalization: TextCapitalization.characters,
                              decoration: InputDecoration(
                                hintText: 'Ej: AMEY-30D-4921',
                                hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 0),
                                filled: true,
                                fillColor: Colors.black38,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: isProcessing
                                ? null
                                : () async {
                                    final code = pinCtrl.text.trim();
                                    if (code.isEmpty) return;
                                    setModalState(() => isProcessing = true);
                                    final res = await AuthService.redeemActivationPin(code);
                                    setModalState(() => isProcessing = false);
                                    if (context.mounted) {
                                      Navigator.pop(ctx);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(res.message),
                                          backgroundColor: res.isSuccess ? const Color(0xFF00E676) : Colors.redAccent,
                                        ),
                                      );
                                      if (res.isSuccess) setState(() {});
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('Canjear', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isHead) ...[
                  const SizedBox(height: 14),
                  // CÍRCULO AMEYCAR - CÓDIGO DE REFERIDO OPCIONAL
                  TextField(
                    controller: refCtrl,
                    textCapitalization: TextCapitalization.characters,
                    style: const TextStyle(color: Color(0xFFFFD600), fontWeight: FontWeight.bold),
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.card_giftcard, color: Color(0xFFFFD600), size: 18),
                      labelText: '¿Te invitó un amigo? Código opcional (+15 días para él)',
                      labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                      hintText: 'AMEY-NOMBRE-0000',
                      hintStyle: const TextStyle(color: Colors.white24, fontSize: 12),
                      filled: true,
                      fillColor: const Color(0xFF131A29),
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 20),
                  const Row(
                    children: [
                      Text('🇵🇪 ', style: TextStyle(fontSize: 16)),
                      Text('Pago Nacional (Cero Comisiones):', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentTile(
                    icon: Icons.phone_android,
                    color: const Color(0xFF7B2CBF),
                    title: 'Yape / Plin',
                    subtitle: '51905823660 • Titular: AMEYCAR TV',
                    copyText: '51905823660',
                    context: context,
                  ),
                  const SizedBox(height: 8),
                  _buildPaymentTile(
                    icon: Icons.account_balance,
                    color: const Color(0xFFFF7043),
                    title: 'BCP - Cuenta Soles',
                    subtitle: '19194759620085 • Titular: ACOSTA NN CARLOS RAFAEL',
                    copyText: '19194759620085',
                    context: context,
                  ),
                  const SizedBox(height: 20),
                  const Row(
                    children: [
                      Text('🌎 ', style: TextStyle(fontSize: 16)),
                      Text('Pago Internacional (Anti-Fraude):', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentTile(
                    icon: Icons.currency_bitcoin,
                    color: const Color(0xFFFFD700),
                    title: 'Binance Pay (USDT - Inmediato)',
                    subtitle: 'Pay ID: 214778098',
                    copyText: '214778098',
                    context: context,
                  ),
                  const SizedBox(height: 8),
                  _buildPaymentTile(
                    icon: Icons.account_balance_wallet,
                    color: const Color(0xFF0072FF),
                    title: 'PayPal',
                    subtitle: 'carlos_87_21@hotmail.com',
                    copyText: 'carlos_87_21@hotmail.com',
                    context: context,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E283D),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF25D366).withOpacity(0.5), width: 1.5),
                    ),
                    child: Column(
                      children: [
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline, color: Color(0xFF25D366), size: 22),
                            SizedBox(width: 8),
                            Text(
                              'Validar Pago y Activar',
                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Toca aquí para enviar la captura de tu transferencia. Te entregaremos tu PIN de renovación de inmediato.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.chat, color: Colors.white, size: 16),
                          label: const Text('Enviar Voucher por WhatsApp', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () async {
                            final refTxt = refCtrl.text.trim().isNotEmpty ? ' | Código amigo: ${refCtrl.text.trim()}' : '';
                            final msg = '¡Hola! He realizado una transferencia para renovar mi plan hoy. Mi usuario es: ${_currentUser?.username ?? "cliente"}$refTxt. Adjunto mi voucher de pago.';
                            Clipboard.setData(ClipboardData(text: msg));

                            const phoneNumber = "51905823660";
                            final url = Uri.parse("whatsapp://send?phone=$phoneNumber&text=${Uri.encodeComponent(msg)}");
                            try {
                              if (await canLaunchUrl(url)) {
                                await launchUrl(url);
                              } else {
                                final webUrl = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(msg)}");
                                await launchUrl(webUrl, mode: LaunchMode.externalApplication);
                              }
                            } catch (_) {}
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPaymentTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String copyText,
    required BuildContext context,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, color: Color(0xFF00E5FF), size: 18),
            tooltip: 'Copiar dato',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copyText));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¡Copiado: $copyText!'), duration: const Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
    );
  }

  UserModel _dummyUser() {
    return UserModel(
      id: 'default',
      username: 'cacosta',
      password: '',
      expirationDate: DateTime.now().add(const Duration(days: 30)),
      isFamilyAdmin: true,
      maxScreens: 5,
    );
  }
}