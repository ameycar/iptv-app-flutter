import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String id;
  final String username;
  final String password;
  final String role; // 'admin' (SuperAdmin) | 'family_admin' (Admin Familiar) | 'user' (Cliente)
  final bool isActive;
  final bool isVip;
  final DateTime expirationDate;
  final String? registeredHardwareId; // ID único del dispositivo vinculado
  final String? deviceName; // Ej: "Smart TV Sala", "Xiaomi Box", "Samsung S23"
  final bool hardwareResetRequested; // Si el usuario solicitó cambio desde la app
  final String? hardwareResetToken; // Código PIN express (4 dígitos) de desbloqueo rápido
  final int maxScreens; // Máximo de pantallas permitidas (1 para estándar, 5 para familiar)
  final DateTime? createdAt;
  final DateTime? lastActiveAt;

  // Campos para Grupos Familiares (Hasta 5 dispositivos) estilo Disney+
  final String? familyId; // Identificador del grupo familiar (ej: "FAM-CACOSTA-912")
  final bool isFamilyAdmin; // True si es el jefe/administrador de la cuenta familiar
  final String? familyPlan; // 'vip' | 'standard' (determina el paquete del grupo)
  final String? familyAdminUsername; // Nombre del jefe de la familia que lo creó
  final int avatarIndex; // 0..5 para avatares Disney+ / Netflix
  final String? pinCode; // PIN opcional de 4 dígitos para perfil privado

  UserModel({
    required this.id,
    required this.username,
    required this.password,
    this.role = 'user',
    this.isActive = true,
    this.isVip = false,
    required this.expirationDate,
    this.registeredHardwareId,
    this.deviceName,
    this.hardwareResetRequested = false,
    this.hardwareResetToken,
    this.maxScreens = 1,
    this.createdAt,
    this.lastActiveAt,
    this.familyId,
    this.isFamilyAdmin = false,
    this.familyPlan,
    this.familyAdminUsername,
    this.avatarIndex = 0,
    this.pinCode,
  });

  bool get isAdmin => role == 'admin';
  bool get isSuperAdmin => role == 'admin';
  bool get isFamilyGroupAdmin => role == 'family_admin' || isFamilyAdmin;
  bool get hasAdminPrivileges => isAdmin || isFamilyGroupAdmin;
  bool get isPartOfFamily =>
      (familyId != null && familyId!.isNotEmpty) || isFamilyGroupAdmin;

  String get effectiveFamilyId => (familyId != null && familyId!.isNotEmpty)
      ? familyId!
      : (isFamilyGroupAdmin ? 'FAM-${username.toUpperCase()}' : '');

  bool get isExpired => DateTime.now().isAfter(expirationDate);

  int get daysRemaining {
    final diff = expirationDate.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Verifica si el hardware actual coincide con el registrado
  bool isHardwareAuthorized(String currentHardwareId) {
    if (isAdmin) return true; // El SuperAdmin puede entrar desde su consola autorizada
    if (registeredHardwareId == null || registeredHardwareId!.isEmpty) {
      return true; // Aún no tiene hardware asignado, se asignará en el primer inicio
    }
    return registeredHardwareId == currentHardwareId;
  }

  Map<String, dynamic> toMap() {
    return {
      'username': username.trim().toLowerCase(),
      'password': password.trim(),
      'role': role,
      'isActive': isActive,
      'isVip': isVip,
      'expirationDate': expirationDate.toIso8601String(),
      'registeredHardwareId': registeredHardwareId,
      'deviceName': deviceName,
      'hardwareResetRequested': hardwareResetRequested,
      'hardwareResetToken': hardwareResetToken,
      'maxScreens': maxScreens,
      'createdAt': createdAt?.toIso8601String(),
      'lastActiveAt': lastActiveAt?.toIso8601String(),
      'familyId': familyId,
      'isFamilyAdmin': isFamilyAdmin,
      'familyPlan': familyPlan,
      'familyAdminUsername': familyAdminUsername,
      'avatarIndex': avatarIndex,
      'pinCode': pinCode,
    };
  }

  factory UserModel.fromMap(String id, Map<String, dynamic> map) {
    DateTime expDate = DateTime.now().add(const Duration(days: 30));
    if (map['expirationDate'] != null) {
      if (map['expirationDate'] is Timestamp) {
        expDate = (map['expirationDate'] as Timestamp).toDate();
      } else if (map['expirationDate'] is String) {
        expDate = DateTime.tryParse(map['expirationDate']) ?? expDate;
      }
    }

    DateTime? created;
    if (map['createdAt'] != null) {
      if (map['createdAt'] is Timestamp) {
        created = (map['createdAt'] as Timestamp).toDate();
      } else if (map['createdAt'] is String) {
        created = DateTime.tryParse(map['createdAt']);
      }
    }

    DateTime? lastActive;
    if (map['lastActiveAt'] != null) {
      if (map['lastActiveAt'] is Timestamp) {
        lastActive = (map['lastActiveAt'] as Timestamp).toDate();
      } else if (map['lastActiveAt'] is String) {
        lastActive = DateTime.tryParse(map['lastActiveAt']);
      }
    }

    return UserModel(
      id: id,
      username: (map['username'] ?? '').toString().trim().toLowerCase(),
      password: (map['password'] ?? '').toString().trim(),
      role: (map['role'] ?? 'user').toString(),
      isActive: map['isActive'] == true || map['isActive'] == null,
      isVip: map['isVip'] == true,
      expirationDate: expDate,
      registeredHardwareId: map['registeredHardwareId']?.toString(),
      deviceName: map['deviceName']?.toString(),
      hardwareResetRequested: map['hardwareResetRequested'] == true,
      hardwareResetToken: map['hardwareResetToken']?.toString(),
      maxScreens: (map['maxScreens'] as num?)?.toInt() ?? 1,
      createdAt: created,
      lastActiveAt: lastActive,
      familyId: map['familyId']?.toString(),
      isFamilyAdmin: map['isFamilyAdmin'] == true,
      familyPlan: map['familyPlan']?.toString(),
      familyAdminUsername: map['familyAdminUsername']?.toString(),
      avatarIndex: (map['avatarIndex'] as num?)?.toInt() ?? 0,
      pinCode: map['pinCode']?.toString(),
    );
  }

  UserModel copyWith({
    String? id,
    String? username,
    String? password,
    String? role,
    bool? isActive,
    bool? isVip,
    DateTime? expirationDate,
    String? registeredHardwareId,
    String? deviceName,
    bool? hardwareResetRequested,
    String? hardwareResetToken,
    int? maxScreens,
    DateTime? createdAt,
    DateTime? lastActiveAt,
    String? familyId,
    bool? isFamilyAdmin,
    String? familyPlan,
    String? familyAdminUsername,
    int? avatarIndex,
    String? pinCode,
  }) {
    return UserModel(
      id: id ?? this.id,
      username: username ?? this.username,
      password: password ?? this.password,
      role: role ?? this.role,
      isActive: isActive ?? this.isActive,
      isVip: isVip ?? this.isVip,
      expirationDate: expirationDate ?? this.expirationDate,
      registeredHardwareId: registeredHardwareId ?? this.registeredHardwareId,
      deviceName: deviceName ?? this.deviceName,
      hardwareResetRequested: hardwareResetRequested ?? this.hardwareResetRequested,
      hardwareResetToken: hardwareResetToken ?? this.hardwareResetToken,
      maxScreens: maxScreens ?? this.maxScreens,
      createdAt: createdAt ?? this.createdAt,
      lastActiveAt: lastActiveAt ?? this.lastActiveAt,
      familyId: familyId ?? this.familyId,
      isFamilyAdmin: isFamilyAdmin ?? this.isFamilyAdmin,
      familyPlan: familyPlan ?? this.familyPlan,
      familyAdminUsername: familyAdminUsername ?? this.familyAdminUsername,
      avatarIndex: avatarIndex ?? this.avatarIndex,
      pinCode: pinCode ?? this.pinCode,
    );
  }
}

/// Modelo de PIN Prepago de Activación (Voucher 24/7)
class ActivationPinModel {
  final String code;
  final int days; // 30, 90, 365 días
  final bool isVip;
  final bool isUsed;
  final String? usedBy;
  final DateTime? usedAt;
  final DateTime createdAt;

  ActivationPinModel({
    required this.code,
    required this.days,
    this.isVip = true,
    this.isUsed = false,
    this.usedBy,
    this.usedAt,
    required this.createdAt,
  });

  Map<String, dynamic> toMap() => {
        'code': code,
        'days': days,
        'isVip': isVip,
        'isUsed': isUsed,
        'usedBy': usedBy,
        'usedAt': usedAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory ActivationPinModel.fromMap(Map<String, dynamic> map) {
    return ActivationPinModel(
      code: map['code']?.toString() ?? '',
      days: (map['days'] as num?)?.toInt() ?? 30,
      isVip: map['isVip'] == true,
      isUsed: map['isUsed'] == true,
      usedBy: map['usedBy']?.toString(),
      usedAt: map['usedAt'] != null ? DateTime.tryParse(map['usedAt']) : null,
      createdAt: map['createdAt'] != null
          ? (DateTime.tryParse(map['createdAt']) ?? DateTime.now())
          : DateTime.now(),
    );
  }
}