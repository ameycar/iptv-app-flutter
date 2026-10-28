import 'package:shared_preferences/shared_preferences.dart';

class ParentalService {
  static const String _pinKey = 'parental_pin';
  static const String _lockedCategoriesKey = 'locked_categories';

  // Guardar o actualizar el PIN parental (4 dígitos)
  static Future<bool> setPin(String pin) async {
    final prefs = await SharedPreferences.getInstance();
    return await prefs.setString(_pinKey, pin);
  }

  // Obtener el PIN actual (null si no se ha configurado)
  static Future<String?> getPin() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_pinKey);
  }

  // Verificar si el PIN ingresado es correcto
  static Future<bool> verifyPin(String inputPin) async {
    final currentPin = await getPin();
    if (currentPin == null) return true; // Si no hay PIN configurado, permite acceso
    return currentPin == inputPin;
  }

  // Saber si existe un PIN establecido
  static Future<bool> hasPin() async {
    final pin = await getPin();
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
