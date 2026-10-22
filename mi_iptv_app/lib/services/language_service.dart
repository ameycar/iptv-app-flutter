import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Servicio de gestión y traducción de idiomas para AMEYCAR TV
/// Soporta Español (es), Inglés (en) y Portugués (pt).
class LanguageService {
  static final ValueNotifier<String> currentLanguage = ValueNotifier<String>('es');

  static String get languageCode => currentLanguage.value;

  static const List<Map<String, String>> supportedLanguages = [
    {'code': 'es', 'name': 'Español', 'flag': '🇪🇸'},
    {'code': 'en', 'name': 'English', 'flag': '🇺🇸'},
    {'code': 'pt', 'name': 'Português', 'flag': '🇧🇷'},
  ];

  static Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedLang = prefs.getString('app_language_code') ?? 'es';
      currentLanguage.value = savedLang;
    } catch (_) {}
  }

  static Future<void> setLanguage(String langCode) async {
    if (['es', 'en', 'pt'].contains(langCode)) {
      currentLanguage.value = langCode;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('app_language_code', langCode);
      } catch (_) {}
    }
  }

  static final Map<String, Map<String, String>> _localizedValues = {
    'es': {
      'language': 'Idioma',
      'select_language': 'Seleccionar Idioma',
      'login_title': 'AmeycarTV VIP',
      'login_subtitle': 'Acceso Seguro & Blindado 1-Device',
      'username': 'Usuario',
      'password': 'Password / Clave',
      'btn_login': 'INICIAR SESIÓN',
      'loading': 'Cargando...',
      'who_is_watching': '¿Quién está viendo hoy?',
      'profiles_title': 'Perfiles de la Familia',
      'renew_plan': 'Renovar Plan',
      'redeem_pin': 'Canjear PIN',
      'manage_playlists': 'Gestor de Listas M3U',
      'add_playlist': 'Agregar Lista M3U',
      'live': 'En Vivo',
      'movies': 'Películas',
      'series': 'Series',
      'search_hint': 'Buscar canal, serie o película...',
      'no_channels': 'No hay canales cargados',
    },
    'en': {
      'language': 'Language',
      'select_language': 'Select Language',
      'login_title': 'AmeycarTV VIP',
      'login_subtitle': 'Secure & Shielded 1-Device Access',
      'username': 'Username',
      'password': 'Password',
      'btn_login': 'SIGN IN',
      'loading': 'Loading...',
      'who_is_watching': 'Who is watching today?',
      'profiles_title': 'Family Profiles',
      'renew_plan': 'Renew Plan',
      'redeem_pin': 'Redeem PIN',
      'manage_playlists': 'M3U Playlist Manager',
      'add_playlist': 'Add M3U Playlist',
      'live': 'Live TV',
      'movies': 'Movies',
      'series': 'Series',
      'search_hint': 'Search channel, series or movie...',
      'no_channels': 'No channels loaded',
    },
    'pt': {
      'language': 'Idioma',
      'select_language': 'Selecionar Idioma',
      'login_title': 'AmeycarTV VIP',
      'login_subtitle': 'Acesso Seguro & Blindado 1-Dispositivo',
      'username': 'Usuário',
      'password': 'Senha',
      'btn_login': 'ENTRAR',
      'loading': 'Carregando...',
      'who_is_watching': 'Quem está assistindo hoje?',
      'profiles_title': 'Perfis da Família',
      'renew_plan': 'Renovar Plano',
      'redeem_pin': 'Resgatar PIN',
      'manage_playlists': 'Gerenciador de Listas M3U',
      'add_playlist': 'Adicionar Lista M3U',
      'live': 'Ao Vivo',
      'movies': 'Filmes',
      'series': 'Séries',
      'search_hint': 'Pesquisar canal, série ou filme...',
      'no_channels': 'Nenhum canal carregado',
    },
  };

  static String tr(String key) {
    final lang = languageCode;
    final dict = _localizedValues[lang] ?? _localizedValues['es']!;
    return dict[key] ?? _localizedValues['es']![key] ?? key;
  }
}