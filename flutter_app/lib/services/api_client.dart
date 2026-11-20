import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../models/ir4anki_models.dart';

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode != null ? '[$statusCode] $message' : message;
}

/// Thrown on HTTP 409 from `/api/files/upload` with clashing Markdown relative paths.
class UploadConflictException extends ApiException {
  const UploadConflictException(this.conflicts)
      : super('文件名冲突', statusCode: 409);

  final List<String> conflicts;
}

class UploadFileEntry {
  const UploadFileEntry({
    required this.bytes,
    required this.fileName,
    required this.relativePath,
  });

  final List<int> bytes;
  final String fileName;
  final String relativePath;
}

/// Complete standalone desktop HTTP client for IR4Anki FastAPI backend (`backend/app.py`).
///
/// Security-guard compliant:
/// - Regular API calls omit `Origin` and `Sec-Fetch-Site`, passing `APIAccessGuard`
///   for loopback hosts and `ANKI_TRUSTED_HOSTS`.
/// - Loopback `POST /api/local/sync` explicitly injects `Origin: <origin>`,
///   `X-IR4Anki-Local-Sync: confirm`, and `{"commit_undo": true}` per `_local_sync_authorize`.
/// - Remote / admin `/api/engine/*` calls use an in-memory Bearer token only.
class IR4AnkiApiClient {
  IR4AnkiApiClient({
    String baseUrl = 'http://127.0.0.1:8901',
    http.Client? client,
  })  : _baseUrl = _normalizeBase(baseUrl),
        _client = client ?? http.Client();

  String _baseUrl;
  String _engineToken = '';
  final http.Client _client;
  final Map<String, String> _noteIdCache = <String, String>{};

  static String _normalizeBase(String url) {
    var trimmed = url.trim();
    if (trimmed.isEmpty) trimmed = 'http://127.0.0.1:8901';
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      trimmed = 'http://$trimmed';
    }
    while (trimmed.endsWith('/')) {
      trimmed = trimmed.substring(0, trimmed.length - 1);
    }
    return trimmed;
  }

  String get baseUrl => _baseUrl;
  set baseUrl(String value) {
    _baseUrl = _normalizeBase(value);
    _noteIdCache.clear();
  }

  String get engineToken => _engineToken;
  set engineToken(String value) => _engineToken = value.trim();

  bool get isLoopbackHost {
    final host = Uri.tryParse(_baseUrl)?.host.toLowerCase() ?? '';
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  String get origin {
    final uri = Uri.parse(_baseUrl);
    final portPart = uri.hasPort ? ':${uri.port}' : '';
    return '${uri.scheme}://${uri.host}$portPart';
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = Uri.parse('$_baseUrl$path');
    if (query == null || query.isEmpty) return base;
    return base.replace(queryParameters: query);
  }

  String resolveResourceUrl(String resourceId) =>
      '$_baseUrl/api/resources/${Uri.encodeComponent(resourceId)}';

  String resolveReadingMediaUrl(String name) =>
      '$_baseUrl/api/reading/media/${Uri.encodeComponent(name)}';

  String resolveAnkiMediaUrl(String name) =>
      '$_baseUrl/media/${Uri.encodeComponent(name)}';

  /// Resolves Markdown image targets following IR4Anki's rules:
  /// - `:/<resource_id>` -> `/api/resources/<id>`
  /// - `http://` / `https://` -> pass through
  /// - `/media/...` or `/api/...` -> prepend baseUrl
  /// - bare filename -> `/api/reading/media/<name>` (or `/media/<name>` for Anki cards)
  String resolveImageUrl(String src, {bool isAnkiCard = false}) {
    final s = src.trim();
    if (s.startsWith(':/')) {
      return resolveResourceUrl(s.substring(2));
    }
    if (s.startsWith('http://') || s.startsWith('https://')) {
      return s;
    }
    if (s.startsWith('/')) {
      return '$_baseUrl$s';
    }
    return isAnkiCard ? resolveAnkiMediaUrl(s) : resolveReadingMediaUrl(s);
  }

  dynamic _parseResponse(http.Response r) {
    final bodyText = utf8.decode(r.bodyBytes);
    dynamic data;
    try {
      data = jsonDecode(bodyText);
    } catch (_) {
      data = null;
    }
    if (r.statusCode < 200 || r.statusCode >= 300) {
      String msg = 'HTTP ${r.statusCode}';
      if (data is Map && data['detail'] != null) {
        final d = data['detail'];
        msg = d is String ? d : jsonEncode(d);
      } else if (bodyText.trim().isNotEmpty && bodyText.length < 240) {
        msg = bodyText.trim();
      }
      throw ApiException(msg, statusCode: r.statusCode);
    }
    if (data == null) {
      throw const ApiException('后端响应不是有效 JSON（请确认服务地址与版本）');
    }
    return data;
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? query,
    Map<String, String>? headers,
  }) async {
    try {
      final r = await _client
          .get(_uri(path, query), headers: headers)
          .timeout(const Duration(seconds: 20));
      final data = _parseResponse(r);
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on SocketException catch (e) {
      throw ApiException('无法连接到后端 $_baseUrl（${e.message}）');
    } on TimeoutException {
      throw ApiException('连接后端超时（$_baseUrl）');
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path, {
    Map<String, String>? query,
    Object? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final mergedHeaders = <String, String>{...?headers};
    String? encoded;
    if (body != null) {
      mergedHeaders['Content-Type'] = 'application/json';
      encoded = jsonEncode(body);
    }
    try {
      final r = await _client
          .post(_uri(path, query), headers: mergedHeaders, body: encoded)
          .timeout(timeout);
      final data = _parseResponse(r);
      return data is Map<String, dynamic> ? data : <String, dynamic>{};
    } on SocketException catch (e) {
      throw ApiException('无法连接到后端 $_baseUrl（${e.message}）');
    } on TimeoutException {
      throw ApiException('请求超时（$path）');
    }
  }

  Map<String, String> get _bearerHeaders =>
      _engineToken.isNotEmpty ? {'Authorization': 'Bearer $_engineToken'} : {};

  // ---- Health & Status ----

  Future<Map<String, dynamic>> getStatus() => _getJson('/api/status');

  Future<EngineStatus> getEngineStatus() async {
    final data = await _getJson('/api/engine/status', headers: _bearerHeaders);
    return EngineStatus.fromJson(data);
  }

  Future<Map<String, dynamic>> getEngineStats() =>
      _getJson('/api/engine/stats', headers: _bearerHeaders);

  Future<Map<String, dynamic>> triggerLocalOrRemoteSync() async {
    if (isLoopbackHost && _engineToken.isEmpty) {
      // Loopback sync requires exact Origin + X-IR4Anki-Local-Sync: confirm
      return _postJson(
        '/api/local/sync',
        headers: {
          'Origin': origin,
          'X-IR4Anki-Local-Sync': 'confirm',
        },
        body: const {'commit_undo': true},
        timeout: const Duration(seconds: 120),
      );
    }
    return _postJson(
      '/api/engine/sync',
      headers: _bearerHeaders,
      body: const {'commit_undo': true},
      timeout: const Duration(seconds: 120),
    );
  }

  Future<Map<String, dynamic>> triggerEngineBackup() => _postJson(
        '/api/engine/backup',
        headers: _bearerHeaders,
        body: const <String, dynamic>{},
        timeout: const Duration(seconds: 90),
      );

  // ---- Flow & Review ----

  Future<SessionStateResponse> getFlowState() async {
    final data = await _getJson('/api/flow/state');
    return SessionStateResponse.fromJson(data);
  }

  Future<SessionStateResponse> startFlow({
    String mode = 'daily',
    bool extraReading = false,
  }) async {
    final query = <String, String>{'mode': mode};
    if (extraReading) query['extra_reading'] = 'true';
    final data = await _postJson('/api/flow/start', query: query);
    return SessionStateResponse.fromJson(data);
  }

  Future<SessionStateResponse> endFlowReading() async {
    final data = await _postJson('/api/flow/end-reading');
    return SessionStateResponse.fromJson(data);
  }

  Future<void> exitFlow() async {
    await _postJson('/api/flow/exit');
  }

  Future<({bool answered, SessionStateResponse? state, String? reason})>
      answerCard(int cardId, int ease) async {
    final data = await _postJson(
      '/api/answer',
      query: {'card_id': '$cardId', 'ease': '$ease'},
    );
    return (
      answered: data['answered'] == true,
      state: data['state'] is Map<String, dynamic>
          ? SessionStateResponse.fromJson(data['state'] as Map<String, dynamic>)
          : null,
      reason: data['reason']?.toString(),
    );
  }

  Future<({bool restored, StudyCard? card})> undoAnswer() async {
    final data = await _postJson('/api/undo');
    return (
      restored: data['restored'] == true,
      card: data['card'] is Map<String, dynamic>
          ? StudyCard.fromJson(data['card'] as Map<String, dynamic>)
          : null,
    );
  }

  Future<NoteDetail> getNote(int cardId) async {
    final data = await _getJson('/api/note', query: {'card_id': '$cardId'});
    return NoteDetail.fromJson(data);
  }

  Future<({bool updated, String question, String answer})> updateNote(
    int cardId,
    Map<String, String> fields,
    List<String> tags,
  ) async {
    final data = await _postJson(
      '/api/note/update',
      body: {'card_id': cardId, 'fields': fields, 'tags': tags},
    );
    return (
      updated: data['updated'] == true,
      question: data['question']?.toString() ?? '',
      answer: data['answer']?.toString() ?? '',
    );
  }

  Future<({String modelName, List<String> fields})> getAddCardInfo({
    String kind = 'qa',
  }) async {
    final data = await _getJson(
      '/api/card/add/info',
      query: kind == 'cloze' ? {'kind': 'cloze'} : null,
    );
    return (
      modelName: data['model_name']?.toString() ?? '',
      fields: (data['fields'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
    );
  }

  Future<({int noteId, List<int> cardIds, int? pool})> addCard({
    required Map<String, String> fields,
    required List<String> tags,
    String kind = 'qa',
    String? readingPath,
    String? readingChunkKey,
  }) async {
    final body = <String, dynamic>{
      'fields': fields,
      'tags': tags,
      if (kind == 'cloze') 'kind': 'cloze',
      if (readingPath != null && readingChunkKey != null)
        'reading_source': {'path': readingPath, 'chunk_key': readingChunkKey},
    };
    final data = await _postJson('/api/card/add', body: body);
    return (
      noteId: (data['noteId'] as num).toInt(),
      cardIds: (data['cardIds'] as List?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          const [],
      pool: (data['pool'] as num?)?.toInt(),
    );
  }

  Future<void> deleteCard(int cardId) async {
    await _postJson('/api/card/delete', query: {'card_id': '$cardId'});
  }

  Future<List<String>> getTags() async {
    final data = await _getJson('/api/tags');
    return (data['tags'] as List?)?.map((e) => e.toString()).toList() ??
        const [];
  }

  Future<String> uploadAnkiMedia(List<int> bytes, String filename) async {
    final req = http.MultipartRequest('POST', _uri('/api/media/upload'));
    req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final resp = await http.Response.fromStream(streamed);
    final data = _parseResponse(resp) as Map<String, dynamic>;
    return data['filename']?.toString() ?? filename;
  }

  Future<({String filename, String? resourceId, String markdown})>
      uploadReadingMedia(List<int> bytes, String filename) async {
    final req =
        http.MultipartRequest('POST', _uri('/api/reading/media/upload'));
    req.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename));
    final streamed = await req.send().timeout(const Duration(seconds: 30));
    final resp = await http.Response.fromStream(streamed);
    final data = _parseResponse(resp) as Map<String, dynamic>;
    final resId = data['resource_id']?.toString();
    final fn = data['filename']?.toString() ?? filename;
    final md = data['markdown']?.toString() ??
        (resId != null ? '![](:/$resId)' : '![]($fn)');
    return (filename: fn, resourceId: resId, markdown: md);
  }

  // ---- Reading Mode ----

  Future<({List<ReadingFileSummary> list, int available})>
      getReadingStatus() async {
    final data = await _getJson('/api/reading/status');
    final list = (data['list'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReadingFileSummary.fromJson)
            .toList() ??
        const [];
    return (list: list, available: (data['available'] as num?)?.toInt() ?? 0);
  }

  Future<String> getReadingFile(String path) async {
    final data = await _getJson('/api/reading/file', query: {'path': path});
    return data['text']?.toString() ?? '';
  }

  Future<Map<String, dynamic>> readingAct(
    String path,
    String chunkKey,
    String action,
  ) =>
      _postJson('/api/reading/act', query: {
        'path': path,
        'chunk_key': chunkKey,
        'action': action,
      });

  Future<ReadingSplitResponse> readingSplit({
    required String path,
    required int segId,
    required int startLine,
    required int endLine,
    String? fingerprint,
    int? lineStart,
  }) async {
    final body = <String, dynamic>{
      'path': path,
      'seg_id': segId,
      'selections': [
        {'start_line': startLine, 'end_line': endLine},
      ],
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (lineStart != null) 'line_start': lineStart,
    };
    final data = await _postJson('/api/reading/split', body: body);
    return ReadingSplitResponse.fromJson(data);
  }

  Future<ReadingEditResponse> readingEdit({
    required String path,
    required int segId,
    required String newText,
    required String expectedRevision,
    required String expectedFingerprint,
  }) async {
    final data = await _postJson('/api/reading/edit', body: {
      'path': path,
      'seg_id': segId,
      'new_text': newText,
      'expected_revision': expectedRevision,
      'expected_fingerprint': expectedFingerprint,
    });
    return ReadingEditResponse.fromJson(data);
  }

  Future<ReadingSource?> getReadingSource(int noteId) async {
    try {
      final r = await _client
          .get(_uri('/api/reading/source', {'note_id': '$noteId'}))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) return null;
      final data = _parseResponse(r) as Map<String, dynamic>;
      return ReadingSource.fromJson(data);
    } on SocketException catch (e) {
      throw ApiException('网络错误：${e.message}');
    }
  }

  Future<List<ReadingCreatedCard>> getReadingCards(List<int> noteIds) async {
    if (noteIds.isEmpty) return const [];
    final data = await _getJson(
      '/api/reading/cards',
      query: {'notes': noteIds.join(',')},
    );
    return (data['cards'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(ReadingCreatedCard.fromJson)
            .toList() ??
        const [];
  }

  Future<List<AiAnnotation>> getNoteAnnotations(String path) async {
    final data = await _getJson('/api/annotations', query: {'path': path});
    return (data['annotations'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(AiAnnotation.fromJson)
            .toList() ??
        const [];
  }

  Future<void> readingListAdd(String path, {bool fresh = false}) async {
    await _postJson('/api/reading/list/add', body: {
      'path': path,
      if (fresh) 'fresh': true,
    });
  }

  Future<void> readingListRemove(String path) async {
    await _postJson('/api/reading/list/remove', body: {'path': path});
  }

  Future<void> readingListReorder({String? path, bool? top, List<String>? order}) async {
    await _postJson('/api/reading/list/reorder', body: {
      if (path != null) 'path': path,
      if (top == true) 'top': true,
      if (order != null) 'order': order,
    });
  }

  // ---- Files & Storage v2 ----

  Future<({List<FileListItem> files, List<String> dirs})> getFilesList() async {
    final data = await _getJson('/api/files/list');
    final files = (data['files'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(FileListItem.fromJson)
            .toList() ??
        const [];
    final dirs = (data['dirs'] as List?)?.map((e) => e.toString()).toList() ??
        const [];
    return (files: files, dirs: dirs);
  }

  Future<({String path, String text, String? revision, String? noteId})>
      getFileRaw(String path) async {
    final data = await _getJson('/api/files/raw', query: {'path': path});
    final resolvedPath = data['path']?.toString() ?? path;
    final noteId = data['note_id']?.toString();
    if (noteId != null && noteId.isNotEmpty) {
      _noteIdCache[path] = noteId;
      _noteIdCache[resolvedPath] = noteId;
    }
    return (
      path: resolvedPath,
      text: data['text']?.toString() ?? '',
      revision: data['revision']?.toString(),
      noteId: noteId,
    );
  }

  Future<FilesUploadResponse> uploadFiles({
    required List<UploadFileEntry> entries,
    required String dir,
    String onConflict = 'error',
  }) async {
    final req = http.MultipartRequest('POST', _uri('/api/files/upload'));
    for (final e in entries) {
      req.files.add(http.MultipartFile.fromBytes(
        'files',
        e.bytes,
        filename: e.fileName,
      ));
    }
    // http.MultipartRequest.fields is a Map, so for repeated rel_paths we use
    // MultipartFile.fromString without filename (standard multipart form field).
    for (final e in entries) {
      req.files.add(http.MultipartFile.fromString('rel_paths', e.relativePath));
    }
    req.fields['dir'] = dir;
    req.fields['on_conflict'] = onConflict;

    final streamed = await req.send().timeout(const Duration(seconds: 60));
    final resp = await http.Response.fromStream(streamed);
    if (resp.statusCode == 409) {
      final raw = jsonDecode(utf8.decode(resp.bodyBytes));
      final detail = raw is Map ? raw['detail']?.toString() ?? '' : '';
      try {
        final parsed = jsonDecode(detail);
        if (parsed is Map && parsed['conflicts'] is List) {
          final conflicts = (parsed['conflicts'] as List)
              .map((e) => e.toString())
              .toList();
          if (conflicts.isNotEmpty) {
            throw UploadConflictException(conflicts);
          }
        }
      } catch (e) {
        if (e is UploadConflictException) rethrow;
      }
      throw ApiException(detail.isNotEmpty ? detail : '上传目标冲突', statusCode: 409);
    }
    final data = _parseResponse(resp) as Map<String, dynamic>;
    return FilesUploadResponse.fromJson(data);
  }

  Future<String> filesMkdir(String dir, String name) async {
    final data =
        await _postJson('/api/files/mkdir', body: {'dir': dir, 'name': name});
    return data['path']?.toString() ?? '';
  }

  Future<({String path, String? operationId})> filesRename(
    String path,
    String newName, {
    String? requestId,
  }) async {
    final data = await _postJson('/api/files/rename', body: {
      'path': path,
      'new_name': newName,
      if (requestId != null) 'requestId': requestId,
    });
    return (
      path: data['path']?.toString() ?? path,
      operationId: data['operationId']?.toString(),
    );
  }

  Future<({String path, String? operationId})> filesMove(
    String path,
    String newDir, {
    String? requestId,
  }) async {
    final data = await _postJson('/api/files/move', body: {
      'path': path,
      'new_dir': newDir,
      if (requestId != null) 'requestId': requestId,
    });
    return (
      path: data['path']?.toString() ?? path,
      operationId: data['operationId']?.toString(),
    );
  }

  Future<void> filesDelete(String path, String confirm) async {
    await _postJson('/api/files/delete', body: {
      'path': path,
      'confirm': confirm,
    });
  }

  Future<void> filesUndo(String operationId) async {
    await _postJson('/api/files/undo', body: {'operationId': operationId});
  }

  Future<List<StorageSearchResult>> storageSearch(String query,
      {int limit = 40}) async {
    final data = await _getJson('/api/storage/search', query: {
      'q': query,
      'limit': '$limit',
    });
    return (data['results'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(StorageSearchResult.fromJson)
            .toList() ??
        const [];
  }

  Future<List<TrashItem>> storageTrash() async {
    final data = await _getJson('/api/storage/trash');
    final notebooks = (data['notebooks'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => TrashItem.fromJson('notebook', e))
            .toList() ??
        const <TrashItem>[];
    final notes = (data['notes'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => TrashItem.fromJson('note', e))
            .toList() ??
        const <TrashItem>[];
    return [...notebooks, ...notes];
  }

  Future<void> storageTrashRestore(String kind, String id) async {
    await _postJson('/api/storage/trash/restore', body: {
      'kind': kind,
      'id': id,
    });
  }

  Future<({int notesPurged, int notebooksPurged})> storageTrashEmpty() async {
    final data = await _postJson('/api/storage/trash/empty');
    return (
      notesPurged: (data['notes_purged'] as num?)?.toInt() ?? 0,
      notebooksPurged: (data['notebooks_purged'] as num?)?.toInt() ?? 0,
    );
  }

  /// Resolves a relative Markdown path or UUID to its Storage v2 note UUID.
  /// FastAPI's `/api/notes/{note_id}/revisions` takes a single path segment (UUID),
  /// so nested paths like `2026/Book/01.md` must be mapped to their UUID first.
  Future<String?> resolveNoteId(String noteIdOrPath) async {
    final trimmed = noteIdOrPath.trim();
    if (trimmed.isEmpty) return null;
    if (!trimmed.contains('/') && !trimmed.toLowerCase().endsWith('.md')) {
      return trimmed;
    }
    final cached = _noteIdCache[trimmed];
    if (cached != null && cached.isNotEmpty) return cached;

    try {
      final tree = await _getJson('/api/storage/tree');
      final notes = (tree['notes'] as List?)?.whereType<Map<String, dynamic>>();
      if (notes != null) {
        for (final n in notes) {
          final id = n['id']?.toString() ?? '';
          final p = n['path']?.toString() ?? '';
          if (id.isNotEmpty && p.isNotEmpty) {
            _noteIdCache[p] = id;
          }
        }
      }
    } catch (_) {
      // Fallback: leave cache unchanged.
    }
    return _noteIdCache[trimmed];
  }

  Future<List<NoteRevisionMeta>> getNoteRevisions(String noteIdOrPath) async {
    final noteId = await resolveNoteId(noteIdOrPath);
    if (noteId == null || noteId.isEmpty) return const [];
    final encoded = Uri.encodeComponent(noteId);
    final data = await _getJson('/api/notes/$encoded/revisions');
    return (data['revisions'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map(NoteRevisionMeta.fromJson)
            .toList() ??
        const [];
  }

  Future<String> getNoteRevisionBody(String noteIdOrPath, int revId) async {
    final noteId = await resolveNoteId(noteIdOrPath);
    if (noteId == null || noteId.isEmpty) {
      throw const ApiException('找不到对应的笔记 UUID，无法加载历史版本', statusCode: 404);
    }
    final encoded = Uri.encodeComponent(noteId);
    final data = await _getJson('/api/notes/$encoded/revisions/$revId');
    return data['body']?.toString() ?? '';
  }

  Future<void> restoreNoteRevision(String noteIdOrPath, int revId) async {
    final noteId = await resolveNoteId(noteIdOrPath);
    if (noteId == null || noteId.isEmpty) {
      throw const ApiException('找不到对应的笔记 UUID，无法恢复历史版本', statusCode: 404);
    }
    final encoded = Uri.encodeComponent(noteId);
    await _postJson('/api/notes/$encoded/revisions/$revId/restore');
  }

  void dispose() => _client.close();
}
