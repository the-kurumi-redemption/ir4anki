/// Wire models matching IR4Anki FastAPI backend (`backend/app.py` & `frontend/src/types.ts`).
library;

class MemoryState {
  const MemoryState({
    this.stability,
    this.difficulty,
    this.retention,
  });

  final double? stability;
  final double? difficulty;
  final double? retention;

  factory MemoryState.fromJson(Map<String, dynamic> json) => MemoryState(
        stability: (json['stability'] as num?)?.toDouble(),
        difficulty: (json['difficulty'] as num?)?.toDouble(),
        retention: (json['retention'] as num?)?.toDouble(),
      );
}

class StudyCard {
  const StudyCard({
    required this.cardId,
    this.noteId,
    this.kind,
    this.tags = const [],
    this.fields,
    this.ord,
    this.nextIntervals,
    this.memoryState,
    required this.question,
    required this.answer,
    required this.deckName,
    required this.modelName,
    this.css = '',
    this.isNew = false,
    this.due = 0,
  });

  final int cardId;
  final int? noteId;
  final String? kind; // 'qa' | 'cloze'
  final List<String> tags;
  final Map<String, String>? fields;
  final int? ord;
  final List<String>? nextIntervals; // [again, hard, good, easy]
  final MemoryState? memoryState;
  final String question;
  final String answer;
  final String deckName;
  final String modelName;
  final String css;
  final bool isNew;
  final int due;

  bool get isCloze =>
      kind == 'cloze' ||
      RegExp(r'cloze|填空', caseSensitive: false).hasMatch(modelName);

  factory StudyCard.fromJson(Map<String, dynamic> json) {
    Map<String, String>? parsedFields;
    if (json['fields'] is Map) {
      parsedFields = {};
      (json['fields'] as Map).forEach((k, v) {
        if (v is Map && v['value'] != null) {
          parsedFields![k.toString()] = v['value'].toString();
        } else {
          parsedFields![k.toString()] = v?.toString() ?? '';
        }
      });
    }
    List<String>? intervals;
    if (json['next_intervals'] is List) {
      intervals = (json['next_intervals'] as List)
          .map((e) => e?.toString() ?? '')
          .toList();
    }
    return StudyCard(
      cardId: (json['cardId'] as num).toInt(),
      noteId: (json['noteId'] as num?)?.toInt(),
      kind: json['kind']?.toString(),
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      fields: parsedFields,
      ord: (json['ord'] as num?)?.toInt(),
      nextIntervals: intervals,
      memoryState: json['memory_state'] is Map<String, dynamic>
          ? MemoryState.fromJson(json['memory_state'] as Map<String, dynamic>)
          : null,
      question: json['question']?.toString() ?? '',
      answer: json['answer']?.toString() ?? '',
      deckName: json['deckName']?.toString() ?? '',
      modelName: json['modelName']?.toString() ?? '',
      css: json['css']?.toString() ?? '',
      isNew: json['isNew'] == true,
      due: (json['due'] as num?)?.toInt() ?? 0,
    );
  }

  StudyCard copyWith({
    String? question,
    String? answer,
    Map<String, String>? fields,
    List<String>? tags,
  }) =>
      StudyCard(
        cardId: cardId,
        noteId: noteId,
        kind: kind,
        tags: tags ?? this.tags,
        fields: fields ?? this.fields,
        ord: ord,
        nextIntervals: nextIntervals,
        memoryState: memoryState,
        question: question ?? this.question,
        answer: answer ?? this.answer,
        deckName: deckName,
        modelName: modelName,
        css: css,
        isNew: isNew,
        due: due,
      );
}

class StudyModeSizes {
  const StudyModeSizes({required this.newCount, required this.reviewCount});

  final int newCount;
  final int reviewCount;

  factory StudyModeSizes.fromJson(Map<String, dynamic> json) => StudyModeSizes(
        newCount: (json['new'] as num?)?.toInt() ?? 0,
        reviewCount: (json['review'] as num?)?.toInt() ?? 0,
      );
}

class FlowStats {
  const FlowStats({
    this.readingDone = 0,
    this.readingSkipped = 0,
    this.readingNext = 0,
    this.reviewed = 0,
    this.newReviewed = 0,
  });

  final int readingDone;
  final int readingSkipped;
  final int readingNext;
  final int reviewed;
  final int newReviewed;

  int get totalReading => readingDone + readingSkipped + readingNext;

  factory FlowStats.fromJson(Map<String, dynamic> json) => FlowStats(
        readingDone: (json['readingDone'] as num?)?.toInt() ?? 0,
        readingSkipped: (json['readingSkipped'] as num?)?.toInt() ?? 0,
        readingNext: (json['readingNext'] as num?)?.toInt() ?? 0,
        reviewed: (json['reviewed'] as num?)?.toInt() ?? 0,
        newReviewed: (json['newReviewed'] as num?)?.toInt() ?? 0,
      );
}

class FlowState {
  const FlowState({
    required this.id,
    required this.policy,
    required this.phase,
    required this.readingConsumed,
    required this.cardHandled,
    required this.cardAnswered,
    required this.effectiveCardCount,
    required this.readingSlots,
    required this.cardCount,
    required this.blocks,
    required this.stats,
  });

  final String id;
  final String policy;
  final String phase; // 'reading' | 'review' | 'complete'
  final int readingConsumed;
  final int cardHandled;
  final int cardAnswered;
  final int effectiveCardCount;
  final int readingSlots;
  final int cardCount;
  final List<int> blocks;
  final FlowStats stats;

  factory FlowState.fromJson(Map<String, dynamic> json) => FlowState(
        id: json['id']?.toString() ?? '',
        policy: json['policy']?.toString() ?? 'even-floor-v1',
        phase: json['phase']?.toString() ?? 'complete',
        readingConsumed: (json['reading_consumed'] as num?)?.toInt() ?? 0,
        cardHandled: (json['card_handled'] as num?)?.toInt() ?? 0,
        cardAnswered: (json['card_answered'] as num?)?.toInt() ?? 0,
        effectiveCardCount:
            (json['effective_card_count'] as num?)?.toInt() ?? 0,
        readingSlots: (json['reading_slots'] as num?)?.toInt() ?? 0,
        cardCount: (json['card_count'] as num?)?.toInt() ?? 0,
        blocks: (json['blocks'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        stats: json['stats'] is Map<String, dynamic>
            ? FlowStats.fromJson(json['stats'] as Map<String, dynamic>)
            : const FlowStats(),
      );
}

class ReadingChunk {
  const ReadingChunk({
    this.kind = 'markdown',
    required this.path,
    required this.chunkKey,
    this.segId,
    this.parentSegId,
    required this.title,
    this.headingPath = const [],
    this.lineStart = 1,
    this.lineEnd = 1,
    this.text = '',
    this.fingerprint,
    this.editRevision,
    this.status = 'todo',
    this.cardsCreated = const [],
    this.ancestorCards = const [],
    this.fileChunks = 1,
    this.fileDone = 0,
    this.fileSkipped = 0,
    this.pageStart,
    this.pageEnd,
  });

  final String kind; // 'markdown' | 'pdf'
  final String path;
  final String chunkKey;
  final int? segId;
  final int? parentSegId;
  final String title;
  final List<String> headingPath;
  final int lineStart;
  final int lineEnd;
  final String text;
  final String? fingerprint;
  final String? editRevision;
  final String status;
  final List<int> cardsCreated;
  final List<int> ancestorCards;
  final int fileChunks;
  final int fileDone;
  final int fileSkipped;
  final int? pageStart;
  final int? pageEnd;

  bool get isPdf => kind == 'pdf';
  bool get canSplit => !isPdf && segId != null && status != 'container';

  List<int> get allRelatedNoteIds {
    final seen = <int>{};
    final out = <int>[];
    for (final id in [...cardsCreated, ...ancestorCards]) {
      if (seen.add(id)) out.add(id);
    }
    return out;
  }

  factory ReadingChunk.fromJson(Map<String, dynamic> json) => ReadingChunk(
        kind: json['kind']?.toString() ?? 'markdown',
        path: json['path']?.toString() ?? '',
        chunkKey: json['chunk_key']?.toString() ?? '',
        segId: (json['seg_id'] as num?)?.toInt(),
        parentSegId: (json['parent_seg_id'] as num?)?.toInt(),
        title: json['title']?.toString() ?? '',
        headingPath: (json['heading_path'] as List?)
                ?.map((e) => e.toString())
                .toList() ??
            const [],
        lineStart: (json['line_start'] as num?)?.toInt() ?? 1,
        lineEnd: (json['line_end'] as num?)?.toInt() ?? 1,
        text: json['text']?.toString() ?? '',
        fingerprint: json['fingerprint']?.toString(),
        editRevision: json['edit_revision']?.toString(),
        status: json['status']?.toString() ?? 'todo',
        cardsCreated: (json['cards_created'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        ancestorCards: (json['ancestor_cards'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        fileChunks: (json['file_chunks'] as num?)?.toInt() ?? 1,
        fileDone: (json['file_done'] as num?)?.toInt() ?? 0,
        fileSkipped: (json['file_skipped'] as num?)?.toInt() ?? 0,
        pageStart: (json['page_start'] as num?)?.toInt(),
        pageEnd: (json['page_end'] as num?)?.toInt(),
      );

  ReadingChunk copyWith({
    String? status,
    List<int>? cardsCreated,
    String? text,
    int? lineStart,
    int? lineEnd,
    String? fingerprint,
    String? editRevision,
  }) =>
      ReadingChunk(
        kind: kind,
        path: path,
        chunkKey: chunkKey,
        segId: segId,
        parentSegId: parentSegId,
        title: title,
        headingPath: headingPath,
        lineStart: lineStart ?? this.lineStart,
        lineEnd: lineEnd ?? this.lineEnd,
        text: text ?? this.text,
        fingerprint: fingerprint ?? this.fingerprint,
        editRevision: editRevision ?? this.editRevision,
        status: status ?? this.status,
        cardsCreated: cardsCreated ?? this.cardsCreated,
        ancestorCards: ancestorCards,
        fileChunks: fileChunks,
        fileDone: fileDone,
        fileSkipped: fileSkipped,
        pageStart: pageStart,
        pageEnd: pageEnd,
      );
}

class ReadingRound {
  const ReadingRound({
    required this.status,
    this.chunks = const [],
    this.done = 0,
    this.total = 0,
    this.mode,
  });

  final String status; // 'active' | 'complete'
  final List<ReadingChunk> chunks;
  final int done;
  final int total;
  final String? mode;

  factory ReadingRound.fromJson(Map<String, dynamic> json) => ReadingRound(
        status: json['status']?.toString() ?? 'complete',
        chunks: (json['chunks'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(ReadingChunk.fromJson)
                .toList() ??
            const [],
        done: (json['done'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        mode: json['mode']?.toString(),
      );
}

class SessionStateResponse {
  const SessionStateResponse({
    required this.state,
    this.cards = const [],
    this.done = 0,
    this.total = 0,
    this.newInBatch,
    this.dueRemaining,
    this.newPerRound,
    this.newTotal,
    this.canUndo = false,
    this.mode,
    this.previewMode = false,
    this.previewPool,
    this.pendingRelease,
    this.releaseDailyGoal,
    this.releaseBudgetLeft,
    this.studyModes = const {},
    this.defaultMode = 'daily',
    this.readingMode = false,
    this.readingListSize = 0,
    this.readingAvailable = 0,
    this.readingDealable = 0,
    this.readingDailyDone = false,
    this.readingDailyPlanned = 0,
    this.readingDailyRemaining = 0,
    this.readingDailyCompleted = 0,
    this.readingExtraRounds = 0,
    this.readingDealableExtra = 0,
    this.readingActive = 0,
    this.readingGated = 0,
    this.readingRound,
    this.flow,
  });

  final String state; // 'none' | 'active' | 'complete'
  final List<StudyCard> cards;
  final int done;
  final int total;
  final int? newInBatch;
  final int? dueRemaining;
  final int? newPerRound;
  final int? newTotal;
  final bool canUndo;
  final String? mode;
  final bool previewMode;
  final int? previewPool;
  final int? pendingRelease;
  final int? releaseDailyGoal;
  final int? releaseBudgetLeft;
  final Map<String, StudyModeSizes> studyModes;
  final String defaultMode;
  final bool readingMode;
  final int readingListSize;
  final int readingAvailable;
  final int readingDealable;
  final bool readingDailyDone;
  final int readingDailyPlanned;
  final int readingDailyRemaining;
  final int readingDailyCompleted;
  final int readingExtraRounds;
  final int readingDealableExtra;
  final int readingActive;
  final int readingGated;
  final ReadingRound? readingRound;
  final FlowState? flow;

  StudyModeSizes? get dailyPlan =>
      studyModes[mode ?? defaultMode] ?? studyModes['daily'];

  factory SessionStateResponse.fromJson(Map<String, dynamic> json) {
    final modes = <String, StudyModeSizes>{};
    if (json['study_modes'] is Map) {
      (json['study_modes'] as Map).forEach((k, v) {
        if (v is Map<String, dynamic>) {
          modes[k.toString()] = StudyModeSizes.fromJson(v);
        }
      });
    }
    return SessionStateResponse(
      state: json['state']?.toString() ?? 'none',
      cards: (json['cards'] as List?)
              ?.whereType<Map<String, dynamic>>()
              .map(StudyCard.fromJson)
              .toList() ??
          const [],
      done: (json['done'] as num?)?.toInt() ?? 0,
      total: (json['total'] as num?)?.toInt() ?? 0,
      newInBatch: (json['new_in_batch'] as num?)?.toInt(),
      dueRemaining: (json['due_remaining'] as num?)?.toInt(),
      newPerRound: (json['new_per_round'] as num?)?.toInt(),
      newTotal: (json['new_total'] as num?)?.toInt(),
      canUndo: json['can_undo'] == true,
      mode: json['mode']?.toString(),
      previewMode: json['preview_mode'] == true,
      previewPool: (json['preview_pool'] as num?)?.toInt(),
      pendingRelease: (json['pending_release'] as num?)?.toInt(),
      releaseDailyGoal: (json['release_daily_goal'] as num?)?.toInt(),
      releaseBudgetLeft: (json['release_budget_left'] as num?)?.toInt(),
      studyModes: modes,
      defaultMode: json['default_mode']?.toString() ?? 'daily',
      readingMode: json['reading_mode'] == true,
      readingListSize: (json['reading_list_size'] as num?)?.toInt() ?? 0,
      readingAvailable: (json['reading_available'] as num?)?.toInt() ?? 0,
      readingDealable: (json['reading_dealable'] as num?)?.toInt() ?? 0,
      readingDailyDone: json['reading_daily_done'] == true,
      readingDailyPlanned:
          (json['reading_daily_planned'] as num?)?.toInt() ?? 0,
      readingDailyRemaining:
          (json['reading_daily_remaining'] as num?)?.toInt() ?? 0,
      readingDailyCompleted:
          (json['reading_daily_completed'] as num?)?.toInt() ?? 0,
      readingExtraRounds: (json['reading_extra_rounds'] as num?)?.toInt() ?? 0,
      readingDealableExtra:
          (json['reading_dealable_extra'] as num?)?.toInt() ?? 0,
      readingActive: (json['reading_active'] as num?)?.toInt() ?? 0,
      readingGated: (json['reading_gated'] as num?)?.toInt() ?? 0,
      readingRound: json['reading_round'] is Map<String, dynamic>
          ? ReadingRound.fromJson(
              json['reading_round'] as Map<String, dynamic>)
          : null,
      flow: json['flow'] is Map<String, dynamic>
          ? FlowState.fromJson(json['flow'] as Map<String, dynamic>)
          : null,
    );
  }
}

class ReadingSourceCrumb {
  const ReadingSourceCrumb({
    required this.segId,
    required this.status,
    required this.title,
    this.lineStart,
    this.lineEnd,
    this.cardsCreated = const [],
  });

  final int segId;
  final String status;
  final String title;
  final int? lineStart;
  final int? lineEnd;
  final List<int> cardsCreated;

  factory ReadingSourceCrumb.fromJson(Map<String, dynamic> json) =>
      ReadingSourceCrumb(
        segId: (json['seg_id'] as num?)?.toInt() ?? 0,
        status: json['status']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        lineStart: (json['line_start'] as num?)?.toInt(),
        lineEnd: (json['line_end'] as num?)?.toInt(),
        cardsCreated: (json['cards_created'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
      );
}

class ReadingSource {
  const ReadingSource({
    this.kind = 'markdown',
    required this.path,
    this.segId,
    this.status = 'todo',
    this.stale = false,
    this.lineStart = 1,
    this.lineEnd = 1,
    this.fingerprint,
    this.editRevision,
    this.text = '',
    this.cardsCreated = const [],
    this.breadcrumb = const [],
  });

  final String kind;
  final String path;
  final int? segId;
  final String status;
  final bool stale;
  final int lineStart;
  final int lineEnd;
  final String? fingerprint;
  final String? editRevision;
  final String text;
  final List<int> cardsCreated;
  final List<ReadingSourceCrumb> breadcrumb;

  List<int> get allNoteIds {
    final seen = <int>{};
    final out = <int>[];
    for (final id in cardsCreated) {
      if (seen.add(id)) out.add(id);
    }
    for (final crumb in breadcrumb) {
      for (final id in crumb.cardsCreated) {
        if (seen.add(id)) out.add(id);
      }
    }
    return out;
  }

  ReadingChunk toTraceChunk() {
    final ancestorIds = <int>[];
    final seen = cardsCreated.toSet();
    for (final c in breadcrumb) {
      for (final id in c.cardsCreated) {
        if (seen.add(id)) ancestorIds.add(id);
      }
    }
    final title = breadcrumb.isNotEmpty
        ? breadcrumb.last.title
        : path.split('/').last.replaceAll(RegExp(r'\.md$'), '');
    return ReadingChunk(
      kind: kind,
      path: path,
      chunkKey: segId != null ? 'seg:$segId' : '',
      segId: segId,
      title: title,
      headingPath: breadcrumb.map((e) => e.title).where((s) => s.isNotEmpty).toList(),
      lineStart: lineStart,
      lineEnd: lineEnd,
      text: text,
      fingerprint: fingerprint,
      editRevision: editRevision,
      status: status,
      cardsCreated: cardsCreated,
      ancestorCards: ancestorIds,
    );
  }

  factory ReadingSource.fromJson(Map<String, dynamic> json) => ReadingSource(
        kind: json['kind']?.toString() ?? 'markdown',
        path: json['path']?.toString() ?? '',
        segId: (json['seg_id'] as num?)?.toInt(),
        status: json['status']?.toString() ?? 'todo',
        stale: json['stale'] == true,
        lineStart: (json['line_start'] as num?)?.toInt() ?? 1,
        lineEnd: (json['line_end'] as num?)?.toInt() ?? 1,
        fingerprint: json['fingerprint']?.toString(),
        editRevision: json['edit_revision']?.toString(),
        text: json['text']?.toString() ?? '',
        cardsCreated: (json['cards_created'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const [],
        breadcrumb: (json['breadcrumb'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(ReadingSourceCrumb.fromJson)
                .toList() ??
            const [],
      );
}

class ReadingCreatedCard {
  const ReadingCreatedCard({
    required this.noteId,
    required this.model,
    required this.kind,
    required this.fields,
    this.tags = const [],
    this.numCards = 1,
  });

  final int noteId;
  final String model;
  final String kind; // 'qa' | 'cloze'
  final Map<String, String> fields;
  final List<String> tags;
  final int numCards;

  factory ReadingCreatedCard.fromJson(Map<String, dynamic> json) {
    final fields = <String, String>{};
    if (json['fields'] is Map) {
      (json['fields'] as Map).forEach((k, v) {
        fields[k.toString()] = v?.toString() ?? '';
      });
    }
    return ReadingCreatedCard(
      noteId: (json['noteId'] as num).toInt(),
      model: json['model']?.toString() ?? '',
      kind: json['kind']?.toString() ?? 'qa',
      fields: fields,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      numCards: (json['numCards'] as num?)?.toInt() ?? 1,
    );
  }
}

class NoteDetail {
  const NoteDetail({
    required this.cardId,
    required this.noteId,
    required this.modelName,
    required this.fields,
    required this.tags,
    this.kind,
    this.ord,
  });

  final int cardId;
  final int noteId;
  final String modelName;
  final Map<String, String> fields;
  final List<String> tags;
  final String? kind;
  final int? ord;

  factory NoteDetail.fromJson(Map<String, dynamic> json) {
    final fields = <String, String>{};
    if (json['fields'] is Map) {
      (json['fields'] as Map).forEach((k, v) {
        fields[k.toString()] = v?.toString() ?? '';
      });
    }
    return NoteDetail(
      cardId: (json['cardId'] as num).toInt(),
      noteId: (json['noteId'] as num).toInt(),
      modelName: json['modelName']?.toString() ?? '',
      fields: fields,
      tags: (json['tags'] as List?)?.map((e) => e.toString()).toList() ??
          const [],
      kind: json['kind']?.toString(),
      ord: (json['ord'] as num?)?.toInt(),
    );
  }
}

class AiAnnotation {
  const AiAnnotation({
    required this.id,
    required this.noteId,
    this.layerName = 'default',
    required this.quoteExact,
    this.quotePrefix = '',
    this.quoteSuffix = '',
    this.comment = '',
    this.lineHint = 0,
    this.status = 'active',
  });

  final String id;
  final String noteId;
  final String layerName;
  final String quoteExact;
  final String quotePrefix;
  final String quoteSuffix;
  final String comment;
  final int lineHint;
  final String status;

  factory AiAnnotation.fromJson(Map<String, dynamic> json) => AiAnnotation(
        id: json['id']?.toString() ?? '',
        noteId: json['note_id']?.toString() ?? '',
        layerName: json['layer_name']?.toString() ?? 'default',
        quoteExact: json['quote_exact']?.toString() ?? '',
        quotePrefix: json['quote_prefix']?.toString() ?? '',
        quoteSuffix: json['quote_suffix']?.toString() ?? '',
        comment: json['comment']?.toString() ?? '',
        lineHint: (json['line_hint'] as num?)?.toInt() ?? 0,
        status: json['status']?.toString() ?? 'active',
      );
}

class ReadingFrontier {
  const ReadingFrontier({
    required this.chunkKey,
    required this.status,
    required this.title,
    this.lineStart,
    this.lineEnd,
    this.preview,
  });

  final String chunkKey;
  final String status;
  final String title;
  final int? lineStart;
  final int? lineEnd;
  final String? preview;

  factory ReadingFrontier.fromJson(Map<String, dynamic> json) =>
      ReadingFrontier(
        chunkKey: json['chunk_key']?.toString() ?? '',
        status: json['status']?.toString() ?? 'todo',
        title: json['title']?.toString() ?? '',
        lineStart: (json['line_start'] as num?)?.toInt(),
        lineEnd: (json['line_end'] as num?)?.toInt(),
        preview: json['preview']?.toString(),
      );
}

class ReadingFileSummary {
  const ReadingFileSummary({
    this.kind = 'markdown',
    required this.path,
    required this.title,
    this.missing = false,
    this.needsResync = false,
    this.totalChunks = 0,
    this.todo = 0,
    this.active = 0,
    this.done = 0,
    this.skipped = 0,
    this.totalChars = 0,
    this.readChars = 0,
    this.activeChars = 0,
    this.frontier,
    this.gated = 0,
    this.gatedFrontier,
    this.cardsCreated = 0,
  });

  final String kind;
  final String path;
  final String title;
  final bool missing;
  final bool needsResync;
  final int totalChunks;
  final int todo;
  final int active;
  final int done;
  final int skipped;
  final int totalChars;
  final int readChars;
  final int activeChars;
  final ReadingFrontier? frontier;
  final int gated;
  final ReadingFrontier? gatedFrontier;
  final int cardsCreated;

  double get progressRatio {
    if (totalChars > 0) return (readChars / totalChars).clamp(0.0, 1.0);
    if (totalChunks > 0) return ((done + skipped) / totalChunks).clamp(0.0, 1.0);
    return 0.0;
  }

  bool get isComplete => todo == 0 && active == 0 && gated == 0 && totalChunks > 0;

  factory ReadingFileSummary.fromJson(Map<String, dynamic> json) =>
      ReadingFileSummary(
        kind: json['kind']?.toString() ?? 'markdown',
        path: json['path']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        missing: json['missing'] == true,
        needsResync: json['needs_resync'] == true,
        totalChunks: (json['total_chunks'] as num?)?.toInt() ?? 0,
        todo: (json['todo'] as num?)?.toInt() ?? 0,
        active: (json['active'] as num?)?.toInt() ?? 0,
        done: (json['done'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        totalChars: (json['total_chars'] as num?)?.toInt() ?? 0,
        readChars: (json['read_chars'] as num?)?.toInt() ?? 0,
        activeChars: (json['active_chars'] as num?)?.toInt() ?? 0,
        frontier: json['frontier'] is Map<String, dynamic>
            ? ReadingFrontier.fromJson(json['frontier'] as Map<String, dynamic>)
            : null,
        gated: (json['gated'] as num?)?.toInt() ?? 0,
        gatedFrontier: json['gated_frontier'] is Map<String, dynamic>
            ? ReadingFrontier.fromJson(
                json['gated_frontier'] as Map<String, dynamic>)
            : null,
        cardsCreated: (json['cards_created'] as num?)?.toInt() ?? 0,
      );
}

class FileListItem {
  const FileListItem({
    required this.path,
    required this.title,
    this.revision,
  });

  final String path;
  final String title;
  final String? revision;

  String get directory {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? '' : path.substring(0, idx);
  }

  String get fileName {
    final idx = path.lastIndexOf('/');
    return idx < 0 ? path : path.substring(idx + 1);
  }

  factory FileListItem.fromJson(Map<String, dynamic> json) => FileListItem(
        path: json['path']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        revision: json['revision']?.toString(),
      );
}

class StorageSearchResult {
  const StorageSearchResult({
    required this.id,
    required this.title,
    this.legacyPath,
    this.inList = false,
    this.snippet = '',
  });

  final String id;
  final String title;
  final String? legacyPath;
  final bool inList;
  final String snippet;

  factory StorageSearchResult.fromJson(Map<String, dynamic> json) =>
      StorageSearchResult(
        id: json['id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        legacyPath: json['legacy_path']?.toString(),
        inList: json['in_list'] == true,
        snippet: json['snippet']?.toString() ?? '',
      );
}

class TrashItem {
  const TrashItem({
    required this.kind, // 'note' | 'notebook'
    required this.id,
    required this.title,
    this.legacyPath,
    this.deletedAt,
  });

  final String kind;
  final String id;
  final String title;
  final String? legacyPath;
  final String? deletedAt;

  factory TrashItem.fromJson(String kind, Map<String, dynamic> json) =>
      TrashItem(
        kind: kind,
        id: json['id']?.toString() ?? '',
        title: (json['title'] ?? json['name'] ?? '').toString(),
        legacyPath: json['legacy_path']?.toString(),
        deletedAt: json['deleted_at']?.toString(),
      );
}

class NoteRevisionMeta {
  const NoteRevisionMeta({
    required this.id,
    required this.noteId,
    required this.title,
    required this.reason,
    required this.createdAt,
    required this.byteLength,
  });

  final int id;
  final String noteId;
  final String title;
  final String reason;
  final String createdAt;
  final int byteLength;

  factory NoteRevisionMeta.fromJson(Map<String, dynamic> json) =>
      NoteRevisionMeta(
        id: (json['id'] as num).toInt(),
        noteId: json['note_id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        reason: json['reason']?.toString() ?? '',
        createdAt: json['created_at']?.toString() ?? '',
        byteLength: (json['byte_length'] as num?)?.toInt() ?? 0,
      );
}

class EngineStatus {
  const EngineStatus({
    this.backend,
    this.syncDeferred = false,
    this.undoAvailable = false,
    this.lastSyncSuccess,
    this.lastSyncAttempt,
    this.syncStage,
    this.localChangesPending = false,
    this.lastSyncError,
  });

  final String? backend;
  final bool syncDeferred;
  final bool undoAvailable;
  final String? lastSyncSuccess;
  final String? lastSyncAttempt;
  final String? syncStage;
  final bool localChangesPending;
  final String? lastSyncError;

  factory EngineStatus.fromJson(Map<String, dynamic> json) => EngineStatus(
        backend: json['backend']?.toString(),
        syncDeferred: json['sync_deferred'] == true,
        undoAvailable: json['undo_available'] == true,
        lastSyncSuccess: json['last_sync_success']?.toString(),
        lastSyncAttempt: json['last_sync_attempt']?.toString(),
        syncStage: json['sync_stage']?.toString(),
        localChangesPending: json['local_changes_pending'] == true,
        lastSyncError: json['last_sync_error']?.toString(),
      );
}

class ReadingSplitResponse {
  const ReadingSplitResponse({
    required this.ok,
    required this.parentSegId,
    required this.childChunks,
  });

  final bool ok;
  final int parentSegId;
  final List<ReadingChunk> childChunks;

  factory ReadingSplitResponse.fromJson(Map<String, dynamic> json) =>
      ReadingSplitResponse(
        ok: json['ok'] == true,
        parentSegId: (json['parent_seg_id'] as num?)?.toInt() ?? 0,
        childChunks: (json['child_chunks'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(ReadingChunk.fromJson)
                .toList() ??
            const [],
      );
}

class ReadingEditResponse {
  const ReadingEditResponse({
    required this.ok,
    required this.delta,
    required this.lineStart,
    required this.lineEnd,
    required this.fileSha,
    this.chunk,
  });

  final bool ok;
  final int delta;
  final int lineStart;
  final int lineEnd;
  final String fileSha;
  final ReadingChunk? chunk;

  factory ReadingEditResponse.fromJson(Map<String, dynamic> json) =>
      ReadingEditResponse(
        ok: json['ok'] == true,
        delta: (json['delta'] as num?)?.toInt() ?? 0,
        lineStart: (json['line_start'] as num?)?.toInt() ?? 1,
        lineEnd: (json['line_end'] as num?)?.toInt() ?? 1,
        fileSha: json['file_sha']?.toString() ?? '',
        chunk: json['chunk'] is Map<String, dynamic>
            ? ReadingChunk.fromJson(json['chunk'] as Map<String, dynamic>)
            : null,
      );
}

class InteropImportSummary {
  const InteropImportSummary({
    this.notesImported = 0,
    this.notesWritten = 0,
    this.notesOverwritten = 0,
    this.notesRenamed = 0,
    this.notesSkipped = 0,
    this.resourcesImported = 0,
    this.resourcesNew = 0,
    this.resourcesReused = 0,
    this.skipped = 0,
    this.warnings = 0,
  });

  final int notesImported;
  final int notesWritten;
  final int notesOverwritten;
  final int notesRenamed;
  final int notesSkipped;
  final int resourcesImported;
  final int resourcesNew;
  final int resourcesReused;
  final int skipped;
  final int warnings;

  factory InteropImportSummary.fromJson(Map<String, dynamic> json) =>
      InteropImportSummary(
        notesImported: (json['notes_imported'] as num?)?.toInt() ?? 0,
        notesWritten: (json['notes_written'] as num?)?.toInt() ?? 0,
        notesOverwritten: (json['notes_overwritten'] as num?)?.toInt() ?? 0,
        notesRenamed: (json['notes_renamed'] as num?)?.toInt() ?? 0,
        notesSkipped: (json['notes_skipped'] as num?)?.toInt() ?? 0,
        resourcesImported: (json['resources_imported'] as num?)?.toInt() ?? 0,
        resourcesNew: (json['resources_new'] as num?)?.toInt() ?? 0,
        resourcesReused: (json['resources_reused'] as num?)?.toInt() ?? 0,
        skipped: (json['skipped'] as num?)?.toInt() ?? 0,
        warnings: (json['warnings'] as num?)?.toInt() ?? 0,
      );
}

class FilesUploadResponse {
  const FilesUploadResponse({
    required this.ok,
    this.savedPaths = const [],
    this.warnings = const [],
    this.summary,
  });

  final bool ok;
  final List<String> savedPaths;
  final List<String> warnings;
  final InteropImportSummary? summary;

  factory FilesUploadResponse.fromJson(Map<String, dynamic> json) {
    final saved = (json['saved'] as List?)
            ?.whereType<Map<String, dynamic>>()
            .map((e) => e['path']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList() ??
        const [];
    final warnings = (json['warnings'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const [];
    return FilesUploadResponse(
      ok: json['ok'] == true,
      savedPaths: saved,
      warnings: warnings,
      summary: json['summary'] is Map<String, dynamic>
          ? InteropImportSummary.fromJson(
              json['summary'] as Map<String, dynamic>)
          : null,
    );
  }
}
