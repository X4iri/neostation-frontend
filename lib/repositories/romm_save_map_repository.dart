import '../data/datasources/sqlite_service.dart';
import 'package:neostation/services/logger_service.dart';

/// Repository for the RomM save-sync mapping table (`app_romm_rom_map`).
///
/// Links a local game (its [romname] within a [systemFolder]) to the RomM ROM
/// id it was downloaded from, so save/state sync can target the correct
/// `rom_id`. Per the architecture rules, this is the only layer that touches
/// [SqliteService] for this data.
class RommSaveMapRepository {
  static final _log = LoggerService.instance;

  /// Records (or replaces) the mapping for a downloaded ROM.
  static Future<void> putMapping({
    required String romname,
    required String systemFolder,
    required int rommRomId,
    String? fsName,
  }) async {
    try {
      final db = await SqliteService.getDatabase();
      await db.insert('app_romm_rom_map', {
        'romname': romname,
        'system_folder': systemFolder,
        'romm_rom_id': rommRomId,
        'romm_fs_name': fsName,
        'updated_at': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    } catch (e) {
      _log.e('Error saving RomM rom map ($romname/$systemFolder): $e');
    }
  }

  /// Returns the RomM ROM id for a local game, or null if not mapped.
  static Future<int?> getRommRomId(String romname, String systemFolder) async {
    try {
      final db = await SqliteService.getDatabase();
      final rows = await db.query(
        'app_romm_rom_map',
        columns: ['romm_rom_id'],
        where: 'romname = ? AND system_folder = ?',
        whereArgs: [romname, systemFolder],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return int.tryParse(rows.first['romm_rom_id'].toString());
    } catch (e) {
      _log.e('Error reading RomM rom map ($romname/$systemFolder): $e');
      return null;
    }
  }
}
