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
class _IncomingReaction {
  final String id;
  final String emoji;

  const _IncomingReaction({
    required this.id,
    required this.emoji,
  });
}

class LiveChatOverlay extends StatefulWidget {
  final String channelId;
  final String channelName;
  final bool isTvMode;
  final VoidCallback? onClose;

  static final String _sharedSessionId =
      's_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';
  static String _watchingDocId = '';
  static Timer? _watchingTimer;

  static String normalizeChannelDocId(String raw) {
    final cleaned = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    return cleaned.isEmpty ? 'canal_general' : cleaned;
  }

  static Future<void> _writePresencePing(String docId) async {
    if (!AuthService.isFirebaseAvailable || docId.isEmpty) return;
    final userName = AuthService.currentActiveProfile?.deviceName ??
        AuthService.currentUser?.username ??
        'Espectador';
    try {
      await FirebaseFirestore.instance
          .collection('live_chats')
          .doc(docId)
          .collection('presence')
          .doc(_sharedSessionId)
          .set({
        'user': userName,
        'clientMs': DateTime.now().millisecondsSinceEpoch,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  static Future<void> _deletePresenceDoc(String docId) async {
    if (!AuthService.isFirebaseAvailable || docId.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('live_chats')
          .doc(docId)
          .collection('presence')
          .doc(_sharedSessionId)
          .delete();
    } catch (_) {}
  }

  static Future<void> syncWatchingPresence(String rawChannelId) async {
    final docId = normalizeChannelDocId(rawChannelId);
    if (!AuthService.isFirebaseAvailable || docId.isEmpty) return;

    if (_watchingDocId.isNotEmpty && _watchingDocId != docId) {
      final prev = _watchingDocId;
      _watchingDocId = docId;
      unawaited(_deletePresenceDoc(prev));
    } else {
      _watchingDocId = docId;
    }

    _watchingTimer?.cancel();
    unawaited(_writePresencePing(docId));
    _watchingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_watchingDocId == docId) {
        _writePresencePing(docId);
      }
    });
  }

  static Future<void> stopWatchingPresence() async {
    _watchingTimer?.cancel();
    _watchingTimer = null;
    final prev = _watchingDocId;
    _watchingDocId = '';
    if (prev.isNotEmpty) {
      await _deletePresenceDoc(prev);
    }
  }

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
  final Set<String> _processedMsgIds = {};
  final Set<String> _seenReactionIds = {};
  final List<_LiveChatMsg> _pendingQueue = [];
  final List<_LiveChatMsg> _visibleMessages = [];

  StreamSubscription? _messagesSub;
  StreamSubscription? _presenceSub;
  Timer? _presenceTimer;
  Timer? _topExpireTimer;
  Timer? _fadeRemoveTimer;
  Timer? _queuePaceTimer;
  Timer? _noticeTimer;

  int _liveViewersCount = 1;
  String _activePresenceDocId = '';
  bool _hasLoadedInitialSnapshot = false;
  String? _fadingTopMsgId;

  DateTime _lastSendTime = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastReactionTime = DateTime.fromMillisecondsSinceEpoch(0);
  String _moderationNotice = '';

  static const List<String> _tvQuickPhrases = [
    '⚽ ¡GOLAZO!',
    '🔥 ¡Buenazo!',
    '😂 Jajaja',
    '👏 ¡Bravo!',
    '😱 ¡Increíble!',
  ];

  static const List<String> _quickEmojis = ['🔥', '⚽', '😂', '👏', '😱', '❤️'];

  int get _maxVisibleSlots => widget.isTvMode ? 4 : 3;

  String get _currentUsername =>
      AuthService.currentActiveProfile?.deviceName ??
      AuthService.currentUser?.username ??
      'Espectador';

  bool get _isVip => AuthService.currentUser?.isVip ?? false;

  String get _safeDocId => LiveChatOverlay.normalizeChannelDocId(widget.channelId);

  @override
  void initState() {
    super.initState();
    ParentalService.getProfanityFilterEnabled();
    ParentalService.getHiddenMenuItems();
    _subscribeToChannelChat();
    _startPresenceHeartbeat();

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
      _resetQueueAndChannelState();
      _subscribeToChannelChat();
      _startPresenceHeartbeat();
    }
  }

  void _resetQueueAndChannelState() {
    _topExpireTimer?.cancel();
    _topExpireTimer = null;
    _fadeRemoveTimer?.cancel();
    _fadeRemoveTimer = null;
    _queuePaceTimer?.cancel();
    _queuePaceTimer = null;
    _processedMsgIds.clear();
    _seenReactionIds.clear();
    _pendingQueue.clear();
    _visibleMessages.clear();
    _activeEmojis.clear();
    _fadingTopMsgId = null;
    _hasLoadedInitialSnapshot = false;
  }

  void _subscribeToChannelChat() {
    _messagesSub?.cancel();
    if (!AuthService.isFirebaseAvailable) return;

    _messagesSub = FirebaseFirestore.instance
        .collection('live_chats')
        .doc(_safeDocId)
        .collection('messages')
        .orderBy('createdAtMs', descending: true)
        .limit(60)
        .snapshots()
        .listen(
      (snapshot) {
        if (!mounted) return;
        final List<_LiveChatMsg> parsedTexts = [];
        final List<_IncomingReaction> parsedReactions = [];

        for (final doc in snapshot.docs) {
          final data = doc.data();
          final type = (data['type'] ?? 'text').toString();
          final msgId = (data['clientMsgId'] ?? doc.id).toString();

          if (type == 'reaction') {
            final emoji = (data['emoji'] ?? data['text'] ?? '').toString().trim();
            if (emoji.isNotEmpty) {
              parsedReactions.add(_IncomingReaction(id: msgId, emoji: emoji));
            }
            continue;
          }

          final sender = (data['sender'] ?? 'Usuario').toString();
          final text = (data['text'] ?? '').toString();
          if (text.trim().isEmpty) continue;
          final isVipMsg = data['isVip'] == true;
          final createdAtMs = (data['createdAtMs'] is int)
              ? data['createdAtMs'] as int
              : DateTime.now().millisecondsSinceEpoch;

          parsedTexts.add(_LiveChatMsg(
            id: msgId,
            sender: sender,
            text: text,
            isVip: isVipMsg,
            createdAtMs: createdAtMs,
          ));
        }

        parsedTexts.sort((a, b) => a.createdAtMs.compareTo(b.createdAtMs));

        if (!_hasLoadedInitialSnapshot) {
          _hasLoadedInitialSnapshot = true;

          for (final rx in parsedReactions) {
            _seenReactionIds.add(rx.id);
          }

          final nowMs = DateTime.now().millisecondsSinceEpoch;
          final int recentStartIdx =
              parsedTexts.length > 2 ? parsedTexts.length - 2 : 0;

          for (int i = 0; i < parsedTexts.length; i++) {
            final msg = parsedTexts[i];
            final bool isVeryRecent =
                i >= recentStartIdx && (nowMs - msg.createdAtMs).abs() <= 90000;
            if (isVeryRecent) {
              _enqueueMessage(msg);
            } else {
              _processedMsgIds.add(msg.id);
            }
          }
          return;
        }

        for (final rx in parsedReactions) {
          if (!_seenReactionIds.contains(rx.id)) {
            _seenReactionIds.add(rx.id);
            _spawnFloatingEmoji(rx.emoji, id: rx.id);
          }
        }

        for (final msg in parsedTexts) {
          if (!_processedMsgIds.contains(msg.id)) {
            _enqueueMessage(msg);
          }
        }
      },
      onError: (e) {
        debugPrint('Aviso stream chat en vivo: $e');
      },
    );
  }

  void _enqueueMessage(_LiveChatMsg msg) {
    if (_processedMsgIds.contains(msg.id)) return;
    _processedMsgIds.add(msg.id);
    _pendingQueue.add(msg);
    if (_pendingQueue.length > 40) {
      _pendingQueue.removeAt(0);
    }
    _pumpQueue();
  }

  void _pumpQueue() {
    if (!mounted) return;
    if (_pendingQueue.isEmpty || _visibleMessages.length >= _maxVisibleSlots) {
      return;
    }
    if (_queuePaceTimer?.isActive == true) return;

    final nextMsg = _pendingQueue.removeAt(0);
    setState(() {
      _visibleMessages.add(nextMsg);
    });

    _ensureTopCountdown();

    _queuePaceTimer = Timer(const Duration(milliseconds: 850), () {
      _queuePaceTimer = null;
      _pumpQueue();
    });
  }

  void _ensureTopCountdown() {
    if (_visibleMessages.isEmpty) {
      _topExpireTimer?.cancel();
      _topExpireTimer = null;
      return;
    }
    if (_topExpireTimer?.isActive == true || _fadeRemoveTimer?.isActive == true) {
      return;
    }

    final String topId = _visibleMessages.first.id;
    _topExpireTimer = Timer(const Duration(seconds: 3), () {
      _topExpireTimer = null;
      if (!mounted) return;
      if (_visibleMessages.isEmpty || _visibleMessages.first.id != topId) {
        _ensureTopCountdown();
        return;
      }

      setState(() {
        _fadingTopMsgId = topId;
      });

      _fadeRemoveTimer?.cancel();
      _fadeRemoveTimer = Timer(const Duration(milliseconds: 350), () {
        _fadeRemoveTimer = null;
        if (!mounted) return;
        setState(() {
          _visibleMessages.removeWhere((m) => m.id == topId);
          if (_fadingTopMsgId == topId) {
            _fadingTopMsgId = null;
          }
        });

        _ensureTopCountdown();

        if (_pendingQueue.isNotEmpty) {
          _queuePaceTimer?.cancel();
          _queuePaceTimer = Timer(const Duration(milliseconds: 450), () {
            _queuePaceTimer = null;
            _pumpQueue();
          });
        }
      });
    });
  }

  Future<void> _leavePresence() async {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _presenceSub?.cancel();
    _presenceSub = null;
    final oldDocId = _activePresenceDocId;
    _activePresenceDocId = '';
    if (!AuthService.isFirebaseAvailable || oldDocId.isEmpty) return;
    if (oldDocId != LiveChatOverlay._watchingDocId) {
      await LiveChatOverlay._deletePresenceDoc(oldDocId);
    }
  }

  void _startPresenceHeartbeat() {
    _leavePresence();
    if (!AuthService.isFirebaseAvailable) return;
    final docId = _safeDocId;
    _activePresenceDocId = docId;

    LiveChatOverlay._writePresencePing(docId);
    _presenceTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      LiveChatOverlay._writePresencePing(docId);
    });

    _presenceSub = FirebaseFirestore.instance
        .collection('live_chats')
        .doc(docId)
        .collection('presence')
        .snapshots()
        .listen((snapshot) {
      if (!mounted) return;

      int maxServerMs = 0;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final ts = data['updatedAt'];
        if (ts is Timestamp && ts.millisecondsSinceEpoch > maxServerMs) {
          maxServerMs = ts.millisecondsSinceEpoch;
        }
      }

      final nowLocalMs = DateTime.now().millisecondsSinceEpoch;
      int activeNow = 0;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        final ts = data['updatedAt'];
        final clientMs = data['clientMs'];

        if (ts == null) {
          activeNow++;
        } else if (ts is Timestamp &&
            (maxServerMs - ts.millisecondsSinceEpoch) <= 120000) {
          activeNow++;
        } else if (maxServerMs == 0 &&
            clientMs is int &&
            (nowLocalMs - clientMs).abs() <= 120000) {
          activeNow++;
        }
      }

      setState(() {
        _liveViewersCount = max(1, activeNow);
      });
    }, onError: (_) {});
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

    final bool filterActive = ParentalService.isProfanityFilterEnabledSync();
    if (ParentalService.containsProfanity(textToSend)) {
      if (filterActive) {
        textToSend = ParentalService.sanitizeMessage(textToSend);
        _showModerationNotice('🛡️ Palabras filtradas por Control Parental.');
      }
    }

    if (presetText == null) {
      _chatController.clear();
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final clientMsgId = '${nowMs}_${_random.nextInt(999999)}';

    _enqueueMessage(_LiveChatMsg(
      id: clientMsgId,
      sender: _currentUsername,
      text: textToSend,
      isVip: _isVip,
      createdAtMs: nowMs,
    ));

    if (AuthService.isFirebaseAvailable) {
      try {
        await FirebaseFirestore.instance
            .collection('live_chats')
            .doc(_safeDocId)
            .collection('messages')
            .add({
          'type': 'text',
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

  void _spawnFloatingEmoji(String emoji, {String? id}) {
    if (!mounted || emoji.trim().isEmpty) return;
    final emojiId =
        id ?? '${DateTime.now().microsecondsSinceEpoch}_${_random.nextInt(9999)}';

    final newEmoji = FloatingEmoji(
      id: emojiId,
      emoji: emoji,
      startX: widget.isTvMode
          ? 0.68 + (_random.nextDouble() * 0.22)
          : 0.62 + (_random.nextDouble() * 0.28),
    );

    setState(() {
      _activeEmojis.add(newEmoji);
      if (_activeEmojis.length > 16) {
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

  Future<void> _sendReaction(String emoji) async {
    final now = DateTime.now();
    if (now.difference(_lastReactionTime).inMilliseconds < 320) return;
    _lastReactionTime = now;

    final nowMs = now.millisecondsSinceEpoch;
    final reactionId = 'rx_${nowMs}_${_random.nextInt(999999)}';

    _seenReactionIds.add(reactionId);
    _spawnFloatingEmoji(emoji, id: reactionId);

    if (AuthService.isFirebaseAvailable) {
      try {
        await FirebaseFirestore.instance
            .collection('live_chats')
            .doc(_safeDocId)
            .collection('messages')
            .add({
          'type': 'reaction',
          'emoji': emoji,
          'text': emoji,
          'clientMsgId': reactionId,
          'sender': _currentUsername,
          'isVip': _isVip,
          'createdAtMs': nowMs,
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        debugPrint('Error enviando reacción en vivo: $e');
      }
    }
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

  @override
  void dispose() {
    _leavePresence();
    _messagesSub?.cancel();
    _topExpireTimer?.cancel();
    _fadeRemoveTimer?.cancel();
    _queuePaceTimer?.cancel();
    _noticeTimer?.cancel();
    _chatController.dispose();
    _inputFocusNode.dispose();
    _tvChatScopeNode.dispose();
    super.dispose();
  }

  @override
  void dispose() {
    _leavePresence();
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

  /// Diseño Smartphone / Tablet: tope bajo (<= mitad del video), toques libres al video y 3s en tope
  Widget _buildMobileLiveChatLayout(bool profanityFilterOn) {
    final onlineCount = max(1, _liveViewersCount);

    return LayoutBuilder(
      builder: (context, constraints) {
        final double maxFeedHeight =
            (constraints.maxHeight * 0.44).clamp(64.0, 128.0);

        return Stack(
          children: [
            ..._buildFloatingEmojisLayer(constraints.biggest),

            Positioned(
              top: 8,
              left: 10,
              child: IgnorePointer(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.58),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: const Color(0xFF00E5FF).withOpacity(0.45)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.circle,
                          color: Color(0xFFFF1744), size: 7),
                      const SizedBox(width: 4),
                      Text(
                        'LIVE • $onlineCount en sala',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
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
              ),
            ),

            Positioned(
              left: 10,
              right: 20,
              bottom: 54,
              child: IgnorePointer(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxFeedHeight),
                  child: ClipRect(
                    child: Align(
                      alignment: Alignment.bottomLeft,
                      child: _visibleMessages.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.only(bottom: 4),
                              child: Text(
                                '💬 Sé el primero en comentar en vivo...',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 4)
                                  ],
                                ),
                              ),
                            )
                          : Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: _visibleMessages.map((msg) {
                                final isFading = _fadingTopMsgId == msg.id;
                                return _buildAnimatedMessageBubble(
                                  msg,
                                  profanityFilterOn,
                                  isFadingOut: isFading,
                                );
                              }).toList(),
                            ),
                    ),
                  ),
                ),
              ),
            ),

            if (_moderationNotice.isNotEmpty)
              Positioned(
                left: 12,
                right: 12,
                bottom: 54,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
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
              ),

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
                            constraints: const BoxConstraints(
                                minWidth: 34, minHeight: 34),
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
        );
      },
    );
  }

  /// Diseño Smart TV: Panel lateral derecho con cola ordenada, 3s al llegar al tope y emojis en vivo
  Widget _buildTvChatLayout(bool profanityFilterOn) {
    final onlineCount = max(1, _liveViewersCount);

    return LayoutBuilder(
      builder: (context, constraints) {
        return Stack(
          children: [
            ..._buildFloatingEmojisLayer(constraints.biggest),
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

                      Expanded(
                        child: Align(
                          alignment: Alignment.bottomLeft,
                          child: _visibleMessages.isEmpty
                              ? const Center(
                                  child: Text(
                                    '¡El chat está listo!\nEnvía una reacción rápida abajo con tu control.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 12.5),
                                  ),
                                )
                              : SingleChildScrollView(
                                  physics: const NeverScrollableScrollPhysics(),
                                  reverse: true,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: _visibleMessages.map((msg) {
                                      final isFading =
                                          _fadingTopMsgId == msg.id;
                                      return _buildAnimatedMessageBubble(
                                        msg,
                                        profanityFilterOn,
                                        isFadingOut: isFading,
                                      );
                                    }).toList(),
                                  ),
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
      },
    );
  }

  Widget _buildAnimatedMessageBubble(
    _LiveChatMsg msg,
    bool profanityFilterOn, {
    required bool isFadingOut,
  }) {
    return KeyedSubtree(
      key: ValueKey(msg.id),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 340),
        opacity: isFadingOut ? 0.0 : 1.0,
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, value, child) {
            return Opacity(
              opacity: value.clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, 14 * (1 - value)),
                child: child,
              ),
            );
          },
          child: _buildMessageBubble(msg, profanityFilterOn),
        ),
      ),
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
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4.5),
        decoration: BoxDecoration(
          color: Colors.black.withOpacity(0.58),
          borderRadius: BorderRadius.circular(12),
          border: msg.isVip
              ? Border.all(
                  color: const Color(0xFFFFD600).withOpacity(0.45), width: 0.8)
              : null,
        ),
        child: RichText(
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
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
                  fontSize: 11.5,
                ),
              ),
              TextSpan(
                text: displayText,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildFloatingEmojisLayer(Size areaSize) {
    final double w = areaSize.width > 0 ? areaSize.width : 320;
    final double h = areaSize.height > 0 ? areaSize.height : 200;

    return _activeEmojis.map((emojiData) {
      return TweenAnimationBuilder<double>(
        key: ValueKey(emojiData.id),
        tween: Tween(begin: 1.0, end: 0.0),
        duration: const Duration(milliseconds: 2400),
        builder: (context, value, child) {
          return Positioned(
            left: (w * emojiData.startX).clamp(16.0, max(16.0, w - 42.0)),
            bottom: 52 + (h * 0.52 * (1 - value)),
            child: IgnorePointer(
              child: Opacity(
                opacity: value.clamp(0.0, 1.0),
                child: Transform.scale(
                  scale: 0.9 + (1 - value) * 0.55,
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