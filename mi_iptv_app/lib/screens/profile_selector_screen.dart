import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import 'family_panel_screen.dart';

class ProfileSelectorScreen extends StatefulWidget {
  final VoidCallback? onLogout;
  final VoidCallback onProfileSelected;

  const ProfileSelectorScreen({
    super.key,
    this.onLogout,
    required this.onProfileSelected,
  });

  @override
  State<ProfileSelectorScreen> createState() => _ProfileSelectorScreenState();
}

class _ProfileSelectorScreenState extends State<ProfileSelectorScreen> {
  final UserModel? _currentUser = AuthService.currentUser;
  bool _isManageMode = false;

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

  @override
  Widget build(BuildContext context) {
    final familyId = _currentUser?.effectiveFamilyId ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFF070A10),
      body: SafeArea(
        child: StreamBuilder<List<UserModel>>(
          stream: AuthService.getFamilyMembersStream(familyId),
          builder: (context, snapshot) {
            final members = snapshot.data ?? [_currentUser ?? _dummyUser()];
            final usedScreens = members.length;
            const maxScreens = 5;
            final canAddMore = usedScreens < maxScreens && (_currentUser?.isFamilyAdmin ?? false);

            return Column(
              children: [
                // 1. TOP BAR DISNEY+
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
                            child: const Icon(Icons.family_restroom, color: Color(0xFFC77DFF), size: 18),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'FAMILIA ${_currentUser?.username.toUpperCase() ?? ""}',
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
                      // BOTÓN ADMINISTRAR PERFILES
                      if (_currentUser?.isFamilyAdmin == true)
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
                ),

                const Spacer(flex: 1),

                // 2. TÍTULO "¿QUIÉN ESTÁ VIENDO HOY?"
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
                      ? 'Toca un perfil para cambiar nombre o liberar su equipo'
                      : 'Selecciona tu pantalla para iniciar la transmisión',
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                ),

                const SizedBox(height: 28),

                // 3. CUADRÍCULA DE PERFILES (HASTA 5 PANTALLAS ESTILO DISNEY+)
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

                // 4. BARRA INFERIOR DE ACCIONES (RENOVAR, GESTIÓN Y SALIR)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: const BoxDecoration(
                    color: Color(0xFF101726),
                    border: Border(top: BorderSide(color: Colors.white10)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      // RENOVAR SUSCRIPCIÓN CON FINTECH / PAGO AUTOMÁTICO
                      TextButton.icon(
                        icon: const Icon(Icons.credit_card, color: Color(0xFF00E676), size: 16),
                        label: const Text(
                          'Renovar Plan',
                          style: TextStyle(color: Color(0xFF00E676), fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                        onPressed: () => _showPaymentOptionsModal(context),
                      ),

                      // GESTIONAR PANTALLAS (RESET HW)
                      if (_currentUser?.isFamilyAdmin == true)
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

                      // CERRAR SESIÓN
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

    return GestureDetector(
      onTap: () {
        if (_isManageMode) {
          _showEditProfileModal(member);
        } else {
          AuthService.setActiveProfile(member);
          widget.onProfileSelected();
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
              member.deviceName ?? member.username,
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
                  labelText: 'Nombre del Perfil (Ej: TV Sala, Mamá, Habitación)',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 14),
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

                    try {
                      await AuthService.addFamilyMember(
                        familyId: familyId,
                        username: username,
                        password: password,
                        memberName: name,
                        overrideVip: isVip,
                        avatarIndex: selectedAvatar,
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
    final nameCtrl = TextEditingController(text: member.deviceName ?? member.username);
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.edit, color: Color(0xFFC77DFF)),
                SizedBox(width: 8),
                Text('Editar: ${member.deviceName ?? member.username}', style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameCtrl,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                labelText: 'Nombre de la Pantalla',
                labelStyle: const TextStyle(color: Colors.white60),
                filled: true,
                fillColor: const Color(0xFF131A29),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.phonelink_erase, size: 14, color: Colors.orangeAccent),
                    label: const Text('Liberar Equipo', style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await AuthService.adminResetHardware(member.id);
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Dispositivo liberado. Ahora puede vincularse en un nuevo televisor.')),
                        );
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: () async {
                      Navigator.pop(ctx);
                      await AuthService.updateClientUser(member.id, {'deviceName': nameCtrl.text.trim()});
                      if (mounted) setState(() {});
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black),
                    child: const Text('Guardar'),
                  ),
                ),
              ],
            ),
            if (!member.isFamilyAdmin) ...[
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

  void _showPaymentOptionsModal(BuildContext context) {
    final pinCtrl = TextEditingController();
    bool isProcessing = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
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
              const Row(
                children: [
                  Icon(Icons.credit_card, color: Color(0xFF00E676)),
                  SizedBox(width: 8),
                  Text('Renovar Suscripción Automática', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Al realizar el pago o ingresar tu código PIN prepago, tu acceso se extiende automáticamente por 30 días sin esperas.',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 14),

              // 1. CANJEAR PIN PREPAGO / VOUCHER
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF131A29),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('¿Tienes un Código o PIN de Activación?', style: TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
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
                              fillColor: Colors.black26,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                                  final res = await AuthService.redeemActivationPin(pinCode: code);
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
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                          ),
                          child: const Text('Canjear', style: TextStyle(fontWeight: FontWeight.bold)),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // 2. BOTONES DE PAGO AUTOMÁTICO (MERCADO PAGO / BINANCE)
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.payment, color: Color(0xFF00E5FF), size: 16),
                      label: const Text('Mercado Pago', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFF00E5FF)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: () async {
                        setModalState(() => isProcessing = true);
                        final res = await AuthService.simulateAutomaticPayment(
                          userId: _currentUser?.id ?? '',
                          days: 30,
                          paymentMethod: 'Mercado Pago (Aprobado 24/7)',
                        );
                        setModalState(() => isProcessing = false);
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(res.message), backgroundColor: const Color(0xFF00E676)),
                          );
                          setState(() {});
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.currency_bitcoin, color: Color(0xFFF7931A), size: 16),
                      label: const Text('Binance USDT', style: TextStyle(color: Color(0xFFF7931A), fontSize: 11)),
                      style: OutlinedButton.styleFrom(
                        side: const BorderSide(color: Color(0xFFF7931A)),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                      ),
                      onPressed: () async {
                        setModalState(() => isProcessing = true);
                        final res = await AuthService.simulateAutomaticPayment(
                          userId: _currentUser?.id ?? '',
                          days: 30,
                          paymentMethod: 'Binance Pay USDT (Aprobado 24/7)',
                        );
                        setModalState(() => isProcessing = false);
                        if (context.mounted) {
                          Navigator.pop(ctx);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text(res.message), backgroundColor: const Color(0xFF00E676)),
                          );
                          setState(() {});
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  UserModel _dummyUser() {
    return UserModel(
      id: 'default_head',
      username: 'jefe',
      password: '',
      role: 'family_admin',
      isFamilyAdmin: true,
      expirationDate: DateTime.now().add(const Duration(days: 30)),
      deviceName: 'Mi Pantalla Principal',
    );
  }
}