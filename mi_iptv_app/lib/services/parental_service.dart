import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ParentalService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static String? _currentUserId;

  static void setCurrentUser(String userId) {
    _currentUserId = userId.trim();
  }

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
      await _firestore.collection('users').doc(uid).set(scheduleData, SetOptions(merge: true));
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('sleep_enabled_$uid', enabled);
    await prefs.setInt('sleep_start_h_$uid', startHour);
    await prefs.setInt('sleep_start_m_$uid', startMinute);
    await prefs.setInt('sleep_end_h_$uid', endHour);
    await prefs.setInt('sleep_end_m_$uid', endMinute);
  }

  static Future<Map<String, dynamic>> getSleepSchedule() async {
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

  // Verifica si el reloj actual se encuentra dentro del rango de apagado
  static Future<bool> isSleepTimeActive() async {
    final schedule = await getSleepSchedule();
    if (schedule['enabled'] != true) return false;

    final now = DateTime.now();
    final nowMinutes = now.hour * 60 + now.minute;
    final startMinutes = (schedule['startH'] as int) * 60 + (schedule['startM'] as int);
    final endMinutes = (schedule['endH'] as int) * 60 + (schedule['endM'] as int);

    if (startMinutes <= endMinutes) {
      return nowMinutes >= startMinutes && nowMinutes < endMinutes;
    } else {
      // Cruza la medianoche (ejemplo: 22:00 a 06:00)
      return nowMinutes >= startMinutes || nowMinutes < endMinutes;
    }
  }
}