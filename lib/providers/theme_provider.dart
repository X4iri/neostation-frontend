import 'package:neostation/services/logger_service.dart';
import 'package:flutter/material.dart';
import 'package:neostation/themes/app_themes.dart';
import 'package:neostation/repositories/config_repository.dart';

/// Provider responsible for managing the application's visual theme.
///
/// Supports static theme selection (Dark, Light, OLED, etc.) and a dynamic
/// 'System' mode that automatically synchronizes with the OS platform brightness.
/// Persists the selection to the local database.
class ThemeProvider extends ChangeNotifier with WidgetsBindingObserver {
  static final _log = LoggerService.instance;

  /// The current [ThemeData] being applied to the application.
  ThemeData _currentTheme =
      (WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark)
      ? AppThemes.darkTheme
      : AppThemes.lightTheme;

  /// Internal identifier for the current theme. Set to 'system' for dynamic mode.
  String _currentThemeName = 'system';

  /// Returns the appropriate [ThemeData] for the current selection.
  ///
  /// If in 'system' mode, it dynamically resolves the theme based on the
  /// current platform brightness.
  ThemeData get currentTheme {
    if (_currentThemeName == 'system') {
      final brightness =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
      return brightness == Brightness.dark
          ? availableThemes['dark']!
          : availableThemes['light']!;
    }

    return _currentTheme;
  }

  String get currentThemeName => _currentThemeName;

  /// Whether the current theme is specifically optimized for OLED displays (pure black).
  bool get isOled => _currentThemeName == 'oled';

  /// Registry of all available concrete themes.
  static final Map<String, ThemeData> availableThemes = {
    'dark': AppThemes.darkTheme,
    'light': AppThemes.lightTheme,
    'oled': AppThemes.oledTheme,
    'valentine': AppThemes.valentineTheme,
    'dracula': AppThemes.draculaTheme,
    'nord': AppThemes.nordTheme,
    'coffee': AppThemes.coffeeTheme,
    'tokyo_night': AppThemes.tokyoNightTheme,
    'retro': AppThemes.retroTheme,
    'abyss': AppThemes.abyssTheme,
    'cyberpunk': AppThemes.cyberpunkTheme,
    'aqua': AppThemes.aquaTheme,
    'palenight': AppThemes.palenightTheme,
    'horizon': AppThemes.horizonTheme,
  };

  /// Human-readable mapping for theme identifiers.
  static const Map<String, String> themeDisplayNames = {
    'system': 'System',
    'dark': 'Dark',
    'light': 'Light',
    'oled': 'OLED',
    'valentine': 'Valentine',
    'dracula': 'Dracula',
    'nord': 'Nord',
    'coffee': 'Coffee',
    'tokyo_night': 'Tokyo Night',
    'retro': 'Retro',
    'abyss': 'Abyss',
    'cyberpunk': 'Cyberpunk',
    'aqua': 'Aqua',
    'palenight': 'Palenight',
    'horizon': 'Horizon',
  };

  ThemeProvider() {
    _loadSavedTheme();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Reacts to OS-level brightness changes when in 'system' theme mode.
  @override
  void didChangePlatformBrightness() {
    if (_currentThemeName == 'system') {
      _log.i('Platform brightness changed, updating system theme...');
      _updateSystemTheme();
      notifyListeners();
    }
  }

  /// Internal logic to resolve the appropriate theme based on system brightness.
  void _updateSystemTheme() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    _currentTheme = brightness == Brightness.dark
        ? availableThemes['dark']!
        : availableThemes['light']!;
  }

  /// Loads the persisted theme name from the database and applies it.
  Future<void> _loadSavedTheme() async {
    try {
      final savedThemeName = await ConfigRepository.getThemeName();
      if (savedThemeName == 'system') {
        _currentThemeName = 'system';
        _updateSystemTheme();
        notifyListeners();
      } else if (availableThemes.containsKey(savedThemeName)) {
        _currentTheme = availableThemes[savedThemeName]!;
        _currentThemeName = savedThemeName;
        notifyListeners();
      } else {
        // The previously selected theme is no longer available (e.g. removed
        // in an update). Fall back to the system theme and persist it.
        _log.w(
          'Saved theme "$savedThemeName" is no longer available, falling back to system.',
        );
        _currentThemeName = 'system';
        _updateSystemTheme();
        await ConfigRepository.updateThemeName('system');
        notifyListeners();
      }
    } catch (e) {
      _log.e('Error loading saved theme: $e');
    }
  }

  /// Updates the application theme and persists the choice to the database.
  ///
  /// Special handling for the 'system' value to enable dynamic mode.
  Future<void> setTheme(String themeName) async {
    if (themeName == 'system') {
      _currentThemeName = 'system';
      _updateSystemTheme();

      try {
        await ConfigRepository.updateThemeName('system');
      } catch (e) {
        _log.e('Error saving theme: $e');
      }

      notifyListeners();
      return;
    }

    if (availableThemes.containsKey(themeName)) {
      _currentTheme = availableThemes[themeName]!;
      _currentThemeName = themeName;

      try {
        await ConfigRepository.updateThemeName(themeName);
      } catch (e) {
        _log.e('Error saving theme: $e');
      }

      notifyListeners();
    }
  }

  /// Returns a metadata list for all available themes, excluding the 'system' option.
  ///
  /// Used for populating theme selection UIs with display names and preview icons.
  List<Map<String, String>> getThemeList() {
    return availableThemes.keys.map((key) {
      return {'name': key, 'displayName': themeDisplayNames[key] ?? key};
    }).toList();
  }
}
