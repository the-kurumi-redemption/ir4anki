import 'package:flutter/material.dart';
import 'screens/files_workbench_screen.dart';
import 'screens/study_workspace.dart';
import 'screens/sync_settings_screen.dart';
import 'state/app_controller.dart';
import 'theme/m3e_theme.dart';
import 'theme/m3e_typography.dart';
import 'widgets/navigation/m3e_nav_rail.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const IR4AnkiDesktopApp());
}

class IR4AnkiDesktopApp extends StatefulWidget {
  const IR4AnkiDesktopApp({super.key, this.controller});

  final AppController? controller;

  @override
  State<IR4AnkiDesktopApp> createState() => _IR4AnkiDesktopAppState();
}

class _IR4AnkiDesktopAppState extends State<IR4AnkiDesktopApp> {
  late final AppController _controller;
  late final bool _ownsController;
  final GlobalKey<ScaffoldMessengerState> _messengerKey = GlobalKey();
  int _lastShownToastEpoch = 0;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? AppController();
    _controller.addListener(_onControllerChanged);
    if (_ownsController) {
      _controller.init();
    }
  }

  void _onControllerChanged() {
    if (_controller.toastEpoch != _lastShownToastEpoch &&
        _controller.toastMessage != null) {
      _lastShownToastEpoch = _controller.toastEpoch;
      final msg = _controller.toastMessage!;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _messengerKey.currentState
          ?..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(msg),
              duration: const Duration(seconds: 4),
            ),
          );
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'IR4Anki',
          debugShowCheckedModeBanner: false,
          scaffoldMessengerKey: _messengerKey,
          themeMode: _controller.themeMode,
          theme: buildM3ETheme(
            brightness: Brightness.light,
            palette: _controller.palette,
            motionScheme: _controller.motionScheme,
          ),
          darkTheme: buildM3ETheme(
            brightness: Brightness.dark,
            palette: _controller.palette,
            motionScheme: _controller.motionScheme,
          ),
          home: _DesktopShell(controller: _controller),
        );
      },
    );
  }
}

class _DesktopShell extends StatelessWidget {
  const _DesktopShell({required this.controller});

  final AppController controller;

  Future<void> _openQuickSyncDialog(BuildContext context) async {
    await controller.refreshEngineStatus();
    if (!context.mounted) return;
    final eng = controller.engineStatus;
    final typo = M3ETypography.of(context);
    final cs = Theme.of(context).colorScheme;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动同步 AnkiWeb'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '上次成功同步：${eng?.lastSyncSuccess ?? '尚无记录'}',
                style: typo.baseline.bodyMedium,
              ),
              const SizedBox(height: 6),
              Text(
                (eng?.localChangesPending ?? false)
                    ? '状态：检测到本地待同步更改'
                    : '状态：本地无明显未同步更改',
                style: typo.baseline.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              if (eng?.undoAvailable == true || eng?.syncDeferred == true) ...[
                const SizedBox(height: 12),
                Text(
                  '注意：同步会先终结当前挂起的「撤销上次评分」槽位。',
                  style: typo.emphasized.bodySmall?.copyWith(color: cs.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(ctx).pop(true),
            icon: const Icon(Icons.sync_rounded, size: 18),
            label: const Text('立即同步'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.runManualSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          M3ENavigationRail(
            controller: controller,
            onQuickSyncTap: () => _openQuickSyncDialog(context),
          ),
          Expanded(
            child: IndexedStack(
              index: controller.section.index,
              children: [
                StudyWorkspace(controller: controller),
                FilesWorkbenchScreen(controller: controller),
                SyncSettingsScreen(controller: controller),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
