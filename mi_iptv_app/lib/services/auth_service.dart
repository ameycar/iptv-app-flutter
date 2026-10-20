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
  static const String _kHardwareIdKey = 'ameycaiptv_hardware_id_v2';
  static const String _kSessionUserKey = 'ameycaiptv_current_user_id';
  static const String _kLocalUsersDbKey = 'ameycaiptv_local_users_db_v2';
  static const String _kMasterAdminHwKey = 'ameycaiptv_master_admin_hw_id';
  static const String _usersCollection = 'users';

  // Clave maestra de recuperación para autorizar un nuevo dispositivo del dueño
  static const String masterRecoveryKey = 'AMEYCAR-VIP-2026';

  static UserModel? _currentUser;
  static String? _cachedHardwareId;

  // Notificador reactivo para modo local y soporte multiplataforma
  static final StreamController<List<UserModel>> _localUsersStreamController =
      StreamController<List<UserModel>>.broadcast();

  static UserModel? get currentUser => _currentUser;
  static bool get isLoggedIn => _currentUser != null;
  static bool get isAdmin => _currentUser?.isAdmin ?? false;
  static bool get isSuperAdmin => _currentUser?.isSuperAdmin ?? false;
  static bool get isFamilyAdmin => _currentUser?.isFamilyGroupAdmin ?? false;

  /// Verifica si Firebase Firestore está inicializado
  static bool get isFirebaseAvailable {
    try {
      return Firebase.apps.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Obtiene o genera el Hardware ID único y permanente de este dispositivo
  static Future<String> getDeviceHardwareId() async {
    if (_cachedHardwareId != null && _cachedHardwareId!.isNotEmpty) {
      return _cachedHardwareId!;
    }
    final prefs = await SharedPreferences.getInstance();
    String? hwId = prefs.getString(_kHardwareIdKey);
    if (hwId == null || hwId.isEmpty) {
      final rand = Random();
      final partA = rand.nextInt(900000) + 100000;
      final partB = rand.nextInt(900000) + 100000;
      hwId = 'AMEYCAR-HW-$partA-$partB';
      await prefs.setString(_kHardwareIdKey, hwId);
    }
    _cachedHardwareId = hwId;
    return hwId;
  }

  /// Verifica si este dispositivo físico es el teléfono autorizado del Dueño (SuperAdmin)
  static Future<bool> isMasterAdminDeviceAuthorized() async {
    final prefs = await SharedPreferences.getInstance();
    final registeredMasterHw = prefs.getString(_kMasterAdminHwKey);
    final currentHw = await getDeviceHardwareId();

    if (registeredMasterHw == null || registeredMasterHw.isEmpty) {
      // Primer inicio del Administrador: este celular se convierte en el Dispositivo Maestro
      await prefs.setString(_kMasterAdminHwKey, currentHw);
      return true;
    }
    return registeredMasterHw == currentHw;
  }

  /// Autoriza un nuevo teléfono maestro usando la clave maestra de recuperación
  static Future<bool> authorizeMasterAdminDevice(String recoveryKey) async {
    if (recoveryKey.trim() == masterRecoveryKey) {
      final prefs = await SharedPreferences.getInstance();
      final currentHw = await getDeviceHardwareId();
      await prefs.setString(_kMasterAdminHwKey, currentHw);
      return true;
    }
    return false;
  }

  /// Inicializa la cuenta admin por defecto si es el primer inicio
  static Future<void> initializeAdminAccount() async {
    try {
      final currentHw = await getDeviceHardwareId();
      if (isFirebaseAvailable) {
        final doc = await FirebaseFirestore.instance
            .collection(_usersCollection)
            .doc('admin')
            .get();
        if (!doc.exists) {
          final defaultAdmin = UserModel(
            id: 'admin',
            username: 'admin',
            password: 'adminpassword123',
            role: 'admin',
            isActive: true,
            isVip: true,
            expirationDate: DateTime.now().add(const Duration(days: 3650)),
            deviceName: 'Consola Administrador Principal',
            registeredHardwareId: currentHw,
            createdAt: DateTime.now(),
          );
          await FirebaseFirestore.instance
              .collection(_usersCollection)
              .doc('admin')
              .set(defaultAdmin.toMap());
        }
      } else {
        final localUsers = await _getLocalUsers();
        if (!localUsers.any((u) => u.username.toLowerCase() == 'admin')) {
          final defaultAdmin = UserModel(
            id: 'admin',
            username: 'admin',
            password: 'adminpassword123',
            role: 'admin',
            isActive: true,
            isVip: true,
            expirationDate: DateTime.now().add(const Duration(days: 3650)),
            deviceName: 'Consola Administrador Principal',
            registeredHardwareId: currentHw,
            createdAt: DateTime.now(),
          );
          localUsers.add(defaultAdmin);
          await _saveLocalUsers(localUsers);
        }
      }
    } catch (e) {
      debugPrint('Error inicializando cuenta admin: $e');
    }
  }

  /// Inicio de Sesión seguro con control de Hardware y Soporte Familiar
  static Future<AuthResponse> login(String username, String password) async {
    final cleanUser = username.trim().toLowerCase();
    final cleanPass = password.trim();
    final currentHw = await getDeviceHardwareId();

    try {
      UserModel? matchedUser;

      if (isFirebaseAvailable) {
        final query = await FirebaseFirestore.instance
            .collection(_usersCollection)
            .where('username', isEqualTo: cleanUser)
            .limit(1)
            .get();

        if (query.docs.isNotEmpty) {
          matchedUser = UserModel.fromMap(
            query.docs.first.id,
            query.docs.first.data(),
          );
        }
      } else {
        final localUsers = await _getLocalUsers();
        for (final u in localUsers) {
          if (u.username.toLowerCase() == cleanUser) {
            matchedUser = u;
            break;
          }
        }
      }

      if (matchedUser == null) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'Usuario no encontrado. Verifica con tu proveedor.',
        );
      }

      if (matchedUser.password != cleanPass) {
        return AuthResponse(
          status: AuthStatus.invalidCredentials,
          message: 'Contraseña incorrecta.',
        );
      }

      // Si es SuperAdmin, verificar blindaje de dispositivo maestro
      if (matchedUser.isAdmin) {
        final isMasterPhone = await isMasterAdminDeviceAuthorized();
        if (!isMasterPhone) {
          return AuthResponse(
            status: AuthStatus.adminDeviceUnauthorized,
            user: matchedUser,
            message: 'Acceso Denegado: Este dispositivo no está autorizado para abrir el Panel Maestro.',
          );
        }
      }

      if (!matchedUser.isActive) {
        return AuthResponse(
          status: AuthStatus.accountDisabled,
          user: matchedUser,
          message: 'Esta cuenta ha sido pausada o desactivada.',
        );
      }

      if (matchedUser.isExpired) {
        return AuthResponse(
          status: AuthStatus.subscriptionExpired,
          user: matchedUser,
          message: 'Tu suscripción ha vencido. Contacta a soporte para renovar.',
        );
      }

      // Validación de Hardware ID
      if (!matchedUser.isAdmin) {
        if (matchedUser.registeredHardwareId == null ||
            matchedUser.registeredHardwareId!.isEmpty) {
          // Primer login: Se vincula automáticamente a este dispositivo
          await updateClientUser(matchedUser.id, {
            'registeredHardwareId': currentHw,
            'lastActiveAt': DateTime.now().toIso8601String(),
          });
          matchedUser = matchedUser.copyWith(
            registeredHardwareId: currentHw,
            lastActiveAt: DateTime.now(),
          );
        } else if (matchedUser.registeredHardwareId != currentHw) {
          return AuthResponse(
            status: AuthStatus.hardwareMismatch,
            user: matchedUser,
            message: 'Esta cuenta ya está vinculada a otro dispositivo.',
          );
        }
      }

      _currentUser = matchedUser;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kSessionUserKey, matchedUser.id);

      return AuthResponse(
        status: AuthStatus.success,
        user: matchedUser,
        message: 'Bienvenido ${matchedUser.username}',
      );
    } catch (e) {
      return AuthResponse(
        status: AuthStatus.error,
        message: 'Error al conectar con el servidor: $e',
      );
    }
  }

  // ============================================================
  // GESTIÓN DE GRUPOS FAMILIARES (HASTA 5 DISPOSITIVOS)
  // ============================================================

  /// Crea un nuevo Grupo Familiar completo con su Administrador Familiar
  static Future<void> createFamilyGroup({
    required String familyName,
    required String adminUsername,
    required String adminPassword,
    required bool isVip,
    required DateTime expirationDate,
  }) async {
    final familyId = 'FAM-${familyName.trim().toUpperCase().replaceAll(' ', '_')}-${Random().nextInt(9000) + 1000}';
    final familyPlan = isVip ? 'vip' : 'standard';

    final familyAdminUser = UserModel(
      id: 'usr_${DateTime.now().millisecondsSinceEpoch}_admin',
      username: adminUsername.trim().toLowerCase(),
      password: adminPassword.trim(),
      role: 'family_admin',
      isActive: true,
      isVip: isVip,
      expirationDate: expirationDate,
      deviceName: 'Consola Familiar ($adminUsername)',
      maxScreens: 5,
      familyId: familyId,
      isFamilyAdmin: true,
      familyPlan: familyPlan,
      createdAt: DateTime.now(),
    );

    await createClientUser(familyAdminUser);
  }

  /// Obtiene los miembros de una familia específica
  static Future<List<UserModel>> getFamilyMembers(String familyId) async {
    if (isFirebaseAvailable) {
      final snap = await FirebaseFirestore.instance
          .collection(_usersCollection)
          .where('familyId', isEqualTo: familyId)
          .get();
      return snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList();
    } else {
      final all = await _getLocalUsers();
      return all.where((u) => u.familyId == familyId).toList();
    }
  }

  /// Stream reactivo de miembros de una familia para el Panel Familiar
  static Stream<List<UserModel>> getFamilyMembersStream(String familyId) {
    if (isFirebaseAvailable) {
      return FirebaseFirestore.instance
          .collection(_usersCollection)
          .where('familyId', isEqualTo: familyId)
          .snapshots()
          .map((snap) => snap.docs.map((d) => UserModel.fromMap(d.id, d.data())).toList());
    } else {
      Future.microtask(() async {
        final list = await getFamilyMembers(familyId);
        _localUsersStreamController.add(list);
      });
      return _localUsersStreamController.stream.map((list) => list.where((u) => u.familyId == familyId).toList());
    }
  }

  /// Agrega un sub-usuario al grupo familiar (máximo 5 miembros en total)
  static Future<bool> addFamilyMember({
    required String familyId,
    required String username,
    required String password,
    required String memberName,
    bool? overrideVip,
  }) async {
    final currentMembers = await getFamilyMembers(familyId);
    if (currentMembers.length >= 5) {
      throw Exception('Límite alcanzado: Este grupo familiar ya tiene el cupo máximo de 5 pantallas.');
    }

    final familyAdmin = currentMembers.firstWhere(
      (u) => u.isFamilyAdmin,
      orElse: () => currentMembers.first,
    );

    final bool isMemberVip = overrideVip ?? familyAdmin.isVip;

    final newMember = UserModel(
      id: 'usr_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999)}',
      username: username.trim().toLowerCase(),
      password: password.trim(),
      role: 'user',
      isActive: true,
      isVip: isMemberVip,
      expirationDate: familyAdmin.expirationDate,
      deviceName: memberName.trim(),
      maxScreens: 1,
      familyId: familyId,
      isFamilyAdmin: false,
      familyPlan: familyAdmin.familyPlan,
      familyAdminUsername: familyAdmin.username,
      createdAt: DateTime.now(),
    );

    await createClientUser(newMember);
    return true;
  }

  /// El Administrador de Familia puede cambiar si una pantalla es VIP o Estándar
  static Future<void> toggleMemberVipStatus(String memberId, bool newVip) async {
    await updateClientUser(memberId, {'isVip': newVip});
  }

  /// Renueva o modifica la fecha de vencimiento a TODA la familia completa
  static Future<void> renewFamilyGroup(String familyId, int additionalDays) async {
    final members = await getFamilyMembers(familyId);
    final now = DateTime.now();
    for (final member in members) {
      final baseDate = member.expirationDate.isAfter(now) ? member.expirationDate : now;
      final newExp = baseDate.add(Duration(days: additionalDays));
      await updateClientUser(member.id, {'expirationDate': newExp.toIso8601String()});
    }
  }

  /// Activa o pausa a TODA la familia completa de un solo toque
  static Future<void> toggleFamilyGroupActive(String familyId, bool active) async {
    final members = await getFamilyMembers(familyId);
    for (final member in members) {
      await updateClientUser(member.id, {'isActive': active});
    }
  }

  // ============================================================
  // OPERACIONES CRUD DE USUARIOS (CLOUD & LOCAL)
  // ============================================================

  /// Crea un nuevo usuario cliente
  static Future<void> createClientUser(UserModel newUser) async {
    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(newUser.id)
          .set(newUser.toMap());
    } else {
      final local = await _getLocalUsers();
      local.removeWhere((u) => u.id == newUser.id || u.username == newUser.username);
      local.add(newUser);
      await _saveLocalUsers(local);
    }
  }

  /// Actualiza campos de un usuario
  static Future<void> updateClientUser(String userId, Map<String, dynamic> updates) async {
    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(userId)
          .update(updates);
    } else {
      final local = await _getLocalUsers();
      final idx = local.indexWhere((u) => u.id == userId);
      if (idx != -1) {
        final map = local[idx].toMap();
        map.addAll(updates);
        local[idx] = UserModel.fromMap(userId, map);
        await _saveLocalUsers(local);
      }
    }
  }

  /// Elimina un usuario cliente
  static Future<void> deleteClientUser(String userId) async {
    if (isFirebaseAvailable) {
      await FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(userId)
          .delete();
    } else {
      final local = await _getLocalUsers();
      local.removeWhere((u) => u.id == userId);
      await _saveLocalUsers(local);
    }
  }

  /// Genera un PIN express de 4 dígitos para desbloqueo rápido de hardware
  static Future<String> adminGenerateExpressPin(String userId) async {
    final pin = (Random().nextInt(9000) + 1000).toString();
    await updateClientUser(userId, {
      'hardwareResetToken': pin,
      'hardwareResetRequested': true,
    });
    return pin;
  }

  /// Resetea el hardware de un usuario (para cambio de televisor o teléfono)
  static Future<void> adminResetHardware(String userId) async {
    await updateClientUser(userId, {
      'registeredHardwareId': null,
      'hardwareResetRequested': false,
      'hardwareResetToken': null,
    });
  }

  /// El cliente solicita cambio de dispositivo desde la pantalla de bloqueo
  static Future<void> requestHardwareReset(String userId) async {
    await updateClientUser(userId, {'hardwareResetRequested': true});
  }

  /// Desbloqueo directo con PIN de 4 dígitos proporcionado por el soporte
  static Future<bool> unlockWithExpressPin(String userId, String inputPin) async {
    final user = await getUserById(userId);
    if (user != null &&
        user.hardwareResetToken != null &&
        user.hardwareResetToken == inputPin.trim()) {
      final currentHw = await getDeviceHardwareId();
      await updateClientUser(userId, {
        'registeredHardwareId': currentHw,
        'hardwareResetRequested': false,
        'hardwareResetToken': null,
      });
      return true;
    }
    return false;
  }

  /// Obtiene un usuario por su ID
  static Future<UserModel?> getUserById(String userId) async {
    if (isFirebaseAvailable) {
      final doc = await FirebaseFirestore.instance
          .collection(_usersCollection)
          .doc(userId)
          .get();
      if (doc.exists) {
        return UserModel.fromMap(doc.id, doc.data()!);
      }
      return null;
    } else {
      final local = await _getLocalUsers();
      final matches = local.where((u) => u.id == userId);
      return matches.isNotEmpty ? matches.first : null;
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
      Future.microtask(() async {
        final list = await _getLocalUsers();
        _localUsersStreamController.add(list);
      });
      return _localUsersStreamController.stream;
    }
  }

  /// Cierre de sesión
  static Future<void> logout() async {
    _currentUser = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionUserKey);
  }

  /// Comprueba sesión previa activa
  static Future<UserModel?> checkAutoLogin() async {
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(_kSessionUserKey);
    if (savedId != null && savedId.isNotEmpty) {
      final user = await getUserById(savedId);
      if (user != null && user.isActive && !user.isExpired) {
        _currentUser = user;
        return user;
      }
    }
    return null;
  }

  // ============================================================
  // MODO AUTÓNOMO LOCAL (PERSISTENCIA OFFLINE SIN FIREBASE)
  // ============================================================

  static Future<List<UserModel>> _getLocalUsers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_kLocalUsersDbKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> decoded = jsonDecode(jsonStr);
        return decoded
            .map((item) => UserModel.fromMap(item['id'] ?? '', item as Map<String, dynamic>))
            .toList();
      }
    } catch (e) {
      debugPrint('Error leyendo DB local: $e');
    }
    return [];
  }

  static Future<void> _saveLocalUsers(List<UserModel> users) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final listMaps = users.map((u) {
        final map = u.toMap();
        map['id'] = u.id;
        return map;
      }).toList();
      await prefs.setString(_kLocalUsersDbKey, jsonEncode(listMaps));
      _localUsersStreamController.add(users);
    } catch (e) {
      debugPrint('Error guardando DB local: $e');
    }
  }
}