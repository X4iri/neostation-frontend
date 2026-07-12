import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/romm_collection.dart';
import '../models/romm_platform.dart';
import '../models/romm_rom.dart';
import '../models/system_model.dart';
import '../repositories/romm_repository.dart';
import '../repositories/romm_save_map_repository.dart';
import '../repositories/scraper_repository.dart';
import '../repositories/system_repository.dart';
import '../services/logger_service.dart';
import '../services/romm_service.dart';
import 'file_provider.dart';

/// High-level connection state for the RomM integration.
enum RommConnectionStatus { disconnected, connecting, connected, error }

/// Per-ROM download lifecycle state.
enum RommDownloadStatus { downloading, completed, failed, cancelled }

/// Why a download could not proceed/complete (UI maps these to localized text).
enum RommDownloadError { none, noSystemMatch, noWritableFolder, network }

/// Tracks an in-flight or finished download for a single ROM.
class RommDownload {
  final int romId;
  RommDownloadStatus status;
  int received;
  int? total;
  RommDownloadError error;
  String? errorDetail;
  bool cancelRequested;

  RommDownload({
    required this.romId,
    this.status = RommDownloadStatus.downloading,
    this.received = 0,
    this.total,
    this.error = RommDownloadError.none,
    this.errorDetail,
    this.cancelRequested = false,
  });

  double? get fraction =>
      (total != null && total! > 0) ? received / total! : null;
}

/// State for browsing a remote RomM library and downloading ROMs locally.
///
/// Owns a single [RommService] connection. After a successful download it asks
/// the caller (via a supplied callback) to rescan the target system so the new
/// ROM is indexed by the normal pipeline and becomes launchable.
class RommProvider extends ChangeNotifier {
  static final _log = LoggerService.instance;

  final RommService _service = RommService();

  RommConnectionStatus _status = RommConnectionStatus.disconnected;
  String? _lastError;

  String _serverUrl = '';
  String _username = '';

  List<RommPlatform> _platforms = [];
  bool _loadingPlatforms = false;

  List<RommCollection> _collections = [];
  bool _loadingCollections = false;

  RommPlatform? _currentPlatform;
  RommCollection? _currentCollection;
  List<RommRom> _roms = [];
  bool _loadingRoms = false;
  bool _romsHasMore = false;
  int _romsOffset = 0;
  String _searchTerm = '';
  static const int _pageSize = 50;

  final Map<int, RommDownload> _downloads = {};

  /// Invoked (debounced) after downloads settle so freshly downloaded ROMs get
  /// indexed and the affected systems' game lists refreshed. Wired in main.dart
  /// to the config/database providers; receives the systems whose downloads
  /// completed since the last settle.
  Future<void> Function(List<SystemModel> systems)? onDownloadsSettled;

  Timer? _settleTimer;
  bool _settling = false;
  static const Duration _settleDebounce = Duration(seconds: 2);

  /// Current user's RetroAchievements progress: RA game id → earned count.
  /// Loaded best-effort from `/api/users/me`; empty when RA isn't linked.
  Map<int, int> _raEarnedByGameId = {};

  /// Systems that received at least one successful download this session, keyed
  /// by folder name. Used to refresh the library when the browse screen closes.
  final Map<String, SystemModel> _downloadedSystems = {};

  // ── Getters ────────────────────────────────────────────────────────────────
  RommConnectionStatus get status => _status;
  bool get isConnected => _status == RommConnectionStatus.connected;
  String? get lastError => _lastError;
  String get serverUrl => _serverUrl;
  String get username => _username;

  List<RommPlatform> get platforms => List.unmodifiable(_platforms);
  bool get loadingPlatforms => _loadingPlatforms;

  List<RommCollection> get collections => List.unmodifiable(_collections);
  bool get loadingCollections => _loadingCollections;

  RommPlatform? get currentPlatform => _currentPlatform;
  RommCollection? get currentCollection => _currentCollection;
  List<RommRom> get roms => List.unmodifiable(_roms);
  bool get loadingRoms => _loadingRoms;
  bool get romsHasMore => _romsHasMore;
  String get searchTerm => _searchTerm;

  RommService get service => _service;
  Map<int, RommDownload> get downloads => Map.unmodifiable(_downloads);
  RommDownload? downloadFor(int romId) => _downloads[romId];

  /// The user's earned achievement count for [rom], or null when the game has
  /// no RA set or the user's RA progress hasn't been synced in RomM.
  int? raEarnedFor(RommRom rom) {
    final id = rom.raId;
    if (id == null) return null;
    return _raEarnedByGameId[id];
  }

  /// Systems that received a successful download this session (for an on-exit
  /// library refresh).
  List<SystemModel> get downloadedSystems =>
      _downloadedSystems.values.toList(growable: false);
  void clearDownloadedSystems() => _downloadedSystems.clear();

  /// (Re)arms the debounced settle. Called on each completed download so a
  /// burst of completions coalesces into a single rescan a short quiet period
  /// after the last one, instead of scanning per ROM or waiting for the whole
  /// batch. Fires independently of the browse screen's lifecycle.
  void _scheduleSettle() {
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDebounce, _runSettle);
  }

  Future<void> _runSettle() async {
    final handler = onDownloadsSettled;
    if (handler == null) return;
    // Serialize: if a settle is already scanning, re-arm and let it finish so a
    // long batch never overlaps scans — completions accumulate and get picked
    // up by the next run.
    if (_settling) {
      _scheduleSettle();
      return;
    }
    final systems = downloadedSystems;
    if (systems.isEmpty) return;
    clearDownloadedSystems();
    _settling = true;
    try {
      await handler(systems);
    } finally {
      _settling = false;
    }
  }

  /// Known IGDB-style RomM slug → NeoStation folder name mismatches. Tried after
  /// direct slug/fs_slug lookups, which already cover the matching majority.
  static const Map<String, String> _slugAliases = {
    'ps': 'ps1',
    'psx': 'ps1',
    'playstation': 'ps1',
    'genesis-slash-megadrive': 'genesis',
    'sega-mega-drive-slash-genesis': 'genesis',
    'sega-master-system-slash-mark-iii': 'sms',
    'sega-master-system': 'sms',
    'turbografx16--1': 'tg16',
    'turbografx-16-slash-pc-engine-cd': 'pccd',
    'atari2600': '2600',
    'atari-2600': '2600',
    'atari5200': '5200',
    'atari7800': '7800',
    'wonderswan-color': 'wsc',
    'wonderswan': 'ws',
    'neo-geo-pocket-color': 'ngpc',
    'neo-geo-pocket': 'ngp',
    'virtualboy': 'vb',
    'virtual-boy': 'vb',
    'sega32x': '32x',
    'sega-32x': '32x',
    'segacd': 'scd',
    'sega-cd': 'scd',
    'gamegear': 'gg',
    'sega-game-gear': 'gg',
    'arcade': 'mame',
    'commodore-c64-slash-128-slash-max': 'c64',
    'dreamcast': 'dc',
    'super-famicom': 'sfc',
  };

  // ── Lifecycle / connection ──────────────────────────────────────────────────

  /// Loads any persisted credentials/tokens and configures the service.
  /// Does not hit the network; status becomes [connected] when a config exists.
  Future<void> initialize() async {
    try {
      final config = await RommRepository.getConfig();
      if (config == null) {
        _status = RommConnectionStatus.disconnected;
        notifyListeners();
        return;
      }
      _serverUrl = config['server_url'] as String;
      _username = config['username'] as String? ?? '';
      _service.configure(
        serverUrl: _serverUrl,
        username: _username,
        password: config['password'] as String? ?? '',
        accessToken: config['access_token'] as String?,
        refreshToken: config['refresh_token'] as String?,
        tokenExpiresMs: config['token_expires'] as int?,
      );
      _status = RommConnectionStatus.connected;
      notifyListeners();
    } catch (e) {
      _log.e('RomM initialize failed: $e');
      _status = RommConnectionStatus.disconnected;
      notifyListeners();
    }
  }

  /// Validates credentials against the server without persisting them.
  /// Returns null on success, or a user-facing error message.
  Future<String?> testConnection({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final probe = RommService()
      ..configure(serverUrl: serverUrl, username: username, password: password);
    try {
      await probe.verifyConnection();
      return null;
    } on RommException catch (e) {
      return e.message;
    } catch (e) {
      return 'Connection failed: $e';
    }
  }

  /// Authenticates, persists credentials + tokens, and marks the provider
  /// connected. Returns null on success or a user-facing error message.
  Future<String?> connect({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    _status = RommConnectionStatus.connecting;
    _lastError = null;
    notifyListeners();

    _service.configure(
      serverUrl: serverUrl,
      username: username,
      password: password,
    );
    try {
      await _service.authenticate();
    } on RommException catch (e) {
      _status = RommConnectionStatus.error;
      _lastError = e.message;
      notifyListeners();
      return e.message;
    } catch (e) {
      _status = RommConnectionStatus.error;
      _lastError = 'Connection failed: $e';
      notifyListeners();
      return _lastError;
    }

    await RommRepository.saveConfig(
      serverUrl: _service.baseUrl,
      username: username,
      password: password,
    );
    await RommRepository.saveTokens(
      accessToken: _service.accessToken!,
      refreshToken: _service.refreshToken,
      tokenExpires: _service.tokenExpiresMs,
    );

    _serverUrl = _service.baseUrl;
    _username = username;
    _status = RommConnectionStatus.connected;
    notifyListeners();
    return null;
  }

  /// Clears stored credentials and resets all browse state.
  Future<void> disconnect() async {
    await RommRepository.clearConfig();
    _status = RommConnectionStatus.disconnected;
    _lastError = null;
    _serverUrl = '';
    _username = '';
    _platforms = [];
    _collections = [];
    _currentPlatform = null;
    _currentCollection = null;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    _searchTerm = '';
    _downloads.clear();
    _raEarnedByGameId = {};
    _downloadedSystems.clear();
    notifyListeners();
  }

  // ── Browsing ────────────────────────────────────────────────────────────────

  /// Loads (and caches) the platform list. Pass [force] to refetch.
  Future<void> loadPlatforms({bool force = false}) async {
    if (_loadingPlatforms) return;
    if (_platforms.isNotEmpty && !force) return;
    _loadingPlatforms = true;
    _lastError = null;
    notifyListeners();
    try {
      _platforms = await _service.getPlatforms();
      // Persist any refreshed token so it survives restarts.
      await _persistRefreshedTokens();
      // RA progress is supplementary; never let it block platform browsing.
      await _loadRaProgression();
    } on RommException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = 'Failed to load platforms: $e';
    } finally {
      _loadingPlatforms = false;
      notifyListeners();
    }
  }

  /// Loads (and caches) the collection list (user + virtual). Pass [force] to
  /// refetch. Virtual collections are best-effort: if that endpoint fails the
  /// user collections are still returned.
  Future<void> loadCollections({bool force = false}) async {
    if (_loadingCollections) return;
    if (_collections.isNotEmpty && !force) return;
    _loadingCollections = true;
    _lastError = null;
    notifyListeners();
    try {
      final user = await _service.getCollections();
      var virtual = const <RommCollection>[];
      try {
        virtual = await _service.getVirtualCollections();
      } catch (e) {
        // Virtual collections are optional; a server-side failure here must not
        // hide the user's own collections.
        _log.w('RomM virtual collections unavailable: $e');
      }
      _collections = [...user, ...virtual];
      await _persistRefreshedTokens();
    } on RommException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = 'Failed to load collections: $e';
    } finally {
      _loadingCollections = false;
      notifyListeners();
    }
  }

  /// Selects a platform and loads its first page of ROMs.
  Future<void> selectPlatform(
    RommPlatform platform, {
    String search = '',
  }) async {
    _currentCollection = null;
    _currentPlatform = platform;
    _searchTerm = search;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    notifyListeners();
    await loadMoreRoms();
  }

  /// Selects a collection and loads its first page of ROMs.
  Future<void> selectCollection(
    RommCollection collection, {
    String search = '',
  }) async {
    _currentPlatform = null;
    _currentCollection = collection;
    _searchTerm = search;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    notifyListeners();
    await loadMoreRoms();
  }

  /// Re-runs the current platform/collection query with a new search term.
  Future<void> searchRoms(String term) async {
    if (_currentCollection != null) {
      await selectCollection(_currentCollection!, search: term);
    } else if (_currentPlatform != null) {
      await selectPlatform(_currentPlatform!, search: term);
    }
  }

  /// Returns to the platform/collection list (the in-screen / system back
  /// action), clearing whichever browse target is active.
  void backToPlatforms() {
    _currentPlatform = null;
    _currentCollection = null;
    _roms = [];
    _romsOffset = 0;
    _romsHasMore = false;
    _searchTerm = '';
    notifyListeners();
  }

  /// Loads the next page of ROMs for the current platform or collection.
  Future<void> loadMoreRoms() async {
    final platform = _currentPlatform;
    final collection = _currentCollection;
    if ((platform == null && collection == null) || _loadingRoms) return;
    _loadingRoms = true;
    _lastError = null;
    notifyListeners();
    try {
      final page = await _service.getRoms(
        platformId: platform?.id,
        collectionId: (collection != null && !collection.isVirtual)
            ? int.tryParse(collection.id)
            : null,
        virtualCollectionId: (collection != null && collection.isVirtual)
            ? collection.id
            : null,
        search: _searchTerm,
        limit: _pageSize,
        offset: _romsOffset,
      );
      _roms = [..._roms, ...page];
      _romsOffset += page.length;
      _romsHasMore = page.length >= _pageSize;
      await _persistRefreshedTokens();
    } on RommException catch (e) {
      _lastError = e.message;
    } catch (e) {
      _lastError = 'Failed to load ROMs: $e';
    } finally {
      _loadingRoms = false;
      notifyListeners();
    }
  }

  // ── System mapping / destination ────────────────────────────────────────────

  /// Resolves the local [SystemModel] for a RomM ROM, or null if none matches.
  Future<SystemModel?> resolveSystem(RommRom rom) async {
    final candidates = <String>[
      rom.platformSlug,
      _slugAliases[rom.platformSlug] ?? '',
    ];
    final platform = _platformFor(rom);
    if (platform != null) {
      candidates
        ..add(platform.slug)
        ..add(platform.fsSlug ?? '')
        ..add(_slugAliases[platform.slug] ?? '');
    }
    for (final c in candidates) {
      if (c.isEmpty) continue;
      final sys = await SystemRepository.getSystemByFolderName(c);
      if (sys != null) return sys;
    }
    return null;
  }

  RommPlatform? _platformFor(RommRom rom) {
    for (final platform in _platforms) {
      if (platform.id == rom.platformId) return platform;
    }
    return null;
  }

  /// Resolves a configured ROM folder to a real filesystem base path.
  ///
  /// Plain paths are returned as-is. Android's folder picker stores folders as
  /// SAF `content://` tree URIs even for real directories; for the standard
  /// external-storage provider these map deterministically onto `/storage/...`,
  /// so we can read/write them directly when the app holds broad storage
  /// access (All Files Access). Returns null for URIs we can't map.
  String? _folderToRealBase(String folder) {
    if (!folder.startsWith('content://')) return folder;
    const prefix = 'content://com.android.externalstorage.documents/tree/';
    if (!folder.startsWith(prefix)) return null;
    var docPart = folder.substring(prefix.length);
    // A picker URI may carry a `/document/<id>` suffix; the tree id is enough.
    final docIdx = docPart.indexOf('/document/');
    if (docIdx >= 0) docPart = docPart.substring(0, docIdx);
    final decoded = Uri.decodeComponent(docPart); // e.g. "primary:emu/roms"
    final colon = decoded.indexOf(':');
    if (colon < 0) return null;
    final volume = decoded.substring(0, colon);
    final relative = decoded.substring(colon + 1);
    final root = volume == 'primary'
        ? '/storage/emulated/0'
        : '/storage/$volume';
    return relative.isEmpty ? root : '$root/$relative';
  }

  /// Picks a writable destination directory `<romFolder>/<system>` for [system].
  ///
  /// Resolves SAF folders to their real path, then confirms the target is
  /// actually writable with a probe file (fails cleanly when the app lacks
  /// All Files Access). Returns null when no folder is writable.
  Future<String?> _resolveDestDir(
    SystemModel system,
    List<String> romFolders,
  ) async {
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      final dir = Directory(p.join(base, system.folderName));
      try {
        await dir.create(recursive: true);
        final probe = File(p.join(dir.path, '.romm_write_test'));
        await probe.writeAsString('');
        await probe.delete();
        return dir.path;
      } catch (_) {
        // Not writable (e.g. no broad storage permission): try the next folder.
        continue;
      }
    }
    return null;
  }

  /// All folder names (primary + aliases) a system's ROMs can live under.
  ///
  /// A system can map to several on-disk folders — Sega CD, for example, is
  /// indexed under both `scd` and `segacd`. The library scan reads every alias,
  /// so download/dedup logic must consider all of them, not just [folderName].
  List<String> _systemFolderNames(SystemModel system) {
    return <String>{
      if (system.folderName.isNotEmpty) system.folderName,
      ...system.folders,
    }.toList();
  }

  /// Directory of an already-downloaded copy of [rom] under any of the system's
  /// folder aliases, or null if none exists.
  ///
  /// Checking every alias (not just the canonical [folderName]) is what stops a
  /// re-download from writing a second copy under a different alias — e.g. a ROM
  /// already sitting in `segacd/` would otherwise be re-fetched into `scd/` and
  /// show up as a duplicate game once the scan indexes both.
  Future<String?> _existingRomDir(
    SystemModel system,
    RommRom rom,
    List<String> romFolders,
  ) async {
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      for (final name in _systemFolderNames(system)) {
        final dir = p.join(base, name);
        if (await File(p.join(dir, rom.fsName)).exists()) return dir;
      }
    }
    return null;
  }

  /// True when a file named after [rom] already exists in a configured folder.
  Future<bool> isDownloaded(RommRom rom, List<String> romFolders) async {
    final system = await resolveSystem(rom);
    if (system == null) return false;
    return await _existingRomDir(system, rom, romFolders) != null;
  }

  // ── Download ────────────────────────────────────────────────────────────────

  /// Downloads [rom] into a configured ROM folder. On success the resolved
  /// system is recorded in [downloadedSystems] and a debounced rescan is armed
  /// (see [_scheduleSettle]) so freshly downloaded ROMs are indexed and their
  /// system lists refreshed progressively — even if the user backs out of the
  /// browse screen mid-batch, since this provider outlives that screen.
  ///
  /// Updates [downloadFor] progress as it goes. Returns the final
  /// [RommDownload]; inspect its `status`/`error` for the outcome.
  Future<RommDownload> downloadRom(
    RommRom rom, {
    required List<String> romFolders,
    FileProvider? fileProvider,
  }) async {
    final tracker = RommDownload(romId: rom.id);
    _downloads[rom.id] = tracker;
    notifyListeners();

    final system = await resolveSystem(rom);
    if (system == null) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.noSystemMatch;
      notifyListeners();
      return tracker;
    }

    // Reuse the folder an existing copy already lives in (possibly a different
    // alias, e.g. segacd vs scd) so a re-download overwrites in place rather
    // than creating a duplicate the scan would index twice.
    final destDir =
        await _existingRomDir(system, rom, romFolders) ??
        await _resolveDestDir(system, romFolders);
    if (destDir == null) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.noWritableFolder;
      notifyListeners();
      return tracker;
    }

    // Multi-file ROMs are served by RomM as a single zip archive; the logical
    // fsName carries no (or the wrong) extension, so the scan/emulator would
    // not recognise the download. Give it a .zip so it's handled as an archive.
    final needsZip =
        rom.isMultiFile && !rom.fsName.toLowerCase().endsWith('.zip');
    final destPath = p.join(destDir, needsZip ? '${rom.fsName}.zip' : rom.fsName);
    try {
      await _service.downloadRom(
        rom,
        destFilePath: destPath,
        onProgress: (received, total) {
          tracker
            ..received = received
            ..total = total;
          notifyListeners();
        },
        shouldCancel: () => tracker.cancelRequested,
      );
      await _persistRefreshedTokens();
    } on RommException catch (e) {
      tracker.status = e.message == 'Download cancelled'
          ? RommDownloadStatus.cancelled
          : RommDownloadStatus.failed;
      if (tracker.status == RommDownloadStatus.failed) {
        tracker
          ..error = RommDownloadError.network
          ..errorDetail = e.message;
      }
      notifyListeners();
      return tracker;
    } catch (e) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.network
        ..errorDetail = '$e';
      notifyListeners();
      return tracker;
    }

    // Best-effort metadata + cover import from RomM (never fails the download).
    if (fileProvider != null) {
      await _importMetadata(rom, system, fileProvider);
    }

    tracker.status = RommDownloadStatus.completed;
    _downloadedSystems[system.folderName] = system;
    // Record the rom_id ↔ local game mapping so save sync can target this ROM.
    // rom.fsName is the on-disk filename the library scan later indexes as
    // GameModel.romname, so the key matches at sync time.
    await RommSaveMapRepository.putMapping(
      romname: rom.fsName,
      systemFolder: system.folderName,
      rommRomId: rom.id,
      fsName: rom.fsName,
    );
    notifyListeners();
    // Arm the debounced rescan so this ROM (and any others finishing around the
    // same time) get indexed + their lists refreshed shortly, without waiting
    // for the whole batch or the browse screen to close.
    _scheduleSettle();
    return tracker;
  }

  /// Imports RomM's metadata + cover art for [rom] into the same tables/media
  /// folders the ScreenScraper integration uses, so the library shows game info
  /// and box art without a separate scrape. Keyed by filename + system id, so
  /// it links up when the scan later creates the user_roms row.
  Future<void> _importMetadata(
    RommRom rom,
    SystemModel system,
    FileProvider fileProvider,
  ) async {
    try {
      final detail = await _service.getRomDetail(rom.id);
      if (detail == null) return;
      final md =
          (detail['metadatum'] as Map?)?.cast<String, dynamic>() ?? const {};

      final metadata = <String, dynamic>{
        'filename': rom.fsName,
        'real_name': rom.name,
      };
      final summary = detail['summary']?.toString();
      if (summary != null && summary.isNotEmpty) {
        metadata['description_en'] = summary;
      }
      final genres = (md['genres'] as List?)?.whereType<String>().toList();
      if (genres != null && genres.isNotEmpty) {
        metadata['genre'] = genres.join(', ');
      }
      // RomM has a flat company list (no dev/publisher split).
      final companies = (md['companies'] as List?)
          ?.whereType<String>()
          .toList();
      if (companies != null && companies.isNotEmpty) {
        metadata['developer'] = companies.join(', ');
      }
      final players = md['player_count']?.toString();
      if (players != null && players.isNotEmpty) {
        metadata['players'] = players;
      }
      final frd = md['first_release_date'];
      if (frd is num) {
        final dt = DateTime.fromMillisecondsSinceEpoch(
          frd.toInt(),
          isUtc: true,
        );
        final y = dt.year.toString().padLeft(4, '0');
        final m = dt.month.toString().padLeft(2, '0');
        final d = dt.day.toString().padLeft(2, '0');
        metadata['release_date'] = '$y-$m-$d';
      }

      // app_system_id is a FK to app_systems(id); skip rather than silently
      // fail the insert if the resolved system somehow has no id.
      final sysId = system.id ?? '';
      if (sysId.isEmpty) {
        _log.w(
          'RomM metadata import: no system id for ${rom.fsName}, skipping',
        );
      } else {
        await ScraperRepository.saveGameMetadata(
          metadata,
          sysId,
          isFullyScraped: true,
        );
      }

      // Cover art -> box2d media folder (prefer the larger RomM-served image).
      // RomM serves JPEG even from *.png cover paths, and the library's image
      // lookup is extension-sensitive, so save under the extension that matches
      // the actual bytes and remove any stale wrong-extension variant.
      final coverPath =
          (detail['path_cover_large']?.toString().isNotEmpty ?? false)
          ? detail['path_cover_large'].toString()
          : detail['path_cover_small']?.toString();
      if (coverPath != null && coverPath.isNotEmpty) {
        final bytes = await _service.fetchImageBytes(coverPath);
        if (bytes != null && bytes.isNotEmpty) {
          final ext = RommService.imageExtensionFor(bytes);
          // NeoStation shows fanart for game art (both grid and list views), so
          // the RomM cover is saved as the fanart. RomM exposes no separate
          // fanart image, so the cover doubles as it.
          final dest = fileProvider.getMediaPath(
            system.folderName,
            'fanarts',
            rom.fsName,
            ext,
          );
          final destFile = File(dest);
          await destFile.parent.create(recursive: true);
          await destFile.writeAsBytes(bytes);
          // Drop an other-format leftover so getImagePath resolves this one.
          for (final other in const ['png', 'jpg']) {
            if (other == ext) continue;
            final stale = File(
              fileProvider.getMediaPath(
                system.folderName,
                'fanarts',
                rom.fsName,
                other,
              ),
            );
            if (await stale.exists()) await stale.delete();
          }
        }
      }
    } catch (e) {
      _log.e('RomM metadata import failed: $e');
    }
  }

  /// Requests cancellation of an in-flight download.
  void cancelDownload(int romId) {
    final d = _downloads[romId];
    if (d != null && d.status == RommDownloadStatus.downloading) {
      d.cancelRequested = true;
      notifyListeners();
    }
  }

  /// Clears a finished download entry (so its UI badge resets).
  void clearDownload(int romId) {
    _downloads.remove(romId);
    notifyListeners();
  }

  // ── Internal ────────────────────────────────────────────────────────────────

  /// Persists tokens after a call that may have transparently refreshed them.
  Future<void> _persistRefreshedTokens() async {
    if (_service.accessToken == null) return;
    await RommRepository.saveTokens(
      accessToken: _service.accessToken!,
      refreshToken: _service.refreshToken,
      tokenExpires: _service.tokenExpiresMs,
    );
  }

  /// Best-effort fetch of the user's RetroAchievements progress. Failures are
  /// swallowed so a missing/unconfigured RA link never breaks library browsing.
  Future<void> _loadRaProgression() async {
    try {
      _raEarnedByGameId = await _service.getRaProgression();
    } catch (e) {
      _log.w('RomM RA progression fetch failed (non-fatal): $e');
    }
  }
}
