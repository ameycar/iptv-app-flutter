import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/user_model.dart';
import '../services/auth_service.dart';

class AdminPanelScreen extends StatefulWidget {
  const AdminPanelScreen({super.key});

  @override
  State<AdminPanelScreen> createState() => _AdminPanelScreenState();
}

class _AdminPanelScreenState extends State<AdminPanelScreen> {
  final _searchController = TextEditingController();
  String _selectedFilter = 'todos'; // 'todos' | 'pendientes' | 'activos' | 'vencidos'

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
            icon: const Icon(Icons.refresh, color: Colors.white70),
            tooltip: 'Refrescar',
            onPressed: () => setState(() {}),
          ),
          IconButton(
            icon: const Icon(Icons.exit_to_app, color: Colors.white70),
            tooltip: 'Cerrar Sesión',
            onPressed: () async {
              await AuthService.logout();
              if (mounted) Navigator.pop(context);
            },
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showCreateUserModal,
        backgroundColor: const Color(0xFF00E5FF),
        foregroundColor: Colors.black,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Nuevo Cliente', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: Color(0xFF00E5FF)));
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error cargando clientes: ${snapshot.error}', style: const TextStyle(color: Colors.red)),
            );
          }

          final docs = snapshot.data?.docs ?? [];
          final allUsers = docs.map((d) => UserModel.fromMap(d.id, d.data() as Map<String, dynamic>)).toList();

          // Filtrar admins y usuarios según búsqueda y tabs
          final clientUsers = allUsers.where((u) => !u.isAdmin).toList();
          final pendingHwUsers = clientUsers.where((u) => u.hardwareResetRequested).toList();
          final activeUsers = clientUsers.where((u) => u.isActive && !u.isExpired).toList();
          final expiredUsers = clientUsers.where((u) => u.isExpired).toList();

          // Filtro de búsqueda
          final searchTerm = _searchController.text.trim().toLowerCase();
          final filteredUsers = clientUsers.where((u) {
            final matchesSearch = u.username.toLowerCase().contains(searchTerm) ||
                (u.deviceName ?? '').toLowerCase().contains(searchTerm);
            if (!matchesSearch) return false;

            if (_selectedFilter == 'pendientes') return u.hardwareResetRequested;
            if (_selectedFilter == 'activos') return u.isActive && !u.isExpired;
            if (_selectedFilter == 'vencidos') return u.isExpired;
            return true;
          }).toList();

          return CustomScrollView(
            slivers: [
              // 1. Tarjetas de Resumen
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildStatsRow(
                        total: clientUsers.length,
                        active: activeUsers.length,
                        expired: expiredUsers.length,
                        pendingHw: pendingHwUsers.length,
                      ),
                      const SizedBox(height: 16),

                      // 2. BANNER DE SOLICITUDES DE HARDWARE URGENTES
                      if (pendingHwUsers.isNotEmpty) ...[
                        _buildPendingHardwareAlertSection(pendingHwUsers),
                        const SizedBox(height: 16),
                      ],

                      // 3. Barra de Búsqueda y Filtros
                      _buildSearchBar(),
                      const SizedBox(height: 12),
                      _buildFilterChips(pendingHwCount: pendingHwUsers.length),
                    ],
                  ),
                ),
              ),

              // 4. Lista de Clientes
              if (filteredUsers.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text('No hay clientes en esta categoría.', style: TextStyle(color: Colors.white54)),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) => _buildUserCard(filteredUsers[index]),
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

  Widget _buildStatsRow({
    required int total,
    required int active,
    required int expired,
    required int pendingHw,
  }) {
    return Row(
      children: [
        _buildStatCard('Total', total.toString(), const Color(0xFF00E5FF), Icons.people),
        const SizedBox(width: 8),
        _buildStatCard('Activos', active.toString(), const Color(0xFF00E676), Icons.check_circle_outline),
        const SizedBox(width: 8),
        _buildStatCard('Vencidos', expired.toString(), const Color(0xFFFF5252), Icons.timer_off_outlined),
        const SizedBox(width: 8),
        _buildStatCard(
          'HW Reset',
          pendingHw.toString(),
          pendingHw > 0 ? const Color(0xFFFFD600) : Colors.white38,
          Icons.phonelink_lock,
          highlight: pendingHw > 0,
        ),
      ],
    );
  }

  Widget _buildStatCard(String label, String value, Color color, IconData icon, {bool highlight = false}) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: highlight ? const Color(0xFFFFD600).withOpacity(0.15) : const Color(0xFF131A29),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: highlight ? const Color(0xFFFFD600) : Colors.white12),
        ),
        child: Column(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  /// ⚡ ALERTA EXPRESS: Solicitudes de cambio de equipo en tiempo real
  Widget _buildPendingHardwareAlertSection(List<UserModel> pendingList) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFD600).withOpacity(0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFD600), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, color: Color(0xFFFFD600), size: 24),
              const SizedBox(width: 8),
              Text(
                '⚡ ${pendingList.length} Solicitud(es) de Cambio de Hardware',
                style: const TextStyle(color: Color(0xFFFFD600), fontWeight: FontWeight.bold, fontSize: 14),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...pendingList.map((user) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF101726),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            user.username,
                            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          Text(
                            user.deviceName ?? 'Equipo sin nombre',
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    // Botón 1-Toque Liberar
                    ElevatedButton.icon(
                      onPressed: () => _quickResetHardware(user),
                      icon: const Icon(Icons.lock_open, size: 16),
                      label: const Text('Liberar (1-Toque)', style: TextStyle(fontSize: 11)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00E676),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      ),
                    ),
                    const SizedBox(width: 6),
                    // Botón PIN Express WhatsApp
                    IconButton(
                      icon: const Icon(Icons.send_to_mobile, color: Color(0xFF00E5FF)),
                      tooltip: 'Generar PIN para WhatsApp',
                      onPressed: () => _generatePinAndShare(user),
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
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: 'Buscar por usuario o dispositivo...',
        hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
        prefixIcon: const Icon(Icons.search, color: Color(0xFF00E5FF), size: 20),
        filled: true,
        fillColor: const Color(0xFF131A29),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
      ),
    );
  }

  Widget _buildFilterChips({required int pendingHwCount}) {
    final filters = [
      {'key': 'todos', 'label': 'Todos'},
      {'key': 'pendientes', 'label': '⚡ HW Reset ($pendingHwCount)'},
      {'key': 'activos', 'label': 'Activos'},
      {'key': 'vencidos', 'label': 'Vencidos'},
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: filters.map((f) {
          final isSelected = _selectedFilter == f['key'];
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: Text(f['label']!),
              selected: isSelected,
              onSelected: (_) => setState(() => _selectedFilter = f['key']!),
              selectedColor: const Color(0xFF00E5FF),
              backgroundColor: const Color(0xFF131A29),
              labelStyle: TextStyle(
                color: isSelected ? Colors.black : Colors.white70,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 12,
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildUserCard(UserModel user) {
    final isLocked = user.registeredHardwareId != null && user.registeredHardwareId!.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: user.hardwareResetRequested
              ? const Color(0xFFFFD600)
              : (user.isExpired ? const Color(0xFFFF5252).withOpacity(0.5) : Colors.white10),
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
                child: Icon(
                  Icons.person,
                  color: user.isActive ? const Color(0xFF00E5FF) : Colors.white38,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          user.username,
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                        if (user.isVip) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD600),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text('VIP', style: TextStyle(color: Colors.black, fontSize: 9, fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Vence: ${_formatDate(user.expirationDate)} (${user.daysRemaining} días restantes)',
                      style: TextStyle(
                        color: user.isExpired ? const Color(0xFFFF5252) : Colors.white54,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),

              // Switch Activo/Desactivado
              Switch(
                value: user.isActive,
                activeColor: const Color(0xFF00E676),
                onChanged: (val) {
                  FirebaseFirestore.instance.collection('users').doc(user.id).update({'isActive': val});
                },
              ),
            ],
          ),

          const SizedBox(height: 10),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 10),

          // Estado del Dispositivo Blindado
          Row(
            children: [
              Icon(
                isLocked ? Icons.phonelink_lock : Icons.phonelink_erase,
                size: 16,
                color: isLocked ? const Color(0xFF00E5FF) : Colors.white38,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  isLocked ? 'Vinculado: ${user.deviceName ?? user.registeredHardwareId}' : 'Sin dispositivo asignado',
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          const SizedBox(height: 10),

          // Botones de Acción Rápida
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Botón 1: Resetear Hardware
              TextButton.icon(
                onPressed: () => _quickResetHardware(user),
                icon: const Icon(Icons.refresh, size: 16, color: Color(0xFFFFD600)),
                label: const Text('Reset HW', style: TextStyle(color: Color(0xFFFFD600), fontSize: 11)),
              ),
              // Botón 2: +30 Días
              TextButton.icon(
                onPressed: () => _extendSubscription(user, 30),
                icon: const Icon(Icons.add_circle_outline, size: 16, color: Color(0xFF00E676)),
                label: const Text('+30 Días', style: TextStyle(color: Color(0xFF00E676), fontSize: 11)),
              ),
              // Botón 3: Generar PIN WhatsApp
              IconButton(
                icon: const Icon(Icons.pin, size: 18, color: Color(0xFF00E5FF)),
                tooltip: 'Generar PIN Express',
                onPressed: () => _generatePinAndShare(user),
              ),
              // Botón 4: Eliminar
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 18, color: Colors.white38),
                tooltip: 'Eliminar usuario',
                onPressed: () => _deleteUser(user),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _quickResetHardware(UserModel user) async {
    final ok = await AuthService.adminResetHardware(user.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: ok ? const Color(0xFF00C853) : Colors.red,
          content: Text(ok ? '⚡ Hardware de ${user.username} liberado al instante.' : 'Error liberando hardware.'),
        ),
      );
    }
  }

  Future<void> _generatePinAndShare(UserModel user) async {
    final pin = await AuthService.adminGenerateExpressPin(user.id);
    if (pin != null && mounted) {
      Clipboard.setData(ClipboardData(text: pin));
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF131A29),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text('PIN Generado para ${user.username}', style: const TextStyle(color: Colors.white, fontSize: 16)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Copiado al portapapeles. Pégalo en WhatsApp:', style: TextStyle(color: Colors.white70, fontSize: 13)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5FF).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFF00E5FF)),
                ),
                child: Text(
                  pin,
                  style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 28, letterSpacing: 8, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx),
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E5FF)),
              child: const Text('Listo', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _extendSubscription(UserModel user, int days) async {
    final newExp = user.isExpired ? DateTime.now().add(Duration(days: days)) : user.expirationDate.add(Duration(days: days));
    await FirebaseFirestore.instance.collection('users').doc(user.id).update({
      'expirationDate': Timestamp.fromDate(newExp),
      'isActive': true,
    });
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(backgroundColor: const Color(0xFF00C853), content: Text('Suscripción de ${user.username} extendida +$days días.')),
      );
    }
  }

  Future<void> _deleteUser(UserModel user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131A29),
        title: const Text('Eliminar Cliente', style: TextStyle(color: Colors.white)),
        content: Text('¿Estás seguro de eliminar al usuario "${user.username}"?', style: const TextStyle(color: Colors.white70)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancelar', style: TextStyle(color: Colors.white54))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Eliminar', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await FirebaseFirestore.instance.collection('users').doc(user.id).delete();
    }
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
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(context).viewInsets.bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.person_add, color: Color(0xFF00E5FF)),
                  SizedBox(width: 8),
                  Text('Nuevo Cliente VIP', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                ],
              ),
              const SizedBox(height: 16),
              TextField(
                controller: usernameCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Nombre de Usuario',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.04),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: passwordCtrl,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  labelStyle: const TextStyle(color: Colors.white60),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.04),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
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

                  final docRef = FirebaseFirestore.instance.collection('users').doc();
                  final newUser = UserModel(
                    id: docRef.id,
                    username: uname,
                    password: pwd,
                    role: 'user',
                    isActive: true,
                    isVip: isVip,
                    expirationDate: DateTime.now().add(Duration(days: selectedMonths * 30)),
                  );
                  await docRef.set(newUser.toMap());
                  if (context.mounted) Navigator.pop(ctx);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  minimumSize: const Size(double.infinity, 44),
                ),
                child: const Text('CREAR Y GUARDAR CLIENTE', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}