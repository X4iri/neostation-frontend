import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../l10n/app_locale.dart';
import '../../models/romm_platform.dart';
import '../../models/romm_rom.dart';
import '../../providers/file_provider.dart';
import '../../providers/romm_provider.dart';
import '../../providers/sqlite_config_provider.dart';
import '../../providers/sqlite_database_provider.dart';
import '../../services/game_service.dart';
import '../../services/romm_service.dart';
import '../../utils/gamepad_nav.dart';
import '../../widgets/custom_notification.dart';

/// Gamepad/touch-navigable browser for a connected RomM server.
///
/// Flow: source menu (Collections / Platforms) → platform/collection list →
/// ROM grid → per-ROM download. Downloads land in a configured ROM folder under
/// the mapped system subfolder, after which the normal scan indexes them so they
/// become launchable.
class RommBrowseScreen extends StatefulWidget {
  const RommBrowseScreen({super.key});

  @override
  State<RommBrowseScreen> createState() => _RommBrowseScreenState();
}

/// Which top-level list is showing when not drilled into a ROM grid.
enum _BrowseView { source, platforms, collections }

class _RommBrowseScreenState extends State<RommBrowseScreen> {
  final TextEditingController _searchController = TextEditingController();

  // The intermediate source menu sits ahead of the platform/collection lists.
  _BrowseView _view = _BrowseView.source;
  // Source-menu rows, in display order. Selecting one opens that list.
  static const List<_BrowseView> _sourceItems = [
    _BrowseView.collections,
    _BrowseView.platforms,
  ];
  int _sourceIndex = 0;
  int _collectionIndex = 0;

  // Captured in initState so they're usable from dispose() (context is defunct
  // by then). Both are app-level providers that outlive this screen.
  late final RommProvider _rommProvider;
  late final SqliteConfigProvider _configProvider;
  late final SqliteDatabaseProvider _dbProvider;

  // ── Gamepad navigation ──────────────────────────────────────────────────────
  late final GamepadNavigation _gamepadNav;
  // Selection index per phase (platform list vs. ROM grid). Highlight + the
  // confirm/back actions key off whichever phase is active.
  int _platformIndex = 0;
  int _romIndex = 0;
  // Column count of the ROM grid, recomputed each layout so GridNavUtils math
  // matches what's actually on screen.
  int _romColumns = 1;
  // Per-item keys so the selected tile can be scrolled into view.
  final Map<int, GlobalKey> _platformKeys = {};
  final Map<int, GlobalKey> _collectionKeys = {};
  final Map<int, GlobalKey> _romKeys = {};

  // The platform list is rebuilt from scratch each time we drill out of a
  // platform, so its scroll offset is restored explicitly via this controller.
  // A fixed item extent lets us jump to any index even when it isn't built yet.
  final ScrollController _platformScroll = ScrollController();
  final ScrollController _collectionScroll = ScrollController();
  final ScrollController _romScroll = ScrollController();
  double get _platformExtent => 84.r;

  // Grid geometry, recomputed in the ROM grid's LayoutBuilder. Used to scroll
  // the focused cell into view arithmetically — the lazy GridView doesn't build
  // off-screen cells, so a GlobalKey-based ensureVisible silently no-ops when
  // the selection jumps past the viewport (the focus box "disappears").
  double _romRowStride = 1;
  double _romCellHeight = 1;
  double _romTopPadding = 12;

  /// True while a platform or collection is open (i.e. the ROM grid is showing).
  bool get _inRomGrid =>
      _rommProvider.currentPlatform != null ||
      _rommProvider.currentCollection != null;

  @override
  void initState() {
    super.initState();
    _rommProvider = context.read<RommProvider>();
    _configProvider = context.read<SqliteConfigProvider>();
    _dbProvider = context.read<SqliteDatabaseProvider>();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: _confirmSelection,
      onBack: _handleBack,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'romm_browse_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
      if (_rommProvider.isConnected) {
        _rommProvider.loadPlatforms();
      }
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('romm_browse_screen');
    _gamepadNav.dispose();
    _platformScroll.dispose();
    _collectionScroll.dispose();
    _romScroll.dispose();
    _searchController.dispose();
    // After downloads: run the same full re-detect + scan the manual "Rescan
    // all folders" action uses (a per-system scan misses brand-new system
    // folders), then reload each affected system's in-memory game list so the
    // freshly imported metadata + covers actually show in the UI.
    final systems = _rommProvider.downloadedSystems;
    _rommProvider.clearDownloadedSystems();
    if (systems.isNotEmpty) {
      () async {
        await _configProvider.scanSystems();
        for (final system in systems) {
          await _dbProvider.refreshSystem(system.folderName);
        }
      }();
    }
    super.dispose();
  }

  Future<void> _startDownload(RommRom rom) async {
    final romFolders = context.read<SqliteConfigProvider>().config.romFolders;
    final result = await _rommProvider.downloadRom(
      rom,
      romFolders: romFolders,
      fileProvider: context.read<FileProvider>(),
    );

    if (!mounted) return;
    switch (result.status) {
      case RommDownloadStatus.completed:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadComplete.getString(context),
          type: NotificationType.success,
        );
        break;
      case RommDownloadStatus.cancelled:
        AppNotification.showNotification(
          context,
          AppLocale.rommDownloadCancelled.getString(context),
          type: NotificationType.info,
        );
        break;
      case RommDownloadStatus.failed:
        AppNotification.showNotification(
          context,
          _errorMessage(result.error),
          type: NotificationType.error,
        );
        break;
      case RommDownloadStatus.downloading:
        break;
    }
  }

  String _errorMessage(RommDownloadError error) {
    switch (error) {
      case RommDownloadError.noSystemMatch:
        return AppLocale.rommNoSystemMatch.getString(context);
      case RommDownloadError.noWritableFolder:
        return AppLocale.rommNoWritableFolder.getString(context);
      case RommDownloadError.network:
      case RommDownloadError.none:
        return AppLocale.rommDownloadFailed.getString(context);
    }
  }

  // ── Gamepad navigation handlers ─────────────────────────────────────────────

  void _navigateUp() {
    if (!_inRomGrid) {
      _moveListSelection(-1);
      return;
    }
    final n = _rommProvider.roms.length;
    if (n == 0) return;
    setState(
      () => _romIndex = GridNavUtils.navigateUp(
        currentIndex: _romIndex,
        crossAxisCount: _romColumns,
        maxItems: n,
      ),
    );
    _scrollRomTo(_romIndex);
  }

  void _navigateDown() {
    if (!_inRomGrid) {
      _moveListSelection(1);
      return;
    }
    final n = _rommProvider.roms.length;
    if (n == 0) return;
    final next = _romIndex + _romColumns;
    if (next < n) {
      setState(() => _romIndex = next);
    } else if (_rommProvider.romsHasMore && !_rommProvider.loadingRoms) {
      // At the last loaded row with more available: page in instead of wrapping.
      _rommProvider.loadMoreRoms();
    } else {
      setState(
        () => _romIndex = GridNavUtils.navigateDown(
          currentIndex: _romIndex,
          crossAxisCount: _romColumns,
          maxItems: n,
        ),
      );
    }
    _scrollRomTo(_romIndex);
    _maybeLoadMore();
  }

  void _navigateLeft() {
    if (!_inRomGrid) return;
    final n = _rommProvider.roms.length;
    if (n == 0) return;
    setState(
      () => _romIndex = GridNavUtils.navigateLeft(
        currentIndex: _romIndex,
        crossAxisCount: _romColumns,
        maxItems: n,
      ),
    );
    _scrollRomTo(_romIndex);
  }

  void _navigateRight() {
    if (!_inRomGrid) return;
    final n = _rommProvider.roms.length;
    if (n == 0) return;
    setState(
      () => _romIndex = GridNavUtils.navigateRight(
        currentIndex: _romIndex,
        crossAxisCount: _romColumns,
        maxItems: n,
      ),
    );
    _scrollRomTo(_romIndex);
    _maybeLoadMore();
  }

  /// Moves the selection by [delta] (wrapping) within whichever top-level list
  /// is showing, and scrolls it into view.
  void _moveListSelection(int delta) {
    switch (_view) {
      case _BrowseView.source:
        final n = _sourceItems.length;
        setState(() => _sourceIndex = (_sourceIndex + delta + n) % n);
        break;
      case _BrowseView.platforms:
        final n = _rommProvider.platforms.length;
        if (n == 0) return;
        setState(() => _platformIndex = (_platformIndex + delta + n) % n);
        _scrollListTo(_platformScroll, _platformIndex);
        break;
      case _BrowseView.collections:
        final n = _rommProvider.collections.length;
        if (n == 0) return;
        setState(() => _collectionIndex = (_collectionIndex + delta + n) % n);
        _scrollListTo(_collectionScroll, _collectionIndex);
        break;
    }
  }

  void _confirmSelection() {
    if (_inRomGrid) {
      final roms = _rommProvider.roms;
      if (roms.isEmpty || _romIndex >= roms.length) return;
      _startDownload(roms[_romIndex]);
      return;
    }
    switch (_view) {
      case _BrowseView.source:
        _openSource(_sourceItems[_sourceIndex]);
        break;
      case _BrowseView.platforms:
        final platforms = _rommProvider.platforms;
        if (platforms.isEmpty || _platformIndex >= platforms.length) return;
        _searchController.clear();
        setState(() => _romIndex = 0);
        _rommProvider.selectPlatform(platforms[_platformIndex]);
        break;
      case _BrowseView.collections:
        final collections = _rommProvider.collections;
        if (collections.isEmpty || _collectionIndex >= collections.length) {
          return;
        }
        _searchController.clear();
        setState(() => _romIndex = 0);
        _rommProvider.selectCollection(collections[_collectionIndex]);
        break;
    }
  }

  /// Opens one of the source-menu destinations, loading its data on demand.
  void _openSource(_BrowseView target) {
    setState(() => _view = target);
    if (target == _BrowseView.platforms) {
      _rommProvider.loadPlatforms();
    } else if (target == _BrowseView.collections) {
      _rommProvider.loadCollections();
    }
  }

  void _handleBack() {
    if (_inRomGrid) {
      _returnToList();
    } else if (_view != _BrowseView.source) {
      // From a platform/collection list, step back to the source menu.
      setState(() => _view = _BrowseView.source);
    } else {
      Navigator.of(context).maybePop();
    }
  }

  /// Drops back from the ROM grid to the list it was opened from, restoring that
  /// list's scroll to the drilled-into row (the list is rebuilt fresh, so the
  /// offset is set explicitly).
  void _returnToList() {
    final wasCollection = _rommProvider.currentCollection != null;
    _searchController.clear();
    setState(() {
      _romIndex = 0;
      _view = wasCollection ? _BrowseView.collections : _BrowseView.platforms;
    });
    _rommProvider.backToPlatforms();
    if (wasCollection) {
      _scrollListTo(_collectionScroll, _collectionIndex);
    } else {
      _scrollListTo(_platformScroll, _platformIndex);
    }
  }

  void _scrollListTo(ScrollController controller, int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!controller.hasClients) return;
      final pos = controller.position;
      final target =
          (index * _platformExtent) -
          (pos.viewportDimension - _platformExtent) / 2;
      pos.jumpTo(target.clamp(pos.minScrollExtent, pos.maxScrollExtent));
    });
  }

  /// Pages in more ROMs when the selection nears the end of the loaded set.
  void _maybeLoadMore() {
    final n = _rommProvider.roms.length;
    if (_rommProvider.romsHasMore &&
        !_rommProvider.loadingRoms &&
        _romIndex >= n - _romColumns * 2) {
      _rommProvider.loadMoreRoms();
    }
  }

  /// Scrolls the ROM grid so the focused cell's row is centred. Computed from
  /// grid geometry (not a GlobalKey) so it works even when the selection jumps
  /// to a not-yet-built off-screen cell during fast navigation.
  void _scrollRomTo(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_romScroll.hasClients) return;
      final pos = _romScroll.position;
      final row = index ~/ _romColumns;
      final target =
          _romTopPadding +
          row * _romRowStride -
          (pos.viewportDimension - _romCellHeight) / 2;
      pos.animateTo(
        target.clamp(pos.minScrollExtent, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();
    // Only the source menu exits the screen; deeper views step back one level.
    final atRoot = !_inRomGrid && _view == _BrowseView.source;

    return PopScope(
      canPop: atRoot,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Symbols.arrow_back_rounded),
            onPressed: _handleBack,
          ),
          title: Text(
            _appBarTitle(provider),
            style: TextStyle(fontSize: 16.r, fontWeight: FontWeight.bold),
          ),
        ),
        body: Builder(
          builder: (context) {
            if (!provider.isConnected) {
              return _centeredMessage(
                theme,
                Symbols.cloud_off_rounded,
                AppLocale.rommNotConnected.getString(context),
              );
            }
            if (_inRomGrid) {
              return _buildRomGrid(theme, provider);
            }
            switch (_view) {
              case _BrowseView.source:
                return _buildSourceMenu(theme);
              case _BrowseView.platforms:
                return _buildPlatformList(theme, provider);
              case _BrowseView.collections:
                return _buildCollectionList(theme, provider);
            }
          },
        ),
      ),
    );
  }

  String _appBarTitle(RommProvider provider) {
    if (_inRomGrid) {
      return provider.currentPlatform?.name ??
          provider.currentCollection?.name ??
          AppLocale.rommLibrary.getString(context);
    }
    switch (_view) {
      case _BrowseView.platforms:
        return AppLocale.rommPlatforms.getString(context);
      case _BrowseView.collections:
        return AppLocale.rommCollections.getString(context);
      case _BrowseView.source:
        return AppLocale.rommLibrary.getString(context);
    }
  }

  // ── Source menu ─────────────────────────────────────────────────────────────

  Widget _buildSourceMenu(ThemeData theme) {
    return ListView(
      padding: EdgeInsets.all(12.r),
      children: [
        for (var i = 0; i < _sourceItems.length; i++)
          _sourceTile(theme, i, _sourceItems[i]),
      ],
    );
  }

  Widget _sourceTile(ThemeData theme, int index, _BrowseView target) {
    final scheme = theme.colorScheme;
    final isFocused = _sourceIndex == index;
    final isCollections = target == _BrowseView.collections;
    return Container(
      margin: EdgeInsets.symmetric(vertical: 4.r),
      decoration: BoxDecoration(
        color: isFocused
            ? scheme.primary.withValues(alpha: 0.18)
            : scheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(
          color: isFocused ? scheme.primary : Colors.transparent,
          width: 2.r,
        ),
        boxShadow: isFocused
            ? [
                BoxShadow(
                  color: scheme.primary.withValues(alpha: 0.3),
                  blurRadius: 8.r,
                  spreadRadius: 1.r,
                ),
              ]
            : null,
      ),
      child: ListTile(
        leading: Icon(
          isCollections
              ? Symbols.collections_bookmark_rounded
              : Symbols.dashboard_rounded,
          color: scheme.primary,
          size: 28.r,
        ),
        title: Text(
          isCollections
              ? AppLocale.rommCollections.getString(context)
              : AppLocale.rommPlatforms.getString(context),
          style: TextStyle(fontSize: 14.r, fontWeight: FontWeight.w600),
        ),
        trailing: Icon(
          Symbols.chevron_right_rounded,
          color: isFocused ? scheme.primary : null,
        ),
        onTap: () {
          setState(() => _sourceIndex = index);
          _openSource(target);
        },
      ),
    );
  }

  // ── Collection list ─────────────────────────────────────────────────────────

  Widget _buildCollectionList(ThemeData theme, RommProvider provider) {
    if (provider.loadingCollections && provider.collections.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.collections.isEmpty) {
      return _centeredMessage(
        theme,
        Symbols.collections_bookmark_rounded,
        AppLocale.rommNoCollections.getString(context),
      );
    }
    _collectionIndex = _collectionIndex.clamp(
      0,
      provider.collections.length - 1,
    );
    final scheme = theme.colorScheme;
    return ListView.builder(
      controller: _collectionScroll,
      itemExtent: _platformExtent,
      padding: EdgeInsets.all(12.r),
      itemCount: provider.collections.length,
      itemBuilder: (context, index) {
        final collection = provider.collections[index];
        final isFocused = _collectionIndex == index;
        return Container(
          key: _collectionKeys.putIfAbsent(index, GlobalKey.new),
          margin: EdgeInsets.symmetric(vertical: 4.r),
          decoration: BoxDecoration(
            color: isFocused
                ? scheme.primary.withValues(alpha: 0.18)
                : scheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: isFocused ? scheme.primary : Colors.transparent,
              width: 2.r,
            ),
            boxShadow: isFocused
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.3),
                      blurRadius: 8.r,
                      spreadRadius: 1.r,
                    ),
                  ]
                : null,
          ),
          child: ListTile(
            leading: Container(
              width: 40.r,
              height: 40.r,
              decoration: BoxDecoration(
                color: scheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8.r),
              ),
              child: Icon(
                collection.isVirtual
                    ? Symbols.auto_awesome_motion_rounded
                    : Symbols.collections_bookmark_rounded,
                color: scheme.primary,
                size: 22.r,
              ),
            ),
            title: Text(
              collection.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13.r, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              '${collection.romCount}',
              style: TextStyle(fontSize: 10.r),
            ),
            trailing: Icon(
              Symbols.chevron_right_rounded,
              color: isFocused ? scheme.primary : null,
            ),
            onTap: () {
              _searchController.clear();
              setState(() {
                _collectionIndex = index;
                _romIndex = 0;
              });
              provider.selectCollection(collection);
            },
          ),
        );
      },
    );
  }

  Widget _centeredMessage(ThemeData theme, IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 48.r,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
          ),
          SizedBox(height: 12.r),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 32.r),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Platform list ───────────────────────────────────────────────────────────

  Widget _buildPlatformList(ThemeData theme, RommProvider provider) {
    if (provider.loadingPlatforms && provider.platforms.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.platforms.isEmpty) {
      return _centeredMessage(
        theme,
        Symbols.videogame_asset_off_rounded,
        AppLocale.rommNoPlatforms.getString(context),
      );
    }
    _platformIndex = _platformIndex.clamp(0, provider.platforms.length - 1);
    final scheme = theme.colorScheme;
    return ListView.builder(
      controller: _platformScroll,
      itemExtent: _platformExtent,
      padding: EdgeInsets.all(12.r),
      itemCount: provider.platforms.length,
      itemBuilder: (context, index) {
        final platform = provider.platforms[index];
        final isFocused = _platformIndex == index;
        return Container(
          key: _platformKeys.putIfAbsent(index, GlobalKey.new),
          margin: EdgeInsets.symmetric(vertical: 4.r),
          decoration: BoxDecoration(
            color: isFocused
                ? scheme.primary.withValues(alpha: 0.18)
                : scheme.surface.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(12.r),
            border: Border.all(
              color: isFocused ? scheme.primary : Colors.transparent,
              width: 2.r,
            ),
            boxShadow: isFocused
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.3),
                      blurRadius: 8.r,
                      spreadRadius: 1.r,
                    ),
                  ]
                : null,
          ),
          child: ListTile(
            leading: _PlatformIcon(
              platform: platform,
              service: provider.service,
            ),
            title: Text(
              platform.name,
              style: TextStyle(fontSize: 13.r, fontWeight: FontWeight.w500),
            ),
            subtitle: Text(
              '${platform.romCount}',
              style: TextStyle(fontSize: 10.r),
            ),
            trailing: Icon(
              Symbols.chevron_right_rounded,
              color: isFocused ? scheme.primary : null,
            ),
            onTap: () {
              _searchController.clear();
              setState(() {
                _platformIndex = index;
                _romIndex = 0;
              });
              provider.selectPlatform(platform);
            },
          ),
        );
      },
    );
  }

  // ── ROM grid ────────────────────────────────────────────────────────────────

  Widget _buildRomGrid(ThemeData theme, RommProvider provider) {
    return Column(
      children: [
        _buildSearchBar(theme, provider),
        Expanded(child: _buildRomGridBody(theme, provider)),
      ],
    );
  }

  Widget _buildSearchBar(ThemeData theme, RommProvider provider) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 8.r),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 36.r,
              child: TextField(
                controller: _searchController,
                style: TextStyle(fontSize: 12.r),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: AppLocale.rommSearch.getString(context),
                  hintStyle: TextStyle(fontSize: 11.r),
                  prefixIcon: Icon(Symbols.search_rounded, size: 18.r),
                  filled: true,
                  fillColor: theme.colorScheme.onSurface.withValues(
                    alpha: 0.05,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8.r),
                    borderSide: BorderSide.none,
                  ),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (value) => provider.searchRoms(value),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRomGridBody(ThemeData theme, RommProvider provider) {
    if (provider.loadingRoms && provider.roms.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (provider.roms.isEmpty) {
      return _centeredMessage(
        theme,
        Symbols.search_off_rounded,
        AppLocale.rommNoRoms.getString(context),
      );
    }

    final romFolders = context.watch<SqliteConfigProvider>().config.romFolders;
    _romIndex = _romIndex.clamp(0, provider.roms.length - 1);

    const cellExtent = 140.0;
    final spacing = 10.r;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Derive the real column count so GridNavUtils moves the selection by
        // exactly one visual row/column.
        final usableWidth =
            constraints.maxWidth - 24.r; // 12.r padding each side
        _romColumns = ((usableWidth + spacing) / (cellExtent.r + spacing))
            .floor()
            .clamp(1, 99);

        // Cache geometry for arithmetic scroll-into-view (see _scrollRomTo).
        final cellWidth =
            (usableWidth - (_romColumns - 1) * spacing) / _romColumns;
        _romCellHeight = cellWidth / 0.62; // childAspectRatio
        _romRowStride = _romCellHeight + spacing; // mainAxisSpacing
        _romTopPadding = 12.r;

        return NotificationListener<ScrollNotification>(
          onNotification: (scroll) {
            if (scroll.metrics.pixels >=
                    scroll.metrics.maxScrollExtent - 200.r &&
                provider.romsHasMore &&
                !provider.loadingRoms) {
              provider.loadMoreRoms();
            }
            return false;
          },
          child: GridView.builder(
            controller: _romScroll,
            padding: EdgeInsets.all(12.r),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: _romColumns,
              childAspectRatio: 0.62,
              crossAxisSpacing: spacing,
              mainAxisSpacing: spacing,
            ),
            itemCount: provider.roms.length,
            itemBuilder: (context, index) {
              final rom = provider.roms[index];
              return _RomCard(
                key: _romKeys.putIfAbsent(index, GlobalKey.new),
                rom: rom,
                provider: provider,
                romFolders: romFolders,
                isFocused: _romIndex == index,
                onDownload: () => _startDownload(rom),
                onCancel: () => provider.cancelDownload(rom.id),
                onTap: () => setState(() => _romIndex = index),
              );
            },
          ),
        );
      },
    );
  }
}

/// A single ROM tile: cover art, name, and a download/progress/done control.
class _RomCard extends StatefulWidget {
  final RommRom rom;
  final RommProvider provider;
  final List<String> romFolders;
  final bool isFocused;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onTap;

  const _RomCard({
    super.key,
    required this.rom,
    required this.provider,
    required this.romFolders,
    required this.isFocused,
    required this.onDownload,
    required this.onCancel,
    required this.onTap,
  });

  @override
  State<_RomCard> createState() => _RomCardState();
}

class _RomCardState extends State<_RomCard> {
  bool _alreadyDownloaded = false;

  @override
  void initState() {
    super.initState();
    _checkDownloaded();
  }

  Future<void> _checkDownloaded() async {
    final exists = await widget.provider.isDownloaded(
      widget.rom,
      widget.romFolders,
    );
    if (mounted && exists != _alreadyDownloaded) {
      setState(() => _alreadyDownloaded = exists);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final coverUrl = widget.provider.service.coverUrl(widget.rom);
    final download = widget.provider.downloadFor(widget.rom.id);

    final scheme = theme.colorScheme;
    return GestureDetector(
      onTap: widget.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8.r),
                border: Border.all(
                  color: widget.isFocused ? scheme.primary : Colors.transparent,
                  width: 2.r,
                ),
                boxShadow: widget.isFocused
                    ? [
                        BoxShadow(
                          color: scheme.primary.withValues(alpha: 0.3),
                          blurRadius: 8.r,
                          spreadRadius: 1.r,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6.r),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _buildCover(theme, coverUrl),
                    if (widget.rom.hasRetroAchievements) _buildRaBadge(),
                    _buildOverlay(theme, download),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: 4.r),
          Text(
            widget.rom.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 10.r,
              fontWeight: widget.isFocused
                  ? FontWeight.w700
                  : FontWeight.normal,
              color: widget.isFocused ? scheme.primary : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCover(ThemeData theme, String? coverUrl) {
    if (coverUrl == null) {
      return _coverPlaceholder(theme);
    }
    return Image.network(
      coverUrl,
      fit: BoxFit.cover,
      headers: widget.provider.service.imageHeadersFor(coverUrl),
      errorBuilder: (_, _, _) => _coverPlaceholder(theme),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return _coverPlaceholder(theme);
      },
    );
  }

  Widget _coverPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surface,
      child: Center(
        child: Icon(
          Symbols.videogame_asset_rounded,
          size: 28.r,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.3),
        ),
      ),
    );
  }

  /// Top-left badge showing the ROM has RetroAchievements and, when RomM has
  /// synced the user's progression, their earned/total count. The download
  /// badge owns the bottom-right corner, so this sits top-left.
  Widget _buildRaBadge() {
    final rom = widget.rom;
    final earned = widget.provider.raEarnedFor(rom);
    final total = rom.raTotalAchievements;
    final hasProgress = earned != null;
    final label = hasProgress ? '$earned/$total' : '$total';

    return Positioned.fill(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.all(4.r),
          child: Semantics(
            label: hasProgress
                ? 'RetroAchievements: $earned of $total earned'
                : 'RetroAchievements: $total achievements',
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 6.r, vertical: 3.r),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.82),
                borderRadius: BorderRadius.circular(10.r),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Symbols.emoji_events_rounded,
                    size: 14.r,
                    // Dim the trophy when progress isn't synced.
                    color: Colors.orangeAccent.withValues(
                      alpha: hasProgress ? 1.0 : 0.6,
                    ),
                  ),
                  SizedBox(width: 3.r),
                  Text(
                    label,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10.r,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOverlay(ThemeData theme, RommDownload? download) {
    // Active download: progress + cancel.
    if (download != null && download.status == RommDownloadStatus.downloading) {
      return Container(
        color: Colors.black.withValues(alpha: 0.55),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 28.r,
                height: 28.r,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5.r,
                  value: download.fraction,
                  color: theme.colorScheme.primary,
                ),
              ),
              SizedBox(height: 6.r),
              GestureDetector(
                onTap: widget.onCancel,
                child: Icon(
                  Symbols.close_rounded,
                  size: 18.r,
                  color: Colors.white,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isDone =
        _alreadyDownloaded ||
        (download != null && download.status == RommDownloadStatus.completed);

    return Positioned.fill(
      child: Align(
        alignment: Alignment.bottomRight,
        child: Padding(
          padding: EdgeInsets.all(4.r),
          child: GestureDetector(
            onTap: isDone
                ? null
                : () {
                    widget.onDownload();
                    // Re-check presence shortly after a completed download.
                    Future.delayed(
                      const Duration(seconds: 1),
                      _checkDownloaded,
                    );
                  },
            child: Container(
              padding: EdgeInsets.all(5.r),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isDone
                    ? Symbols.check_circle_rounded
                    : Symbols.download_rounded,
                size: 18.r,
                color: isDone ? Colors.greenAccent : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Platform list-tile icon: RomM's bundled SVG when available, falling back to
/// the IGDB raster logo, then a generic gamepad icon. Fetched SVGs are cached
/// process-wide so scrolling/rebuilds don't refetch.
class _PlatformIcon extends StatefulWidget {
  final RommPlatform platform;
  final RommService service;

  const _PlatformIcon({required this.platform, required this.service});

  @override
  State<_PlatformIcon> createState() => _PlatformIconState();
}

class _PlatformIconState extends State<_PlatformIcon> {
  static final Map<String, String?> _svgCache = {};

  String? _svg;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = widget.service.platformIconUrl(widget.platform);
    if (_svgCache.containsKey(url)) {
      setState(() {
        _svg = _svgCache[url];
        _loaded = true;
      });
      return;
    }
    final svg = await widget.service.fetchSvg(url);
    _svgCache[url] = svg;
    if (!mounted) return;
    setState(() {
      _svg = svg;
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fallback = Icon(
      Symbols.sports_esports_rounded,
      color: theme.colorScheme.primary,
    );

    if (_svg != null) {
      // RomM's platform icons are full-colour illustrations (their <style> class
      // fills are inlined in RommService.fetchSvg). Render the art as-is, with
      // no white backing, so it sits cleanly on the dark UI.
      return _frame(SvgPicture.string(_svg!, fit: BoxFit.contain));
    }

    // No SVG (yet or 404): try the IGDB raster logo before the generic icon.
    final logoUrl = widget.service.platformLogoUrl(widget.platform);
    if (_loaded && logoUrl != null) {
      return _frame(
        Image.network(
          logoUrl,
          fit: BoxFit.contain,
          headers: widget.service.imageHeadersFor(logoUrl),
          errorBuilder: (_, _, _) => fallback,
          loadingBuilder: (context, child, progress) =>
              progress == null ? child : fallback,
        ),
      );
    }

    return fallback;
  }

  /// Frames an icon at a consistent size with no background — the artwork
  /// (colour SVG or logo) carries its own colours on the dark surface.
  Widget _frame(Widget child) {
    return SizedBox(width: 40.r, height: 40.r, child: child);
  }
}
