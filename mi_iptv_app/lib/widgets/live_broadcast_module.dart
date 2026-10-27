import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

class LiveBroadcastBanner extends StatefulWidget {
  static const String currentAppBuildVersion = '2.4.0';

  const LiveBroadcastBanner({super.key});

  @override
  State<LiveBroadcastBanner> createState() => _LiveBroadcastBannerState();
}

class _LiveBroadcastBannerState extends State<LiveBroadcastBanner> {
  String _dismissedBannerId = '';
  String _shownUpdateVersion = '';

  @override
  void initState() {
    super.initState();
    _loadDismissedState();
  }

  Future<void> _loadDismissedState() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _dismissedBannerId = prefs.getString('dismissed_broadcast_id') ?? '';
      _shownUpdateVersion = prefs.getString('shown_update_version') ?? '';
    });
  }

  void _checkAndShowUpdateDialog(Map<String, dynamic> data) {
    if (kIsWeb) return; // En Web Netlify siempre sirve la última versión automáticamente
    final bool updateActive = data['updateActive'] == true;
    final String latestVersion = (data['latestVersion'] ?? '').toString().trim();
    final String apkUrl = (data['apkDownloadUrl'] ?? '').toString().trim();
    final String updateNotes = (data['updateNotes'] ?? 'Mejoras de estabilidad, velocidad y nuevos canales.').toString();
    final bool forceUpdate = data['forceUpdate'] == true;

    if (!updateActive || latestVersion.isEmpty) return;
    if (latestVersion == LiveBroadcastBanner.currentAppBuildVersion) return;
    if (!forceUpdate && _shownUpdateVersion == latestVersion) return;

    _shownUpdateVersion = latestVersion;
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString('shown_update_version', latestVersion);
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: !forceUpdate,
        builder: (ctx) => PopScope(
          canPop: !forceUpdate,
          child: AlertDialog(
            backgroundColor: const Color(0xFF111827),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: const BorderSide(color: Color(0xFF00E5FF), width: 1.5),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00E5FF).withOpacity(0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.system_update_rounded, color: Color(0xFF00E5FF), size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '¡Nueva Versión v$latestVersion!',
                    style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900),
                  ),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  updateNotes,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1F2937),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    'Tu versión actual: v${LiveBroadcastBanner.currentAppBuildVersion}  →  Nueva: v$latestVersion',
                    style: const TextStyle(color: Color(0xFFFFD600), fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            actions: [
              if (!forceUpdate)
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Más tarde', style: TextStyle(color: Colors.white54)),
                ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('ACTUALIZAR AHORA', style: TextStyle(fontWeight: FontWeight.w900)),
                onPressed: () async {
                  if (apkUrl.isNotEmpty) {
                    final uri = Uri.tryParse(apkUrl);
                    if (uri != null) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    }
                  }
                  if (!forceUpdate && ctx.mounted) Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('system_config')
          .doc('broadcast_announcement')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || !(snapshot.data?.exists ?? false)) {
          return const SizedBox.shrink();
        }

        final data = snapshot.data!.data() ?? {};
        _checkAndShowUpdateDialog(data);

        final bool isActive = data['isActive'] == true;
        final String message = (data['message'] ?? '').toString().trim();
        final String type = (data['type'] ?? 'match').toString();
        final String broadcastId = (data['updatedAt'] ?? message).toString();

        if (!isActive || message.isEmpty || _dismissedBannerId == broadcastId) {
          return const SizedBox.shrink();
        }

        Color bgStart = const Color(0xFF7B2CBF);
        Color bgEnd = const Color(0xFF3B0764);
        Color accent = const Color(0xFFC77DFF);
        IconData icon = Icons.campaign_rounded;
        String badgeText = 'AVISO OFICIAL';

        if (type == 'match') {
          bgStart = const Color(0xFF991B1B);
          bgEnd = const Color(0xFF450A0A);
          accent = const Color(0xFFFFD600);
          icon = Icons.sports_soccer_rounded;
          badgeText = 'EVENTO EN VIVO';
        } else if (type == 'promo') {
          bgStart = const Color(0xFF065F46);
          bgEnd = const Color(0xFF064E3B);
          accent = const Color(0xFF34D399);
          icon = Icons.card_giftcard_rounded;
          badgeText = 'PROMO VIP';
        } else if (type == 'warning') {
          bgStart = const Color(0xFF92400E);
          bgEnd = const Color(0xFF451A03);
          accent = const Color(0xFFFBBF24);
          icon = Icons.build_circle_rounded;
          badgeText = 'SOPORTE / RED';
        }

        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [bgStart, bgEnd]),
            border: Border(bottom: BorderSide(color: accent.withOpacity(0.7), width: 1.2)),
          ),
          child: Row(
            children: [
              Icon(icon, color: accent, size: 18),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black38,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: accent.withOpacity(0.6), width: 0.8),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(color: accent, fontSize: 9, fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              InkWell(
                onTap: () async {
                  final prefs = await SharedPreferences.getInstance();
                  await prefs.setString('dismissed_broadcast_id', broadcastId);
                  if (mounted) setState(() => _dismissedBannerId = broadcastId);
                },
                child: const Padding(
                  padding: EdgeInsets.only(left: 8),
                  child: Icon(Icons.close, color: Colors.white60, size: 16),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class AdminBroadcastControlCard extends StatefulWidget {
  const AdminBroadcastControlCard({super.key});

  @override
  State<AdminBroadcastControlCard> createState() => _AdminBroadcastControlCardState();
}

class _AdminBroadcastControlCardState extends State<AdminBroadcastControlCard> {
  final TextEditingController _msgCtrl = TextEditingController();
  final TextEditingController _versionCtrl = TextEditingController(text: '2.4.0');
  final TextEditingController _apkUrlCtrl = TextEditingController();
  final TextEditingController _notesCtrl = TextEditingController();

  String _selectedType = 'match';
  bool _bannerActive = false;
  bool _updateActive = false;
  bool _forceUpdate = false;
  bool _isSaving = false;
  bool _isExpanded = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentBroadcastConfig();
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _versionCtrl.dispose();
    _apkUrlCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentBroadcastConfig() async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('system_config')
          .doc('broadcast_announcement')
          .get();
      if (doc.exists && mounted) {
        final d = doc.data() ?? {};
        setState(() {
          _msgCtrl.text = (d['message'] ?? '').toString();
          _selectedType = (d['type'] ?? 'match').toString();
          _bannerActive = d['isActive'] == true;
          _updateActive = d['updateActive'] == true;
          _forceUpdate = d['forceUpdate'] == true;
          if (d['latestVersion'] != null) _versionCtrl.text = d['latestVersion'].toString();
          if (d['apkDownloadUrl'] != null) _apkUrlCtrl.text = d['apkDownloadUrl'].toString();
          if (d['updateNotes'] != null) _notesCtrl.text = d['updateNotes'].toString();
        });
      }
    } catch (_) {}
  }

  Future<void> _saveBroadcastConfig() async {
    setState(() => _isSaving = true);
    try {
      await FirebaseFirestore.instance
          .collection('system_config')
          .doc('broadcast_announcement')
          .set({
        'isActive': _bannerActive,
        'message': _msgCtrl.text.trim(),
        'type': _selectedType,
        'updateActive': _updateActive,
        'latestVersion': _versionCtrl.text.trim(),
        'apkDownloadUrl': _apkUrlCtrl.text.trim(),
        'updateNotes': _notesCtrl.text.trim(),
        'forceUpdate': _forceUpdate,
        'updatedAt': DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _bannerActive || _updateActive
                  ? '📡 ¡Anuncio / Alerta transmitida en vivo a todas las pantallas!'
                  : '⏹ Transmisión global desactivada.',
            ),
            backgroundColor: const Color(0xFF10B981),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error al publicar aviso: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF17153B), Color(0xFF111827)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFFFD600).withOpacity(0.45), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFFD600).withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.podcasts_rounded, color: Color(0xFFFFD600), size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Megáfono Global: Eventos en Vivo & Actualizaciones APK',
                        style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w900),
                      ),
                      Text(
                        _bannerActive
                            ? '🟢 TRANSMITIENDO EN PANTALLAS: "${_msgCtrl.text}"'
                            : 'Toca aquí para anunciar un partido, promoción o nueva versión de la App',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _bannerActive ? const Color(0xFF10B981) : Colors.white60,
                          fontSize: 11.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  _isExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                  color: const Color(0xFFFFD600),
                ),
              ],
            ),
          ),
          if (_isExpanded) ...[
            const Divider(color: Colors.white12, height: 24),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    activeColor: const Color(0xFF10B981),
                    title: const Text(
                      'Mostrar Banner en Vivo a todos',
                      style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12.5),
                    ),
                    value: _bannerActive,
                    onChanged: (v) => setState(() => _bannerActive = v),
                  ),
                ),
                const SizedBox(width: 12),
                DropdownButton<String>(
                  value: _selectedType,
                  dropdownColor: const Color(0xFF1F2937),
                  style: const TextStyle(color: Colors.white, fontSize: 12.5),
                  items: const [
                    DropdownMenuItem(value: 'match', child: Text('⚽ Evento / Partido')),
                    DropdownMenuItem(value: 'promo', child: Text('🎁 Promoción VIP')),
                    DropdownMenuItem(value: 'info', child: Text('📢 Aviso General')),
                    DropdownMenuItem(value: 'warning', child: Text('🛠️ Mantenimiento')),
                  ],
                  onChanged: (v) => setState(() => _selectedType = v ?? 'match'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _msgCtrl,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Mensaje del Banner (Ej: 🔥 HOY 8:00 PM Perú vs Brasil en Vivo por CH 015)',
                labelStyle: const TextStyle(color: Colors.white60, fontSize: 12),
                filled: true,
                fillColor: const Color(0xFF1F2937),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              activeColor: const Color(0xFF00E5FF),
              title: const Text(
                'Avisar Nueva Actualización de APK (Pop-up en celulares/TV Box)',
                style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 12.5),
              ),
              value: _updateActive,
              onChanged: (v) => setState(() => _updateActive = v),
            ),
            if (_updateActive) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  SizedBox(
                    width: 130,
                    child: TextField(
                      controller: _versionCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        labelText: 'Nueva Versión',
                        hintText: '2.5.0',
                        labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF1F2937),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _apkUrlCtrl,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5),
                      decoration: InputDecoration(
                        labelText: 'Link directo de descarga del nuevo APK',
                        labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF1F2937),
                        isDense: true,
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _notesCtrl,
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                decoration: InputDecoration(
                  labelText: 'Novedades de la versión (lo que leerá el cliente)',
                  labelStyle: const TextStyle(color: Colors.white60, fontSize: 11),
                  filled: true,
                  fillColor: const Color(0xFF1F2937),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                activeColor: Colors.redAccent,
                title: const Text(
                  'Actualización obligatoria (no permite cerrar el aviso sin actualizar)',
                  style: TextStyle(color: Colors.white70, fontSize: 11.5),
                ),
                value: _forceUpdate,
                onChanged: (v) => setState(() => _forceUpdate = v == true),
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFFFD600),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                icon: _isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Icon(Icons.send_and_archive_rounded, size: 18),
                label: Text(
                  _isSaving ? 'PUBLICANDO...' : 'GUARDAR Y TRANSMITIR A TODOS LOS DISPOSITIVOS',
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12.5),
                ),
                onPressed: _isSaving ? null : _saveBroadcastConfig,
              ),
            ),
          ],
        ],
      ),
    );
  }
}