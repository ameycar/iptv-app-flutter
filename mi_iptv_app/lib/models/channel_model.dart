class ChannelModel {
  final String id;
  final int number;
  final String name;
  final String streamUrl;
  final String logoUrl;
  final String groupCategory;
  final String resolution;
  final bool isValid;
  bool isFavorite;

  ChannelModel({
    required this.id,
    this.number = 0,
    required this.name,
    required this.streamUrl,
    required this.logoUrl,
    required this.groupCategory,
    this.resolution = '1080p FHD',
    this.isValid = true,
    this.isFavorite = false,
  });

  ChannelModel copyWith({
    String? id,
    int? number,
    String? name,
    String? streamUrl,
    String? logoUrl,
    String? groupCategory,
    String? resolution,
    bool? isValid,
    bool? isFavorite,
  }) {
    return ChannelModel(
      id: id ?? this.id,
      number: number ?? this.number,
      name: name ?? this.name,
      streamUrl: streamUrl ?? this.streamUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      groupCategory: groupCategory ?? this.groupCategory,
      resolution: resolution ?? this.resolution,
      isValid: isValid ?? this.isValid,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  Map<String, dynamic> toMap() => {
    'id': id,
    'number': number,
    'name': name,
    'streamUrl': streamUrl,
    'logoUrl': logoUrl,
    'groupCategory': groupCategory,
    'resolution': resolution,
    'isValid': isValid,
    'isFavorite': isFavorite,
  };

  factory ChannelModel.fromMap(Map<String, dynamic> map) {
    return ChannelModel(
      id: map['id'] ?? '',
      number: map['number'] ?? 0,
      name: map['name'] ?? '',
      streamUrl: map['streamUrl'] ?? '',
      logoUrl: map['logoUrl'] ?? '',
      groupCategory: map['groupCategory'] ?? 'General',
      resolution: map['resolution'] ?? '1080p FHD',
      isValid: map['isValid'] ?? true,
      isFavorite: map['isFavorite'] ?? false,
    );
  }
}