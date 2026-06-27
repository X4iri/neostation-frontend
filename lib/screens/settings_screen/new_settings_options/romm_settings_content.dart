import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../../l10n/app_locale.dart';
import '../../../providers/romm_provider.dart';
import '../../../providers/sqlite_config_provider.dart';
import '../../../sync/providers/neo_sync_adapter.dart';
import '../../../sync/providers/romm_provider.dart';
import '../../../sync/sync_manager.dart';
import '../../../widgets/custom_notification.dart';
import '../../romm_screen/romm_browse_screen.dart';
import 'settings_title.dart';

/// Settings panel for the RomM integration: server credentials, test/connect,
/// disconnect, and an entry point into the library browser.
class RommSettingsContent extends StatefulWidget {
  final bool isContentFocused;
  final int selectedContentIndex;

  const RommSettingsContent({
    super.key,
    required this.isContentFocused,
    required this.selectedContentIndex,
  });

  @override
  State<RommSettingsContent> createState() => RommSettingsContentState();
}

class RommSettingsContentState extends State<RommSettingsContent> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _itemKeys = [];

  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _userController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _urlFocus = FocusNode();
  final FocusNode _userFocus = FocusNode();
  final FocusNode _passwordFocus = FocusNode();

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < 6; i++) {
      _itemKeys.add(GlobalKey());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<RommProvider>();
      _urlController.text = provider.serverUrl;
      _userController.text = provider.username;
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _urlFocus.dispose();
    _userFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  // ── Gamepad/settings contract ───────────────────────────────────────────────

  int getItemCount() {
    final connected = context.read<RommProvider>().isConnected;
    return connected ? 3 : 4;
  }

  void selectItem(int index) {
    final provider = context.read<RommProvider>();
    if (provider.isConnected) {
      switch (index) {
        case 0:
          _openBrowser();
          break;
        case 1:
          _toggleSaveSync();
          break;
        case 2:
          _disconnect();
          break;
      }
      return;
    }
    switch (index) {
      case 0:
        _urlFocus.requestFocus();
        break;
      case 1:
        _userFocus.requestFocus();
        break;
      case 2:
        _passwordFocus.requestFocus();
        break;
      case 3:
        _connect();
        break;
    }
  }

  void scrollToIndex(int index) {
    if (index >= 0 && index < _itemKeys.length) {
      final ctx = _itemKeys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: 0.5,
        );
      }
    }
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  bool _validateInputs() {
    if (_urlController.text.trim().isEmpty ||
        _userController.text.trim().isEmpty ||
        _passwordController.text.isEmpty) {
      AppNotification.showNotification(
        context,
        AppLocale.rommCredentialsRequired.getString(context),
        type: NotificationType.error,
      );
      return false;
    }
    return true;
  }

  Future<void> _connect() async {
    if (_busy || !_validateInputs()) return;
    setState(() => _busy = true);
    final provider = context.read<RommProvider>();
    final error = await provider.connect(
      serverUrl: _urlController.text.trim(),
      username: _userController.text.trim(),
      password: _passwordController.text,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      AppNotification.showNotification(
        context,
        error,
        type: NotificationType.error,
      );
    } else {
      _passwordController.clear();
      AppNotification.showNotification(
        context,
        AppLocale.rommConnectionSuccess.getString(context),
        type: NotificationType.success,
      );
    }
  }

  Future<void> _disconnect() async {
    final provider = context.read<RommProvider>();
    await provider.disconnect();
    if (!mounted) return;
    _passwordController.clear();
    setState(() {});
  }

  void _openBrowser() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const RommBrowseScreen()));
  }

  bool get _isSaveSyncActive =>
      SyncManager.instance.activeProviderId == RomMSyncProvider.kProviderId;

  /// Toggles whether RomM is the active save-sync provider (vs NeoSync).
  Future<void> _toggleSaveSync() async {
    final persist = context
        .read<SqliteConfigProvider>()
        .updateActiveSyncProvider;
    final target = _isSaveSyncActive
        ? NeoSyncAdapter.kProviderId
        : RomMSyncProvider.kProviderId;
    await SyncManager.instance.setActive(target, persist: persist);
    if (!mounted) return;
    setState(() {});
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  bool _isSelected(int index) =>
      widget.isContentFocused && widget.selectedContentIndex == index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = context.watch<RommProvider>();

    return SingleChildScrollView(
      controller: _scrollController,
      physics: const ClampingScrollPhysics(),
      padding: EdgeInsets.only(bottom: 24.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SettingsTitle(title: AppLocale.rommLibrary.getString(context)),
          SizedBox(height: 8.r),
          _buildStatusLine(theme, provider),
          SizedBox(height: 12.r),
          if (provider.isConnected)
            ..._buildConnectedRows(theme)
          else
            ..._buildCredentialRows(theme),
        ],
      ),
    );
  }

  Widget _buildStatusLine(ThemeData theme, RommProvider provider) {
    final connected = provider.isConnected;
    final String text;
    if (connected) {
      text = AppLocale.rommConnectedAs
          .getString(context)
          .replaceAll('{user}', provider.username);
    } else if (provider.status == RommConnectionStatus.connecting) {
      text = AppLocale.rommConnecting.getString(context);
    } else {
      text = AppLocale.rommStatusDisconnected.getString(context);
    }
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Row(
        children: [
          Icon(
            connected ? Symbols.cloud_done_rounded : Symbols.cloud_off_rounded,
            size: 16.r,
            color: connected
                ? Colors.greenAccent
                : theme.colorScheme.onSurface.withValues(alpha: 0.5),
          ),
          SizedBox(width: 8.r),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 11.r,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildCredentialRows(ThemeData theme) {
    return [
      _buildFieldRow(
        theme,
        index: 0,
        label: AppLocale.rommServerUrl.getString(context),
        hint: AppLocale.rommServerUrlHint.getString(context),
        controller: _urlController,
        focusNode: _urlFocus,
      ),
      SizedBox(height: 10.r),
      _buildFieldRow(
        theme,
        index: 1,
        label: AppLocale.username.getString(context),
        hint: AppLocale.enterUsername.getString(context),
        controller: _userController,
        focusNode: _userFocus,
      ),
      SizedBox(height: 10.r),
      _buildFieldRow(
        theme,
        index: 2,
        label: AppLocale.password.getString(context),
        hint: AppLocale.enterPassword.getString(context),
        controller: _passwordController,
        focusNode: _passwordFocus,
        obscure: true,
      ),
      SizedBox(height: 14.r),
      _buildActionRow(
        theme,
        index: 3,
        icon: Symbols.link_rounded,
        label: _busy
            ? AppLocale.rommConnecting.getString(context)
            : AppLocale.rommSaveConnect.getString(context),
        primary: true,
        onTap: _connect,
      ),
    ];
  }

  List<Widget> _buildConnectedRows(ThemeData theme) {
    return [
      _buildActionRow(
        theme,
        index: 0,
        icon: Symbols.grid_view_rounded,
        label: AppLocale.rommBrowseLibrary.getString(context),
        primary: true,
        onTap: _openBrowser,
      ),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 1,
        icon: _isSaveSyncActive
            ? Symbols.cloud_done_rounded
            : Symbols.cloud_sync_rounded,
        label: _isSaveSyncActive
            ? AppLocale.rommSaveSyncActive.getString(context)
            : AppLocale.rommUseForSaveSync.getString(context),
        primary: _isSaveSyncActive,
        onTap: _toggleSaveSync,
      ),
      SizedBox(height: 10.r),
      _buildActionRow(
        theme,
        index: 2,
        icon: Symbols.logout_rounded,
        label: AppLocale.rommDisconnect.getString(context),
        onTap: _disconnect,
      ),
    ];
  }

  Widget _buildFieldRow(
    ThemeData theme, {
    required int index,
    required String label,
    required String hint,
    required TextEditingController controller,
    required FocusNode focusNode,
    bool obscure = false,
  }) {
    final selected = _isSelected(index);
    return Container(
      key: _itemKeys[index],
      padding: EdgeInsets.symmetric(horizontal: 12.r),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11.r,
              fontWeight: FontWeight.w500,
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          SizedBox(height: 4.r),
          SizedBox(
            height: 34.r,
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              obscureText: obscure,
              enabled: !_busy,
              style: TextStyle(fontSize: 11.r),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                hintStyle: TextStyle(
                  fontSize: 10.r,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                ),
                filled: true,
                fillColor: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.r),
                  borderSide: BorderSide(
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.primary.withValues(alpha: 0.1),
                    width: selected ? 2.r : 1.r,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.r),
                  borderSide: BorderSide(
                    color: theme.colorScheme.primary,
                    width: 1.5.r,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionRow(
    ThemeData theme, {
    required int index,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool primary = false,
  }) {
    final selected = _isSelected(index);
    final accent = theme.colorScheme.primary;
    return GestureDetector(
      onTap: _busy ? null : onTap,
      child: Container(
        key: _itemKeys[index],
        margin: EdgeInsets.symmetric(horizontal: 12.r),
        padding: EdgeInsets.symmetric(horizontal: 12.r, vertical: 10.r),
        decoration: BoxDecoration(
          color: primary
              ? accent.withValues(alpha: 0.15)
              : theme.colorScheme.surface.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8.r),
          border: Border.all(
            color: selected ? accent : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: 18.r,
              color: selected || primary ? accent : theme.colorScheme.onSurface,
            ),
            SizedBox(width: 10.r),
            Text(
              label,
              style: TextStyle(
                fontSize: 12.r,
                fontWeight: FontWeight.w500,
                color: selected || primary
                    ? accent
                    : theme.colorScheme.onSurface,
              ),
            ),
            if (_busy) ...[
              SizedBox(width: 10.r),
              SizedBox(
                width: 12.r,
                height: 12.r,
                child: CircularProgressIndicator(strokeWidth: 2.r),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
