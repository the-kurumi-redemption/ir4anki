"""Pure domain functions for progressive reading segments, line re-anchoring,
bookmark splitting, and in-note segment editing.

Zero OS or database calls: operates purely on strings, lines, and segment dicts.
Designed for 100% portability across desktop/server and mobile runtimes.
"""
from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Any

HEADING_RE = re.compile(r"^(#{1,6})\s+(.+?)\s*$")
RESOURCE_LINK_RE = re.compile(r":/([a-fA-F0-9]{16,64})")

MIN_READING_BODY = 10


def normalize_newlines(text: str) -> str:
    """Normalize CRLF / CR line endings to LF."""
    return (text or "").replace("\r\n", "\n").replace("\r", "\n")


def reading_worthwhile(text: str) -> bool:
    """Return True if text has at least MIN_READING_BODY non-heading characters."""
    body = re.sub(r"^#{1,6}\s+.*$", "", text or "", flags=re.M).strip()
    return len(body) >= MIN_READING_BODY


def infer_note_title(lines: list[str], fallback: str = "未命名笔记") -> str:
    """Extract the first Markdown heading as display title, else fallback."""
    for line in lines:
        m = HEADING_RE.match(line)
        if m:
            return m.group(2).strip()
    stem = Path(fallback).stem if fallback else ""
    return stem or fallback or "未命名笔记"


def seg_fingerprint(lines: list[str], start: int, end: int) -> str:
    """Compute 32-char SHA-256 hex digest of the 1-based inclusive line window."""
    if not lines or start < 1 or end < start:
        return ""
    window = "\n".join(lines[start - 1 : min(end, len(lines))])
    return hashlib.sha256(window.encode("utf-8")).hexdigest()[:32]


def seed_whole_note(
    text: str,
    title_fallback: str = "未命名笔记",
    *,
    start_id: int = 1,
    now_iso: str = "",
) -> list[dict[str, Any]]:
    """Seed a whole note as a single root segment covering lines 1..N."""
    norm = normalize_newlines(text)
    if not reading_worthwhile(norm):
        return []
    lines = norm.split("\n")
    return [
        {
            "seg_id": start_id,
            "start_line": 1,
            "end_line": len(lines),
            "fingerprint": seg_fingerprint(lines, 1, len(lines)),
            "first_line": lines[0] if lines else "",
            "title": infer_note_title(lines, title_fallback),
            "heading_path": [],
            "status": "todo",
            "parent_seg_id": None,
            "stale": False,
            "cards_created": [],
            "updated_at": now_iso,
        }
    ]


def next_seg_id(segments: list[dict[str, Any]], orphans: list[dict[str, Any]] | None = None) -> int:
    """Return next monotonic per-note segment ID (never reuses retired/orphaned IDs)."""
    ids = [int(s.get("seg_id") or 0) for s in (segments or [])]
    for o in orphans or []:
        sid = (o or {}).get("seg_id")
        if isinstance(sid, int):
            ids.append(sid)
    return (max(ids) + 1) if ids else 1


def relocate_span(
    lines: list[str], fp: str, first_line: str, span: int, hint_start: int
) -> int | None:
    """Locate 1-based start_line for a segment with exact fingerprint `fp`."""
    n = len(lines)
    if not fp or span < 1 or n < span:
        return None
    tried: set[int] = set()

    def _hit(st: int) -> bool:
        return st + span - 1 <= n and seg_fingerprint(lines, st, st + span - 1) == fp

    if 1 <= hint_start <= n - span + 1:
        tried.add(hint_start)
        if _hit(hint_start):
            return hint_start
    if first_line:
        for i, line in enumerate(lines[:5000]):
            if line == first_line and (i + 1) not in tried:
                tried.add(i + 1)
                if _hit(i + 1):
                    return i + 1
    for st in range(1, n - span + 2):
        if st in tried:
            continue
        if _hit(st):
            return st
    return None


def reanchor_segments(
    segments: list[dict[str, Any]],
    orphans: list[dict[str, Any]],
    lines: list[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], bool]:
    """Re-anchor segments against updated `lines` after a full-note edit.

    Returns (kept_segments, updated_orphans, damaged_needs_resync).
    """
    n = len(lines)
    segs = [dict(s, cards_created=list(s.get("cards_created") or [])) for s in (segments or [])]
    out_orphans = [dict(o) for o in (orphans or [])]
    damaged = False

    # Pass 1: leaf segments
    for s in segs:
        if s.get("status") == "container":
            continue
        span = int(s["end_line"]) - int(s["start_line"]) + 1
        st = relocate_span(
            lines,
            s.get("fingerprint", ""),
            s.get("first_line", ""),
            span,
            int(s["start_line"]),
        )
        if st is None:
            s["_lost"] = True
            damaged = True
        else:
            s["start_line"] = st
            s["end_line"] = st + span - 1
            s["first_line"] = lines[st - 1] if st - 1 < n else ""

    # Pass 2: containers (own fingerprint, else union of surviving children)
    for s in segs:
        if s.get("status") != "container":
            continue
        span = int(s["end_line"]) - int(s["start_line"]) + 1
        st = relocate_span(
            lines,
            s.get("fingerprint", ""),
            s.get("first_line", ""),
            span,
            int(s["start_line"]),
        )
        if st is not None:
            s["start_line"] = st
            s["end_line"] = st + span - 1
            s["first_line"] = lines[st - 1] if st - 1 < n else ""
            continue
        kids = [
            c
            for c in segs
            if c.get("parent_seg_id") == s["seg_id"] and not c.get("_lost")
        ]
        if kids:
            s["start_line"] = min(int(k["start_line"]) for k in kids)
            s["end_line"] = max(int(k["end_line"]) for k in kids)
            s["fingerprint"] = seg_fingerprint(lines, s["start_line"], s["end_line"])
            s["first_line"] = lines[s["start_line"] - 1] if n else ""
        else:
            s["_lost"] = True
            damaged = True

    kept: list[dict[str, Any]] = []
    for s in segs:
        if not s.pop("_lost", False):
            kept.append(s)
            continue
        if s.get("cards_created"):
            s["status"] = "container"
            s["start_line"] = max(1, min(int(s["start_line"]), n or 1))
            s["end_line"] = max(s["start_line"], min(int(s["end_line"]), n or 1))
            s["fingerprint"] = seg_fingerprint(lines, s["start_line"], s["end_line"])
            s["first_line"] = lines[s["start_line"] - 1] if n else ""
            s["stale"] = True
            kept.append(s)
        else:
            payload = {k: v for k, v in s.items()}
            out_orphans.append({"chunk_key": f"seg:{payload.get('seg_id')}", **payload})

    return kept, out_orphans, damaged


def reseed_segments(
    segments: list[dict[str, Any]],
    orphans: list[dict[str, Any]],
    lines: list[str],
    title_fallback: str,
    *,
    now_iso: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], int]:
    """Clear needs_resync by relocating surviving segments/orphans and seeding uncovered runs.

    Returns (new_segments, remaining_orphans, fresh_count).
    """
    n = len(lines)
    surviving: list[dict[str, Any]] = []
    for raw_s in segments or []:
        s = dict(raw_s, cards_created=list(raw_s.get("cards_created") or []))
        span = int(s["end_line"]) - int(s["start_line"]) + 1
        st = relocate_span(
            lines,
            s.get("fingerprint", ""),
            s.get("first_line", ""),
            span,
            int(s["start_line"]),
        )
        if s.get("status") == "container":
            if st is not None:
                s["start_line"] = st
                s["end_line"] = st + span - 1
                s["first_line"] = lines[st - 1] if st - 1 < n else ""
            else:
                s["stale"] = True
            surviving.append(s)
        elif st is not None:
            s["start_line"] = st
            s["end_line"] = st + span - 1
            s["first_line"] = lines[st - 1] if st - 1 < n else ""
            surviving.append(s)
        elif s.get("cards_created"):
            s["status"] = "container"
            s["stale"] = True
            surviving.append(s)

    kept_orphans: list[dict[str, Any]] = []
    for raw_o in orphans or []:
        o = dict(raw_o)
        sid = o.get("seg_id")
        if isinstance(sid, int) and o.get("fingerprint"):
            span = int(o["end_line"]) - int(o["start_line"]) + 1
            st = relocate_span(
                lines,
                o.get("fingerprint", ""),
                o.get("first_line", ""),
                span,
                int(o.get("start_line", 1)),
            )
            if st is not None:
                restored = {k: v for k, v in o.items() if k != "chunk_key"}
                restored["start_line"] = st
                restored["end_line"] = st + span - 1
                restored["first_line"] = lines[st - 1] if st - 1 < n else ""
                status = restored.get("status", "todo")
                if status not in ("todo", "active", "done", "skipped", "background", "container"):
                    status = "todo"
                restored["status"] = status
                restored.setdefault("cards_created", [])
                surviving.append(restored)
                continue
        kept_orphans.append(o)

    covered: set[int] = set()
    for s in surviving:
        if s.get("status") != "container":
            covered.update(range(int(s["start_line"]), int(s["end_line"]) + 1))

    nid = next_seg_id(surviving, kept_orphans)
    fresh: list[dict[str, Any]] = []
    line_no = 1
    while line_no <= n:
        if line_no in covered:
            line_no += 1
            continue
        run_start = line_no
        while line_no <= n and line_no not in covered:
            line_no += 1
        run_end = line_no - 1
        run_text = "\n".join(lines[run_start - 1 : run_end])
        if not reading_worthwhile(run_text):
            continue
        title = infer_note_title(lines[run_start - 1 : run_end], title_fallback)
        fresh.append(
            {
                "seg_id": nid,
                "start_line": run_start,
                "end_line": run_end,
                "fingerprint": seg_fingerprint(lines, run_start, run_end),
                "first_line": lines[run_start - 1] if run_start - 1 < n else "",
                "title": title,
                "heading_path": [],
                "status": "todo",
                "parent_seg_id": None,
                "stale": False,
                "cards_created": [],
                "updated_at": now_iso,
            }
        )
        nid += 1

    return surviving + fresh, kept_orphans, len(fresh)


def compute_bookmark_split(
    segments: list[dict[str, Any]],
    orphans: list[dict[str, Any]],
    lines: list[str],
    seg_id: int,
    selections: list[dict[str, int]],
    *,
    expected_fingerprint: str | None = None,
    expected_line_start: int | None = None,
    now_iso: str = "",
) -> dict[str, Any]:
    """Perform bookmark split on `seg_id` over `lines`.

    Raises ValueError on validation failure or LookupError if segment not found.
    Returns dict with `updated_segments`, `children`, `tail_seg_id`, `parent_seg_id`.
    """
    segs = [dict(s, cards_created=list(s.get("cards_created") or [])) for s in (segments or [])]
    parent = next((s for s in segs if s.get("seg_id") == seg_id), None)
    if parent is None:
        raise LookupError(f"segment {seg_id} not found")
    if parent.get("status") == "container":
        raise ValueError("segment already split")
    if expected_fingerprint is not None and parent.get("fingerprint", "") != expected_fingerprint:
        raise ValueError("stale: 片段坐标已过期，请刷新后重新选择")
    if expected_line_start is not None and int(parent.get("start_line", 0)) != int(expected_line_start):
        raise ValueError("stale: 片段坐标已过期，请刷新后重新选择")

    p_start, p_end = int(parent["start_line"]), int(parent["end_line"])
    sels: list[tuple[int, int]] = []
    sels_raw = False
    for sel in selections:
        try:
            a = int(sel["start_line"])
            b = int(sel["end_line"])
        except (KeyError, TypeError, ValueError) as exc:
            raise ValueError("selections need int start_line/end_line") from exc
        if a < 1 or b < a or b > len(lines):
            raise ValueError(f"selection out of range: {a}-{b}")
        a = max(a, p_start)
        b = min(b, p_end)
        if a > b:
            continue
        sels_raw = True
        while a <= b and not lines[a - 1].strip():
            a += 1
        while b >= a and not lines[b - 1].strip():
            b -= 1
        if a <= b:
            sels.append((a, b))

    sels.sort()
    merged: list[tuple[int, int]] = []
    for a, b in sels:
        if merged and a <= merged[-1][1] + 1:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))

    if not merged:
        if sels_raw:
            raise ValueError("选区没有实质内容（只有空行）")
        raise ValueError("no valid selection inside the segment")

    sel_text = "\n".join("\n".join(lines[a - 1 : b]) for a, b in merged)
    if not reading_worthwhile(sel_text):
        raise ValueError("选区没有实质内容（太短或只有空行/标题）")

    nid = next_seg_id(segs, orphans)
    children: list[dict[str, Any]] = []

    def _mk(a: int, b: int, status: str) -> None:
        nonlocal nid
        children.append(
            {
                "seg_id": nid,
                "start_line": a,
                "end_line": b,
                "fingerprint": seg_fingerprint(lines, a, b),
                "first_line": lines[a - 1] if a - 1 < len(lines) else "",
                "title": parent.get("title") or "",
                "heading_path": list(parent.get("heading_path") or []),
                "status": status,
                "parent_seg_id": parent["seg_id"],
                "stale": False,
                "cards_created": [],
                "updated_at": now_iso,
            }
        )
        nid += 1

    cursor = p_start
    for a, b in merged:
        if a > cursor:
            _mk(cursor, a - 1, "background")
        _mk(a, b, "todo")
        cursor = b + 1

    tail_seg_id: int | None = None
    if cursor <= p_end:
        tail_text = "\n".join(lines[cursor - 1 : p_end])
        tail_status = "todo" if reading_worthwhile(tail_text) else "background"
        _mk(cursor, p_end, tail_status)
        if tail_status == "todo":
            tail_seg_id = children[-1]["seg_id"]

    if not any(c["status"] == "todo" for c in children if c["seg_id"] != tail_seg_id):
        raise ValueError("selections cover nothing new")

    parent["status"] = "container"
    parent["updated_at"] = now_iso
    segs.extend(children)

    return {
        "parent_seg_id": parent["seg_id"],
        "tail_seg_id": tail_seg_id,
        "children": children,
        "updated_segments": segs,
    }


def apply_segment_edit(
    segments: list[dict[str, Any]],
    orphans: list[dict[str, Any]],
    body_text: str,
    seg_id: int,
    new_seg_text: str,
    *,
    expected_fingerprint: str | None = None,
    now_iso: str = "",
) -> dict[str, Any]:
    """Replace one leaf segment's line range in `body_text` and shift all other segments.

    Returns dict with `new_body`, `delta`, `edited_segment`, `updated_segments`, `updated_orphans`.
    """
    segs = [dict(s, cards_created=list(s.get("cards_created") or [])) for s in (segments or [])]
    out_orphans = [dict(o) for o in (orphans or [])]
    seg = next((s for s in segs if s.get("seg_id") == seg_id), None)
    if seg is None:
        raise LookupError(f"segment {seg_id} not found")
    if seg.get("status") == "container":
        raise ValueError("container segments are read-only")
    if expected_fingerprint is not None and seg.get("fingerprint") != expected_fingerprint:
        raise ValueError("segment fingerprint mismatch")

    norm_new = normalize_newlines(new_seg_text)
    if not norm_new.strip():
        raise ValueError("segment cannot be empty")

    lines = normalize_newlines(body_text).split("\n")
    st = max(1, min(int(seg["start_line"]), len(lines) or 1))
    en = max(st, min(int(seg["end_line"]), len(lines)))
    new_lines = norm_new.split("\n")
    delta = len(new_lines) - (en - st + 1)
    merged = lines[: st - 1] + new_lines + lines[en:]
    n = len(merged)

    seg["start_line"] = st
    seg["end_line"] = st + len(new_lines) - 1
    seg["fingerprint"] = seg_fingerprint(merged, st, seg["end_line"])
    seg["first_line"] = merged[st - 1] if st - 1 < n else ""
    hm = HEADING_RE.match(seg["first_line"])
    if hm:
        new_title = hm.group(2).strip()
        hp = list(seg.get("heading_path") or [])
        if hp and hp[-1] == seg.get("title"):
            hp[-1] = new_title
            seg["heading_path"] = hp
        seg["title"] = new_title
    seg["updated_at"] = now_iso

    for s in segs:
        if s is seg:
            continue
        s_st, s_en = int(s.get("start_line", 1)), int(s.get("end_line", 1))
        if s_st > en:
            s["start_line"] = s_st + delta
            s["end_line"] = max(s_st + delta, s_en + delta)
        elif s_en >= en and s_st <= st:
            s["end_line"] = max(s_st, s_en + delta)
            s["fingerprint"] = seg_fingerprint(merged, s["start_line"], s["end_line"])
            s["first_line"] = merged[s["start_line"] - 1] if n else ""

    for o in out_orphans:
        if isinstance(o, dict) and (o.get("start_line") or 0) > en:
            o["start_line"] = int(o["start_line"]) + delta
            o["end_line"] = int(o.get("end_line", o["start_line"])) + delta

    return {
        "new_body": "\n".join(merged),
        "delta": delta,
        "edited_segment": seg,
        "updated_segments": segs,
        "updated_orphans": out_orphans,
    }


def extract_resource_ids(markdown_body: str) -> list[str]:
    """Extract unique Joplin-style `(:/<resource_id>)` resource IDs referenced in markdown."""
    if not markdown_body:
        return []
    seen: dict[str, None] = {}
    for m in RESOURCE_LINK_RE.finditer(markdown_body):
        seen[m.group(1).lower()] = None
    return list(seen.keys())


# ----------------------------------------------------------------------
# Stand-off AI Highlight & Comment Layer: Multi-tier Drift-Resistant Anchoring
# ----------------------------------------------------------------------

_NORM_SKIP_RE = re.compile(
    r"[\s\*_`~#\>\-\+\|\[\]\(\)!，。、；：？！“”‘’（）【】《》〈〉「」『』—…·,.;:?!\"'\\]+"
)
_CJK_PUNCT_MAP = str.maketrans(
    {
        "，": ",",
        "。": ".",
        "；": ";",
        "：": ":",
        "？": "?",
        "！": "!",
        "（": "(",
        "）": ")",
        "【": "[",
        "】": "]",
        "“": '"',
        "”": '"',
        "‘": "'",
        "’": "'",
    }
)
ANNOTATION_CONTEXT_CHARS = 36


def _char_to_line(text: str, char_idx: int) -> int:
    """Return 1-based line number for `char_idx` in `text`."""
    if not text or char_idx <= 0:
        return 1
    return text.count("\n", 0, min(char_idx, len(text))) + 1


def _line_to_char(text: str, line_no: int) -> int:
    """Return 0-based character index of the start of 1-based `line_no`."""
    if not text or line_no <= 1:
        return 0
    idx = 0
    for _ in range(line_no - 1):
        nxt = text.find("\n", idx)
        if nxt < 0:
            return len(text)
        idx = nxt + 1
    return idx


def _extract_context(text: str, start: int, end: int, width: int = ANNOTATION_CONTEXT_CHARS) -> tuple[str, str]:
    prefix = text[max(0, start - width) : start]
    suffix = text[end : min(len(text), end + width)]
    return prefix, suffix


def _build_skeleton(text: str) -> tuple[str, list[int]]:
    """Strip markdown syntax, whitespace, and punctuation into a skeleton string
    and return `(skeleton, index_map)` where `index_map[i]` is the original index in `text`."""
    skel_chars: list[str] = []
    idx_map: list[int] = []
    for i, ch in enumerate(text):
        if _NORM_SKIP_RE.match(ch):
            continue
        skel_chars.append(ch.lower())
        idx_map.append(i)
    return "".join(skel_chars), idx_map


def _score_context_candidate(
    text: str,
    start: int,
    end: int,
    quote_prefix: str,
    quote_suffix: str,
    line_hint: int | None,
) -> float:
    """Score a candidate span [start, end) by context prefix/suffix similarity and line_hint proximity."""
    from difflib import SequenceMatcher

    score = 0.0
    cand_prefix, cand_suffix = _extract_context(text, start, end)
    if quote_prefix:
        p_norm = quote_prefix.translate(_CJK_PUNCT_MAP).strip()
        cp_norm = cand_prefix.translate(_CJK_PUNCT_MAP).strip()
        if p_norm and cp_norm:
            if cp_norm.endswith(p_norm) or p_norm.endswith(cp_norm):
                score += 2.0
            else:
                score += SequenceMatcher(None, p_norm[-24:], cp_norm[-24:]).ratio() * 1.5
    if quote_suffix:
        s_norm = quote_suffix.translate(_CJK_PUNCT_MAP).strip()
        cs_norm = cand_suffix.translate(_CJK_PUNCT_MAP).strip()
        if s_norm and cs_norm:
            if cs_norm.startswith(s_norm) or s_norm.startswith(cs_norm):
                score += 2.0
            else:
                score += SequenceMatcher(None, s_norm[:24], cs_norm[:24]).ratio() * 1.5
    if line_hint is not None and line_hint > 0:
        cand_line = _char_to_line(text, start)
        dist = abs(cand_line - line_hint)
        score += 0.5 / (1.0 + dist * 0.05)
    return score


_CLOSING_PUNCT = frozenset("。，、；：？！）】》」』.,;:?!)]}\"'”’")


def _expand_clean_markdown_boundaries(
    text: str, start: int, end: int, orig_quote: str = ""
) -> tuple[int, int]:
    """Keep matched span boundaries clean: balance inline Markdown markers (`*`, `_`, `` ` ``)
    and include immediate closing punctuation if `orig_quote` ended with punctuation or brackets."""
    n = len(text)
    start = max(0, min(start, n))
    end = max(start, min(end, n))
    while start < end and text[start] in (" ", "\t", "\n"):
        start += 1
    while end > start and text[end - 1] in (" ", "\t", "\n"):
        end -= 1

    # Balance closing brackets/parens opened inside [start, end)
    inner = text[start:end]
    for open_ch, close_ch in (("（", "）"), ("(", ")"), ("【", "】"), ("[", "]"), ("《", "》"), ("“", "”")):
        if inner.count(open_ch) > inner.count(close_ch) and end < n and text[end] == close_ch:
            end += 1
            inner = text[start:end]

    # If orig_quote ended with sentence punctuation, include immediate trailing punctuation on the same line
    if orig_quote and orig_quote[-1] in _CLOSING_PUNCT:
        while end < n and text[end] in _CLOSING_PUNCT and text[end] == orig_quote[-1]:
            end += 1
            break

    # Balance inline Markdown emphasis/code markers (`**`, `*`, `` ` ``) that wrap the start or end
    for marker in ("**", "__", "*", "_", "`"):
        m_len = len(marker)
        inner = text[start:end]
        if inner.count(marker) % 2 == 1:
            if start >= m_len and text[start - m_len : start] == marker:
                start -= m_len
            elif end + m_len <= n and text[end : end + m_len] == marker:
                end += m_len

    return start, end


def locate_quote_anchor(
    body_text: str,
    quote_exact: str,
    *,
    quote_prefix: str = "",
    quote_suffix: str = "",
    line_hint: int | None = None,
    min_fuzzy_ratio: float = 0.72,
) -> dict[str, Any] | None:
    """Locate `quote_exact` in `body_text` across 4 drift-resistant tiers:

    Tier 1: Exact substring match (disambiguated by `quote_prefix`, `quote_suffix`, and `line_hint`).
    Tier 2: Skeleton-normalized match (immune to whitespace, CJK/ASCII punctuation differences,
            or user adding/removing `**bold**`, `*italic*`, `` `code` ``, or soft line breaks).
    Tier 3: Context-bounded Edit-Heal (if prefix & suffix match around an edited span, heal the interior).
    Tier 4: Fuzzy SequenceMatcher alignment on the skeleton stream (handles user fixing typos,
            inserting/deleting words inside the highlighted sentence itself).

    Returns dict with `start_char`, `end_char`, `line_hint`, `quote_exact`, `quote_prefix`,
    `quote_suffix`, `tier`, `confidence`, or `None` if the quote was deleted/unrecognizable.
    """
    from difflib import SequenceMatcher

    norm_body = normalize_newlines(body_text)
    clean_quote = normalize_newlines(quote_exact).strip()
    if not norm_body or not clean_quote:
        return None

    # --- Tier 1: Exact Substring Match ---
    exact_hits: list[tuple[int, int]] = []
    pos = 0
    q_len = len(clean_quote)
    while True:
        idx = norm_body.find(clean_quote, pos)
        if idx < 0:
            break
        exact_hits.append((idx, idx + q_len))
        pos = idx + 1

    if exact_hits:
        best_start, best_end = max(
            exact_hits,
            key=lambda sp: _score_context_candidate(
                norm_body, sp[0], sp[1], quote_prefix, quote_suffix, line_hint
            ),
        )
        p, s = _extract_context(norm_body, best_start, best_end)
        return {
            "start_char": best_start,
            "end_char": best_end,
            "line_hint": _char_to_line(norm_body, best_start),
            "quote_exact": norm_body[best_start:best_end],
            "quote_prefix": p,
            "quote_suffix": s,
            "tier": "exact",
            "confidence": 1.0,
        }

    # Build skeleton once for Tiers 2 & 4
    body_skel, body_map = _build_skeleton(norm_body)
    quote_skel, _ = _build_skeleton(clean_quote)
    if not body_skel or not quote_skel:
        return None

    # --- Tier 2: Skeleton-Normalized Match (Immune to Markdown formatting / punctuation / whitespace) ---
    skel_hits: list[tuple[int, int]] = []
    pos = 0
    qs_len = len(quote_skel)
    while True:
        idx = body_skel.find(quote_skel, pos)
        if idx < 0:
            break
        orig_start = body_map[idx]
        orig_end = body_map[idx + qs_len - 1] + 1
        orig_start, orig_end = _expand_clean_markdown_boundaries(
            norm_body, orig_start, orig_end, clean_quote
        )
        skel_hits.append((orig_start, orig_end))
        pos = idx + 1

    if skel_hits:
        best_start, best_end = max(
            skel_hits,
            key=lambda sp: _score_context_candidate(
                norm_body, sp[0], sp[1], quote_prefix, quote_suffix, line_hint
            ),
        )
        p, s = _extract_context(norm_body, best_start, best_end)
        return {
            "start_char": best_start,
            "end_char": best_end,
            "line_hint": _char_to_line(norm_body, best_start),
            "quote_exact": norm_body[best_start:best_end],
            "quote_prefix": p,
            "quote_suffix": s,
            "tier": "normalized",
            "confidence": 0.98,
        }

    # --- Tier 3: Context-Pinch Boundary Heal (Surrounding prefix & suffix intact, interior edited) ---
    if quote_prefix and quote_suffix and len(quote_prefix.strip()) >= 6 and len(quote_suffix.strip()) >= 6:
        p_tail = quote_prefix[-16:]
        s_head = quote_suffix[:16]
        p_idx = norm_body.find(p_tail)
        if p_idx >= 0:
            cand_start = p_idx + len(p_tail)
            s_idx = norm_body.find(s_head, cand_start)
            if s_idx > cand_start and (s_idx - cand_start) <= max(len(clean_quote) * 3, 200):
                cand_start, cand_end = _expand_clean_markdown_boundaries(
                    norm_body, cand_start, s_idx, clean_quote
                )
                cand_skel, _ = _build_skeleton(norm_body[cand_start:cand_end])
                if cand_skel:
                    ratio = SequenceMatcher(None, quote_skel, cand_skel).ratio()
                    # Even if interior was moderately rewritten, strong prefix+suffix sandwich + minimum similarity heals it
                    if ratio >= 0.45:
                        p, s = _extract_context(norm_body, cand_start, cand_end)
                        return {
                            "start_char": cand_start,
                            "end_char": cand_end,
                            "line_hint": _char_to_line(norm_body, cand_start),
                            "quote_exact": norm_body[cand_start:cand_end],
                            "quote_prefix": p,
                            "quote_suffix": s,
                            "tier": "context_pinch",
                            "confidence": round(max(0.75, ratio), 3),
                        }

    # --- Tier 4: Fuzzy Sequence Alignment on Skeleton Stream ---
    # Search in a window around line_hint first (if provided), then global fallback
    if len(quote_skel) < 3:
        return None

    search_ranges: list[tuple[int, int]] = []
    if line_hint is not None and line_hint > 0:
        center_char = _line_to_char(norm_body, line_hint)
        # Map center_char to skeleton index
        import bisect

        center_skel = bisect.bisect_left(body_map, center_char)
        win_radius = max(len(quote_skel) * 12, 800)
        w_start = max(0, center_skel - win_radius)
        w_end = min(len(body_skel), center_skel + win_radius)
        search_ranges.append((w_start, w_end))
    if not search_ranges or search_ranges[0] != (0, len(body_skel)):
        search_ranges.append((0, len(body_skel)))

    best_fuzzy: dict[str, Any] | None = None
    best_fuzzy_score = -1.0

    # Sliding window on skeleton using anchor k-mers from quote_skel
    k = min(4, max(2, len(quote_skel) // 4))
    step = max(1, (len(quote_skel) - k) // 5 or 1)
    seeds = [quote_skel[i : i + k] for i in range(0, len(quote_skel) - k + 1, step)]

    for r_start, r_end in search_ranges:
        sub_skel = body_skel[r_start:r_end]
        candidate_starts: set[int] = set()
        for idx_s, seed in enumerate(seeds):
            approx_offset = idx_s * step
            pos = 0
            hits = 0
            while hits < 25:
                found = sub_skel.find(seed, pos)
                if found < 0:
                    break
                abs_skel_start = max(r_start, r_start + found - approx_offset - max(4, len(quote_skel) // 4))
                candidate_starts.add(abs_skel_start)
                pos = found + 1
                hits += 1

        for c_start in sorted(candidate_starts):
            c_end = min(len(body_skel), c_start + int(len(quote_skel) * 1.45) + 8)
            window_skel = body_skel[c_start:c_end]
            if not window_skel:
                continue
            sm = SequenceMatcher(None, quote_skel, window_skel, autojunk=False)
            blocks = [b for b in sm.get_matching_blocks() if b.size > 0]
            if not blocks:
                continue
            matched_chars = sum(b.size for b in blocks)
            # Determine tight span in window_skel from first matching block to last matching block
            first_b = blocks[0]
            last_b = blocks[-1]
            # Extrapolate leading/trailing unmatched characters of quote_skel proportionally
            tight_start_in_win = max(0, first_b.b - first_b.a)
            tight_end_in_win = min(
                len(window_skel),
                last_b.b + last_b.size + (len(quote_skel) - (last_b.a + last_b.size)),
            )
            if tight_end_in_win <= tight_start_in_win:
                continue
            tight_skel = window_skel[tight_start_in_win:tight_end_in_win]
            ratio = SequenceMatcher(None, quote_skel, tight_skel, autojunk=False).ratio()
            if ratio < min_fuzzy_ratio:
                continue

            abs_s = c_start + tight_start_in_win
            abs_e = min(len(body_skel) - 1, c_start + tight_end_in_win - 1)
            orig_s = body_map[abs_s]
            orig_e = body_map[abs_e] + 1
            orig_s, orig_e = _expand_clean_markdown_boundaries(
                norm_body, orig_s, orig_e, clean_quote
            )
            # Do not allow fuzzy match to span across multiple blank-line paragraph breaks unless original did
            if "\n\n" in norm_body[orig_s:orig_e] and "\n\n" not in clean_quote:
                continue

            ctx_bonus = _score_context_candidate(
                norm_body, orig_s, orig_e, quote_prefix, quote_suffix, line_hint
            )
            combined_score = ratio * 3.0 + ctx_bonus * 0.4
            if combined_score > best_fuzzy_score:
                best_fuzzy_score = combined_score
                p, s = _extract_context(norm_body, orig_s, orig_e)
                best_fuzzy = {
                    "start_char": orig_s,
                    "end_char": orig_e,
                    "line_hint": _char_to_line(norm_body, orig_s),
                    "quote_exact": norm_body[orig_s:orig_e],
                    "quote_prefix": p,
                    "quote_suffix": s,
                    "tier": "fuzzy",
                    "confidence": round(ratio, 3),
                }
        if best_fuzzy is not None and best_fuzzy["confidence"] >= 0.82:
            break

    return best_fuzzy


def reanchor_annotations(
    annotations: list[dict[str, Any]],
    new_body: str,
    *,
    now_iso: str = "",
) -> list[dict[str, Any]]:
    """Re-anchor a note's stand-off AI annotations against `new_body` after a user edit.

    - Active annotations that relocate (via exact, normalized, context_pinch, or fuzzy match)
      have their `quote_exact`, `quote_prefix`, `quote_suffix`, and `line_hint` seamlessly
      healed to match the user's edited text.
    - Orphaned annotations from a previous edit get a chance to self-heal if the user
      restored or undid the text deletion.
    - Annotations whose target sentence was deleted become `status = 'orphaned'` (never
      corrupting or drifting onto unrelated sentences).
    """
    updated: list[dict[str, Any]] = []
    for raw_ann in annotations or []:
        ann = dict(raw_ann)
        old_status = ann.get("status", "active")
        if old_status not in ("active", "orphaned"):
            updated.append(ann)
            continue

        hit = locate_quote_anchor(
            new_body,
            ann.get("quote_exact", ""),
            quote_prefix=ann.get("quote_prefix", ""),
            quote_suffix=ann.get("quote_suffix", ""),
            line_hint=int(ann.get("line_hint") or 1),
        )
        if hit is not None:
            changed = (
                ann.get("quote_exact") != hit["quote_exact"]
                or ann.get("quote_prefix") != hit["quote_prefix"]
                or ann.get("quote_suffix") != hit["quote_suffix"]
                or int(ann.get("line_hint") or 0) != hit["line_hint"]
                or old_status != "active"
            )
            ann["quote_exact"] = hit["quote_exact"]
            ann["quote_prefix"] = hit["quote_prefix"]
            ann["quote_suffix"] = hit["quote_suffix"]
            ann["line_hint"] = hit["line_hint"]
            ann["status"] = "active"
            if changed and now_iso:
                ann["updated_at"] = now_iso
        else:
            if old_status != "orphaned":
                ann["status"] = "orphaned"
                if now_iso:
                    ann["updated_at"] = now_iso
        updated.append(ann)
    return updated

