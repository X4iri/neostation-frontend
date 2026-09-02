import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:provider/provider.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';

class TacoCalibrationView extends StatefulWidget {
  const TacoCalibrationView({super.key});

  @override
  State<TacoCalibrationView> createState() => _TacoCalibrationViewState();
}

class _TacoCalibrationViewState extends State<TacoCalibrationView> {
  late bool _enabled;
  late double _ratio;
  late String _alignment;

  @override
  void initState() {
    super.initState();
    final config = context.read<SqliteConfigProvider>().config;
    _enabled = config.tacoEnabled;
    _ratio = config.tacoRatio;
    _alignment = config.tacoAlignment;

    // Force portrait for calibration if enabling
    if (!_enabled) {
      _enabled = true;
    }

    _applyOrientation();
  }

  void _applyOrientation() {
    if (_enabled) {
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
    }
  }

  @override
  void dispose() {
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
      alignment: _alignment,
    );
    SfxService().playEnterSound();
    Navigator.of(context).pop();
  }

  void _cancel() {
    SfxService().playBackSound();
    Navigator.of(context).pop();
  }

  void _toggleAlignment() {
    setState(() {
      _alignment = _alignment == 'top' ? 'bottom' : 'top';
    });
    SfxService().playNavSound();
  }

  void _adjustRatio(double delta) {
    setState(() {
      _ratio = (_ratio + delta).clamp(0.3, 0.8);
    });
    SfxService().playNavSound();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mediaQuery = MediaQuery.of(context);
    final screenHeight = mediaQuery.size.height;
    final screenWidth = mediaQuery.size.width;

    final activeHeight = screenHeight * _ratio;
    final isTop = _alignment == 'top';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Shortcuts(
        shortcuts: <LogicalKeySet, Intent>{
          LogicalKeySet(LogicalKeyboardKey.gameButtonA):
              const _TacoSaveIntent(),
          LogicalKeySet(LogicalKeyboardKey.enter): const _TacoSaveIntent(),
          LogicalKeySet(LogicalKeyboardKey.gameButtonB):
              const _TacoCancelIntent(),
          LogicalKeySet(LogicalKeyboardKey.escape): const _TacoCancelIntent(),
          LogicalKeySet(LogicalKeyboardKey.gameButtonY):
              const _ToggleAlignmentIntent(),
          LogicalKeySet(LogicalKeyboardKey.arrowUp): const _AdjustRatioIntent(
            0.01,
          ),
          LogicalKeySet(LogicalKeyboardKey.arrowDown): const _AdjustRatioIntent(
            -0.01,
          ),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _TacoSaveIntent: CallbackAction<_TacoSaveIntent>(
              onInvoke: (_) => _saveAndExit(),
            ),
            _TacoCancelIntent: CallbackAction<_TacoCancelIntent>(
              onInvoke: (_) => _cancel(),
            ),
            _ToggleAlignmentIntent: CallbackAction<_ToggleAlignmentIntent>(
              onInvoke: (_) => _toggleAlignment(),
            ),
            _AdjustRatioIntent: CallbackAction<_AdjustRatioIntent>(
              onInvoke: (intent) => _adjustRatio(intent.delta),
            ),
          },
          child: Focus(
            autofocus: true,
            child: Stack(
              children: [
                // Live UI Mockup / Semi-transparent guide
                Align(
                  alignment: isTop
                      ? Alignment.topCenter
                      : Alignment.bottomCenter,
                  child: Container(
                    width: screenWidth,
                    height: activeHeight,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      border: Border.all(
                        color: theme.colorScheme.primary,
                        width: 2.r,
                      ),
                    ),
                    child: Center(
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
                                  (screenWidth / activeHeight).toStringAsFixed(
                                    2,
                                  ),
                                )
                                .replaceFirst(
                                  '{width}',
                                  screenWidth.toInt().toString(),
                                )
                                .replaceFirst(
                                  '{height}',
                                  activeHeight.toInt().toString(),
                                ),
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Dividing Line
                Positioned(
                  top: isTop ? activeHeight - 10.r : null,
                  bottom: isTop ? null : activeHeight - 10.r,
                  left: 0,
                  right: 0,
                  child: GestureDetector(
                    onVerticalDragUpdate: (details) {
                      final newHeight = isTop
                          ? details.globalPosition.dy
                          : screenHeight - details.globalPosition.dy;
                      setState(() {
                        _ratio = (newHeight / screenHeight).clamp(0.3, 0.8);
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

                // Controls Overlay
                Positioned(
                  bottom: isTop ? 40.r : null,
                  top: isTop ? null : 40.r,
                  left: 20.r,
                  right: 20.r,
                  child: Card(
                    color: Colors.black.withValues(alpha: 0.8),
                    child: Padding(
                      padding: EdgeInsets.all(16.r),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _ControlHint(
                            label: AppLocale.tacoSaveApply.getString(context),
                            button: 'A / ENTER',
                          ),
                          _ControlHint(
                            label: AppLocale.cancel.getString(context),
                            button: 'B / ESC',
                          ),
                          _ControlHint(
                            label: AppLocale.tacoAlignment.getString(context),
                            button: 'Y',
                          ),
                          _ControlHint(
                            label: AppLocale.tacoRatio.getString(context),
                            button: 'UP / DOWN',
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TacoSaveIntent extends Intent {
  const _TacoSaveIntent();
}

class _TacoCancelIntent extends Intent {
  const _TacoCancelIntent();
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

class _ToggleAlignmentIntent extends Intent {
  const _ToggleAlignmentIntent();
}

class _AdjustRatioIntent extends Intent {
  final double delta;
  const _AdjustRatioIntent(this.delta);
}
