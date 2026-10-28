import 'package:shared_preferences/shared_preferences.dart';

class ParentalService {
  static const String _pinKey = 'parental_pin';
  static const String _lockedCategoriesKey = 'locked_categories';

  // Guardar o actualizar el PIN parental (4 dígitos)
  static Future<bool> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    return await prefs.setString(_pinKey, pin);
  }

  // Obtener el PIN actual (devuelve '0000' si el usuario aún no configuró uno)
  static Future<String> getPin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pinKey) ?? '0000';
  }

  // Verificar si el PIN ingresado coincide con el guardado o el defecto '0000'
  static Future<bool> verifyPin(String inputPin) async {
    final currentPin = await getPin();
    return currentPin == inputPin.trim();
  }

  // Saber si existe un PIN establecido por el usuario
  static Future<bool> hasPin() async {
    final prefs = await SharedPreferences.getInstance();
    final pin = prefs.getString(_pinKey);
    return pin != null && pin.isNotEmpty;
  }

  // Obtener lista de categorías bloqueadas
  static Future<List<String>> getLockedCategories() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getStringList(_lockedCategoriesKey) ?? [];
  }

  // Alternar bloqueo de una categoría
  static Future<void> toggleCategoryLock(String categoryName) async {
    final prefs = await SharedPreferences.getInstance();
    final locked = prefs.getStringList(_lockedCategoriesKey) ?? [];
    if (locked.contains(categoryName)) {
      locked.remove(categoryName);
    } else {
      locked.add(categoryName);
    }
    await prefs.setStringList(_lockedCategoriesKey, locked);
  }

  // Saber si una categoría en particular está bloqueada
  static Future<bool> isCategoryLocked(String categoryName) async {
    final locked = await getLockedCategories();
    return locked.contains(categoryName);
  }
}