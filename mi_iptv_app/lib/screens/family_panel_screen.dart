import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';

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
  bool _memberIsVip = false;
  bool _isSaving = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _deviceNameCtrl.dispose();
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
    _memberIsVip = adminUser.familyPlan == 'vip';

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
                  const SizedBox(height: 20),
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
                  if (adminUser.familyPlan == 'vip') ...[
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
                            familyId: adminUser.familyId!,
                            username: _usernameCtrl.text,
                            password: _passwordCtrl.text,
                            memberName: _deviceNameCtrl.text,
                            overrideVip: _memberIsVip,
                          );
                          if (mounted) {
                            Navigator.pop(modalCtx);
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

  @override
  Widget build(BuildContext context) {
    final currentUser = AuthService.currentUser;
    if (currentUser == null || !currentUser.isFamilyGroupAdmin || currentUser.familyId == null) {
      return Scaffold(
        backgroundColor: const Color(0xFF0D1117),
        appBar: AppBar(title: const Text('Panel Familiar'), backgroundColor: Colors.transparent),
        body: const Center(
          child: Text('No tienes una cuenta de Administrador Familiar activa.', style: TextStyle(color: Colors.white70)),
        ),
      );
    }

    final familyId = currentUser.familyId!;
    final isVipPlan = currentUser.familyPlan == 'vip';

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
                                Icon(
                                  isHeadOfFamily ? Icons.star_rounded : Icons.tv_rounded,
                                  color: isHeadOfFamily ? const Color(0xFFFFD600) : const Color(0xFF8B5CF6),
                                  size: 24,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        member.deviceName ?? member.username,
                                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
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
                            Row(
                              children: [
                                Icon(
                                  member.registeredHardwareId != null ? Icons.lock : Icons.lock_open,
                                  size: 14,
                                  color: member.registeredHardwareId != null ? Colors.greenAccent : Colors.amberAccent,
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    member.registeredHardwareId != null
                                        ? 'Vinculado a: ${member.registeredHardwareId}'
                                        : 'Sin vincular (Se asociará al primer inicio)',
                                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
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
                                    onPressed: () async {
                                      await AuthService.adminResetHardware(member.id);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Dispositivo desvinculado. Puede conectarse en otro TV.')),
                                      );
                                    },
                                    icon: const Icon(Icons.refresh, size: 14),
                                    label: const Text('Cambiar TV / Liberar', style: TextStyle(fontSize: 11)),
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