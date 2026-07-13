import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
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
import '../services/user_data_location_service.dart';
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

  /// Cache of RomM platform id → resolved local [SystemModel] (null = no match).
  /// Every browse-grid tile resolves its system to render the download badge;
  /// without this, each tile ran up to ~5 sequential SystemRepository queries,
  /// re-run on every GridView recycle — hundreds of redundant SQLite reads that
  /// janked scrolling. All ROMs on a platform resolve identically, so one lookup
  /// per platform suffices. Cleared on [disconnect].
  final Map<int, SystemModel?> _systemByPlatformId = {};

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
      // These tokens came straight from the DB; mark them as persisted so the
      // first browse call doesn't re-write an identical row.
      _lastPersistedAccessToken = config['access_token'] as String?;
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
    _lastPersistedAccessToken = _service.accessToken;

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
    _systemByPlatformId.clear();
    _lastPersistedAccessToken = null;
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
      // Fetch it in the background and repaint (achievement badges) when it
      // lands, rather than awaiting a second /api/users/me round-trip here.
      unawaited(_loadRaProgression().then((_) => notifyListeners()));
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
  ///
  /// Memoized per platform id (see [_systemByPlatformId]) so the browse grid
  /// resolves each platform once instead of per tile.
  Future<SystemModel?> resolveSystem(RommRom rom) async {
    if (_systemByPlatformId.containsKey(rom.platformId)) {
      return _systemByPlatformId[rom.platformId];
    }
    final resolved = await _resolveSystemUncached(rom);
    _systemByPlatformId[rom.platformId] = resolved;
    return resolved;
  }

  Future<SystemModel?> _resolveSystemUncached(RommRom rom) async {
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
  /// SAF `content://` tree URIs even for real directories; the shared
  /// [UserDataLocationService.safUriToRealPath] maps those onto `/storage/...`
  /// (primary + removable volumes) so we can read/write them directly when the
  /// app holds broad storage access. Returns null for URIs it can't map.
  String? _folderToRealBase(String folder) {
    if (!folder.startsWith('content://')) return folder;
    return UserDataLocationService.safUriToRealPath(folder);
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
    final candidates = _existingRomNames(rom);
    // A bundled multi-disc playlist keeps its own arbitrary basename, which the
    // name heuristics above can't reconstruct. If this ROM was downloaded here
    // before, the map recorded the exact on-disk indexed name (the .m3u) — use
    // it so the game is recognised as downloaded instead of re-fetched.
    final recorded = await RommSaveMapRepository.getIndexedNameForRomId(
      rom.id,
      system.folderName,
    );
    if (recorded != null && !candidates.contains(recorded)) {
      candidates.add(recorded);
    }
    for (final folder in romFolders) {
      final base = _folderToRealBase(folder);
      if (base == null) continue;
      for (final name in _systemFolderNames(system)) {
        final dir = p.join(base, name);
        for (final candidate in candidates) {
          if (await File(p.join(dir, candidate)).exists()) return dir;
        }
      }
    }
    return null;
  }

  /// On-disk names that mark [rom] as already downloaded in a folder.
  ///
  /// A single-file ROM lands as its [RommRom.fsName]. A multi-disc ROM is
  /// served as a zip that [extractMultiDiscZip] unpacks into disc files plus a
  /// `.m3u` playlist and then deletes — so the fsName itself never exists on
  /// disk; only the playlist does. We match the playlist names that extraction
  /// would produce: the synthesised fallback (`<fsName>.m3u`) and, defensively,
  /// the extension-replaced variant. (A bundled playlist keeps its own basename
  /// which we can't predict here, so those re-download; the common synthesised
  /// case is covered.)
  List<String> _existingRomNames(RommRom rom) {
    final names = <String>[rom.fsName];
    if (rom.isMultiFile) {
      names.add('${rom.fsName}.m3u');
      final stem = p.basenameWithoutExtension(rom.fsName);
      if (stem.isNotEmpty && stem != rom.fsName) names.add('$stem.m3u');
    }
    return names;
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

    // Multi-file (multi-disc) ROMs are served by RomM as a single zip archive
    // whose logical fsName may or may not already carry a .zip extension. We
    // stream it to a .zip first, then always unpack it into the native scan
    // layout below. A plain .zip neither scans (most disc systems omit it from
    // their extension list) nor launches (the emulator boots the playlist/disc,
    // not the archive), so a multi-file ROM must always go through extraction.
    final isArchive = rom.isMultiFile;
    // Only append .zip when fsName doesn't already end in it (avoid foo.zip.zip).
    final appendZipExt =
        isArchive && !rom.fsName.toLowerCase().endsWith('.zip');
    final destPath =
        p.join(destDir, appendZipExt ? '${rom.fsName}.zip' : rom.fsName);
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
    } on RommCancelledException {
      // User-cancelled: a distinct type (not a message-string match) keeps this
      // from being reported as a network failure if the message ever changes.
      tracker.status = RommDownloadStatus.cancelled;
      notifyListeners();
      return tracker;
    } on RommException catch (e) {
      tracker
        ..status = RommDownloadStatus.failed
        ..error = RommDownloadError.network
        ..errorDetail = e.message;
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

    // The name the library scan will index for this download. For a single-file
    // ROM that's the fsName as-downloaded; for an unpacked multi-disc archive it
    // becomes the playlist (.m3u) we write below. Save-sync and metadata both
    // key on this, so it must match what the scan records as GameModel.romname.
    var indexedName = p.basename(destPath);
    if (isArchive) {
      final exts = await SystemRepository.getExtensionsForSystem(
        system.id ?? '',
      );
      // Only unpack for systems that drive multi-disc games via .m3u playlists
      // (PS1, Saturn, Dreamcast, SegaCD, PCE-CD, 3DO, the m3u home computers…).
      // Others (e.g. single-disc DVD systems) keep the archive untouched.
      if (exts.contains('m3u')) {
        final m3uName = await extractMultiDiscZip(destPath, destDir, rom.fsName);
        if (m3uName != null) indexedName = m3uName;
      }
    }

    // Best-effort metadata + cover import from RomM (never fails the download).
    if (fileProvider != null) {
      await _importMetadata(rom, system, fileProvider, indexedName);
    }

    tracker.status = RommDownloadStatus.completed;
    _downloadedSystems[system.folderName] = system;
    // Record the rom_id ↔ local game mapping so save sync can target this ROM.
    // [indexedName] is the on-disk filename the library scan indexes as
    // GameModel.romname (the .m3u for unpacked multi-disc ROMs), so the key
    // matches at sync time.
    await RommSaveMapRepository.putMapping(
      romname: indexedName,
      systemFolder: system.folderName,
      rommRomId: rom.id,
      fsName: indexedName,
    );
    notifyListeners();
    // Arm the debounced rescan so this ROM (and any others finishing around the
    // same time) get indexed + their lists refreshed shortly, without waiting
    // for the whole batch or the browse screen to close.
    _scheduleSettle();
    return tracker;
  }

  /// Unpacks a downloaded multi-disc zip ([zipPath]) into NeoStation's native
  /// multi-disc layout under [destDir]: the `.m3u` playlist and the disc images
  /// all sit together in the ROM folder root (so the library scan indexes a
  /// single entry that launches with disc-switching, while the playlist filter
  /// hides the referenced disc files by basename).
  ///
  /// Disc content is streamed entry-by-entry straight to disk, so a multi-GB
  /// archive never lands wholly in memory. When RomM bundles its own `.m3u` its
  /// disc ordering is preserved; otherwise a playlist is synthesised from the
  /// disc files in stable name order, using [fallbackBaseName].
  ///
  /// Returns the on-disk `.m3u` filename on success (the name the scan indexes
  /// and save-sync/metadata key on), or null if the archive holds nothing
  /// disc-like or extraction fails — in which case the caller leaves the zip
  /// in place untouched.
  @visibleForTesting
  static Future<String?> extractMultiDiscZip(
    String zipPath,
    String destDir,
    String fallbackBaseName,
  ) async {
    InputFileStream? input;
    try {
      input = InputFileStream(zipPath);
      final archive = ZipDecoder().decodeStream(input);

      ArchiveFile? m3uEntry;
      final discEntries = <ArchiveFile>[];
      for (final f in archive.files) {
        if (!f.isFile) continue;
        final base = p.basename(f.name);
        if (base.isEmpty) continue;
        if (p.extension(base).toLowerCase() == '.m3u') {
          m3uEntry ??= f;
        } else {
          discEntries.add(f);
        }
      }
      if (discEntries.isEmpty) return null;

      final extractedDiscs = <String>[];
      for (final f in discEntries) {
        final base = p.basename(f.name);
        final out = OutputFileStream(p.join(destDir, base));
        f.writeContent(out);
        out.closeSync();
        extractedDiscs.add(base);
      }

      // Preserve the bundled playlist's disc order when present; otherwise fall
      // back to a stable alphabetical order (disc 1, disc 2, …).
      final String m3uName;
      List<String> ordered;
      if (m3uEntry != null) {
        m3uName = p.basename(m3uEntry.name);
        final referenced = <String>[];
        for (final line in utf8.decode(m3uEntry.content).split('\n')) {
          final t = line.trim();
          if (t.isEmpty || t.startsWith('#')) continue;
          final b = p.basename(t);
          if (extractedDiscs.contains(b)) referenced.add(b);
        }
        ordered = referenced.isNotEmpty
            ? referenced
            : (extractedDiscs..sort());
      } else {
        m3uName = '$fallbackBaseName.m3u';
        ordered = extractedDiscs..sort();
      }

      // Reference discs by bare basename: they sit alongside the .m3u in the
      // ROM folder, and the scan's basename filter hides them so only the .m3u
      // surfaces as a game entry.
      final playlist = ordered.join('\n');
      await File(
        p.join(destDir, m3uName),
      ).writeAsString('$playlist\n', flush: true);

      await input.close();
      input = null;
      await File(zipPath).delete();
      return m3uName;
    } catch (e, st) {
      _log.e(
        'RomM multi-disc extract failed for $zipPath',
        error: e,
        stackTrace: st,
      );
      return null;
    } finally {
      await input?.close();
    }
  }

  /// Imports RomM's metadata + cover art for [rom] into the same tables/media
  /// folders the ScreenScraper integration uses, so the library shows game info
  /// and box art without a separate scrape. Keyed by filename + system id, so
  /// it links up when the scan later creates the user_roms row.
  ///
  /// [indexedName] is the on-disk filename the scan will record (the playlist
  /// for an unpacked multi-disc ROM, otherwise the fsName). The metadata row is
  /// matched to the scanned game by exact filename, so it must use this name.
  Future<void> _importMetadata(
    RommRom rom,
    SystemModel system,
    FileProvider fileProvider,
    String indexedName,
  ) async {
    try {
      final detail = await _service.getRomDetail(rom.id);
      if (detail == null) return;
      final md =
          (detail['metadatum'] as Map?)?.cast<String, dynamic>() ?? const {};

      final metadata = <String, dynamic>{
        'filename': indexedName,
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
            indexedName,
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
                indexedName,
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

  /// Last access token written to the DB, so repeated page loads that didn't
  /// refresh the token don't fire a redundant SQLite UPDATE each time.
  String? _lastPersistedAccessToken;

  /// Persists tokens after a call that may have transparently refreshed them —
  /// but only when the access token actually changed. Browsing calls this after
  /// every platform/collection/ROM page and every download; without the guard
  /// each 50-ROM page cost a needless UPDATE on the hot path.
  Future<void> _persistRefreshedTokens() async {
    final token = _service.accessToken;
    if (token == null || token == _lastPersistedAccessToken) return;
    await RommRepository.saveTokens(
      accessToken: token,
      refreshToken: _service.refreshToken,
      tokenExpires: _service.tokenExpiresMs,
    );
    _lastPersistedAccessToken = token;
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
