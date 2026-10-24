import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; // NUEVO: Para leer la nube
import 'package:url_launcher/url_launcher.dart'; // NUEVO: Para abrir WhatsApp
import '../models/playlist_item.dart';
import '../models/playlist_model.dart';
import '../services/auth_service.dart';
import '../services/reminder_service.dart';
import '../services/m3u_parser_service.dart'; // NUEVO: Para descargar listas M3U automáticamente
import '../widgets/active_reminders_dialog.dart';
import '../widgets/epg_modal.dart';
import '../widgets/alexa_voice_sheet.dart';
import 'add_playlist_screen.dart';
import 'video_player_screen.dart';
import 'profile_selector_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  List<PlaylistItem> _channels = [];
  List<PlaylistModel> _userPlaylists = [];
  String _activeTab = 'live'; // 'live', 'movies', 'series'
  String _selectedCategory = 'Todos';
  String _searchFilter = '';
  bool _isSearching = false;
  bool _isLoadingChannels = true;
  final TextEditingController _searchController = TextEditingController();

  late Timer _clockTimer;
  String _currentTime = '';
  int _activeRemindersCount = 0;

  // Multitarea: Canal reproduciéndose en Miniatura Flotante (PiP)
  PlaylistItem? _pipChannel;

  String get _currentProfileId =>
      AuthService.currentActiveProfile?.id ??
      AuthService.currentUser?.id ??
      'perfil_principal';

  String get _currentProfileName =>
      AuthService.currentActiveProfile?.username ??
      AuthService.currentUser?.username ??
      'Perfil';

  // RESTRICCIÓN ESTRICTA DE JEFE / ADMIN FAMILIAR
  bool get _isJefeProfile => AuthService.isFamilyAdmin;

  @override
  void initState() {
    super.initState();
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _loadRemindersCount();
    _loadProfileChannelsAndPlaylists();
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
    try {
      final list = await ReminderService().getActiveReminders();
      if (mounted) {
        setState(() {
          _activeRemindersCount = list.length;
        });
      }
    } catch (_) {}
  }

  /// Carga listas y canales del perfil actual (Incluye Sincronización Cloud Automática)
  Future<void> _loadProfileChannelsAndPlaylists() async {
    setState(() => _isLoadingChannels = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlistsKey = 'saved_playlists_$_currentProfileId';
      final rawPlaylists = prefs.getString(playlistsKey);
      List<PlaylistModel> playlists = [];

      // 1. Cargar las listas locales si existen
      if (rawPlaylists != null && rawPlaylists.isNotEmpty) {
        try {
          final List list = jsonDecode(rawPlaylists);
          playlists = list.map((m) => PlaylistModel.fromMap(m)).toList();
        } catch (e) {
          debugPrint('Error parseando listas del perfil: $e');
        }
      }

      // 2. MAGIA CLOUD: Buscar listas en Firestore (Ideal para nueva TV Box)
      if (AuthService.isFirebaseAvailable && AuthService.currentUser != null) {
        try {
          final cloudSnap = await FirebaseFirestore.instance
              .collection('users')
              .doc(AuthService.currentUser!.id)
              .collection('profiles')
              .doc(_currentProfileId)
              .collection('playlists')
              .get();

          if (cloudSnap.docs.isNotEmpty) {
            bool isLocalUpdated = false;
            for (var doc in cloudSnap.docs) {
              final cloudPl = PlaylistModel.fromMap(doc.data());
              // Si la TV Box aún no tiene esta lista de la nube, la agrega
              if (!playlists.any((p) => p.id == cloudPl.id)) {
                playlists.add(cloudPl);
                isLocalUpdated = true;
              }
            }

            if (isLocalUpdated) {
              if (playlists.isNotEmpty && !playlists.any((p) => p.isActive)) {
                playlists[0] = playlists[0].copyWith(isActive: true);
              }
              await prefs.setString(playlistsKey, jsonEncode(playlists.map((p) => p.toMap()).toList()));
            }
          }
        } catch (e) {
          debugPrint('Error al sincronizar listas de Firestore: $e');
        }
      }

      // 3. Cargar canales activos locales
      final channelsKey = 'active_channels_$_currentProfileId';
      final rawChannels = prefs.getString(channelsKey);
      List<PlaylistItem> loadedChannels = [];

      if (rawChannels != null && rawChannels.isNotEmpty) {
        try {
          final List list = jsonDecode(rawChannels);
          loadedChannels = list.map((m) => PlaylistItem.fromMap(m)).toList();
        } catch (e) {
          debugPrint('Error parseando canales activos: $e');
        }
      }

      // 4. AUTO-DESCARGA: Si no hay canales locales pero SÍ hay una playlist (ej. recién bajada de la nube)
      if (loadedChannels.isEmpty && playlists.isNotEmpty) {
        final activePl = playlists.firstWhere((p) => p.isActive, orElse: () => playlists.first);
        final plChannelsKey = 'channels_${_currentProfileId}_${activePl.id}';
        final rawPlChannels = prefs.getString(plChannelsKey);

        if (rawPlChannels != null && rawPlChannels.isNotEmpty) {
          final List list = jsonDecode(rawPlChannels);
          loadedChannels = list.map((m) => PlaylistItem.fromMap(m)).toList();
        } else {
          // El TV no tiene los canales. Se conecta a la URL de la nube y los descarga automáticamente.
          try {
            loadedChannels = await M3UParserService.fetchAndParseM3U(activePl.url);
            final encodedChannels = jsonEncode(loadedChannels.map((i) => i.toMap()).toList());
            await prefs.setString(plChannelsKey, encodedChannels);
            await prefs.setString('active_channels_$_currentProfileId', encodedChannels);
            await prefs.setString('active_playlist_id_$_currentProfileId', activePl.id);
          } catch (e) {
            debugPrint('Error auto-descargando canales M3U: $e');
          }
        }
      }

      if (mounted) {
        setState(() {
          _userPlaylists = playlists;
          _channels = loadedChannels;
          _isLoadingChannels = false;
        });
      }
    } catch (e) {
      debugPrint('Error al cargar datos del perfil: $e');
      if (mounted) setState(() => _isLoadingChannels = false);
    }
  }

  /// Navega a agregar lista y recarga el perfil
  void _navigateToAddPlaylist() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => AddPlaylistScreen(profileId: _currentProfileId),
      ),
    );

    if (result != null) {
      if (result is Map && result['channels'] is List<PlaylistItem>) {
        setState(() {
          _channels = result['channels'] as List<PlaylistItem>;
          if (result['playlist'] is PlaylistModel) {
            _userPlaylists.removeWhere((p) => p.id == (result['playlist'] as PlaylistModel).id);
            _userPlaylists.add(result['playlist'] as PlaylistModel);
          }
        });
      } else if (result is List<PlaylistItem>) {
        setState(() {
          _channels = result;
        });
      }
      _loadProfileChannelsAndPlaylists();
    }
  }

  /// Abre el Gestor de Listas M3U (permite ver hasta 5 listas, alternar cuál está activa y borrar)
  void _openPlaylistManagerDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                top: 20,
                left: 20,
                right: 20,
                bottom: MediaQuery.of(context).viewInsets.bottom + 24,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.playlist_play, color: Color(0xFF8B5CF6), size: 28),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Gestor de Listas M3U',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'Perfil: $_currentProfileName (${_userPlaylists.length}/5)',
                                style: const TextStyle(color: Colors.white60, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white60),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_userPlaylists.isEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: const Column(
                        children: [
                          Icon(Icons.tv_off_rounded, size: 48, color: Colors.white30),
                          SizedBox(height: 12),
                          Text(
                            'No tienes listas guardadas en este perfil',
                            style: TextStyle(color: Colors.white70, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  ] else ...[
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 280),
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: _userPlaylists.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, index) {
                          final pl = _userPlaylists[index];
                          return Container(
                            decoration: BoxDecoration(
                              color: pl.isActive
                                  ? const Color(0xFF8B5CF6).withOpacity(0.18)
                                  : const Color(0xFF1E293B),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: pl.isActive
                                    ? const Color(0xFF8B5CF6)
                                    : Colors.white.withOpacity(0.08),
                                width: pl.isActive ? 1.5 : 1,
                              ),
                            ),
                            child: ListTile(
                              leading: Icon(
                                pl.isActive
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_off,
                                color: pl.isActive
                                    ? const Color(0xFF8B5CF6)
                                    : Colors.white38,
                              ),
                              title: Text(
                                pl.name,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight:
                                      pl.isActive ? FontWeight.bold : FontWeight.w500,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                '${pl.channelCount} canales • ${pl.isActive ? "ACTIVA" : "Toca para activar"}',
                                style: TextStyle(
                                  color: pl.isActive ? Colors.cyanAccent : Colors.white54,
                                  fontSize: 11,
                                ),
                              ),
                              trailing: IconButton(
                                icon: const Icon(Icons.delete_outline,
                                    color: Colors.redAccent, size: 20),
                                onPressed: () async {
                                  await _deletePlaylist(pl);
                                  setSheetState(() {});
                                },
                              ),
                              onTap: () async {
                                await _switchActivePlaylist(pl);
                                setSheetState(() {});
                              },
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  if (_userPlaylists.length < 5) ...[
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.pop(context);
                        _navigateToAddPlaylist();
                      },
                      icon: const Icon(Icons.add, color: Colors.white),
                      label: Text(
                        'Agregar Otra Lista (${_userPlaylists.length}/5)',
                        style: const TextStyle(
                            color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF8B5CF6),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ] else ...[
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.amber.withOpacity(0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Has alcanzado el límite máximo de 5 listas para este perfil.',
                        style: TextStyle(color: Colors.amber, fontSize: 12),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// Alterna cuál lista está activa en este perfil
  Future<void> _switchActivePlaylist(PlaylistModel target) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final updated = _userPlaylists
          .map((p) => p.copyWith(isActive: p.id == target.id))
          .toList();

      final playlistsKey = 'saved_playlists_$_currentProfileId';
      await prefs.setString(
        playlistsKey,
        jsonEncode(updated.map((p) => p.toMap()).toList()),
      );

      final channelsKey = 'channels_${_currentProfileId}_${target.id}';
      final raw = prefs.getString(channelsKey);

      List<PlaylistItem> newChannels = [];
      if (raw != null && raw.isNotEmpty) {
        final List list = jsonDecode(raw);
        newChannels = list.map((m) => PlaylistItem.fromMap(m)).toList();
        await prefs.setString('active_channels_$_currentProfileId', raw);
        await prefs.setString('active_playlist_id_$_currentProfileId', target.id);
      } else {
         // Si por alguna razón la lista no estaba procesada, la descargamos.
         newChannels = await M3UParserService.fetchAndParseM3U(target.url);
         final encodedChannels = jsonEncode(newChannels.map((i) => i.toMap()).toList());
         await prefs.setString(channelsKey, encodedChannels);
         await prefs.setString('active_channels_$_currentProfileId', encodedChannels);
         await prefs.setString('active_playlist_id_$_currentProfileId', target.id);
      }

      setState(() {
        _userPlaylists = updated;
        _channels = newChannels;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lista activa cambiada a: "${target.name}"'),
            backgroundColor: const Color(0xFF8B5CF6),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('Error cambiando lista activa: $e');
    }
  }

  /// Elimina una lista del perfil (Local y Nube)
  Future<void> _deletePlaylist(PlaylistModel target) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _userPlaylists.removeWhere((p) => p.id == target.id);

      final playlistsKey = 'saved_playlists_$_currentProfileId';
      await prefs.setString(
        playlistsKey,
        jsonEncode(_userPlaylists.map((p) => p.toMap()).toList()),
      );

      await prefs.remove('channels_${_currentProfileId}_${target.id}');
      
      // ELIMINAR DE LA NUBE (Para que no reaparezca en otros dispositivos)
      if (AuthService.isFirebaseAvailable && AuthService.currentUser != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(AuthService.currentUser!.id)
              .collection('profiles')
              .doc(_currentProfileId)
              .collection('playlists')
              .doc(target.id)
              .delete();
        } catch (_) {}
      }

      if (target.isActive && _userPlaylists.isNotEmpty) {
        await _switchActivePlaylist(_userPlaylists.first);
      } else if (_userPlaylists.isEmpty) {
        await prefs.remove('active_channels_$_currentProfileId');
        await prefs.remove('active_playlist_id_$_currentProfileId');
        setState(() {
          _channels = [];
        });
      } else {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Error eliminando lista: $e');
    }
  }

  /// Cambia de perfil volviendo al selector Disney+
  void _switchProfile() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const ProfileSelectorScreen()),
    );

    if (result != null || mounted) {
      _loadProfileChannelsAndPlaylists();
    }
  }

  void _openVoiceAssistant() {
    AlexaVoiceSheet.show(
      context,
      channels: _channels,
      currentSection: _activeTab,
      onChannelSelected: (channel) {
        _playChannel(channel);
      },
      onNavigateSection: (section) {
        setState(() {
          final s = section.toLowerCase();
          if (s.contains('peli') || s == 'movies') {
            _activeTab = 'movies';
          } else if (s.contains('seri') || s == 'series') {
            _activeTab = 'series';
          } else {
            _activeTab = 'live';
          }
          _selectedCategory = 'Todos';
        });
      },
      onSearch: (query, section) {
        setState(() {
          _isSearching = true;
          _searchFilter = query;
          _searchController.text = query;
          final s = section.toLowerCase();
          if (s.contains('peli') || s == 'movies') {
            _activeTab = 'movies';
          } else if (s.contains('seri') || s == 'series') {
            _activeTab = 'series';
          } else {
            _activeTab = 'live';
          }
        });
      },
      onOpenEpg: () {
        if (_channels.isNotEmpty) {
          _openEPGModal(_channels.first);
        }
      },
    );
  }

  void _playChannel(PlaylistItem channel) {
    setState(() {
      _pipChannel = null;
    });
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(
          item: channel,
          channels: _channels,
          onMinimizeToPiP: (minimizedItem) {
            setState(() {
              _pipChannel = minimizedItem;
            });
          },
        ),
      ),
    );
  }

  void _openEPGModal(PlaylistItem channel) {
    showDialog(
      context: context,
      builder: (context) => EpgModal(
        channel: channel,
        onPlay: () => _playChannel(channel),
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

    if (_activeTab == 'movies') {
      list = list.where((c) {
        final cat = c.category.toLowerCase();
        final name = c.name.toLowerCase();
        return cat.contains('pelicula') ||
            cat.contains('movie') ||
            cat.contains('vod') ||
            cat.contains('cine') ||
            name.contains('cine') ||
            name.contains('film');
      }).toList();
    } else if (_activeTab == 'series') {
      list = list.where((c) {
        final cat = c.category.toLowerCase();
        return cat.contains('serie') || cat.contains('series') || cat.contains('show');
      }).toList();
    }

    if (_selectedCategory != 'Todos') {
      list = list.where((c) => c.category == _selectedCategory).toList();
    }

    if (_searchFilter.trim().isNotEmpty) {
      final q = _searchFilter.toLowerCase();
      list = list
          .where((c) =>
              c.name.toLowerCase().contains(q) || c.category.toLowerCase().contains(q))
          .toList();
    }

    return list;
  }

  // MÉTODO NUEVO: Menú inferior de Soporte Técnico Directo vía WhatsApp
  void _openSupportMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.only(top: 20, left: 20, right: 20, bottom: 40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.support_agent, color: Color(0xFF00E5FF), size: 28),
                  SizedBox(width: 10),
                  Text(
                    'Soporte Técnico Directo',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Selecciona el motivo de tu consulta. Te atenderemos vía WhatsApp.',
                style: TextStyle(color: Colors.white60, fontSize: 12),
              ),
              const SizedBox(height: 20),
              
              _buildSupportOption(
                icon: Icons.autorenew,
                title: 'Renovar o recuperar mi servicio',
                subtitle: 'Si tu proveedor anterior ya no responde',
                message: 'Hola Ameycar TV, mi proveedor original ya no me atiende y deseo renovar mi perfil directamente con ustedes.',
              ),
              const SizedBox(height: 10),
              _buildSupportOption(
                icon: Icons.wifi_tethering_error_rounded,
                title: 'Reportar problema de conexión',
                subtitle: 'Fallas técnicas o cortes de señal',
                message: 'Hola equipo, estoy experimentando fallas de conexión en mi dispositivo.',
              ),
              const SizedBox(height: 10),
              _buildSupportOption(
                icon: Icons.add_to_queue,
                title: 'Solicitar pantallas adicionales',
                subtitle: 'Ampliar plan familiar',
                message: 'Hola, me interesa ampliar mi plan y adquirir pantallas adicionales.',
              ),
            ],
          ),
        );
      },
    );
  }

  // MÉTODO NUEVO: Widget de opciones de Soporte con enlace a WhatsApp
  Widget _buildSupportOption({required IconData icon, required String title, required String subtitle, required String message}) {
    return InkWell(
      onTap: () async {
        Navigator.pop(context); // Cierra el menú
        final phoneNumber = "51905823660"; // COLOCA AQUÍ TU NÚMERO REAL
        final url = Uri.parse("whatsapp://send?phone=$phoneNumber&text=${Uri.encodeComponent(message)}");
        
        try {
          if (await canLaunchUrl(url)) {
            await launchUrl(url);
          } else {
             final webUrl = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(message)}");
             await launchUrl(webUrl, mode: LaunchMode.externalApplication);
          }
        } catch (e) {
          debugPrint("Error al abrir WhatsApp: $e");
        }
      },
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF00E5FF).withOpacity(0.1), shape: BoxShape.circle),
              child: Icon(icon, color: const Color(0xFF00E5FF), size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                  Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const Icon(Icons.arrow_forward_ios, color: Colors.white38, size: 14),
          ],
        ),
      ),
    );
  }

  Widget _buildDynamicEPGBar() {
    if (_channels.isEmpty || _activeTab != 'live') return const SizedBox.shrink();

    final now = DateTime.now();
    final startHour = now.hour;
    final endHour = (startHour + 1) % 24;
    final remainingMin = 60 - now.minute;

    final firstChannel = _channels.first;
    final isSports = firstChannel.name.toLowerCase().contains('deporte') ||
        firstChannel.name.toLowerCase().contains('espn') ||
        firstChannel.name.toLowerCase().contains('fox') ||
        firstChannel.name.toLowerCase().contains('dsports');

    final currentProgram = isSports
        ? "⚽ Transmisión en Vivo: Fútbol Internacional de Primera División"
        : "📺 ${firstChannel.name} - Emisión Estelar en Directo (HD)";

    final nextProgram = isSports
        ? "Resumen de la Jornada y Goles de la Fecha"
        : "Edición Nocturna y Análisis";

    return GestureDetector(
      onTap: () => _openEPGModal(firstChannel),
      child: Container(
        margin: const EdgeInsets.fromLTRB(14, 10, 14, 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1A38),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.live_tv, color: Colors.redAccent, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentProgram,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${startHour.toString().padLeft(2, '0')}:00 -${endHour.toString().padLeft(2, '0')}:00',
                  style: const TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'A continuación: $nextProgram',
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  'Quedan $remainingMin min',
                  style: const TextStyle(
                      color: Colors.cyanAccent,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFloatingMiniPlayer() {
    if (_pipChannel == null) return const SizedBox.shrink();

    return Positioned(
      bottom: 12,
      left: 14,
      right: 14,
      child: GestureDetector(
        onTap: () => _playChannel(_pipChannel!),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF121B2F),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFF00E5FF), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF00E5FF).withOpacity(0.3),
                blurRadius: 15,
                spreadRadius: 2,
              )
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.play_circle_fill,
                    color: Color(0xFF00E5FF), size: 30),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _pipChannel!.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 13),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const Text(
                      'Reproduciendo en segundo plano • Toca para expandir',
                      style: TextStyle(color: Colors.cyanAccent, fontSize: 10),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.fullscreen, color: Colors.white),
                onPressed: () => _playChannel(_pipChannel!),
              ),
              IconButton(
                icon: const Icon(Icons.close, color: Colors.white54),
                onPressed: () {
                  setState(() => _pipChannel = null);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filteredChannels = _getFilteredChannels();
    final categories = {
      'Todos',
      ..._channels.map((c) => c.category.isEmpty ? 'General' : c.category)
    };

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
                  // Botón del Perfil Activo
                  InkWell(
                    onTap: _switchProfile,
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: _isJefeProfile
                            ? Colors.amber.withOpacity(0.18)
                            : const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _isJefeProfile
                              ? Colors.amber
                              : Colors.cyanAccent.withOpacity(0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _isJefeProfile ? Icons.shield : Icons.person,
                            color: _isJefeProfile ? Colors.amber : Colors.cyanAccent,
                            size: 14,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _currentProfileName.toUpperCase(),
                            style: TextStyle(
                              color: _isJefeProfile ? Colors.amber : Colors.cyanAccent,
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 2),
                          const Icon(Icons.arrow_drop_down, color: Colors.white54, size: 16),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
        actions: [
          // BOTÓN DE SOPORTE INTEGRADO
          if (!_isSearching)
            IconButton(
              tooltip: 'Soporte y Renovaciones',
              icon: const Icon(Icons.headset_mic, color: Color(0xFF00E5FF)),
              onPressed: _openSupportMenu,
            ),
          if (!_isSearching)
            IconButton(
              tooltip: 'Buscar contenido',
              icon: const Icon(Icons.search, color: Colors.white),
              onPressed: () {
                setState(() => _isSearching = true);
              },
            ),
          if (_activeRemindersCount >
