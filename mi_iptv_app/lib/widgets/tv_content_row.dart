import 'package:flutter/material.dart';
import 'focusable_tv_card.dart';

class TvContentRow extends StatefulWidget {
  final String title;
  final List<String> items; // Lista temporal para maquetar
  final double height;
  final double cardWidth;

  const TvContentRow({
    super.key,
    required this.title,
    required this.items,
    this.height = 220.0,
    this.cardWidth = 140.0,
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
              return Padding(
                padding: const EdgeInsets.only(right: 16.0),
                child: FocusableTvCard(
                  focusedScale: 1.1,
                  focusedBorderColor: const Color(0xFF00E5FF),
                  onTap: () {
                    debugPrint('Reproducir: ${widget.items[index]}');
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
                        // Imagen de portada (Placeholder para mockup)
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
                        // Título de la película/serie
                        Positioned(
                          bottom: 12,
                          left: 12,
                          right: 12,
                          child: Text(
                            widget.items[index],
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
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