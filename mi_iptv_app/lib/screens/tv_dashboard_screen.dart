import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/channel_model.dart';
import '../widgets/pro_video_player.dart';
import '../widgets/focusable_tv_card.dart';

class TvDashboardScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const TvDashboardScreen({super.key, this.onLogout});

  @override
  State<TvDashboardScreen> createState() => _TvDashboardScreenState();
}

class _TvDashboardScreenState extends State<TvDashboardScreen> {
  final FocusScopeNode _tvFocusScope = FocusScopeNode();
  final FocusNode _sidebarFocusNode = FocusNode();
  final FocusNode _zappingFocusNode = FocusNode(); // Foco para el riel de canales
  
  bool _isSidebarExpanded = false;
  bool _isZappingOverlayVisible = false; // Estado del panel inferior
  Timer? _zappingHideTimer;

  String _selectedSection = 'En Vivo';
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
      // Lógica futura para cargar tus canales reales desde Firestore/Hive
    } catch (_) {}
  }

  // Lógica para mostrar el panel de zapping y ocultarlo tras 5 segundos
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
            // Si cerramos el menú, devolvemos el foco al área general
            FocusScope.of(context).requestFocus(_tvFocusScope);
          }
        },
        // Al presionar Arriba o Abajo, activamos el Overlay de Zapping
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
              // 1. CAPA DE VIDEO: Reproductor de fondo activo
              const Positioned.fill(
                child: Center(
                  child: Text(
                    'REPRODUCTOR DE FONDO ACTIVO\n(Presiona Arriba/Abajo para Zapping)',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white24, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              // Superposición semi-transparente base
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.35),
                ),
              ),

              // 2. CAPA ÁREA PRINCIPAL
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                left: _isSidebarExpanded ? 260 : 90,
                right: 20,
                top: 20,
                bottom: 20,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _selectedSection,
                      style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),

              // 3. CAPA ZAPPING OVERLAY (Riel inferior Translúcido)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeOutCubic,
                bottom: _isZappingOverlayVisible ? 0 : -200, // Se esconde debajo de la pantalla
                left: _isSidebarExpanded ? 240 : 70, // Respeta el espacio del sidebar
                right: 0,
                height: 160,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(topLeft: Radius.circular(24)),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.65),
                        border: Border(
                          top: BorderSide(color: Colors.white.withOpacity(0.1), width: 1),
                        ),
                      ),
                      padding: const EdgeInsets.only(top: 16, bottom: 16, left: 16),
                      child: Focus(
                        focusNode: _zappingFocusNode,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: 10, // Mock de 10 canales
                          itemBuilder: (context, index) {
                            return Padding(
                              padding: const EdgeInsets.only(right: 16),
                              child: FocusableTvCard(
                                focusedScale: 1.1,
                                focusedBorderColor: const Color(0xFF00E5FF),
                                onTap: () {
                                  // Al hacer clic (OK) en el control, reiniciamos el temporizador
                                  _triggerZappingOverlay();
                                  debugPrint('Cambiar al canal $index');
                                },
                                child: Container(
                                  width: 180,
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        const Color(0xFF1E2336),
                                        Colors.black.withOpacity(0.8),
                                      ],
                                    ),
                                  ),
                                  child: Stack(
                                    children: [
                                      // Imagen de fondo/logo del canal
                                      const Center(
                                        child: Icon(Icons.tv, color: Colors.white24, size: 48),
                                      ),
                                      // Textos EPG sobre la tarjeta
                                      Positioned(
                                        bottom: 12,
                                        left: 12,
                                        right: 12,
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Text(
                                              'CH ${index + 1}',
                                              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 12, fontWeight: FontWeight.bold),
                                            ),
                                            const Text(
                                              'Programa en Vivo',
                                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
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

              // 4. CAPA SIDEBAR TRANSLÚCIDO (Siempre por encima del zapping en el eje Z)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                left: 0,
                top: 0,
                bottom: 0,
                width: _isSidebarExpanded ? 240 : 70,
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(16),
                    bottomRight: Radius.circular(16),
                  ),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        border: Border(
                          right: BorderSide(color: Colors.white.withOpacity(0.15), width: 1),
                        ),
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
                                    child: Text(
                                      'AMEYCAR TV',
                                      style: TextStyle(color: Color(0xFF00E5FF), fontSize: 18, fontWeight: FontWeight.black, letterSpacing: 1.2),
                                    ),
                                  )
                                : const Icon(Icons.tv_rounded, color: Color(0xFF00E5FF), size: 28),
                            const SizedBox(height: 32),
                            Expanded(
                              child: ListView(
                                children: [
                                  _buildSidebarItem(Icons.live_tv, 'En Vivo', 'En Vivo'),
                                  _buildSidebarItem(Icons.movie, 'Películas', 'Películas'),
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
        // Retornamos el foco al área general al seleccionar
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