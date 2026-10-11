class PlaylistItem {
      final String id;
        final String name;
          final String originalName;
            final String url;
              final String? logoUrl;
                final String category;
                  final bool isLive;

                    PlaylistItem({
                        required this.id,
                            required this.name,
                                required this.originalName,
                                    required this.url,
                                        this.logoUrl,
                                            required this.category,
                                                this.isLive = true,
                                                  });

                                                    Map<String, dynamic> toMap() {
                                                        return {
                                                              'id': id,
                                                                    'name': name,
                                                                          'originalName': originalName,
                                                                                'url': url,
                                                                                      'logoUrl': logoUrl,
                                                                                            'category': category,
                                                                                                  'isLive': isLive,
                                                                                                      };
                                                                                                        }

                                                                                                          factory PlaylistItem.fromMap(Map<String, dynamic> map) {
                                                                                                              return PlaylistItem(
                                                                                                                    id: map['id'] ?? '',
                                                                                                                          name: map['name'] ?? '',
                                                                                                                                originalName: map['originalName'] ?? '',
                                                                                                                                      url: map['url'] ?? '',
                                                                                                                                            logoUrl: map['logoUrl'],
                                                                                                                                                  category: map['category'] ?? 'General',
                                                                                                                                                        isLive: map['isLive'] ?? true,
                                                                                                                                                            );
                                                                                                                                                              }
                                                                                                                                                              }
                                                                                                                                                              
}