/// A RomM save or save-state asset, returned by `/api/saves` and `/api/states`.
///
/// Both endpoints share the same schema; [isState] records which router the
/// asset came from so callers can route uploads/downloads correctly.
class RommAsset {
  /// RomM asset id (used for `/api/{saves|states}/{id}/content`).
  final int id;

  /// The emulator's filename for this save/state (e.g. "Game.srm").
  final String fileName;

  /// Size in bytes.
  final int fileSizeBytes;

  /// Server-side content hash, when provided (used for change detection).
  final String? contentHash;

  /// When the asset was first uploaded.
  final DateTime? createdAt;

  /// When the asset was last updated (primary timestamp for conflict checks).
  final DateTime? updatedAt;

  /// Emulator label the asset is associated with, if any.
  final String? emulator;

  /// Save slot, for emulators that expose multiple slots.
  final int? slot;

  /// Server-relative URL to fetch the raw bytes
  /// (`/api/raw/assets/{file_path}/{file_name}?timestamp=...`). This is the
  /// canonical download for BOTH saves and states — the `/api/saves/{id}/content`
  /// convenience route exists only for saves, so states must use this.
  final String? downloadPath;

  /// True if this came from `/api/states`, false for `/api/saves`.
  final bool isState;

  const RommAsset({
    required this.id,
    required this.fileName,
    required this.fileSizeBytes,
    required this.isState,
    this.contentHash,
    this.createdAt,
    this.updatedAt,
    this.emulator,
    this.slot,
    this.downloadPath,
  });

  factory RommAsset.fromJson(
    Map<String, dynamic> json, {
    required bool isState,
  }) {
    return RommAsset(
      id: int.tryParse((json['id'] ?? 0).toString()) ?? 0,
      fileName: (json['file_name'] ?? '').toString(),
      fileSizeBytes:
          int.tryParse((json['file_size_bytes'] ?? '0').toString()) ?? 0,
      contentHash: json['content_hash']?.toString(),
      createdAt: DateTime.tryParse((json['created_at'] ?? '').toString()),
      updatedAt: DateTime.tryParse((json['updated_at'] ?? '').toString()),
      emulator: json['emulator']?.toString(),
      slot: int.tryParse((json['slot'] ?? '').toString()),
      downloadPath: json['download_path']?.toString(),
      isState: isState,
    );
  }

  /// Milliseconds-since-epoch of [updatedAt], or 0 when unknown.
  int get updatedAtMs => updatedAt?.millisecondsSinceEpoch ?? 0;
}
