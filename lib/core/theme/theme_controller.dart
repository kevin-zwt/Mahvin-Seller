import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Holds the selected theme mode and persists it to storage.
///
/// The UI never touches SharedPreferences directly — it listens to [mode]
/// and calls [setDark] / [toggle].
class ThemeController {
  ThemeController(this._prefs) : _mode = ValueNotifier(_read(_prefs));

  static const _key = 'themeMode';

  final SharedPreferences _prefs;
  final ValueNotifier<ThemeMode> _mode;

  /// Listenable used by `MaterialApp.themeMode`.
  ValueListenable<ThemeMode> get mode => _mode;

  bool get isDark => _mode.value == ThemeMode.dark;

  static ThemeMode _read(SharedPreferences prefs) =>
      prefs.getString(_key) == 'dark' ? ThemeMode.dark : ThemeMode.light;

  Future<void> setDark(bool dark) async {
    _mode.value = dark ? ThemeMode.dark : ThemeMode.light;
    await _prefs.setString(_key, dark ? 'dark' : 'light');
  }

  Future<void> toggle() => setDark(!isDark);
}
