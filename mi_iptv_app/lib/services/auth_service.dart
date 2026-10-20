import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/user_model.dart';

enum AuthStatus {
  success,
  invalidCredentials,
  accountDisabled,
  subscriptionExpired,
  hardwareMismatch,
  error,
}

class AuthResponse {
  final AuthStatus status;
  final UserModel? user;
  final String message;

  AuthResponse({
    required this.status,
    this.user,
    required this.message,
  });

  bool get isSuccess => status == AuthStatus.success;
}

class AuthService {
  static const String _kHardwareIdKey = 'ameycaiptv_hardware_id_v2';
  static const String _kSessionUserKey = 'ameycaiptv_current_user_id';
  static const String _usersCollection = 'users';

  static UserModel? _currentUser;
  static String? _cachedHardwareId;

  static UserModel? get currentUser => _currentUser;
  static bool get isLoggedIn => _currentUser != null;
  static bool get isAdmin => _currentUser?.isAdmin ?? false;

  /// Genera y almacena una firma criptográfica única e inalterable del equipo
  static Future<String> getDeviceHardwareId() async {
    if (_cachedHardwareId != null && _cachedHardwareId!.isNotEmpty) {
      return _cachedHardwareId!;
    }

    final prefs = await SharedPreferences.getInstance();
    String? storedId = prefs.getString(_kHardwareIdKey);

    if (storedId == null || storedId.isEmpty) {
      final random = Random.secure();
      final values = List<int>.generate(16, (i) => random.nextInt(256));
      final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      final timestamp = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
      storedId = 'HW-${timestamp.substring(max(0, timestamp.length - 6))}-${hex.substring(0, 12).toUpperCase()}';
      await prefs.setString(_kHardwareIdKey, storedId);
    }

    _cachedHardwareId = storedId;
    return storedId;
  }

  /// Crea automáticamente el usuario administrador maestro si no existe
  static Future<void> initializeAdminAccount() async {
    try {
      final query = await FirebaseFirestore.instance
          .collection(_usersCollection)
          .where('role', isEqualTo: 'admin')
          .limit(1)
          .get();

      if (query.docs.isEmpty) {
        final adminDoc = FirebaseFirestore.instance.collection(_usersCollection).doc();
        final defaultAdmin = UserModel(
          id: adminDoc.id,
          username: 'admin',
          password: 'admin1234', // Puedes cambiarla desde el panel
          role: 'admin',
          isActive: true,
          isVip: true,
          expirationDate: DateTime.now().add(const Duration(days: 3650)),
          deviceName: 'Consola Administrador',
          maxScreens: 5,
        );
        await adminDoc.set(defaultAdmin.toMap());
        debugPrint('✅ [AuthService] Usuario Admin creado: admin / admin1234');
      }
    } catch (e) {
      debugPrint('⚠️ [AuthService] Inicialización admin: $e');
    }
  }

  /// Valida credenciales, expiración y candado 1-Device
  static Future<AuthResponse> login({
    required String username,
    required String password,
  }) async {
    try {
      final cleanUsername = username.trim().toLowerCase();
      final cleanPassword = password.trim();

      if (cleanUsername.isEmpty || cleanPassword.isEmpty) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'Por favor, ingresa tu usuario y contraseña.',
        );
      }

      final hardwareId = await getDeviceHardwareId();

      final snapshot = await FirebaseFirestore.instance
          .collection(_usersCollection)
          .where('username', isEqualTo: cleanUsername)
          .limit(1)
          .get();

      if (snapshot.docs.isEmpty) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'Usuario o contraseña incorrectos.',
        );
      }

      final doc = snapshot.docs.first;
      final user = UserModel.fromMap(doc.id, doc.data());

      if (user.password != cleanPassword) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'Contraseña incorrecta.',
        );
      }

      if (!user.isActive) {
        return AuthResponse(
          status: AuthStatus.accountDisabled,
          user: user,
          message: 'Tu cuenta está pausada o desactivada. Contacta al soporte.',
        );
      }

      if (!user.isAdmin && user.isExpired) {
        return AuthResponse(
          status: AuthStatus.subscriptionExpired,
          user: user,
          message: 'Tu suscripción venció el ${_formatDate(user.expirationDate)}. Solicita tu renovación.',
        );
      }

      // 🔒 BLINDAJE DE HARDWARE (1 DISPOSITIVO = 1 CUENTA)
      if (!user.isAdmin) {
        // Caso A: Primer inicio (se vincula este dispositivo al usuario)
        if (user.registeredHardwareId == null || user.registeredHardwareId!.isEmpty) {
          await FirebaseFirestore.instance.collection(_usersCollection).doc(user.id).update({
            'registeredHardwareId': hardwareId,
            'deviceName': 'Equipo ${hardwareId.substring(max(0, hardwareId.length - 6))}',
            'hardwareResetRequested': false,
            'lastActiveAt': FieldValue.serverTimestamp(),
          });
          _currentUser = user.copyWith(registeredHardwareId: hardwareId);
          await _saveSession(user.id);
          return AuthResponse(
            status: AuthStatus.success,
            user: _currentUser,
            message: 'Bienvenido. Dispositivo blindado con éxito.',
          );
        }

        // Caso B: Intento desde otro equipo no autorizado (Anti-Piratería)
        if (user.registeredHardwareId != hardwareId) {
          return AuthResponse(
            status: AuthStatus.hardwareMismatch,
            user: user,
            message: 'Esta cuenta ya está vinculada a otro equipo (${user.deviceName ?? "Dispositivo Registrado"}). No se permite compartir cuentas.',
          );
        }
      }

      await FirebaseFirestore.instance.collection(_usersCollection).doc(user.id).update({
        'lastActiveAt': FieldValue.serverTimestamp(),
      });

      _currentUser = user;
      await _saveSession(user.id);

      return AuthResponse(
        status: AuthStatus.success,
        user: user,
        message: 'Sesión iniciada correctamente.',
      );
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error de conexión: $e');
    }
  }

  /// ⚡ El usuario solicita cambio de equipo con 1 solo toque en su pantalla
  static Future<bool> requestHardwareReset(String userId) async {
    try {
      await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
        'hardwareResetRequested': true,
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  /// ⚡ El Administrador libera el equipo con 1 toque en su panel
  static Future<bool> adminResetHardware(String userId) async {
    try {
      await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
        'registeredHardwareId': null,
        'deviceName': null,
        'hardwareResetRequested': false,
        'hardwareResetToken': null,
      });
      return true;
    } catch (e) {
      return false;
    }
  }

  /// ⚡ El Administrador genera un PIN de 4 dígitos para WhatsApp
  static Future<String?> adminGenerateExpressPin(String userId) async {
    try {
      final random = Random();
      final pin = (1000 + random.nextInt(9000)).toString(); // Ej: 6184
      await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
        'hardwareResetToken': pin,
      });
      return pin;
    } catch (e) {
      return null;
    }
  }

  /// ⚡ El usuario ingresa el PIN de 4 dígitos y se vincula al segundo
  static Future<AuthResponse> unlockWithExpressPin({
    required String userId,
    required String pin,
  }) async {
    try {
      final doc = await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).get();
      if (!doc.exists) {
        return AuthResponse(status: AuthStatus.error, message: 'Usuario no encontrado.');
      }

      final user = UserModel.fromMap(doc.id, doc.data()!);
      if (user.hardwareResetToken != pin.trim()) {
        return AuthResponse(status: AuthStatus.error, message: 'PIN incorrecto o expirado.');
      }

      final hardwareId = await getDeviceHardwareId();
      await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
        'registeredHardwareId': hardwareId,
        'deviceName': 'Equipo Vinculado Express',
        'hardwareResetRequested': false,
        'hardwareResetToken': null,
        'lastActiveAt': FieldValue.serverTimestamp(),
      });

      _currentUser = user.copyWith(registeredHardwareId: hardwareId);
      await _saveSession(user.id);

      return AuthResponse(
        status: AuthStatus.success,
        user: _currentUser,
        message: '¡Equipo vinculado exitosamente!',
      );
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error: $e');
    }
  }

  /// Escucha en vivo si el admin liberó el equipo para auto-entrar
  static Stream<UserModel?> listenToUserRealtime(String userId) {
    return FirebaseFirestore.instance
        .collection(_usersCollection)
        .doc(userId)
        .snapshots()
        .map((doc) => doc.exists ? UserModel.fromMap(doc.id, doc.data()!) : null);
  }

  static Future<void> _saveSession(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSessionUserKey, userId);
  }

  static Future<UserModel?> checkAutoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(_kSessionUserKey);
      if (userId == null) return null;

      final doc = await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).get();
      if (!doc.exists) return null;

      final user = UserModel.fromMap(doc.id, doc.data()!);
      final hardwareId = await getDeviceHardwareId();

      if (!user.isActive || (!user.isAdmin && user.isExpired)) {
        await logout();
        return null;
      }

      if (!user.isAdmin && user.registeredHardwareId != hardwareId) {
        await logout();
        return null;
      }

      _currentUser = user;
      return user;
    } catch (e) {
      return null;
    }
  }

  static Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionUserKey);
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}