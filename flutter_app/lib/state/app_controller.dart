import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ir4anki_models.dart';
import '../services/api_client.dart';
import '../services/line_split_engine.dart';
import '../theme/m3e_motion.dart';
import '../theme/m3e_theme.dart';

enum AppSection { study, files, syncSettings }

enum StudyViewPhase { loading, error, start, reading, review, trace }

enum AuthoringMode { addQa, editNote, addCloze }

class AuthoringRequest {
  const AuthoringRequest({
    required this.mode,
    this.editCard,
    this.initialClozeText = '',
    this.readingPath,
    this.readingChunkKey,
  });

  final AuthoringMode mode;
  final StudyCard? editCard;
  final String initialClozeText;
  final String? readingPath;
  final String? readingChunkKey;
}

class AppController extends ChangeNotifier {
  AppController({IR4AnkiApiClient? api})
      : api = api ?? IR4AnkiApiClient();

  final IR4AnkiApiClient api;
  SharedPreferences? _prefs;

  // ---- Preferences & Theme ----
  ThemeMode _themeMode = ThemeMode.system;
  M3EPalettePreset _palette = M3EPalettePreset.expressiveViolet;
  M3EMotionScheme _motionScheme = M3EMotionScheme.expressive;
  bool _railExpanded = false;
  bool _aiLayerEnabled = true;
  double _splitRatio = 0.54;

  ThemeMode get themeMode => _themeMode;
  M3EPalettePreset get palette => _palette;
  M3EMotionScheme get motionScheme => _motionScheme;
  bool get railExpanded => _railExpanded;
  bool get aiLayerEnabled => _aiLayerEnabled;
  double get splitRatio => _splitRatio;

  // ---- Navigation ----
  AppSection _section = AppSection.study;
  AppSection get section => _section;

  // ---- Study & Flow State ----
  bool _initialLoading = true;
  bool _busy = false;
  String? _connectionError;
  SessionStateResponse? _session;
  FlowStats? _lastRoundSummary;

  /// Reveal state strictly keyed by cardId (never a bare boolean).
  int? _revealedForCardId;
  int _reviewIndex = 0;
  int _readingIndex = 0;

  /// Current card's cached raw note detail (for Markdown+Cloze rendering).
  final Map<int, NoteDetail> _noteCache = {};

  /// Provenance for the currently shown review card (`null` = orphan/none).
  ReadingSource? _reviewSource;
  int? _reviewSourceForCardId;
  bool _reviewSourceLoading = false;

  /// Trace detour (`溯源`): temporarily views a review card's source segment.
  ReadingChunk? _traceChunk;

  /// Supporting pane full-file cache & AI annotations cache.
  final Map<String, String> _fileTextCache = {};
  final Map<String, List<AiAnnotation>> _annotationCache = {};
  final Map<String, List<ReadingCreatedCard>> _relatedCardsCache = {};

  /// Non-modal authoring drawer floating over the right supporting pane.
  AuthoringRequest? _authoringRequest;

  /// Toast / snackbar message bus.
  String? _toastMessage;
  int _toastEpoch = 0;

  // ---- Files Workbench State ----
  bool _filesLoading = false;
  List<FileListItem> _files = const [];
  List<String> _dirs = const [];
  List<ReadingFileSummary> _readingList = const [];
  String _currentDir = '';
  String? _selectedFilePath;
  String? _selectedFileText;
  bool _selectedFileLoading = false;
  String _fileSearchQuery = '';
  List<StorageSearchResult> _ftsResults = const [];
  bool _ftsSearching = false;
  Timer? _searchDebounce;
  String? _lastFileOperationId;

  // ---- Engine & Sync State ----
  EngineStatus? _engineStatus;
  bool _syncing = false;
  Map<String, dynamic>? _engineStats;

  // ---- Getters ----
  bool get initialLoading => _initialLoading;
  bool get busy => _busy;
  String? get connectionError => _connectionError;
  SessionStateResponse? get session => _session;
  FlowStats? get lastRoundSummary => _lastRoundSummary;
  AuthoringRequest? get authoringRequest => _authoringRequest;
  String? get toastMessage => _toastMessage;
  int get toastEpoch => _toastEpoch;

  EngineStatus? get engineStatus => _engineStatus;
  bool get syncing => _syncing;
  Map<String, dynamic>? get engineStats => _engineStats;

  bool get filesLoading => _filesLoading;
  List<FileListItem> get files => _files;
  List<String> get dirs => _dirs;
  List<ReadingFileSummary> get readingList => _readingList;
  String get currentDir => _currentDir;
  String? get selectedFilePath => _selectedFilePath;
  String? get selectedFileText => _selectedFileText;
  bool get selectedFileLoading => _selectedFileLoading;
  String get fileSearchQuery => _fileSearchQuery;
  List<StorageSearchResult> get ftsResults => _ftsResults;
  bool get ftsSearching => _ftsSearching;
  String? get lastFileOperationId => _lastFileOperationId;

  List<ReadingChunk> get readingChunks =>
      _session?.readingRound?.chunks ?? const [];

  ReadingChunk? get currentReadingChunk {
    if (_traceChunk != null) return _traceChunk;
    final list = readingChunks;
    if (list.isEmpty) return null;
    final idx = _readingIndex.clamp(0, list.length - 1);
    return list[idx];
  }

  List<StudyCard> get reviewCards => _session?.cards ?? const [];

  StudyCard? get currentReviewCard {
    final list = reviewCards;
    if (list.isEmpty) return null;
    final idx = _reviewIndex.clamp(0, list.length - 1);
    return list[idx];
  }

  bool get isCurrentCardRevealed =>
      currentReviewCard != null &&
      _revealedForCardId == currentReviewCard!.cardId;

  NoteDetail? noteDetailFor(int cardId) => _noteCache[cardId];

  ReadingSource? get currentReviewSource =>
      currentReviewCard != null &&
              _reviewSourceForCardId == currentReviewCard!.cardId
          ? _reviewSource
          : null;

  bool get reviewSourceLoading => _reviewSourceLoading;
  bool get traceAvailable => currentReviewSource != null;

  StudyViewPhase get studyPhase {
    if (_initialLoading) return StudyViewPhase.loading;
    if (_connectionError != null && _session == null) return StudyViewPhase.error;
    if (_traceChunk != null) return StudyViewPhase.trace;
    final flow = _session?.flow;
    if (flow != null) {
      if (flow.phase == 'reading' && readingChunks.isNotEmpty) {
        return StudyViewPhase.reading;
      }
      if (flow.phase == 'review' && reviewCards.isNotEmpty) {
        return StudyViewPhase.review;
      }
      if (flow.phase == 'complete') {
        return StudyViewPhase.start;
      }
    }
    if (_session?.state == 'active' && reviewCards.isNotEmpty) {
      return StudyViewPhase.review;
    }
    if (_session?.readingRound?.status == 'active' && readingChunks.isNotEmpty) {
      return StudyViewPhase.reading;
    }
    return StudyViewPhase.start;
  }

  /// Reading progress for Navigation Rail ring.
  ({int done, int total}) get readingProgress {
    final flow = _session?.flow;
    if (flow != null && flow.readingSlots > 0) {
      return (done: flow.readingConsumed, total: flow.readingSlots);
    }
    final rr = _session?.readingRound;
    if (rr != null && rr.total > 0) {
      return (done: rr.done, total: rr.total);
    }
    final planned = _session?.readingDailyPlanned ?? 0;
    final completed = _session?.readingDailyCompleted ?? 0;
    return (done: completed, total: planned);
  }

  /// Review progress for Navigation Rail ring.
  ({int done, int total}) get reviewProgress {
    final flow = _session?.flow;
    if (flow != null && flow.effectiveCardCount > 0) {
      return (done: flow.cardAnswered, total: flow.effectiveCardCount);
    }
    if (_session != null && _session!.total > 0) {
      return (done: _session!.done, total: _session!.total);
    }
    return (done: 0, total: 0);
  }

  // ---- Lifecycle & Initialization ----

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final savedUrl = _prefs?.getString('ir4anki_server_url');
    if (savedUrl != null && savedUrl.trim().isNotEmpty) {
      api.baseUrl = savedUrl;
    }
    final themeStr = _prefs?.getString('ir4anki_theme_mode');
    if (themeStr == 'light') _themeMode = ThemeMode.light;
    if (themeStr == 'dark') _themeMode = ThemeMode.dark;

    final paletteIdx = _prefs?.getInt('ir4anki_palette') ?? 0;
    _palette = M3EPalettePreset.values[
        paletteIdx.clamp(0, M3EPalettePreset.values.length - 1)];

    final motionStr = _prefs?.getString('ir4anki_motion');
    if (motionStr == 'standard') _motionScheme = M3EMotionScheme.standard;

    _railExpanded = _prefs?.getBool('ir4anki_rail_expanded') ?? false;
    _aiLayerEnabled = _prefs?.getBool('ir4anki_ai_layer_enabled') ?? true;
    _splitRatio = (_prefs?.getDouble('ir4anki_split_ratio') ?? 0.54).clamp(0.36, 0.72);

    notifyListeners();
    await bootstrap();
  }

  Future<void> bootstrap() async {
    _initialLoading = true;
    _connectionError = null;
    notifyListeners();
    try {
      final results = await Future.wait([
        api.getFlowState(),
        api.getReadingStatus().catchError((_) => (list: const <ReadingFileSummary>[], available: 0)),
        api.getEngineStatus().catchError((_) => const EngineStatus()),
      ]);
      _applySession(results[0] as SessionStateResponse);
      _readingList = (results[1] as ({List<ReadingFileSummary> list, int available})).list;
      _engineStatus = results[2] as EngineStatus;
      _initialLoading = false;
      notifyListeners();
      _syncSideDataForCurrentView();
    } catch (e) {
      _connectionError = e.toString();
      _initialLoading = false;
      notifyListeners();
    }
  }

  void _showToast(String msg) {
    _toastMessage = msg;
    _toastEpoch++;
    notifyListeners();
  }

  void showMessage(String msg) => _showToast(msg);

  // ---- Settings & Theme Setters ----

  void setSection(AppSection next) {
    if (_section == next) return;
    _section = next;
    notifyListeners();
    if (next == AppSection.files) {
      refreshFilesWorkbench();
    } else if (next == AppSection.syncSettings) {
      refreshEngineStatus();
    }
  }

  void toggleRailExpanded() {
    _railExpanded = !_railExpanded;
    _prefs?.setBool('ir4anki_rail_expanded', _railExpanded);
    notifyListeners();
  }

  void setSplitRatio(double next) {
    _splitRatio = next.clamp(0.36, 0.72);
    _prefs?.setDouble('ir4anki_split_ratio', _splitRatio);
    notifyListeners();
  }

  void setThemeMode(ThemeMode mode) {
    _themeMode = mode;
    _prefs?.setString('ir4anki_theme_mode', mode.name);
    notifyListeners();
  }

  void setPalette(M3EPalettePreset preset) {
    _palette = preset;
    _prefs?.setInt('ir4anki_palette', preset.index);
    notifyListeners();
  }

  void setMotionScheme(M3EMotionScheme scheme) {
    _motionScheme = scheme;
    _prefs?.setString('ir4anki_motion', scheme.name);
    notifyListeners();
  }

  void toggleAiLayer() {
    _aiLayerEnabled = !_aiLayerEnabled;
    _prefs?.setBool('ir4anki_ai_layer_enabled', _aiLayerEnabled);
    notifyListeners();
  }

  Future<void> updateServerConfig(String url, {String? token}) async {
    api.baseUrl = url;
    if (token != null) api.engineToken = token;
    await _prefs?.setString('ir4anki_server_url', api.baseUrl);
    _fileTextCache.clear();
    _annotationCache.clear();
    _relatedCardsCache.clear();
    _noteCache.clear();
    await bootstrap();
  }

  // ---- Flow & Session Coordination ----

  void _applySession(SessionStateResponse next, {bool captureCompleteSummary = false}) {
    final prevPhase = _session?.flow?.phase;
    _session = next;
    _connectionError = null;
    _readingIndex = 0;
    _reviewIndex = 0;

    // Keep reveal only if the exact same card is still at index 0.
    final headCard = currentReviewCard;
    if (headCard == null || headCard.cardId != _revealedForCardId) {
      _revealedForCardId = null;
    }

    if (captureCompleteSummary &&
        prevPhase != 'complete' &&
        next.flow?.phase == 'complete') {
      _lastRoundSummary = next.flow!.stats;
    }
  }

  Future<void> resyncFlow({bool captureCompleteSummary = false}) async {
    try {
      final state = await api.getFlowState();
      _applySession(state, captureCompleteSummary: captureCompleteSummary);
      notifyListeners();
      _syncSideDataForCurrentView();
    } catch (e) {
      _showToast('状态同步失败：$e');
    }
  }

  Future<void> startDailyRound({bool extraReading = false}) async {
    if (_busy) return;
    _busy = true;
    _lastRoundSummary = null;
    _traceChunk = null;
    _authoringRequest = null;
    notifyListeners();
    try {
      final next = await api.startFlow(
        mode: _session?.defaultMode ?? 'daily',
        extraReading: extraReading,
      );
      _applySession(next);
      if (studyPhase == StudyViewPhase.start) {
        _showToast('当前没有待处理的阅读段或复习卡片');
      }
    } catch (e) {
      _showToast('开始学习失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
      _syncSideDataForCurrentView();
    }
  }

  Future<void> endReadingStage() async {
    if (_busy) return;
    _busy = true;
    _authoringRequest = null;
    notifyListeners();
    try {
      final next = await api.endFlowReading();
      _applySession(next, captureCompleteSummary: true);
    } catch (e) {
      _showToast('结束阅读失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
      _syncSideDataForCurrentView();
    }
  }

  Future<void> exitRound() async {
    if (_busy) return;
    _busy = true;
    _traceChunk = null;
    _authoringRequest = null;
    notifyListeners();
    try {
      await api.exitFlow();
      final next = await api.getFlowState();
      _applySession(next);
      _showToast('已退出本轮学习');
    } catch (e) {
      _showToast('退出本轮失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ---- Review Card Actions ----

  void revealCurrentCard() {
    final card = currentReviewCard;
    if (card == null || _busy) return;
    _revealedForCardId = card.cardId;
    notifyListeners();
    // Now that the answer is revealed, load supporting pane content!
    _loadReviewSupportingContent(card);
  }

  Future<void> answerCurrentCard(int ease) async {
    final card = currentReviewCard;
    if (card == null || _busy || !isCurrentCardRevealed) return;
    _busy = true;
    _authoringRequest = null;
    notifyListeners();
    try {
      final res = await api.answerCard(card.cardId, ease);
      if (res.state != null) {
        _applySession(res.state!, captureCompleteSummary: true);
      } else {
        await resyncFlow(captureCompleteSummary: true);
      }
    } catch (e) {
      _showToast('评分提交异常，正在恢复进度：$e');
      await resyncFlow();
    } finally {
      _busy = false;
      notifyListeners();
      _syncSideDataForCurrentView();
    }
  }

  Future<void> undoLastAnswer() async {
    if (_busy || !(_session?.canUndo ?? false)) return;
    _busy = true;
    _traceChunk = null;
    _authoringRequest = null;
    notifyListeners();
    try {
      final res = await api.undoAnswer();
      if (res.restored) {
        _showToast('已撤销上次评分');
      }
      await resyncFlow();
    } catch (e) {
      _showToast('撤销失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> deleteCurrentCard() async {
    final card = currentReviewCard;
    if (card == null || _busy) return;
    _busy = true;
    notifyListeners();
    try {
      await api.deleteCard(card.cardId);
      _noteCache.remove(card.cardId);
      _showToast('已删除该笔记及关联卡片');
      await resyncFlow(captureCompleteSummary: true);
    } catch (e) {
      _showToast('删除失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  void enterTraceDetour() {
    final src = currentReviewSource;
    if (src == null) return;
    _traceChunk = src.toTraceChunk();
    _authoringRequest = null;
    notifyListeners();
    _ensureFileAndAnnotationsLoaded(src.path);
    _loadRelatedCards(src.allNoteIds, cacheKey: 'trace:${src.path}:${src.segId}');
  }

  void exitTraceDetour() {
    if (_traceChunk == null) return;
    _traceChunk = null;
    _authoringRequest = null;
    notifyListeners();
  }

  // ---- Reading Card Actions ----

  Future<void> actOnCurrentReading(String action) async {
    final chunk = currentReadingChunk;
    if (chunk == null || _busy || studyPhase == StudyViewPhase.trace) return;
    _busy = true;
    _authoringRequest = null;
    notifyListeners();
    try {
      await api.readingAct(chunk.path, chunk.chunkKey, action);
      await resyncFlow(captureCompleteSummary: true);
    } catch (e) {
      _showToast('操作失败：$e');
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> splitCurrentReading(LineSplitSelection selection) async {
    final chunk = currentReadingChunk;
    if (chunk == null || chunk.segId == null || _busy) return false;
    _busy = true;
    notifyListeners();
    try {
      final fileStart = chunk.lineStart + selection.startLine - 1;
      final fileEnd = chunk.lineStart + selection.endLine - 1;
      final res = await api.readingSplit(
        path: chunk.path,
        segId: chunk.segId!,
        startLine: fileStart,
        endLine: fileEnd,
        fingerprint: chunk.fingerprint,
        lineStart: chunk.lineStart,
      );
      if (studyPhase == StudyViewPhase.trace && res.childChunks.isNotEmpty) {
        _traceChunk = res.childChunks.first;
      } else {
        await resyncFlow();
      }
      _showToast('已切分第 $fileStart–$fileEnd 行（保留未读尾部）');
      return true;
    } catch (e) {
      _showToast('切分失败：$e');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<bool> editCurrentReading(String newText) async {
    final chunk = currentReadingChunk;
    if (chunk == null || chunk.segId == null || _busy) return false;
    _busy = true;
    notifyListeners();
    try {
      final res = await api.readingEdit(
        path: chunk.path,
        segId: chunk.segId!,
        newText: newText,
        expectedRevision: chunk.editRevision ?? '',
        expectedFingerprint: chunk.fingerprint ?? '',
      );
      _fileTextCache.remove(chunk.path);
      _annotationCache.remove(chunk.path);
      if (studyPhase == StudyViewPhase.trace && res.chunk != null) {
        _traceChunk = res.chunk;
      } else {
        await resyncFlow();
      }
      await _ensureFileAndAnnotationsLoaded(chunk.path, force: true);
      _showToast('片段已保存（修订快照已归档）');
      return true;
    } catch (e) {
      _showToast('保存编辑失败：$e');
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  // ---- Non-Modal Card Authoring Drawer ----

  void openAddQaDrawer() {
    final provenance = _resolveCurrentProvenance();
    _authoringRequest = AuthoringRequest(
      mode: AuthoringMode.addQa,
      readingPath: provenance?.$1,
      readingChunkKey: provenance?.$2,
    );
    notifyListeners();
  }

  void openAddClozeDrawer(String initialText) {
    final provenance = _resolveCurrentProvenance();
    _authoringRequest = AuthoringRequest(
      mode: AuthoringMode.addCloze,
      initialClozeText: initialText,
      readingPath: provenance?.$1,
      readingChunkKey: provenance?.$2,
    );
    notifyListeners();
  }

  void openEditCurrentCardDrawer() {
    final card = currentReviewCard;
    if (card == null) return;
    _authoringRequest = AuthoringRequest(
      mode: AuthoringMode.editNote,
      editCard: card,
    );
    notifyListeners();
  }

  void closeAuthoringDrawer() {
    if (_authoringRequest == null) return;
    _authoringRequest = null;
    notifyListeners();
  }

  (String, String)? _resolveCurrentProvenance() {
    if (studyPhase == StudyViewPhase.reading ||
        studyPhase == StudyViewPhase.trace) {
      final c = currentReadingChunk;
      if (c != null && c.path.isNotEmpty && c.chunkKey.isNotEmpty) {
        return (c.path, c.chunkKey);
      }
    } else if (studyPhase == StudyViewPhase.review) {
      final src = currentReviewSource;
      if (src != null && src.segId != null) {
        return (src.path, 'seg:${src.segId}');
      }
    }
    return null;
  }

  Future<void> onCardAdded(int noteId) async {
    _showToast('卡片已添加（Note #$noteId，进入明日预览池）');
    _relatedCardsCache.clear();
    if (studyPhase == StudyViewPhase.reading) {
      await resyncFlow();
    } else if (studyPhase == StudyViewPhase.trace && _traceChunk != null) {
      _traceChunk = _traceChunk!.copyWith(
        status: _traceChunk!.status == 'todo' ? 'active' : _traceChunk!.status,
        cardsCreated: [..._traceChunk!.cardsCreated, noteId],
      );
      notifyListeners();
      _loadRelatedCards(_traceChunk!.allRelatedNoteIds,
          cacheKey: 'trace:${_traceChunk!.path}:${_traceChunk!.segId}');
    } else if (studyPhase == StudyViewPhase.review && currentReviewCard != null) {
      await _loadReviewSupportingContent(currentReviewCard!, force: true);
    }
  }

  Future<void> onCardUpdated(int cardId, String q, String a) async {
    _noteCache.remove(cardId);
    _relatedCardsCache.clear();
    _revealedForCardId = null;
    _showToast('卡片已更新');
    await resyncFlow();
  }

  // ---- Supporting Pane Data Loaders ----

  String? cachedFileText(String path) => _fileTextCache[path];
  List<AiAnnotation> cachedAnnotations(String path) =>
      _annotationCache[path] ?? const [];
  List<ReadingCreatedCard> cachedRelatedCards(String key) =>
      _relatedCardsCache[key] ?? const [];

  String get currentRelatedCacheKey {
    if (studyPhase == StudyViewPhase.reading ||
        studyPhase == StudyViewPhase.trace) {
      final c = currentReadingChunk;
      return c != null ? 'chunk:${c.path}:${c.chunkKey}' : '';
    }
    final card = currentReviewCard;
    return card != null ? 'card:${card.cardId}' : '';
  }

  void _syncSideDataForCurrentView() {
    final phase = studyPhase;
    if (phase == StudyViewPhase.reading || phase == StudyViewPhase.trace) {
      final chunk = currentReadingChunk;
      if (chunk != null) {
        _ensureFileAndAnnotationsLoaded(chunk.path);
        _loadRelatedCards(
          chunk.allRelatedNoteIds,
          cacheKey: 'chunk:${chunk.path}:${chunk.chunkKey}',
        );
      }
    } else if (phase == StudyViewPhase.review) {
      final card = currentReviewCard;
      if (card != null) {
        _ensureCardNoteDetailLoaded(card);
        _loadReviewSourceMetadata(card);
      }
    }
  }

  Future<void> _ensureCardNoteDetailLoaded(StudyCard card) async {
    if (_noteCache.containsKey(card.cardId)) return;
    if (card.fields != null && card.tags.isNotEmpty && card.ord != null) {
      _noteCache[card.cardId] = NoteDetail(
        cardId: card.cardId,
        noteId: card.noteId ?? 0,
        modelName: card.modelName,
        fields: card.fields!,
        tags: card.tags,
        kind: card.kind,
        ord: card.ord,
      );
      notifyListeners();
      return;
    }
    try {
      final detail = await api.getNote(card.cardId);
      _noteCache[card.cardId] = detail;
      notifyListeners();
    } catch (_) {
      // Fall back to card.question/answer HTML
    }
  }

  Future<void> _loadReviewSourceMetadata(StudyCard card) async {
    final noteId = card.noteId ?? _noteCache[card.cardId]?.noteId;
    if (noteId == null || noteId == 0) {
      // Wait for note detail first if needed
      try {
        final detail = await api.getNote(card.cardId);
        _noteCache[card.cardId] = detail;
        if (currentReviewCard?.cardId != card.cardId) return;
        await _fetchReviewSourceByNoteId(card, detail.noteId);
      } catch (_) {}
      return;
    }
    await _fetchReviewSourceByNoteId(card, noteId);
  }

  Future<void> _fetchReviewSourceByNoteId(StudyCard card, int noteId) async {
    if (_reviewSourceForCardId == card.cardId && !_reviewSourceLoading) return;
    _reviewSourceForCardId = card.cardId;
    _reviewSource = null;
    _reviewSourceLoading = true;
    notifyListeners();
    try {
      final src = await api.getReadingSource(noteId);
      if (currentReviewCard?.cardId != card.cardId) return;
      _reviewSource = src;
      _reviewSourceLoading = false;
      notifyListeners();
      if (isCurrentCardRevealed && src != null) {
        await _loadReviewSupportingContent(card);
      }
    } catch (_) {
      if (currentReviewCard?.cardId == card.cardId) {
        _reviewSourceLoading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadReviewSupportingContent(StudyCard card,
      {bool force = false}) async {
    final src = currentReviewSource;
    if (src == null) return;
    await _ensureFileAndAnnotationsLoaded(src.path, force: force);
    await _loadRelatedCards(
      src.allNoteIds,
      cacheKey: 'card:${card.cardId}',
      force: force,
    );
  }

  Future<void> _ensureFileAndAnnotationsLoaded(String path,
      {bool force = false}) async {
    if (path.isEmpty) return;
    final futures = <Future<void>>[];
    if (force || !_fileTextCache.containsKey(path)) {
      futures.add(api.getReadingFile(path).then((txt) {
        _fileTextCache[path] = txt;
      }).catchError((_) {}));
    }
    if (force || !_annotationCache.containsKey(path)) {
      futures.add(api.getNoteAnnotations(path).then((anns) {
        _annotationCache[path] = anns;
      }).catchError((_) {}));
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
      notifyListeners();
    }
  }

  Future<void> _loadRelatedCards(
    List<int> noteIds, {
    required String cacheKey,
    bool force = false,
  }) async {
    if (noteIds.isEmpty) {
      _relatedCardsCache[cacheKey] = const [];
      notifyListeners();
      return;
    }
    if (!force && _relatedCardsCache.containsKey(cacheKey)) return;
    try {
      final cards = await api.getReadingCards(noteIds);
      _relatedCardsCache[cacheKey] = cards;
      notifyListeners();
    } catch (_) {}
  }

  // ---- Files Workbench Actions ----

  Future<void> refreshFilesWorkbench() async {
    _filesLoading = true;
    notifyListeners();
    try {
      final res = await Future.wait([
        api.getFilesList(),
        api.getReadingStatus(),
      ]);
      final fl = res[0] as ({List<FileListItem> files, List<String> dirs});
      final rs =
          res[1] as ({List<ReadingFileSummary> list, int available});
      _files = fl.files;
      _dirs = fl.dirs;
      _readingList = rs.list;
    } catch (e) {
      _showToast('加载文件工作台失败：$e');
    } finally {
      _filesLoading = false;
      notifyListeners();
    }
  }

  void setCurrentDir(String dir) {
    _currentDir = dir;
    notifyListeners();
  }

  Future<void> selectFileForPreview(String? path, {bool force = false}) async {
    _selectedFilePath = path;
    if (path == null) {
      _selectedFileText = null;
      _selectedFileLoading = false;
      notifyListeners();
      return;
    }
    _selectedFileLoading = true;
    notifyListeners();
    try {
      final raw = await api.getFileRaw(path);
      _selectedFileText = raw.text;
      _fileTextCache[path] = raw.text;
      await _ensureFileAndAnnotationsLoaded(path, force: force);
    } catch (e) {
      _showToast('读取笔记失败：$e');
    } finally {
      _selectedFileLoading = false;
      notifyListeners();
    }
  }

  void setFileSearchQuery(String query) {
    _fileSearchQuery = query;
    notifyListeners();
    _searchDebounce?.cancel();
    final trimmed = query.trim();
    if (trimmed.length < 2) {
      _ftsResults = const [];
      _ftsSearching = false;
      notifyListeners();
      return;
    }
    _ftsSearching = true;
    notifyListeners();
    _searchDebounce = Timer(const Duration(milliseconds: 220), () async {
      try {
        final results = await api.storageSearch(trimmed);
        if (_fileSearchQuery.trim() == trimmed) {
          _ftsResults = results;
          _ftsSearching = false;
          notifyListeners();
        }
      } catch (_) {
        _ftsSearching = false;
        notifyListeners();
      }
    });
  }

  Future<void> addToReadingList(String path, {bool fresh = false}) async {
    try {
      await api.readingListAdd(path, fresh: fresh);
      await refreshFilesWorkbench();
      await resyncFlow();
      _showToast(fresh ? '已重新播种并加入阅读清单' : '已加入阅读清单');
    } catch (e) {
      _showToast('加入阅读清单失败：$e');
    }
  }

  Future<void> removeFromReadingList(String path) async {
    try {
      await api.readingListRemove(path);
      await refreshFilesWorkbench();
      await resyncFlow();
      _showToast('已移出阅读清单（进度已归档）');
    } catch (e) {
      _showToast('移出失败：$e');
    }
  }

  Future<void> moveReadingItemToTop(String path) async {
    try {
      await api.readingListReorder(path: path, top: true);
      await refreshFilesWorkbench();
      _showToast('已置顶到阅读清单首位');
    } catch (e) {
      _showToast('置顶失败：$e');
    }
  }

  Future<void> reorderReadingList(int oldIndex, int newIndex) async {
    if (oldIndex == newIndex) return;
    final list = List<ReadingFileSummary>.from(_readingList);
    if (newIndex > oldIndex) newIndex--;
    final item = list.removeAt(oldIndex);
    list.insert(newIndex, item);
    _readingList = list;
    notifyListeners();
    try {
      await api.readingListReorder(order: list.map((e) => e.path).toList());
    } catch (e) {
      _showToast('排序保存失败：$e');
      await refreshFilesWorkbench();
    }
  }

  Future<void> createFolder(String name) async {
    try {
      await api.filesMkdir(_currentDir, name.trim());
      await refreshFilesWorkbench();
      _showToast('已新建文件夹「$name」');
    } catch (e) {
      _showToast('新建文件夹失败：$e');
    }
  }

  Future<void> renamePath(String path, String newName) async {
    try {
      final res = await api.filesRename(path, newName.trim());
      _lastFileOperationId = res.operationId;
      if (_selectedFilePath == path) _selectedFilePath = res.path;
      await refreshFilesWorkbench();
      _showToast('已重命名为 ${res.path}');
    } catch (e) {
      _showToast('重命名失败：$e');
    }
  }

  Future<void> deletePath(String path) async {
    try {
      final base = path.split('/').last;
      await api.filesDelete(path, base);
      if (_selectedFilePath == path) {
        _selectedFilePath = null;
        _selectedFileText = null;
      }
      await refreshFilesWorkbench();
      _showToast('已移入回收站：$base');
    } catch (e) {
      _showToast('删除失败：$e');
    }
  }

  Future<void> undoLastFileOperation() async {
    final opId = _lastFileOperationId;
    if (opId == null) return;
    try {
      await api.filesUndo(opId);
      _lastFileOperationId = null;
      await refreshFilesWorkbench();
      _showToast('已撤销上一次文件操作');
    } catch (e) {
      _showToast('撤销文件操作失败：$e');
    }
  }

  // ---- Engine & Sync Actions ----

  Future<void> refreshEngineStatus() async {
    try {
      _engineStatus = await api.getEngineStatus();
      if (api.engineToken.isNotEmpty) {
        _engineStats = await api.getEngineStats().catchError((_) => <String, dynamic>{});
      }
      notifyListeners();
    } catch (_) {}
  }

  Future<bool> runManualSync() async {
    if (_syncing) return false;
    _syncing = true;
    notifyListeners();
    try {
      await api.triggerLocalOrRemoteSync();
      await refreshEngineStatus();
      await resyncFlow();
      _showToast('Anki 同步完成');
      return true;
    } catch (e) {
      _showToast('同步失败：$e');
      await refreshEngineStatus();
      return false;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    api.dispose();
    super.dispose();
  }
}
