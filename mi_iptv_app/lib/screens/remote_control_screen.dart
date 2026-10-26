import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/channel_model.dart';
import '../services/remote_control_service.dart';

class RemoteControlScreen extends StatefulWidget {
  final List<ChannelModel> channels;
  final Set<String> favoriteUrls;
  final ChannelModel? initialChannel;

  const RemoteControlScreen({
    super.key,
    this.channels = const [],
    this.favoriteUrls = const {},
    this.initialChannel,
  });

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  static const MethodChannel _pipOrCastChannel = MethodChannel('ameycar.tv/pip');
  String _searchText = '';
  bool _onlyFavorites = false;

  void _fireCmd(String cmd, {Map<String, dynamic>? extra, String? feedback}) {
    HapticFeedback.lightImpact();
    RemoteControlService.sendCommandToTv(command: cmd, extraData: extra);
    if (feedback != null && mounted) {
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(feedback, style: const TextStyle(fontSize: 12)),
          duration: const Duration(milliseconds: 900),
          backgroundColor: const Color(0xFF1E293B),
        ),
      );
    }
  }

  Future<void> _openSystemCastSettings() async {
    try {
      await _pipOrCastChannel.invokeMethod('openCastSettings');
    } catch (_) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF131A29),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Row(
            children: [
              Icon(Icons.cast_connected, color: Color(0xFF00E5FF)),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Conectar a TV / Chromecast',
                  style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          content: const Text(
            '• MODO 1 (Smart TV / TV Box / PC): Abre AMEYCAR TV con tu misma cuenta en tu televisor o PC. ¡Este mando controlará los canales, volumen y pausa automáticamente sin configurar nada!\n\n'
            '• MODO 2 (Chromecast / Duplicar Pantalla): Desliza la barra superior de tu celular y toca "Transmitir / Smart View" para enviar el video al Chromecast mientras usas la app.',
            style: TextStyle(color: Colors.white70, fontSize: 12.5, height: 1.4),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00E5FF),
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Entendido', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final liveList = widget.channels.where((c) => c.isLive).where((c) {
      if (_onlyFavorites && !widget.favoriteUrls.contains(c.streamUrl.trim())) {
        return false;
      }
      if (_searchText.isNotEmpty &&
          !c.name.toLowerCase().contains(_searchText.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();

    return Scaffold(
      backgroundColor: const Color(0xFF070A10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Row(
          children: [
            Icon(Icons.settings_remote, color: Color(0xFF00E5FF), size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text(
                'Mando TV & Cast',
                style: TextStyle(color: Colors.white, fontSize: 15.5, fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            onPressed: _openSystemCastSettings,
            icon: const Icon(Icons.cast, color: Color(0xFF00E5FF), size: 18),
            label: const Text(
              'Cast',
              style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 28),
        child: Column(
          children: [
            // Cruceta Principal Táctil (CH+ / CH- / -15s / +15s / OK Pantalla Completa)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF131B2E), Color(0xFF0B101D)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: const Color(0xFF9D4EDD).withOpacity(0.45)),
              ),
              child: Column(
                children: [
                  _buildBigPadButton(
                    icon: Icons.keyboard_arrow_up_rounded,
                    label: 'CANAL SIGUIENTE (CH+)',
                    color: const Color(0xFF00E5FF),
                    onTap: () => _fireCmd('channel_next', feedback: '📺 Enviado: Canal Siguiente (CH+)'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildBigPadButton(
                          icon: Icons.replay_10,
                          label: '-15s',
                          color: Colors.white70,
                          onTap: () => _fireCmd('rewind_15', feedback: '⏪ Retroceder 15s en TV'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildBigPadButton(
                          icon: Icons.fullscreen,
                          label: 'PANTALLA',
                          color: const Color(0xFFC77DFF),
                          onTap: () => _fireCmd('toggle_fullscreen', feedback: '🖥️ Alternar Pantalla Completa en TV'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildBigPadButton(
                          icon: Icons.forward_10,
                          label: '+15s',
                          color: Colors.white70,
                          onTap: () => _fireCmd('forward_15', feedback: '⏩ Adelantar 15s en TV'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildBigPadButton(
                    icon: Icons.keyboard_arrow_down_rounded,
                    label: 'CANAL ANTERIOR (CH-)',
                    color: const Color(0xFF00E5FF),
                    onTap: () => _fireCmd('channel_prev', feedback: '📺 Enviado: Canal Anterior (CH-)'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // Fila de Volumen, Play/Pausa, Ir a Vivo y Grabar en TV
            Row(
              children: [
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.volume_down,
                    label: 'Vol -',
                    color: Colors.white,
                    onTap: () => _fireCmd('vol_down'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.volume_off,
                    label: 'Mute',
                    color: Colors.amberAccent,
                    onTap: () => _fireCmd('mute_toggle', feedback: '🔇 Silencio alternado en TV'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.volume_up,
                    label: 'Vol +',
                    color: Colors.white,
                    onTap: () => _fireCmd('vol_up'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.play_arrow_rounded,
                    label: 'Play',
                    color: const Color(0xFF00E676),
                    onTap: () => _fireCmd('play', feedback: '▶️ Reproducir en TV'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.pause_rounded,
                    label: 'Pausa',
                    color: const Color(0xFFFFB703),
                    onTap: () => _fireCmd('pause', feedback: '⏸️ Pausado en TV'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.bolt,
                    label: 'En Vivo',
                    color: const Color(0xFF00E5FF),
                    onTap: () => _fireCmd('jump_live', feedback: '⚡ Saltando a EN VIVO en TV'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _buildActionTile(
                    icon: Icons.fiber_manual_record,
                    label: 'REC TV',
                    color: const Color(0xFFFF1744),
                    onTap: () => _fireCmd('toggle_rec', feedback: '🔴 Grabación DVR alternada en TV'),
                  ),
                ),
              ],
            ),

            if (widget.channels.isNotEmpty) ...[
              const SizedBox(height: 22),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Lanzar Canal Directo a la TV:',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13.5),
                  ),
                  FilterChip(
                    selected: _onlyFavorites,
                    selectedColor: const Color(0xFF7B2CBF),
                    backgroundColor: const Color(0xFF1E293B),
                    label: const Text('⭐ Favoritos', style: TextStyle(color: Colors.white, fontSize: 11)),
                    onSelected: (v) => setState(() => _onlyFavorites = v),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              TextField(
                style: const TextStyle(color: Colors.white, fontSize: 12.5),
                decoration: InputDecoration(
                  hintText: 'Escribir canal para mandar a la TV...',
                  hintStyle: const TextStyle(color: Colors.white38, fontSize: 12),
                  prefixIcon: const Icon(Icons.search, color: Color(0xFF00E5FF), size: 18),
                  filled: true,
                  fillColor: const Color(0xFF131A29),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (v) => setState(() => _searchText = v.trim()),
              ),
              const SizedBox(height: 10),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: liveList.length > 25 ? 25 : liveList.length,
                itemBuilder: (context, idx) {
                  final ch = liveList[idx];
                  return Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF131A29),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.white10),
                    ),
                    child: ListTile(
                      dense: true,
                      title: Text(
                        ch.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(
                        ch.groupCategory,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54, fontSize: 10.5),
                      ),
                      trailing: const Icon(Icons.send_to_mobile, color: Color(0xFF00E5FF), size: 18),
                      onTap: () => _fireCmd(
                        'tune_channel',
                        extra: {'url': ch.streamUrl, 'name': ch.name},
                        feedback: '📺 Sintonizando "${ch.name}" en tu TV',
                      ),
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBigPadButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF1E293B),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(height: 3),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF131A29),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          child: Column(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(height: 3),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.bold)),
            ],
          ),
        ),
      ),
    );
  }
}
