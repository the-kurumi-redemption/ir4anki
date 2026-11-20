import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../models/ir4anki_models.dart';
import '../services/api_client.dart';
import '../state/app_controller.dart';
import '../theme/m3e_shapes.dart';
import '../theme/m3e_theme.dart';
import '../theme/m3e_typography.dart';
import '../widgets/m3e/m3e_button.dart';
import '../widgets/m3e/m3e_floating_toolbar.dart';
import '../widgets/m3e/m3e_indicators.dart';
import '../widgets/m3e/m3e_segmented_list.dart';
import '../widgets/markdown/ir_markdown_view.dart';

/// Three-Pane Material 3 Expressive Files & Reading Queue Workbench.
///
/// Mirrors every Storage v2 & Interop P0 capability from `FilesScreen.tsx`:
/// 1. Left Sidebar: Folder tree (`全部文件` + dirs), New Folder, Import Files/Folder
///    with 409 conflict policy dialog (`skip` / `rename` / `overwrite`), Trash bin,
///    and single-step File Undo.
/// 2. Middle Column: Directory file list with reading-progress badges + debounced
///    FTS5 global full-text search with highlighted snippet cards.
/// 3. Right Workbench:
///    - Default: **Reading Queue (`阅读清单`)** with wavy progress bars, frontier
///      status chips, Move-to-Top, Reorder Up/Down, and Remove.
///    - Selected File: **File Detail & Full Markdown Preview** with AI highlight
///      layer, Reading-list Add/Re-seed/Remove, Rename, Delete, and `历史版本`
///      Time-Travel Revision Rollback dialog!
class FilesWorkbenchScreen extends StatefulWidget {
  const FilesWorkbenchScreen({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<FilesWorkbenchScreen> createState() => _FilesWorkbenchScreenState();
}

class _FilesWorkbenchScreenState extends State<FilesWorkbenchScreen> {
  final TextEditingController _searchCtrl = TextEditingController();
  bool _uploading = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.controller.fileSearchQuery;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _importFiles({bool folder = false}) async {
    final entries = <UploadFileEntry>[];
    if (folder) {
      final dirPath = await getDirectoryPath(confirmButtonText: '选择导入文件夹');
      if (dirPath == null) return;
      final rootDir = Directory(dirPath);
      final rootName = rootDir.uri.pathSegments
          .where((s) => s.isNotEmpty)
          .lastOrNull ?? 'imported';
      await for (final entity in rootDir.list(recursive: true)) {
        if (entity is File) {
          final relUnderRoot = entity.path
              .substring(rootDir.path.length)
              .replaceFirst(RegExp(r'^/+'), '');
          final lower = entity.path.toLowerCase();
          if (lower.endsWith('.md') ||
              lower.endsWith('.png') ||
              lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.webp') ||
              lower.endsWith('.gif') ||
              lower.endsWith('.svg')) {
            final bytes = await entity.readAsBytes();
            entries.add(UploadFileEntry(
              bytes: bytes,
              fileName: entity.uri.pathSegments.last,
              relativePath: '$rootName/$relUnderRoot',
            ));
          }
        }
      }
    } else {
      const group = XTypeGroup(
        label: 'Markdown & Images',
        extensions: ['md', 'png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'],
      );
      final files = await openFiles(acceptedTypeGroups: [group]);
      if (files.isEmpty) return;
      for (final f in files) {
        final bytes = await f.readAsBytes();
        entries.add(UploadFileEntry(
          bytes: bytes,
          fileName: f.name,
          relativePath: f.name,
        ));
      }
    }

    if (entries.isEmpty) {
      widget.controller.showMessage('未找到可导入的 Markdown 或图片文件');
      return;
    }

    await _performUpload(entries, 'error');
  }

  Future<void> _performUpload(
    List<UploadFileEntry> entries,
    String onConflict,
  ) async {
    setState(() => _uploading = true);
    try {
      final res = await widget.controller.api.uploadFiles(
        entries: entries,
        dir: widget.controller.currentDir,
        onConflict: onConflict,
      );
      await widget.controller.refreshFilesWorkbench();
      final sum = res.summary;
      final msg = sum != null
          ? '导入完成：笔记 ${sum.notesImported} 篇（新增 ${sum.notesWritten} / 覆盖 ${sum.notesOverwritten} / 改名 ${sum.notesRenamed}），媒体 ${sum.resourcesImported} 个（复用 ${sum.resourcesReused}）'
          : '已导入 ${res.savedPaths.length} 个文件';
      widget.controller.showMessage(msg);
    } on UploadConflictException catch (e) {
      if (!mounted) return;
      final policy = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('检测到同名笔记冲突'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('以下 ${e.conflicts.length} 个 Markdown 文件已存在：'),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 160),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final c in e.conflicts)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text('• $c'),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(null),
              child: const Text('取消'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.of(ctx).pop('skip'),
              child: const Text('跳过重名'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(ctx).pop('rename'),
              child: const Text('改名保留两者'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop('overwrite'),
              child: const Text('覆盖'),
            ),
          ],
        ),
      );
      if (policy != null) {
        await _performUpload(entries, policy);
      }
    } catch (e) {
      widget.controller.showMessage('导入失败：$e');
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _showNewFolderDialog() async {
    final nameCtrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: InputDecoration(
            labelText: '文件夹名称',
            helperText: widget.controller.currentDir.isEmpty
                ? '将创建在根目录'
                : '将创建在 ${widget.controller.currentDir}/ 下',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (name != null && name.trim().isNotEmpty) {
      await widget.controller.createFolder(name.trim());
    }
  }

  Future<void> _showRenameDialog(String path) async {
    final oldName = path.split('/').last;
    final nameCtrl = TextEditingController(text: oldName);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名'),
        content: TextField(
          controller: nameCtrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新名称'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(nameCtrl.text),
            child: const Text('重命名'),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    if (next != null && next.trim().isNotEmpty && next.trim() != oldName) {
      await widget.controller.renamePath(path, next.trim());
    }
  }

  Future<void> _confirmDeletePath(String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移入回收站？'),
        content: Text('将「$path」软删除至回收站，可随时恢复；已制作卡片的溯源关系不会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('移入回收站'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.deletePath(path);
    }
  }

  Future<void> _openTrashDialog() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _TrashDialog(controller: widget.controller),
    );
  }

  Future<void> _openRevisionsDialog(String path) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => _RevisionHistoryDialog(
        controller: widget.controller,
        path: path,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final ctrl = widget.controller;

    final readingMap = {for (final r in ctrl.readingList) r.path: r};
    final query = ctrl.fileSearchQuery.trim().toLowerCase();

    // Filter files in current directory (or globally when searching)
    final visibleFiles = ctrl.files.where((f) {
      if (query.isNotEmpty) {
        return f.title.toLowerCase().contains(query) ||
            f.path.toLowerCase().contains(query);
      }
      if (ctrl.currentDir.isEmpty) return true;
      return f.directory == ctrl.currentDir ||
          f.path.startsWith('${ctrl.currentDir}/');
    }).toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top Action Bar
          Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('语料与阅读清单', style: typo.emphasized.headlineSmall),
                  Text(
                    '共 ${ctrl.files.length} 篇笔记 · 阅读清单 ${ctrl.readingList.length} 篇',
                    style: typo.baseline.bodySmall,
                  ),
                ],
              ),
              const Spacer(),
              if (ctrl.lastFileOperationId != null) ...[
                M3EButton(
                  label: '撤销文件操作',
                  icon: Icons.undo_rounded,
                  variant: M3EButtonStyleVariant.tonal,
                  size: M3EButtonSize.s,
                  onPressed: ctrl.undoLastFileOperation,
                ),
                const SizedBox(width: 8),
              ],
              M3EFloatingToolbar(
                children: [
                  M3EButton(
                    label: _uploading ? '导入中…' : '导入文件',
                    icon: Icons.upload_file_rounded,
                    variant: M3EButtonStyleVariant.filled,
                    size: M3EButtonSize.s,
                    onPressed: _uploading ? null : () => _importFiles(folder: false),
                  ),
                  const SizedBox(width: 6),
                  M3EButton(
                    label: '导入文件夹',
                    icon: Icons.drive_folder_upload_rounded,
                    variant: M3EButtonStyleVariant.tonal,
                    size: M3EButtonSize.s,
                    onPressed: _uploading ? null : () => _importFiles(folder: true),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    tooltip: '新建文件夹',
                    onPressed: _showNewFolderDialog,
                    icon: const Icon(Icons.create_new_folder_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: '回收站',
                    onPressed: _openTrashDialog,
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                  ),
                  IconButton(
                    tooltip: '刷新列表',
                    onPressed: ctrl.refreshFilesWorkbench,
                    icon: const Icon(Icons.refresh_rounded, size: 20),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 14),

          // Three-Pane Desktop Workbench
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 1. Left Folder Tree Sidebar
                SizedBox(
                  width: 210,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(M3ERadius.xl),
                      border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.45)),
                    ),
                    child: ListView(
                      children: [
                        _FolderTile(
                          label: '全部文件',
                          icon: Icons.folder_special_rounded,
                          selected: ctrl.currentDir.isEmpty,
                          indent: 0,
                          onTap: () => ctrl.setCurrentDir(''),
                        ),
                        for (final dir in ctrl.dirs)
                          _FolderTile(
                            label: dir.split('/').last,
                            icon: Icons.folder_outlined,
                            selected: ctrl.currentDir == dir,
                            indent: dir.split('/').length - 1,
                            onTap: () => ctrl.setCurrentDir(dir),
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                // 2. Middle File List + FTS5 Global Search
                SizedBox(
                  width: 350,
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(M3ERadius.xl),
                      border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.45)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: TextField(
                            controller: _searchCtrl,
                            onChanged: ctrl.setFileSearchQuery,
                            decoration: InputDecoration(
                              hintText: '搜索文件名或全文内容（FTS5）…',
                              prefixIcon: const Icon(Icons.search_rounded, size: 20),
                              suffixIcon: _searchCtrl.text.isNotEmpty
                                  ? IconButton(
                                      icon: const Icon(Icons.close_rounded, size: 18),
                                      onPressed: () {
                                        _searchCtrl.clear();
                                        ctrl.setFileSearchQuery('');
                                      },
                                    )
                                  : null,
                              isDense: true,
                            ),
                          ),
                        ),
                        Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
                        Expanded(
                          child: ctrl.filesLoading
                              ? const Center(child: M3ELoadingIndicator(size: 44))
                              : ListView(
                                  padding: const EdgeInsets.all(10),
                                  children: [
                                    // FTS5 Full-text search matches section
                                    if (query.length >= 2) ...[
                                      Padding(
                                        padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
                                        child: Row(
                                          children: [
                                            Icon(Icons.manage_search_rounded,
                                                size: 16, color: cs.primary),
                                            const SizedBox(width: 6),
                                            Text(
                                              ctrl.ftsSearching
                                                  ? '全文检索中…'
                                                  : '全文检索匹配（${ctrl.ftsResults.length}）',
                                              style: typo.emphasized.labelMedium
                                                  ?.copyWith(color: cs.primary),
                                            ),
                                          ],
                                        ),
                                      ),
                                      for (int i = 0; i < ctrl.ftsResults.length; i++)
                                        _FtsResultRow(
                                          index: i,
                                          total: ctrl.ftsResults.length,
                                          item: ctrl.ftsResults[i],
                                          selected: ctrl.selectedFilePath ==
                                              ctrl.ftsResults[i].legacyPath,
                                          onTap: () {
                                            final p = ctrl.ftsResults[i].legacyPath;
                                            if (p != null && p.isNotEmpty) {
                                              ctrl.selectFileForPreview(p);
                                            }
                                          },
                                        ),
                                      if (ctrl.ftsResults.isNotEmpty)
                                        const SizedBox(height: 12),
                                    ],

                                    // Directory Files List
                                    if (visibleFiles.isEmpty)
                                      Padding(
                                        padding: const EdgeInsets.all(24),
                                        child: Center(
                                          child: Text(
                                            '当前目录暂无匹配笔记',
                                            style: typo.baseline.bodySmall,
                                          ),
                                        ),
                                      )
                                    else
                                      for (int i = 0; i < visibleFiles.length; i++)
                                        _FileListRow(
                                          index: i,
                                          total: visibleFiles.length,
                                          file: visibleFiles[i],
                                          readingSummary:
                                              readingMap[visibleFiles[i].path],
                                          selected: ctrl.selectedFilePath ==
                                              visibleFiles[i].path,
                                          onTap: () => ctrl.selectFileForPreview(
                                              visibleFiles[i].path),
                                        ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(width: 12),

                // 3. Right Workbench: File Preview OR Reading Queue
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(M3ERadius.xl),
                      border: Border.all(
                          color: cs.outlineVariant.withValues(alpha: 0.45)),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: ctrl.selectedFilePath != null
                        ? _buildFilePreviewPane(
                            context,
                            ctrl.selectedFilePath!,
                            readingMap[ctrl.selectedFilePath!],
                          )
                        : _buildReadingQueuePane(context),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReadingQueuePane(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final ctrl = widget.controller;
    final list = ctrl.readingList;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Row(
            children: [
              M3EShapeContainer(
                kind: M3EShapeKind.arch,
                color: semantic.readingContainer,
                size: 36,
                child: Icon(Icons.playlist_play_rounded,
                    size: 20, color: semantic.onReadingContainer),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('阅读清单队列', style: typo.emphasized.titleLarge),
                    Text(
                      '按优先级排布；每轮发牌时清单中每篇最多贡献 2 段待读内容',
                      style: typo.baseline.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),
        Expanded(
          child: list.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.menu_book_rounded,
                            size: 44, color: cs.onSurfaceVariant),
                        const SizedBox(height: 12),
                        Text('阅读清单为空', style: typo.emphasized.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          '在中间列表中点选任意 Markdown 笔记，即可加入阅读清单并开始渐进制卡。',
                          style: typo.baseline.bodySmall,
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: list.length,
                  itemBuilder: (ctx, idx) {
                    final item = list[idx];
                    final pct = (item.progressRatio * 100).round();
                    final frontierStatus = item.isComplete
                        ? '已读完 ✓'
                        : item.frontier != null
                            ? (item.frontier!.status == 'active'
                                ? '正在制卡'
                                : '未读')
                            : (item.gated > 0 ? '等待预览池解冻' : '队列中');

                    return M3ESegmentedListItem(
                      index: idx,
                      totalCount: list.length,
                      onTap: () => ctrl.selectFileForPreview(item.path),
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: cs.primaryContainer,
                                  borderRadius:
                                      BorderRadius.circular(M3ERadius.full),
                                ),
                                child: Text(
                                  '#${idx + 1}',
                                  style: typo.emphasized.labelSmall?.copyWith(
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  item.title.isNotEmpty ? item.title : item.path,
                                  style: typo.emphasized.titleSmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                  color: item.isComplete
                                      ? semantic.successContainer
                                      : cs.surfaceContainerHighest,
                                  borderRadius:
                                      BorderRadius.circular(M3ERadius.full),
                                ),
                                child: Text(
                                  frontierStatus,
                                  style: typo.emphasized.labelSmall?.copyWith(
                                    color: item.isComplete
                                        ? semantic.successAccent
                                        : cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              IconButton(
                                tooltip: '置顶',
                                visualDensity: VisualDensity.compact,
                                onPressed: idx == 0
                                    ? null
                                    : () => ctrl.moveReadingItemToTop(item.path),
                                icon: const Icon(Icons.vertical_align_top_rounded,
                                    size: 18),
                              ),
                              IconButton(
                                tooltip: '上移',
                                visualDensity: VisualDensity.compact,
                                onPressed: idx == 0
                                    ? null
                                    : () => ctrl.reorderReadingList(idx, idx - 1),
                                icon: const Icon(Icons.arrow_upward_rounded,
                                    size: 18),
                              ),
                              IconButton(
                                tooltip: '下移',
                                visualDensity: VisualDensity.compact,
                                onPressed: idx == list.length - 1
                                    ? null
                                    : () => ctrl.reorderReadingList(idx, idx + 2),
                                icon: const Icon(Icons.arrow_downward_rounded,
                                    size: 18),
                              ),
                              IconButton(
                                tooltip: '移出阅读清单（保留归档进度）',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    ctrl.removeFromReadingList(item.path),
                                icon: Icon(Icons.playlist_remove_rounded,
                                    size: 18, color: cs.error),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          M3EWavyProgressIndicator(
                            value: item.progressRatio,
                            height: 8,
                            strokeWidth: 3,
                            amplitude: 2.0,
                            color: item.isComplete
                                ? semantic.successAccent
                                : semantic.readingAccent,
                            animateWave: false,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '$pct% · 片段 ${item.done + item.skipped}/${item.totalChunks} · 已制 ${item.cardsCreated} 卡 · ${item.path}',
                            style: typo.baseline.labelSmall,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildFilePreviewPane(
    BuildContext context,
    String path,
    ReadingFileSummary? summary,
  ) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final ctrl = widget.controller;
    final inList = summary != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Preview Header
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 14, 12),
          child: Row(
            children: [
              IconButton(
                tooltip: '返回阅读清单队列',
                onPressed: () => ctrl.selectFileForPreview(null),
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      path.split('/').last,
                      style: typo.emphasized.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(path, style: typo.baseline.labelSmall),
                  ],
                ),
              ),
              M3EFloatingToolbar(
                children: [
                  if (!inList)
                    M3EButton(
                      label: '加入阅读清单',
                      icon: Icons.playlist_add_rounded,
                      size: M3EButtonSize.s,
                      onPressed: () => ctrl.addToReadingList(path),
                    )
                  else ...[
                    M3EButton(
                      label: '置顶',
                      icon: Icons.vertical_align_top_rounded,
                      variant: M3EButtonStyleVariant.tonal,
                      size: M3EButtonSize.s,
                      onPressed: () => ctrl.moveReadingItemToTop(path),
                    ),
                    const SizedBox(width: 6),
                    M3EButton(
                      label: '移出清单',
                      variant: M3EButtonStyleVariant.outlined,
                      size: M3EButtonSize.s,
                      onPressed: () => ctrl.removeFromReadingList(path),
                    ),
                  ],
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: '历史版本与时间旅行回滚',
                    onPressed: () => _openRevisionsDialog(path),
                    icon: const Icon(Icons.history_rounded, size: 20),
                  ),
                  IconButton(
                    tooltip: '重命名',
                    onPressed: () => _showRenameDialog(path),
                    icon: const Icon(Icons.drive_file_rename_outline_rounded,
                        size: 20),
                  ),
                  IconButton(
                    tooltip: '移入回收站',
                    onPressed: () => _confirmDeletePath(path),
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 20, color: cs.error),
                  ),
                ],
              ),
            ],
          ),
        ),

        // Reading Progress Strip if in reading list
        if (summary != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            color: semantic.readingContainer.withValues(alpha: 0.35),
            child: Row(
              children: [
                Icon(Icons.auto_stories_rounded,
                    size: 16, color: semantic.readingAccent),
                const SizedBox(width: 8),
                Text(
                  '阅读进度 ${(summary.progressRatio * 100).round()}% · 已完成 ${summary.done}/${summary.totalChunks} 段 · 已制 ${summary.cardsCreated} 卡',
                  style: typo.emphasized.labelMedium?.copyWith(
                    color: semantic.readingAccent,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => ctrl.addToReadingList(path, fresh: true),
                  child: const Text('重新整篇播种'),
                ),
              ],
            ),
          ),

        Divider(color: cs.outlineVariant.withValues(alpha: 0.4)),

        // Full Markdown Preview with Stand-off AI Highlight Layer
        Expanded(
          child: ctrl.selectedFileLoading
              ? const Center(child: M3ELoadingIndicator(size: 48))
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(26, 20, 26, 36),
                  child: IRMarkdownView(
                    markdown: ctrl.selectedFileText ?? '',
                    imageUrlResolver: (src) =>
                        ctrl.api.resolveImageUrl(src, isAnkiCard: false),
                    annotations: ctrl.cachedAnnotations(path),
                    aiLayerEnabled: ctrl.aiLayerEnabled,
                    anchorLineStart: summary?.frontier?.lineStart,
                    anchorLineEnd: summary?.frontier?.lineEnd,
                  ),
                ),
        ),
      ],
    );
  }
}

class _FolderTile extends StatelessWidget {
  const _FolderTile({
    required this.label,
    required this.icon,
    required this.selected,
    required this.indent,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final int indent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    return Padding(
      padding: EdgeInsets.only(left: indent * 12.0, bottom: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(M3ERadius.full),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? cs.secondaryContainer : Colors.transparent,
            borderRadius: BorderRadius.circular(M3ERadius.full),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 18,
                color: selected ? cs.onSecondaryContainer : cs.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: (selected
                          ? typo.emphasized.labelLarge
                          : typo.baseline.bodyMedium)
                      ?.copyWith(
                    color: selected ? cs.onSecondaryContainer : cs.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileListRow extends StatelessWidget {
  const _FileListRow({
    required this.index,
    required this.total,
    required this.file,
    required this.readingSummary,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final int total;
  final FileListItem file;
  final ReadingFileSummary? readingSummary;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final semantic = IRSemanticColors.of(context);
    final pct = readingSummary != null
        ? (readingSummary!.progressRatio * 100).round()
        : null;

    return M3ESegmentedListItem(
      index: index,
      totalCount: total,
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 17,
                color: selected ? cs.onSecondaryContainer : cs.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  file.title.isNotEmpty ? file.title : file.fileName,
                  style: typo.emphasized.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (pct != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: semantic.readingContainer,
                    borderRadius: BorderRadius.circular(M3ERadius.full),
                  ),
                  child: Text(
                    readingSummary!.isComplete ? '已读完' : '$pct%',
                    style: typo.emphasized.labelSmall?.copyWith(
                      color: semantic.onReadingContainer,
                      fontSize: 10.5,
                    ),
                  ),
                ),
            ],
          ),
          if (file.directory.isNotEmpty) ...[
            const SizedBox(height: 3),
            Text(
              file.directory,
              style: typo.baseline.labelSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

class _FtsResultRow extends StatelessWidget {
  const _FtsResultRow({
    required this.index,
    required this.total,
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final int total;
  final StorageSearchResult item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);
    final cleanSnippet = item.snippet.replaceAll(RegExp(r'</?mark>'), '');

    return M3ESegmentedListItem(
      index: index,
      totalCount: total,
      selected: selected,
      onTap: onTap,
      backgroundColor: cs.primaryContainer.withValues(alpha: 0.25),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title.isNotEmpty ? item.title : (item.legacyPath ?? item.id),
            style: typo.emphasized.bodyMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (cleanSnippet.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              cleanSnippet,
              style: typo.baseline.bodySmall,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Recycle Bin Dialog (`/api/storage/trash`)
class _TrashDialog extends StatefulWidget {
  const _TrashDialog({required this.controller});
  final AppController controller;

  @override
  State<_TrashDialog> createState() => _TrashDialogState();
}

class _TrashDialogState extends State<_TrashDialog> {
  bool _loading = true;
  List<TrashItem> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.controller.api.storageTrash();
      if (mounted) setState(() => _items = list);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final typo = M3ETypography.of(context);
    return AlertDialog(
      title: const Text('回收站'),
      content: SizedBox(
        width: 540,
        height: 380,
        child: _loading
            ? const Center(child: M3ELoadingIndicator(size: 44))
            : _items.isEmpty
                ? const Center(child: Text('回收站为空'))
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (ctx, idx) {
                      final item = _items[idx];
                      return M3ESegmentedListItem(
                        index: idx,
                        totalCount: _items.length,
                        child: Row(
                          children: [
                            Icon(
                              item.kind == 'notebook'
                                  ? Icons.folder_outlined
                                  : Icons.description_outlined,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.title,
                                      style: typo.emphasized.bodyMedium),
                                  if (item.legacyPath != null)
                                    Text(item.legacyPath!,
                                        style: typo.baseline.labelSmall),
                                ],
                              ),
                            ),
                            FilledButton.tonal(
                              onPressed: () async {
                                await widget.controller.api
                                    .storageTrashRestore(item.kind, item.id);
                                await widget.controller.refreshFilesWorkbench();
                                await _load();
                              },
                              child: const Text('恢复'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
      ),
      actions: [
        if (_items.isNotEmpty)
          TextButton(
            onPressed: () async {
              final res = await widget.controller.api.storageTrashEmpty();
              widget.controller.showMessage(
                  '已清空回收站（清除 ${res.notesPurged} 篇笔记、${res.notebooksPurged} 个文件夹）');
              await _load();
            },
            child: const Text('清空回收站'),
          ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// Time-Travel Note Revision History & Rollback Dialog (`/api/notes/{id}/revisions`).
class _RevisionHistoryDialog extends StatefulWidget {
  const _RevisionHistoryDialog({
    required this.controller,
    required this.path,
  });

  final AppController controller;
  final String path;

  @override
  State<_RevisionHistoryDialog> createState() => _RevisionHistoryDialogState();
}

class _RevisionHistoryDialogState extends State<_RevisionHistoryDialog> {
  bool _loading = true;
  List<NoteRevisionMeta> _revs = const [];
  NoteRevisionMeta? _selected;
  String? _previewBody;
  bool _restoring = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final list = await widget.controller.api.getNoteRevisions(widget.path);
      if (mounted) {
        setState(() => _revs = list);
        if (list.isNotEmpty) _selectRevision(list.first);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _selectRevision(NoteRevisionMeta rev) async {
    setState(() {
      _selected = rev;
      _previewBody = null;
    });
    final body =
        await widget.controller.api.getNoteRevisionBody(widget.path, rev.id);
    if (mounted && _selected?.id == rev.id) {
      setState(() => _previewBody = body);
    }
  }

  Future<void> _restore() async {
    if (_selected == null || _restoring) return;
    setState(() => _restoring = true);
    try {
      await widget.controller.api
          .restoreNoteRevision(widget.path, _selected!.id);
      await widget.controller.selectFileForPreview(widget.path, force: true);
      widget.controller.showMessage('已回滚到历史版本 #${_selected!.id}');
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      widget.controller.showMessage('回滚失败：$e');
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final typo = M3ETypography.of(context);

    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 960, maxHeight: 680),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('历史版本 · ${widget.path}',
                  style: typo.emphasized.headlineSmall),
              const SizedBox(height: 14),
              Expanded(
                child: _loading
                    ? const Center(child: M3ELoadingIndicator(size: 44))
                    : _revs.isEmpty
                        ? const Center(child: Text('暂无历史修订记录'))
                        : Row(
                            children: [
                              SizedBox(
                                width: 260,
                                child: ListView.builder(
                                  itemCount: _revs.length,
                                  itemBuilder: (ctx, idx) {
                                    final r = _revs[idx];
                                    return M3ESegmentedListItem(
                                      index: idx,
                                      totalCount: _revs.length,
                                      selected: _selected?.id == r.id,
                                      onTap: () => _selectRevision(r),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '版本 #${r.id} · ${r.reason}',
                                            style: typo.emphasized.labelLarge,
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${r.createdAt} · ${r.byteLength} B',
                                            style: typo.baseline.labelSmall,
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: Container(
                                  padding: const EdgeInsets.all(14),
                                  decoration: BoxDecoration(
                                    color: cs.surface,
                                    borderRadius:
                                        BorderRadius.circular(M3ERadius.lg),
                                    border: Border.all(
                                        color: cs.outlineVariant
                                            .withValues(alpha: 0.5)),
                                  ),
                                  child: _previewBody == null
                                      ? const Center(
                                          child: M3ELoadingIndicator(size: 36))
                                      : SingleChildScrollView(
                                          child: SelectableText(
                                            _previewBody!,
                                            style: typo.mono,
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
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('关闭'),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    onPressed:
                        (_selected == null || _restoring) ? null : _restore,
                    icon: const Icon(Icons.restore_rounded, size: 18),
                    label: Text(_restoring ? '回滚中…' : '回滚到此版本'),
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
