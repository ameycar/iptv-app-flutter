import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../models/playlist_item.dart';
import '../models/playlist_model.dart';
import '../services/auth_service.dart';
import '../services/m3u_parser_service.dart';

class AddPlaylistScreen extends StatefulWidget {
  final String? profileId; // ID opcional si se pasa desde el gestor

  const AddPlaylistScreen({
    super.key,
    this.profileId,
  });

  @override
  State<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends State<AddPlaylistScreen> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _isLoading = false;
  String? _errorMessage;
  int _currentPlaylistCount = 0;
  static const int maxPlaylistsPerProfile = 5;

  String get _effectiveProfileId {
    if (widget.profileId != null && widget.profileId!.isNotEmpty) {
      return widget.profileId!;
    }
    return AuthService.currentActiveProfile?.id ??
        AuthService.currentUser?.id ??
        'perfil_principal';
  }

  @override
  void initState() {
    super.initState();
    _checkPlaylistLimit();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _checkPlaylistLimit() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'saved_playlists_$_effectiveProfileId';
      final raw = prefs.getString(key);
      if (raw != null && raw.isNotEmpty) {
        final List list = jsonDecode(raw);
        setState(() {
          _currentPlaylistCount = list.length;
        });
      }
    } catch (_) {}
  }

  Future<void> _processPlaylist() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();

    if (url.isEmpty) {
      setState(() => _errorMessage = 'Por favor ingresa la URL de la lista M3U.');
      return;
    }

    if (_currentPlaylistCount >= maxPlaylistsPerProfile) {
      setState(() => _errorMessage =
          'Límite alcanzado: Este perfil ya tiene $maxPlaylistsPerProfile listas M3U registradas.');
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 1. Descargar y parsear con IA / Sanitizador
      List<PlaylistItem> items = await M3UParserService.fetchAndParseM3U(url);

      if (items.isEmpty) {
        throw Exception('La lista no contiene canales válidos o accesibles.');
      }

      // 2. Crear modelo de lista asociado ÚNICAMENTE al perfil activo
      final playlistId = 'pl_${DateTime.now().millisecondsSinceEpoch}';
      final finalName = name.isNotEmpty
          ? name
          : 'Lista ${_currentPlaylistCount + 1} (${items.length} canales)';

      final newPlaylist = PlaylistModel(
        id: playlistId,
        name: finalName,
        url: url,
        channelCount: items.length,
        isActive: true, // Se activa automáticamente la recién creada
        profileId: _effectiveProfileId,
      );

      // 3. Guardar en SharedPreferences de forma AISLADA por perfil
      final prefs = await SharedPreferences.getInstance();
      final listKey = 'saved_playlists_$_effectiveProfileId';

      List<PlaylistModel> existingPlaylists = [];
      final raw = prefs.getString(listKey);
      if (raw != null && raw.isNotEmpty) {
        try {
          final List list = jsonDecode(raw);
          existingPlaylists = list.map((m) => PlaylistModel.fromMap(m)).toList();
        } catch (_) {}
      }

      // Desactivar las anteriores para activar la nueva
      existingPlaylists = existingPlaylists
          .map((p) => p.copyWith(isActive: false))
          .toList();

      existingPlaylists.add(newPlaylist);

      // Guardar metadatos de las listas del perfil
      await prefs.setString(
        listKey,
        jsonEncode(existingPlaylists.map((p) => p.toMap()).toList()),
      );

      // Guardar canales con clave aislada del perfil
      final channelsKey = 'channels_${_effectiveProfileId}_$playlistId';
      final encodedChannels = jsonEncode(items.map((i) => i.toMap()).toList());
      await prefs.setString(channelsKey, encodedChannels);

      // Guardar como canales activos actuales para este perfil
      await prefs.setString('active_channels_$_effectiveProfileId', encodedChannels);
      await prefs.setString('active_playlist_id_$_effectiveProfileId', playlistId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '¡Lista "$finalName" guardada con éxito (${items.length} canales)!',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
          ),
        );

        // Retornamos el mapa con la playlist y los canales
        Navigator.pop(context, {
          'playlist': newPlaylist,
          'channels': items,
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage =
              'Error al cargar o procesar la lista M3U. Verifica la URL e inténtalo nuevamente.';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeProfileName = AuthService.currentActiveProfile?.username ??
        AuthService.currentUser?.username ??
        'Mi Perfil';

    return Scaffold(
      backgroundColor: const Color(0xFF101726),
      appBar: AppBar(
        title: const Text(
          'Nueva Lista M3U',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: const Color(0xFF161F36),
        elevation: 0,
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.amber.withOpacity(0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person, size: 14, color: Colors.amber),
                const SizedBox(width: 4),
                Text(
                  activeProfileName.toUpperCase(),
                  style: const TextStyle(
                    color: Colors.amber,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 10),
            // Badge informativo del aislamiento por perfil
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF1E293B),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF334155)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.folder_shared, color: Colors.cyanAccent, size: 24),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Aislamiento Privado: Perfil "$activeProfileName"',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Esta lista pertenecerá solo a este perfil ($currentCountLabel).',
                          style: const TextStyle(color: Colors.white70, fontSize: 11),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),

            const Center(
              child: Icon(Icons.psychology_outlined, size: 64, color: Color(0xFF8B5CF6)),
            ),
            const SizedBox(height: 12),
            const Text(
              'Ingresa tu lista M3U',
              style: TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            const Text(
              'Nuestro motor de IA limpiará los nombres de los canales y ordenará las categorías automáticamente.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 26),

            // 1. Campo para Nombre de la lista
            const Text(
              'Nombre de la lista (opcional):',
              style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _nameController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Ej: Deportes HD, Películas, Canales VIP...',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                prefixIcon: const Icon(Icons.label_outline, color: Color(0xFF8B5CF6)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 18),

            // 2. Campo para URL M3U
            const Text(
              'URL del enlace M3U / M3U8:',
              style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'https://ejemplo.com/lista.m3u',
                hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
                filled: true,
                fillColor: const Color(0xFF1E293B),
                prefixIcon: const Icon(Icons.link, color: Color(0xFF8B5CF6)),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),

            if (_errorMessage != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.redAccent.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.redAccent.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: Colors.redAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: 28),

            // Botón Procesar y Guardar
            ElevatedButton(
              onPressed: _isLoading ? null : _processPlaylist,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF8B5CF6),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 4,
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 22,
                      width: 22,
                      child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                    )
                  : const Text(
                      'Procesar, Sanitizar y Guardar',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  String get currentCountLabel =>
      '$_currentPlaylistCount de $maxPlaylistsPerProfile listas en uso';
}