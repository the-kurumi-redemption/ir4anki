import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../state/app_controller.dart';
import '../theme/m3e_motion.dart';
import '../theme/m3e_shapes.dart';
import '../theme/m3e_typography.dart';
import '../widgets/m3e/m3e_button.dart';
import '../widgets/m3e/m3e_indicators.dart';
import '../widgets/study/card_authoring_drawer.dart';
import '../widgets/study/flashcard_view.dart';
import '../widgets/study/reading_card_view.dart';
import '../widgets/study/supporting_pane.dart';
import 'start_screen.dart';

/// Unified Study Workspace orchestrating:
/// - Loading (M3E shape-morphing indicator) & Reconnect Error screen
/// - StartScreen (Hero daily plan & round summary)
/// - Draggable Desktop Split-Pane (`ReadingCard` / `Flashcard` ↔ `SupportingPane`)
/// - Non-Modal Floating `CardAuthoringDrawer` over the right pane
/// - Global Study Keyboard Shortcuts (`Space`, `1-4`, `A`, `C`, `S`, `N`, `Esc`, `Ctrl+Z`)
class StudyWorkspace extends StatefulWidget {
  const StudyWorkspace({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<StudyWorkspace> createState() => _StudyWorkspaceState();
}

class _StudyWorkspaceState extends State<StudyWorkspace> {
  final GlobalKey<ReadingCardViewState> _readingCardKey = GlobalKey();
  bool _narrowShowSupporting = false;
  late final TextEditingController _quickUrlCtrl;

  @override
  void initState() {
    super.initState();
    _quickUrlCtrl = TextEditingController(text: widget.controller.api.baseUrl);
    HardwareKeyboard.instance.addHandler(_handleGlobalKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleGlobalKey);
    _quickUrlCtrl.dispose();
    super.dispose();
  }

  bool _isTextInputFocused() {
    final focus = FocusManager.instance.primaryFocus;
    final ctx = focus?.context;
    if (ctx == null) return false;
    return ctx.widget is EditableText ||
        ctx.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  bool _handleGlobalKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final ctrl = widget.controller;
    if (ctrl.section != AppSection.study) return false;
    if (ctrl.authoringRequest != null) return false;
    if (_isTextInputFocused()) return false;
    // Do not intercept when a modal dialog route is active on top
    if (ModalRoute.of(context)?.isCurrent == false) return false;

    final key = event.logicalKey;
    final isCtrlOrMeta = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final phase = ctrl.studyPhase;

    // Ctrl/Cmd + Z -> Undo last review answer
    if (isCtrlOrMeta && key == LogicalKeyboardKey.keyZ) {
      if ((phase == StudyViewPhase.review || phase == StudyViewPhase.reading) &&
          (ctrl.session?.canUndo ?? false)) {
        ctrl.undoLastAnswer();
        return true;
      }
      return false;
    }

    if (isCtrlOrMeta || HardwareKeyboard.instance.isAltPressed) return false;

    if (phase == StudyViewPhase.review) {
      if (!ctrl.isCurrentCardRevealed && key == LogicalKeyboardKey.space) {
        ctrl.revealCurrentCard();
        return true;
      }
      if (ctrl.isCurrentCardRevealed) {
        if (key == LogicalKeyboardKey.digit1) {
          ctrl.answerCurrentCard(1);
          return true;
        }
        if (key == LogicalKeyboardKey.digit2) {
          ctrl.answerCurrentCard(2);
          return true;
        }
        if (key == LogicalKeyboardKey.digit3) {
          ctrl.answerCurrentCard(3);
          return true;
        }
        if (key == LogicalKeyboardKey.digit4) {
          ctrl.answerCurrentCard(4);
          return true;
        }
      }
      return false;
    }

    if (phase == StudyViewPhase.reading) {
      if (key == LogicalKeyboardKey.escape) {
        return _readingCardKey.currentState?.clearLinePickIfActive() ?? false;
      }
      if (key == LogicalKeyboardKey.space) {
        ctrl.actOnCurrentReading('complete');
        return true;
      }
      if (key == LogicalKeyboardKey.keyA) {
        ctrl.openAddQaDrawer();
        return true;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _readingCardKey.currentState?.openClozeFromSelection();
        return true;
      }
      if (key == LogicalKeyboardKey.keyS) {
        ctrl.actOnCurrentReading('skip');
        return true;
      }
      if (key == LogicalKeyboardKey.keyN) {
        ctrl.actOnCurrentReading('next');
        return true;
      }
      return false;
    }

    if (phase == StudyViewPhase.trace) {
      if (key == LogicalKeyboardKey.escape) {
        if (_readingCardKey.currentState?.clearLinePickIfActive() ?? false) {
          return true;
        }
        ctrl.exitTraceDetour();
        return true;
      }
      if (key == LogicalKeyboardKey.keyA) {
        ctrl.openAddQaDrawer();
        return true;
      }
      if (key == LogicalKeyboardKey.keyC) {
        _readingCardKey.currentState?.openClozeFromSelection();
        return true;
      }
    }

    return false;
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = widget.controller;
    final phase = ctrl.studyPhase;

    switch (phase) {
      case StudyViewPhase.loading:
        return _buildLoading(context);
      case StudyViewPhase.error:
        return _buildError(context);
      case StudyViewPhase.start:
        return StartScreen(controller: ctrl);
      case StudyViewPhase.reading:
      case StudyViewPhase.review:
      case StudyViewPhase.trace:
        return _buildSplitStudyWorkspace(context, phase);
    }
  }

  Widget _buildLoading(BuildContext context) {
    final typo = M3ETypography.of(context);
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const M3ELoadingIndicator(size: 72),
          const SizedBox(height: 18),
          Text('正在连接 IR4Anki 本地引擎…', style: typo.emphasized.titleMedium),
          const SizedBox(height: 6),
          Text(
            widget.controller.api.baseUrl,
            style: typo.baseline.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final ctrl = widget.controller;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Container(
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(M3ERadius.xl),
            border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.5)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  M3EShapeContainer(
                    kind: M3EShapeKind.softBurst,
                    color: cs.errorContainer,
                    size: 52,
                    child: Icon(Icons.cloud_off_rounded,
                        color: cs.onErrorContainer),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('无法连接后端服务',
                            style: typo.emphasized.titleLarge),
                        Text(
                          '请确认 ir4anki.service 或 Uvicorn 正在运行',
                          style: typo.baseline.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.errorContainer.withValues(alpha: 0.45),
                  borderRadius: BorderRadius.circular(M3ERadius.md),
                ),
                child: Text(
                  ctrl.connectionError ?? '未知连接错误',
                  style: typo.baseline.bodySmall
                      ?.copyWith(color: cs.onErrorContainer),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _quickUrlCtrl,
                decoration: const InputDecoration(
                  labelText: '后端地址',
                  hintText: 'http://127.0.0.1:8901',
                ),
                onSubmitted: (v) => ctrl.updateServerConfig(v),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  M3EButton(
                    label: '更新地址并重连',
                    icon: Icons.refresh_rounded,
                    onPressed: () =>
                        ctrl.updateServerConfig(_quickUrlCtrl.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryCard(StudyViewPhase phase) {
    final ctrl = widget.controller;
    if (phase == StudyViewPhase.reading || phase == StudyViewPhase.trace) {
      final chunk = ctrl.currentReadingChunk;
      if (chunk == null) return const SizedBox.shrink();
      return ReadingCardView(
        key: _readingCardKey,
        controller: ctrl,
        chunk: chunk,
        isTrace: phase == StudyViewPhase.trace,
      );
    }
    final card = ctrl.currentReviewCard;
    if (card == null) return const SizedBox.shrink();
    return FlashcardView(
      controller: ctrl,
      card: card,
    );
  }

  Widget _buildSplitStudyWorkspace(BuildContext context, StudyViewPhase phase) {
    final ctrl = widget.controller;
    final cs = Theme.of(context).colorScheme;
    final motion = M3EMotionTokens.of(context);
    final authoring = ctrl.authoringRequest;

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1020;

        if (!isWide) {
          return Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: M3EConnectedButtonGroup<bool>(
                    selected: _narrowShowSupporting,
                    expand: true,
                    size: M3EButtonSize.s,
                    onSelected: (v) =>
                        setState(() => _narrowShowSupporting = v),
                    items: const [
                      (
                        value: false,
                        label: '当前学习卡',
                        icon: Icons.auto_stories_rounded,
                        badge: null,
                      ),
                      (
                        value: true,
                        label: '全文参考 / 相关卡片',
                        icon: Icons.chrome_reader_mode_outlined,
                        badge: null,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _narrowShowSupporting
                            ? SupportingPane(controller: ctrl)
                            : _buildPrimaryCard(phase),
                      ),
                      if (authoring != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: constraints.maxHeight * 0.62,
                          child: CardAuthoringDrawer(
                            controller: ctrl,
                            request: authoring,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // Desktop Wide Split-Pane with Draggable Divider + Floating Right Authoring Drawer
        final totalWidth = constraints.maxWidth - 32; // outer horizontal padding
        const dividerWidth = 14.0;
        final usable = (totalWidth - dividerWidth).clamp(400.0, 2400.0);
        final leftWidth = usable * ctrl.splitRatio;
        final rightWidth = usable - leftWidth;

        return Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: leftWidth,
                child: _buildPrimaryCard(phase),
              ),
              // Draggable Split Divider
              MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onHorizontalDragUpdate: (details) {
                    final nextRatio =
                        (leftWidth + details.delta.dx) / usable;
                    ctrl.setSplitRatio(nextRatio);
                  },
                  child: SizedBox(
                    width: dividerWidth,
                    child: Center(
                      child: Container(
                        width: 4,
                        height: 44,
                        decoration: BoxDecoration(
                          color: cs.outlineVariant.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(M3ERadius.full),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // Right Supporting Pane + Non-Modal Floating CardAuthoringDrawer
              SizedBox(
                width: rightWidth,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: SupportingPane(controller: ctrl),
                    ),
                    AnimatedPositioned(
                      duration: motion.defaultSpatial.fallbackDuration,
                      curve: motion.defaultSpatial.fallbackCurve,
                      top: 0,
                      bottom: 0,
                      right: authoring != null ? 0 : -(rightWidth + 32),
                      width: rightWidth,
                      child: authoring != null
                          ? CardAuthoringDrawer(
                              controller: ctrl,
                              request: authoring,
                            )
                          : const SizedBox.shrink(),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
