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
  accountExpired,
  hardwareMismatch,
  adminDeviceUnauthorized,
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
  static const String _usersCollection = 'users';
  static const String _pinsCollection = 'activation_pins';
  static const String _kLocalUsersDbKey = 'local_mock_users_db_v2';
  static const String _kActivationPinsKey = 'ameycar_activation_pins_db_v1';
  static const String _kSessionUserKey = 'current_logged_user_id';
  static const String _kActiveProfileKey = 'current_active_profile_id';
  static const String _kAdminDeviceIdKey = 'authorized_superadmin_hwid';

  // LLAVE MAESTRA DE EMERGENCIA (Para autorizar un nuevo dispositivo del Admin)
  static const String superAdminMasterKey = 'AMEYCAR-ROOT-2026';
  static const String masterRecoveryKey = 'AMEYCAR-ROOT-2026';

  static UserModel? _currentUser;
  static UserModel? _currentActiveProfile;
  static UserModel? get currentUser => _currentUser;
  static UserModel? get currentActiveProfile => _currentActiveProfile ?? _currentUser;

  static final StreamController<List<UserModel>> _localUsersStreamController =
      StreamController<List<UserModel>>.broadcast();

  static final StreamController<List<ActivationPinModel>> _localPinsStreamController =
      StreamController<List<ActivationPinModel>>.broadcast();

  static bool get isFirebaseAvailable {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  static bool get isLoggedIn => _currentUser != null;
  static bool get isAdmin => _currentUser?.isAdmin ?? false;
  static bool get isFamilyAdmin => _currentUser?.isFamilyGroupAdmin ?? false;

  /// Establece el perfil activo de la familia (Disney+ Style)
  static Future<void> setActiveProfile(UserModel profile) async {
    _currentActiveProfile = profile;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kActiveProfileKey, profile.id);
  }

  /// Obtiene o genera el Hardware ID único del dispositivo
  static Future<String> getDeviceHardwareId() async {
    final prefs = await SharedPreferences.getInstance();
    String? hwId = prefs.getString('device_unique_hw_id');
    if (hwId == null || hwId.isEmpty) {
      final random = Random.secure();
      final values = List<int>.generate(8, (i) => random.nextInt(256));
      final hex = values.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();
      hwId = 'AMEYCAR-TV-$hex';
      await prefs.setString('device_unique_hw_id', hwId);
    }
    return hwId;
  }

  /// Inicializa la cuenta SuperAdmin por defecto si no existe
  static Future<void> initializeAdminAccount() async {
    try {
      final hardwareId = await getDeviceHardwareId();
      final defaultAdmin = UserModel(
        id: 'admin_master',
        username: 'admin',
        password: 'admin2026',
        role: 'admin',
        isActive: true,
        isVip: true,
        expirationDate: DateTime.now().add(const Duration(days: 3650)),
        registeredHardwareId: hardwareId,
        deviceName: 'Dispositivo Principal Admin',
        maxScreens: 5,
        createdAt: DateTime.now(),
        lastActiveAt: DateTime.now(),
      );

      if (isFirebaseAvailable) {
        final query = await FirebaseFirestore.instance
            .collection(_usersCollection)
            .where('username', isEqualTo: 'admin')
            .limit(1)
            .get();

        if (query.docs.isEmpty) {
          await FirebaseFirestore.instance
              .collection(_usersCollection)
              .doc(defaultAdmin.id)
              .set(defaultAdmin.toMap());
          debugPrint('✅ [AuthService Cloud] SuperAdmin creado en Firestore.');
        }
      } else {
        final localUsers = await _getLocalUsers();
        final exists = localUsers.any((u) => u.username.toLowerCase() == 'admin');
        if (!exists) {
          localUsers.add(defaultAdmin);
          await _saveLocalUsers(localUsers);
          debugPrint('✅ [AuthService Local] SuperAdmin creado en almacenamiento local.');
        }
      }
    } catch (e) {
      debugPrint('⚠️ [AuthService] Error inicializando admin: $e');
    }
  }

  /// Inicia sesión con validación de credenciales, roles y blindaje de Hardware
  static Future<AuthResponse> login({
    required String username,
    required String password,
    String? masterKeyOverride,
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
          if (cleanUsername == 'admin' && (cleanPassword == 'admin2026' || cleanPassword == 'admin1234')) {
            await initializeAdminAccount();
            return login(username: username, password: password, masterKeyOverride: masterKeyOverride);
          }
          return AuthResponse(
            status: AuthStatus.invalidCredentials,
            message: 'El usuario no existe o las credenciales son incorrectas.',
          );
        }

        final doc = snapshot.docs.first;
        final user = UserModel.fromMap(doc.id, doc.data());

        if (user.password != cleanPassword) {
          return AuthResponse(
            status: AuthStatus.invalidCredentials,
            message: 'Contraseña incorrecta. Inténtalo nuevamente.',
          );
        }

        if (!user.isActive) {
          return AuthResponse(
            status: AuthStatus.accountDisabled,
            message: 'Tu cuenta ha sido desactivada. Contacta al soporte.',
          );
        }

        if (!user.isAdmin && user.isExpired) {
          return AuthResponse(
            status: AuthStatus.subscriptionExpired,
            message: 'Tu suscripción ha vencido. Contacta al administrador para renovar.',
          );
        }

        // CONTROL DE ACCESO SUPERADMIN
        if (user.isAdmin) {
          final prefs = await SharedPreferences.getInstance();
          final authorizedAdminHwId = prefs.getString(_kAdminDeviceIdKey);

          if (authorizedAdminHwId == null) {
            await prefs.setString(_kAdminDeviceIdKey, hardwareId);
          } else if (authorizedAdminHwId != hardwareId) {
            if (masterKeyOverride != null && masterKeyOverride.trim() == superAdminMasterKey) {
              await prefs.setString(_kAdminDeviceIdKey, hardwareId);
            } else {
              return AuthResponse(
                status: AuthStatus.adminDeviceUnauthorized,
                message: 'Este dispositivo no está autorizado para administrar el sistema.',
              );
            }
          }

          _currentUser = user;
          _currentActiveProfile = user;
          await _saveSession(user.id);
          return AuthResponse(status: AuthStatus.success, user: user, message: 'Bienvenido Administrador');
        }

        // CONTROL DE BLINDAJE DE HARDWARE (1 DISPOSITIVO POR CUENTA)
        if (user.registeredHardwareId == null || user.registeredHardwareId!.isEmpty) {
          await FirebaseFirestore.instance.collection(_usersCollection).doc(user.id).update({
            'registeredHardwareId': hardwareId,
            'deviceName': 'Dispositivo Vinculado',
            'lastActiveAt': FieldValue.serverTimestamp(),
          });
          _currentUser = user.copyWith(registeredHardwareId: hardwareId);
          _currentActiveProfile = _currentUser;
          await _saveSession(user.id);
          return AuthResponse(status: AuthStatus.success, user: _currentUser, message: 'Dispositivo vinculado con éxito.');
        } else if (user.registeredHardwareId != hardwareId) {
          return AuthResponse(
            status: AuthStatus.hardwareMismatch,
            user: user,
            message: 'Tu cuenta ya está vinculada a otro dispositivo.',
          );
        }

        await FirebaseFirestore.instance.collection(_usersCollection).doc(user.id).update({
          'lastActiveAt': FieldValue.serverTimestamp(),
        });
        _currentUser = user;
        _currentActiveProfile = user;
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: user, message: 'Acceso concedido.');
      }

      // ==========================================
      // CASO B: MODO LOCAL SEGURO
      // ==========================================
      final localUsers = await _getLocalUsers();
      if (localUsers.isEmpty) {
        await initializeAdminAccount();
      }

      final matched = localUsers.where((u) => u.username.toLowerCase() == cleanUsername);
      if (matched.isEmpty) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'El usuario no existe en la base de datos.',
        );
      }

      final user = matched.first;
      if (user.password != cleanPassword) {
        return AuthResponse(status: AuthStatus.invalidCredentials, message: 'Contraseña incorrecta.');
      }

      if (!user.isActive) {
        return AuthResponse(status: AuthStatus.accountDisabled, message: 'Tu cuenta está suspendida.');
      }

      if (!user.isAdmin && user.isExpired) {
        return AuthResponse(status: AuthStatus.subscriptionExpired, message: 'Tu cuenta ha vencido.');
      }

      if (user.isAdmin) {
        final prefs = await SharedPreferences.getInstance();
        final authorizedAdminHwId = prefs.getString(_kAdminDeviceIdKey);
        if (authorizedAdminHwId == null) {
          await prefs.setString(_kAdminDeviceIdKey, hardwareId);
        } else if (authorizedAdminHwId != hardwareId) {
          if (masterKeyOverride != null && masterKeyOverride.trim() == superAdminMasterKey) {
            await prefs.setString(_kAdminDeviceIdKey, hardwareId);
          } else {
            return AuthResponse(
              status: AuthStatus.adminDeviceUnauthorized,
              message: 'Dispositivo no autorizado para administrar.',
            );
          }
        }

        _currentUser = user;
        _currentActiveProfile = user;
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: user, message: 'Bienvenido Administrador');
      }

      if (user.registeredHardwareId == null || user.registeredHardwareId!.isEmpty) {
        final updatedUser = user.copyWith(registeredHardwareId: hardwareId);
        await _saveLocalUser(updatedUser);
        _currentUser = updatedUser;
        _currentActiveProfile = updatedUser;
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: _currentUser, message: 'Dispositivo vinculado.');
      } else if (user.registeredHardwareId != hardwareId) {
        return AuthResponse(
          status: AuthStatus.hardwareMismatch,
          user: user,
          message: 'Esta cuenta ya está vinculada a otro dispositivo.',
        );
      }

      _currentUser = user;
      _currentActiveProfile = user;
      await _saveSession(user.id);
      return AuthResponse(status: AuthStatus.success, user: user, message: 'Acceso concedido.');
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error al iniciar sesión: $e');
    }
  }

  // ============================================================
  // GESTIÓN DE PLANES FAMILIARES (HASTA 5 DISPOSITIVOS) DISNEY+
  // ============================================================

  static Future<void> createFamilyGroup({
    required String familyName,
    required String adminUsername,
    required String adminPassword,
    required bool isVip,
    required DateTime expirationDate,
  }) async {
    final familyId = 'FAM-${Random().nextInt(900000) + 100000}';

    final familyAdminUser = UserModel(
      id: isFirebaseAvailable ? FirebaseFirestore.instance.collection(_usersCollection).doc().id : 'user_${DateTime.now().millisecondsSinceEpoch}',
      username: adminUsername.trim().toLowerCase(),
      password: adminPassword.trim(),
      role: 'family_admin',
      isActive: true,
      isVip: isVip,
      expirationDate: expirationDate,
      deviceName: 'Pantalla Principal ($adminUsername)',
      maxScreens: 5,
      familyId: familyId,
      isFamilyAdmin: true,
      familyPlan: isVip ? 'vip' : 'standard',
      familyAdminUsername: adminUsername.trim(),
      avatarIndex: 0,
      createdAt: DateTime.now(),
      lastActiveAt: DateTime.now(),
    );

    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(familyAdminUser.id)
          .set(familyAdminUser.toMap());
    } else {
      final list = await _getLocalUsers();
      list.add(familyAdminUser);
      await _saveLocalUsers(list);
    }
  }

  /// Agrega un perfil/pantalla al grupo familiar (máximo 5 pantallas en total)
  static Future<bool> addFamilyMember({
    required String familyId,
    required String username,
    required String password,
    String? memberName,
    String? familyAdminUsername,
    bool? isVip,
    bool? overrideVip,
    DateTime? expirationDate,
    int avatarIndex = 1,
    String? pinCode,
  }) async {
    final currentMembers = await getFamilyMembers(familyId);
    if (currentMembers.length >= 5) {
      throw Exception('Límite alcanzado: Este grupo familiar ya tiene el cupo máximo de 5 pantallas activas.');
    }

    final familyAdmin = currentMembers.firstWhere(
      (u) => u.isFamilyAdmin,
      orElse: () => currentMembers.isNotEmpty ? currentMembers.first : _currentUser!,
    );

    final bool isMemberVip = overrideVip ?? isVip ?? familyAdmin.isVip;
    final expDate = expirationDate ?? familyAdmin.expirationDate;

    final memberUser = UserModel(
      id: isFirebaseAvailable
          ? FirebaseFirestore.instance.collection(_usersCollection).doc().id
          : 'member_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999)}',
      username: username.trim().toLowerCase(),
      password: password.trim(),
      role: 'user',
      isActive: true,
      isVip: isMemberVip,
      expirationDate: expDate,
      deviceName: memberName ?? username,
      maxScreens: 1,
      familyId: familyId,
      isFamilyAdmin: false,
      familyPlan: familyAdmin.familyPlan ?? (isMemberVip ? 'vip' : 'standard'),
      familyAdminUsername: familyAdminUsername ?? familyAdmin.username,
      avatarIndex: avatarIndex,
      pinCode: pinCode,
      createdAt: DateTime.now(),
      lastActiveAt: DateTime.now(),
    );

    await createClientUser(memberUser);
    return true;
  }

  /// Obtiene los miembros de una familia específica
  static Future<List<UserModel>> getFamilyMembers(String familyId) async {
    final cleanId = familyId.trim();
    if (isFirebaseAvailable) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(_usersCollection)
            .where('familyId', isEqualTo: cleanId)
            .get();
        if (snap.docs.isNotEmpty) {
          return snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList();
        }
      } catch (e) {
        debugPrint('Error en getFamilyMembers Firestore: $e');
      }
    }
    final all = await _getLocalUsers();
    final list = all.where((u) => u.effectiveFamilyId == cleanId || u.familyId == cleanId).toList();
    if (list.isEmpty && _currentUser != null && _currentUser!.effectiveFamilyId == cleanId) {
      list.add(_currentUser!);
    }
    return list;
  }

  /// Stream reactivo de los miembros de una familia
  static Stream<List<UserModel>> getFamilyMembersStream(String familyId) {
    final cleanId = familyId.trim();
    if (isFirebaseAvailable) {
      return FirebaseFirestore.instance
          .collection(_usersCollection)
          .where('familyId', isEqualTo: cleanId)
          .snapshots()
          .map((snap) => snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList());
    } else {
      final controller = StreamController<List<UserModel>>.broadcast();
      getFamilyMembers(cleanId).then((initialList) {
        if (!controller.isClosed) controller.add(initialList);
      });
      final sub = _localUsersStreamController.stream.listen((allUsers) {
        if (!controller.isClosed) {
          final list = allUsers.where((u) => u.effectiveFamilyId == cleanId || u.familyId == cleanId).toList();
          if (list.isEmpty && _currentUser != null && _currentUser!.effectiveFamilyId == cleanId) {
            list.add(_currentUser!);
          }
          controller.add(list);
        }
      });
      controller.onCancel = () => sub.cancel();
      return controller.stream;
    }
  }

  static Future<void> renewFamilyGroup(String familyId, int additionalDays) async {
    if (isFirebaseAvailable) {
      final snap = await FirebaseFirestore.instance
          .collection(_usersCollection)
          .where('familyId', isEqualTo: familyId)
          .get();

      final batch = FirebaseFirestore.instance.batch();
      for (final doc in snap.docs) {
        final currentExp = UserModel.fromMap(doc.id, doc.data()).expirationDate;
        final base = currentExp.isAfter(DateTime.now()) ? currentExp : DateTime.now();
        final newExp = base.add(Duration(days: additionalDays));
        batch.update(doc.reference, {'expirationDate': newExp.toIso8601String()});
      }
      await batch.commit();
    } else {
      final list = await _getLocalUsers();
      for (int i = 0; i < list.length; i++) {
        if (list[i].familyId == familyId || list[i].effectiveFamilyId == familyId) {
          final base = list[i].expirationDate.isAfter(DateTime.now()) ? list[i].expirationDate : DateTime.now();
          list[i] = list[i].copyWith(expirationDate: base.add(Duration(days: additionalDays)));
        }
      }
      await _saveLocalUsers(list);
    }
  }

  // ============================================================
  // SISTEMA FINTECH: PINES PREPAGO 24/7 Y AUTORRENOVACIÓN
  // ============================================================

  /// Canjea un PIN Prepago de Activación (30, 90, 365 días)
  /// Acepta llamada posicional: redeemActivationPin(code)
  /// y opcionalmente con userId: redeemActivationPin(code, userId: id)
  static Future<AuthResponse> redeemActivationPin(
    String pinCode, {
    String? userId,
  }) async {
    try {
      final cleanCode = pinCode.trim().toUpperCase();
      if (cleanCode.isEmpty) {
        return AuthResponse(status: AuthStatus.error, message: 'Ingresa un código de PIN válido.');
      }

      final pins = await getActivationPins();
      final pinIdx = pins.indexWhere((p) => p.code == cleanCode);

      if (pinIdx == -1) {
        return AuthResponse(status: AuthStatus.error, message: 'El PIN ingresado no existe en el sistema.');
      }

      final pin = pins[pinIdx];
      if (pin.isUsed) {
        return AuthResponse(status: AuthStatus.error, message: 'Este PIN ya fue utilizado previamente.');
      }

      final targetUser = userId != null
          ? (await _getLocalUsers()).firstWhere((u) => u.id == userId, orElse: () => _currentUser!)
          : _currentUser;

      if (targetUser == null) {
        return AuthResponse(status: AuthStatus.error, message: 'No hay usuario autenticado para aplicar el PIN.');
      }

      // Marcar PIN como usado
      final updatedPin = ActivationPinModel(
        code: pin.code,
        days: pin.days,
        isVip: pin.isVip,
        isUsed: true,
        usedBy: targetUser.username,
        usedAt: DateTime.now(),
        createdAt: pin.createdAt,
      );
      pins[pinIdx] = updatedPin;
      await _saveLocalPins(pins);

      // Aplicar días a la cuenta
      final baseDate = targetUser.isExpired ? DateTime.now() : targetUser.expirationDate;
      final newExpiration = baseDate.add(Duration(days: pin.days));

      // Si es parte de una familia, renueva a toda la familia
      if (targetUser.isFamilyAdmin && targetUser.isPartOfFamily) {
        await renewFamilyGroup(targetUser.effectiveFamilyId, pin.days);
      } else {
        await updateClientUser(targetUser.id, {
          'expirationDate': newExpiration.toIso8601String(),
          'isActive': true,
          if (pin.isVip) 'isVip': true,
        });
      }

      if (_currentUser?.id == targetUser.id) {
        _currentUser = _currentUser?.copyWith(
          expirationDate: newExpiration,
          isActive: true,
          isVip: pin.isVip ? true : _currentUser?.isVip,
        );
      }

      return AuthResponse(
        status: AuthStatus.success,
        user: _currentUser,
        message: '¡Suscripción renovada exitosamente por +${pin.days} días!',
      );
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error procesando PIN: $e');
    }
  }

  /// Genera lote de Pines Prepago para que el CEO los venda por WhatsApp o revendedores
  static Future<List<String>> generateActivationPins({
    required int count,
    required int days,
    bool isVip = true,
  }) async {
    final existingPins = await getActivationPins();
    final List<String> newCodes = [];
    final random = Random();

    for (int i = 0; i < count; i++) {
      final suffix = random.nextInt(9000) + 1000;
      final code = 'AMEY-${days}D-$suffix';
      final pin = ActivationPinModel(
        code: code,
        days: days,
        isVip: isVip,
        isUsed: false,
        createdAt: DateTime.now(),
      );
      existingPins.insert(0, pin);
      newCodes.add(code);
    }

    await _saveLocalPins(existingPins);
    return newCodes;
  }

  /// Obtiene la lista de todos los Pines generados
  static Future<List<ActivationPinModel>> getActivationPins() async {
    if (isFirebaseAvailable) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection(_pinsCollection)
            .orderBy('createdAt', descending: true)
            .get();
        if (snap.docs.isNotEmpty) {
          return snap.docs.map((d) => ActivationPinModel.fromMap(d.data())).toList();
        }
      } catch (_) {}
    }
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_kActivationPinsKey);
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List;
      return list.map((m) => ActivationPinModel.fromMap(Map<String, dynamic>.from(m))).toList();
    } catch (_) {
      return [];
    }
  }

  /// Stream en tiempo real de Pines
  static Stream<List<ActivationPinModel>> getActivationPinsStream() {
    final controller = StreamController<List<ActivationPinModel>>.broadcast();
    getActivationPins().then((list) {
      if (!controller.isClosed) controller.add(list);
    });
    final sub = _localPinsStreamController.stream.listen((list) {
      if (!controller.isClosed) controller.add(list);
    });
    controller.onCancel = () => sub.cancel();
    return controller.stream;
  }

  static Future<void> _saveLocalPins(List<ActivationPinModel> pins) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(pins.map((p) => p.toMap()).toList());
    await prefs.setString(_kActivationPinsKey, encoded);
    _localPinsStreamController.add(pins);

    if (isFirebaseAvailable) {
      try {
        for (final p in pins) {
          await FirebaseFirestore.instance
              .collection(_pinsCollection)
              .doc(p.code)
              .set(p.toMap(), SetOptions(merge: true));
        }
      } catch (_) {}
    }
  }

  /// Simulación / Webhook de Pago Automático (Mercado Pago / Binance Pay)
  static Future<AuthResponse> simulateAutomaticPayment({
    required String userId,
    required int days,
    String paymentMethod = 'Pago Automático 24/7',
  }) async {
    try {
      final users = await _getLocalUsers();
      final idx = users.indexWhere((u) => u.id == userId);
      if (idx == -1) {
        return AuthResponse(status: AuthStatus.error, message: 'Usuario no encontrado.');
      }

      UserModel user = users[idx];
      final baseDate = user.isExpired ? DateTime.now() : user.expirationDate;
      final newExpiration = baseDate.add(Duration(days: days));

      if (user.isFamilyAdmin && user.isPartOfFamily) {
        await renewFamilyGroup(user.effectiveFamilyId, days);
      } else {
        await updateClientUser(user.id, {
          'expirationDate': newExpiration.toIso8601String(),
          'isActive': true,
        });
      }

      if (_currentUser?.id == user.id) {
        _currentUser = _currentUser?.copyWith(
          expirationDate: newExpiration,
          isActive: true,
        );
      }

      return AuthResponse(
        status: AuthStatus.success,
        user: _currentUser,
        message: '¡Pago recibido vía $paymentMethod! Suscripción extendida +$days días.',
      );
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error al procesar pago: $e');
    }
  }

  // ============================================================
  // LIBERACIÓN EXPRESS DE HARDWARE
  // ============================================================

  /// El usuario solicita cambio de equipo con 1 toque
  static Future<bool> requestHardwareReset(String userId) async {
    try {
      if (isFirebaseAvailable) {
        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'hardwareResetRequested': true,
          'requestedAt': FieldValue.serverTimestamp(),
        });
      } else {
        final users = await _getLocalUsers();
        final idx = users.indexWhere((u) => u.id == userId);
        if (idx != -1) {
          users[idx] = users[idx].copyWith(hardwareResetRequested: true);
          await _saveLocalUsers(users);
        }
      }
      return true;
    } catch (e) {
      debugPrint('Error solicitando reset de hardware: $e');
      return false;
    }
  }

  /// El Administrador libera el hardware con 1 toque
  static Future<bool> adminResetHardware(String userId) async {
    try {
      if (isFirebaseAvailable) {
        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'registeredHardwareId': null,
          'deviceName': null,
          'hardwareResetRequested': false,
          'hardwareResetToken': null,
        });
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
        }
      }
      return true;
    } catch (e) {
      debugPrint('Error reseteando hardware: $e');
      return false;
    }
  }

  /// Genera un PIN express de 4 dígitos para vincular el nuevo equipo
  static Future<String?> adminGenerateExpressPin(String userId) async {
    try {
      final pin = (Random().nextInt(9000) + 1000).toString();
      if (isFirebaseAvailable) {
        await FirebaseFirestore.instance.collection(_usersCollection).doc(userId).update({
          'hardwareResetToken': pin,
          'hardwareResetRequested': false,
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

  /// El usuario ingresa el PIN de 4 dígitos y se vincula al instante
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
        _currentActiveProfile = _currentUser;
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
        _currentActiveProfile = user;
        await _saveSession(user.id);
        return AuthResponse(status: AuthStatus.success, user: _currentUser, message: '¡Hardware desbloqueado!');
      }
    } catch (e) {
      return AuthResponse(status: AuthStatus.error, message: 'Error al canjear PIN: $e');
    }
  }

  /// Escucha en tiempo real los cambios de un usuario específico (Cloud Firestore o Local)
  static Stream<UserModel?> listenToUserRealtime(String userId) {
    final cleanId = userId.trim();
    if (isFirebaseAvailable) {
      return FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(cleanId)
          .snapshots()
          .map((doc) => doc.exists ? UserModel.fromMap(doc.id, doc.data()!) : null);
    } else {
      final controller = StreamController<UserModel?>.broadcast();
      _getLocalUsers().then((list) {
        if (!controller.isClosed) {
          final idx = list.indexWhere((u) => u.id == cleanId);
          controller.add(idx != -1 ? list[idx] : (_currentUser?.id == cleanId ? _currentUser : null));
        }
      });
      final sub = _localUsersStreamController.stream.listen((allUsers) {
        if (!controller.isClosed) {
          final idx = allUsers.indexWhere((u) => u.id == cleanId);
          controller.add(idx != -1 ? allUsers[idx] : (_currentUser?.id == cleanId ? _currentUser : null));
        }
      });
      controller.onCancel = () => sub.cancel();
      return controller.stream;
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
      final controller = StreamController<List<UserModel>>.broadcast();
      _getLocalUsers().then((list) {
        if (!controller.isClosed) controller.add(list);
      });
      final sub = _localUsersStreamController.stream.listen((list) {
        if (!controller.isClosed) controller.add(list);
      });
      controller.onCancel = () => sub.cancel();
      return controller.stream;
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

  /// Elimina un cliente o miembro en el Panel Admin (Cloud o Local)
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
        if (_currentUser?.id == userId) {
          _currentUser = list[idx];
        }
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
        _currentActiveProfile = user;
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
        _currentActiveProfile = user;
        return user;
      }
    } catch (e) {
      return null;
    }
  }

  /// Cierra sesión
  static Future<void> logout() async {
    _currentUser = null;
    _currentActiveProfile = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionUserKey);
    await prefs.remove(_kActiveProfileKey);
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
}