import 'package:flutter/material.dart';
import 'package:neostation/models/installed_app_model.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

class InstalledAppsProvider extends ChangeNotifier with WidgetsBindingObserver {
  static final _log = LoggerService.instance;

  List<InstalledAppModel> _apps = [];
  bool _isLoading = false;
  Set<String> _favorites = {};

  List<InstalledAppModel> get apps => _apps;
  bool get isLoading => _isLoading;

  InstalledAppsProvider() {
    WidgetsBinding.instance.addObserver(this);
    loadApps();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _log.i('InstalledAppsProvider: App resumed, refreshing app list');
      loadApps();
    }
  }

  Future<void> loadApps() async {
    _isLoading = true;
    notifyListeners();

    try {
      _favorites = await SqliteService.getAppFavorites();
      final List<Map<String, dynamic>> rawApps =
          await AndroidService.getInstalledApps(includeIcons: true);

      _apps = rawApps.map((map) {
        final pkg = map['package']?.toString() ?? '';
        return InstalledAppModel.fromMap(
          map,
          isFavorite: _favorites.contains(pkg),
        );
      }).toList();

      _sortApps();
    } catch (e) {
      _log.e('Error loading installed apps: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void _sortApps() {
    // Sort by favorite status first, then by name
    _apps.sort((a, b) {
      if (a.isFavorite && !b.isFavorite) return -1;
      if (!a.isFavorite && b.isFavorite) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  Future<void> toggleFavorite(String packageName) async {
    final isFav = _favorites.contains(packageName);
    await SqliteService.setAppFavorite(packageName, !isFav);

    if (isFav) {
      _favorites.remove(packageName);
    } else {
      _favorites.add(packageName);
    }

    // Update local list
    final index = _apps.indexWhere((a) => a.packageName == packageName);
    if (index != -1) {
      _apps[index] = _apps[index].copyWith(isFavorite: !isFav);
      _sortApps();
      notifyListeners();
    }
  }

  bool isFavorite(String packageName) => _favorites.contains(packageName);
}
