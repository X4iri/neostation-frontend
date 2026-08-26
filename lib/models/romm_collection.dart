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

  /// Per-ROM cover paths RomM assembles into the collection's mosaic thumbnail
  /// (as shown on RomM's own web `/collections` page). RomM-relative or
  /// absolute; empty when the server reports no covers. Rendered as a 2×2
  /// montage in the browse grid.
  final List<String> coverUrls;

  /// Whether this collection has a custom cover artwork (as opposed to
  /// generating a mosaic from its ROMs).
  final bool hasCustomCover;

  const RommCollection({
    required this.id,
    required this.name,
    this.romCount = 0,
    this.isVirtual = false,
    this.urlCover,
    this.coverUrls = const [],
    this.hasCustomCover = false,
  });

  factory RommCollection.fromJson(
    Map<String, dynamic> json, {
    required bool isVirtual,
  }) {
    // Priority 1: Custom Artwork.
    String? cover = json['path_cover_l']?.toString();
    if (cover == null || cover.isEmpty) {
      cover = json['path_cover_s']?.toString();
    }
    if (cover == null || cover.isEmpty) {
      cover = json['url_cover']?.toString();
    }

    final bool trulyCustom = cover != null && cover.isNotEmpty;

    // Priority 2: Mosaic components (per-ROM cover paths).
    List<String> covers = _stringList(json['path_covers_l']);
    if (covers.isEmpty) {
      covers = _stringList(json['path_covers_s']);
    }
    if (covers.isEmpty) {
      covers = _stringList(json['path_covers_large']);
    }
    if (covers.isEmpty) {
      covers = _stringList(json['path_covers_small']);
    }

    // Fallback for urlCover to satisfy existing tests and single-image
    // consumers: when no custom artwork is assigned, the "primary" image is
    // the first mosaic tile.
    if (!trulyCustom && covers.isNotEmpty) {
      cover = covers.first;
    }

    return RommCollection(
      id: json['id'].toString(),
      name: json['name']?.toString() ?? 'Unknown',
      romCount: (json['rom_count'] as num?)?.toInt() ?? 0,
      isVirtual: isVirtual,
      urlCover: (cover != null && cover.isNotEmpty) ? cover : null,
      coverUrls: covers,
      hasCustomCover: trulyCustom,
    );
  }

  /// Coerces a JSON value that may be a list of paths (or a single path) into a
  /// clean list of non-empty strings.
  static List<String> _stringList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toList();
    }
    final single = value?.toString();
    return (single != null && single.isNotEmpty) ? [single] : [];
  }
}
