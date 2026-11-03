import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/channel_model.dart';
import '../widgets/pro_video_player.dart';

class TvDashboardScreen extends StatefulWidget {
  final VoidCallback? onLogout;

  const TvDashboardScreen({super.key, this.onLogout});

  @override
  State<TvDashboardScreen> createState() => _TvDashboardScreenState();
}

class _TvDashboardScreenState extends State<TvDashboardScreen> {
  final FocusScopeNode _tvFocusScope = FocusScopeNode();
  final FocusNode _sidebarFocusNode = FocusNode();
  
  bool _isSidebarExpanded = false;
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
      // Inicializar con canales o lógica de carga de la app si se requiere
    } catch (_) {}
  }

  @override
  void dispose() {
    _tvFocusScope.dispose();
    _sidebarFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
          setState(() => _isSidebarExpanded = true);
          FocusScope.of(context).requestFocus(_sidebarFocusNode);
        },
        const SingleActivator(LogicalKeyboardKey.arrowRight): () {
          if (_isSidebarExpanded) {
            setState(() => _isSidebarExpanded = false);
          }
        },
      },
      child: FocusScope(
        node: _tvFocusScope,
        autofocus: true,
        child: Scaffold(
          backgroundColor: const Color(0xFF070A10),
          body: Stack(
            children: [
              // Capa de video de fondo, de tamaño completo
              const Positioned.fill(
                child: Center(
                  child: Text(
                    'REPRODUCTOR DE FONDO ACTIVO',
                    style: TextStyle(color: Colors.white24, fontSize: 24, fontWeight: FontWeight.bold),
                  ),
                ),
              ),

              // Superposición semi-transparente que oscurece el fondo
              Positioned.fill(
                child: Container(
                  color: Colors.black.withOpacity(0.35),
                ),
              ),

              // Capa del Sidebar Translúcido (Glassmorphism)
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
                            // Logotipo o Banner superior
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
                            // Secciones del menú
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

              // Área de contenido principal desplazada para no colisionar con el menú
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
                    // Aquí se insertarán las grillas translúcidas e inteligentes
                  ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() {
              _selectedSection = section;
              _isSidebarExpanded = false;
            });
          },
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: isSelected ? Colors.white.withOpacity(0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
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
        ),
      ),
    );
  }
}