import 'package:flutter/material.dart';
import 'focusable_tv_card.dart';
import '../models/channel_model.dart'; // Importamos tu modelo real

class TvContentRow extends StatefulWidget {
  final String title;
  final List<ChannelModel> items; // Lista de datos VIP reales
  final double height;
  final double cardWidth;
  final void Function(ChannelModel channel)? onItemTap; // Gatillo de reproducción

  const TvContentRow({
    super.key,
    required this.title,
    required this.items,
    this.height = 220.0,
    this.cardWidth = 140.0,
    this.onItemTap,
  });

  @override
  State<TvContentRow> createState() => _TvContentRowState();
}

class _TvContentRowState extends State<TvContentRow> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink(); // Si no hay contenido en esta categoría, ocultamos el carril
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 16.0, bottom: 12.0),
          child: Text(
            widget.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
            ),
          ),
        ),
        SizedBox(
          height: widget.height,
          child: ListView.builder(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            itemCount: widget.items.length,
            itemBuilder: (context, index) {
              final item = widget.items[index];

              return Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: FocusableTvCard(
                  focusedScale: 1.1,
                  focusedBorderColor: const Color(0xFF00E5FF),
                  onTap: () {
                    if (widget.onItemTap != null) {
                      widget.onItemTap!(item); // Avisa al Dashboard para reproducir
                    } else {
                      debugPrint('Reproducir: ${item.name}');
                    }
                  },
                  child: Container(
                    width: widget.cardWidth,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E2336),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // IMAGEN DE PORTADA / LOGO REAL
                        if (item.logoUrl.isNotEmpty)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.network(
                              item.logoUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                return const Icon(Icons.movie_creation_outlined, color: Colors.white12, size: 64);
                              },
                            ),
                          )
                        else
                          const Icon(Icons.movie_creation_outlined, color: Colors.white12, size: 64),
                        
                        // Gradiente oscuro en la parte inferior para resaltar el texto
                        Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withOpacity(0.95),
                              ],
                            ),
                          ),
                        ),
                        // TÍTULO REAL DE LA PELÍCULA/SERIE
                        Positioned(
                          bottom: 12,
                          left: 12,
                          right: 12,
                          child: Text(
                            item.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        
                        // ETIQUETA HD / 4K Opcional
                        if (item.resolution.isNotEmpty)
                          Positioned(
                            top: 8,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5), width: 0.5),
                              ),
                              child: Text(
                                item.resolution.contains('4K') ? '4K' : (item.resolution.contains('720') ? 'HD' : 'FHD'),
                                style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 9, fontWeight: FontWeight.bold),
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