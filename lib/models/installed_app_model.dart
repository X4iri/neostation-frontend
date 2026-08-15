import 'dart:typed_data';

/// Metadata for an installed Android application.
class InstalledAppModel {
  final String name;
  final String packageName;
  final bool isSystemApp;
  final bool isGame;
  final Uint8List? icon;
  final bool isFavorite;

  const InstalledAppModel({
    required this.name,
    required this.packageName,
    this.isSystemApp = false,
    this.isGame = false,
    this.icon,
    this.isFavorite = false,
  });

  factory InstalledAppModel.fromMap(Map<String, dynamic> map, {bool isFavorite = false}) {
    return InstalledAppModel(
      name: map['name']?.toString() ?? '',
      packageName: map['package']?.toString() ?? '',
      isSystemApp: map['isSystemApp'] == true || map['isSystemApp'] == 1,
      isGame: map['isGame'] == true || map['isGame'] == 1,
      icon: map['icon'] as Uint8List?,
      isFavorite: isFavorite,
    );
  }

  InstalledAppModel copyWith({
    String? name,
    String? packageName,
    bool? isSystemApp,
    bool? isGame,
    Uint8List? icon,
    bool? isFavorite,
  }) {
    return InstalledAppModel(
      name: name ?? this.name,
      packageName: packageName ?? this.packageName,
      isSystemApp: isSystemApp ?? this.isSystemApp,
      isGame: isGame ?? this.isGame,
      icon: icon ?? this.icon,
      isFavorite: isFavorite ?? this.isFavorite,
    );
  }

  @override
  String toString() => 'InstalledAppModel(name: $name, package: $packageName, isFavorite: $isFavorite)';
}
