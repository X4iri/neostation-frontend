import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/models/installed_app_model.dart';
import 'package:neostation/providers/installed_apps_provider.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart';

class AppManagementModal extends StatefulWidget {
  final InstalledAppModel app;

  const AppManagementModal({super.key, required this.app});

  @override
  State<AppManagementModal> createState() => _AppManagementModalState();
}

class _AppManagementModalState extends State<AppManagementModal> {
  int _selectedIndex = 0;
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onSelectItem: _handleSelect,
      onBack: () => Navigator.pop(context),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gamepadNav.initialize();
      GamepadNavigationManager.pushLayer(
        'app_management_modal',
        modal: true,
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('app_management_modal');
    _gamepadNav.dispose();
    super.dispose();
  }

  void _navigateUp() {
    setState(() {
      _selectedIndex = (_selectedIndex - 1 + 3) % 3;
    });
    SfxService().playNavSound();
  }

  void _navigateDown() {
    setState(() {
      _selectedIndex = (_selectedIndex + 1) % 3;
    });
    SfxService().playNavSound();
  }

  void _handleSelect() {
    final provider = context.read<InstalledAppsProvider>();
    SfxService().playEnterSound();

    switch (_selectedIndex) {
      case 0:
        AndroidService.openAppInfo(widget.app.packageName);
        Navigator.pop(context);
        break;
      case 1:
        AndroidService.uninstallApp(widget.app.packageName);
        Navigator.pop(context);
        break;
      case 2:
        provider.toggleFavorite(widget.app.packageName);
        Navigator.pop(context);
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<InstalledAppsProvider>();
    final isFav = provider.isFavorite(widget.app.packageName);

    final favLabel = isFav 
        ? AppLocale.removeFromFavorites.getString(context) 
        : AppLocale.addToFavorites.getString(context);

    final actions = [
      _ModalAction(
        icon: Icons.info_outline_rounded,
        label: AppLocale.appInfo.getString(context),
        onTap: () {
          AndroidService.openAppInfo(widget.app.packageName);
          Navigator.pop(context);
        },
      ),
      _ModalAction(
        icon: Icons.delete_outline_rounded,
        label: AppLocale.uninstall.getString(context),
        onTap: () {
          AndroidService.uninstallApp(widget.app.packageName);
          Navigator.pop(context);
        },
      ),
      _ModalAction(
        icon: isFav ? Icons.star_border_rounded : Icons.star_rounded,
        label: favLabel,
        onTap: () {
          provider.toggleFavorite(widget.app.packageName);
          Navigator.pop(context);
        },
      ),
    ];

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(horizontal: 100.r),
      child: Container(
        width: 300.r,
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor.withValues(alpha: 0.95),
          borderRadius: theme.extension<CornerRadii>()?.radiusExternal ?? BorderRadius.circular(24.r),
          border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.2)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.all(24.r),
              child: Column(
                children: [
                  if (widget.app.icon != null)
                    Image.memory(widget.app.icon!, width: 64.r, height: 64.r)
                  else
                    Icon(Icons.android, size: 64.r),
                  SizedBox(height: 16.r),
                  Text(
                    widget.app.name,
                    style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            ...actions.asMap().entries.map((entry) {
              final index = entry.key;
              final action = entry.value;
              final isFocused = index == _selectedIndex;

              return InkWell(
                onTap: () {
                  SfxService().playEnterSound();
                  action.onTap();
                },
                onHover: (hovering) {
                  if (hovering) setState(() => _selectedIndex = index);
                },
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 16.r),
                  color: isFocused ? theme.colorScheme.primary.withValues(alpha: 0.1) : null,
                  child: Row(
                    children: [
                      Icon(action.icon, color: isFocused ? theme.colorScheme.primary : null),
                      SizedBox(width: 16.r),
                      Text(
                        action.label,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: isFocused ? theme.colorScheme.primary : null,
                          fontWeight: isFocused ? FontWeight.bold : null,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }),
            SizedBox(height: 8.r),
          ],
        ),
      ),
    );
  }
}

class _ModalAction {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  _ModalAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
}
