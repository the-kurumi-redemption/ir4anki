#!/usr/bin/env python3
"""Comprehensive test suite for Stand-off AI Highlight & Comment Layer and 4-Tier Edit-Drift Resilience.

Covers:
1. Tier 1 (Exact match + context disambiguation for repeated phrases)
2. Tier 2 (Skeleton-normalized match: immune to **bold**/*italic* Markdown edits, punctuation, soft breaks)
3. Tier 3 (Context-pinch boundary heal: interior words rewritten while prefix/suffix remain intact)
4. Tier 4 (Fuzzy SequenceMatcher alignment: user fixes typos, inserts/deletes words inside the highlighted sentence)
5. Surrounding text insertions/deletions (adding/removing whole paragraphs before/after)
6. In-app segment editing (`StorageEngine.edit_segment`) auto-healing `quote_exact` in transaction
7. Deletion of highlighted sentence -> cleanly marked `status = 'orphaned'` (never drifts onto unrelated text)
8. Self-healing from `orphaned` -> `active` when user restores/undoes a deleted sentence or rolls back a revision
9. Zero pollution guarantee: `notes.body` and `segments.fingerprint` remain 100% untouched by AI annotations
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "backend"))

from storage import LocalFsDriver, PlatformShim, SQLiteDatabaseDriver, StorageEngine
from storage.domain import locate_quote_anchor, reanchor_annotations


SAMPLE_MEDICAL_NOTE = """# 胃十二指肠疾病

## 一、胃溃疡与十二指肠溃疡鉴别
胃溃疡好发于胃角和胃小弯，疼痛多在餐后半小时至一小时出现。
十二指肠溃疡好发于球部前壁，穿孔多见于前壁，出血多见于后壁。

## 二、胃大部切除术后并发症
1. 术后胃出血：最常见的原因是吻合口出血。
2. 十二指肠残端破裂：是毕II式胃大部切除术后早期最严重的并发症，多发生在术后3～6天。
3. 胃肠吻合口破裂或瘘：多发生在术后5～7天。
4. 倾倒综合征：分为早期倾倒综合征与晚期倾倒综合征（低血糖综合征）。
"""


class AiAnnotationDriftResilienceTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.engine = StorageEngine(
            SQLiteDatabaseDriver(self.root / "data.db"),
            LocalFsDriver(self.root / "media"),
            PlatformShim(),
        )
        self.nb = self.engine.create_notebook("外科学")
        self.note = self.engine.create_note(
            "胃十二指肠疾病",
            SAMPLE_MEDICAL_NOTE,
            notebook_id=self.nb["id"],
            in_list=True,
        )
        self.note_id = self.note["id"]

    def tearDown(self) -> None:
        self.engine.close()
        self.tmp.cleanup()

    def test_zero_source_pollution_and_batch_anchoring(self) -> None:
        orig_note = self.engine.get_note(self.note_id, include_segments=True)
        orig_body = orig_note["body"]
        orig_sha = orig_note["body_sha"]
        orig_fp = orig_note["segments"][0]["fingerprint"]

        res = self.engine.add_annotations_batch(
            self.note_id,
            [
                {
                    "quote": "十二指肠溃疡好发于球部前壁，穿孔多见于前壁，出血多见于后壁。",
                    "comment": "学长重点：前穿孔、后出血（背侧有胃十二指肠动脉），必考单选！",
                },
                {
                    # Agent slightly misquoted punctuation/formatting (used ASCII colon and bold)
                    "quote": "**十二指肠残端破裂**: 是毕II式胃大部切除术后早期最严重的并发症",
                    "comment": "21级、23级名解+单选连考！注意是『早期最严重』。",
                },
            ],
            layer_name="22级学长总结",
        )
        self.assertEqual(res["saved_count"], 2)
        self.assertEqual(res["unmatched_count"], 0)
        # Second quote should be automatically healed to exact substring in note body
        self.assertEqual(
            res["saved"][1]["quote_exact"],
            "十二指肠残端破裂：是毕II式胃大部切除术后早期最严重的并发症",
        )

        after_note = self.engine.get_note(self.note_id, include_segments=True)
        self.assertEqual(after_note["body"], orig_body)
        self.assertEqual(after_note["body_sha"], orig_sha)
        self.assertEqual(after_note["segments"][0]["fingerprint"], orig_fp)

    def test_context_disambiguation_on_repeated_phrases(self) -> None:
        repeated_doc = (
            "第一段讨论正中神经：损伤后表现为拇指对掌功能障碍，常见于腕管综合征。\n\n"
            "第二段讨论尺神经：损伤后表现为爪形手，但有时也需鉴别拇指对掌功能障碍与其他肌群代偿。\n"
        )
        # Anchor specifically the second occurrence using prefix/suffix or line_hint
        hit1 = locate_quote_anchor(repeated_doc, "拇指对掌功能障碍", line_hint=1)
        hit2 = locate_quote_anchor(
            repeated_doc,
            "拇指对掌功能障碍",
            quote_prefix="损伤后表现为爪形手，但有时也需鉴别",
            line_hint=3,
        )
        self.assertIsNotNone(hit1)
        self.assertIsNotNone(hit2)
        self.assertEqual(hit1["line_hint"], 1)
        self.assertEqual(hit2["line_hint"], 3)
        self.assertNotEqual(hit1["start_char"], hit2["start_char"])

    def test_survives_heavy_surrounding_edits_and_markdown_formatting_changes(self) -> None:
        self.engine.add_annotations_batch(
            self.note_id,
            [
                {
                    "quote": "十二指肠残端破裂：是毕II式胃大部切除术后早期最严重的并发症，多发生在术后3～6天。",
                    "comment": "必考并发症时间窗与处理原则",
                }
            ],
        )

        # User inserts 3 new paragraphs at the top, adds **bold** and *italic* inside the highlighted sentence,
        # and changes full-width colon to ASCII colon.
        edited_body = (
            "# 胃十二指肠疾病（期末复习个人补充版）\n\n"
            "> 个人笔记：这一章老师上课重点讲了毕I式和毕II式的区别，我自己整理了下面的对比表。\n\n"
            "## 二、胃大部切除术后并发症\n"
            "1. 术后胃出血：最常见的原因是吻合口出血。\n"
            "2. **十二指肠残端破裂**: 是 *毕II式* 胃大部切除术后**早期最严重的并发症**，多发生在术后3～6天。\n"
        )
        self.engine.update_note(self.note_id, body=edited_body)
        anns = self.engine.list_annotations(self.note_id, status="active")
        self.assertEqual(len(anns), 1)
        self.assertEqual(
            anns[0]["quote_exact"],
            "**十二指肠残端破裂**: 是 *毕II式* 胃大部切除术后**早期最严重的并发症**，多发生在术后3～6天。",
        )
        self.assertIn(anns[0]["quote_exact"], edited_body)

    def test_survives_typo_fix_and_word_edits_inside_highlighted_sentence(self) -> None:
        self.engine.add_annotations_batch(
            self.note_id,
            [
                {
                    "quote": "十二指肠溃疡好发于球部前壁，穿孔多见于前壁，出血多见于后壁。",
                    "comment": "前穿孔后出血",
                },
                {
                    "quote": "倾倒综合征：分为早期倾倒综合征与晚期倾倒综合征（低血糖综合征）。",
                    "comment": "注意晚期是反应性低血糖",
                },
            ],
        )

        # User edits the segment via edit_segment (like SegEditDialog):
        # Modifies words inside both highlighted sentences!
        edited_seg_text = SAMPLE_MEDICAL_NOTE.replace(
            "十二指肠溃疡好发于球部前壁，穿孔多见于前壁，出血多见于后壁。",
            "十二指肠溃疡95%好发于十二指肠球部前壁，急性穿孔多见于前壁，大出血多见于后壁。",
        ).replace(
            "倾倒综合征：分为早期倾倒综合征与晚期倾倒综合征（低血糖综合征）。",
            "倾倒综合征：临床上分为早期倾倒综合征和晚期倾倒综合征（又称反应性低血糖综合征）。",
        )

        seg = self.engine.get_note_segments(self.note_id)[0]
        self.engine.edit_segment(
            self.note_id,
            seg["seg_id"],
            edited_seg_text,
            expected_body_sha=self.note["body_sha"],
            expected_fingerprint=seg["fingerprint"],
        )

        anns = self.engine.list_annotations(self.note_id, status="active")
        self.assertEqual(len(anns), 2)
        self.assertEqual(
            anns[0]["quote_exact"],
            "十二指肠溃疡95%好发于十二指肠球部前壁，急性穿孔多见于前壁，大出血多见于后壁。",
        )
        self.assertEqual(
            anns[1]["quote_exact"],
            "倾倒综合征：临床上分为早期倾倒综合征和晚期倾倒综合征（又称反应性低血糖综合征）。",
        )

    def test_deleted_sentence_becomes_orphaned_and_self_heals_on_restore(self) -> None:
        self.engine.add_annotations_batch(
            self.note_id,
            [
                {
                    "quote": "十二指肠残端破裂：是毕II式胃大部切除术后早期最严重的并发症，多发生在术后3～6天。",
                    "comment": "早期最严重",
                },
                {
                    "quote": "胃肠吻合口破裂或瘘：多发生在术后5～7天。",
                    "comment": "术后5-7天",
                },
            ],
        )

        # User completely deletes the second highlighted sentence
        body_without_second = SAMPLE_MEDICAL_NOTE.replace(
            "3. 胃肠吻合口破裂或瘘：多发生在术后5～7天。\n", ""
        )
        self.engine.update_note(self.note_id, body=body_without_second)

        active_anns = self.engine.list_annotations(self.note_id, status="active")
        orphaned_anns = self.engine.list_annotations(self.note_id, status="orphaned")
        self.assertEqual(len(active_anns), 1)
        self.assertEqual(len(orphaned_anns), 1)
        self.assertIn("十二指肠残端破裂", active_anns[0]["quote_exact"])
        self.assertIn("胃肠吻合口破裂或瘘", orphaned_anns[0]["quote_exact"])

        # Now user restores the deleted sentence (or rolls back revision) -> orphaned annotation self-heals!
        self.engine.update_note(self.note_id, body=SAMPLE_MEDICAL_NOTE)
        active_after = self.engine.list_annotations(self.note_id, status="active")
        orphaned_after = self.engine.list_annotations(self.note_id, status="orphaned")
        self.assertEqual(len(active_after), 2)
        self.assertEqual(len(orphaned_after), 0)


if __name__ == "__main__":
    unittest.main()
