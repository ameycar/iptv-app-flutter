import 'package:cloud_firestore/cloud_firestore.dart';

class UserModel {
  final String id;
  final String username;
  final String password;
  final String role; // 'admin' | 'user'
  final bool isActive;
  final bool isVip;
  final DateTime expirationDate;
  final String? registeredHardwareId; // ID único del dispositivo vinculado
  final String? deviceName; // Ej: "Smart TV Sala", "Xiaomi Box", "Samsung S23"
  final bool hardwareResetRequested; // Si el usuario solicitó cambio desde la app
  final String? hardwareResetToken; // PIN express (4 dígitos) de desbloqueo rápido
  final int maxScreens; // Máximo de pantallas permitidas (1 por defecto)
  final DateTime? createdAt;
  final DateTime? lastActiveAt;

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
  });

  bool get isAdmin => role == 'admin';

  bool get isExpired => DateTime.now().isAfter(expirationDate);

  int get daysRemaining {
    final diff = expirationDate.difference(DateTime.now()).inDays;
    return diff < 0 ? 0 : diff;
  }

  /// Verifica si el hardware actual coincide con el registrado
  bool isHardwareAuthorized(String currentHardwareId) {
    if (isAdmin) return true; // Administrador tiene acceso total
    if (registeredHardwareId == null || registeredHardwareId!.isEmpty) {
      return true; // Primer inicio: se vinculará este dispositivo automáticamente
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
      'expirationDate': Timestamp.fromDate(expirationDate),
      'registeredHardwareId': registeredHardwareId,
      'deviceName': deviceName,
      'hardwareResetRequested': hardwareResetRequested,
      'hardwareResetToken': hardwareResetToken,
      'maxScreens': maxScreens,
      'createdAt': createdAt != null ? Timestamp.fromDate(createdAt!) : FieldValue.serverTimestamp(),
      'lastActiveAt': lastActiveAt != null ? Timestamp.fromDate(lastActiveAt!) : FieldValue.serverTimestamp(),
    };
  }

  factory UserModel.fromMap(String id, Map<String, dynamic> map) {
    DateTime parseDate(dynamic val) {
      if (val is Timestamp) return val.toDate();
      if (val is String) return DateTime.tryParse(val) ?? DateTime.now().add(const Duration(days: 30));
      return DateTime.now().add(const Duration(days: 30));
    }

    return UserModel(
      id: id,
      username: (map['username'] ?? '').toString(),
      password: (map['password'] ?? '').toString(),
      role: (map['role'] ?? 'user').toString(),
      isActive: map['isActive'] is bool ? map['isActive'] : true,
      isVip: map['isVip'] is bool ? map['isVip'] : false,
      expirationDate: parseDate(map['expirationDate']),
      registeredHardwareId: map['registeredHardwareId']?.toString(),
      deviceName: map['deviceName']?.toString(),
      hardwareResetRequested: map['hardwareResetRequested'] == true,
      hardwareResetToken: map['hardwareResetToken']?.toString(),
      maxScreens: (map['maxScreens'] as num?)?.toInt() ?? 1,
      createdAt: map['createdAt'] is Timestamp ? (map['createdAt'] as Timestamp).toDate() : null,
      lastActiveAt: map['lastActiveAt'] is Timestamp ? (map['lastActiveAt'] as Timestamp).toDate() : null,
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
    );
  }
}