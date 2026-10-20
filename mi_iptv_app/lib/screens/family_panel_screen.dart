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
  final _currentUser = AuthService.currentUser;

  @override
  Widget build(BuildContext context) {
    final familyId = _currentUser?.familyId ?? '';

    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101726),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.family_restroom, color: Color(0xFF00E5FF)),
            const SizedBox(width: 8),
            Text(
              'Grupo Familiar (${_currentUser?.familyPlan?.toUpperCase() ?? "ESTÁNDAR"})',
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Actualizar',
            onPressed: () => setState(() {}),
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app, color: Colors.white70),
            tooltip: 'Cerrar Sesión',
            onPressed: () async {
              await AuthService.logout();
              if (mounted) {
                Navigator.pop(context);
                widget.onLogout?.call();
              }
            },
          ),
        ],
      ),
      body: StreamBuilder<List<UserModel>>(
        stream: AuthService.getFamilyMembersStream(familyId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF)));
          }

          final members = snapshot.data ?? [];
          final usedScreens = members.length;
          const maxScreens = 5;
          final availableScreens = maxScreens - usedScreens;

          return CustomScrollView(
            slivers: [
              // 1. Banner Resumen de Pantallas Familiares
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF101726),
                          _currentUser?.isVip == true
                              ? const Color(0xFF4A148C).withOpacity(0.4)
                              : const Color(0xFF004D40).withOpacity(0.4),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: _currentUser?.isVip == true ? const Color(0xFFC77DFF) : const Color(0xFF00E5FF),
                        width: 1.5,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      _currentUser?.isVip == true ? Icons.stars : Icons.tv,
                                      color: _currentUser?.isVip == true
                                          ? const Color(0xFFFFD700)
                                          : const Color(0xFF00E5FF),
                                      size: 20,
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      _currentUser?.isVip == true ? 'PLAN FAMILIAR VIP' : 'PLAN FAMILIAR ESTÁNDAR',
                                      style: TextStyle(
                                        color: _currentUser?.isVip == true
                                            ? const Color(0xFFFFD700)
                                            : const Color(0xFF00E5FF),
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 1.1,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Administrador: ${_currentUser?.username ?? ""}',
                                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                                ),
                              ],
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: Colors.black45,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Text(
                                '${_currentUser?.daysRemaining ?? 0} días restantes',
                                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        // Barra de progreso de pantallas
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Pantallas Activas: $usedScreens de $maxScreens',
                              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                            ),
                            Text(
                              availableScreens > 0 ? '$availableScreens cupo(s) disponible(s)' : 'Cupo lleno',
                              style: TextStyle(
                                color: availableScreens > 0 ? const Color(0xFF00E676) : Colors.orangeAccent,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                            value: usedScreens / maxScreens,
                            minHeight: 8,
                            backgroundColor: Colors.white12,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              usedScreens == maxScreens ? Colors.orangeAccent : const Color(0xFF00E5FF),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

              // 2. Encabezado de la lista
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    'Dispositivos y Perfiles de la Familia (5 Máximo)',
                    style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              // 3. Lista de miembros familiares
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) {
                      final member = members[index];
                      return _buildFamilyMemberCard(member);
                    },
                    childCount: members.length,
                  ),
                ),
              ),

              const SliverToBoxAdapter(child: SizedBox(height: 90)),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddMemberModal(context, familyId),
        backgroundColor: const Color(0xFF00E5FF),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_to_queue),
        label: const Text('Agregar Pantalla', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }

  Widget _buildFamilyMemberCard(UserModel member) {
    final bool isHead = member.isFamilyAdmin;
    final bool hasHw = member.registeredHardwareId != null && member.registeredHardwareId!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isHead ? const Color(0xFFC77DFF).withOpacity(0.6) : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                backgroundColor: isHead ? const Color(0xFFC77DFF).withOpacity(0.2) : Colors.white10,
                radius: 20,
                child: Icon(
                  isHead ? Icons.admin_panel_settings : Icons.tv,
                  color: isHead ? const Color(0xFFC77DFF) : const Color(0xFF00E5FF),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          member.username,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        const SizedBox(width: 6),
                        if (isHead)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFC77DFF).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFFC77DFF), width: 0.8),
                            ),
                            child: const Text('JEFE', style: TextStyle(color: Color(0xFFC77DFF), fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: member.isVip ? Colors.amber.withOpacity(0.2) : Colors.blueGrey.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            member.isVip ? 'VIP' : 'ESTÁNDAR',
                            style: TextStyle(
                              color: member.isVip ? Colors.amber : Colors.white70,
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      member.deviceName ?? (isHead ? 'Dispositivo Administrador' : 'Dispositivo sin registrar'),
                      style: const TextStyle(color: Colors.white60, fontSize: 12),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.copy, size: 16, color: Colors.white38),
                tooltip: 'Copiar Usuario y Contraseña',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: 'Usuario: ${member.username} | Clave: ${member.password}'));
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Credenciales copiadas para ${member.username}'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          const Divider(color: Colors.white10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(hasHw ? Icons.lock : Icons.lock_open, size: 14, color: hasHw ? const Color(0xFF00E676) : Colors.orangeAccent),
                  const SizedBox(width: 4),
                  Text(
                    hasHw ? 'Dispositivo Vinculado' : 'Pendiente de primer inicio',
                    style: TextStyle(color: hasHw ? const Color(0xFF00E676) : Colors.orangeAccent, fontSize: 11),
                  ),
                ],
              ),
              Row(
                children: [
                  if (hasHw)
                    TextButton.icon(
                      icon: const Icon(Icons.phonelink_erase, size: 14, color: Colors.orangeAccent),
                      label: const Text('Reset HW', style: TextStyle(color: Colors.orangeAccent, fontSize: 11)),
                      onPressed: () => _confirmResetHw(member),
                    ),
                  if (!isHead)
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.redAccent, size: 18),
                      tooltip: 'Eliminar pantalla para liberar cupo',
                      onPressed: () => _confirmDeleteMember(member),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _confirmResetHw(UserModel member) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        title: const Text('¿Liberar Dispositivo?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Esto permitirá que ${member.username} inicie sesión en un nuevo celular o televisor.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await AuthService.adminResetHardware(member.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Dispositivo liberado exitosamente.')),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orangeAccent, foregroundColor: Colors.black),
            child: const Text('Liberar'),
          ),
        ],
      ),
    );
  }

  void _confirmDeleteMember(UserModel member) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        title: const Text('¿Eliminar Pantalla?', style: TextStyle(color: Colors.white)),
        content: Text(
          'Se eliminará a ${member.username} y se liberará 1 cupo para otra pantalla familiar.',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancelar')),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await AuthService.deleteClientUser(member.id);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Pantalla eliminada y cupo liberado.')),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.redAccent, foregroundColor: Colors.white),
            child: const Text('Eliminar'),
          ),
        ],
      ),
    );
  }

  void _showAddMemberModal(BuildContext context, String familyId) {
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final nameCtrl = TextEditingController();
    bool isVip = _currentUser?.isVip ?? false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
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
                  Icon(Icons.tv, color: Color(0xFF00E5FF)),
                  SizedBox(width: 8),
                  Text('Agregar Pantalla Familiar', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: nameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Nombre del Dispositivo / Familiar (Ej: TV Habitación, Hijo)',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: userCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Usuario para ingresar',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Acceso VIP a esta pantalla', style: TextStyle(color: Colors.white, fontSize: 14)),
                subtitle: const Text('Canales premium, 4K y películas/series', style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: isVip,
                activeColor: Colors.amber,
                onChanged: (val) => setModalState(() => isVip = val),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: () async {
                    if (userCtrl.text.trim().isEmpty || passCtrl.text.trim().isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Por favor completa usuario y contraseña.')),
                      );
                      return;
                    }

                    try {
                      await AuthService.addFamilyMember(
                        familyId: familyId,
                        username: userCtrl.text.trim(),
                        password: passCtrl.text.trim(),
                        memberName: nameCtrl.text.trim().isEmpty ? 'Dispositivo Familiar' : nameCtrl.text.trim(),
                        overrideVip: isVip,
                      );
                      if (context.mounted) {
                        Navigator.pop(ctx);
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('¡Pantalla agregada exitosamente!')),
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
                  child: const Text('Guardar y Activar Pantalla', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}