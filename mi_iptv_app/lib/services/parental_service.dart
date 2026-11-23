import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_service.dart';

class ParentalService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static String? get _currentUserId => AuthService.currentUser?.id;

  // Notificadores en tiempo real para que TV y Celular reaccionen al instante
  static final ValueNotifier<List<String>> hiddenItemsNotifier =
      ValueNotifier<List<String>>([]);
  static final ValueNotifier<bool> profanityFilterNotifier =
      ValueNotifier<bool>(true);

  static List<String> _cachedHiddenItems = [];

  static void setCurrentUser(String userId) {}

  // --- PIN PARENTAL ---
  static Future<bool> setPin(String pin) async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return false;
    try {
      await _firestore.collection('users').doc(uid).set({
        'parental_pin': pin,
      }, SetOptions(merge: true));

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('parental_pin_$uid', pin);
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<String> getPin() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return '0000';
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists && doc.data()?.containsKey('parental_pin') == true) {
        return doc.data()!['parental_pin'] ?? '0000';
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('parental_pin_$uid') ?? '0000';
  }

  static Future<bool> verifyPin(String inputPin) async {
    final currentPin = await getPin();
    return currentPin == inputPin.trim();
  }

  // Cambia el PIN verificando primero el anterior o clave maestra
  static Future<bool> changePinWithOldPin({
    required String oldPin,
    required String newPin,
  }) async {
    final currentPin = await getPin();
    if (oldPin.trim() != currentPin && oldPin.trim() != '9999') {
      return false;
    }
    return await setPin(newPin.trim());
  }

  // Reseteo administrativo desde el panel de Master Admin
  static Future<bool> adminForceResetPin(String targetUserId) async {
    try {
      await _firestore.collection('users').doc(targetUserId).set({
        'parental_pin': '0000',
      }, SetOptions(merge: true));
      return true;
    } catch (_) {
      return false;
    }
  }

  // Solicitud al CEO / Admin para reiniciar PIN
  static Future<void> requestPinReset() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return;
    try {
      await _firestore.collection('pin_reset_requests').doc(uid).set({
        'userId': uid,
        'requestedAt': FieldValue.serverTimestamp(),
        'status': 'pending',
      }, SetOptions(merge: true));
    } catch (_) {}
  }

  // --- CATEGORÍAS BLOQUEADAS ---
  static Future<List<String>> getLockedCategories() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return [];
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists && doc.data()?.containsKey('locked_categories') == true) {
        final List<dynamic> list = doc.data()!['locked_categories'] ?? [];
        return list.map((e) => e.toString()).toList();
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList('locked_categories_$uid') ?? [];
  }

  static Future<void> toggleCategoryLock(String categoryName) async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return;

    final current = await getLockedCategories();
    if (current.contains(categoryName)) {
      current.remove(categoryName);
    } else {
      current.add(categoryName);
    }

    try {
      await _firestore.collection('users').doc(uid).set({
        'locked_categories': current,
      }, SetOptions(merge: true));
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('locked_categories_$uid', current);
  }

  static Future<bool> isCategoryLocked(String categoryName) async {
    final locked = await getLockedCategories();
    return locked.contains(categoryName);
  }

  // --- HORA DE SUEÑO / BLOQUEO NOCTURNO (CURFEW) ---
  static Future<void> setSleepSchedule({
    required bool enabled,
    required int startHour,
    required int startMinute,
    required int endHour,
    required int endMinute,
  }) async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return;

    final scheduleData = {
      'sleep_lock_enabled': enabled,
      'sleep_start_hour': startHour,
      'sleep_start_minute': startMinute,
      'sleep_end_hour': endHour,
      'sleep_end_minute': endMinute,
    };

    try {
      await _firestore
          .collection('users')
          .doc(uid)
          .set(scheduleData, SetOptions(merge: true));
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sleep_enabled_$uid', enabled);
    await prefs.setInt('sleep_start_h_$uid', startHour);
    await prefs.setInt('sleep_start_m_$uid', startMinute);
    await prefs.setInt('sleep_end_h_$uid', endHour);
    await prefs.setInt('sleep_end_m_$uid', endMinute);
  }

  static Future<ParentalMap> getSleepSchedule() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) {
      return {'enabled': false, 'startH': 22, 'startM': 0, 'endH': 6, 'endM': 0};
    }

    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists && doc.data()?.containsKey('sleep_lock_enabled') == true) {
        final d = doc.data()!;
        return {
          'enabled': d['sleep_lock_enabled'] ?? false,
          'startH': d['sleep_start_hour'] ?? 22,
          'startM': d['sleep_start_minute'] ?? 0,
          'endH': d['sleep_end_hour'] ?? 6,
          'endM': d['sleep_end_minute'] ?? 0,
        };
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    return {
      'enabled': prefs.getBool('sleep_enabled_$uid') ?? false,
      'startH': prefs.getInt('sleep_start_h_$uid') ?? 22,
      'startM': prefs.getInt('sleep_start_m_$uid') ?? 0,
      'endH': prefs.getInt('sleep_end_h_$uid') ?? 6,
      'endM': prefs.getInt('sleep_end_m_$uid') ?? 0,
    };
  }

  static Future<bool> isSleepTimeActive() async {
    final schedule = await getSleepSchedule();
    if (schedule['enabled'] != true) return false;

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes =
        (schedule['startH'] as int) * 60 + (schedule['startM'] as int);
    final endMinutes =
        (schedule['endH'] as int) * 60 + (schedule['endM'] as int);

    if (startMinutes <= endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    } else {
      return nowMinutes >= startMinutes || nowMinutes < endMinutes;
    }
  }

  // --- ELEMENTOS DEL MENÚ OCULTOS (ANTI-BYPASS, INCLUYE 'chat') ---
  static bool isMenuItemHiddenSync(String itemKey) {
    return _cachedHiddenItems.contains(itemKey);
  }

  static bool isChatHiddenSync() {
    return _cachedHiddenItems.contains('chat');
  }

  static Future<List<String>> getHiddenMenuItems() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return _cachedHiddenItems;
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists && doc.data()?.containsKey('hidden_menu_items') == true) {
        final List<dynamic> list = doc.data()!['hidden_menu_items'] ?? [];
        _cachedHiddenItems = list.map((e) => e.toString()).toList();
        hiddenItemsNotifier.value = List<String>.from(_cachedHiddenItems);
        return _cachedHiddenItems;
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    _cachedHiddenItems = prefs.getStringList('hidden_menu_items_$uid') ?? [];
    hiddenItemsNotifier.value = List<String>.from(_cachedHiddenItems);
    return _cachedHiddenItems;
  }

  static Future<void> setHiddenMenuItems(List<String> items) async {
    _cachedHiddenItems = List<String>.from(items);
    hiddenItemsNotifier.value = List<String>.from(items);
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return;
    try {
      await _firestore.collection('users').doc(uid).set({
        'hidden_menu_items': items,
      }, SetOptions(merge: true));
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('hidden_menu_items_$uid', items);
  }

  static Future<bool> isMenuItemHidden(String itemKey) async {
    final list = await getHiddenMenuItems();
    return list.contains(itemKey);
  }

  // --- FILTRO DE GROSERÍAS Y PALABRAS OBSCENAS EN CHAT EN VIVO ---
  static bool isProfanityFilterEnabledSync() {
    return profanityFilterNotifier.value;
  }

  static Future<bool> getProfanityFilterEnabled() async {
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return profanityFilterNotifier.value;
    try {
      final doc = await _firestore.collection('users').doc(uid).get();
      if (doc.exists &&
          doc.data()?.containsKey('chat_profanity_filter') == true) {
        final val = doc.data()!['chat_profanity_filter'] != false;
        profanityFilterNotifier.value = val;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('chat_profanity_filter_$uid', val);
        return val;
      }
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final localVal = prefs.getBool('chat_profanity_filter_$uid') ?? true;
    profanityFilterNotifier.value = localVal;
    return localVal;
  }

  static Future<void> setProfanityFilterEnabled(bool enabled) async {
    profanityFilterNotifier.value = enabled;
    final uid = _currentUserId;
    if (uid == null || uid.isEmpty) return;
    try {
      await _firestore.collection('users').doc(uid).set({
        'chat_profanity_filter': enabled,
      }, SetOptions(merge: true));
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('chat_profanity_filter_$uid', enabled);
  }

  // Diccionario de groserías y palabras obscenas (Español LATAM / España + Inglés)
  static const Set<String> _blockedWords = {
    'puta', 'puto', 'putas', 'putos', 'putita', 'putito', 'putear', 'puteo',
    'hijueputa', 'hdp', 'hp', 'hdpm', 'ctm', 'conchetumare', 'conchetumadre',
    'conchatumadre', 'conchatumare', 'reconchetumadre', 'reputa',
    'mierda', 'mierdas', 'mierdero', 'cagada', 'cagar', 'cagon', 'cagado',
    'carajo', 'carajos', 'verga', 'vergas', 'vergazo', 'vergon', 'averga',
    'chinga', 'chingada', 'chingado', 'chingar', 'chingon', 'chingate',
    'pendejo', 'pendeja', 'pendejos', 'pendejas', 'pendejada',
    'cabron', 'cabrona', 'cabrones', 'cabronazo',
    'culero', 'culera', 'culiao', 'culeado', 'culear', 'culo', 'culos', 'ojete',
    'cojudo', 'cojuda', 'cojudos', 'cojudez', 'huevon', 'huevona', 'huevones',
    'weon', 'weona', 'webon', 'webona', 'huevada', 'webada',
    'marico', 'maricon', 'marica', 'maricones', 'mariconazo', 'joto', 'putazo',
    'mamaguevo', 'mamahuevo', 'mardito', 'maldito', 'malparido', 'malparida',
    'gonorrea', 'pirobo', 'careverga', 'careculo', 'chupapico', 'chupapija',
    'pija', 'pijas', 'pito', 'pene', 'vagina', 'tetas', 'teta', 'chocha',
    'concha', 'conchudo', 'conchuda', 'pelotudo', 'pelotuda', 'boludo', 'boluda',
    'forro', 'gilipollas', 'joder', 'jodete', 'jodido', 'jodida', 'coño',
    'cono', 'hostia', 'capullo', 'subnormal', 'imbecil', 'idiota', 'estupido',
    'estupida', 'tarado', 'tarada', 'zorra', 'zorras', 'perra', 'perras',
    'bastardo', 'bastarda', 'desgraciado', 'desgraciada', 'pinche', 'pinches',
    'verguenza', 'pajero', 'pajera', 'paja', 'follar', 'follada', 'coger',
    'cogida', 'sexo', 'porno', 'pornografia', 'xxx', 'nudes', 'pack',
    'fuck', 'fucking', 'fucker', 'shit', 'bitch', 'asshole', 'bastard',
    'dick', 'cock', 'pussy', 'whore', 'slut', 'cunt', 'motherfucker', 'wtf',
    'stfu', 'nigger', 'nigga', 'faggot', 'retard', 'penis', 'boobs', 'porn',
  };

  static const List<String> _blockedPhrases = [
    'hijo de puta',
    'hija de puta',
    'hijos de puta',
    'la concha de tu madre',
    'concha de tu madre',
    'la puta madre',
    'tu puta madre',
    'vete a la mierda',
    'vete a la verga',
    'me vale verga',
    'chupa la verga',
    'chupame la',
    'vete al carajo',
    'que te jodan',
    'fuck you',
    'son of a bitch',
  ];

  static String _normalizeToken(String raw) {
    var s = raw.toLowerCase();
    const replacements = {
      'á': 'a', 'à': 'a', 'ä': 'a', 'â': 'a', '@': 'a', '4': 'a',
      'é': 'e', 'è': 'e', 'ë': 'e', 'ê': 'e', '3': 'e',
      'í': 'i', 'ì': 'i', 'ï': 'i', 'î': 'i', '1': 'i', '!': 'i',
      'ó': 'o', 'ò': 'o', 'ö': 'o', 'ô': 'o', '0': 'o',
      'ú': 'u', 'ù': 'u', 'ü': 'u', 'û': 'u',
      'ñ': 'n', '\$': 's', '5': 's', '7': 't',
    };
    final sb = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      sb.write(replacements[ch] ?? ch);
    }
    var cleaned = sb.toString().replaceAll(RegExp(r'[^a-z]'), '');
    // Colapsar letras estiradas (ej: puuuutaaaa -> puta)
    cleaned = cleaned.replaceAllMapped(
      RegExp(r'(.)\1{2,}'),
      (m) => m.group(1) ?? '',
    );
    return cleaned;
  }

  static bool _isBadWord(String rawWord) {
    final norm = _normalizeToken(rawWord);
    if (norm.length < 2) return false;
    if (_blockedWords.contains(norm)) return true;
    // También probar colapsando dobles letras (ej: puutta -> puta)
    final collapsed = norm.replaceAllMapped(
      RegExp(r'(.)\1+'),
      (m) => m.group(1) ?? '',
    );
    return _blockedWords.contains(collapsed);
  }

  static bool containsProfanity(String text) {
    if (text.trim().isEmpty) return false;

    final lowerNormSpace = text
        .toLowerCase()
        .replaceAll('á', 'a')
        .replaceAll('é', 'e')
        .replaceAll('í', 'i')
        .replaceAll('ó', 'o')
        .replaceAll('ú', 'u')
        .replaceAll('ñ', 'n');

    for (final phrase in _blockedPhrases) {
      if (lowerNormSpace.contains(phrase)) return true;
    }

    final wordRegex = RegExp(r'[A-Za-zÁÉÍÓÚáéíóúÜüÑñ0-9@\$!]+');
    for (final match in wordRegex.allMatches(text)) {
      final token = match.group(0) ?? '';
      if (_isBadWord(token)) return true;
    }

    // Detectar truco de separar letras con espacios (ej: "p u t a")
    final spacedLetters = RegExp(r'(?:\b[A-Za-z0-9@\$!]\s+){3,}[A-Za-z0-9@\$!]\b');
    for (final match in spacedLetters.allMatches(text)) {
      final joined = (match.group(0) ?? '').replaceAll(RegExp(r'\s+'), '');
      if (_isBadWord(joined)) return true;
    }

    return false;
  }

  static String sanitizeMessage(String text) {
    if (text.trim().isEmpty) return text;

    var result = text;

    // 1. Censurar frases compuestas
    for (final phrase in _blockedPhrases) {
      final pattern = RegExp(RegExp.escape(phrase), caseSensitive: false);
      result = result.replaceAllMapped(
        pattern,
        (m) => '*' * (m.group(0)?.length.clamp(4, 12) ?? 4),
      );
    }

    // 2. Censurar truco de letras separadas (ej: "p u t a")
    final spacedLetters = RegExp(r'(?:\b[A-Za-z0-9@\$!]\s+){3,}[A-Za-z0-9@\$!]\b');
    result = result.replaceAllMapped(spacedLetters, (m) {
      final raw = m.group(0) ?? '';
      final joined = raw.replaceAll(RegExp(r'\s+'), '');
      if (_isBadWord(joined)) {
        return '****';
      }
      return raw;
    });

    // 3. Censurar palabras individuales preservando signos y espacios
    final wordRegex = RegExp(r'[A-Za-zÁÉÍÓÚáéíóúÜüÑñ0-9@\$!]+');
    result = result.replaceAllMapped(wordRegex, (m) {
      final token = m.group(0) ?? '';
      if (_isBadWord(token)) {
        if (token.length <= 2) return '**';
        return '${token[0]}${'*' * (token.length - 1).clamp(3, 8)}';
      }
      return token;
    });

    return result;
  }
}