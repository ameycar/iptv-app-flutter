import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';
import 'dart:math';

class FamilyPanelScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const FamilyPanelScreen({super.key, this.onLogout});

  @override
  State<FamilyPanelScreen> createState() => _FamilyPanelScreenState();
}

class _FamilyPanelScreenState extends State<FamilyPanelScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _deviceNameCtrl = TextEditingController();
  final _voucherCtrl = TextEditingController();
  bool _memberIsVip = false;
  bool _isSaving = false;
  int _selectedAvatar = 1;

  final List<Color> _avatarColors = [
    const Color(0xFF00E5FF),
    const Color(0xFF7B2CBF),
    const Color(0xFFFF007A),
    const Color(0xFF00E676),
    const Color(0xFFFFD600),
    const Color(0xFFFF5252),
  ];

  final List<IconData> _avatarIcons = [
    Icons.face,
    Icons.sentiment_very_satisfied,
    Icons.pets,
    Icons.sports_esports,
    Icons.rocket_launch,
    Icons.movie,
  ];

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _deviceNameCtrl.dispose();
    _voucherCtrl.dispose();
    super.dispose();
  }

  void _showAddMemberModal(BuildContext context, UserModel adminUser, int currentCount) {
    if (currentCount >= 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Colors.redAccent,
          content: Text('Has alcanzado el límite máximo de 5 pantallas en tu plan familiar.'),
        ),
      );
      return;
    }

    _usernameCtrl.clear();
    _passwordCtrl.clear();
    _deviceNameCtrl.clear();
    _selectedAvatar = currentCount % _avatarIcons.length;
    _memberIsVip = adminUser.familyPlan == 'vip' || adminUser.isVip;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (modalCtx, setModalState) => Container(
          padding: EdgeInsets.only(
            top: 24,
            left: 24,
            right: 24,
            bottom: MediaQuery.of(modalCtx).viewInsets.bottom + 24,
          ),
          decoration: BoxDecoration(
            color: const Color(0xFF161B26),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Form(
            key: _formKey,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF8B5CF6).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.tv_rounded, color: Color(0xFFC4B5FD)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Agregar Pantalla / Dispositivo',
                              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            Text(
                              'Pantalla ${currentCount + 1} de 5 permitidas',
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(modalCtx),
                        icon: const Icon(Icons.close, color: Colors.white60),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),

                  const Text('Elige un Ícono / Avatar:', style: TextStyle(color: Colors.white70, fontSize: 12)),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(_avatarIcons.length, (idx) {
                      final isSelected = _selectedAvatar == idx;
                      final col = _avatarColors[idx];
                      return GestureDetector(
                        onTap: () => setModalState(() => _selectedAvatar = idx),
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: col.withOpacity(isSelected ? 0.35 : 0.12),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? col : Colors.white24,
                              width: isSelected ? 2.5 : 1,
                            ),
                          ),
                          child: Icon(_avatarIcons[idx], color: col, size: 22),
                        ),
                      );
                    }),
                  ),

                  const SizedBox(height: 18),
                  TextFormField(
                    controller: _deviceNameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Nombre del Dispositivo / Familiar',
                      hintText: 'Ej: TV Sala, Celular Hijo, Tablet',
                      hintStyle: const TextStyle(color: Colors.white38),
                      prefixIcon: const Icon(Icons.devices, color: Color(0xFF8B5CF6)),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Ingresa el nombre del dispositivo' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _usernameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Usuario para esta pantalla',
                      hintText: 'Ej: sala_${adminUser.username}',
                      hintStyle: const TextStyle(color: Colors.white38),
                      prefixIcon: const Icon(Icons.person, color: Color(0xFF8B5CF6)),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    validator: (v) => v == null || v.trim().isEmpty ? 'Ingresa un usuario' : null,
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _passwordCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Contraseña para esta pantalla',
                      hintText: 'Mínimo 4 caracteres',
                      hintStyle: const TextStyle(color: Colors.white38),
                      prefixIcon: const Icon(Icons.lock, color: Color(0xFF8B5CF6)),
                      filled: true,
                      fillColor: Colors.black26,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                    ),
                    validator: (v) => v == null || v.trim().length < 4 ? 'Mínimo 4 caracteres' : null,
                  ),
                  const SizedBox(height: 16),
                  if (adminUser.familyPlan == 'vip' || adminUser.isVip) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _memberIsVip,
                      title: const Text('Asignar Canales VIP a esta pantalla', style: TextStyle(color: Colors.white, fontSize: 14)),
                      subtitle: const Text('Habilita contenido premium y 4K', style: TextStyle(color: Colors.white54, fontSize: 12)),
                      activeColor: const Color(0xFFFFD600),
                      onChanged: (val) => setModalState(() => _memberIsVip = val),
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                      ),
                      onPressed: _isSaving ? null : () async {
                        if (!_formKey.currentState!.validate()) return;
                        setModalState(() => _isSaving = true);
                        try {
                          await AuthService.addFamilyMember(
                            familyId: adminUser.effectiveFamilyId,
                            username: _usernameCtrl.text,
                            password: _passwordCtrl.text,
                            memberName: _deviceNameCtrl.text,
                            overrideVip: _memberIsVip,
                            avatarIndex: _selectedAvatar,
                          );
                          if (mounted) {
                            Navigator.pop(modalCtx);
                            setState(() {});
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                backgroundColor: Color(0xFF10B981),
                                content: Text('¡Pantalla agregada con éxito al grupo familiar!'),
                              ),
                            );
                          }
                        } catch (e) {
                          setModalState(() => _isSaving = false);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(backgroundColor: Colors.redAccent, content: Text('Error: $e')),
                          );
                        }
                      },
                      icon: _isSaving
                          ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                          : const Icon(Icons.add_circle_outline, color: Colors.white),
                      label: Text(_isSaving ? 'Guardando...' : 'ACTIVAR PANTALLA', style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showRedeemVoucherModal(BuildContext context, UserModel currentUser) {
    _voucherCtrl.clear();
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF161B26),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF00E676), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.confirmation_number_outlined, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text('Renovar Plan Familiar', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ingresa tu PIN de activación o código prepago (WhatsApp / Mercado Pago) para extender las 5 pantallas al mismo tiempo:',
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _voucherCtrl,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(color: Color(0xFF00E676), fontSize: 18, letterSpacing: 2, fontWeight: FontWeight.bold),
              decoration: InputDecoration(
                hintText: 'AMEY-30D-XXXX',
                hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 1),
                filled: true,
                fillColor: Colors.black38,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), foregroundColor: Colors.black),
            onPressed: () async {
              final code = _voucherCtrl.text.trim();
              if (code.isEmpty) return;
              Navigator.pop(dCtx);

              final res = await AuthService.redeemActivationPin(code);
              if (mounted) {
                setState(() {});
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    backgroundColor: res.isSuccess ? const Color(0xFF00E676) : Colors.redAccent,
                    content: Text(res.message, style: TextStyle(color: res.isSuccess ? Colors.black : Colors.white, fontWeight: FontWeight.bold)),
                  ),
                );
              }
            },
            child: const Text('Canjear Código', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // --- INDICADOR VISUAL DUAL (MÓVIL Y TV) ---
  Widget _buildDualDeviceIndicator(UserModel user) {
    final hasHw = user.registeredHardwareId != null && user.registeredHardwareId!.isNotEmpty;
    // UI temporal: Si hay algo vinculado, lo marcamos como TV por ahora
    final bool isMobileLinked = false; 
    final bool isTvLinked = hasHw;

    return Row(
      children: [
        _buildDeviceIcon(Icons.smartphone, isMobileLinked),
        const SizedBox(width: 8),
        _buildDeviceIcon(Icons.tv, isTvLinked),
      ],
    );
  }

  Widget _buildDeviceIcon(IconData icon, bool isLinked) {
    return Stack(
      alignment: Alignment.topRight,
      children: [
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: isLinked ? const Color(0xFF00E5FF).withOpacity(0.15) : Colors.white10,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: isLinked ? const Color(0xFF00E5FF).withOpacity(0.5) : Colors.transparent),
          ),
          child: Icon(
            icon,
            size: 14,
            color: isLinked ? const Color(0xFF00E5FF) : Colors.white38,
          ),
        ),
        if (!isLinked)
          const Positioned(
            right: -3,
            top: -3,
            child: Icon(Icons.lock, size: 12, color: Colors.redAccent),
          ),
      ],
    );
  }

  // --- MODAL DE RESET ERGONÓMICO FAMILIAR ---
  void _showErgonomicResetModal(BuildContext context, UserModel user) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161B26),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Liberar Dispositivo (Reset HW)',
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              'Selecciona qué dispositivo deseas liberar para "${user.username}".',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 20),
            
            ListTile(
              tileColor: const Color(0xFF1E283D),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              leading: const Icon(Icons.smartphone, color: Color(0xFF00E5FF)),
              title: const Text('Liberar Solo Celular', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              trailing: const Icon(Icons.lock_open, color: Colors.white38, size: 18),
              onTap: () async {
                Navigator.pop(ctx);
                await _performReset(user, type: 'mobile');
              },
            ),
            const SizedBox(height: 10),
            
            ListTile(
              tileColor: const Color(0xFF1E283D),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              leading: const Icon(Icons.tv, color: Color(0xFFC77DFF)),
              title: const Text('Liberar Solo Smart TV', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              trailing: const Icon(Icons.lock_open, color: Colors.white38, size: 18),
              onTap: () async {
                Navigator.pop(ctx);
                await _performReset(user, type: 'tv');
              },
            ),
            const SizedBox(height: 10),
            
            ListTile(
              tileColor: Colors.redAccent.withOpacity(0.1),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: Colors.redAccent),
              ),
              leading: const Icon(Icons.warning_amber_rounded, color: Colors.redAccent),
              title: const Text('Resetear Ambos (Completo)', style: TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold)),
              onTap: () async {
                Navigator.pop(ctx);
                await _performReset(user, type: 'both');
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performReset(UserModel user, {required String type}) async {
    // Almacena el llamado unificado de reset por ahora
    final success = await AuthService.adminResetHardware(user.id);
    if (success && mounted) {
      setState(() {});
      String msg = type == 'mobile' ? 'Celular liberado.' : type == 'tv' ? 'Smart TV liberada.' : 'Ambos dispositivos liberados.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: const Color(0xFF00C853), content: Text('$msg (Usuario: ${user.username})')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUser = AuthService.currentUser;
    if (currentUser == null || !currentUser.isFamilyGroupAdmin || currentUser.effectiveFamilyId.isEmpty) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(title: const Text('Panel Familiar'), backgroundColor: Colors.transparent),
        body: const Center(
          child: Text('No tienes una cuenta de Administrador Familiar activa.', style: TextStyle(color: Colors.white70)),
        ),
      );
    }

    final familyId = currentUser.effectiveFamilyId;
    final isVipPlan = currentUser.familyPlan == 'vip' || currentUser.isVip;

    return Scaffold(
      backgroundColor: const Color(0xFF0B0F17),
      appBar: AppBar(
        backgroundColor: const Color(0xFF161B26),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: isVipPlan ? const Color(0xFFFFD600).withOpacity(0.2) : const Color(0xFF8B5CF6).withOpacity(0.2),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.family_restroom, color: isVipPlan ? const Color(0xFFFFD600) : const Color(0xFFC4B5FD)),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Panel Familiar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                Text(
                  isVipPlan ? 'PLAN FAMILIAR VIP (5 Pantallas)' : 'PLAN FAMILIAR ESTÁNDAR (5 Pantallas)',
                  style: TextStyle(fontSize: 11, color: isVipPlan ? const Color(0xFFFFD600) : const Color(0xFF94A3B8)),
                ),
              ],
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Renovar con PIN / Voucher',
            icon: const Icon(Icons.confirmation_number_outlined, color: Color(0xFF00E676)),
            onPressed: () => _showRedeemVoucherModal(context, currentUser),
          ),
          IconButton(
            tooltip: 'Actualizar',
            icon: const Icon(Icons.refresh, color: Colors.white70),
            onPressed: () => setState(() {}),
          ),
          IconButton(
            tooltip: 'Cerrar Sesión',
            icon: const Icon(Icons.logout, color: Colors.white70),
            onPressed: () async {
              await AuthService.logout();
              if (widget.onLogout != null) widget.onLogout!();
              if (mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      body: StreamBuilder<List<UserModel>>(
        stream: AuthService.getFamilyMembersStream(familyId),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF8B5CF6)));
          }

          final members = snapshot.data!;
          final activeScreensCount = members.length;

          return Column(
            children: [
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: isVipPlan
                        ? [const Color(0xFF3B2D00), const Color(0xFF1A1500)]
                        : [const Color(0xFF2E1065), const Color(0xFF160B30)],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: isVipPlan ? const Color(0xFFFFD600).withOpacity(0.4) : const Color(0xFF8B5CF6).withOpacity(0.4),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Pantallas en uso: $activeScreensCount / 5',
                              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Vence en: ${currentUser.daysRemaining} días (${currentUser.expirationDate.day}/${currentUser.expirationDate.month}/${currentUser.expirationDate.year})',
                              style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: isVipPlan ? const Color(0xFFFFD600) : const Color(0xFF8B5CF6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            isVipPlan ? 'FAMILIA VIP' : 'ESTÁNDAR',
                            style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: activeScreensCount / 5.0,
                        minHeight: 8,
                        backgroundColor: Colors.white12,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          isVipPlan ? const Color(0xFFFFD600) : const Color(0xFF8B5CF6),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'PANTALLAS VINCULADAS',
                      style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 1),
                    ),
                    if (activeScreensCount < 5)
                      TextButton.icon(
                        style: TextButton.styleFrom(foregroundColor: const Color(0xFFC4B5FD)),
                        onPressed: () => _showAddMemberModal(context, currentUser, activeScreensCount),
                        icon: const Icon(Icons.add, size: 18),
                        label: const Text('Agregar Pantalla'),
                      ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  itemCount: members.length,
                  itemBuilder: (ctx, idx) {
                    final member = members[idx];
                    final isHeadOfFamily = member.isFamilyAdmin;
                    final avatarColor = _avatarColors[member.avatarIndex % _avatarColors.length];
                    final avatarIcon = _avatarIcons[member.avatarIndex % _avatarIcons.length];

                    return Card(
                      color: const Color(0xFF161B26),
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(
                          color: isHeadOfFamily ? const Color(0xFF8B5CF6).withOpacity(0.5) : Colors.white10,
                        ),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: avatarColor.withOpacity(0.2),
                                    shape: BoxShape.circle,
                                    border: Border.all(color: avatarColor, width: 1.5),
                                  ),
                                  child: Icon(avatarIcon, color: avatarColor, size: 22),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            member.deviceName ?? member.username,
                                            style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                          ),
                                          if (isHeadOfFamily) ...[
                                            const SizedBox(width: 6),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF8B5CF6).withOpacity(0.2),
                                                borderRadius: BorderRadius.circular(6),
                                              ),
                                              child: const Text('JEFE', style: TextStyle(color: Color(0xFFC4B5FD), fontSize: 9.5, fontWeight: FontWeight.bold)),
                                            ),
                                          ],
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        'Usuario: ${member.username} | Clave: ${member.password}',
                                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                if (member.isVip)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFFFD600).withOpacity(0.2),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Text('VIP', style: TextStyle(color: Color(0xFFFFD600), fontSize: 11, fontWeight: FontWeight.bold)),
                                  ),
                              ],
                            ),
                            const Divider(color: Colors.white10, height: 24),
                            
                            // NUEVO: INDICADOR VISUAL DUAL EN PANEL FAMILIAR
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _buildDualDeviceIndicator(member),
                                if (member.registeredHardwareId != null)
                                  Text(
                                    'ID: ${member.registeredHardwareId!.substring(0, min(8, member.registeredHardwareId!.length))}...',
                                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                                  )
                                else
                                  const Text('Libre (Primer inicio)', style: TextStyle(color: Colors.amberAccent, fontSize: 11)),
                              ],
                            ),
                            
                            const SizedBox(height: 14),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (member.registeredHardwareId != null)
                                  OutlinedButton.icon(
                                    style: OutlinedButton.styleFrom(
                                      foregroundColor: Colors.amberAccent,
                                      side: const BorderSide(color: Colors.amberAccent),
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    ),
                                    onPressed: () => _showErgonomicResetModal(context, member), // CAMBIO ERGONÓMICO
                                    icon: const Icon(Icons.refresh, size: 14),
                                    label: const Text('Liberar HW', style: TextStyle(fontSize: 11)),
                                  ),
                                if (!isHeadOfFamily) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    tooltip: 'Eliminar pantalla',
                                    icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 20),
                                    onPressed: () async {
                                      final confirm = await showDialog<bool>(
                                        context: context,
                                        builder: (dCtx) => AlertDialog(
                                          backgroundColor: const Color(0xFF161B26),
                                          title: const Text('¿Eliminar pantalla?', style: TextStyle(color: Colors.white)),
                                          content: Text('Se revocará el acceso al usuario "${member.username}".', style: const TextStyle(color: Colors.white70)),
                                          actions: [
                                            TextButton(onPressed: () => Navigator.pop(dCtx, false), child: const Text('Cancelar')),
                                            TextButton(onPressed: () => Navigator.pop(dCtx, true), child: const Text('Eliminar', style: TextStyle(color: Colors.redAccent))),
                                          ],
                                        ),
                                      );
                                      if (confirm == true) {
                                        await AuthService.deleteClientUser(member.id);
                                        if (mounted) setState(() {});
                                      }
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
      floatingActionButton: StreamBuilder<List<UserModel>>(
        stream: AuthService.getFamilyMembersStream(familyId),
        builder: (context, snapshot) {
          final count = snapshot.data?.length ?? 0;
          if (count >= 5) return const SizedBox.shrink();
          return FloatingActionButton.extended(
            backgroundColor: const Color(0xFF8B5CF6),
            onPressed: () => _showAddMemberModal(context, currentUser, count),
            icon: const Icon(Icons.add, color: Colors.white),
            label: const Text('Agregar Pantalla', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          );
        },
      ),
    );
  }
}