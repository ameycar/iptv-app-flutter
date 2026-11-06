import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/channel_model.dart';

class TvVodDetailsScreen extends StatefulWidget {
  final ChannelModel item;

  const TvVodDetailsScreen({super.key, required this.item});

  @override
  State<TvVodDetailsScreen> createState() => _TvVodDetailsScreenState();
}

class _TvVodDetailsScreenState extends State<TvVodDetailsScreen> {
  final FocusScopeNode _detailsFocusScope = FocusScopeNode();
  
  @override
  void dispose() {
    _detailsFocusScope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isSeries = widget.item.contentType == 'series';

    return FocusScope(
      node: _detailsFocusScope,
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.goBack) {
            Navigator.pop(context, false);
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070A10),
        body: Stack(
          children: [
            // 1. FONDO INMERSIVO (Póster gigante)
            Positioned.fill(
              child: widget.item.logoUrl.isNotEmpty
                  ? Image.network(
                      widget.item.logoUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const Icon(Icons.movie, color: Colors.white10, size: 200),
                    )
                  : const Icon(Icons.movie, color: Colors.white10, size: 200),
            ),
            
            // 2. GRADIENTES PARA LEER EL TEXTO
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF070A10).withOpacity(1.0), // Muy oscuro a la izquierda
                      const Color(0xFF070A10).withOpacity(0.85),
                      const Color(0xFF070A10).withOpacity(0.4), // Más claro a la derecha
                      Colors.transparent,
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF070A10).withOpacity(1.0), 
                      Colors.transparent,
                    ],
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                  ),
                ),
              ),
            ),

            // 3. CONTENIDO PRINCIPAL (Navegable)
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 50.0, vertical: 40.0),
                child: FocusTraversalGroup(
                  policy: WidgetOrderTraversalPolicy(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // ETQUETAS SUPERIORES
                      Row(
                        children: [
                          _buildBadge(isSeries ? 'SERIE' : 'PELÍCULA', const Color(0xFFC77DFF)),
                          const SizedBox(width: 10),
                          _buildBadge(widget.item.resolution.isNotEmpty ? widget.item.resolution : 'HD', const Color(0xFF00E5FF)),
                          const SizedBox(width: 10),
                          _buildBadge(widget.item.groupCategory, Colors.white38),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // TÍTULO GIGANTE
                      SizedBox(
                        width: MediaQuery.of(context).size.width * 0.6,
                        child: Text(
                          widget.item.name,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 48,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2,
                            shadows: [Shadow(color: Colors.black, blurRadius: 10)],
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 20),

                      // SINOPSIS / DESCRIPCIÓN
                      SizedBox(
                        width: MediaQuery.of(context).size.width * 0.5,
                        child: Text(
                          isSeries 
                            ? 'Disfruta de todos los episodios de esta increíble serie. Selecciona reproducir para continuar donde te quedaste.'
                            : 'Una experiencia cinematográfica imperdible. Prepara tus snacks, ponte cómodo y disfruta de este gran título en la mejor calidad.',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            height: 1.5,
                            shadows: [Shadow(color: Colors.black, blurRadius: 4)],
                          ),
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(height: 36),

                      // BOTONES DE ACCIÓN (Control Remoto)
                      Row(
                        children: [
                          _buildHeroActionBtn(
                            'Reproducir', 
                            Icons.play_arrow_rounded, 
                            isPrimary: true,
                            autoFocus: true, // El foco arranca aquí
                            onTap: () => Navigator.pop(context, true), // Devuelve 'true' para indicar que se debe reproducir
                          ),
                          const SizedBox(width: 16),
                          _buildHeroActionBtn(
                            'Favorito', 
                            Icons.star_border_rounded, 
                            isPrimary: false,
                            onTap: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Añadido a Favoritos ⭐'), backgroundColor: Color(0xFF7B2CBF)),
                              );
                            },
                          ),
                          const SizedBox(width: 16),
                          _buildHeroActionBtn(
                            'Volver', 
                            Icons.arrow_back_rounded, 
                            isPrimary: false,
                            onTap: () => Navigator.pop(context, false), // Devuelve 'false'
                          ),
                        ],
                      ),
                      
                      // ESPACIO PARA TEMPORADAS (Si es serie)
                      if (isSeries) ...[
                        const SizedBox(height: 40),
                        const Text(
                          'Temporada 1',
                          style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          height: 100,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: 5,
                            itemBuilder: (context, index) {
                              return _buildEpisodeCard(index + 1);
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroActionBtn(String text, IconData icon, {required bool isPrimary, bool autoFocus = false, required VoidCallback onTap}) {
    return Builder(builder: (context) {
      return Focus(
        autofocus: autoFocus,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
            onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: hasFocus
                    ? const Color(0xFF00E5FF)
                    : (isPrimary ? Colors.white : Colors.white.withOpacity(0.1)),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: hasFocus ? Colors.white : Colors.transparent,
                  width: hasFocus ? 2 : 0,
                ),
                boxShadow: hasFocus
                    ? [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.6), blurRadius: 15)]
                    : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, color: hasFocus ? Colors.black : (isPrimary ? Colors.black : Colors.white), size: 24),
                  const SizedBox(width: 8),
                  Text(text,
                      style: TextStyle(
                          color: hasFocus ? Colors.black : (isPrimary ? Colors.black : Colors.white),
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                ],
              ),
            ),
          );
        }),
      );
    });
  }

  Widget _buildEpisodeCard(int epNumber) {
    return Builder(builder: (context) {
      return Focus(
        child: Builder(builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return Container(
            width: 180,
            margin: const EdgeInsets.only(right: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF131A29),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: hasFocus ? const Color(0xFF00E5FF) : Colors.white10, width: hasFocus ? 2 : 1),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: widget.item.logoUrl.isNotEmpty
                      ? Opacity(opacity: 0.5, child: Image.network(widget.item.logoUrl, fit: BoxFit.cover))
                      : const SizedBox.shrink(),
                ),
                Center(
                  child: Icon(Icons.play_circle_fill, color: hasFocus ? const Color(0xFF00E5FF) : Colors.white54, size: 36),
                ),
                Positioned(
                  bottom: 8,
                  left: 8,
                  child: Text('Episodio $epNumber', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                ),
              ],
            ),
          );
        }),
      );
    });
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.5),
      ),
    );
  }
}