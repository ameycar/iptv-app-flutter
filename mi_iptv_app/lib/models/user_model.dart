import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String id;
  final String username;
  final String password;
  final String role; // 'admin' | 'user' | 'family_admin'
  final bool isActive;
  final bool isVip;
  final DateTime expirationDate;
  final String? registeredHardwareId; // ID único del dispositivo vinculado
  final String? deviceName; // Ej: "Smart TV Sala", "Xiaomi Box", "Samsung S23"
  final bool hardwareResetRequested; // Si el usuario solicitó cambio desde la app
  final String? hardwareResetToken; // Código PIN express (4 dígitos) de desbloqueo rápido
  final int maxScreens; // Máximo de pantallas permitidas (1 por defecto, 5 en familiar)
  final DateTime? createdAt;
  final DateTime? lastActiveAt;

  // Campos para Grupos Familiares (Hasta 5 dispositivos)
  final String? familyId;
  final bool isFamilyAdmin;
  final String? familyPlan;
  final String? familyAdminUsername;

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
  });

  bool get isAdmin => role == 'admin';
  bool get isSuperAdmin => role == 'admin';
  bool get isFamilyGroupAdmin => role == 'family_admin' || isFamilyAdmin;
  bool get hasAdminPrivileges => isAdmin || isFamilyGroupAdmin;
  bool get isPartOfFamily => familyId != null && familyId!.isNotEmpty;

  bool get isExpired => DateTime.now().isAfter(expirationDate);

  int get daysRemaining {
    final diff = expirationDate.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Verifica si el hardware actual coincide con el registrado (Tu método original)
  bool isHardwareAuthorized(String currentHardwareId) {
    if (isAdmin) return true;
    if (registeredHardwareId == null || registeredHardwareId!.isEmpty) {
      return true;
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
      'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
      'lastActiveAt': (lastActiveAt ?? DateTime.now()).toIso8601String(),
      'familyId': familyId,
      'isFamilyAdmin': isFamilyAdmin,
      'familyPlan': familyPlan,
      'familyAdminUsername': familyAdminUsername,
    };
  }

  factory UserModel.fromMap(String id, Map<String, dynamic> map) {
    DateTime parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is int) return DateTime.fromMillisecondsSinceEpoch(val);
      if (val is String) return DateTime.tryParse(val) ?? DateTime.now().add(const Duration(days: 30));
      return DateTime.now().add(const Duration(days: 30));
    }

    final parsedRole = (map['role'] ?? 'user').toString();
    final bool parsedIsFamilyAdmin = map['isFamilyAdmin'] == true || parsedRole == 'family_admin';

    return UserModel(
      id: id,
      username: (map['username'] ?? '').toString(),
      password: (map['password'] ?? '').toString(),
      role: parsedRole,
      isActive: map['isActive'] is bool ? map['isActive'] : true,
      isVip: map['isVip'] is bool ? map['isVip'] : false,
      expirationDate: parseDate(map['expirationDate']),
      registeredHardwareId: map['registeredHardwareId']?.toString(),
      deviceName: map['deviceName']?.toString(),
      hardwareResetRequested: map['hardwareResetRequested'] == true,
      hardwareResetToken: map['hardwareResetToken']?.toString(),
      maxScreens: (map['maxScreens'] as num?)?.toInt() ?? (parsedIsFamilyAdmin ? 5 : 1),
      createdAt: map['createdAt'] != null ? parseDate(map['createdAt']) : null,
      lastActiveAt: map['lastActiveAt'] != null ? parseDate(map['lastActiveAt']) : null,
      familyId: map['familyId']?.toString(),
      isFamilyAdmin: parsedIsFamilyAdmin,
      familyPlan: map['familyPlan']?.toString(),
      familyAdminUsername: map['familyAdminUsername']?.toString(),
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
    );
  }
}