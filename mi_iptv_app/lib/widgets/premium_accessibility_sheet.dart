import 'package:flutter/material.dart';
import '../services/player_settings_service.dart';
import '../services/auth_service.dart'; 

class PremiumAccessibilitySheet extends StatelessWidget {
  const PremiumAccessibilitySheet({super.key});

  @override
  Widget build(BuildContext context) {
    // Validamos si el usuario es Premium o Admin (ajusta esta variable según el modelo de tu base de datos)
    final isPremium = AuthService.currentUser?.isAdmin == true || 
                      AuthService.currentUser?.username?.toLowerCase() == 'admin'; 
                      // TODO: Agregar aquí "|| AuthService.currentUser?.isPremium == true" cuando tengas tu sistema de pagos

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0D1324),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.accessibility_new_rounded, color: Color(0xFF00E5FF), size: 28),
              const SizedBox(width: 12),
              const Text(
                'Inclusión y Accesibilidad',
                style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (isPremium)
                const Icon(Icons.workspace_premium, color: Color(0xFFFFD700), size: 28),
            ],
          ),
          const SizedBox(height: 24),
          if (isPremium) _buildPremiumContent(context) else _buildLockedUpsell(context),
        ],
      ),
    );
  }

  Widget _buildPremiumContent(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Filtro de Daltonismo (En Vivo)', style: TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 8),
        ValueListenableBuilder<String>(
          valueListenable: PlayerSettingsService.colorFilterNotifier,
          builder: (context, currentFilter, _) {
            return DropdownButtonFormField<String>(
              value: currentFilter,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              items: ['Normal', 'Protanopia (Rojo)', 'Deuteranopia (Verde)', 'Tritanopia (Azul)', 'Blanco y Negro']
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (val) {
                if (val != null) PlayerSettingsService.setColorFilter(val);
              },
            );
          },
        ),
        const SizedBox(height: 20),
        const Text('Subtítulos Inteligentes', style: TextStyle(color: Colors.white70, fontSize: 14)),
        const SizedBox(height: 8),
        ValueListenableBuilder<String>(
          valueListenable: PlayerSettingsService.subtitleTrackNotifier,
          builder: (context, currentSub, _) {
            return DropdownButtonFormField<String>(
              value: currentSub,
              dropdownColor: const Color(0xFF1E293B),
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
              ),
              items: ['Desactivado', 'Español', 'Inglés']
                  .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                  .toList(),
              onChanged: (val) {
                if (val != null) PlayerSettingsService.setSubtitleTrack(val);
              },
            );
          },
        ),
      ],
    );
  }

  Widget _buildLockedUpsell(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2C220B), Color(0xFF1A1608)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.3)),
      ),
      child: Column(
        children: [
          const Icon(Icons.lock_outline, color: Color(0xFFFFD700), size: 48),
          const SizedBox(height: 16),
          const Text(
            'Función Exclusiva Premium',
            style: TextStyle(color: Color(0xFFFFD700), fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text(
            'Mejora tu cuenta para desbloquear filtros visuales para daltonismo y subtítulos inteligentes en tiempo real.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 20),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFFD700),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              minimumSize: const Size(double.infinity, 48),
            ),
            onPressed: () {
              Navigator.pop(context); // Cierra la alerta
              // TODO: Navegar a tu pasarela de pagos o pantalla de planes en el futuro
            },
            child: const Text('Hacerse Premium', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );
  }
}