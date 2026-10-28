import 'package:flutter/material.dart';
import '../services/playback_history_service.dart';

class ContinueWatchingCarousel extends StatelessWidget {
  final List<PlaybackHistoryItem> items;
  final Function(PlaybackHistoryItem) onItemTap;
  final Function(PlaybackHistoryItem) onItemRemove;

  const ContinueWatchingCarousel({
    Key? key,
    required this.items,
    required this.onItemTap,
    required this.onItemRemove,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            children: [
              Icon(Icons.history_toggle_off_rounded, color: Color(0xFF00E5FF), size: 20),
              SizedBox(width: 8),
              Text(
                'Continuar Viendo',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 150,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, index) {
              final item = items[index];
              return GestureDetector(
                onTap: () => onItemTap(item),
                child: Container(
                  width: 220,
                  decoration: BoxDecoration(
                    color: const Color(0xFF131A29),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.08)),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    children: [
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (item.logoUrl.isNotEmpty)
                                  Image.network(
                                    item.logoUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, __, ___) => Container(
                                      color: const Color(0xFF1E293B),
                                      child: const Icon(Icons.movie, color: Colors.white24, size: 36),
                                    ),
                                  )
                                else
                                  Container(
                                    color: const Color(0xFF1E293B),
                                    child: const Icon(Icons.movie, color: Colors.white24, size: 36),
                                  ),
                                Container(
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.transparent,
                                        Colors.black.withOpacity(0.8),
                                      ],
                                    ),
                                  ),
                                ),
                                const Center(
                                  child: CircleAvatar(
                                    radius: 18,
                                    backgroundColor: Colors.black54,
                                    child: Icon(Icons.play_arrow_rounded, color: Color(0xFF00E5FF), size: 24),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Barra de Progreso Disney+
                          LinearProgressIndicator(
                            value: item.progressPercentage,
                            backgroundColor: Colors.white12,
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF00E5FF)),
                            minHeight: 3.5,
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${(item.positionSeconds ~/ 60)} min reproducidos',
                                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: IconButton(
                          icon: const Icon(Icons.close, color: Colors.white70, size: 16),
                          onPressed: () => onItemRemove(item),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
