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
import '../../services/romm_service.dart';
import '../../widgets/custom_notification.dart';

/// Gamepad/touch-navigable browser for a connected RomM server.
///
/// Flow: platform list → ROM grid → per-ROM download. Downloads land in a
/// configured ROM folder under the mapped system subfolder, after which the
/// normal scan indexes them so they become launchable.
class RommBrowseScreen extends StatefulWidget {
  const RommBrowseScreen({super.key});

  @override
  State<RommBrowseScreen> createState() => _RommBrowseScreenState();
}

class _RommBrowseScreenState extends State<RommBrowseScreen> {
  final TextEditingController _searchController = TextEditingController();

  // Captured in initState so they're usable from dispose() (context is defunct
  // by then). Both are app-level providers that outlive this screen.
  late final RommProvider _rommProvider;
  late final SqliteConfigProvider _configProvider;
  late final SqliteDatabaseProvider _dbProvider;

  @override
  void initState() {
    super.initState();
    _rommProvider = context.read<RommProvider>();
    _configProvider = context.read<SqliteConfigProvider>();
    _dbProvider = context.read<SqliteDatabaseProvider>();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_rommProvider.isConnected) {
        _rommProvider.loadPlatforms();
      }
    });
  }

  @override
  void dispose() {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();
    // While a platform is open, "back" drills out to the platform list rather
    // than popping the whole screen; only the platform list exits to settings.
    final atPlatformList = provider.currentPlatform == null;

    return PopScope(
      canPop: atPlatformList,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) provider.backToPlatforms();
      },
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Symbols.arrow_back_rounded),
            onPressed: () {
              if (provider.currentPlatform != null) {
                provider.backToPlatforms();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          title: Text(
            provider.currentPlatform?.name ??
                AppLocale.rommLibrary.getString(context),
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
            if (provider.currentPlatform == null) {
              return _buildPlatformList(theme, provider);
            }
            return _buildRomGrid(theme, provider);
          },
        ),
      ),
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
    return ListView.builder(
      padding: EdgeInsets.all(12.r),
      itemCount: provider.platforms.length,
      itemBuilder: (context, index) {
        final platform = provider.platforms[index];
        return Card(
          color: theme.colorScheme.surface.withValues(alpha: 0.5),
          margin: EdgeInsets.symmetric(vertical: 4.r),
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
            trailing: const Icon(Symbols.chevron_right_rounded),
            onTap: () {
              _searchController.clear();
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

    return NotificationListener<ScrollNotification>(
      onNotification: (scroll) {
        if (scroll.metrics.pixels >= scroll.metrics.maxScrollExtent - 200.r &&
            provider.romsHasMore &&
            !provider.loadingRoms) {
          provider.loadMoreRoms();
        }
        return false;
      },
      child: GridView.builder(
        padding: EdgeInsets.all(12.r),
        gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140.r,
          childAspectRatio: 0.62,
          crossAxisSpacing: 10.r,
          mainAxisSpacing: 10.r,
        ),
        itemCount: provider.roms.length,
        itemBuilder: (context, index) {
          final rom = provider.roms[index];
          return _RomCard(
            rom: rom,
            provider: provider,
            romFolders: romFolders,
            onDownload: () => _startDownload(rom),
            onCancel: () => provider.cancelDownload(rom.id),
          );
        },
      ),
    );
  }
}

/// A single ROM tile: cover art, name, and a download/progress/done control.
class _RomCard extends StatefulWidget {
  final RommRom rom;
  final RommProvider provider;
  final List<String> romFolders;
  final VoidCallback onDownload;
  final VoidCallback onCancel;

  const _RomCard({
    required this.rom,
    required this.provider,
    required this.romFolders,
    required this.onDownload,
    required this.onCancel,
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6.r),
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildCover(theme, coverUrl),
                _buildOverlay(theme, download),
              ],
            ),
          ),
        ),
        SizedBox(height: 4.r),
        Text(
          widget.rom.name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 10.r, color: theme.colorScheme.onSurface),
        ),
      ],
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
      // RomM's icons use dark fills meant for a light backing, so render them
      // on a light chip to stay visible on the dark UI.
      return _chip(SvgPicture.string(_svg!, fit: BoxFit.contain));
    }

    // No SVG (yet or 404): try the IGDB raster logo before the generic icon.
    final logoUrl = widget.service.platformLogoUrl(widget.platform);
    if (_loaded && logoUrl != null) {
      return _chip(
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

  Widget _chip(Widget child) {
    return Container(
      width: 40.r,
      height: 40.r,
      padding: EdgeInsets.all(4.r),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8.r),
      ),
      child: child,
    );
  }
}
