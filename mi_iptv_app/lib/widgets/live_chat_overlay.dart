import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';

// Clase para animar los emojis flotantes
class FloatingEmoji {
  final String id;
  final String emoji;
  final double startX;
  
  FloatingEmoji({required this.id, required this.emoji, required this.startX});
}

class LiveChatOverlay extends StatefulWidget {
  final String channelId; 
  final String channelName;

  const LiveChatOverlay({
    super.key,
    required this.channelId,
    required this.channelName,
  });

  @override
  State<LiveChatOverlay> createState() => _LiveChatOverlayState();
}

class _LiveChatOverlayState extends State<LiveChatOverlay> with TickerProviderStateMixin {
  final TextEditingController _chatController = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  
  // Lista para manejar los emojis que están volando en pantalla
  final List<FloatingEmoji> _activeEmojis = [];
  final Random _random = Random();

  String get _currentUsername => AuthService.currentUser?.username ?? 'Espectador';
  bool get _isVip => AuthService.currentUser?.isVip ?? false;

  void _sendMessage() async {
    final text = _chatController.text.trim();
    if (text.isEmpty) return;
    
    _chatController.clear();
    _focusNode.unfocus();

    if (AuthService.isFirebaseAvailable) {
      try {
        await FirebaseFirestore.instance
            .collection('live_chats')
            .doc(widget.channelId)
            .collection('messages')
            .add({
          'text': text,
          'sender': _currentUsername,
          'isVip': _isVip,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Error enviando mensaje: $e');
      }
    }
  }

  void _sendReaction(String emoji) {
    // 1. Mostrar el emoji flotando localmente al instante
    final newEmoji = FloatingEmoji(
      id: DateTime.now().millisecondsSinceEpoch.toString() + _random.nextInt(1000).toString(),
      emoji: emoji,
      startX: 0.6 + (_random.nextDouble() * 0.3), // Aparece aleatoriamente en el 30% derecho de la pantalla
    );
    
    setState(() {
      _activeEmojis.add(newEmoji);
    });

    // Remover el emoji después de 2.5 segundos (lo que dura la animación)
    Future.delayed(const Duration(milliseconds: 2500), () {
      if (mounted) {
        setState(() {
          _activeEmojis.removeWhere((e) => e.id == newEmoji.id);
        });
      }
    });

    // 2. Enviar la reacción a Firebase para que los demás la vean (Opcional para no saturar BD, 
    // pero ideal para el modo "Estadio Virtual" si usamos Realtime Database luego).
  }

  @override
  void dispose() {
    _chatController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // ZONA DE CHAT (Lado izquierdo/inferior)
        Positioned(
          left: 16,
          bottom: 80,
          width: MediaQuery.of(context).size.width * 0.6,
          height: 200,
          child: ShaderMask(
            shaderCallback: (Rect bounds) {
              return const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black],
                stops: [0.0, 0.2],
              ).createShader(bounds);
            },
            blendMode: BlendMode.dstIn,
            child: AuthService.isFirebaseAvailable 
              ? StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('live_chats')
                      .doc(widget.channelId)
                      .collection('messages')
                      .orderBy('timestamp', descending: true)
                      .limit(20)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) return const SizedBox.shrink();
                    final docs = snapshot.data!.docs;
                    
                    return ListView.builder(
                      reverse: true,
                      itemCount: docs.length,
                      itemBuilder: (context, index) {
                        final data = docs[index].data() as Map<String, dynamic>;
                        final sender = data['sender'] ?? 'Usuario';
                        final text = data['text'] ?? '';
                        final isVipMsg = data['isVip'] ?? false;

                        return Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (isVipMsg)
                                const Padding(
                                  padding: EdgeInsets.only(right: 4, top: 2),
                                  child: Icon(Icons.stars, color: Color(0xFFFFD600), size: 12),
                                ),
                              Expanded(
                                child: RichText(
                                  text: TextSpan(
                                    children: [
                                      TextSpan(
                                        text: '$sender: ',
                                        style: TextStyle(
                                          color: isVipMsg ? const Color(0xFFFFD600) : const Color(0xFF00E5FF),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          shadows: const [Shadow(color: Colors.black, blurRadius: 2)],
                                        ),
                                      ),
                                      TextSpan(
                                        text: text,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          shadows: [Shadow(color: Colors.black, blurRadius: 2)],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                )
              : const Center(child: Text('Chat offline', style: TextStyle(color: Colors.white54))),
          ),
        ),

        // CAPA DE EMOJIS FLOTANTES (Animaciones)
        ..._activeEmojis.map((emojiData) {
          return TweenAnimationBuilder<double>(
            key: ValueKey(emojiData.id),
            tween: Tween(begin: 1.0, end: 0.0),
            duration: const Duration(milliseconds: 2500),
            builder: (context, value, child) {
              // value va de 1.0 a 0.0
              final screenHeight = MediaQuery.of(context).size.height;
              final screenWidth = MediaQuery.of(context).size.width;
              
              return Positioned(
                left: screenWidth * emojiData.startX,
                bottom: 80 + (screenHeight * 0.5 * (1 - value)), // Sube por la pantalla
                child: Opacity(
                  opacity: value, // Se desvanece al subir
                  child: Transform.scale(
                    scale: 1.0 + (1 - value), // Se hace un poco más grande
                    child: Text(emojiData.emoji, style: const TextStyle(fontSize: 28)),
                  ),
                ),
              );
            },
          );
        }).toList(),

        // BARRA DE INPUT Y REACCIONES (Inferior)
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Row(
            children: [
              // Caja de texto Glassmorphism
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _chatController,
                          focusNode: _focusNode,
                          style: const TextStyle(color: Colors.white, fontSize: 13),
                          decoration: const InputDecoration(
                            hintText: 'Chatear en vivo...',
                            hintStyle: TextStyle(color: Colors.white54),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                          onSubmitted: (_) => _sendMessage(),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.send, color: Color(0xFF00E5FF), size: 18),
                        onPressed: _sendMessage,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Botones de Reacción Rápida
              _buildReactionButton('🔥'),
              _buildReactionButton('⚽'),
              _buildReactionButton('😱'),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildReactionButton(String emoji) {
    return GestureDetector(
      onTap: () => _sendReaction(emoji),
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.4),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 18)),
      ),
    );
  }
}