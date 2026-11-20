import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ir4anki_desktop/models/ir4anki_models.dart';
import 'package:ir4anki_desktop/services/ai_layer_engine.dart';
import 'package:ir4anki_desktop/services/api_client.dart';
import 'package:ir4anki_desktop/services/cloze_engine.dart';
import 'package:ir4anki_desktop/services/line_split_engine.dart';
import 'package:ir4anki_desktop/theme/m3e_motion.dart';
import 'package:ir4anki_desktop/theme/m3e_theme.dart';
import 'package:ir4anki_desktop/widgets/m3e/m3e_button.dart';
import 'package:ir4anki_desktop/widgets/m3e/m3e_indicators.dart';

void main() {
  group('ClozeEngine', () {
    test('parses brace-balanced TeX inside cloze markers', () {
      const src = r'公式 {{c1::\frac{a}{b} = c::分式}} 与 {{c2::能量}}';
      final ranges = parseClozeRanges(src);
      expect(ranges.length, 2);
      expect(ranges[0].ordinal, 1);
      expect(ranges[0].content, r'\frac{a}{b} = c');
      expect(ranges[0].hint, '分式');
      expect(ranges[1].ordinal, 2);
      expect(ranges[1].content, '能量');
    });

    test('wraps selection and swallows adjacent balanced emphasis markers', () {
      const raw = '**髂嵴最高点** = 髂结节，平对 L4 棘突';
      final wrapped = wrapSelectionAsCloze(raw, '髂嵴最高点 = 髂结节');
      expect(wrapped, '{{c1::**髂嵴最高点** = 髂结节}}，平对 L4 棘突');
    });

    test('transforms question vs answer with sentinels', () {
      const raw = '心脏起搏点是 {{c1::窦房结::解剖结构}}';
      final q = transformClozeMarkdown(raw, showAnswer: false, activeOrdinal: 1);
      final a = transformClozeMarkdown(raw, showAnswer: true, activeOrdinal: 1);
      expect(q, '心脏起搏点是 $kClozeOpenSentinel[解剖结构]$kClozeCloseSentinel');
      expect(a, '心脏起搏点是 $kClozeOpenSentinel窦房结$kClozeCloseSentinel');
    });
  });

  group('AiLayerEngine', () {
    test('resolves Tier 1 exact & Tier 2 skeleton matches with numbered badges', () {
      const text = '第一句：主动脉瓣关闭不全表现为水冲脉。第二句：脉压增大。';
      final anns = [
        const AiAnnotation(
          id: 'a1',
          noteId: 'n1',
          quoteExact: '**主动脉瓣关闭不全**表现为水冲脉',
          comment: '高频考点：周围血管征',
        ),
        const AiAnnotation(
          id: 'a2',
          noteId: 'n1',
          quoteExact: '脉压增大',
          comment: '舒张压降低导致',
        ),
      ];
      final hits = AiLayerEngine.resolveHighlights(text, anns);
      expect(hits.length, 2);
      expect(hits[0].badge, '①');
      expect(hits[1].badge, '②');
      expect(text.substring(hits[0].start, hits[0].end), '主动脉瓣关闭不全表现为水冲脉');
    });
  });

  group('LineSplitEngine', () {
    test('moves nearest endpoint and cancels when clicking inside range', () {
      var sel = LineSplitSelection.togglePick(null, 4, 4);
      expect(sel?.startLine, 4);
      expect(sel?.endLine, 4);

      sel = LineSplitSelection.togglePick(sel, 5, 5);
      expect(sel?.startLine, 4);
      expect(sel?.endLine, 5);

      sel = LineSplitSelection.togglePick(sel, 3, 3);
      expect(sel?.startLine, 3);
      expect(sel?.endLine, 5);

      // Clicking inside [3..5] cancels selection
      sel = LineSplitSelection.togglePick(sel, 4, 4);
      expect(sel, isNull);
    });

    test('preserves atomic blocks (code fence & display math) line spans', () {
      const md = '# 标题\n\n```python\nprint(1)\n```\n\n正文行';
      final blocks = splitMarkdownIntoLineBlocks(md);
      expect(blocks.length, 3);
      expect(blocks[0].startLine, 1);
      expect(blocks[1].isAtomic, isTrue);
      expect(blocks[1].startLine, 3);
      expect(blocks[1].endLine, 5);
      expect(blocks[2].startLine, 7);
    });
  });

  group('IR4AnkiApiClient', () {
    test('resolves Storage v2 :/resource_id, reading media, and Anki media URLs', () {
      final api = IR4AnkiApiClient(baseUrl: 'http://127.0.0.1:8901/');
      expect(api.isLoopbackHost, isTrue);
      expect(api.origin, 'http://127.0.0.1:8901');
      expect(
        api.resolveImageUrl(':/abc123'),
        'http://127.0.0.1:8901/api/resources/abc123',
      );
      expect(
        api.resolveImageUrl('diagram.png', isAnkiCard: false),
        'http://127.0.0.1:8901/api/reading/media/diagram.png',
      );
      expect(
        api.resolveImageUrl('card.png', isAnkiCard: true),
        'http://127.0.0.1:8901/media/card.png',
      );
      expect(
        api.resolveImageUrl('https://example.com/a.png'),
        'https://example.com/a.png',
      );
    });
  });

  testWidgets('M3E widgets render cleanly under vibrant expressive theme',
      (WidgetTester tester) async {
    int tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildM3ETheme(
          brightness: Brightness.light,
          palette: M3EPalettePreset.expressiveViolet,
          motionScheme: M3EMotionScheme.expressive,
        ),
        home: Scaffold(
          body: Column(
            children: [
              M3EButton(
                label: 'Good',
                sublabel: '4d',
                keycap: '3',
                onPressed: () => tapped++,
              ),
              const M3EWavyProgressIndicator(value: 0.65, animateWave: false),
              const M3EProgressRing(
                done: 5,
                total: 10,
                label: '阅读',
                color: Colors.teal,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Good'), findsOneWidget);
    expect(find.text('4d'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    await tester.tap(find.text('Good'));
    expect(tapped, 1);
  });
}
