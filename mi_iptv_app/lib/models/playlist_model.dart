class PlaylistModel {
  final String id;
  final String profileId; // Identificador del perfil dueño de la lista (jefe o secundario)
  final String name; // Nombre asignado (ej: "Mi Lista 1", "Deportes")
  final String url; // Enlace M3U o ruta local
  final bool isActive; // Si está seleccionada para ver actualmente
  final DateTime createdAt;
  final int channelCount; // Cantidad de canales detectados

  PlaylistModel({
    required this.id,
    required this.profileId,
    required this.name,
    required this.url,
    this.isActive = true,
    DateTime? createdAt,
    this.channelCount = 0,
  }) : createdAt = createdAt ?? DateTime.now();

  PlaylistModel copyWith({
    String? id,
    String? profileId,
    String? name,
    String? url,
    bool? isActive,
    DateTime? createdAt,
    int? channelCount,
  }) {
    return PlaylistModel(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      name: name ?? this.name,
      url: url ?? this.url,
      isActive: isActive ?? this.isActive,
      createdAt: createdAt ?? this.createdAt,
      channelCount: channelCount ?? this.channelCount,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'profileId': profileId,
      'name': name,
      'url': url,
      'isActive': isActive,
      'createdAt': createdAt.toIso8601String(),
      'channelCount': channelCount,
    };
  }

  factory PlaylistModel.fromMap(Map<String, dynamic> map) {
    return PlaylistModel(
      id: map['id'] ?? '',
      profileId: map['profileId'] ?? '',
      name: map['name'] ?? '',
      url: map['url'] ?? '',
      isActive: map['isActive'] ?? true,
      createdAt: map['createdAt'] != null 
          ? DateTime.tryParse(map['createdAt']) ?? DateTime.now()
          : DateTime.now(),
      channelCount: map['channelCount'] ?? 0,
    );
  }
}