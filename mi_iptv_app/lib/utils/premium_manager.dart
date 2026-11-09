import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/auth_service.dart';

class PremiumManager {
  // 1. Verificamos en tiempo real si el usuario o perfil activo es Admin o VIP vigente
  static bool get isPremium {
    final user = AuthService.currentUser;
    final profile = AuthService.currentActiveProfile ?? user;

    if (user == null) return false;

    // SuperAdmin siempre tiene acceso total
    if (user.isAdmin == true || user.username.toUpperCase() == 'ADMIN') {
      return true;
    }

    // Si la suscripción está vencida o inactiva, no tiene acceso VIP
    if (!user.isActive || user.isExpired) {
      return false;
    }

    // Verificamos si el perfil activo o la cuenta raíz tienen rango VIP o Plan Familiar VIP
    final bool hasVipFlag = (profile?.isVip == true) ||
        (user.isVip == true) ||
        (user.familyPlan?.toLowerCase() == 'vip') ||
        (profile?.familyPlan?.toLowerCase() == 'vip');

    return hasVipFlag;
  }

  // 2. El interceptor: Envuelve cualquier función con esto
  static void runIfPremium(BuildContext context, {required VoidCallback action}) {
    if (isPremium) {
      action(); // Lo deja pasar y ejecuta la función inmediatamente
    } else {
      _showLockedUpsell(context); // Lo bloquea y le muestra el banner de actualización
    }
  }

  // 3. El Banner Dorado de Venta (Reutilizable para cualquier botón)
  static void _showLockedUpsell(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xFF2C220B), Color(0xFF1A1608)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: const Color(0xFFFFD700).withOpacity(0.5), width: 1.5),
          boxShadow: [
            BoxShadow(color: const Color(0xFFFFD700).withOpacity(0.2), blurRadius: 20, spreadRadius: 2)
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.workspace_premium, color: Color(0xFFFFD700), size: 60),
            const SizedBox(height: 16),
            const Text(
              'Función Exclusiva Premium',
              style: TextStyle(color: Color(0xFFFFD700), fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            const Text(
              'Estás intentando usar una herramienta de nivel profesional. Conviértete en Premium VIP para desbloquear hasta 5 listas M3U en la nube, Timeshift (retroceso en vivo), Grabación DVR, filtros visuales y cero publicidad.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFFD700),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                minimumSize: const Size(double.infinity, 54),
                elevation: 5,
              ),
              onPressed: () async {
                Navigator.pop(ctx);
                final username = AuthService.currentUser?.username ?? 'Cliente';
                final msg = Uri.encodeComponent(
                    '¡Hola AMEYCAR TV! Mi usuario es $username y deseo activar el Plan VIP Premium.');
                final waUrl = Uri.parse('https://wa.me/51905823660?text=$msg');
                try {
                  await launchUrl(waUrl, mode: LaunchMode.externalApplication);
                } catch (_) {}
              },
              child: const Text('🌟 OBTENER PREMIUM AHORA', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15, letterSpacing: 0.5)),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Quizás más tarde', style: TextStyle(color: Colors.white54)),
            )
          ],
        ),
      ),
    );
  }
}