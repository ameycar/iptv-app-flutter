import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/channel_model.dart';
import '../widgets/pro_video_player.dart';
import '../widgets/focusable_tv_card.dart';
import '../widgets/tv_content_row.dart'; // Importación de la Fase 6: Carruseles

class TvDashboardScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const TvDashboardScreen({super.key, this.onLogout});

  @override
  State<TvDashboardScreen> createState() => _TvDashboardScreenState();
}

class _TvDashboardScreenState extends State<TvDashboardScreen> {
  final FocusScopeNode _tvFocusScope = FocusScopeNode();
  final FocusNode _sidebarFocusNode = FocusNode();
  final FocusNode _zappingFocusNode = FocusNode();
  
  bool _isSidebarExpanded = false;
  bool _isZappingOverlayVisible = false;
  Timer? _zappingHideTimer;

  String _selectedSection = 'Inicio VIP';
  List<ChannelModel> _channels = [];
  int _selectedChannelIndex = 0;

  @override
  void initState() {
    super.initState();
    _loadChannels();
  }

  Future<void> _loadChannels() async {
    try {
      final box = Hive.box('watch_progress_box');
      // Lógica futura para cargar canales
    } catch (_) {}
  }

  void _triggerZappingOverlay() {
    setState(() => _isZappingOverlayVisible = true);
    FocusScope.of(context).requestFocus(_zappingFocusNode);
    
    _zappingHideTimer?.cancel();
    _zappingHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _isZappingOverlayVisible = false);
      }
    });
  }

  @override
  void dispose() {
    _zappingHideTimer?.cancel();
    _tvFocusScope.dispose();
    _sidebarFocusNode.dispose();
    _zappingFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          if (!_isSidebarExpanded && !_isZappingOverlayVisible) {
            setState(() => _isSidebarExpanded = true);
            FocusScope.of(context).requestFocus(_sidebarFocusNode);
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          if (_isSidebarExpanded) {
            setState(() => _isSidebarExpanded = false);
            FocusScope.of(context).requestFocus(_tvFocusScope);
          }
        },
        const SingleActivator(LogicalKeyboardKey.arrowUp): _triggerZappingOverlay,
        const SingleActivator(LogicalKeyboardKey.arrowDown): _triggerZappingOverlay,
      },
      child: FocusScope(
        node: _tvFocusScope,
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF070A10),
          body: Stack(
            children: [
              // 1. CAPA DE VIDEO (Fondo Absoluto)
              const Positioned.fill(
                child: Center(
                  child: Text(
                    'STREAMING DE FONDO',
                    style: TextStyle(color: Colors.white10, fontSize: 32, fontWeight: FontWeight.w900),
                  ),
                ),
              ),

              // Oscurecimiento base para resaltar la UI
              Positioned.fill(
                child: Container(color: Colors.black.withOpacity(0.4)),
              ),

              // 2. CAPA ÁREA PRINCIPAL (VOD & Inteligencia Artificial)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                left: _isSidebarExpanded ? 260 : 90,
                right: 0, // Se extiende hasta el borde derecho
                top: 0,
                bottom: 0,
                child: _buildMainVODContent(),
              ),

              // 3. CAPA ZAPPING OVERLAY (Riel inferior Translúcido)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                bottom: _isZappingOverlayVisible ? 0 : -200,
                left: _isSidebarExpanded ? 240 : 70,
                right: 0,
                height: 160,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(24)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.65),
                        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.1), width: 1)),
                      ),
                      padding: const EdgeInsets.only(top: 16, bottom: 16, left: 16),
                      child: Focus(
                        focusNode: _zappingFocusNode,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: 10,
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: FocusableTvCard(
                                focusedScale: 1.1,
                                focusedBorderColor: const Color(0xFF00E5FF),
                                onTap: () => _triggerZappingOverlay(),
                                child: Container(
                                  width: 180,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [const Color(0xFF1E2336), Colors.black.withOpacity(0.8)],
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      const Center(child: Icon(Icons.tv, color: Colors.white24, size: 48)),
                                      Positioned(
                                        bottom: 12,
                                        left: 12,
                                        right: 12,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text('CH ${index + 1}', style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold)),
                                            const Text('En Vivo Ahora', style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600)),
                                          ],
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
                    ),
                  ),
                ),
              ),

              // 4. CAPA SIDEBAR TRANSLÚCIDO
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                left: 0,
                top: 0,
                bottom: 0,
                width: _isSidebarExpanded ? 240 : 70,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(topRight: Radius.circular(16), bottomRight: Radius.circular(16)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        border: Border(right: BorderSide(color: Colors.white.withOpacity(0.15), width: 1)),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
                      child: Focus(
                        focusNode: _sidebarFocusNode,
                        child: Column(
                          crossAxisAlignment: _isSidebarExpanded ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                          children: [
                            _isSidebarExpanded
                                ? const Padding(
                                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    child: Text('AMEYCAR TV', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 18, fontWeight: FontWeight.black, letterSpacing: 1.2)),
                                  )
                                : const Icon(Icons.tv_rounded, color: Color(0xFF00E5FF), size: 28),
                            const SizedBox(height: 32),
                            Expanded(
                              child: ListView(
                                children: [
                                  _buildSidebarItem(Icons.home_filled, 'Inicio VIP', 'Inicio VIP'),
                                  _buildSidebarItem(Icons.live_tv, 'Televisión', 'Televisión'),
                                  _buildSidebarItem(Icons.movie, 'Cine IA', 'Cine IA'),
                                  _buildSidebarItem(Icons.tv, 'Series', 'Series'),
                                  _buildSidebarItem(Icons.settings, 'Ajustes', 'Ajustes'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // --- NUEVA SECCIÓN MAGISTRAL: El Área de Contenido ---
  Widget _buildMainVODContent() {
    return SingleChildScrollView(
      clipBehavior: Clip.none,
      physics: const BouncingScrollPhysics(),
      child: Padding(
        padding: const EdgeInsets.only(top: 32.0, bottom: 80.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Título Dinámico
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Text(
                _selectedSection,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 38,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.5,
                  shadows: [Shadow(color: Colors.black87, blurRadius: 15, offset: Offset(0, 5))],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // El "Gancho": Hero Banner Inteligente
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: _buildHeroBanner(),
            ),
            const SizedBox(height: 48),

            // Los Carruseles Magnéticos
            const TvContentRow(
              title: '🔮 Selección de IA para Carlos',
              items: ['El Creador', 'Dune: Parte 2', 'Oppenheimer', 'Interstellar', 'Blade Runner 2049', 'Matrix Resurrecciones'],
              height: 240,
              cardWidth: 160,
            ),
            const SizedBox(height: 32),
            const TvContentRow(
              title: '⏱️ Continuar Viendo',
              items: ['The Last of Us - S1:E3', 'Gladiador', 'Succession - S4:E1'],
              height: 160,
              cardWidth: 280, // Aspect Ratio 16:9 para episodios
            ),
            const SizedBox(height: 32),
            const TvContentRow(
              title: '🔥 Estrenos Premium',
              items: ['Spider-Man', 'John Wick 4', 'Barbie', 'Super Mario Bros', 'Fast X'],
              height: 240,
              cardWidth: 160,
            ),
          ],
        ),
      ),
    );
  }

  // --- EL HERO BANNER (El diseño impactante superior) ---
  Widget _buildHeroBanner() {
    return FocusableTvCard(
      focusedScale: 1.02, // Escala suave por ser un elemento tan grande
      focusedBorderColor: const Color(0xFF00E5FF),
      onTap: () => debugPrint('Reproducir Contenido Destacado'),
      child: Container(
        height: 340,
        width: double.infinity,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF131726), Color(0xFF0A0C14)],
          ),
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.6), blurRadius: 25, offset: const Offset(0, 15)),
          ],
        ),
        child: Stack(
          children: [
            // Patrón de fondo tecnológico (Sin imágenes de internet para que cargue ultra rápido)
            Positioned(
              right: -60,
              top: -60,
              child: Icon(Icons.hub_outlined, size: 400, color: const Color(0xFF00E5FF).withOpacity(0.04)),
            ),
            Positioned(
              right: 60,
              bottom: -40,
              child: Icon(Icons.movie_filter_rounded, size: 250, color: Colors.deepPurpleAccent.withOpacity(0.05)),
            ),
            
            // Textos y Botones
            Padding(
              padding: const EdgeInsets.all(40.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  // Etiqueta de IA
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(
                      color: const Color(0xFF00E5FF).withOpacity(0.15),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.auto_awesome, color: Color(0xFF00E5FF), size: 16),
                        SizedBox(width: 8),
                        Text('Recomendación IA: 98% Afinidad', style: TextStyle(color: Color(0xFF00E5FF), fontWeight: FontWeight.bold, fontSize: 13, letterSpacing: 0.5)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  
                  // Título principal
                  const Text(
                    'AMEYCAR ORIGINALS',
                    style: TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 2.5),
                  ),
                  const SizedBox(height: 12),
                  
                  // Descripción
                  const Text(
                    'Disfruta de la mejor experiencia cinematográfica en casa.\nUn catálogo infinito seleccionado inteligentemente para ti.',
                    style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.5),
                  ),
                  const SizedBox(height: 32),
                  
                  // Botones de acción
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.play_arrow_rounded, color: Colors.black, size: 26),
                            SizedBox(width: 8),
                            Text('Reproducir', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold, fontSize: 17)),
                          ],
                        ),
                      ),
                      const SizedBox(width: 20),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.white.withOpacity(0.2)),
                        ),
                        child: const Text('Más Información', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 17)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarItem(IconData icon, String title, String section) {
    final isSelected = _selectedSection == section;
    return FocusableTvCard(
      padding: const EdgeInsets.symmetric(vertical: 6),
      focusedBorderColor: const Color(0xFF00E5FF),
      focusedScale: 1.05,
      onTap: () {
        setState(() {
          _selectedSection = section;
          _isSidebarExpanded = false;
        });
        FocusScope.of(context).requestFocus(_tvFocusScope);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? Colors.white.withOpacity(0.12) : Colors.transparent,
        ),
        child: Row(
          mainAxisAlignment: _isSidebarExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
          children: [
            Icon(icon, color: isSelected ? const Color(0xFF00E5FF) : Colors.white60, size: 22),
            if (_isSidebarExpanded) ...[
              const SizedBox(width: 16),
              Text(
                title,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.white60,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 15,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}