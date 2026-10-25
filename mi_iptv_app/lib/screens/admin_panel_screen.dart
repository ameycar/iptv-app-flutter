import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';

class AdminPanelScreen extends StatefulWidget {
  final VoidCallback? onLogout;
  const AdminPanelScreen({super.key, this.onLogout});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _searchController = TextEditingController();
  String _selectedFilter = 'todos';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF090D16),
      appBar: AppBar(
        backgroundColor: const Color(0xFF101726),
        elevation: 0,
        title: const Row(
          children: [
            Icon(Icons.shield_outlined, color: Color(0xFF00E5FF)),
            SizedBox(width: 8),
            Text(
              'Panel Administrador VIP',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.confirmation_number_outlined, color: Color(0xFF00E676)),
            tooltip: 'Pines de Activación 24/7',
            onPressed: () => _showPinsManagerModal(context),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Refrescar',
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
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateOptionsModal,
        backgroundColor: const Color(0xFF00E5FF),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.add_circle_outline),
        label: const Text('Nuevo Registro', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<List<UserModel>>(
        stream: AuthService.getUsersStream(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF)));
          }

          final allUsers = snapshot.data ?? [];
          final clientUsers = allUsers.where((u) => !u.isAdmin).toList();
          final familyAdminUsers = clientUsers.where((u) => u.isFamilyAdmin).toList();
          final individualUsers = clientUsers.where((u) => !u.isPartOfFamily).toList();
          final pendingHwUsers = clientUsers.where((u) => u.hardwareResetRequested).toList();
          final activeUsers = clientUsers.where((u) => u.isActive && !u.isExpired).toList();
          final expiredUsers = clientUsers.where((u) => u.isExpired).toList();

          final searchTerm = _searchController.text.trim().toLowerCase();
          final filteredUsers = clientUsers.where((u) {
            final matchesSearch = u.username.toLowerCase().contains(searchTerm) ||
                (u.deviceName ?? '').toLowerCase().contains(searchTerm) ||
                (u.familyId ?? '').toLowerCase().contains(searchTerm);
            if (!matchesSearch) return false;

            if (_selectedFilter == 'familias') return u.isFamilyAdmin;
            if (_selectedFilter == 'individuales') return !u.isPartOfFamily;
            if (_selectedFilter == 'pendientes') return u.hardwareResetRequested;
            if (_selectedFilter == 'activos') return u.isActive && !u.isExpired;
            if (_selectedFilter == 'vencidos') return u.isExpired;
            return true;
          }).toList();

          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        margin: const EdgeInsets.only(bottom: 14),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: AuthService.isFirebaseAvailable
                              ? const Color(0xFF00E676).withOpacity(0.12)
                              : const Color(0xFF00E5FF).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: AuthService.isFirebaseAvailable
                                ? const Color(0xFF00E676).withOpacity(0.4)
                                : const Color(0xFF00E5FF).withOpacity(0.35),
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              AuthService.isFirebaseAvailable ? Icons.cloud_done : Icons.shield,
                              color: AuthService.isFirebaseAvailable ? const Color(0xFF00E676) : const Color(0xFF00E5FF),
                              size: 18,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                AuthService.isFirebaseAvailable
                                    ? 'Sincronización en la Nube Activa (Base de datos Firestore en vivo).'
                                    : 'Modo Autónomo Local Activo (Base de datos segura en este equipo).',
                                style: TextStyle(
                                  color: AuthService.isFirebaseAvailable ? const Color(0xFF00E676) : const Color(0xFF00E5FF),
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      _buildStatsRow(
                        total: clientUsers.length,
                        families: familyAdminUsers.length,
                        individuals: individualUsers.length,
                        pendingHw: pendingHwUsers.length,
                      ),
                      const SizedBox(height: 16),
                      if (pendingHwUsers.isNotEmpty) ...[
                        _buildPendingHardwareAlertSection(pendingHwUsers),
                        const SizedBox(height: 16),
                      ],
                      _buildSearchBar(),
                      const SizedBox(height: 12),
                      _buildFilterChips(
                        pendingHwCount: pendingHwUsers.length,
                        familyCount: familyAdminUsers.length,
                        individualCount: individualUsers.length,
                      ),
                    ],
                  ),
                ),
              ),
              if (filteredUsers.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.person_outline, color: Colors.white24, size: 48),
                          SizedBox(height: 8),
                          Text('No hay registros aún.', style: TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.bold)),
                          SizedBox(height: 4),
                          Text('Toca "Nuevo Registro" para crear clientes o familias.', style: TextStyle(color: Colors.white38, fontSize: 12)),
                        ],
                      ),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final user = filteredUsers[index];
                        if (user.isFamilyAdmin) {
                          return _buildFamilyGroupCard(user, allUsers);
                        }
                        return _buildUserCard(user);
                      },
                      childCount: filteredUsers.length,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 80)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildStatsRow({required int total, required int families, required int individuals, required int pendingHw}) {
    return Row(
      children: [
        _buildStatCard('Pantallas', total.toString(), const Color(0xFF00E5FF), Icons.devices),
        const SizedBox(width: 8),
        _buildStatCard('Familias (5)', families.toString(), const Color(0xFFC77DFF), Icons.family_restroom),
        const SizedBox(width: 8),
        _buildStatCard('Individual', individuals.toString(), const Color(0xFF00E676), Icons.person),
        const SizedBox(width: 8),
        _buildStatCard('HW Reset', pendingHw.toString(), pendingHw > 0 ? const Color(0xFFFFD600) : Colors.white38, Icons.phonelink_lock, highlight: pendingHw > 0),
      ],
    );
  }

  Widget _buildStatCard(String title, String value, Color color, IconData icon, {bool highlight = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: highlight ? color.withOpacity(0.18) : const Color(0xFF101726),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: highlight ? color : Colors.white10),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(title, style: const TextStyle(color: Colors.white60, fontSize: 10), maxLines: 1),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingHardwareAlertSection(List<UserModel> pendingUsers) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFD600).withOpacity(0.15),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD600), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notification_important, color: Color(0xFFFFD600), size: 20),
              const SizedBox(width: 8),
              Text('${pendingUsers.length} SOLICITUD(ES) DE RESET DE HARDWARE', style: const TextStyle(color: Color(0xFFFFD600), fontWeight: FontWeight.bold, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 8),
          ...pendingUsers.map((u) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(u.username, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                    ElevatedButton.icon(
                      icon: const Icon(Icons.flash_on, size: 14),
                      label: const Text('Liberar HW', style: TextStyle(fontSize: 11)),
                      onPressed: () => _showErgonomicResetModal(context, u), 
                      style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFFD600), foregroundColor: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4)),
                    ),
                  ],
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return TextField(
      controller: _searchController,
      onChanged: (_) => setState(() {}),
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Buscar por usuario, equipo o familia...',
        hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Color(0xFF00E5FF), size: 20),
        suffixIcon: _searchController.text.isNotEmpty
            ? IconButton(icon: const Icon(Icons.clear, color: Colors.white54, size: 18), onPressed: () { _searchController.clear(); setState(() {}); })
            : null,
        filled: true,
        fillColor: const Color(0xFF101726),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  Widget _buildFilterChips({required int pendingHwCount, required int familyCount, required int individualCount}) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _buildFilterChip('todos', 'Todos'),
          const SizedBox(width: 8),
          _buildFilterChip('familias', 'Familias ($familyCount)'),
          const SizedBox(width: 8),
          _buildFilterChip('individuales', 'Individuales ($individualCount)'),
          const SizedBox(width: 8),
          _buildFilterChip('pendientes', 'HW Reset ($pendingHwCount)', isWarning: pendingHwCount > 0),
          const SizedBox(width: 8),
          _buildFilterChip('activos', 'Activos'),
          const SizedBox(width: 8),
          _buildFilterChip('vencidos', 'Vencidos'),
        ],
      ),
    );
  }

  Widget _buildFilterChip(String key, String label, {bool isWarning = false}) {
    final isSelected = _selectedFilter == key;
    return ChoiceChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => setState(() => _selectedFilter = key),
      selectedColor: isWarning ? const Color(0xFFFFD600) : const Color(0xFF00E5FF),
      backgroundColor: const Color(0xFF101726),
      labelStyle: TextStyle(
        color: isSelected ? Colors.black : (isWarning ? const Color(0xFFFFD600) : Colors.white70),
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 12,
      ),
    );
  }

  // --- LÓGICA DE INTERFAZ DUAL (MÓVIL Y TV) ---
  Widget _buildDualDeviceIndicator(UserModel user) {
    final hasHw = user.registeredHardwareId != null && user.registeredHardwareId!.isNotEmpty;
    final bool isMobileLinked = false; 
    final bool isTvLinked = hasHw;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildDeviceIcon(Icons.smartphone, isMobileLinked),
        const SizedBox(width: 6),
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
            size: 16,
            color: isLinked ? const Color(0xFF00E5FF) : Colors.white38,
          ),
        ),
        if (!isLinked)
          const Positioned(
            right: -2,
            top: -2,
            child: Icon(Icons.lock, size: 10, color: Colors.redAccent),
          ),
      ],
    );
  }

  Widget _buildFamilyGroupCard(UserModel familyAdmin, List<UserModel> allUsers) {
    final familyId = familyAdmin.familyId ?? '';
    final members = allUsers.where((u) => u.familyId == familyId).toList();
    final usedScreens = members.length;
    final isVip = familyAdmin.isVip;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: isVip ? const Color(0xFFC77DFF) : const Color(0xFF00E5FF), width: 1.5),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.all(12),
        leading: CircleAvatar(
          backgroundColor: isVip ? const Color(0xFFC77DFF).withOpacity(0.2) : const Color(0xFF00E5FF).withOpacity(0.2),
          child: Icon(Icons.family_restroom, color: isVip ? const Color(0xFFC77DFF) : const Color(0xFF00E5FF)),
        ),
        title: Row(
          children: [
            Expanded(child: Text('FAMILIA: ${familyAdmin.username.toUpperCase()}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15))),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: isVip ? Colors.amber.withOpacity(0.2) : Colors.blueGrey.withOpacity(0.2), borderRadius: BorderRadius.circular(4)),
              child: Text(isVip ? 'FAMILIA VIP' : 'ESTÁNDAR', style: TextStyle(color: isVip ? Colors.amber : Colors.white70, fontSize: 10, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        subtitle: Text('Pantallas: $usedScreens / 5 en uso • Vence: ${_formatDate(familyAdmin.expirationDate)} (${familyAdmin.daysRemaining} días)', style: const TextStyle(color: Colors.white60, fontSize: 12)),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(color: Colors.white12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Miembros y Dispositivos:', style: TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
                    Row(
                      children: [
                        TextButton.icon(
                          icon: const Icon(Icons.add_circle, size: 14, color: Color(0xFF00E5FF)),
                          label: const Text('+30 Días', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11)),
                          onPressed: () async {
                            await AuthService.renewFamilyGroup(familyId, 30);
                            setState(() {});
                            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Plan familiar renovado +30 días.')));
                          },
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_forever, color: Colors.redAccent, size: 18),
                          tooltip: 'Eliminar Familia Completa',
                          onPressed: () => _deleteUser(familyAdmin),
                        ),
                      ],
                    ),
                  ],
                ),
                ...members.map((m) {
                  final isHead = m.isFamilyAdmin;
                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.04), borderRadius: BorderRadius.circular(8)),
                    child: Row(
                      children: [
                        Icon(isHead ? Icons.admin_panel_settings : Icons.tv, size: 16, color: isHead ? const Color(0xFFC77DFF) : const Color(0xFF00E5FF)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${m.username} (${m.deviceName ?? "Sin asignar"})', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 4),
                              _buildDualDeviceIndicator(m),
                            ],
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFFFD600)), tooltip: 'Reset HW', onPressed: () => _showErgonomicResetModal(context, m)),
                      ],
                    ),
                  );
                }),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserCard(UserModel user) {
    final isPendingHw = user.hardwareResetRequested;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isPendingHw ? const Color(0xFFFFD600) : (user.isExpired ? const Color(0xFFFF5252).withOpacity(0.5) : Colors.white10),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: user.isActive ? const Color(0xFF00E5FF).withOpacity(0.2) : Colors.white12,
                child: Icon(Icons.person, color: user.isActive ? const Color(0xFF00E5FF) : Colors.white38, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(user.username, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                        if (user.isVip) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(color: const Color(0xFFFFD600), borderRadius: BorderRadius.circular(4)),
                            child: const Text('VIP', style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text('Vence: ${_formatDate(user.expirationDate)} (${user.daysRemaining} días restantes)', style: TextStyle(color: user.isExpired ? const Color(0xFFFF5252) : Colors.white54, fontSize: 11)),
                  ],
                ),
              ),
              Switch(
                value: user.isActive,
                activeColor: const Color(0xFF00E676),
                onChanged: (val) async {
                  await AuthService.updateClientUser(user.id, {'isActive': val});
                  setState(() {});
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Dispositivos Vinculados:', style: TextStyle(color: Colors.white70, fontSize: 11)),
              _buildDualDeviceIndicator(user),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton.icon(onPressed: () => _showErgonomicResetModal(context, user), icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFFFD600)), label: const Text('Reset HW', style: TextStyle(color: Color(0xFFFFD600), fontSize: 11))),
              TextButton.icon(onPressed: () => _extendSubscription(user, 30), icon: const Icon(Icons.add_circle_outline, size: 16, color: Color(0xFF00E676)), label: const Text('+30 Días', style: TextStyle(color: Color(0xFF00E676), fontSize: 11))),
              IconButton(onPressed: () => _generatePinAndShare(user), icon: const Icon(Icons.pin, size: 18, color: Color(0xFF00E5FF)), tooltip: 'PIN Express'),
              IconButton(onPressed: () => _deleteUser(user), icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white38), tooltip: 'Eliminar'),
            ],
          ),
        ],
      ),
    );
  }

  // --- MODAL DE RESET ERGONÓMICO ---
  void _showErgonomicResetModal(BuildContext context, UserModel user) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF131A29),
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
              'Selecciona qué dispositivo deseas liberar para el usuario "${user.username}".',
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
    final success = await AuthService.adminResetHardware(user.id);
    if (success && mounted) {
      setState(() {});
      String msg = type == 'mobile' ? 'Celular liberado.' : type == 'tv' ? 'Smart TV liberada.' : 'Ambos dispositivos liberados.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: const Color(0xFF00C853), content: Text('$msg (Usuario: ${user.username})')),
      );
    }
  }

  Future<void> _generatePinAndShare(UserModel user) async {
    final pin = await AuthService.adminGenerateExpressPin(user.id);
    if (pin != null && mounted) {
      setState(() {});
      Clipboard.setData(ClipboardData(text: pin));
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF131A29),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('PIN para ${user.username}', style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: Text(pin, style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
          actions: [ElevatedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Listo'))],
        ),
      );
    }
  }

  Future<void> _extendSubscription(UserModel user, int days) async {
    final newExp = user.isExpired ? DateTime.now().add(Duration(days: days)) : user.expirationDate.add(Duration(days: days));
    await AuthService.updateClientUser(user.id, {'expirationDate': newExp.toIso8601String(), 'isActive': true});
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(backgroundColor: const Color(0xFF00C853), content: Text('Suscripción extendida +$days días.')));
    }
  }

  Future<void> _deleteUser(UserModel user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        title: const Text('¿Eliminar Registro?', style: TextStyle(color: Colors.white)),
        content: Text('¿Seguro de eliminar a "${user.username}"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: Colors.red), child: const Text('Eliminar')),
        ],
      ),
    );
    if (confirm == true) {
      await AuthService.deleteClientUser(user.id);
      if (mounted) setState(() {});
    }
  }

  void _showCreateOptionsModal() {
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
            const Text('¿Qué tipo de registro deseas realizar?', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ListTile(
              tileColor: const Color(0xFF131A29),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF00E5FF))),
              leading: const Icon(Icons.person_add, color: Color(0xFF00E5FF)),
              title: const Text('Cliente Individual (1 Perfil = Celular + TV)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text('Puede vincular 1 Móvil y 1 Smart TV independientemente', style: TextStyle(color: Colors.white60, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showCreateUserModal();
              },
            ),
            const SizedBox(height: 12),
            ListTile(
              tileColor: const Color(0xFF131A29),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFFC77DFF))),
              leading: const Icon(Icons.family_restroom, color: Color(0xFFC77DFF)),
              title: const Text('Grupo Familiar (Hasta 5 Pantallas)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text('Cada perfil puede tener 1 Móvil y 1 TV', style: TextStyle(color: Colors.white60, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showCreateFamilyModal();
              },
            ),
            const SizedBox(height: 12),
            ListTile(
              tileColor: const Color(0xFF131A29),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Color(0xFF00E676))),
              leading: const Icon(Icons.confirmation_number_outlined, color: Color(0xFF00E676)),
              title: const Text('Generar Pines de Activación 24/7 (Vouchers)', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
              subtitle: const Text('Códigos prepagados para WhatsApp, Mercadolibre o revendedores.', style: TextStyle(color: Colors.white60, fontSize: 12)),
              onTap: () {
                Navigator.pop(ctx);
                _showPinsManagerModal(context);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _showCreateFamilyModal() {
    final familyNameCtrl = TextEditingController();
    final adminUserCtrl = TextEditingController();
    final adminPassCtrl = TextEditingController();
    int selectedMonths = 1;
    bool isVip = true;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.family_restroom, color: Color(0xFFC77DFF)),
                  SizedBox(width: 8),
                  Text('Nuevo Grupo Familiar (5 Pantallas)', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 14),
              TextField(
                controller: familyNameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Nombre de la Familia (Ej: Garcia, Acosta)', filled: true, fillColor: Colors.white.withOpacity(0.04), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: adminUserCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Usuario del Jefe de Familia', filled: true, fillColor: Colors.white.withOpacity(0.04), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: adminPassCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Contraseña del Jefe de Familia', filled: true, fillColor: Colors.white.withOpacity(0.04), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 12),
              const Text('Duración del Plan Familiar:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 6),
              Row(
                children: [1, 3, 6, 12].map((months) {
                  final sel = selectedMonths == months;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('$months ${months == 1 ? "mes" : "meses"}'),
                      selected: sel,
                      onSelected: (_) => setModalState(() => selectedMonths = months),
                      selectedColor: const Color(0xFFC77DFF),
                      labelStyle: TextStyle(color: sel ? Colors.black : Colors.white70, fontWeight: sel ? FontWeight.bold : FontWeight.normal),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Paquete Familia VIP', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Si se apaga, será Familia Estándar', style: TextStyle(color: Colors.white54, fontSize: 12)),
                value: isVip,
                activeColor: Colors.amber,
                onChanged: (v) => setModalState(() => isVip = v),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final famName = familyNameCtrl.text.trim();
                  final uname = adminUserCtrl.text.trim();
                  final pwd = adminPassCtrl.text.trim();
                  if (famName.isEmpty || uname.isEmpty || pwd.isEmpty) return;
                  
                  // MAGIA DE REFERIDOS: Generamos el código automáticamente
                  final cleanName = uname.toUpperCase().replaceAll(' ', '');
                  final refCode = 'AMEY-$cleanName-${Random().nextInt(9999).toString().padLeft(4, '0')}';

                  await AuthService.createFamilyGroup(
                    familyName: famName,
                    adminUsername: uname,
                    adminPassword: pwd,
                    isVip: isVip,
                    expirationDate: DateTime.now().add(Duration(days: selectedMonths * 30)),
                  );

                  if (context.mounted) {
                    Navigator.pop(ctx);
                    setState(() {});
                    
                    // VENTANA EMERGENTE CON LOS DATOS LISTOS PARA MANDAR POR WHATSAPP
                    _showSuccessDialog(uname, pwd, refCode);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFC77DFF), foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 44)),
                child: const Text('CREAR GRUPO FAMILIAR (5 CUPOS)', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCreateUserModal() {
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    int selectedMonths = 1;
    bool isVip = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (context, setModalState) => Padding(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: MediaQuery.of(context).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.person_add, color: Color(0xFF00E5FF)),
                  SizedBox(width: 8),
                  Text('Nuevo Cliente Individual', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: usernameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Nombre de Usuario', filled: true, fillColor: Colors.white.withOpacity(0.04), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(labelText: 'Contraseña', filled: true, fillColor: Colors.white.withOpacity(0.04), border: OutlineInputBorder(borderRadius: BorderRadius.circular(10))),
              ),
              const SizedBox(height: 14),
              const Text('Duración de Suscripción:', style: TextStyle(color: Colors.white70, fontSize: 12)),
              const SizedBox(height: 8),
              Row(
                children: [1, 3, 6, 12].map((months) {
                  final sel = selectedMonths == months;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text('$months ${months == 1 ? "mes" : "meses"}'),
                      selected: sel,
                      onSelected: (_) => setModalState(() => selectedMonths = months),
                      selectedColor: const Color(0xFF00E5FF),
                      labelStyle: TextStyle(color: sel ? Colors.black : Colors.white70, fontWeight: sel ? FontWeight.bold : FontWeight.normal),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Acceso VIP Completo', style: TextStyle(color: Colors.white)),
                value: isVip,
                activeColor: const Color(0xFFFFD600),
                onChanged: (v) => setModalState(() => isVip = v),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final uname = usernameCtrl.text.trim();
                  final pwd = passwordCtrl.text.trim();
                  if (uname.isEmpty || pwd.isEmpty) return;

                  final id = 'usr_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(9999)}';
                  
                  // MAGIA DE REFERIDOS: Generamos el código de invitación único
                  final cleanName = uname.toUpperCase().replaceAll(' ', '');
                  final refCode = 'AMEY-$cleanName-${Random().nextInt(9999).toString().padLeft(4, '0')}';

                  final newUser = UserModel(
                    id: id,
                    username: uname,
                    password: pwd,
                    role: 'user',
                    isActive: true,
                    isVip: isVip,
                    expirationDate: DateTime.now().add(Duration(days: selectedMonths * 30)),
                    // IMPORTANTE: Cuando agregues la propiedad 'referralCode' a tu UserModel,
                    // podrás descomentar esta línea para que se guarde directo en tu BD.
                    // referralCode: refCode, 
                  );
                  
                  await AuthService.createClientUser(newUser);
                  
                  // Inyectamos el código a Firebase usando el actualizador de mapas para no romper nada
                  await AuthService.updateClientUser(id, {'referralCode': refCode});

                  if (context.mounted) {
                    Navigator.pop(ctx);
                    setState(() {});
                    
                    // VENTANA EMERGENTE CON LOS DATOS LISTOS PARA MANDAR POR WHATSAPP
                    _showSuccessDialog(uname, pwd, refCode);
                  }
                },
                style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF), foregroundColor: Colors.black, minimumSize: const Size(double.infinity, 44)),
                child: const Text('CREAR Y GUARDAR CLIENTE', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  // NUEVO MODAL DE ÉXITO: Para copiar y enviar los datos del cliente + Referido
  void _showSuccessDialog(String uname, String pwd, String refCode) {
    showDialog(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: Color(0xFF00E676), width: 1.5),
        ),
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: Color(0xFF00E676)),
            SizedBox(width: 10),
            Text('¡Cliente Creado!', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Envía estos datos al cliente:', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('👤 Usuario: $uname', style: const TextStyle(color: Colors.white, fontSize: 14)),
                  const SizedBox(height: 4),
                  Text('🔑 Clave: $pwd', style: const TextStyle(color: Colors.white, fontSize: 14)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text('Su Código de Invitación (El Círculo AMEYCAR):', style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(height: 6),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFD600).withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFFFD600)),
              ),
              child: Text(
                refCode,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Color(0xFFFFD600), fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 2),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cerrar', style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton.icon(
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copiar Todo'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00E676),
              foregroundColor: Colors.black,
            ),
            onPressed: () {
              final msg = '¡Hola! Bienvenido a AMEYCAR TV 🍿\n\n👤 Usuario: $uname\n🔑 Clave: $pwd\n\n🎁 *CLUB DE REFERIDOS*\nSi un amigo compra un plan e ingresa tu código: *$refCode*, ¡Tú ganas 15 Días GRATIS automáticamente!';
              Clipboard.setData(ClipboardData(text: msg));
              Navigator.pop(dCtx);
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('¡Datos copiados! Listos para pegar en WhatsApp.')));
            },
          ),
        ],
      ),
    );
  }

  void _showPinsManagerModal(BuildContext context) {
    int count = 5;
    int days = 30;
    bool isVip = true;
    bool isGenerating = false;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF101726),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.85,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Row(
                      children: [
                        Icon(Icons.confirmation_number, color: Color(0xFF00E676)),
                        SizedBox(width: 8),
                        Text(
                          'Pines de Activación 24/7',
                          style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white54),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Genera lotes de códigos para clientes o revendedores. Al canjearlos en la app, la cuenta se extiende automáticamente.',
                  style: TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 14),

                // GENERADOR RÁPIDO
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131A29),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Generar Nuevo Lote:', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: count,
                              dropdownColor: const Color(0xFF131A29),
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                labelText: 'Cantidad',
                                labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                                filled: true,
                                fillColor: Colors.black26,
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              items: const [
                                DropdownMenuItem(value: 1, child: Text('1 PIN')),
                                DropdownMenuItem(value: 5, child: Text('5 Pines')),
                                DropdownMenuItem(value: 10, child: Text('10 Pines')),
                                DropdownMenuItem(value: 25, child: Text('25 Pines')),
                              ],
                              onChanged: (v) => setModalState(() => count = v ?? 5),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: DropdownButtonFormField<int>(
                              value: days,
                              dropdownColor: const Color(0xFF131A29),
                              style: const TextStyle(color: Colors.white, fontSize: 12),
                              decoration: InputDecoration(
                                labelText: 'Duración',
                                labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                                filled: true,
                                fillColor: Colors.black26,
                                isDense: true,
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                              items: const [
                                DropdownMenuItem(value: 30, child: Text('30 Días (1M)')),
                                DropdownMenuItem(value: 90, child: Text('90 Días (3M)')),
                                DropdownMenuItem(value: 365, child: Text('365 Días (1A)')),
                              ],
                              onChanged: (v) => setModalState(() => days = v ?? 30),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Checkbox(
                                value: isVip,
                                activeColor: Colors.amber,
                                onChanged: (v) => setModalState(() => isVip = v ?? true),
                              ),
                              const Text('VIP', style: TextStyle(color: Colors.white, fontSize: 12)),
                            ],
                          ),
                          ElevatedButton.icon(
                            icon: const Icon(Icons.bolt, size: 16),
                            label: Text(isGenerating ? 'Generando...' : 'Crear Pines'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E676),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                            ),
                            onPressed: isGenerating
                                ? null
                                : () async {
                                    setModalState(() => isGenerating = true);
                                    final codes = await AuthService.generateActivationPins(
                                      count: count,
                                      days: days,
                                      isVip: isVip,
                                    );
                                    setModalState(() => isGenerating = false);
                                    if (ctx.mounted) {
                                      Clipboard.setData(ClipboardData(text: codes.join('\n')));
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text('¡${count} Pines generados y copiados al portapapeles!'),
                                          backgroundColor: const Color(0xFF00E676),
                                        ),
                                      );
                                    }
                                  },
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                const Text('Pines en el Sistema:', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),

                // LISTA DE PINES EN TIEMPO REAL
                Expanded(
                  child: StreamBuilder<List<ActivationPinModel>>(
                    stream: AuthService.getActivationPinsStream(),
                    builder: (context, snapshot) {
                      final pins = snapshot.data ?? [];
                      if (pins.isEmpty) {
                        return const Center(
                          child: Text(
                            'No hay pines generados aún.\nGenera el primer lote arriba.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white38, fontSize: 13),
                          ),
                        );
                      }

                      return ListView.builder(
                        itemCount: pins.length,
                        itemBuilder: (ctx, i) {
                          final pin = pins[i];
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF131A29),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: pin.isUsed ? Colors.white10 : const Color(0xFF00E676).withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  pin.isUsed ? Icons.check_circle_outline : Icons.confirmation_number_outlined,
                                  color: pin.isUsed ? Colors.white38 : const Color(0xFF00E676),
                                  size: 18,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        pin.code,
                                        style: TextStyle(
                                          color: pin.isUsed ? Colors.white54 : Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 13,
                                          letterSpacing: 1,
                                          decoration: pin.isUsed ? TextDecoration.lineThrough : null,
                                        ),
                                      ),
                                      Text(
                                        pin.isUsed
                                            ? 'Canjeado por ${pin.usedBy ?? "Cliente"}'
                                            : '+${pin.days} Días • ${pin.isVip ? "VIP" : "Estándar"} • Disponible',
                                        style: TextStyle(
                                          color: pin.isUsed ? Colors.white38 : const Color(0xFF00E5FF),
                                          fontSize: 10.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.copy, size: 16, color: Colors.white54),
                                  tooltip: 'Copiar PIN',
                                  onPressed: () {
                                    Clipboard.setData(ClipboardData(text: pin.code));
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('PIN ${pin.code} copiado')),
                                    );
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}