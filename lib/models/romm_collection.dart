/// A collection (user-defined or RomM "virtual") as exposed by a RomM server.
///
/// RomM has two flavours that the UI treats uniformly:
/// - **User collections** (`GET /api/collections`) have an integer id and are
///   filtered via `?collection_id=<int>`.
/// - **Virtual collections** (`GET /api/collections/virtual?type=…`) are
///   auto-generated groupings (e.g. game series) with a *string* id and are
///   filtered via `?virtual_collection_id=<string>`.
///
/// To keep one model, [id] is always stored as a string and [isVirtual]
/// selects which `/api/roms` query parameter the provider uses.
class RommCollection {
  /// RomM id. Integer-as-string for user collections, opaque string for
  /// virtual collections.
  final String id;

  /// Human-readable collection name.
  final String name;

  /// Number of ROMs RomM reports for this collection.
  final int romCount;

  /// Whether this is a RomM virtual (auto-generated) collection.
  final bool isVirtual;

  /// Optional cover image URL (RomM-relative or absolute), or null.
  final String? urlCover;

  const RommCollection({
    required this.id,
    required this.name,
    this.romCount = 0,
    this.isVirtual = false,
    this.urlCover,
  });

  factory RommCollection.fromJson(
    Map<String, dynamic> json, {
    required bool isVirtual,
  }) {
    // path_covers_small/large are mosaics (lists of per-ROM cover paths); fall
    // back to the first entry when there's no single url_cover.
    String? cover = json['url_cover']?.toString();
    if (cover == null || cover.isEmpty) {
      final small = json['path_cover_small']?.toString();
      cover = (small != null && small.isNotEmpty) ? small : null;
    }
    return RommCollection(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? 'Unknown',
      romCount: (json['rom_count'] as num?)?.toInt() ?? 0,
      isVirtual: isVirtual,
      urlCover: cover,
    );
  }
}
