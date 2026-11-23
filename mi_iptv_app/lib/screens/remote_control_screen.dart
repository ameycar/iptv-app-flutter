import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/auth_service.dart';
import '../services/remote_control_service.dart';

class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  String _lastActionLabel = 'Listo para controlar tu Smart TV';
  bool _isSending = false;

  Future<void> _send(String command, String label,
      {Map<String, dynamic>? extra}) async {
    HapticFeedback.lightImpact();
    setState(() {
      _isSending = true;
      _lastActionLabel = 'Enviando: $label...';
    });

    final ok = await RemoteControlService.sendCommandToTv(
      command: command,
      extraData: extra,
    );

    if (!mounted) return;
    setState(() {
      _isSending = false;
      _lastActionLabel = ok
          ? '✅ Comando enviado: $label'
          : '⚠️ Sin conexión con la nube';
    });
  }

  @override
  Widget build(BuildContext context) {
    final username = AuthService.currentUser?.username ?? 'Cuenta Activa';

    return Scaffold(
      backgroundColor: const Color(0xFF070A10),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: const Text(
          'Mando a Distancia 📱 AMEYCAR TV',
          style: TextStyle(
              color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        ),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  // Tarjeta de estado de vinculación
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF141D33), Color(0xFF0D1322)],
                      ),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.4),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFF00E5FF).withOpacity(0.16),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _isSending
                                ? Icons.wifi_tethering
                                : Icons.settings_remote_rounded,
                            color: const Color(0xFF00E5FF),
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Vinculado a: $username',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                _lastActionLabel,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF00E5FF),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),

                  // Fila 1: Acciones rápidas superiores
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _buildTopPillButton(
                        icon: Icons.view_list_rounded,
                        label: 'Canales',
                        color: const Color(0xFFC77DFF),
                        onTap: () => _send('open_channels', 'Lista de Canales'),
                      ),
                      _buildTopPillButton(
                        icon: Icons.forum_rounded,
                        label: 'Chat Vivo',
                        color: const Color(0xFFFFD600),
                        onTap: () => _send('toggle_chat', 'Chat en Vivo'),
                      ),
                      _buildTopPillButton(
                        icon: Icons.star_rounded,
                        label: 'Favorito',
                        color: const Color(0xFFFFB703),
                        onTap: () => _send('toggle_favorite', 'Favorito'),
                      ),
                      _buildTopPillButton(
                        icon: Icons.bolt_rounded,
                        label: 'En Vivo',
                        color: const Color(0xFF00E676),
                        onTap: () => _send('jump_live', 'Ir a Vivo'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Bloque Central: VOL | Controles Multimedia | CH
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 22),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A),
                      borderRadius: BorderRadius.circular(28),
                      border: Border.all(color: Colors.white12),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.5),
                          blurRadius: 20,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // Columna Izquierda: Volumen
                        _buildRockerColumn(
                          topIcon: Icons.volume_up_rounded,
                          topLabel: 'VOL +',
                          onTop: () => _send('vol_up', 'Subir Volumen'),
                          centerIcon: Icons.volume_off_rounded,
                          onCenter: () =>
                              _send('mute_toggle', 'Silenciar / Activar Audio'),
                          bottomIcon: Icons.volume_down_rounded,
                          bottomLabel: 'VOL -',
                          onBottom: () => _send('vol_down', 'Bajar Volumen'),
                          accentColor: const Color(0xFFC77DFF),
                        ),

                        // Centro: Botón Play/Pausa + OSD + Timeshift
                        Column(
                          children: [
                            _buildCircleAction(
                              icon: Icons.info_outline_rounded,
                              label: 'MENÚ OK',
                              size: 54,
                              color: const Color(0xFF1E293B),
                              iconColor: Colors.white,
                              onTap: () => _send('toggle_osd', 'Menú Flotante'),
                            ),
                            const SizedBox(height: 16),
                            GestureDetector(
                              onTap: () =>
                                  _send('play_pause', 'Play / Pausa'),
                              child: Container(
                                width: 92,
                                height: 92,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF00E5FF),
                                      Color(0xFF7B2CBF)
                                    ],
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(0xFF00E5FF)
                                          .withOpacity(0.45),
                                      blurRadius: 18,
                                    ),
                                  ],
                                ),
                                child: const Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.play_arrow_rounded,
                                        color: Colors.white, size: 36),
                                    Text(
                                      'PLAY/PAUSA',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9.5,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                            _buildCircleAction(
                              icon: Icons.fullscreen_rounded,
                              label: 'FULL',
                              size: 54,
                              color: const Color(0xFF1E293B),
                              iconColor: const Color(0xFF00E5FF),
                              onTap: () => _send(
                                  'toggle_fullscreen', 'Pantalla Completa'),
                            ),
                          ],
                        ),

                        // Columna Derecha: Canales CH+ / CH-
                        _buildRockerColumn(
                          topIcon: Icons.keyboard_arrow_up_rounded,
                          topLabel: 'CH +',
                          onTop: () =>
                              _send('channel_next', 'Canal Siguiente (CH+)'),
                          centerIcon: Icons.tv_rounded,
                          onCenter: () =>
                              _send('open_channels', 'Guía de Canales'),
                          bottomIcon: Icons.keyboard_arrow_down_rounded,
                          bottomLabel: 'CH -',
                          onBottom: () =>
                              _send('channel_prev', 'Canal Anterior (CH-)'),
                          accentColor: const Color(0xFF00E5FF),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Fila Inferior: Timeshift (-15s / +15s) y Grabación DVR
                  Row(
                    children: [
                      Expanded(
                        child: _buildWideButton(
                          icon: Icons.replay_10_rounded,
                          label: '-15 seg',
                          color: const Color(0xFF1E293B),
                          textColor: Colors.white,
                          onTap: () => _send('rewind_15', 'Retroceder 15s'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildWideButton(
                          icon: Icons.fiber_manual_record_rounded,
                          label: 'REC DVR',
                          color: const Color(0xFFFF1744).withOpacity(0.2),
                          borderColor: const Color(0xFFFF1744),
                          textColor: const Color(0xFFFF8A80),
                          onTap: () => _send('toggle_rec', 'Grabar DVR'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _buildWideButton(
                          icon: Icons.forward_10_rounded,
                          label: '+15 seg',
                          color: const Color(0xFF1E293B),
                          textColor: Colors.white,
                          onTap: () => _send('forward_15', 'Adelantar 15s'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'Asegúrate de tener la misma cuenta iniciada en tu Smart TV / TV Box.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white38, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopPillButton({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Material(
          color: const Color(0xFF111827),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: color.withOpacity(0.45)),
              ),
              child: Column(
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
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

  Widget _buildRockerColumn({
    required IconData topIcon,
    required String topLabel,
    required VoidCallback onTop,
    required IconData centerIcon,
    required VoidCallback onCenter,
    required IconData bottomIcon,
    required String bottomLabel,
    required VoidCallback onBottom,
    required Color accentColor,
  }) {
    return Container(
      width: 78,
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161F33),
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: accentColor.withOpacity(0.35)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: onTop,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              child: Column(
                children: [
                  Icon(topIcon, color: accentColor, size: 30),
                  Text(
                    topLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(color: Colors.white12, height: 12, indent: 14, endIndent: 14),
          InkWell(
            borderRadius: BorderRadius.circular(24),
            onTap: onCenter,
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Icon(centerIcon, color: Colors.white70, size: 22),
            ),
          ),
          const Divider(color: Colors.white12, height: 12, indent: 14, endIndent: 14),
          InkWell(
            borderRadius: BorderRadius.circular(28),
            onTap: onBottom,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
              child: Column(
                children: [
                  Text(
                    bottomLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Icon(bottomIcon, color: accentColor, size: 30),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCircleAction({
    required IconData icon,
    required String label,
    required double size,
    required Color color,
    required Color iconColor,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white12),
            ),
            child: Icon(icon, color: iconColor, size: 24),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWideButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color textColor,
    Color? borderColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: borderColor ?? Colors.white12),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: textColor, size: 18),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}