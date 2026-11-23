import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/auth_service.dart';
import '../services/parental_service.dart';

class FloatingEmoji {
  final String id;
  final String emoji;
  final double startX;

  FloatingEmoji({
    required this.id,
    required this.emoji,
    required this.startX,
  });
}

class _LiveChatMsg {
  final String id;
  final String sender;
  final String text;
  final bool isVip;
  final int createdAtMs;

  const _LiveChatMsg({
    required this.id,
    required this.sender,
    required this.text,
    required this.isVip,
    required this.createdAtMs,
  });
}

class LiveChatOverlay extends StatefulWidget {
  final String channelId;
  final String channelName;
  final bool isTvMode;
  final VoidCallback? onClose;

  const LiveChatOverlay({
    super.key,
    required this.channelId,
    required this.channelName,
    this.isTvMode = false,
    this.onClose,
  });

  @override
  State<LiveChatOverlay> createState() => _LiveChatOverlayState();
}

class _LiveChatOverlayState extends State<LiveChatOverlay> {
  final TextEditingController _chatController = TextEditingController();
  final FocusNode _inputFocusNode = FocusNode();
  final FocusScopeNode _tvChatScopeNode = FocusScopeNode();
  final Random _random = Random();

  final List<FloatingEmoji> _activeEmojis = [];
  final List<_LiveChatMsg> _optimisticMessages = [];
  final Set<String> _recentSenders = {};

 StreamSubscription? _messagesSub;
  List<_LiveChatMsg> _serverMessages = [];

  bool _isFeedAwake = true;
  Timer? _fadeTimer;
  DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _moderationNotice = '';
  Timer? _noticeTimer;

  static const List<String> _tvQuickPhrases = [
    '⚽ ¡GOLAZO!',
    '🔥 ¡Buenazo!',
    '😂 Jajaja',
    '👏 ¡Bravo!',
    '😱 ¡Increíble!',
  ];

  static const List<String> _quickEmojis = ['🔥', '⚽', '😂', '👏', '😱', '❤️'];

  String get _currentUsername =>
      AuthService.currentActiveProfile?.deviceName ??
      AuthService.currentUser?.username ??
      'Espectador';

  bool get _isVip => AuthService.currentUser?.isVip ?? false;

  String get _safeDocId {
    final cleaned = widget.channelId
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    return cleaned.isEmpty ? 'canal_general' : cleaned;
  }

  @override
  void initState() {
    super.initState();
    ParentalService.getProfanityFilterEnabled();
    ParentalService.getHiddenMenuItems();
    _subscribeToChannelChat();
    _wakeUpFeed();

    if (widget.isTvMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          FocusScope.of(context).requestFocus(_tvChatScopeNode);
          _tvChatScopeNode.nextFocus();
        }
      });
    }
  }

  @override
  void didUpdateWidget(LiveChatOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId) {
      _optimisticMessages.clear();
      _serverMessages = [];
      _recentSenders.clear();
      _subscribeToChannelChat();
      _wakeUpFeed();
    }
  }

  void _subscribeToChannelChat() {
    _messagesSub?.cancel();
    if (!AuthService.isFirebaseAvailable) return;

    _messagesSub = FirebaseFirestore.instance
        .collection('live_chats')
        .doc(_safeDocId)
        .collection('messages')
        .orderBy('createdAtMs', descending: true)
        .limit(40)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted) return;
        final List<_LiveChatMsg> parsed = [];
        final Set<String> senders = {};

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final sender = (data['sender'] ?? 'Usuario').toString();
          final text = (data['text'] ?? '').toString();
          if (text.trim().isEmpty) continue;
          final isVipMsg = data['isVip'] == true;
          final createdAtMs = (data['createdAtMs'] is int)
              ? data['createdAtMs'] as int
              : DateTime.now().millisecondsSinceEpoch;

          senders.add(sender);
          parsed.add(_LiveChatMsg(
            id: (data['clientMsgId'] ?? doc.id).toString(),
            sender: sender,
            text: text,
            isVip: isVipMsg,
            createdAtMs: createdAtMs,
          ));
        }

        // Limpiar mensajes locales que ya llegaron confirmados desde Firestore
        final serverIds = parsed.map((m) => m.id).toSet();
        _optimisticMessages.removeWhere((m) => serverIds.contains(m.id));

        setState(() {
          _serverMessages = parsed;
          _recentSenders
            ..clear()
            ..addAll(senders);
        });

        if (parsed.isNotEmpty) {
          _wakeUpFeed();
        }
      },
      onError: (e) {
        debugPrint('Aviso stream chat en vivo: $e');
      },
    );
  }

  void _wakeUpFeed() {
    if (!_isFeedAwake && mounted) {
      setState(() => _isFeedAwake = true);
    }
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(seconds: 12), () {
      if (mounted && !_inputFocusNode.hasFocus) {
        setState(() => _isFeedAwake = false);
      }
    });
  }

  void _showModerationNotice(String msg) {
    _noticeTimer?.cancel();
    if (mounted) {
      setState(() => _moderationNotice = msg);
    }
    _noticeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _moderationNotice = '');
      }
    });
  }

  Future<void> _sendMessage([String? presetText]) async {
    final rawText = (presetText ?? _chatController.text).trim();
    if (rawText.isEmpty) return;

    // Anti-spam para salas con mucho tráfico (1.2s entre mensajes)
    final now = DateTime.now();
    if (now.difference(_lastSendTime).inMilliseconds < 1200) {
      _showModerationNotice('⏳ Espera un momento antes de enviar otro mensaje.');
      return;
    }
    _lastSendTime = now;

    String textToSend = rawText;
    if (textToSend.length > 160) {
      textToSend = textToSend.substring(0, 160);
    }

    // Control de groserías y palabras obscenas
    final bool filterActive = ParentalService.isProfanityFilterEnabledSync();
    if (ParentalService.containsProfanity(textToSend)) {
      if (filterActive) {
        textToSend = ParentalService.sanitizeMessage(textToSend);
        _showModerationNotice(
            '🛡️ Palabras filtradas por Control Parental.');
      }
    }

    if (presetText == null) {
      _chatController.clear();
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clientMsgId = '${nowMs}_${_random.nextInt(999999)}';

    // Inserción inmediata en memoria local (0 ms, nunca desaparece)
    setState(() {
      _optimisticMessages.insert(
        0,
        _LiveChatMsg(
          id: clientMsgId,
          sender: _currentUsername,
          text: textToSend,
          isVip: _isVip,
          createdAtMs: nowMs,
        ),
      );
      if (_optimisticMessages.length > 15) {
        _optimisticMessages.removeLast();
      }
    });
    _wakeUpFeed();

    if (AuthService.isFirebaseAvailable) {
      try {
        await FirebaseFirestore.instance
            .collection('live_chats')
            .doc(_safeDocId)
            .collection('messages')
            .add({
          'clientMsgId': clientMsgId,
          'text': textToSend,
          'sender': _currentUsername,
          'isVip': _isVip,
          'createdAtMs': nowMs,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Error enviando mensaje al chat en vivo: $e');
      }
    }
  }

  void _sendReaction(String emoji) {
    _wakeUpFeed();
    final newEmoji = FloatingEmoji(
      id: '${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(9999)}',
      emoji: emoji,
      startX: widget.isTvMode
          ? 0.72 + (_random.nextDouble() * 0.20)
          : 0.65 + (_random.nextDouble() * 0.25),
    );

    setState(() {
      _activeEmojis.add(newEmoji);
      if (_activeEmojis.length > 14) {
        _activeEmojis.removeAt(0);
      }
    });

    Future.delayed(const Duration(milliseconds: 2400), () {
      if (mounted) {
        setState(() {
          _activeEmojis.removeWhere((e) => e.id == newEmoji.id);
        });
      }
    });
  }

  Color _senderColor(String sender, bool isVip) {
    if (isVip) return const Color(0xFFFFD600);
    const palette = [
      Color(0xFF00E5FF),
      Color(0xFFC77DFF),
      Color(0xFF69F0AE),
      Color(0xFFFFAB40),
      Color(0xFFFF80AB),
      Color(0xFF80D8FF),
    ];
    return palette[sender.hashCode.abs() % palette.length];
  }

  List<_LiveChatMsg> get _mergedMessages {
    final map = <String, _LiveChatMsg>{};
    for (final m in _serverMessages) {
      map[m.id] = m;
    }
    for (final m in _optimisticMessages) {
      map.putIfAbsent(m.id, () => m);
    }
    final list = map.values.toList()
      ..sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
    return list.length > 45 ? list.sublist(0, 45) : list;
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    _fadeTimer?.cancel();
    _noticeTimer?.cancel();
    _chatController.dispose();
    _inputFocusNode.dispose();
    _tvChatScopeNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: ParentalService.hiddenItemsNotifier,
      builder: (context, hiddenItems, _) {
        if (hiddenItems.contains('chat')) {
          return const SizedBox.shrink();
        }

        return ValueListenableBuilder<bool>(
          valueListenable: ParentalService.profanityFilterNotifier,
          builder: (context, profanityFilterOn, __) {
            return RepaintBoundary(
              child: widget.isTvMode
                  ? _buildTvChatLayout(profanityFilterOn)
                  : _buildMobileLiveChatLayout(profanityFilterOn),
            );
          },
        );
      },
    );
  }

  /// Diseño Smartphone / Tablet: Estilo TikTok / Instagram Live (mensajes suben y se difuminan arriba)
  Widget _buildMobileLiveChatLayout(bool profanityFilterOn) {
    final messages = _mergedMessages;
    final onlineCount = max(1, _recentSenders.length);

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: _wakeUpFeed,
      child: Stack(
        children: [
          // Capa de emojis flotantes
          ..._buildFloatingEmojisLayer(),

          // Feed ascendente de mensajes (izquierda / abajo, sobre la barra de entrada)
          Positioned(
            left: 10,
            right: 72,
            bottom: 58,
            top: 34,
            child: Align(
              alignment: Alignment.bottomLeft,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 500),
                opacity: _isFeedAwake ? 1.0 : 0.35,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Cabecera compacta de sala en vivo
                    Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.55),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: const Color(0xFF00E5FF).withOpacity(0.4)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.circle,
                              color: Color(0xFFFF1744), size: 7),
                          const SizedBox(width: 4),
                          Flexible(
                            child: Text(
                              'LIVE • $onlineCount en sala',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          if (profanityFilterOn) ...[
                            const SizedBox(width: 5),
                            const Icon(Icons.shield_rounded,
                                color: Color(0xFF00E676), size: 11),
                          ],
                        ],
                      ),
                    ),
                    Flexible(
                      child: ShaderMask(
                        shaderCallback: (Rect bounds) {
                          return const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              Colors.black,
                              Colors.black,
                            ],
                            stops: [0.0, 0.22, 1.0],
                          ).createShader(bounds);
                        },
                        blendMode: BlendMode.dstIn,
                        child: messages.isEmpty
                            ? const Align(
                                alignment: Alignment.bottomLeft,
                                child: Padding(
                                  padding: EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    '💬 Sé el primero en comentar en vivo...',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 11,
                                      shadows: [
                                        Shadow(
                                            color: Colors.black, blurRadius: 4)
                                      ],
                                    ),
                                  ),
                                ),
                              )
                            : ListView.builder(
                                reverse: true,
                                physics: const BouncingScrollPhysics(),
                                padding: const EdgeInsets.only(top: 16),
                                itemCount: messages.length,
                                itemBuilder: (context, index) {
                                  return _buildMessageBubble(
                                      messages[index], profanityFilterOn);
                                },
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Aviso de moderación / anti-spam
          if (_moderationNotice.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 58,
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: const Color(0xDD1A103C),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amberAccent),
                  ),
                  child: Text(
                    _moderationNotice,
                    style: const TextStyle(
                        color: Colors.amberAccent,
                        fontSize: 11,
                        fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),

          // Barra inferior de escritura y reacciones
          Positioned(
            left: 10,
            right: 10,
            bottom: 8,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.62),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.35),
                      ),
                    ),
                    child: Row(
                      children: [
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextField(
                            controller: _chatController,
                            focusNode: _inputFocusNode,
                            onTap: _wakeUpFeed,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12.5),
                            decoration: const InputDecoration(
                              hintText: 'Comenta en vivo...',
                              hintStyle: TextStyle(
                                  color: Colors.white54, fontSize: 12),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _sendMessage(),
                          ),
                        ),
                        IconButton(
                          padding: EdgeInsets.zero,
                          constraints:
                              const BoxConstraints(minWidth: 34, minHeight: 34),
                          icon: const Icon(Icons.send_rounded,
                              color: Color(0xFF00E5FF), size: 18),
                          onPressed: () => _sendMessage(),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _buildReactionButton('🔥'),
                _buildReactionButton('⚽'),
                _buildReactionButton('😂'),
                _buildReactionButton('❤️'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Diseño Smart TV: Panel lateral derecho semitransparente navegable con D-pad
  Widget _buildTvChatLayout(bool profanityFilterOn) {
    final messages = _mergedMessages;
    final onlineCount = max(1, _recentSenders.length);

    return Stack(
      children: [
        ..._buildFloatingEmojisLayer(),
        Positioned(
          top: 16,
          right: 16,
          bottom: 16,
          width: 350,
          child: FocusScope(
            node: _tvChatScopeNode,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  (event.logicalKey == LogicalKeyboardKey.escape ||
                      event.logicalKey == LogicalKeyboardKey.goBack)) {
                widget.onClose?.call();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF080D18).withOpacity(0.84),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: const Color(0xFF00E5FF).withOpacity(0.45),
                  width: 1.4,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Cabecera TV
                  Row(
                    children: [
                      const Icon(Icons.forum_rounded,
                          color: Color(0xFF00E5FF), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Chat en Vivo • ${widget.channelName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13.5,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Row(
                              children: [
                                const Icon(Icons.circle,
                                    color: Color(0xFFFF1744), size: 7),
                                const SizedBox(width: 4),
                                Text(
                                  '$onlineCount activo(s) ${profanityFilterOn ? "• 🛡️ Filtro activo" : ""}',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 10.5,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (widget.onClose != null)
                        _buildTvFocusableChip(
                          label: '✕',
                          color: Colors.white12,
                          onTap: widget.onClose!,
                        ),
                    ],
                  ),
                  const Divider(color: Colors.white12, height: 18),

                  // Feed ascendente con degradado superior
                  Expanded(
                    child: ShaderMask(
                      shaderCallback: (Rect bounds) {
                        return const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black,
                            Colors.black,
                          ],
                          stops: [0.0, 0.14, 1.0],
                        ).createShader(bounds);
                      },
                      blendMode: BlendMode.dstIn,
                      child: messages.isEmpty
                          ? const Center(
                              child: Text(
                                '¡El chat está listo!\nEnvía una reacción rápida abajo con tu control.',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: Colors.white54, fontSize: 12.5),
                              ),
                            )
                          : ListView.builder(
                              reverse: true,
                              padding: const EdgeInsets.only(top: 14),
                              itemCount: messages.length,
                              itemBuilder: (context, index) {
                                return _buildMessageBubble(
                                    messages[index], profanityFilterOn);
                              },
                            ),
                    ),
                  ),

                  if (_moderationNotice.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      _moderationNotice,
                      style: const TextStyle(
                          color: Colors.amberAccent,
                          fontSize: 11,
                          fontWeight: FontWeight.bold),
                    ),
                  ],

                  const Divider(color: Colors.white12, height: 16),

                  // Frases rápidas navegables con control remoto (1 clic)
                  const Text(
                    'RESPUESTAS RÁPIDAS (OK):',
                    style: TextStyle(
                      color: Color(0xFF00E5FF),
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _tvQuickPhrases
                        .map(
                          (phrase) => _buildTvFocusableChip(
                            label: phrase,
                            color: const Color(0xFF161F33),
                            onTap: () => _sendMessage(phrase),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(height: 10),

                  // Reacciones flotantes con 1 clic
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: _quickEmojis
                        .map(
                          (emoji) => _buildTvFocusableChip(
                            label: emoji,
                            color: Colors.white10,
                            fontSize: 17,
                            onTap: () => _sendReaction(emoji),
                          ),
                        )
                        .toList(),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageBubble(_LiveChatMsg msg, bool profanityFilterOn) {
    final displayText = profanityFilterOn
        ? ParentalService.sanitizeMessage(msg.text)
        : msg.text;
    final nameColor = _senderColor(msg.sender, msg.isVip);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 5),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.54),
          borderRadius: BorderRadius.circular(12),
          border: msg.isVip
              ? Border.all(
                  color: const Color(0xFFFFD600).withOpacity(0.45), width: 0.8)
              : null,
        ),
        child: RichText(
          text: TextSpan(
            children: [
              if (msg.isVip)
                const WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: Padding(
                    padding: EdgeInsets.only(right: 4),
                    child: Icon(Icons.stars_rounded,
                        color: Color(0xFFFFD600), size: 12),
                  ),
                ),
              TextSpan(
                text: '${msg.sender}: ',
                style: TextStyle(
                  color: nameColor,
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
              TextSpan(
                text: displayText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  height: 1.25,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFloatingEmojisLayer() {
    return _activeEmojis.map((emojiData) {
      return TweenAnimationBuilder<double>(
        key: ValueKey(emojiData.id),
        tween: Tween(begin: 1.0, end: 0.0),
        duration: const Duration(milliseconds: 2400),
        builder: (context, value, child) {
          final size = MediaQuery.of(context).size;
          return Positioned(
            left: size.width * emojiData.startX,
            bottom: 65 + (size.height * 0.42 * (1 - value)),
            child: IgnorePointer(
              child: Opacity(
                opacity: value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.9 + (1 - value) * 0.6,
                  child: Text(emojiData.emoji,
                      style: const TextStyle(fontSize: 26)),
                ),
              ),
            ),
          );
        },
      );
    }).toList();
  }

  Widget _buildReactionButton(String emoji) {
    return GestureDetector(
      onTap: () => _sendReaction(emoji),
      child: Container(
        margin: const EdgeInsets.only(left: 5),
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.55),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white24, width: 1),
        ),
        child: Text(emoji, style: const TextStyle(fontSize: 15)),
      ),
    );
  }

  Widget _buildTvFocusableChip({
    required String label,
    required Color color,
    required VoidCallback onTap,
    double fontSize = 11.5,
  }) {
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
      child: Builder(
        builder: (context) {
          final hasFocus = Focus.of(context).hasFocus;
          return GestureDetector(
            onTap: onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 130),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: hasFocus ? const Color(0xFF00E5FF) : color,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: hasFocus ? Colors.white : Colors.white12,
                  width: hasFocus ? 1.8 : 0.8,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  color: hasFocus ? Colors.black : Colors.white,
                  fontSize: fontSize,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}