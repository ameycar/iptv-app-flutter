import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UserCustomizationService {
  static const String _aliasesKey = 'custom_channel_aliases';
  static const String _colorKey = 'custom_accent_color';
  static const String _avatarKey = 'custom_user_avatar';

  static Future<Map<String, String>> getChannelAliases() async {
    final prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_aliasesKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final Map<String, dynamic> decoded = jsonDecode(raw);
      return decoded.map((key, value) => MapEntry(key, value.toString()));
    } catch (_) {
      return {};
    }
  }

  static Future<void> setChannelAlias(String channelId, String newName) async {
    final prefs = await SharedPreferences.getInstance();
    final aliases = await getChannelAliases();
    aliases[channelId] = newName;
    await prefs.setString(_aliasesKey, jsonEncode(aliases));
  }

  static Future<Color> getAccentColor() async {
    final prefs = await SharedPreferences.getInstance();
    final int? colorVal = prefs.getInt(_colorKey);
    return colorVal != null ? Color(colorVal) : const Color(0xFF00E5FF);
  }

  static Future<void> setAccentColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_colorKey, color.value);
  }

  static Future<String?> getUserAvatar() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_avatarKey);
  }

  static Future<void> setUserAvatar(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_avatarKey, url);
  }
}