import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/cloze_engine.dart';
import '../../state/app_controller.dart';
import '../../theme/m3e_shapes.dart';
import '../../theme/m3e_typography.dart';
import '../m3e/m3e_button.dart';
import '../m3e/m3e_indicators.dart';
import '../markdown/ir_markdown_view.dart';

/// Non-modal M3E Floating Card Authoring Drawer.
///
/// Positioned directly over the right supporting pane so the user can keep
/// reading, scrolling, and copying from the left ReadingCard or Flashcard
/// without losing context — honoring one of IR4Anki's most important UX design
/// principles (`CardDrawer.tsx`).
///
/// Supports:
/// - `AuthoringMode.addQa`: Markdown-native QA cards with live preview & media upload.
/// - `AuthoringMode.editNote`: In-place editing of reviewed Anki notes.
/// - `AuthoringMode.addCloze`: Cloze cards with `Ctrl+Shift+C` wrapping,
///   unwrap, ordinal switcher (`c1`, `c2`…), and side-by-side Front/Back live preview!
class CardAuthoringDrawer extends StatefulWidget {
  const CardAuthoringDrawer({
    super.key,
    required this.controller,
    required this.request,
  });

  final AppController controller;
  final AuthoringRequest request;

  @override
  State<CardAuthoringDrawer> createState() => _CardAuthoringDrawerState();
}

class _CardAuthoringDrawerState extends State<CardAuthoringDrawer> {
  bool _loading = true;
  bool _saving = false;
  bool _uploading = false;
  bool _showQaPreview = true;
  String? _error;

  List<String> _fieldNames = const [];
  List<TextEditingController> _fieldCtrls = const [];
  List<String> _tags = const [];
  List<String> _allTags = const [];
  final TextEditingController _tagInputCtrl = TextEditingController();

  int _previewOrdinal = 1;
  bool _preserveMarkdownTag = true;

  @override
  void initState() {
    super.initState();
    _loadSchema();
  }

  @override
  void didUpdateWidget(CardAuthoringDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.request != widget.request) {
      _disposeFieldCtrls();
      _loadSchema();
    }
  }

  void _disposeFieldCtrls() {
    for (final c in _fieldCtrls) {
      c.dispose();
    }
    _fieldCtrls = const [];
  }

  @override
  void dispose() {
    _disposeFieldCtrls();
    _tagInputCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSchema() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final api = widget.controller.api;
    final req = widget.request;

    try {
      final tagsFuture = api.getTags().catchError((_) => const <String>[]);
      if (req.mode == AuthoringMode.editNote && req.editCard != null) {
        final results = await Future.wait([
          api.getNote(req.editCard!.cardId),
          tagsFuture,
        ]);
        final note = results[0] as dynamic;
        final allTags = results[1] as List<String>;
        final fields = note.fields as Map<String, String>;
        final names = fields.keys.toList();
        final noteTags = (note.tags as List<String>);
        _preserveMarkdownTag = isMarkdownNote(noteTags);
        _fieldNames = names;
        _fieldCtrls = [
          for (final k in names) TextEditingController(text: fields[k] ?? ''),
        ];
        _tags = noteTags.where((t) => t != kMarkdownTag).toList();
        _allTags = allTags;
      } else {
        final kind = req.mode == AuthoringMode.addCloze ? 'cloze' : 'qa';
        final results = await Future.wait([
          api.getAddCardInfo(kind: kind),
          tagsFuture,
        ]);
        final info =
            results[0] as ({String modelName, List<String> fields});
        final allTags = results[1] as List<String>;
        final names = info.fields.isNotEmpty
            ? info.fields
            : (kind == 'cloze' ? ['文字'] : ['正面', '背面']);
        _preserveMarkdownTag = true;
        _fieldNames = names;
        _fieldCtrls = [
          for (int i = 0; i < names.length; i++)
            TextEditingController(
              text: (i == 0 && kind == 'cloze') ? req.initialClozeText : '',
            ),
        ];
        _tags = [];
        _allTags = allTags;
      }
      if (mounted) {
        setState(() => _loading = false);
      }
    } catch (e) {
      if (mounted) {
        // Still allow cloze editing if add/info failed
        if (req.mode == AuthoringMode.addCloze) {
          _fieldNames = ['文字'];
          _fieldCtrls = [TextEditingController(text: req.initialClozeText)];
        }
        setState(() {
          _loading = false;
          _error = '加载卡片模板失败：$e';
        });
      }
    }
  }

  TextEditingController? get _primaryCtrl =>
      _fieldCtrls.isNotEmpty ? _fieldCtrls.first : null;

  int _nextClozeOrdinal(String text) {
    final ords = clozeOrdinals(text);
    return ords.isEmpty ? 1 : (ords.last + 1);
  }

  void _wrapClozeSelection() {
    final ctrl = _primaryCtrl;
    if (ctrl == null) return;
    final sel = ctrl.selection;
    final text = ctrl.text;
    if (!sel.isValid || sel.start == sel.end) {
      setState(() => _error = '先在正文里选中要挖空的文字');
      return;
    }
    final s = sel.start.clamp(0, text.length);
    final e = sel.end.clamp(s, text.length);
    final inside = parseClozeRanges(text).any((r) => s >= r.start && e <= r.end);
    if (inside) {
      setState(() => _error = '这段已经在挖空里了');
      return;
    }
    final n = _nextClozeOrdinal(text);
    final wrapped = '{{c$n::${text.substring(s, e)}}}';
    final next = text.replaceRange(s, e, wrapped);
    ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: s + wrapped.length),
    );
    setState(() {
      _previewOrdinal = n;
      _error = null;
    });
  }

  void _unwrapClozeAtCursor() {
    final ctrl = _primaryCtrl;
    if (ctrl == null) return;
    final pos = ctrl.selection.baseOffset;
    final text = ctrl.text;
    final hit = parseClozeRanges(text)
        .where((r) => pos >= r.start && pos <= r.end)
        .firstOrNull;
    if (hit == null) {
      setState(() => _error = '把光标点进一个挖空标记里，再取消挖空');
      return;
    }
    final next = text.replaceRange(hit.start, hit.end, hit.content);
    ctrl.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: hit.start + hit.content.length),
    );
    setState(() => _error = null);
  }

  Future<void> _uploadImageIntoField(TextEditingController fieldCtrl) async {
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
      final filename =
          await widget.controller.api.uploadAnkiMedia(bytes, file.name);
      final snippet = '![]($filename)';
      final sel = fieldCtrl.selection;
      final txt = fieldCtrl.text;
      final offset = sel.isValid ? sel.end.clamp(0, txt.length) : txt.length;
      final next = txt.replaceRange(offset, offset, snippet);
      fieldCtrl.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: offset + snippet.length),
      );
      setState(() {});
    } catch (e) {
      setState(() => _error = '上传媒体失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  void _addTag(String raw) {
    final t = raw.trim();
    if (t.isNotEmpty && !_tags.contains(t)) {
      setState(() => _tags = [..._tags, t]);
    }
    _tagInputCtrl.clear();
  }

  Future<void> _save() async {
    if (_loading || _saving) return;
    final req = widget.request;
    final fields = <String, String>{};
    for (int i = 0; i < _fieldNames.length; i++) {
      fields[_fieldNames[i]] = _fieldCtrls[i].text;
    }

    if (req.mode == AuthoringMode.addCloze) {
      final body = _primaryCtrl?.text ?? '';
      if (body.trim().isEmpty) {
        setState(() => _error = '挖空内容不能为空');
        return;
      }
      if (parseClozeRanges(body).isEmpty) {
        setState(() => _error = '至少要有一处 {{c1::…}} 挖空（选中文字点「挖空选中」）');
        return;
      }
    } else if (req.mode == AuthoringMode.addQa) {
      if ((_primaryCtrl?.text.trim() ?? '').isEmpty) {
        setState(() => _error = '正面问题不能为空');
        return;
      }
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    final finalTags = <String>[
      ..._tags,
      if (_preserveMarkdownTag && !_tags.contains(kMarkdownTag)) kMarkdownTag,
    ];

    try {
      if (req.mode == AuthoringMode.editNote && req.editCard != null) {
        final res = await widget.controller.api
            .updateNote(req.editCard!.cardId, fields, finalTags);
        await widget.controller
            .onCardUpdated(req.editCard!.cardId, res.question, res.answer);
      } else {
        final res = await widget.controller.api.addCard(
          fields: fields,
          tags: finalTags,
          kind: req.mode == AuthoringMode.addCloze ? 'cloze' : 'qa',
          readingPath: req.readingPath,
          readingChunkKey: req.readingChunkKey,
        );
        await widget.controller.onCardAdded(res.noteId);
      }
      if (mounted) {
        widget.controller.closeAuthoringDrawer();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final req = widget.request;
    final isCloze = req.mode == AuthoringMode.addCloze;
    final isEdit = req.mode == AuthoringMode.editNote;

    final title = isCloze
        ? '添加挖空卡'
        : (isEdit ? '编辑卡片' : '添加问答卡');

    final clozeText = isCloze ? (_primaryCtrl?.text ?? '') : '';
    final ordinals = isCloze ? clozeOrdinals(clozeText) : const <int>[];
    final activeOrd = ordinals.contains(_previewOrdinal)
        ? _previewOrdinal
        : (ordinals.isNotEmpty ? ordinals.first : 1);

    final tagQuery = _tagInputCtrl.text.trim().toLowerCase();
    final suggestedTags = tagQuery.isEmpty
        ? const <String>[]
        : _allTags
            .where((t) =>
                t != kMarkdownTag &&
                !_tags.contains(t) &&
                t.toLowerCase().contains(tagQuery))
            .take(5)
            .toList();

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape):
            widget.controller.closeAuthoringDrawer,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _save,
        if (isCloze)
          const SingleActivator(
            LogicalKeyboardKey.keyC,
            control: true,
            shift: true,
          ): _wrapClozeSelection,
      },
      child: Container(
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(M3ERadius.xl),
          border: Border.all(
            color: cs.primary.withValues(alpha: 0.35),
            width: 1.4,
          ),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.16),
              blurRadius: 28,
              offset: const Offset(-4, 8),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 14, 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: typo.emphasized.titleLarge),
                        if (req.readingPath != null)
                          Text(
                            '已关联溯源：${req.readingPath}',
                            style: typo.baseline.labelSmall
                                ?.copyWith(color: cs.primary),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  if (!isCloze)
                    Tooltip(
                      message: _showQaPreview ? '隐藏实时预览' : '显示实时预览',
                      child: IconButton(
                        onPressed: () =>
                            setState(() => _showQaPreview = !_showQaPreview),
                        icon: Icon(
                          _showQaPreview
                              ? Icons.visibility_rounded
                              : Icons.visibility_off_outlined,
                          size: 20,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: '关闭 [Esc]',
                    onPressed:
                        _saving ? null : widget.controller.closeAuthoringDrawer,
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),

            Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),

            // Body
            Expanded(
              child: _loading
                  ? const Center(child: M3ELoadingIndicator(size: 48))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (_error != null) ...[
                            Container(
                              padding: const EdgeInsets.all(12),
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: cs.errorContainer,
                                borderRadius:
                                    BorderRadius.circular(M3ERadius.md),
                              ),
                              child: Text(
                                _error!,
                                style: typo.baseline.bodySmall
                                    ?.copyWith(color: cs.onErrorContainer),
                              ),
                            ),
                          ],

                          // Cloze Toolbar
                          if (isCloze) ...[
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                M3EButton(
                                  label: '挖空选中',
                                  keycap: 'Ctrl+Shift+C',
                                  icon: Icons.password_rounded,
                                  variant: M3EButtonStyleVariant.tonal,
                                  size: M3EButtonSize.s,
                                  onPressed: _wrapClozeSelection,
                                ),
                                M3EButton(
                                  label: '取消挖空',
                                  variant: M3EButtonStyleVariant.text,
                                  size: M3EButtonSize.s,
                                  onPressed: _unwrapClozeAtCursor,
                                ),
                                Text(
                                  '${parseClozeRanges(clozeText).length} 处挖空',
                                  style: typo.emphasized.labelMedium
                                      ?.copyWith(color: cs.primary),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                          ],

                          // Dynamic Fields
                          for (int i = 0; i < _fieldNames.length; i++) ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  _fieldNames[i],
                                  style: typo.emphasized.labelLarge,
                                ),
                                TextButton.icon(
                                  onPressed: _uploading
                                      ? null
                                      : () => _uploadImageIntoField(
                                          _fieldCtrls[i]),
                                  icon: const Icon(Icons.image_outlined,
                                      size: 16),
                                  label: const Text('插图'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            TextField(
                              controller: _fieldCtrls[i],
                              minLines: i == 0 ? 4 : 3,
                              maxLines: 9,
                              style: typo.mono,
                              onChanged: (_) => setState(() {}),
                              decoration: InputDecoration(
                                hintText: isCloze && i == 0
                                    ? '支持 Markdown 与 LaTeX，选中文字按 Ctrl+Shift+C 挖空…'
                                    : '支持 Markdown 与 \$LaTeX\$ 公式…',
                              ),
                            ),
                            const SizedBox(height: 14),
                          ],

                          // Cloze Live Front & Back Preview
                          if (isCloze) ...[
                            if (ordinals.length > 1)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 10),
                                child: Wrap(
                                  spacing: 6,
                                  children: [
                                    for (final n in ordinals)
                                      ChoiceChip(
                                        label: Text('c$n'),
                                        selected: activeOrd == n,
                                        onSelected: (_) => setState(
                                            () => _previewOrdinal = n),
                                      ),
                                  ],
                                ),
                              ),
                            _PreviewCard(
                              title: '正面预览（提问 c$activeOrd）',
                              markdown: transformClozeMarkdown(
                                clozeText,
                                showAnswer: false,
                                activeOrdinal: activeOrd,
                              ),
                              imageResolver: (s) => widget.controller.api
                                  .resolveImageUrl(s, isAnkiCard: true),
                            ),
                            const SizedBox(height: 10),
                            _PreviewCard(
                              title: '背面预览（答案 c$activeOrd）',
                              markdown: transformClozeMarkdown(
                                clozeText,
                                showAnswer: true,
                                activeOrdinal: activeOrd,
                              ),
                              imageResolver: (s) => widget.controller.api
                                  .resolveImageUrl(s, isAnkiCard: true),
                            ),
                            const SizedBox(height: 14),
                          ] else if (_showQaPreview &&
                              _fieldCtrls.isNotEmpty) ...[
                            _PreviewCard(
                              title: '实时渲染预览',
                              markdown: _fieldCtrls
                                  .map((c) => c.text.trim())
                                  .where((s) => s.isNotEmpty)
                                  .join('\n\n---\n\n'),
                              imageResolver: (s) => widget.controller.api
                                  .resolveImageUrl(s, isAnkiCard: true),
                            ),
                            const SizedBox(height: 14),
                          ],

                          // Tags Section
                          Text('标签', style: typo.emphasized.labelLarge),
                          const SizedBox(height: 8),
                          if (_tags.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final t in _tags)
                                    InputChip(
                                      label: Text(t),
                                      onDeleted: () => setState(() => _tags =
                                          _tags.where((x) => x != t).toList()),
                                    ),
                                ],
                              ),
                            ),
                          TextField(
                            controller: _tagInputCtrl,
                            onChanged: (_) => setState(() {}),
                            onSubmitted: _addTag,
                            decoration: const InputDecoration(
                              hintText: '输入标签后回车添加…',
                              isDense: true,
                            ),
                          ),
                          if (suggestedTags.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final t in suggestedTags)
                                  ActionChip(
                                    label: Text('+ $t'),
                                    onPressed: () => _addTag(t),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
            ),

            // Footer Actions
            Divider(color: cs.outlineVariant.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  M3EButton(
                    label: '取消',
                    variant: M3EButtonStyleVariant.text,
                    size: M3EButtonSize.m,
                    onPressed:
                        _saving ? null : widget.controller.closeAuthoringDrawer,
                  ),
                  const SizedBox(width: 10),
                  M3EButton(
                    label: _saving
                        ? '保存中…'
                        : (isEdit
                            ? '保存修改'
                            : (isCloze ? '添加挖空卡' : '添加问答卡')),
                    keycap: 'Ctrl+↵',
                    icon: Icons.check_rounded,
                    size: M3EButtonSize.m,
                    onPressed: (_loading || _saving) ? null : _save,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.title,
    required this.markdown,
    required this.imageResolver,
  });

  final String title;
  final String markdown;
  final String Function(String) imageResolver;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(M3ERadius.lg),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: typo.emphasized.labelSmall?.copyWith(color: cs.primary)),
          const SizedBox(height: 8),
          if (markdown.trim().isEmpty)
            Text('（暂无内容）', style: typo.baseline.bodySmall)
          else
            IRMarkdownView(
              markdown: markdown,
              imageUrlResolver: imageResolver,
              compact: true,
            ),
        ],
      ),
    );
  }
}
