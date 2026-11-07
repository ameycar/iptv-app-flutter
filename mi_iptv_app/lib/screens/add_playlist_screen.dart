import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/playlist_item.dart';
import '../models/playlist_model.dart';
import '../services/auth_service.dart';
import '../services/m3u_parser_service.dart';

class AddPlaylistScreen extends StatefulWidget {
  final String? profileId;

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
  final _epgController = TextEditingController(); 
  
  bool _usePublicEpg = true; 
  bool _isLoading = false;
  String? _errorMessage;
  int _currentPlaylistCount = 0;
  
  static const int maxPlaylistsPerProfile = 6;

  // Variables para la Fase 6: Vinculación Express
  String _pairingCode = '----';
  StreamSubscription<DocumentSnapshot>? _pairingSubscription;
  bool _isPairingSuccess = false;

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
    _initTvPairingCode(); // Inicializamos el escucha de Firebase
  }

  @override
  void dispose() {
    _pairingSubscription?.cancel();
    _nameController.dispose();
    _urlController.dispose();
    _epgController.dispose();
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

  // LÓGICA FASE 6: GENERADOR Y ESCUCHA DEL CÓDIGO EXPRESS
  void _initTvPairingCode() {
    // Solo generamos código si hay Firebase disponible
    if (!AuthService.isFirebaseAvailable) return;

    // Generar 4 dígitos aleatorios
    final code = (Random().nextInt(9000) + 1000).toString();
    setState(() => _pairingCode = code);

    final docRef = FirebaseFirestore.instance.collection('tv_pairing').doc(code);

    // Creamos el documento en Firebase esperando la URL
    docRef.set({
      'status': 'waiting',
      'createdAt': FieldValue.serverTimestamp(),
      'm3uUrl': '',
      'epgUrl': '',
      'playlistName': '',
    });

    // Escuchamos cambios en tiempo real
    _pairingSubscription = docRef.snapshots().listen((snap) {
      if (!snap.exists) return;
      final data = snap.data()!;

      if (data['status'] == 'linked' && data['m3uUrl'].toString().isNotEmpty) {
        // ¡El celular envió la URL!
        _pairingSubscription?.cancel(); // Dejamos de escuchar
        if (mounted) {
          setState(() {
            _isPairingSuccess = true; // Cambiamos la UI a éxito
            _urlController.text = data['m3uUrl'];
            if (data['epgUrl'] != null) _epgController.text = data['epgUrl'];
            if (data['playlistName'] != null) _nameController.text = data['playlistName'];
          });
          
          // Disparamos la carga automáticamente
          _processPlaylist();
        }
      }
    });
  }

  Future<void> _processPlaylist() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    final epgUrl = _epgController.text.trim();

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
      List<PlaylistItem> items = await M3UParserService.fetchAndParseM3U(url);

      if (items.isEmpty) {
        throw Exception('La lista no contiene canales válidos o accesibles.');
      }

      final playlistId = 'pl_${DateTime.now().millisecondsSinceEpoch}';
      final finalName = name.isNotEmpty
          ? name
          : 'Lista ${_currentPlaylistCount + 1} (${items.length} canales)';

      final newPlaylist = PlaylistModel(
        id: playlistId,
        name: finalName,
        url: url,
        channelCount: items.length,
        isActive: true,
        profileId: _effectiveProfileId,
      );

      final playlistMap = newPlaylist.toMap();
      if (epgUrl.isNotEmpty) {
        playlistMap['epgUrl'] = epgUrl;
      }
      playlistMap['usePublicEpg'] = _usePublicEpg;

      final prefs = await SharedPreferences.getInstance();
      final listKey = 'saved_playlists_$_effectiveProfileId';

      List> existingPlaylists = [];
      final raw = prefs.getString(listKey);
      if (raw != null && raw.isNotEmpty) {
        final List list = jsonDecode(raw);
        existingPlaylists = list.map((m) => Map<String, dynamic>.from(m)).toList();
      }

      for (var p in existingPlaylists) {
        p['isActive'] = false;
      }
      existingPlaylists.add(playlistMap);

      await prefs.setString(listKey, jsonEncode(existingPlaylists));

      final channelsKey = 'channels_${_effectiveProfileId}_$playlistId';
      final encodedChannels = jsonEncode(items.map((i) => i.toMap()).toList());
      await prefs.setString(channelsKey, encodedChannels);
      await prefs.setString('active_channels_$_effectiveProfileId', encodedChannels);
      await prefs.setString('active_playlist_id_$_effectiveProfileId', playlistId);

      if (AuthService.isFirebaseAvailable && AuthService.currentUser != null) {
        try {
          await FirebaseFirestore.instance
              .collection('users')
              .doc(AuthService.currentUser!.id)
              .collection('profiles')
              .doc(_effectiveProfileId)
              .collection('playlists')
              .doc(playlistId)
              .set(playlistMap);
        } catch (cloudError) {
          debugPrint('Aviso: No se pudo respaldar en la nube: $cloudError');
        }
      }

      // Si fue por vinculación Express, borramos el documento temporal por seguridad
      if (_isPairingSuccess && AuthService.isFirebaseAvailable) {
        FirebaseFirestore.instance.collection('tv_pairing').doc(_pairingCode).delete();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '¡Lista guardada y sanitizada con éxito (${items.length} canales)!',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
          ),
        );

        Navigator.pop(context, {
          'playlist': PlaylistModel.fromMap(playlistMap),
          'channels': items,
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPairingSuccess = false; // Reiniciamos si falló
          _errorMessage = 'Error al procesar la lista. Verifica la URL y tu conexión a internet.';
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
    final size = MediaQuery.of(context).size;
    final bool isTvMode = size.width >= 900 && size.aspectRatio > 1.2;

    return Scaffold(
      backgroundColor: const Color(0xFF0C0C18),
      appBar: isTvMode 
          ? null 
          : AppBar(
              title: const Text('Gestor de Listas', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: const Color(0xFF121226),
              elevation: 0,
            ),
      body: isTvMode ? _buildTvLayout() : _buildMobileLayout(),
    );
  }

  // ===========================================================================
  // LAYOUT ORIGINAL PARA MÓVILES (INTACTO)
  // ===========================================================================
  Widget _buildMobileLayout() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 500),
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF16162D),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: const Color(0xFF8B5CF6).withOpacity(0.5), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF8B5CF6).withOpacity(0.15),
                blurRadius: 20,
                spreadRadius: 2,
              )
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Row(
                children: [
                  Icon(Icons.wifi_tethering, color: Color(0xFF00E5FF), size: 30),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Gestor de 6 Listas M3U y Guía EPG',
                      style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text('Nombre de la lista (Opcional):', style: TextStyle(color: Color(0xFFB388FF), fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildTextField(_nameController, 'Ej: Mi Lista VIP'),
              const SizedBox(height: 16),
              const Text('1. Enlace de Lista de Canales (M3U / M3U8):', style: TextStyle(color: Color(0xFFB388FF), fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildTextField(_urlController, 'https://...'),
              const SizedBox(height: 16),
              const Text('2. Enlace Guía EPG Privada (XMLTV .xml o .xml.gz - Opcional):', style: TextStyle(color: Color(0xFFB388FF), fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              _buildTextField(_epgController, 'https://proveedor.com/xmltv.xml.gz'),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1A38),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.white10),
                ),
                child: const Column(
                  children: [
                    Row(
                      children: [
                        Icon(Icons.radar, color: Colors.amber, size: 16),
                        SizedBox(width: 8),
                        Expanded(child: Text('Auto-detección M3U: Habilitada (epg.kanya.io)', style: TextStyle(color: Colors.white70, fontSize: 11))),
                      ],
                    ),
                    SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.memory, color: Color(0xFF00E5FF), size: 16),
                        SizedBox(width: 8),
                        Expanded(child: Text('Buscador EPG Activo (Modo Turbo Zapping)', style: TextStyle(color: Color(0xFF00E5FF), fontSize: 11, fontWeight: FontWeight.bold))),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Conector Satelital Público por Defecto', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                        SizedBox(height: 2),
                        Text('Descarga guías XMLTV oficiales en caché', style: TextStyle(color: Colors.white54, fontSize: 11)),
                      ],
                    ),
                  ),
                  Switch(
                    value: _usePublicEpg,
                    activeColor: const Color(0xFF00E5FF),
                    onChanged: (val) => setState(() => _usePublicEpg = val),
                  ),
                ],
              ),
              if (_errorMessage != null) ...[
                const SizedBox(height: 16),
                Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent, fontSize: 13)),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar', style: TextStyle(color: Colors.white54)),
                  ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _isLoading ? null : _processPlaylist,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF8B5CF6),
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    child: _isLoading
                        ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Text('Cargar y Sanitizar', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                  ),
                ],
              )
            ],
          ),
        ),
      ),
    );
  }

  // ===========================================================================
  // LAYOUT NUEVO PARA SMART TV (LEANBACK)
  // ===========================================================================
  Widget _buildTvLayout() {
    return SafeArea(
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: Row(
          children: [
            // COLUMNA IZQUIERDA: FASE 6 - VINCULACIÓN EXPRESS
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.all(40),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [Color(0xFF16162D), Color(0xFF0C0C18)],
                  ),
                  border: Border(right: BorderSide(color: Colors.white.withOpacity(0.05))),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    if (_isPairingSuccess) ...[
                      // ESTADO DE ÉXITO AUTOMÁTICO
                      Container(
                        padding: const EdgeInsets.all(30),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withOpacity(0.1),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_circle, color: Color(0xFF10B981), size: 100),
                      ),
                      const SizedBox(height: 24),
                      const Text(
                        '¡Enlace Recibido!',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Procesando canales automáticamente...',
                        style: TextStyle(color: Color(0xFF10B981), fontSize: 18),
                      ),
                    ] else ...[
                      // ESTADO DE ESPERA DEL CÓDIGO
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        // Simulador de Código QR nativo de alta visibilidad
                        child: const Icon(Icons.qr_code_2_rounded, color: Colors.black, size: 160),
                      ),
                      const SizedBox(height: 32),
                      const Text(
                        'Vinculación Express',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Evita usar el teclado de la TV. Desde tu celular ingresa a:\nameycar.tv/link',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white60, fontSize: 16, height: 1.4),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00E5FF).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: const Color(0xFF00E5FF).withOpacity(0.5)),
                        ),
                        child: Column(
                          children: [
                            const Text('E INGRESA ESTE CÓDIGO:', style: TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold, letterSpacing: 1)),
                            const SizedBox(height: 4),
                            Text(
                              _pairingCode,
                              style: const TextStyle(color: Color(0xFF00E5FF), fontSize: 42, fontWeight: FontWeight.w900, letterSpacing: 10),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),

            // COLUMNA DERECHA: FASE 5 (Ingreso Manual con Teclado de TV)
            Expanded(
              flex: 4,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Center(
                  child: SingleChildScrollView(
                    physics: const BouncingScrollPhysics(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'Ingreso Manual',
                          style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'También puedes pegar tu enlace M3U aquí',
                          style: TextStyle(color: Colors.white54, fontSize: 14),
                        ),
                        const SizedBox(height: 32),

                        const Text('Nombre de la lista (Opcional)', style: TextStyle(color: Color(0xFFB388FF), fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        _buildTvTextField(
                          controller: _nameController, 
                          hint: 'Ej: Lista Familiar TV',
                          icon: Icons.label_outline,
                          autofocus: true,
                        ),
                        
                        const SizedBox(height: 20),
                        
                        const Text('URL de la Lista M3U (Requerido)', style: TextStyle(color: Color(0xFFB388FF), fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        _buildTvTextField(
                          controller: _urlController, 
                          hint: 'http://...',
                          icon: Icons.link,
                          textInputAction: TextInputAction.next,
                        ),
                        
                        const SizedBox(height: 20),
                        
                        const Text('URL de Guía EPG XMLTV (Opcional)', style: TextStyle(color: Color(0xFFB388FF), fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        _buildTvTextField(
                          controller: _epgController, 
                          hint: 'http://...',
                          icon: Icons.calendar_month,
                          textInputAction: TextInputAction.done,
                        ),

                        if (_errorMessage != null) ...[
                          const SizedBox(height: 20),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.redAccent.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                            ),
                            child: Row(
                              children: [
                                const Icon(Icons.error_outline, color: Colors.redAccent),
                                const SizedBox(width: 8),
                                Expanded(child: Text(_errorMessage!, style: const TextStyle(color: Colors.redAccent))),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 32),

                        Row(
                          children: [
                            Expanded(
                              child: _buildTvActionBtn(
                                text: 'Volver',
                                isPrimary: false,
                                onTap: () => Navigator.pop(context),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              flex: 2,
                              child: _buildTvActionBtn(
                                text: _isLoading ? 'Procesando...' : 'Cargar M3U',
                                isPrimary: true,
                                icon: _isLoading ? null : Icons.cloud_download,
                                isLoading: _isLoading,
                                onTap: _isLoading ? () {} : _processPlaylist,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField(TextEditingController controller, String hint) {
    return TextField(
      controller: controller,
      style: const TextStyle(color: Colors.white),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30),
        filled: true,
        fillColor: const Color(0xFF1E1A38), 
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white24)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Colors.white10)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: Color(0xFF8B5CF6))),
      ),
    );
  }

  Widget _buildTvTextField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool autofocus = false,
    TextInputAction textInputAction = TextInputAction.next,
  }) {
    return Focus(
      autofocus: autofocus,
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: hasFocus ? const Color(0xFF1E293B) : const Color(0xFF131B2E),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: hasFocus ? const Color(0xFF00E5FF) : Colors.white12, width: hasFocus ? 2 : 1),
              boxShadow: hasFocus ? [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.3), blurRadius: 15)] : [],
            ),
            child: TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              textInputAction: textInputAction,
              decoration: InputDecoration(
                prefixIcon: Icon(icon, color: hasFocus ? const Color(0xFF00E5FF) : Colors.white38),
                hintText: hint,
                hintStyle: const TextStyle(color: Colors.white24),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              ),
              onSubmitted: (_) {
                if (textInputAction == TextInputAction.next) {
                  FocusScope.of(context).nextFocus();
                } else if (textInputAction == TextInputAction.done) {
                  _processPlaylist();
                }
              },
            ),
          );
        }
      ),
    );
  }

  Widget _buildTvActionBtn({
    required String text,
    required bool isPrimary,
    required VoidCallback onTap,
    IconData? icon,
    bool isLoading = false,
  }) {
    return Builder(builder: (context) {
      return Focus(
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
              padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: hasFocus
                    ? (isPrimary ? const Color(0xFF00E5FF) : Colors.white24)
                    : (isPrimary ? const Color(0xFF8B5CF6) : Colors.transparent),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hasFocus ? Colors.white : (isPrimary ? Colors.transparent : Colors.white24),
                  width: hasFocus ? 2 : 1,
                ),
                boxShadow: (hasFocus && isPrimary) ? [BoxShadow(color: const Color(0xFF00E5FF).withOpacity(0.5), blurRadius: 15)] : [],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isLoading)
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                  else if (icon != null)
                    Icon(icon, color: hasFocus ? Colors.black : Colors.white, size: 20),
                  if (isLoading || icon != null) const SizedBox(width: 8),
                  Text(
                    text,
                    style: TextStyle(
                      color: hasFocus ? (isPrimary ? Colors.black : Colors.white) : (isPrimary ? Colors.white : Colors.white60),
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      );
    });
  }
}