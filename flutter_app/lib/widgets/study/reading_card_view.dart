import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../models/ir4anki_models.dart';
import '../../services/cloze_engine.dart';
import '../../services/line_split_engine.dart';
import '../../state/app_controller.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_theme.dart';
import '../../theme/m3e_typography.dart';
import '../m3e/m3e_button.dart';
import '../m3e/m3e_floating_toolbar.dart';
import '../markdown/ir_markdown_view.dart';

/// ReadingCard (渐进制卡核心卡片) — supports both `round` and `trace` (溯源) variants.
///
/// Faithfully implements every cognitive invariant from the web frontend:
/// - Whole-file seeding + recursive bookmark splitting via gutter line handles
///   (click line dot or double-click line; clicking inside range cancels;
///   clicking outside moves the nearest endpoint).
/// - Head & Tail line preview confirmation dialog before splitting.
/// - Text selection → Cloze seeding (wraps selected text inside whole chunk
///   raw Markdown with balanced emphasis swallowing).
/// - Stand-off AI Highlight & Comment Layer toggle (zero source mutation).
/// - In-app split-pane Segment Editor (`SegEditDialog`) with live KaTeX preview
///   and note image upload (`![](:/<resource_id>)`).
/// - Status bottom dock (`结束阅读`, `跳过 [S]`, `下一张 [N]`, `制卡完成 [Space]`).
class ReadingCardView extends StatefulWidget {
  const ReadingCardView({
    super.key,
    required this.controller,
    required this.chunk,
    this.isTrace = false,
  });

  final AppController controller;
  final ReadingChunk chunk;
  final bool isTrace;

  @override
  State<ReadingCardView> createState() => ReadingCardViewState();
}

class ReadingCardViewState extends State<ReadingCardView> {
  LineSplitSelection? _pick;
  String _selectedText = '';
  String _selectedBlock = '';
  final ScrollController _scrollController = ScrollController();

  @override
  void didUpdateWidget(ReadingCardView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chunk.chunkKey != widget.chunk.chunkKey ||
        oldWidget.chunk.path != widget.chunk.path ||
        oldWidget.chunk.text != widget.chunk.text) {
      _pick = null;
      _selectedText = '';
      _selectedBlock = '';
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  /// Called by keyboard shortcut `Escape` to clear active line-split pick.
  bool clearLinePickIfActive() {
    if (_pick == null) return false;
    setState(() => _pick = null);
    return true;
  }

  /// Called by keyboard shortcut `C` or toolbar button to seed Cloze dialog
  /// with the current text selection wrapped in `{{c1::...}}`.
  void openClozeFromSelection() {
    final raw = widget.chunk.text;
    final seeded = _selectedText.trim().isNotEmpty
        ? (wrapSelectionAsCloze(
              raw,
              _selectedText,
              ordinal: 1,
              containingBlock: _selectedBlock,
            ) ??
            raw)
        : raw;
    widget.controller.openAddClozeDrawer(seeded);
  }

  void _onLineTap(int startLine, int endLine) {
    if (!widget.chunk.canSplit || widget.controller.busy) return;
    setState(() {
      _pick = LineSplitSelection.togglePick(_pick, startLine, endLine);
    });
  }

  Future<void> _openSplitDialog() async {
    final pick = _pick;
    if (pick == null) return;
    final preview = pick.previewHeadTail(widget.chunk.text);
    final fileStart = widget.chunk.lineStart + pick.startLine - 1;
    final fileEnd = widget.chunk.lineStart + pick.endLine - 1;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final cs = Theme.of(ctx).colorScheme;
        final typo = M3ETypography.of(ctx);
        return AlertDialog(
          title: const Text('确认书签切分'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '将第 $fileStart–$fileEnd 行（共 ${pick.lineCount} 行）切分为当前待制卡子片段，原文保持不变；未读尾部将留给后续轮次。',
                  style: typo.baseline.bodyMedium
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                _PreviewBox(label: '起始行（第 $fileStart 行）', text: preview.head),
                const SizedBox(height: 8),
                _PreviewBox(label: '结束行（第 $fileEnd 行）', text: preview.tail),
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
              icon: const Icon(Icons.content_cut_rounded, size: 18),
              label: const Text('确认切分'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      final ok = await widget.controller.splitCurrentReading(pick);
      if (ok && mounted) {
        setState(() => _pick = null);
      }
    }
  }

  Future<void> _openSegEditDialog() async {
    if (widget.chunk.segId == null) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _SegEditDialog(
        controller: widget.controller,
        chunk: widget.chunk,
      ),
    );
  }

  String _statusLabel(String status) => switch (status) {
        'todo' => '未读',
        'active' => '正在制卡',
        'done' => '已完成',
        'skipped' => '已跳过',
        'background' => '上下文背景',
        'container' => '父容器',
        _ => status,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final ctrl = widget.controller;
    final chunk = widget.chunk;
    final anns = ctrl.cachedAnnotations(chunk.path);

    final breadcrumb = chunk.headingPath.isNotEmpty
        ? chunk.headingPath.join(' › ')
        : chunk.title;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).brightness == Brightness.dark
            ? cs.surfaceContainerLow
            : cs.surface,
        borderRadius: BorderRadius.circular(M3ERadius.xl),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.45)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with Breadcrumb + M3E Floating Toolbar
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 16, 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: widget.isTrace
                                  ? cs.tertiaryContainer
                                  : semantic.readingContainer,
                              borderRadius:
                                  BorderRadius.circular(M3ERadius.full),
                            ),
                            child: Text(
                              widget.isTrace
                                  ? '溯源 · ${_statusLabel(chunk.status)}'
                                  : '阅读 · ${_statusLabel(chunk.status)}',
                              style: typo.emphasized.labelSmall?.copyWith(
                                color: widget.isTrace
                                    ? cs.onTertiaryContainer
                                    : semantic.onReadingContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'L${chunk.lineStart}–${chunk.lineEnd}',
                            style: typo.baseline.labelSmall,
                          ),
                          if (chunk.cardsCreated.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              '已制 ${chunk.cardsCreated.length} 卡',
                              style: typo.emphasized.labelSmall?.copyWith(
                                color: cs.primary,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        breadcrumb,
                        style: typo.emphasized.titleMedium,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Expressive Floating Pill Toolbar
                M3EFloatingToolbar(
                  children: [
                    if (widget.isTrace)
                      M3EIconToggleButton(
                        icon: Icons.arrow_back_rounded,
                        selected: false,
                        tooltip: '回到复习 [Esc]',
                        onPressed: ctrl.exitTraceDetour,
                      )
                    else
                      M3EIconToggleButton(
                        icon: Icons.undo_rounded,
                        selected: false,
                        tooltip: '撤销上次复习评分 [Ctrl+Z]',
                        onPressed:
                            (ctrl.session?.canUndo ?? false) && !ctrl.busy
                                ? ctrl.undoLastAnswer
                                : null,
                      ),
                    M3EIconToggleButton(
                      icon: Icons.add_card_rounded,
                      selected: false,
                      tooltip: '添加问答卡 [A]',
                      onPressed: ctrl.busy ? null : ctrl.openAddQaDrawer,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.password_rounded,
                      selected: _selectedText.isNotEmpty,
                      tooltip: _selectedText.isNotEmpty
                          ? '用选中文字添加挖空卡 [C]'
                          : '添加挖空卡 [C]',
                      onPressed: ctrl.busy ? null : openClozeFromSelection,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.content_cut_rounded,
                      selected: _pick != null,
                      tooltip: !chunk.canSplit
                          ? '当前片段不可切分'
                          : _pick == null
                              ? '点选左侧行圆点或双击正文行选择切分范围'
                              : '切分选中范围（${_pick!.lineCount} 行）',
                      onPressed:
                          (_pick != null && !ctrl.busy && chunk.canSplit)
                              ? _openSplitDialog
                              : null,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.edit_note_rounded,
                      selected: false,
                      tooltip: '编辑片段源码',
                      onPressed: (chunk.segId != null && !ctrl.busy)
                          ? _openSegEditDialog
                          : null,
                    ),
                    M3EIconToggleButton(
                      icon: Icons.border_color_rounded,
                      selected: ctrl.aiLayerEnabled,
                      activeColor: semantic.aiCalloutSurface,
                      activeIconColor: semantic.aiBadgeColor,
                      tooltip: ctrl.aiLayerEnabled
                          ? 'AI 划重点图层：已开启（点击隐藏）'
                          : 'AI 划重点图层：已隐藏（点击开启）',
                      onPressed: ctrl.toggleAiLayer,
                    ),
                    if (!widget.isTrace)
                      M3EIconToggleButton(
                        icon: Icons.close_rounded,
                        selected: false,
                        tooltip: '退出本轮',
                        onPressed: ctrl.busy ? null : ctrl.exitRound,
                      ),
                  ],
                ),
              ],
            ),
          ),

          // Contextual Line-Split Range Banner when lines are picked
          if (_pick != null)
            Container(
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(M3ERadius.lg),
              ),
              child: Row(
                children: [
                  Icon(Icons.content_cut_rounded,
                      size: 18, color: cs.onPrimaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '已选切分范围：第 ${chunk.lineStart + _pick!.startLine - 1}–${chunk.lineStart + _pick!.endLine - 1} 行（${_pick!.lineCount} 行）· 点击范围外扩展，点击范围内取消',
                      style: typo.emphasized.labelMedium?.copyWith(
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _pick = null),
                    child: const Text('清除'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _openSplitDialog,
                    child: const Text('切分'),
                  ),
                ],
              ),
            ),

          Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),

          // Scrollable Markdown + KaTeX + Line-Handle + AI Highlight Body
          Expanded(
            child: Scrollbar(
              controller: _scrollController,
              child: SingleChildScrollView(
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(22, 18, 24, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (chunk.isPdf)
                      Container(
                        padding: const EdgeInsets.all(16),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: cs.tertiaryContainer.withValues(alpha: 0.45),
                          borderRadius: BorderRadius.circular(M3ERadius.lg),
                        ),
                        child: Text(
                          'PDF 讲义片段（第 ${chunk.pageStart ?? 1}–${chunk.pageEnd ?? 1} 页）：可在此继续查看文字摘录与制卡；完整 PDF 页面框选挖图仍可通过浏览器兜底版使用。',
                          style: typo.baseline.bodyMedium,
                        ),
                      ),
                    IRMarkdownView(
                      markdown: chunk.text,
                      imageUrlResolver: (src) =>
                          ctrl.api.resolveImageUrl(src, isAnkiCard: false),
                      annotations: anns,
                      aiLayerEnabled: ctrl.aiLayerEnabled,
                      enableLineHandles: chunk.canSplit,
                      selectedLines: _pick,
                      onLineBlockTap: _onLineTap,
                      onSelectionChanged: (sel, blk) {
                        if (sel != _selectedText) {
                          setState(() {
                            _selectedText = sel;
                            _selectedBlock = blk;
                          });
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Bottom Status Dock (round mode only)
          if (!widget.isTrace) ...[
            Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Wrap(
                spacing: 10,
                runSpacing: 8,
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  M3EButton(
                    label: '结束阅读',
                    variant: M3EButtonStyleVariant.text,
                    size: M3EButtonSize.m,
                    onPressed: ctrl.busy ? null : ctrl.endReadingStage,
                  ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      M3EButton(
                        label: '无需制卡，跳过',
                        keycap: 'S',
                        variant: M3EButtonStyleVariant.outlined,
                        size: M3EButtonSize.m,
                        onPressed: ctrl.busy
                            ? null
                            : () => ctrl.actOnCurrentReading('skip'),
                      ),
                      M3EButton(
                        label: '下一张（稍后）',
                        keycap: 'N',
                        variant: M3EButtonStyleVariant.tonal,
                        size: M3EButtonSize.m,
                        onPressed: ctrl.busy
                            ? null
                            : () => ctrl.actOnCurrentReading('next'),
                      ),
                      M3EButton(
                        label: '制卡完成',
                        keycap: 'Space',
                        icon: Icons.check_rounded,
                        variant: M3EButtonStyleVariant.filled,
                        size: M3EButtonSize.m,
                        onPressed: ctrl.busy
                            ? null
                            : () => ctrl.actOnCurrentReading('complete'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PreviewBox extends StatelessWidget {
  const _PreviewBox({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(M3ERadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: typo.emphasized.labelSmall?.copyWith(color: cs.primary)),
          const SizedBox(height: 4),
          Text(text, style: typo.mono.copyWith(fontSize: 12.5)),
        ],
      ),
    );
  }
}

/// Split-pane Raw Markdown + Live KaTeX Preview Segment Editor Dialog.
class _SegEditDialog extends StatefulWidget {
  const _SegEditDialog({
    required this.controller,
    required this.chunk,
  });

  final AppController controller;
  final ReadingChunk chunk;

  @override
  State<_SegEditDialog> createState() => _SegEditDialogState();
}

class _SegEditDialogState extends State<_SegEditDialog> {
  late final TextEditingController _textCtrl;
  bool _saving = false;
  bool _uploading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _textCtrl = TextEditingController(text: widget.chunk.text);
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    super.dispose();
  }

  void _wrapSelection(String prefix, String suffix) {
    final sel = _textCtrl.selection;
    final txt = _textCtrl.text;
    if (!sel.isValid) return;
    final s = sel.start.clamp(0, txt.length);
    final e = sel.end.clamp(s, txt.length);
    final selected = txt.substring(s, e);
    final next = txt.replaceRange(s, e, '$prefix$selected$suffix');
    _textCtrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: s + prefix.length + selected.length + suffix.length,
      ),
    );
    setState(() {});
  }

  Future<void> _uploadImage() async {
    setState(() {
      _uploading = true;
      _error = null;
    });
    try {
      const group = XTypeGroup(
        label: 'Images',
        extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'],
      );
      final file = await openFile(acceptedTypeGroups: [group]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final res = await widget.controller.api
          .uploadReadingMedia(bytes, file.name);
      _wrapSelection('\n${res.markdown}\n', '');
    } catch (e) {
      setState(() => _error = '上传图片失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.controller.editCurrentReading(_textCtrl.text);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error = '保存失败（可能存在并发修改，请刷新后重试）';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120, maxHeight: 760),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('编辑阅读片段', style: typo.emphasized.headlineSmall),
                        Text(
                          '${widget.chunk.path} · 第 ${widget.chunk.lineStart}–${widget.chunk.lineEnd} 行',
                          style: typo.baseline.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  M3EFloatingToolbar(
                    children: [
                      IconButton(
                        tooltip: '粗体',
                        onPressed: () => _wrapSelection('**', '**'),
                        icon: const Icon(Icons.format_bold_rounded, size: 19),
                      ),
                      IconButton(
                        tooltip: '斜体',
                        onPressed: () => _wrapSelection('*', '*'),
                        icon: const Icon(Icons.format_italic_rounded, size: 19),
                      ),
                      IconButton(
                        tooltip: '插入表格',
                        onPressed: () => _wrapSelection(
                          '\n| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |\n',
                          '',
                        ),
                        icon: const Icon(Icons.table_chart_outlined, size: 19),
                      ),
                      IconButton(
                        tooltip: '插入图片（上传到媒体沙箱）',
                        onPressed: _uploading ? null : _uploadImage,
                        icon: _uploading
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.image_outlined, size: 19),
                      ),
                    ],
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!,
                    style: typo.baseline.bodySmall?.copyWith(color: cs.error)),
              ],
              const SizedBox(height: 14),
              Expanded(
                child: Row(
                  children: [
                    // Left Raw Markdown Editor
                    Expanded(
                      child: TextField(
                        controller: _textCtrl,
                        maxLines: null,
                        expands: true,
                        textAlignVertical: TextAlignVertical.top,
                        style: typo.mono,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: 'Markdown 源码…',
                          alignLabelWithHint: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    // Right Live Preview
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(M3ERadius.lg),
                          border: Border.all(
                            color: cs.outlineVariant.withValues(alpha: 0.6),
                          ),
                        ),
                        child: SingleChildScrollView(
                          child: IRMarkdownView(
                            markdown: _textCtrl.text,
                            imageUrlResolver: (src) => widget.controller.api
                                .resolveImageUrl(src, isAnkiCard: false),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  M3EButton(
                    label: '取消',
                    variant: M3EButtonStyleVariant.text,
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  M3EButton(
                    label: _saving ? '保存中…' : '保存片段',
                    icon: Icons.save_rounded,
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
