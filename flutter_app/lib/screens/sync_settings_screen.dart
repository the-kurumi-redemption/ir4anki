import 'package:flutter/material.dart';
import '../state/app_controller.dart';
import '../theme/m3e_motion.dart';
import '../theme/m3e_shapes.dart';
import '../theme/m3e_theme.dart';
import '../theme/m3e_typography.dart';
import '../widgets/m3e/m3e_button.dart';

/// Standalone App Sync, Server Connection & Material 3 Expressive Appearance Hub.
class SyncSettingsScreen extends StatefulWidget {
  const SyncSettingsScreen({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends State<SyncSettingsScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;
  bool _backingUp = false;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: widget.controller.api.baseUrl);
    _tokenCtrl = TextEditingController(text: widget.controller.api.engineToken);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _triggerBackup() async {
    setState(() => _backingUp = true);
    try {
      await widget.controller.api.triggerEngineBackup();
      widget.controller.showMessage('引擎快照备份已触发完成');
    } catch (e) {
      widget.controller.showMessage('备份失败（需配置管理 Bearer Token）：$e');
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final ctrl = widget.controller;
    final eng = ctrl.engineStatus;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('同步与外观设置', style: typo.emphasized.headlineMedium),
              const SizedBox(height: 6),
              Text(
                '独立桌面应用直连本地或远程 IR4Anki 后端；支持 Material Design 3 Expressive 动态配色与弹簧动效方案。',
                style: typo.baseline.bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 22),

              // 1. Anki Manual Sync Card
              _SectionCard(
                title: 'Anki 手动同步',
                subtitle: '默认遵循手动同步策略，避免后台意外覆盖撤销槽位',
                icon: Icons.sync_rounded,
                shapeKind: M3EShapeKind.clover4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        _StatusChip(
                          label: '引擎模式',
                          value: eng?.backend ?? '未知',
                        ),
                        _StatusChip(
                          label: '上次同步成功',
                          value: eng?.lastSyncSuccess ?? '尚无记录',
                        ),
                        _StatusChip(
                          label: '本地待同步变更',
                          value: (eng?.localChangesPending ?? false)
                              ? '有变更待同步'
                              : '已与远端一致',
                          highlight: eng?.localChangesPending ?? false,
                        ),
                      ],
                    ),
                    if (eng?.undoAvailable == true ||
                        eng?.syncDeferred == true) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: semantic.warningContainer,
                          borderRadius: BorderRadius.circular(M3ERadius.md),
                        ),
                        child: Text(
                          '提示：当前存在待提交的最近一次评分撤销槽，点击「立即同步」会先提交该评分再同步 AnkiWeb。',
                          style: typo.baseline.bodySmall?.copyWith(
                            color: semantic.warningAccent,
                          ),
                        ),
                      ),
                    ],
                    if (eng?.lastSyncError != null &&
                        eng!.lastSyncError!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: cs.errorContainer,
                          borderRadius: BorderRadius.circular(M3ERadius.md),
                        ),
                        child: Text(
                          '上次同步报错：${eng.lastSyncError}',
                          style: typo.baseline.bodySmall?.copyWith(
                            color: cs.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        M3EButton(
                          label: ctrl.syncing ? '正在同步 AnkiWeb…' : '立即同步 AnkiWeb',
                          icon: Icons.cloud_sync_rounded,
                          size: M3EButtonSize.m,
                          onPressed: ctrl.syncing ? null : ctrl.runManualSync,
                        ),
                        const SizedBox(width: 10),
                        M3EButton(
                          label: '刷新状态',
                          icon: Icons.refresh_rounded,
                          variant: M3EButtonStyleVariant.tonal,
                          size: M3EButtonSize.m,
                          onPressed: ctrl.refreshEngineStatus,
                        ),
                        const SizedBox(width: 10),
                        M3EButton(
                          label: _backingUp ? '备份中…' : '触发快照备份',
                          icon: Icons.backup_outlined,
                          variant: M3EButtonStyleVariant.outlined,
                          size: M3EButtonSize.m,
                          onPressed: _backingUp ? null : _triggerBackup,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // 2. Material 3 Expressive Appearance & Motion Scheme
              _SectionCard(
                title: 'Material Design 3 Expressive 外观与动效',
                subtitle: 'Vibrant 动态色彩、明暗主题与物理弹簧动效方案',
                icon: Icons.palette_outlined,
                shapeKind: M3EShapeKind.flower,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('主题模式', style: typo.emphasized.labelLarge),
                    const SizedBox(height: 8),
                    M3EConnectedButtonGroup<ThemeMode>(
                      selected: ctrl.themeMode,
                      onSelected: ctrl.setThemeMode,
                      items: const [
                        (
                          value: ThemeMode.system,
                          label: '跟随系统',
                          icon: Icons.brightness_auto_rounded,
                          badge: null,
                        ),
                        (
                          value: ThemeMode.light,
                          label: '浅色',
                          icon: Icons.light_mode_rounded,
                          badge: null,
                        ),
                        (
                          value: ThemeMode.dark,
                          label: '深色',
                          icon: Icons.dark_mode_rounded,
                          badge: null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text('Vibrant 主题色板', style: typo.emphasized.labelLarge),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        for (final preset in M3EPalettePreset.values)
                          InkWell(
                            onTap: () => ctrl.setPalette(preset),
                            borderRadius: BorderRadius.circular(M3ERadius.lg),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 220),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                              decoration: BoxDecoration(
                                color: ctrl.palette == preset
                                    ? cs.secondaryContainer
                                    : cs.surfaceContainerHigh,
                                borderRadius:
                                    BorderRadius.circular(M3ERadius.lg),
                                border: Border.all(
                                  color: ctrl.palette == preset
                                      ? cs.primary
                                      : Colors.transparent,
                                  width: 1.8,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  M3EShapeContainer(
                                    kind: ctrl.palette == preset
                                        ? M3EShapeKind.softBurst
                                        : M3EShapeKind.circle,
                                    color: preset.seedColor,
                                    size: 22,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    preset.label,
                                    style: typo.emphasized.labelLarge,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Text('动效物理方案（Motion Scheme）',
                        style: typo.emphasized.labelLarge),
                    const SizedBox(height: 8),
                    M3EConnectedButtonGroup<M3EMotionScheme>(
                      selected: ctrl.motionScheme,
                      onSelected: ctrl.setMotionScheme,
                      items: const [
                        (
                          value: M3EMotionScheme.expressive,
                          label: 'Expressive（轻弹表现力）',
                          icon: Icons.auto_awesome_rounded,
                          badge: null,
                        ),
                        (
                          value: M3EMotionScheme.standard,
                          label: 'Standard（克制实用）',
                          icon: Icons.speed_rounded,
                          badge: null,
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // 3. Server Connection Settings
              _SectionCard(
                title: '后端连接配置',
                subtitle: '支持本机 loopback 或 Tailscale / 局域网可信主机',
                icon: Icons.dns_outlined,
                shapeKind: M3EShapeKind.squircle,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _urlCtrl,
                      decoration: const InputDecoration(
                        labelText: 'IR4Anki 后端地址',
                        hintText: 'http://127.0.0.1:8901',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _tokenCtrl,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: '管理 Bearer Token（可选，仅保存在内存中）',
                        hintText: '远程同步或触发备份时填写 ANKI_ENGINE_API_TOKEN',
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        M3EButton(
                          label: '保存并重新连接',
                          icon: Icons.link_rounded,
                          onPressed: () => ctrl.updateServerConfig(
                            _urlCtrl.text,
                            token: _tokenCtrl.text,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 18),

              // 4. Desktop Keyboard Shortcuts Cheat Sheet
              _SectionCard(
                title: '桌面端快捷键速查',
                subtitle: '在学习界面的非输入状态下全局生效',
                icon: Icons.keyboard_rounded,
                shapeKind: M3EShapeKind.arch,
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: const [
                    _ShortcutPill(keys: 'Space', desc: '复习：显示答案 / 阅读：制卡完成'),
                    _ShortcutPill(keys: '1 / 2 / 3 / 4', desc: 'Again / Hard / Good / Easy'),
                    _ShortcutPill(keys: 'A', desc: '阅读：添加问答卡'),
                    _ShortcutPill(keys: 'C', desc: '阅读：用选中文字添加挖空卡'),
                    _ShortcutPill(keys: 'S / N', desc: '阅读：跳过 / 下一张（稍后）'),
                    _ShortcutPill(keys: 'Ctrl+Z', desc: '撤销上次复习评分'),
                    _ShortcutPill(keys: 'Esc', desc: '取消行切分 / 退出溯源 / 关闭制卡抽屉'),
                    _ShortcutPill(keys: 'Ctrl+Shift+C', desc: '挖空抽屉：将选中文字包入 {{cN::…}}'),
                    _ShortcutPill(keys: 'Ctrl+Enter', desc: '制卡抽屉：立即保存卡片'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.shapeKind,
    required this.child,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final M3EShapeKind shapeKind;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? cs.surfaceContainerLow
            : cs.surface,
        borderRadius: BorderRadius.circular(M3ERadius.xl),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              M3EShapeContainer(
                kind: shapeKind,
                color: cs.primaryContainer,
                size: 42,
                child: Icon(icon, size: 20, color: cs.onPrimaryContainer),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: typo.emphasized.titleLarge),
                    Text(subtitle, style: typo.baseline.bodySmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.label,
    required this.value,
    this.highlight = false,
  });

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: highlight ? cs.tertiaryContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(M3ERadius.lg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: typo.baseline.labelSmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: typo.emphasized.labelLarge?.copyWith(
              color: highlight ? cs.onTertiaryContainer : cs.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShortcutPill extends StatelessWidget {
  const _ShortcutPill({required this.keys, required this.desc});

  final String keys;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(M3ERadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: cs.primaryContainer,
              borderRadius: BorderRadius.circular(M3ERadius.sm),
            ),
            child: Text(
              keys,
              style: typo.emphasized.labelSmall?.copyWith(
                color: cs.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(desc, style: typo.baseline.bodySmall),
        ],
      ),
    );
  }
}
