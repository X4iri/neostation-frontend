/// RomM save-sync provider.
///
/// Syncs emulator save files and save states between the local device and a
/// self-hosted RomM instance, mirroring NeoSync's per-game flow (download newer
/// remote saves before launch, upload changed local saves after the game
/// closes).
///
/// It reuses the existing, already-authenticated [RommProvider] (library browse)
/// connection — no second login — and delegates local save-file *location* to
/// [NeoSyncProvider]'s battle-tested path resolution. Sync state is tracked in
/// the shared, provider-agnostic `app_neo_sync_state` table via [SyncRepository].
///
/// Saves are keyed by RomM `rom_id`, which is only known for games downloaded
/// from RomM (recorded in `app_romm_rom_map` at download time). Games with no
/// mapping are treated as not-linked and skipped.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:neostation/models/game_model.dart';
import 'package:neostation/models/neo_sync_models.dart';
import 'package:neostation/models/romm_asset.dart';
import 'package:neostation/providers/neo_sync_provider.dart';
import 'package:neostation/providers/romm_provider.dart';
import 'package:neostation/repositories/romm_save_map_repository.dart';
import 'package:neostation/repositories/sync_repository.dart';
import 'package:neostation/services/logger_service.dart';
import 'package:neostation/services/romm_service.dart';

import '../i_sync_provider.dart';

class RomMSyncProvider extends ChangeNotifier implements ISyncProvider {
  static const String kProviderId = 'romm';

  /// Tolerance (ms) for local-vs-recorded mtime comparisons, matching NeoSync.
  static const int _mtimeToleranceMs = 2000;

  static final _log = LoggerService.instance;

  /// Authenticated RomM connection, shared with the library browser.
  final RommProvider _browse;

  /// Used only to locate/place local save files (path resolution reuse).
  final NeoSyncProvider _neoSync;

  final Map<String, GameSyncState> _gameSyncStates = {};

  RomMSyncProvider(this._browse, this._neoSync);

  RommService get _svc => _browse.service;

  // ── Identity ───────────────────────────────────────────────────────────────

  @override
  String get providerId => kProviderId;

  @override
  SyncProviderMeta get meta => const SyncProviderMeta(
    id: kProviderId,
    name: 'RomM',
    description:
        'Self-hosted sync via your own RomM instance. Uses your RomM '
        'connection — only games downloaded from RomM are synced.',
    author: 'Community',
    iconAssetPath: 'assets/icons/romm.png',
  );

  // ── State ──────────────────────────────────────────────────────────────────

  @override
  SyncProviderStatus get status {
    switch (_browse.status) {
      case RommConnectionStatus.connected:
        return SyncProviderStatus.connected;
      case RommConnectionStatus.connecting:
        return SyncProviderStatus.connecting;
      case RommConnectionStatus.error:
        return SyncProviderStatus.error;
      case RommConnectionStatus.disconnected:
        return SyncProviderStatus.disconnected;
    }
  }

  @override
  bool get isAuthenticated => _browse.isConnected;

  @override
  String? get lastError => _browse.lastError;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  Future<void> initialize() async {
    // The browse RommProvider restores config + tokens in its own initialize().
  }

  // ── Authentication ─────────────────────────────────────────────────────────

  @override
  Future<SyncResult> login() async {
    if (_browse.isConnected) return SyncResult.ok();
    return SyncResult.fail(
      SyncError.authRequired,
      message: 'Connect to RomM in Settings → RomM first',
    );
  }

  @override
  Future<void> logout() async {
    await _browse.disconnect();
  }

  // ── Mapping / discovery helpers ─────────────────────────────────────────────

  /// Resolves the RomM `rom_id` for [game], or null if the game isn't linked
  /// to a RomM ROM (i.e. wasn't downloaded from RomM).
  Future<int?> _resolveRomId(GameModel game) async {
    final systemFolder = game.systemFolderName;
    if (systemFolder == null || systemFolder.isEmpty) return null;
    return RommSaveMapRepository.getRommRomId(game.romname, systemFolder);
  }

  GameSyncState _buildState(
    GameModel game,
    GameSyncStatus status, {
    String? errorMessage,
  }) => GameSyncState(
    gameId: game.romname,
    gameName: game.name,
    status: status,
    cloudEnabled: game.cloudSyncEnabled ?? true,
    errorMessage: errorMessage,
  );

  // ── Core per-game sync ──────────────────────────────────────────────────────

  /// Bidirectional sync for [game]. When [downloadOnly] is true (pre-launch),
  /// only newer/missing remote files are pulled; otherwise local changes are
  /// also pushed.
  Future<GameSyncStatus> _syncGame(
    GameModel game, {
    required bool downloadOnly,
  }) async {
    if (!_browse.isConnected) return GameSyncStatus.error;
    if (game.cloudSyncEnabled == false) return GameSyncStatus.disabled;

    final romId = await _resolveRomId(game);
    if (romId == null) {
      return GameSyncStatus.noSaveFound; // not a RomM-linked game
    }

    final localFiles = await _neoSync.locateGameSaveFiles(game);

    final List<RommAsset> remote;
    try {
      final saves = await _svc.listSaves(romId: romId);
      final states = await _svc.listStates(romId: romId);
      remote = [...saves, ...states];
    } catch (e) {
      _log.e('RomM listSaves/listStates failed for ${game.romname}: $e');
      return GameSyncStatus.error;
    }

    final matchedRemote = <int>{}; // asset ids already paired with a local file
    int uploaded = 0, downloaded = 0;
    bool anyLocal = localFiles.isNotEmpty;
    bool anyRemote = remote.isNotEmpty;

    // 1) Reconcile each local file against its remote counterpart.
    for (final local in localFiles) {
      final isState = local.relativePath.startsWith('states/');
      final baseName = path.basename(local.filePath);
      RommAsset? match;
      for (final a in remote) {
        if (a.isState == isState && a.fileName == baseName) {
          match = a;
          break;
        }
      }
      if (match != null) matchedRemote.add(match.id);

      final localMs = local.lastModified.millisecondsSinceEpoch;
      final recorded = await SyncRepository.getSyncState(local.filePath);
      final recordedLocalMs = (recorded?['local_modified_at'] as int?) ?? 0;
      final recordedCloudMs = (recorded?['cloud_updated_at'] as int?) ?? 0;

      final localChanged =
          recorded == null || localMs > recordedLocalMs + _mtimeToleranceMs;

      if (match == null) {
        // Local only → upload (unless pre-launch download-only pass).
        if (!downloadOnly) {
          if (await _upload(romId, local, isState)) uploaded++;
        }
        continue;
      }

      final remoteChanged = match.updatedAtMs > recordedCloudMs;

      if (remoteChanged && (!localChanged || downloadOnly)) {
        // Remote is newer (and local untouched, or we only pull right now).
        if (await _download(game, match)) downloaded++;
      } else if (localChanged && !downloadOnly) {
        // Local newer (or both changed → prefer local).
        if (await _upload(romId, local, isState)) uploaded++;
      }
    }

    // 2) Remote-only files → download.
    for (final a in remote) {
      if (matchedRemote.contains(a.id)) continue;
      if (await _download(game, a)) downloaded++;
    }

    _log.i(
      'RomM sync ${game.romname}: $uploaded up, $downloaded down '
      '(${localFiles.length} local, ${remote.length} remote)',
    );

    if (!anyLocal && !anyRemote) return GameSyncStatus.noSaveFound;
    if (!anyRemote) return GameSyncStatus.localOnly;
    if (!anyLocal && downloaded == 0) return GameSyncStatus.cloudOnly;
    return GameSyncStatus.upToDate;
  }

  /// Extracts the save-folder subpath (e.g. RetroArch's per-core `FCEUmm`
  /// folder) from a local file's `saves/…`/`states/…` relative path, so it can
  /// be preserved across the round-trip via RomM's `emulator` field. Returns
  /// empty when the file sits directly in the saves/states root.
  String _subfolderOf(LocalSaveFile local) {
    final parts = local.relativePath.split('/');
    if (parts.length <= 2) return '';
    return parts.sublist(1, parts.length - 1).join('/');
  }

  Future<bool> _upload(int romId, LocalSaveFile local, bool isState) async {
    try {
      final file = File(local.filePath);
      if (!await file.exists()) return false;
      final sub = _subfolderOf(local);
      final emulator = sub.isEmpty ? null : sub;
      final asset = isState
          ? await _svc.uploadState(romId, file, emulator: emulator)
          : await _svc.uploadSave(romId, file, emulator: emulator);
      final stat = await file.stat();
      await SyncRepository.saveSyncState(
        local.filePath,
        stat.modified.millisecondsSinceEpoch,
        asset.updatedAtMs,
        local.fileSize,
        fileHash: asset.contentHash,
      );
      return true;
    } catch (e) {
      _log.e('RomM upload failed (${local.filePath}): $e');
      return false;
    }
  }

  Future<bool> _download(GameModel game, RommAsset asset) async {
    try {
      // Rebuild the per-core subfolder (carried in the emulator field at upload)
      // so the file lands where the emulator actually reads it.
      final prefix = asset.isState ? 'states' : 'saves';
      final sub = asset.emulator;
      final relativeName = (sub != null && sub.isNotEmpty)
          ? '$prefix/$sub/${asset.fileName}'
          : '$prefix/${asset.fileName}';
      final targets = await _neoSync.resolveLocalTargetPaths(
        game,
        relativeName,
      );
      if (targets.isEmpty) {
        _log.w('RomM download: no local target for ${asset.fileName}');
        return false;
      }
      // Both saves and states download via the asset's download_path; only
      // saves have the /content convenience route (used as a fallback).
      final Uint8List bytes;
      final dp = asset.downloadPath;
      if (dp != null && dp.isNotEmpty) {
        bytes = await _svc.downloadAssetByPath(dp);
      } else if (!asset.isState) {
        bytes = await _svc.downloadSaveContent(asset.id);
      } else {
        _log.w('RomM download: state ${asset.fileName} has no download_path');
        return false;
      }

      for (final target in targets) {
        final f = File(target);
        await f.parent.create(recursive: true);
        await f.writeAsBytes(bytes, flush: true);
        final stat = await f.stat();
        await SyncRepository.saveSyncState(
          target,
          stat.modified.millisecondsSinceEpoch,
          asset.updatedAtMs,
          bytes.length,
          fileHash: asset.contentHash,
        );
      }
      return true;
    } catch (e) {
      _log.e('RomM download failed (${asset.fileName}): $e');
      return false;
    }
  }

  // ── Game-specific sync operations (interface) ───────────────────────────────

  @override
  Future<SyncResult> detectGameSaveFiles(GameModel game) async {
    try {
      final status = await _syncGame(game, downloadOnly: false);
      _gameSyncStates[game.romname] = _buildState(game, status);
      notifyListeners();
      return SyncResult.ok();
    } catch (e) {
      _gameSyncStates[game.romname] = _buildState(
        game,
        GameSyncStatus.error,
        errorMessage: e.toString(),
      );
      notifyListeners();
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  GameSyncState? getGameSyncState(String gameId) => _gameSyncStates[gameId];

  @override
  Future<SyncResult> syncGameSavesBeforeLaunch(GameModel game) async {
    try {
      await _syncGame(game, downloadOnly: true);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.unknown, message: e.toString());
    }
  }

  @override
  Future<SyncResult> syncGameSavesAfterClose(GameModel game) async {
    return detectGameSaveFiles(game);
  }

  @override
  Future<void> updateGameCloudSyncEnabled(String gameId, bool enabled) async {
    final existing = _gameSyncStates[gameId];
    if (existing != null) {
      _gameSyncStates[gameId] = existing.copyWith(
        cloudEnabled: enabled,
        status: enabled ? existing.status : GameSyncStatus.disabled,
      );
      notifyListeners();
    }
  }

  // ── Core sync operations (interface) ────────────────────────────────────────

  @override
  Future<SyncResult> uploadSave(
    String gameId,
    File file, {
    String? customFileName,
  }) async {
    final romId = int.tryParse(gameId);
    if (romId == null) {
      return SyncResult.fail(
        SyncError.configInvalid,
        message: 'uploadSave expects a RomM rom_id',
      );
    }
    try {
      await _svc.uploadSave(romId, file);
      return SyncResult.ok();
    } catch (e) {
      return SyncResult.fail(SyncError.networkError, message: e.toString());
    }
  }

  @override
  Future<SyncResult> downloadSave(String gameId, String fileId) async {
    final assetId = int.tryParse(fileId);
    if (assetId == null) {
      return SyncResult.fail(SyncError.fileNotFound, message: 'Invalid fileId');
    }
    try {
      final bytes = await _svc.downloadSaveContent(assetId);
      return SyncResult.ok(data: bytes);
    } catch (e) {
      return SyncResult.fail(SyncError.networkError, message: e.toString());
    }
  }

  @override
  Future<List<SyncFile>> listSaves({String? gameId}) async {
    final romId = gameId == null ? null : int.tryParse(gameId);
    if (romId == null) return const [];
    try {
      final assets = [
        ...await _svc.listSaves(romId: romId),
        ...await _svc.listStates(romId: romId),
      ];
      return assets
          .map(
            (a) => SyncFile(
              id: a.id.toString(),
              fileName: a.fileName,
              gameId: gameId,
              fileSize: a.fileSizeBytes,
              uploadedAt: a.createdAt ?? DateTime.now(),
              modifiedAt: a.updatedAt,
              checksum: a.contentHash,
            ),
          )
          .toList();
    } catch (e) {
      _log.e('RomM listSaves failed: $e');
      return const [];
    }
  }

  @override
  Future<SyncResult> fullSync() async {
    if (!_browse.isConnected) {
      return SyncResult.fail(SyncError.authRequired);
    }
    // Per-game sync is driven by the launch flow; a global pass would require
    // enumerating mapped games. Deferred — return ok as a no-op for now.
    return SyncResult.ok(message: 'RomM syncs per-game on launch/close');
  }

  @override
  Future<SyncResult> deleteRemote(String fileId) async => SyncResult.fail(
    SyncError.unknown,
    message: 'deleteRemote not supported by $providerId',
  );

  @override
  Future<SyncQuota?> getQuota() async => null;
}
