/// A single file belonging to a [RommRom] (RomM splits multi-disc / multi-part
/// ROMs into multiple files served together as a zip).
class RommRomFile {
  final int id;
  final String fileName;
  final int fileSizeBytes;

  const RommRomFile({
    required this.id,
    required this.fileName,
    this.fileSizeBytes = 0,
  });

  factory RommRomFile.fromJson(Map<String, dynamic> json) {
    return RommRomFile(
      id: (json['id'] as num).toInt(),
      fileName: json['file_name']?.toString() ?? '',
      fileSizeBytes: (json['file_size_bytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A ROM entry as exposed by a remote RomM server.
///
/// Describes the *remote* library; kept separate from the local [GameModel].
class RommRom {
  /// RomM internal ROM id (used for `/api/roms/{id}` and downloads).
  final int id;

  /// Display name.
  final String name;

  /// RomM platform id this ROM belongs to.
  final int platformId;

  /// RomM platform slug (e.g. "snes").
  final String platformSlug;

  /// Filesystem name including extension (the download `file_name`).
  final String fsName;

  /// Filesystem name without extension.
  final String fsNameNoExt;

  /// File extension (without leading dot).
  final String fsExtension;

  /// Total size in bytes.
  final int fsSizeBytes;

  /// Constituent files; length > 1 indicates a multi-disc/multi-part ROM
  /// that RomM serves as a zip archive. NOTE: RomM only populates this on the
  /// detail endpoint (`/api/roms/{id}`); the list endpoint returns it empty, so
  /// prefer [hasMultipleFiles] for the multi-file decision.
  final List<RommRomFile> files;

  /// RomM's own `has_multiple_files` flag, present on BOTH the list and detail
  /// endpoints. This is the reliable multi-file signal because [files] is empty
  /// in list responses (which is what the browse/download flow uses).
  final bool hasMultipleFiles;

  /// Relative or absolute cover URL (may need the server base URL + auth).
  final String? urlCover;

  /// RetroAchievements game id RomM matched this ROM to, or null if none.
  /// A non-null id means the game has a RetroAchievements set.
  ///
  /// Per-user earned progress is NOT carried on the ROM: RomM exposes it on the
  /// current user (`/api/users/me` → `ra_progression.results`, keyed by this
  /// [raId]). See `RommService.getRaProgression` / `RommProvider.raEarnedFor`.
  final int? raId;

  /// Total number of achievements in the RA set (0 when unknown / no set).
  final int raTotalAchievements;

  const RommRom({
    required this.id,
    required this.name,
    required this.platformId,
    required this.platformSlug,
    required this.fsName,
    required this.fsNameNoExt,
    required this.fsExtension,
    this.fsSizeBytes = 0,
    this.files = const [],
    this.hasMultipleFiles = false,
    this.urlCover,
    this.raId,
    this.raTotalAchievements = 0,
  });

  /// True when RomM serves this ROM as a multi-file zip archive. Uses RomM's
  /// `has_multiple_files` flag (reliable on both endpoints) and falls back to
  /// the [files] list, which is only populated on the detail endpoint.
  bool get isMultiFile => hasMultipleFiles || files.length > 1;

  /// True when this ROM has a RetroAchievements set (per RomM metadata).
  bool get hasRetroAchievements => raId != null && raTotalAchievements > 0;

  factory RommRom.fromJson(Map<String, dynamic> json) {
    final filesJson = json['files'];
    final files = <RommRomFile>[];
    if (filesJson is List) {
      for (final f in filesJson) {
        if (f is Map<String, dynamic>) {
          files.add(RommRomFile.fromJson(f));
        }
      }
    }

    return RommRom(
      id: (json['id'] as num).toInt(),
      name:
          json['name']?.toString() ?? json['fs_name']?.toString() ?? 'Unknown',
      platformId: (json['platform_id'] as num?)?.toInt() ?? 0,
      platformSlug: json['platform_slug']?.toString() ?? '',
      fsName: json['fs_name']?.toString() ?? '',
      fsNameNoExt: json['fs_name_no_ext']?.toString() ?? '',
      fsExtension: json['fs_extension']?.toString() ?? '',
      fsSizeBytes: (json['fs_size_bytes'] as num?)?.toInt() ?? 0,
      files: files,
      hasMultipleFiles: json['has_multiple_files'] == true,
      urlCover: json['url_cover']?.toString(),
      raId: (json['ra_id'] as num?)?.toInt(),
      raTotalAchievements: _parseRaTotal(json),
    );
  }

  /// Total achievements in the RA set. Prefers the length of the merged
  /// metadata's achievement list, falling back to numeric count fields.
  static int _parseRaTotal(Map<String, dynamic> json) {
    final meta = json['merged_ra_metadata'];
    if (meta is Map) {
      final ach = meta['achievements'];
      if (ach is List) return ach.length;
      final maxPossible = (meta['max_possible'] as num?)?.toInt();
      if (maxPossible != null) return maxPossible;
    }
    return (json['num_achievements'] as num?)?.toInt() ?? 0;
  }
}
