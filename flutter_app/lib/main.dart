import 'package:flutter/material.dart';
import 'screens/files_workbench_screen.dart';
import 'screens/study_workspace.dart';
import 'screens/sync_settings_screen.dart';
import 'state/app_controller.dart';
import 'theme/m3e_motion.dart';
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

  // Cached ThemeData so normal study/file state updates NEVER recompute
  // Material HCT ColorScheme.fromSeed() or trigger AnimatedTheme across the tree.
  late ThemeMode _cachedThemeMode;
  late M3EPalettePreset _cachedPalette;
  late M3EMotionScheme _cachedMotionScheme;
  late ThemeData _lightTheme;
  late ThemeData _darkTheme;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? AppController();
    _cachedThemeMode = _controller.themeMode;
    _cachedPalette = _controller.palette;
    _cachedMotionScheme = _controller.motionScheme;
    _rebuildThemes();
    _controller.addListener(_onControllerChanged);
    if (_ownsController) {
      _controller.init();
    }
  }

  void _rebuildThemes() {
    _lightTheme = buildM3ETheme(
      brightness: Brightness.light,
      palette: _cachedPalette,
      motionScheme: _cachedMotionScheme,
    );
    _darkTheme = buildM3ETheme(
      brightness: Brightness.dark,
      palette: _cachedPalette,
      motionScheme: _cachedMotionScheme,
    );
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

    final themeChanged = _controller.themeMode != _cachedThemeMode ||
        _controller.palette != _cachedPalette ||
        _controller.motionScheme != _cachedMotionScheme;
    if (themeChanged && mounted) {
      setState(() {
        final needThemeRebuild = _controller.palette != _cachedPalette ||
            _controller.motionScheme != _cachedMotionScheme;
        _cachedThemeMode = _controller.themeMode;
        _cachedPalette = _controller.palette;
        _cachedMotionScheme = _controller.motionScheme;
        if (needThemeRebuild) {
          _rebuildThemes();
        }
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
    return MaterialApp(
      title: 'IR4Anki',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: _messengerKey,
      themeMode: _cachedThemeMode,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      home: _DesktopShell(controller: _controller),
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
          RepaintBoundary(
            child: ListenableBuilder(
              listenable: controller,
              builder: (ctx, _) => M3ENavigationRail(
                controller: controller,
                onQuickSyncTap: () => _openQuickSyncDialog(ctx),
              ),
            ),
          ),
          Expanded(
            child: _SectionHost(controller: controller),
          ),
        ],
      ),
    );
  }
}

/// Hosts the 3 top-level workspaces while ensuring inactive tabs:
/// 1. Have `TickerMode(enabled: false)` so no hidden animations tick.
/// 2. Do NOT rebuild when `AppController` notifies while another tab is active.
class _SectionHost extends StatefulWidget {
  const _SectionHost({required this.controller});

  final AppController controller;

  @override
  State<_SectionHost> createState() => _SectionHostState();
}

class _SectionHostState extends State<_SectionHost> {
  late AppSection _activeSection;

  @override
  void initState() {
    super.initState();
    _activeSection = widget.controller.section;
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(_SectionHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      _activeSection = widget.controller.section;
      widget.controller.addListener(_onChanged);
    }
  }

  void _onChanged() {
    if (widget.controller.section != _activeSection && mounted) {
      setState(() => _activeSection = widget.controller.section);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IndexedStack(
      index: _activeSection.index,
      children: [
        _ActiveTabGate(
          controller: widget.controller,
          isActive: _activeSection == AppSection.study,
          builder: () => StudyWorkspace(controller: widget.controller),
        ),
        _ActiveTabGate(
          controller: widget.controller,
          isActive: _activeSection == AppSection.files,
          builder: () => FilesWorkbenchScreen(controller: widget.controller),
        ),
        _ActiveTabGate(
          controller: widget.controller,
          isActive: _activeSection == AppSection.syncSettings,
          builder: () => SyncSettingsScreen(controller: widget.controller),
        ),
      ],
    );
  }
}

class _ActiveTabGate extends StatefulWidget {
  const _ActiveTabGate({
    required this.controller,
    required this.isActive,
    required this.builder,
  });

  final AppController controller;
  final bool isActive;
  final Widget Function() builder;

  @override
  State<_ActiveTabGate> createState() => _ActiveTabGateState();
}

class _ActiveTabGateState extends State<_ActiveTabGate> {
  bool _hasBeenActivated = false;

  @override
  void initState() {
    super.initState();
    _hasBeenActivated = widget.isActive;
    if (widget.isActive) {
      widget.controller.addListener(_onControllerUpdate);
    }
  }

  @override
  void didUpdateWidget(_ActiveTabGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive) {
      _hasBeenActivated = true;
    }
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.isActive) {
        oldWidget.controller.removeListener(_onControllerUpdate);
      }
      if (widget.isActive) {
        widget.controller.addListener(_onControllerUpdate);
      }
    } else if (oldWidget.isActive != widget.isActive) {
      if (widget.isActive) {
        widget.controller.addListener(_onControllerUpdate);
      } else {
        widget.controller.removeListener(_onControllerUpdate);
      }
    }
  }

  void _onControllerUpdate() {
    if (mounted && widget.isActive) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerUpdate);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasBeenActivated) {
      return const SizedBox.shrink();
    }
    return RepaintBoundary(
      child: TickerMode(
        enabled: widget.isActive,
        child: widget.builder(),
      ),
    );
  }
}
