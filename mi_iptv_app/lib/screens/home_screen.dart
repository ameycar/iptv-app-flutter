import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; 
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart'; 
import 'package:url_launcher/url_launcher.dart'; 
import '../models/playlist_item.dart';
import '../models/playlist_model.dart';
import '../services/auth_service.dart';
import '../services/reminder_service.dart';
import '../services/m3u_parser_service.dart'; 
import '../services/parental_service.dart';
import '../services/user_customization_service.dart';
import '../services/playback_history_service.dart';
import '../widgets/active_reminders_dialog.dart';
import '../widgets/epg_modal.dart';
import '../widgets/alexa_voice_sheet.dart';
import '../widgets/pin_dialog.dart';
import '../widgets/rename_channel_dialog.dart';
import '../widgets/profile_customization_sheet.dart';
import '../widgets/continue_watching_carousel.dart';
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
  String _activeTab = 'live'; 
  String _selectedCategory = 'Todos';
  String _searchFilter = '';
  bool _isSearching = false;
  bool _isLoadingChannels = true;
  final TextEditingController _searchController = TextEditingController();

  late Timer _clockTimer;
  String _currentTime = '';
  int _activeRemindersCount = 0;

  PlaylistItem? _pipChannel;
  Map<String, String> _customChannelAliases = {};
  Color _accentColor = const Color(0xFF00E5FF);
  String? _userAvatarUrl;
  List<PlaybackHistoryItem> _continueWatchingItems = [];

  String get _currentProfileId =>
      AuthService.currentActiveProfile?.id ??
      AuthService.currentUser?.id ??
      'perfil_principal';

  String get _currentProfileName =>
      AuthService.currentActiveProfile?.username ??
      AuthService.currentUser?.username ??
      'Perfil';

  bool get _isJefeProfile => AuthService.isFamilyAdmin;

  bool get _canSeePaymentBanks {
    final user = AuthService.currentUser;
    if (user == null) return false;
    return user.isFamilyAdmin || !user.isPartOfFamily || (user.familyId == null || user.familyId!.isEmpty);
  }

  @override
  void initState() {
    super.initState();
    _updateClock();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) => _updateClock());
    _loadRemindersCount();
    _loadCustomizations();
    _loadContinueWatching();
    _loadProfileChannelsAndPlaylists();
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadContinueWatching() async {
    try {
      final items = await PlaybackHistoryService.getHistory(_currentProfileId);
      if (mounted) {
        setState(() {
          _continueWatchingItems = items;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadCustomizations() async {
    try {
      final aliases = await UserCustomizationService.getChannelAliases();
      final color = await UserCustomizationService.getAccentColor();
      final avatar = await UserCustomizationService.getUserAvatar();
      if (mounted) {
        setState(() {
          _customChannelAliases = aliases;
          _accentColor = color;
          _userAvatarUrl = avatar;
        });
      }
    } catch (_) {}
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

  Future<void> _loadProfileChannelsAndPlaylists() async {
    setState(() => _isLoadingChannels = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final playlistsKey = 'saved_playlists_$_currentProfileId';
      final rawPlaylists = prefs.getString(playlistsKey);
      List<PlaylistModel> playlists = [];

      if (rawPlaylists != null && rawPlaylists.isNotEmpty) {
        try {
          final List list = jsonDecode(rawPlaylists);
          playlists = list.map((m) => PlaylistModel.fromMap(m)).toList();
        } catch (e) {
          debugPrint('Error parseando listas del perfil: $e');
        }
      }

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

      if (loadedChannels.isEmpty && playlists.isNotEmpty) {
        final activePl = playlists.firstWhere((p) => p.isActive, orElse: () => playlists.first);
        final plChannelsKey = 'channels_${_currentProfileId}_${activePl.id}';
        final rawPlChannels = prefs.getString(plChannelsKey);

        if (rawPlChannels != null && rawPlChannels.isNotEmpty) {
          final List list = jsonDecode(rawPlChannels);
          loadedChannels = list.map((m) => PlaylistItem.fromMap(m)).toList();
        } else {
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

      await _loadCustomizations();
      await _loadContinueWatching();

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

  void _playChannel(PlaylistItem channel, {int? resumeAtSeconds}) {
    setState(() {
      _pipChannel = null;
    });
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => VideoPlayerScreen(
          item: channel,
          channels: _channels,
          startAtSeconds: resumeAtSeconds,
          onMinimizeToPiP: (minimizedItem) {
            setState(() {
              _pipChannel = minimizedItem;
            });
          },
        ),
      ),
    ).then((_) {
      _loadContinueWatching();
      _loadRemindersCount();
    });
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

  Future<void> _handleCategorySelection(String categoryName) async {
    final isLocked = await ParentalService.isCategoryLocked(categoryName);
    if (isLocked) {
      if (!mounted) return;
      final enteredPin = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (context) => PinDialog(title: 'Categoría Protegida: $categoryName'),
      );

      if (enteredPin == null) return;

      final isValid = await ParentalService.verifyPin(enteredPin);
      if (!isValid) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('PIN incorrecto. Acceso bloqueado.'),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _selectedCategory = categoryName;
    });
  }

  Future<void> _onChannelLongPress(PlaylistItem channel) async {
    final channelKey = channel.url.isNotEmpty ? channel.url : channel.id;
    final currentDisplayName = _customChannelAliases[channelKey] ?? channel.name;

    final newName = await showDialog<String>(
      context: context,
      builder: (_) => RenameChannelDialog(
        channelId: channelKey,
        currentName: currentDisplayName,
      ),
    );

    if (newName != null && mounted) {
      await _loadCustomizations();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Nombre actualizado: "$newName"'),
          backgroundColor: const Color(0xFF00E5FF),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
      list = list.where((c) {
        final channelKey = c.url.isNotEmpty ? c.url : c.id;
        final displayName = (_customChannelAliases[channelKey] ?? c.name).toLowerCase();
        return displayName.contains(q) || c.category.toLowerCase().contains(q);
      }).toList();
    }

    return list;
  }

  void _showSettingsMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 32, left: 20, right: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white24,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Configuración y Ajustes',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              _buildSettingsTile(
                icon: Icons.person,
                color: _accentColor,
                title: 'Editar Interfaz y Perfil',
                subtitle: 'Cambiar avatar, nombre y diseño',
                onTap: () {
                  Navigator.pop(context);
                  showModalBottomSheet(
                    context: context,
                    isScrollControlled: true,
                    backgroundColor: Colors.transparent,
                    builder: (_) => ProfileCustomizationSheet(
                      onThemeChanged: () {
                        _loadCustomizations();
                      },
                    ),
                  );
                },
              ),
              _buildSettingsTile(
                icon: Icons.lock_outline_rounded,
                color: Colors.amberAccent,
                title: 'Control Parental & PIN',
                subtitle: 'Bloquear categorías y proteger contenido',
                onTap: () {
                  Navigator.pop(context);
                  _openParentalManagerDialog();
                },
              ),
              _buildSettingsTile(
                icon: Icons.playlist_play,
                color: const Color(0xFF8B5CF6),
                title: 'Gestor de Listas M3U',
                subtitle: 'Administra tus proveedores de IPTV',
                onTap: () {
                  Navigator.pop(context);
                  _openPlaylistManagerDialog();
                },
              ),
              _buildSettingsTile(
                icon: Icons.switch_account,
                color: const Color(0xFFC77DFF),
                title: 'Cambiar de Cuenta / Perfil',
                subtitle: 'Ir al selector de pantallas familiares',
                onTap: () {
                  Navigator.pop(context);
                  _switchProfile();
                },
              ),
              _buildSettingsTile(
                icon: Icons.language,
                color: const Color(0xFFFFD600),
                title: 'Cambiar Idioma',
                subtitle: 'Actualmente: Español (Latinoamérica)',
                onTap: () {
                  Navigator.pop(context);
                },
              ),
              _buildSettingsTile(
                icon: Icons.headset_mic,
                color: const Color(0xFF00E676),
                title: 'Soporte Técnico Especializado',
                subtitle: 'Contactar al administrador por WhatsApp',
                onTap: () {
                  Navigator.pop(context);
                  _openSupportMenu();
                },
              ),
              const Divider(color: Colors.white10, height: 24),
              _buildSettingsTile(
                icon: Icons.logout,
                color: Colors.redAccent,
                title: 'Cerrar Sesión Segura',
                subtitle: 'Desconectar cuenta de este dispositivo',
                onTap: () async {
                  Navigator.pop(context);
                  await AuthService.logout();
                  if (mounted) {
                    Navigator.pushAndRemoveUntil(
                      context,
                      MaterialPageRoute(builder: (context) => const ProfileSelectorScreen()),
                      (route) => false,
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }

  void _openParentalManagerDialog() async {
    final categories = _channels
        .map((c) => c.category.isEmpty ? 'General' : c.category)
        .toSet()
        .toList();

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF161F36),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setParentalState) {
            return FutureBuilder<List<String>>(
              future: ParentalService.getLockedCategories(),
              builder: (context, snapshot) {
                final lockedCats = snapshot.data ?? [];
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
                          const Row(
                            children: [
                              Icon(Icons.shield, color: Colors.amberAccent, size: 26),
                              SizedBox(width: 10),
                              Text(
                                'Categorías Bloqueadas',
                                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                            ],
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, color: Colors.white60),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'Activa el candado en las categorías que requieran PIN para acceder.',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      const SizedBox(height: 14),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 260),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: categories.length,
                          separatorBuilder: (_, __) => const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            final cat = categories[i];
                            final isLocked = lockedCats.contains(cat);
                            return Container(
                              decoration: BoxDecoration(
                                color: const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: isLocked ? Colors.amberAccent : Colors.white10),
                              ),
                              child: ListTile(
                                leading: Icon(
                                  isLocked ? Icons.lock : Icons.lock_open,
                                  color: isLocked ? Colors.amberAccent : Colors.white38,
                                ),
                                title: Text(cat, style: const TextStyle(color: Colors.white, fontSize: 14)),
                                trailing: Switch(
                                  value: isLocked,
                                  activeColor: Colors.amberAccent,
                                  onChanged: (val) async {
                                    await ParentalService.toggleCategoryLock(cat);
                                    setParentalState(() {});
                                    setState(() {});
                                  },
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.pin, color: Colors.black),
                        label: const Text('Cambiar o Crear PIN Parental', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.amberAccent,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        onPressed: () async {
                          final pin = await showDialog<String>(
                            context: context,
                            builder: (_) => const PinDialog(title: 'Establecer Nuevo PIN (4 dígitos)'),
                          );
                          if (pin != null && pin.length == 4) {
                            await ParentalService.setPin(pin);
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('¡PIN Parental actualizado con éxito!')),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildSettingsTile({required IconData icon, required Color color, required String title, required String subtitle, required VoidCallback onTap}) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: color.withOpacity(0.15),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
      subtitle: Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      trailing: const Icon(Icons.arrow_forward_ios, color: Colors.white24, size: 14),
      onTap: onTap,
    );
  }

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

  Widget _buildSupportOption({required IconData icon, required String title, required String subtitle, required String message}) {
    return InkWell(
      onTap: () async {
        Navigator.pop(context); 
        final phoneNumber = "51905823660"; 
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

  void _showPaymentOptionsModal(BuildContext context, {required bool isHead}) {
    final pinCtrl = TextEditingController();
    bool isProcessing = false;
    final currentUser = AuthService.currentActiveProfile ?? AuthService.currentUser;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0E1320),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 18,
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                Row(
                  children: [
                    Icon(isHead ? Icons.stars : Icons.confirmation_number, color: const Color(0xFFFFD700), size: 24),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        isHead ? 'Renovación de Suscripción' : 'Canjear PIN de Activación',
                        style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w900),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  isHead
                      ? 'Métodos seguros para extender tu plan sin comisiones.'
                      : 'Ingresa el código proporcionado por el titular para activar tu pantalla.',
                  style: const TextStyle(color: Colors.white60, fontSize: 12),
                ),
                const SizedBox(height: 16),

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF131A29),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.4), width: 1.2),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.confirmation_number, color: Color(0xFF00E5FF), size: 18),
                          SizedBox(width: 8),
                          Text(
                            'Ingresar PIN de Acceso',
                            style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        'Si recibiste un PIN de activación de tu proveedor, ingrésalo aquí:',
                        style: TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: pinCtrl,
                              style: const TextStyle(color: Colors.white, letterSpacing: 1.5, fontWeight: FontWeight.bold),
                              textCapitalization: TextCapitalization.characters,
                              decoration: InputDecoration(
                                hintText: 'Ej: AMEY-30D-4921',
                                hintStyle: const TextStyle(color: Colors.white24, letterSpacing: 0),
                                filled: true,
                                fillColor: Colors.black38,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: isProcessing
                                ? null
                                : () async {
                                    final code = pinCtrl.text.trim();
                                    if (code.isEmpty) return;
                                    setModalState(() => isProcessing = true);
                                    final res = await AuthService.redeemActivationPin(code);
                                    setModalState(() => isProcessing = false);
                                    if (context.mounted) {
                                      Navigator.pop(ctx);
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(res.message),
                                          backgroundColor: res.isSuccess ? const Color(0xFF00E676) : Colors.redAccent,
                                        ),
                                      );
                                      if (res.isSuccess) setState(() {});
                                    }
                                  },
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF00E5FF),
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                            ),
                            child: const Text('Canjear', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                if (isHead) ...[
                  const SizedBox(height: 20),
                  const Row(
                    children: [
                      Text('🇵🇪 ', style: TextStyle(fontSize: 16)),
                      Text('Pago Nacional (Cero Comisiones):', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentTile(
                    icon: Icons.phone_android,
                    color: const Color(0xFF7B2CBF),
                    title: 'Yape / Plin',
                    subtitle: '51905823660 • Titular: AMEYCAR TV', 
                    copyText: '51905823660', 
                    context: context,
                  ),
                  const SizedBox(height: 8),
                  _buildPaymentTile(
                    icon: Icons.account_balance,
                    color: const Color(0xFFFF7043),
                    title: 'BCP - Cuenta Soles',
                    subtitle: '19194759620085 • Titular: ACOSTA NN CARLOS RAFAEL', 
                    copyText: '19194759620085', 
                    context: context,
                  ),
                  const SizedBox(height: 20),
                  const Row(
                    children: [
                      Text('🌎 ', style: TextStyle(fontSize: 16)),
                      Text('Pago Internacional (Anti-Fraude):', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _buildPaymentTile(
                    icon: Icons.currency_bitcoin,
                    color: const Color(0xFFFFD700),
                    title: 'Binance Pay (USDT - Inmediato)',
                    subtitle: 'Pay ID: 214778098', 
                    copyText: '214778098', 
                    context: context,
                  ),
                  const SizedBox(height: 8),
                  _buildPaymentTile(
                    icon: Icons.account_balance_wallet,
                    color: const Color(0xFF0072FF),
                    title: 'PayPal',
                    subtitle: 'carlos_87_21@hotmail.com', 
                    copyText: 'carlos_87_21@hotmail.com', 
                    context: context,
                  ),
                  const SizedBox(height: 20),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1E283D),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF25D366).withOpacity(0.5), width: 1.5),
                    ),
                    child: Column(
                      children: [
                        const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.check_circle_outline, color: Color(0xFF25D366), size: 22),
                            SizedBox(width: 8),
                            Text(
                              'Validar Pago y Activar',
                              style: TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Toca aquí para enviar la captura de tu transferencia. Te entregaremos tu PIN de renovación de inmediato.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white60, fontSize: 11),
                        ),
                        const SizedBox(height: 12),
                        ElevatedButton.icon(
                          icon: const Icon(Icons.chat, color: Colors.white, size: 16),
                          label: const Text('Enviar Voucher por WhatsApp', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF25D366),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: () async {
                            final msg = '¡Hola! He realizado una transferencia para renovar mi plan hoy. Mi usuario es: ${currentUser?.username ?? "cliente"}. Adjunto mi voucher de pago.';
                            Clipboard.setData(ClipboardData(text: msg));
                            
                            const phoneNumber = "51905823660"; 
                            final url = Uri.parse("whatsapp://send?phone=$phoneNumber&text=${Uri.encodeComponent(msg)}");
                            try {
                              if (await canLaunchUrl(url)) {
                                await launchUrl(url);
                              } else {
                                final webUrl = Uri.parse("https://wa.me/$phoneNumber?text=${Uri.encodeComponent(msg)}");
                                await launchUrl(webUrl, mode: LaunchMode.externalApplication);
                              }
                            } catch (_) {}
                          },
                        ),
                      ],
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

  Widget _buildPaymentTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required String copyText,
    required BuildContext context,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF131A29),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold)),
                Text(subtitle, style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy, color: Color(0xFF00E5FF), size: 18),
            tooltip: 'Copiar dato',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: copyText));
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('¡Copiado: $copyText!'), duration: const Duration(seconds: 2)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceSyncStatus() {
    bool isPhoneLinked = true; 
    bool isTvLinked = false;   

    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildDeviceIcon(Icons.smartphone, isPhoneLinked),
          const SizedBox(width: 4),
          _buildDeviceIcon(Icons.tv, isTvLinked),
        ],
      ),
    );
  }

  Widget _buildDeviceIcon(IconData icon, bool isLinked) {
    return Stack(
      alignment: Alignment.topRight,
      children: [
        Padding(
          padding: const EdgeInsets.all(2.0),
          child: Icon(
            icon,
            size: 16,
            color: isLinked ? const Color(0xFF00E5FF) : Colors.white24,
          ),
        ),
        if (!isLinked)
          const Positioned(
            right: 0,
            top: 0,
            child: Icon(Icons.lock, size: 8, color: Colors.redAccent),
          ),
      ],
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
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () => _showPaymentOptionsModal(context, isHead: _canSeePaymentBanks), 
                    borderRadius: BorderRadius.circular(5),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: const Color(0xFF00E676), 
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.confirmation_number, color: Colors.black, size: 12),
                          SizedBox(width: 4),
                          Text(
                            'RENOVAR',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const Spacer(),
                  _buildDeviceSyncStatus(),
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
                              : _accentColor.withOpacity(0.5),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_userAvatarUrl != null && _userAvatarUrl!.isNotEmpty)
                            CircleAvatar(
                              radius: 8,
                              backgroundImage: NetworkImage(_userAvatarUrl!),
                            )
                          else
                            Icon(
                              _isJefeProfile ? Icons.shield : Icons.person,
                              color: _isJefeProfile ? Colors.amber : _accentColor,
                              size: 14,
                            ),
                          const SizedBox(width: 4),
                          Text(
                            _currentProfileName.toUpperCase(),
                            style: TextStyle(
                              color: _isJefeProfile ? Colors.amber : _accentColor,
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
          if (!_isSearching)
            IconButton(
              tooltip: 'Configuración',
              icon: const Icon(Icons.settings, color: Colors.white70),
              onPressed: _showSettingsMenu,
            ),
          if (!_isSearching)
            IconButton(
              tooltip: 'Buscar contenido',
              icon: const Icon(Icons.search, color: Colors.white),
              onPressed: () {
                setState(() => _isSearching = true);
              },
            ),
          if (_activeRemindersCount > 0)
            Stack(
              alignment: Alignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.notifications, color: Colors.amber),
                  onPressed: _openRemindersList,
                ),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      '$_activeRemindersCount',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ],
            )
          else
            IconButton(
              icon: const Icon(Icons.notifications_none, color: Colors.white),
              onPressed: _openRemindersList,
            ),
        ],
      ),
      body: _isLoadingChannels
          ? Center(
              child: CircularProgressIndicator(color: _accentColor))
          : Stack(
              children: [
                Column(
                  children: [
                    // TABS: LIVE | PELÍCULAS | SERIES
                    Container(
                      color: const Color(0xFF121226),
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _buildTabButton('En Vivo', 'live'),
                          _buildTabButton('Películas', 'movies'),
                          _buildTabButton('Series', 'series'),
                        ],
                      ),
                    ),

                    // CARRUSEL DINÁMICO DISNEY+: SEGUIR VIENDO (VOD)
                    if ((_activeTab == 'movies' || _activeTab == 'series') &&
                        _continueWatchingItems.isNotEmpty &&
                        !_isSearching)
                      ContinueWatchingCarousel(
                        items: _continueWatchingItems,
                        onItemTap: (historyItem) {
                          // Busca el PlaylistItem original o crea una instancia temporal para reanudar
                          final matched = _channels.firstWhere(
                            (c) => (c.url.isNotEmpty ? c.url : c.id) == historyItem.id,
                            orElse: () => PlaylistItem(
                              id: historyItem.id,
                              name: historyItem.title,
                              url: historyItem.streamUrl,
                              category: historyItem.category,
                              logo: historyItem.logoUrl,
                              isLive: false,
                            ),
                          );
                          _playChannel(matched, resumeAtSeconds: historyItem.positionSeconds);
                        },
                        onItemRemove: (historyItem) async {
                          await PlaybackHistoryService.removeProgress(_currentProfileId, historyItem.id);
                          _loadContinueWatching();
                        },
                      ),

                    // EPG DINÁMICO (Solo en Live)
                    _buildDynamicEPGBar(),

                    // FILTROS HORIZONTALES (Categorías con Control Parental)
                    if (categories.isNotEmpty)
                      Container(
                        height: 50,
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        margin: const EdgeInsets.only(top: 8),
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          children: categories.map((cat) {
                            final isSel = _selectedCategory == cat;
                            return Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: ChoiceChip(
                                label: Text(cat),
                                selected: isSel,
                                selectedColor: const Color(0xFF8B5CF6),
                                backgroundColor: const Color(0xFF1E1A38),
                                labelStyle: TextStyle(
                                  color: isSel ? Colors.white : Colors.white70,
                                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                                ),
                                onSelected: (val) {
                                  if (val) {
                                    _handleCategorySelection(cat);
                                  } else {
                                    setState(() => _selectedCategory = 'Todos');
                                  }
                                },
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    const SizedBox(height: 8),

                    // LISTA DE CANALES CON RENOMBRADO LOCAL
                    Expanded(
                      child: filteredChannels.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.tv_off, color: Colors.white30, size: 60),
                                  const SizedBox(height: 16),
                                  Text(
                                    _searchFilter.isEmpty
                                        ? 'No hay canales disponibles en esta categoría.'
                                        : 'No se encontraron resultados para "$_searchFilter".',
                                    style: const TextStyle(color: Colors.white54, fontSize: 16),
                                  ),
                                  if (_channels.isEmpty && _searchFilter.isEmpty) ...[
                                    const SizedBox(height: 24),
                                    ElevatedButton.icon(
                                      onPressed: _openPlaylistManagerDialog,
                                      icon: const Icon(Icons.playlist_add),
                                      label: const Text('Gestionar Listas M3U'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF8B5CF6),
                                      ),
                                    )
                                  ]
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                              itemCount: filteredChannels.length,
                              itemBuilder: (context, index) {
                                final channel = filteredChannels[index];
                                final channelKey = channel.url.isNotEmpty ? channel.url : channel.id;
                                final displayName = _customChannelAliases[channelKey] ?? channel.name;

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF1E1A38),
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: Colors.white10),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                    leading: Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF8B5CF6).withOpacity(0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Center(
                                        child: Text(
                                          '${index + 1}',
                                          style: const TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.bold,
                                              fontSize: 13),
                                        ),
                                      ),
                                    ),
                                    title: Text(
                                      displayName,
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15),
                                    ),
                                    subtitle: Text(
                                      'Grupo: ${channel.category.isEmpty ? "General" : channel.category} • 1080p FHD (Mantén presionado para renombrar)',
                                      style: const TextStyle(color: Colors.white54, fontSize: 11),
                                    ),
                                    trailing: const Icon(Icons.volume_up, color: Color(0xFF8B5CF6), size: 20),
                                    onTap: () => _playChannel(channel),
                                    onLongPress: () => _onChannelLongPress(channel),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
                _buildFloatingMiniPlayer(),
              ],
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openVoiceAssistant,
        backgroundColor: _accentColor,
        child: const Icon(Icons.mic, color: Colors.black, size: 28),
      ),
    );
  }

  Widget _buildTabButton(String title, String tabValue) {
    final isActive = _activeTab == tabValue;
    return GestureDetector(
      onTap: () {
        setState(() {
          _activeTab = tabValue;
          _selectedCategory = 'Todos';
        });
        _loadContinueWatching();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: isActive ? const Color(0xFFB388FF) : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Text(
          title,
          style: TextStyle(
            color: isActive ? const Color(0xFFB388FF) : Colors.white54,
            fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}
