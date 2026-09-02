import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:provider/provider.dart';
import 'package:neostation/l10n/app_locale.dart';
import 'package:neostation/providers/sqlite_config_provider.dart';
import 'package:neostation/services/sfx_service.dart';
import 'package:neostation/utils/adaptive_scroll.dart';
import 'widgets/setting_row.dart';
import '../taco_calibration_view.dart';
import 'settings_title.dart';
import '../../../widgets/custom_toggle_switch.dart';

class DisplaySettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const DisplaySettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<DisplaySettingsContent> createState() => DisplaySettingsContentState();
}

class DisplaySettingsContentState extends State<DisplaySettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = [GlobalKey(), GlobalKey()];
  final AdaptiveScroller _scroller = AdaptiveScroller();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  int getItemCount() => 2;

  void selectItem(int index) {
    SfxService().playNavSound();
    final configProvider = context.read<SqliteConfigProvider>();

    if (index == 0) {
      final enabled = configProvider.config.tacoEnabled;
      configProvider.updateTacoSettings(enabled: !enabled);
    } else if (index == 1) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => const TacoCalibrationView()),
      );
    }
  }

  void scrollToIndex(int index) {
    _scroller.ensureVisibleIndex(
      index,
      keys: _itemKeys,
      controller: _scrollController,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<SqliteConfigProvider>();
    final config = provider.config;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingsTitle(title: AppLocale.display.getString(context)),
        SizedBox(height: 12.r),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            physics: const ClampingScrollPhysics(),
            child: Column(
              children: [
                SettingRow(
                  key: _itemKeys[0],
                  onTap: () => selectItem(0),
                  focused:
                      widget.isContentFocused &&
                      widget.selectedContentIndex == 0,
                  title: AppLocale.tacoMode.getString(context),
                  subtitle: AppLocale.tacoModeSubtitle.getString(context),
                  trailing: CustomToggleSwitch(
                    value: config.tacoEnabled,
                    onChanged: (value) =>
                        provider.updateTacoSettings(enabled: value),
                    activeColor: theme.colorScheme.primary,
                  ),
                ),
                SizedBox(height: 12.r),
                SettingRow(
                  key: _itemKeys[1],
                  onTap: () => selectItem(1),
                  focused:
                      widget.isContentFocused &&
                      widget.selectedContentIndex == 1,
                  title: AppLocale.tacoCalibration.getString(context),
                  subtitle:
                      '${AppLocale.tacoRatio.getString(context)}: ${config.tacoRatio.toStringAsFixed(2)}',
                  trailing: Icon(
                    Symbols.tune,
                    size: 20.r,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
