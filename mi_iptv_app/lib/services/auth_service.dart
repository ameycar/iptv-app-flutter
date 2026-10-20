import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
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
  static const String _kLocalUsersDbKey = 'ameycaiptv_local_users_db_v1';
  static const String _usersCollection = 'users';

  static UserModel? _currentUser;
  static String? _cachedHardwareId;

  // Notificador reactivo para modo local y soporte multiplataforma
  static final StreamController<List<UserModel>> _localUsersStreamController =
      StreamController<List<UserModel>>.broadcast();

  static UserModel? get currentUser => _currentUser;
  static bool get isLoggedIn => _currentUser != null;
  static bool get isAdmin => _currentUser?.isAdmin ?? false;

  /// Verifica de forma 100% segura si Firebase está conectado y configurado con google-services.json
  static bool get isFirebaseAvailable {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Obtiene o genera el Hardware ID único y blindado del dispositivo actual
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

  /// Inicializa la cuenta Administrador por defecto tanto en Cloud como en Local
  static Future<void> initializeAdminAccount() async {
    try {
      if (isFirebaseAvailable) {
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
            password: 'admin2026',
            role: 'admin',
            isActive: true,
            isVip: true,
            expirationDate: DateTime.now().add(const Duration(days: 3650)),
            deviceName: 'Admin Master Console',
            maxScreens: 5,
          );
          await adminDoc.set(defaultAdmin.toMap());
          debugPrint('✅ [AuthService Cloud] Usuario Admin creado: admin / admin2026');
        }
      } else {
        // Modo Local: Asegurar usuario admin en base de datos local
        final localUsers = await _getLocalUsers();
        final hasAdmin = localUsers.any((u) => u.isAdmin);
        if (!hasAdmin) {
          final defaultAdmin = UserModel(
            id: 'admin_master_001',
            username: 'admin',
            password: 'admin2026',
            role: 'admin',
            isActive: true,
            isVip: true,
            expirationDate: DateTime.now().add(const Duration(days: 3650)),
            deviceName: 'Admin Master Console',
            maxScreens: 5,
          );
          localUsers.add(defaultAdmin);
          await _saveLocalUsers(localUsers);
          debugPrint('✅ [AuthService Local] Usuario Admin creado: admin / admin2026');
        }
      }
    } catch (e) {
      debugPrint('⚠️ [AuthService] Error inicializando admin: $e');
    }
  }

  /// Inicia sesión validando credenciales, estado, vencimiento y candado de hardware
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

      // ==========================================
      // CASO A: MODO CLOUD (FIREBASE DISPONIBLE)
      // ==========================================
      if (isFirebaseAvailable) {
        final snapshot = await FirebaseFirestore.instance
            .collection(_usersCollection)
            .where('username', isEqualTo: cleanUsername)
            .limit(1)
            .get();

        if (snapshot.docs.isEmpty) {
          // Si es el admin y aún no existe en Firebase, crearlo al vuelo
          if (cleanUsername == 'admin' && (cleanPassword == 'admin2026' || cleanPassword == 'admin1234')) {
            await initializeAdminAccount();
            return login(username: username, password: password);
          }
          return AuthResponse(
            status: AuthStatus.invalidCredentials,
            message: 'El usuario no existe o las credenciales son incorrectas.',
          );
        }

        final doc = snapshot.docs.first;
        final user = UserModel.fromMap(doc.id, doc.data());

        // Validar contraseña
        if (user.password != cleanPassword) {
          return AuthResponse(
            status: AuthStatus.invalidCredentials,
            message: 'Contraseña incorrecta. Verifica e intenta de nuevo.',
          );
        }

        if (!user.isActive) {
          return AuthResponse(
            status: AuthStatus.accountDisabled,
            user: user,
            message: 'Tu cuenta ha sido desactivada. Contacta al administrador.',
          );
        }

        if (!user.isAdmin && user.isExpired) {
          return AuthResponse(
            status: AuthStatus.subscriptionExpired,
            user: user,
            message: 'Tu suscripción venció el ${_formatDate(user.expirationDate)}. Solicita tu renovación.',
          );
        }

        // Blindaje de hardware
        if (!user.isAdmin) {
          if (user.registeredHardwareId == null || user.registeredHardwareId!.isEmpty) {
            await FirebaseFirestore.instance.collection(_usersCollection).doc(user.id).update({
              'registeredHardwareId': hardwareId,
              'deviceName': 'Dispositivo ${hardwareId.substring(max(0, hardwareId.length - 6))}',
              'hardwareResetRequested': false,
              'lastActiveAt': FieldValue.serverTimestamp(),
            });
            _currentUser = user.copyWith(registeredHardwareId: hardwareId);
            await _saveSession(user.id);
            return AuthResponse(
              status: AuthStatus.success,
              user: _currentUser,
              message: 'Bienvenido. Dispositivo vinculado exitosamente.',
            );
          }

          if (user.registeredHardwareId != hardwareId) {
            return AuthResponse(
              status: AuthStatus.hardwareMismatch,
              user: user,
              message: 'Esta cuenta ya está vinculada a otro equipo (${user.deviceName ?? "Equipo Registrado"}). No se permite compartir cuentas.',
            );
          }
        }

        await FirebaseFirestore.instance.collection(_usersCollection).doc(user.id).update({
          'lastActiveAt': FieldValue.serverTimestamp(),
        });

        _currentUser = user;
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: user, message: 'Sesión iniciada correctamente.');
      }

      // ==========================================
      // CASO B: MODO LOCAL (SIN FIREBASE O MODO OFFLINE)
      // ==========================================
      // Super Admin maestro incorporado (acepta admin2026 y admin1234)
      if (cleanUsername == 'admin') {
        if (cleanPassword == 'admin2026' || cleanPassword == 'admin1234') {
          final adminUser = UserModel(
            id: 'admin_master_001',
            username: 'admin',
            password: cleanPassword,
            role: 'admin',
            isActive: true,
            isVip: true,
            expirationDate: DateTime.now().add(const Duration(days: 3650)),
            deviceName: 'Admin Master Console',
            maxScreens: 5,
          );
          _currentUser = adminUser;
          await _saveSession(adminUser.id);
          await _saveLocalUser(adminUser);
          return AuthResponse(
            status: AuthStatus.success,
            user: adminUser,
            message: 'Bienvenido Administrador (Modo Seguro Activo).',
          );
        } else {
          return AuthResponse(
            status: AuthStatus.invalidCredentials,
            message: 'Contraseña de administrador incorrecta.',
          );
        }
      }

      // Buscar en base de datos local
      final localUsers = await _getLocalUsers();
      final matchIdx = localUsers.indexWhere((u) => u.username.toLowerCase() == cleanUsername);

      if (matchIdx == -1) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'El usuario no existe o las credenciales son incorrectas.',
        );
      }

      UserModel user = localUsers[matchIdx];

      if (user.password != cleanPassword) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'Contraseña incorrecta. Verifica e intenta de nuevo.',
        );
      }

      if (!user.isActive) {
        return AuthResponse(
          status: AuthStatus.accountDisabled,
          user: user,
          message: 'Tu cuenta ha sido desactivada. Contacta al administrador.',
        );
      }

      if (!user.isAdmin && user.isExpired) {
        return AuthResponse(
          status: AuthStatus.subscriptionExpired,
          user: user,
          message: 'Tu suscripción venció el ${_formatDate(user.expirationDate)}. Solicita tu renovación.',
        );
      }

      // Blindaje de hardware local
      if (!user.isAdmin) {
        if (user.registeredHardwareId == null || user.registeredHardwareId!.isEmpty) {
          user = user.copyWith(
            registeredHardwareId: hardwareId,
            deviceName: 'Dispositivo ${hardwareId.substring(max(0, hardwareId.length - 6))}',
            hardwareResetRequested: false,
          );
          localUsers[matchIdx] = user;
          await _saveLocalUsers(localUsers);

          _currentUser = user;
          await _saveSession(user.id);
          return AuthResponse(
            status: AuthStatus.success,
            user: _currentUser,
            message: 'Bienvenido. Dispositivo vinculado exitosamente.',
          );
        }

        if (user.registeredHardwareId != hardwareId) {
          return AuthResponse(
            status: AuthStatus.hardwareMismatch,
            user: user,
            message: 'Esta cuenta ya está vinculada a otro equipo (${user.deviceName ?? "Equipo Registrado"}). No se permite compartir cuentas.',
          );
        }
      }

      _currentUser = user;
      await _saveSession(user.id);
      return AuthResponse(
        status: AuthStatus.success,
        user: user,
        message: 'Sesión iniciada correctamente.',
      );
    } catch (e) {
      debugPrint('❌ [AuthService] Error en login: $e');
      return AuthResponse(
        status: AuthStatus.error,
        message: 'Error al iniciar sesión: $e',
      );
    }
  }

  /// ⚡ LIBERACIÓN EXPRESS 1: El usuario solicita cambio de equipo con 1 toque
  static Future<bool> requestHardwareReset(String userId) async {
    try {
      if (isFirebaseAvailable) {
        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'hardwareResetRequested': true,
          'requestedAt': FieldValue.serverTimestamp(),
        });
        return true;
      } else {
        final users = await _getLocalUsers();
        final idx = users.indexWhere((u) => u.id == userId);
        if (idx != -1) {
          users[idx] = users[idx].copyWith(hardwareResetRequested: true);
          await _saveLocalUsers(users);
          return true;
        }
        return false;
      }
    } catch (e) {
      debugPrint('Error solicitando reset de hardware: $e');
      return false;
    }
  }

  /// ⚡ LIBERACIÓN EXPRESS 2: El Administrador libera el hardware con 1 toque
  static Future<bool> adminResetHardware(String userId) async {
    try {
      if (isFirebaseAvailable) {
        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'registeredHardwareId': null,
          'deviceName': null,
          'hardwareResetRequested': false,
          'hardwareResetToken': null,
        });
        return true;
      } else {
        final users = await _getLocalUsers();
        final idx = users.indexWhere((u) => u.id == userId);
        if (idx != -1) {
          users[idx] = users[idx].copyWith(
            registeredHardwareId: null,
            deviceName: null,
            hardwareResetRequested: false,
            hardwareResetToken: null,
          );
          await _saveLocalUsers(users);
          return true;
        }
        return false;
      }
    } catch (e) {
      debugPrint('Error reseteando hardware: $e');
      return false;
    }
  }

  /// ⚡ LIBERACIÓN EXPRESS 3: El Administrador genera un PIN de 4 dígitos para WhatsApp
  static Future<String?> adminGenerateExpressPin(String userId) async {
    try {
      final random = Random();
      final pin = (1000 + random.nextInt(9000)).toString();

      if (isFirebaseAvailable) {
        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'hardwareResetToken': pin,
        });
        return pin;
      } else {
        final users = await _getLocalUsers();
        final idx = users.indexWhere((u) => u.id == userId);
        if (idx != -1) {
          users[idx] = users[idx].copyWith(hardwareResetToken: pin);
          await _saveLocalUsers(users);
          return pin;
        }
        return null;
      }
    } catch (e) {
      debugPrint('Error generando PIN express: $e');
      return null;
    }
  }

  /// ⚡ LIBERACIÓN EXPRESS 4: El usuario ingresa el PIN de 4 dígitos y se vincula al instante
  static Future<AuthResponse> unlockWithExpressPin({
    required String userId,
    required String pin,
  }) async {
    try {
      final hardwareId = await getDeviceHardwareId();

      if (isFirebaseAvailable) {
        final doc = await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).get();
        if (!doc.exists) {
          return AuthResponse(status: AuthStatus.error, message: 'Usuario no encontrado.');
        }

        final user = UserModel.fromMap(doc.id, doc.data()!);
        if (user.hardwareResetToken != pin.trim()) {
          return AuthResponse(status: AuthStatus.error, message: 'PIN express incorrecto o ya expirado.');
        }

        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'registeredHardwareId': hardwareId,
          'deviceName': 'Equipo Vinculado Express',
          'hardwareResetRequested': false,
          'hardwareResetToken': null,
          'lastActiveAt': FieldValue.serverTimestamp(),
        });

        _currentUser = user.copyWith(registeredHardwareId: hardwareId);
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: _currentUser, message: '¡Hardware desbloqueado!');
      } else {
        final users = await _getLocalUsers();
        final idx = users.indexWhere((u) => u.id == userId);
        if (idx == -1) return AuthResponse(status: AuthStatus.error, message: 'Usuario no encontrado.');

        UserModel user = users[idx];
        if (user.hardwareResetToken != pin.trim()) {
          return AuthResponse(status: AuthStatus.error, message: 'PIN express incorrecto.');
        }

        user = user.copyWith(
          registeredHardwareId: hardwareId,
          deviceName: 'Equipo Vinculado Express',
          hardwareResetRequested: false,
          hardwareResetToken: null,
        );
        users[idx] = user;
        await _saveLocalUsers(users);

        _currentUser = user;
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: _currentUser, message: '¡Hardware desbloqueado!');
      }
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error al canjear PIN: $e');
    }
  }

  /// Escucha en tiempo real si el administrador liberó el hardware
  static Stream<UserModel?> listenToUserRealtime(String userId) {
    if (isFirebaseAvailable) {
      return FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(userId)
          .snapshots()
          .map((doc) => doc.exists ? UserModel.fromMap(doc.id, doc.data()!) : null);
    } else {
      return _localUsersStreamController.stream.map((users) {
        final found = users.where((u) => u.id == userId);
        return found.isNotEmpty ? found.first : null;
      });
    }
  }

  /// Stream universal de usuarios para el Panel de Administrador (Cloud o Local)
  static Stream<List<UserModel>> getUsersStream() {
    if (isFirebaseAvailable) {
      return FirebaseFirestore.instance
          .collection(_usersCollection)
          .snapshots()
          .map((snap) => snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList());
    } else {
      // Emitir estado local inicial y cambios futuros
      Future.microtask(() async {
        final list = await _getLocalUsers();
        _localUsersStreamController.add(list);
      });
      return _localUsersStreamController.stream;
    }
  }

  /// Crea un nuevo cliente en el Panel Admin (Cloud o Local)
  static Future<void> createClientUser(UserModel newUser) async {
    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance.collection(_usersCollection).doc(newUser.id).set(newUser.toMap());
    } else {
      final list = await _getLocalUsers();
      list.add(newUser);
      await _saveLocalUsers(list);
    }
  }

  /// Elimina un cliente en el Panel Admin (Cloud o Local)
  static Future<void> deleteClientUser(String userId) async {
    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).delete();
    } else {
      final list = await _getLocalUsers();
      list.removeWhere((u) => u.id == userId);
      await _saveLocalUsers(list);
    }
  }

  /// Actualiza un cliente en el Panel Admin (Cloud o Local)
  static Future<void> updateClientUser(String userId, Map<String, dynamic> updates) async {
    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update(updates);
    } else {
      final list = await _getLocalUsers();
      final idx = list.indexWhere((u) => u.id == userId);
      if (idx != -1) {
        final currentMap = list[idx].toMap();
        currentMap.addAll(updates);
        list[idx] = UserModel.fromMap(userId, currentMap);
        await _saveLocalUsers(list);
      }
    }
  }

  /// Guarda la sesión en preferencias locales
  static Future<void> _saveSession(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kSessionUserKey, userId);
  }

  /// Recupera la sesión activa al abrir la app
  static Future<UserModel?> checkAutoLogin() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getString(_kSessionUserKey);
      if (userId == null) return null;

      final hardwareId = await getDeviceHardwareId();

      if (isFirebaseAvailable) {
        final doc = await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).get();
        if (!doc.exists) return null;

        final user = UserModel.fromMap(doc.id, doc.data()!);
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
      } else {
        final users = await _getLocalUsers();
        final match = users.where((u) => u.id == userId);
        if (match.isEmpty) return null;

        final user = match.first;
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
      }
    } catch (e) {
      return null;
    }
  }

  /// Cierra sesión
  static Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionUserKey);
  }

  // ==========================================
  // HELPERS DE ALMACENAMIENTO LOCAL SEGURO
  // ==========================================
  static Future<List<UserModel>> _getLocalUsers() async {
    final prefs = await SharedPreferences.getInstance();
    final rawJson = prefs.getString(_kLocalUsersDbKey);
    if (rawJson == null || rawJson.isEmpty) return [];
    try {
      final List decoded = jsonDecode(rawJson);
      return decoded.map((m) => UserModel.fromMap(m['id'] ?? '', m as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveLocalUsers(List<UserModel> users) async {
    final prefs = await SharedPreferences.getInstance();
    final mapped = users.map((u) {
      final m = u.toMap();
      m['id'] = u.id;
      return m;
    }).toList();
    await prefs.setString(_kLocalUsersDbKey, jsonEncode(mapped));
    _localUsersStreamController.add(users);
  }

  static Future<void> _saveLocalUser(UserModel user) async {
    final users = await _getLocalUsers();
    final idx = users.indexWhere((u) => u.id == user.id);
    if (idx != -1) {
      users[idx] = user;
    } else {
      users.add(user);
    }
    await _saveLocalUsers(users);
  }

  static String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }
}