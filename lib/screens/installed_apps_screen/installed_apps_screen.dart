import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/installed_apps_provider.dart';
import 'package:neostation/models/installed_app_model.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/game_service.dart' show GamepadNavigationManager;
import 'package:neostation/themes/corner_radii.dart';
import 'widgets/app_management_modal.dart';

class InstalledAppsScreen extends StatefulWidget {
  const InstalledAppsScreen({super.key});

  @override
  State<InstalledAppsScreen> createState() => _InstalledAppsScreenState();

  static void navigateUp() => _currentInstance?._navigateUp();
  static void navigateDown() => _currentInstance?._navigateDown();
  static void navigateLeft() => _currentInstance?._navigateLeft();
  static void navigateRight() => _currentInstance?._navigateRight();
  static void selectCurrent() => _currentInstance?._launchSelectedApp();
  static void openManagement() => _currentInstance?._openManagementModal();

  static _InstalledAppsScreenState? _currentInstance;
}

class _InstalledAppsScreenState extends State<InstalledAppsScreen> {
  int _selectedIndex = 0;
  final ScrollController _scrollController = ScrollController();
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    InstalledAppsScreen._currentInstance = this;
    _gamepadNav = GamepadNavigation(
      onNavigateUp: _navigateUp,
      onNavigateDown: _navigateDown,
      onNavigateLeft: _navigateLeft,
      onNavigateRight: _navigateRight,
      onSelectItem: _launchSelectedApp,
      onFavorite: _openManagementModal,
      onBack: () => GamepadNavigationManager.popLayer('installed_apps_screen'),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      GamepadNavigationManager.pushLayer(
        'installed_apps_screen',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _gamepadNav.dispose();
    super.dispose();
  }

  void _navigateUp() {
    final apps = context.read<InstalledAppsProvider>().apps;
    if (apps.isEmpty) return;
    final cols = _getCrossAxisCount();
    setState(() {
      _selectedIndex = GridNavUtils.navigateUp(
        currentIndex: _selectedIndex,
        crossAxisCount: cols,
        maxItems: apps.length,
      );
    });
    _scrollToSelected();
  }

  void _navigateDown() {
    final apps = context.read<InstalledAppsProvider>().apps;
    if (apps.isEmpty) return;
    final cols = _getCrossAxisCount();
    setState(() {
      _selectedIndex = GridNavUtils.navigateDown(
        currentIndex: _selectedIndex,
        crossAxisCount: cols,
        maxItems: apps.length,
      );
    });
    _scrollToSelected();
  }

  void _navigateLeft() {
    final apps = context.read<InstalledAppsProvider>().apps;
    if (apps.isEmpty) return;
    final cols = _getCrossAxisCount();
    setState(() {
      _selectedIndex = GridNavUtils.navigateLeft(
        currentIndex: _selectedIndex,
        crossAxisCount: cols,
        maxItems: apps.length,
      );
    });
    _scrollToSelected();
  }

  void _navigateRight() {
    final apps = context.read<InstalledAppsProvider>().apps;
    if (apps.isEmpty) return;
    final cols = _getCrossAxisCount();
    setState(() {
      _selectedIndex = GridNavUtils.navigateRight(
        currentIndex: _selectedIndex,
        crossAxisCount: cols,
        maxItems: apps.length,
      );
    });
    _scrollToSelected();
  }

  int _getCrossAxisCount() {
    final width = MediaQuery.of(context).size.width;
    if (width > 1200) return 8;
    if (width > 900) return 6;
    if (width > 600) return 4;
    return 3;
  }

  void _scrollToSelected() {
    // Basic implementation of scroll-into-view
    final cols = _getCrossAxisCount();
    final row = _selectedIndex ~/ cols;
    final itemHeight = 100.r; // Estimated height
    final targetOffset = row * itemHeight;
    
    if (targetOffset < _scrollController.offset) {
      _scrollController.animateTo(targetOffset, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    } else if (targetOffset + itemHeight > _scrollController.offset + MediaQuery.of(context).size.height - 150.r) {
      _scrollController.animateTo(targetOffset - MediaQuery.of(context).size.height + 250.r, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    }
  }

  Future<void> _launchSelectedApp() async {
    final apps = context.read<InstalledAppsProvider>().apps;
    if (apps.isEmpty || _selectedIndex >= apps.length) return;
    
    final app = apps[_selectedIndex];
    SfxService().playEnterSound();
    await AndroidService.launchPackage(app.packageName);
  }

  void _openManagementModal() {
    final apps = context.read<InstalledAppsProvider>().apps;
    if (apps.isEmpty || _selectedIndex >= apps.length) return;
    
    final app = apps[_selectedIndex];
    SfxService().playNavSound();
    
    showDialog(
      context: context,
      builder: (context) => AppManagementModal(app: app),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<InstalledAppsProvider>();
    final apps = provider.apps;

    return Container(
      color: Colors.transparent,
      padding: EdgeInsets.only(top: 46.r),
      child: Column(
        children: [
          Expanded(
            child: provider.isLoading
                ? const Center(child: CircularProgressIndicator())
                : apps.isEmpty
                    ? Center(
                        child: Text(AppLocale.searchNoResults.getString(context)),
                      )
                    : GridView.builder(
                        controller: _scrollController,
                        padding: EdgeInsets.all(16.r),
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: _getCrossAxisCount(),
                          crossAxisSpacing: 16.r,
                          mainAxisSpacing: 16.r,
                          childAspectRatio: 0.9,
                        ),
                        itemCount: apps.length,
                        itemBuilder: (context, index) {
                          final app = apps[index];
                          final isSelected = index == _selectedIndex;
                          return _AppCard(
                            app: app,
                            isSelected: isSelected,
                            onTap: () {
                              setState(() => _selectedIndex = index);
                              _launchSelectedApp();
                            },
                          );
                        },
                      ),
          ),
          if (apps.isNotEmpty && _selectedIndex < apps.length)
            _AppsFooter(app: apps[_selectedIndex]),
        ],
      ),
    );
  }
}

class _AppCard extends StatelessWidget {
  final InstalledAppModel app;
  final bool isSelected;
  final VoidCallback onTap;

  const _AppCard({
    required this.app,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: Theme.of(context).extension<CornerRadii>()?.radiusExternal ?? BorderRadius.circular(14.r),
          border: Border.all(
            color: isSelected ? theme.colorScheme.primary : Colors.transparent,
            width: 2.r,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: theme.colorScheme.primary.withValues(alpha: 0.3),
                    blurRadius: 8.r,
                    spreadRadius: 2.r,
                  )
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: Theme.of(context).extension<CornerRadii>()?.radiusExternal ?? BorderRadius.circular(14.r),
          child: Stack(
            children: [
              Container(
                color: theme.cardColor.withValues(alpha: 0.5),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.all(12.r),
                        child: app.icon != null
                            ? Image.memory(app.icon!, fit: BoxFit.contain)
                            : Icon(Icons.android, size: 48.r),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4.r, vertical: 4.r),
                      child: Text(
                        app.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 10.r,
                          fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (app.isFavorite)
                Positioned(
                  top: 4.r,
                  right: 4.r,
                  child: Icon(
                    Icons.star_rounded,
                    color: Colors.amber,
                    size: 18.r,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AppsFooter extends StatelessWidget {
  final InstalledAppModel app;

  const _AppsFooter({required this.app});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 24.r, vertical: 8.r),
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor.withValues(alpha: 0.9),
        border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.1))),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              app.name.toUpperCase(),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          _FooterAction(
            label: AppLocale.back.getString(context),
            button: 'B',
            color: Colors.lightBlue,
          ),
          SizedBox(width: 16.r),
          _FooterAction(
            label: AppLocale.manage.getString(context),
            button: 'Y',
            color: Colors.blueGrey,
          ),
          SizedBox(width: 16.r),
          _FooterAction(
            label: AppLocale.launch.getString(context),
            button: 'A',
            color: Colors.green,
          ),
        ],
      ),
    );
  }
}

class _FooterAction extends StatelessWidget {
  final String label;
  final String button;
  final Color color;

  const _FooterAction({
    required this.label,
    required this.button,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 4.r),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(16.r),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: EdgeInsets.all(2.r),
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
            child: Text(
              button,
              style: TextStyle(
                color: Colors.black,
                fontSize: 10.r,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          SizedBox(width: 8.r),
          Text(
            label,
            style: TextStyle(
              fontSize: 12.r,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
