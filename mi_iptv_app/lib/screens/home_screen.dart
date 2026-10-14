import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/playlist_item.dart';
import '../services/reminder_service.dart';
import '../widgets/active_reminders_dialog.dart';
import '../widgets/epg_modal.dart';
import '../widgets/voice_assistant_sheet.dart';
import 'add_playlist_screen.dart';
import 'video_player_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  List<PlaylistItem> _channels = [];
  String _activeTab = 'live'; // 'live', 'movies', 'series'
  String _selectedCategory = 'Todos';
  String _searchFilter = '';
  bool _isSearching = false;
  final TextEditingController _searchController = TextEditingController();

  late Timer _clockTimer;
  String _currentTime = '';
  int _activeRemindersCount = 0;

  @override
  void initState() {
    super.initState();
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _loadRemindersCount();
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _updateClock() {
    if (mounted) {
      setState(() {
        _currentTime = DateFormat('HH:mm:ss').format(DateTime.now());
      });
    }
  }

  Future<void> _loadRemindersCount() async {
    final list = await ReminderService().getActiveReminders();
    if (mounted) {
      setState(() {
        _activeRemindersCount = list.length;
      });
    }
  }

  void _navigateToAddPlaylist() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const AddPlaylistScreen()),
    );

    if (result != null && result is List<PlaylistItem>) {
      setState(() {
        _channels = result;
      });
    }
  }

  void _openVoiceAssistant() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => VoiceAssistantSheet(
        channels: _channels,
        onPlayChannel: (channel) {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => VideoPlayerScreen(item: channel)),
          );
        },
        onSwitchTab: (tab) {
          setState(() {
            _activeTab = tab;
            _selectedCategory = 'Todos';
          });
        },
        onSearch: (query) {
          setState(() {
            _isSearching = true;
            _searchFilter = query;
            _searchController.text = query;
          });
        },
        onOpenEPG: () {
          if (_channels.isNotEmpty) {
            _openEPGModal(_channels.first);
          }
        },
      ),
    );
  }

  void _openEPGModal(PlaylistItem channel) {
    showDialog(
      context: context,
      builder: (context) => EpgModal(
        channel: channel,
        onPlay: () {
          Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => VideoPlayerScreen(item: channel)),
          );
        },
      ),
    ).then((_) => _loadRemindersCount());
  }

  void _openRemindersList() {
    showDialog(
      context: context,
      builder: (context) => ActiveRemindersDialog(
        onRemindersChanged: _loadRemindersCount,
      ),
    );
  }

  List<PlaylistItem> _getFilteredChannels() {
    var list = _channels;

    // Filtro por pestaña (En vivo, películas, series)
    if (_activeTab == 'movies') {
      list = list.where((c) {
        final cat = c.category.toLowerCase();
        final name = c.name.toLowerCase();
        return cat.contains('pelicula') || cat.contains('movie') || cat.contains('vod') || cat.contains('cine') || name.contains('cine') || name.contains('film');
      }).toList();
    } else if (_activeTab == 'series') {
      list = list.where((c) {
        final cat = c.category.toLowerCase();
        return cat.contains('serie') || cat.contains('series') || cat.contains('show');
      }).toList();
    }

    // Filtro por categoría chip
    if (_selectedCategory != 'Todos') {
      list = list.where((c) => c.category == _selectedCategory).toList();
    }

    // Filtro por búsqueda
    if (_searchFilter.trim().isNotEmpty) {
      final q = _searchFilter.toLowerCase();
      list = list.where((c) => c.name.toLowerCase().contains(q) || c.category.toLowerCase().contains(q)).toList();
    }

    return list;
  }

  @override
  Widget build(BuildContext context) {
    final filteredChannels = _getFilteredChannels();

    // Obtener categorías únicas
    final categories = {'Todos', ..._channels.map((c) => c.category.isEmpty ? 'General' : c.category)};

    // Texto de la pestaña activa para el badge rojo
    String tabBadgeName = 'LIVE';
    if (_activeTab == 'movies') tabBadgeName = 'PELÍCULAS';
    if (_activeTab == 'series') tabBadgeName = 'SERIES';

    return Scaffold(
      backgroundColor: const Color(0xFF0C0C18),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121226),
        elevation: 0,
        titleSpacing: 12,
        title: _isSearching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  hintText: 'Buscar canal, serie o película...',
                  hintStyle: const TextStyle(color: Colors.white54),
                  border: InputBorder.none,
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () {
                      setState(() {
                        _isSearching = false;
                        _searchFilter = '';
                        _searchController.clear();
                      });
                    },
                  ),
                ),
                onChanged: (val) {
                  setState(() => _searchFilter = val);
                },
              )
            : Row(
                children: [
                  const Text(
                    'AMEYCAR TV',
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xFFB388FF),
                      fontSize: 18,
                      letterSpacing: 1.1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Badge rojo de sección
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.redAccent,
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      tabBadgeName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Reloj con fecha/calendario (Completamente separado y limpio)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1C223A),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.cyanAccent.withOpacity(0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.calendar_today_rounded, color: Colors.cyanAccent, size: 13),
                        const SizedBox(width: 5),
                        Text(
                          _currentTime,
                          style: const TextStyle(
                            color: Colors.cyanAccent,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
        actions: [
          if (!_isSearching)
            IconButton(
              tooltip: 'Buscar contenido',
              icon: const Icon(Icons.search, color: Colors.white),
              onPressed: () {
                setState(() => _isSearching = true);
              },
            ),
          // Botón directo a alarmas activas si hay alguna
          if (_activeRemindersCount > 0)
            IconButton(
              tooltip: 'Ver alarmas activas',
              icon: Stack(
                children: [
                  const Icon(Icons.notifications_active, color: Colors.amber),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle),
                      constraints: const BoxConstraints(minWidth: 14, minHeight: 14),
                      child: Text(
                        '$_activeRemindersCount',
                        style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                ],
              ),
              onPressed: _openRemindersList,
            ),
          IconButton(
            tooltip: 'Cargar lista M3U',
            icon: const Icon(Icons.playlist_add, color: Colors.white),
            onPressed: _navigateToAddPlaylist,
          ),
          // Botón del Asistente por Voz con brillo
          Padding(
            padding: const EdgeInsets.only(right: 8.0),
            child: IconButton(
              tooltip: 'Asistente de Voz Inteligente',
              icon: Container(
                padding: const EdgeInsets.all(6),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [Color(0xFF00E5FF), Color(0xFF7C4DFF)]),
                ),
                child: const Icon(Icons.mic, color: Colors.white, size: 20),
              ),
              onPressed: _openVoiceAssistant,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // Pestañas En Vivo / Películas / Series
          Container(
            color: const Color(0xFF121226),
            child: Row(
              children: [
                _buildMainTab('En Vivo', 'live'),
                _buildMainTab('Películas', 'movies'),
                _buildMainTab('Series', 'series'),
              ],
            ),
          ),

          // Barra Now Playing EPG en vivo si estamos en TV
          if (_activeTab == 'live' && _channels.isNotEmpty)
            GestureDetector(
              onTap: () => _openEPGModal(_channels.first),
              child: Container(
                margin: const EdgeInsets.fromLTRB(14, 10, 14, 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1A38),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.deepPurpleAccent.withOpacity(0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.live_tv, color: Colors.redAccent, size: 16),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            'Magacín de Entretenimiento de la Tarde',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '23:00 - 00:00',
                          style: TextStyle(color: Colors.purple.shade200, fontSize: 11),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'A continuación: Serie Exclusiva: Temporada Estelar',
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        Text(
                          'Quedan 41 min',
                          style: TextStyle(color: Colors.cyanAccent, fontSize: 11),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),

          // Chips de categorías horizontales
          if (_channels.isNotEmpty)
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                children: categories.map((cat) {
                  final isSelected = _selectedCategory == cat;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8.0),
                    child: FilterChip(
                      selected: isSelected,
                      label: Text(cat),
                      labelStyle: TextStyle(
                        color: isSelected ? Colors.white : Colors.white70,
                        fontSize: 12,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                      backgroundColor: const Color(0xFF1A1A2E),
                      selectedColor: const Color(0xFF651FFF),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                      onSelected: (_) {
                        setState(() => _selectedCategory = cat);
                      },
                    ),
                  );
                }).toList(),
              ),
            ),

          // Lista de Canales o Cuadrícula
          Expanded(
            child: _channels.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.tv_off_rounded, size: 80, color: Colors.white24),
                        const SizedBox(height: 16),
                        const Text(
                          'No hay canales cargados',
                          style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text('Agrega una lista M3U para disfrutar de Ameycar TV.', style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 24),
                        ElevatedButton.icon(
                          onPressed: _navigateToAddPlaylist,
                          icon: const Icon(Icons.add, color: Colors.white),
                          label: const Text('Agregar Lista M3U', style: TextStyle(color: Colors.white)),
                          style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF651FFF)),
                        ),
                      ],
                    ),
                  )
                : filteredChannels.isEmpty
                    ? const Center(
                        child: Text(
                          'No se encontraron coincidencias',
                          style: TextStyle(color: Colors.white54, fontSize: 15),
                        ),
                      )
                    : _activeTab == 'movies'
                        ? _buildMoviesGrid(filteredChannels)
                        : _buildChannelsList(filteredChannels),
          ),
        ],
      ),
    );
  }

  Widget _buildMainTab(String label, String tabKey) {
    final isSelected = _activeTab == tabKey;
    return Expanded(
      child: InkWell(
        onTap: () {
          setState(() {
            _activeTab = tabKey;
            _selectedCategory = 'Todos';
          });
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? const Color(0xFFB388FF) : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isSelected ? Colors.white : Colors.white60,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildChannelsList(List<PlaylistItem> list) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final ch = list[index];
        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF16162D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            leading: Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: Colors.black38,
                borderRadius: BorderRadius.circular(8),
              ),
              child: ch.logoUrl != null && ch.logoUrl!.isNotEmpty
                  ? Image.network(
                      ch.logoUrl!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: Colors.deepPurpleAccent, size: 28),
                    )
                  : const Icon(Icons.tv, color: Colors.deepPurpleAccent, size: 28),
            ),
            title: Text(
              ch.name,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              'Grupo: ${ch.category.isEmpty ? "General" : ch.category} • 1080p FHD',
              style: const TextStyle(color: Colors.white54, fontSize: 11),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Guía EPG y Recordatorios',
                  icon: const Icon(Icons.calendar_month, color: Colors.cyanAccent, size: 22),
                  onPressed: () => _openEPGModal(ch),
                ),
                const Icon(Icons.play_arrow_rounded, color: Colors.deepPurpleAccent, size: 28),
              ],
            ),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => VideoPlayerScreen(item: ch)),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildMoviesGrid(List<PlaylistItem> list) {
    return GridView.builder(
      padding: const EdgeInsets.all(14),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.72,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: list.length,
      itemBuilder: (context, index) {
        final item = list[index];
        return GestureDetector(
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => VideoPlayerScreen(item: item)),
            );
          },
          child: Container(
            decoration: BoxDecoration(
              color: const Color(0xFF1B1B33),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white10),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: item.logoUrl != null && item.logoUrl!.isNotEmpty
                      ? Image.network(
                          item.logoUrl!,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => const Center(
                            child: Icon(Icons.movie, color: Colors.deepPurpleAccent, size: 50),
                          ),
                        )
                      : const Center(
                          child: Icon(Icons.movie, color: Colors.deepPurpleAccent, size: 50),
                        ),
                ),
                // Badge HD
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.cyanAccent, width: 0.8),
                    ),
                    child: const Text('HD', style: TextStyle(color: Colors.cyanAccent, fontSize: 10, fontWeight: FontWeight.bold)),
                  ),
                ),
                // Título en degradado inferior
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: const BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [Colors.black, Colors.transparent],
                      ),
                      borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
                    ),
                    child: Text(
                      item.name,
                      style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}