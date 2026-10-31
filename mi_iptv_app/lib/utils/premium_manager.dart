import 'package:flutter/material.dart';
import '../services/auth_service.dart';

class PremiumManager {
  // 1. Verificamos si tiene la llave maestra
  static bool get isPremium {
    return AuthService.currentUser?.isAdmin == true ||
           AuthService.currentUser?.username?.toLowerCase() == 'admin';
           // TODO: Agregar aquí "|| AuthService.currentUser?.isPremium == true" después
  }

  // 2. El interceptor: Envuelve cualquier función con esto
  static void runIfPremium(BuildContext context, {required VoidCallback action}) {
    if (isPremium) {
      action(); // Lo deja pasar y ejecuta la función
    } else {
      _showLockedUpsell(context); // Lo bloquea y le vende la suscripción
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
              'Estás intentando usar una herramienta de nivel profesional. Conviértete en Premium para desbloquear el Timeshift (retroceso en vivo), filtros visuales, ecualizador maestro y cero publicidad.',
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
              onPressed: () {
                Navigator.pop(ctx);
                // TODO: Redirigir a tu pasarela de pagos (WhatsApp, MercadoPago, Stripe)
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