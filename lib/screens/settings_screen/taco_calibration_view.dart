import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/gamepad_nav.dart';
import 'package:neostation/services/gamepad/gamepad_navigation_manager.dart';

class TacoCalibrationView extends StatefulWidget {
  const TacoCalibrationView({super.key});

  @override
  State<TacoCalibrationView> createState() => _TacoCalibrationViewState();
}

class _TacoCalibrationViewState extends State<TacoCalibrationView> {
  late bool _enabled;
  late double _ratio;
  late GamepadNavigation _gamepadNav;

  @override
  void initState() {
    super.initState();
    final config = context.read<SqliteConfigProvider>().config;
    _enabled = config.tacoEnabled;
    _ratio = config.tacoRatio;

    // Force portrait for calibration if enabling
    if (!_enabled) {
      _enabled = true;
    }

    _applyOrientation();

    _gamepadNav = GamepadNavigation(
      onNavigateUp: () => _adjustRatio(-0.01), // Shorter -> Higher ratio (Panoramic)
      onNavigateDown: () => _adjustRatio(0.01), // Taller -> Lower ratio (TATE)
      onSelectItem: _saveAndExit,
      onBack: _cancel,
    );
    _gamepadNav.initialize();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // If ratio is the old default or invalid, set it to 1:1 aspect ratio for the current screen
      final mediaQuery = MediaQuery.of(context);
      if (_ratio == 0.55 || _ratio > 1.0) {
        setState(() {
          _ratio = (mediaQuery.size.width / mediaQuery.size.height).clamp(0.1, 1.0);
        });
      }

      GamepadNavigationManager.pushLayer(
        'taco_calibration',
        onActivate: () => _gamepadNav.activate(),
        onDeactivate: () => _gamepadNav.deactivate(),
      );
    });
  }

  void _applyOrientation() {
    if (_enabled) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }

  @override
  void dispose() {
    GamepadNavigationManager.popLayer('taco_calibration');
    _gamepadNav.dispose();

    // Restore orientation if we didn't save
    final config = context.read<SqliteConfigProvider>().config;
    if (!config.tacoEnabled) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
    super.dispose();
  }

  void _saveAndExit() {
    context.read<SqliteConfigProvider>().updateTacoSettings(
      enabled: _enabled,
      ratio: _ratio,
    );
    SfxService().playEnterSound();
    Navigator.of(context).pop();
  }

  void _cancel() {
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _adjustRatio(double delta) {
    final mediaQuery = MediaQuery.of(context);
    final sw = mediaQuery.size.width;
    final sh = mediaQuery.size.height;
    
    // Limits: 
    // Max Aspect Ratio 2.0 -> activeHeight = sw / 2.0 -> _ratio = (sw / 2.0) / sh
    // Min Aspect Ratio Full -> activeHeight = sh -> _ratio = 1.0
    final minRatio = (sw / 2.0) / sh;
    final maxRatio = 1.0;

    setState(() {
      _ratio = (_ratio + delta).clamp(minRatio, maxRatio);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final screenWidth = mediaQuery.size.width;

    final activeHeight = screenHeight * _ratio;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Active Viewport Guide
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              width: screenWidth,
              height: activeHeight,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.1),
                border: Border.all(color: theme.colorScheme.primary, width: 2.r),
              ),
              child: Stack(
                children: [
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Symbols.aspect_ratio,
                          size: 48.r,
                          color: theme.colorScheme.primary,
                        ),
                        SizedBox(height: 16.r),
                        Text(
                          AppLocale.tacoCurrentAspectRatio
                              .getString(context)
                              .replaceFirst(
                                '{ratio}',
                                (screenWidth / activeHeight).toStringAsFixed(2),
                              ),
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),

                  // Controls Legend INSIDE the preview window
                  Positioned(
                    bottom: 20.r,
                    left: 20.r,
                    right: 20.r,
                    child: Container(
                      padding: EdgeInsets.all(12.r),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(8.r),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ControlHint(
                            label: AppLocale.tacoSaveApply.getString(context),
                            button: 'A',
                          ),
                          _ControlHint(
                            label: AppLocale.cancel.getString(context),
                            button: 'B',
                          ),
                          _ControlHint(
                            label: AppLocale.tacoRatio.getString(context),
                            button: 'UP / DOWN',
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Dividing Line (Handle)
          Positioned(
            top: activeHeight - 10.r,
            left: 0,
            right: 0,
            child: GestureDetector(
              onVerticalDragUpdate: (details) {
                final mediaQuery = MediaQuery.of(context);
                final sw = mediaQuery.size.width;
                final sh = mediaQuery.size.height;
                final minRatio = (sw / 2.0) / sh;
                final maxRatio = 1.0;

                setState(() {
                  _ratio =
                      (details.globalPosition.dy / screenHeight).clamp(minRatio, maxRatio);
                });
              },
              child: Container(
                height: 20.r,
                color: Colors.transparent,
                child: Center(
                  child: Container(
                    width: screenWidth,
                    height: 2.r,
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ControlHint extends StatelessWidget {
  final String label;
  final String button;

  const _ControlHint({required this.label, required this.button});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4.r),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Container(
            padding: EdgeInsets.symmetric(horizontal: 8.r, vertical: 2.r),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              borderRadius: BorderRadius.circular(4.r),
            ),
            child: Text(
              button,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
