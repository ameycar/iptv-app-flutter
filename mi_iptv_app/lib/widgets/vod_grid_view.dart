import 'package:flutter/material.dart';
import '../models/channel_model.dart';

class VodGridView extends StatefulWidget {
  final List<ChannelModel> items;
  final String contentType; // 'movie' o 'series'
  final Function(ChannelModel item) onPlayItem;

  const VodGridView({
    super.key,
    required this.items,
    required this.contentType,
    required this.onPlayItem,
  });

  @override
  State<VodGridView> createState() => _VodGridViewState();
}

class _VodGridViewState extends State<VodGridView> {
  String _selectedGenre = 'Todos';

  List<String> get _genres {
    final list = widget.items.map((e) => e.groupCategory).toSet().toList();
    return ['Todos', ...list];
  }

  List<ChannelModel> get _filteredItems {
    if (_selectedGenre == 'Todos') return widget.items;
    return widget.items.where((e) => e.groupCategory == _selectedGenre).toList();
  }

  void _showItemDetailsModal(ChannelModel item) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 26),
        decoration: BoxDecoration(
          color: const Color(0xFF070A10).withOpacity(0.98),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4), width: 1.5),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Póster Grande
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Container(
                    width: 100,
                    height: 145,
                    color: const Color(0xFF1E293B),
                    child: item.logoUrl.isNotEmpty
                        ? Image.network(
                            item.logoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _buildFallbackPoster(item),
                          )
                        : _buildFallbackPoster(item),
                  ),
                ),
                const SizedBox(width: 16),
                // Información de la Película / Serie
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          if (item.year.isNotEmpty) ...[
                            _buildTag(item.year, Colors.white70),
                            const SizedBox(width: 6),
                          ],
                          _buildTag(item.resolution, const Color(0xFF00E5FF)),
                          const SizedBox(width: 6),
                          _buildTag('★ ${item.rating}', const Color(0xFFFFB703)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Género: ${item.groupCategory}',
                        style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 12),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.contentType == 'movie'
                            ? 'Película disponible en streaming bajo demanda.'
                            : 'Serie completa con temporadas y capítulos.',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 22),

            // Botón de Reproducción estilo Netflix
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00E5FF),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  elevation: 6,
                ),
                onPressed: () {
                  Navigator.pop(ctx);
                  widget.onPlayItem(item);
                },
                icon: const Icon(Icons.play_arrow, size: 26),
                label: Text(
                  widget.contentType == 'movie' ? 'Reproducir Película' : 'Ver Serie / Episodio',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cerrar Ficha', style: TextStyle(color: Colors.white54)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        text,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildFallbackPoster(ChannelModel item) {
    return Container(
      color: const Color(0xFF131B2E),
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            widget.contentType == 'movie' ? Icons.movie_outlined : Icons.tv_outlined,
            color: const Color(0xFF00E5FF),
            size: 28,
          ),
          const SizedBox(height: 6),
          Text(
            item.name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white70, fontSize: 9, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredItems;

    if (list.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.contentType == 'movie' ? Icons.local_movies_outlined : Icons.video_library_outlined,
              color: Colors.white24,
              size: 56,
            ),
            const SizedBox(height: 12),
            Text(
              'No se encontraron ${widget.contentType == 'movie' ? 'películas' : 'series'} en tu lista',
              style: const TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // Selector Horizontal de Géneros
        Container(
          height: 44,
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: _genres.length,
            itemBuilder: (context, index) {
              final genre = _genres[index];
              final isSelected = genre == _selectedGenre;
              return GestureDetector(
                onTap: () => setState(() => _selectedGenre = genre),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected ? const Color(0xFF00E5FF) : const Color(0xFF1E293B).withOpacity(0.8),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: isSelected ? const Color(0xFF00E5FF) : Colors.white10,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      genre,
                      style: TextStyle(
                        color: isSelected ? Colors.black : Colors.white70,
                        fontSize: 11,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Cuadrícula de Pósters (Grid estilo Netflix)
        Expanded(
          child: GridView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: MediaQuery.of(context).orientation == Orientation.portrait ? 3 : 5,
              childAspectRatio: 0.65,
              crossAxisSpacing: 10,
              mainAxisSpacing: 12,
            ),
            itemCount: list.length,
            itemBuilder: (context, index) {
              final item = list[index];

              return InkWell(
                onTap: () => _showItemDetailsModal(item),
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.5),
                        blurRadius: 6,
                        offset: const Offset(0, 3),
                      )
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // Imagen de portada
                        item.logoUrl.isNotEmpty
                            ? Image.network(
                                item.logoUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _buildFallbackPoster(item),
                              )
                            : _buildFallbackPoster(item),

                        // Gradiente inferior para el título
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Colors.black.withOpacity(0.95),
                                  Colors.black.withOpacity(0.6),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  item.name,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (item.year.isNotEmpty)
                                  Text(
                                    item.year,
                                    style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 9),
                                  ),
                              ],
                            ),
                          ),
                        ),

                        // Badge de Resolución arriba
                        Positioned(
                          top: 5,
                          right: 5,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.7),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.6), width: 0.8),
                            ),
                            child: Text(
                              item.resolution.contains('4K') ? '4K' : 'HD',
                              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 8, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                      ],
                    ),
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