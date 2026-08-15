import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/providers/installed_apps_provider.dart';
import 'package:neostation/models/installed_app_model.dart';
import 'package:neostation/services/android_service.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/themes/corner_radii.dart';
import 'widgets/app_management_modal.dart';

import 'package:neostation/responsive.dart';

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

  @override
  void initState() {
    super.initState();
    InstalledAppsScreen._currentInstance = this;
  }

  @override
  void dispose() {
    InstalledAppsScreen._currentInstance = null;
    _scrollController.dispose();
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
    return Responsive.getAndroidAppsCrossAxisCount(context);
  }

  void _scrollToSelected() {
    if (!_scrollController.hasClients) return;
    
    final cols = _getCrossAxisCount();
    final row = _selectedIndex ~/ cols;
    final itemWidth = (MediaQuery.of(context).size.width - 32.r - (cols - 1) * 16.r) / cols;
    final itemHeight = itemWidth / 1.0; // childAspectRatio
    final verticalSpacing = 16.r;
    
    final targetOffset = row * (itemHeight + verticalSpacing);
    
    final viewportHeight = MediaQuery.of(context).size.height - 150.r; // Estimated height for header/footer
    final currentOffset = _scrollController.offset;

    if (targetOffset < currentOffset) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    } else if (targetOffset + itemHeight > currentOffset + viewportHeight) {
      _scrollController.animateTo(
        targetOffset + itemHeight - viewportHeight,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
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
                          childAspectRatio: 1.0,
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
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Focus Ring with glow (outside the card)
          if (isSelected)
            Positioned.fill(
              left: -4.r,
              top: -4.r,
              right: -4.r,
              bottom: -4.r,
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: (theme.extension<CornerRadii>()?.radiusExternal ?? BorderRadius.circular(14.r)).add(BorderRadius.circular(4.r)),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.8),
                    width: 2.r,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: theme.colorScheme.primary.withValues(alpha: 0.4),
                      blurRadius: 10.r,
                      spreadRadius: 2.r,
                    )
                  ],
                ),
              ),
            ),
          
          // Actual Card
          Container(
            decoration: BoxDecoration(
              borderRadius: theme.extension<CornerRadii>()?.radiusExternal ?? BorderRadius.circular(14.r),
              color: theme.cardColor.withValues(alpha: 0.5),
            ),
            child: ClipRRect(
              borderRadius: theme.extension<CornerRadii>()?.radiusExternal ?? BorderRadius.circular(14.r),
              child: Stack(
                children: [
                  Center(
                    child: Padding(
                      padding: EdgeInsets.all(12.r),
                      child: app.icon != null
                          ? Image.memory(app.icon!, fit: BoxFit.contain)
                          : Icon(Icons.android, size: 48.r),
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
        ],
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
