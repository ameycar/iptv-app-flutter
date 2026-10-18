class ChannelModel {
  final String id;
  final int number;
  final String name;
  final String streamUrl;
  final String logoUrl;
  final String groupCategory;
  final String resolution;
  final String contentType; // 'live', 'movie', 'series'
  final String year;
  final String rating;
  final bool isValid;
  bool isFavorite;
  final String tvgId;
  final String countryFeed;

  ChannelModel({
    required this.id,
    this.number = 0,
    required this.name,
    required this.streamUrl,
    required this.logoUrl,
    required this.groupCategory,
    this.resolution = '1080p FHD',
    this.contentType = 'live',
    this.year = '',
    this.rating = 'HD',
    this.isValid = true,
    this.isFavorite = false,
    this.tvgId = '',
    this.countryFeed = '',
  });

  bool get isMovie => contentType == 'movie';
  bool get isSeries => contentType == 'series';
  bool get isLive => contentType == 'live';

  ChannelModel copyWith({
    String? id,
    int? number,
    String? name,
    String? streamUrl,
    String? logoUrl,
    String? groupCategory,
    String? resolution,
    String? contentType,
    String? year,
    String? rating,
    bool? isValid,
    bool? isFavorite,
    String? tvgId,
    String? countryFeed,
  }) {
    return ChannelModel(
      id: id ?? this.id,
      number: number ?? this.number,
      name: name ?? this.name,
      streamUrl: streamUrl ?? this.streamUrl,
      logoUrl: logoUrl ?? this.logoUrl,
      groupCategory: groupCategory ?? this.groupCategory,
      resolution: resolution ?? this.resolution,
      contentType: contentType ?? this.contentType,
      year: year ?? this.year,
      rating: rating ?? this.rating,
      isValid: isValid ?? this.isValid,
      isFavorite: isFavorite ?? this.isFavorite,
      tvgId: tvgId ?? this.tvgId,
      countryFeed: countryFeed ?? this.countryFeed,
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
    'contentType': contentType,
    'year': year,
    'rating': rating,
    'isValid': isValid,
    'isFavorite': isFavorite,
    'tvgId': tvgId,
    'countryFeed': countryFeed,
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
      contentType: map['contentType'] ?? 'live',
      year: map['year'] ?? '',
      rating: map['rating'] ?? 'HD',
      isValid: map['isValid'] ?? true,
      isFavorite: map['isFavorite'] ?? false,
      tvgId: map['tvgId'] ?? '',
      countryFeed: map['countryFeed'] ?? '',
    );
  }
}