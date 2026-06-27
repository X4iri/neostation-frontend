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
  /// that RomM serves as a zip archive.
  final List<RommRomFile> files;

  /// Relative or absolute cover URL (may need the server base URL + auth).
  final String? urlCover;

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
    this.urlCover,
  });

  /// True when RomM serves this ROM as a multi-file zip archive.
  bool get isMultiFile => files.length > 1;

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
      urlCover: json['url_cover']?.toString(),
    );
  }
}
