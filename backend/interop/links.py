"""Code-aware Markdown & HTML local link rewriting to Joplin `:/<resource_id>` syntax.

Preserves exact source formatting and offsets outside matched image/asset links by
masking fenced code blocks, indented code blocks, and inline code spans with
`markdown-it-py`.
"""
from __future__ import annotations

import posixpath
import re
from typing import Callable
from urllib.parse import unquote, urlsplit

from markdown_it import MarkdownIt

_MD_BLOCK_PARSER = MarkdownIt("commonmark", {"maxNesting": 100})

_IMG_TAG_RE = re.compile(r"<img\b([^>]*?)/?>", re.I | re.S)
_ATTR_RE = re.compile(
    r"""([a-zA-Z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))""",
    re.S,
)
_HREF_ATTR_RE = re.compile(r"""(\bhref\s*=\s*["'])([^"']+)(["'])""", re.I)


def visible_markdown(source_text: str) -> str:
    """Return a same-length copy of `source_text` with code blocks & code spans blanked out."""
    normalized = source_text.replace("\r\n", "\n").replace("\r", "\n")
    tokens = []
    _MD_BLOCK_PARSER.block.parse(normalized, _MD_BLOCK_PARSER, {}, tokens)
    starts = [0] + [m.end() for m in re.finditer(r"\r\n|\r|\n", source_text)]
    starts.append(len(source_text))
    characters = list(source_text)
    for token in tokens:
        if token.type in ("code_block", "fence") and token.map is not None:
            start, stop = token.map
            for pos in range(starts[start], starts[stop]):
                if characters[pos] not in "\r\n":
                    characters[pos] = " "
    visible = "".join(characters)

    runs = list(re.finditer(r"`+", visible))
    next_same: dict[int, int] = {}
    last: dict[int, int] = {}
    for index in range(len(runs) - 1, -1, -1):
        length = len(runs[index][0])
        if length in last:
            next_same[index] = last[length]
        last[length] = index

    characters = list(visible)
    end = 0
    for index, run in enumerate(runs):
        if run.start() < end or index not in next_same:
            continue
        # Backslash escapes apply to openers outside code, not closers inside.
        backslashes = 0
        pos = run.start() - 1
        while pos >= 0 and visible[pos] == "\\":
            backslashes += 1
            pos -= 1
        if backslashes % 2:
            continue
        end = runs[next_same[index]].end()
        for pos in range(run.start(), end):
            if characters[pos] != "\n":
                characters[pos] = " "
    return "".join(characters)


def _split_local_ref(ref: str) -> tuple[str, str, str] | None:
    """Return `(decoded_path, query, fragment)` if `ref` is a local relative reference,
    or `None` if it is external (`http://`, `data:`, `:/`, `/abs`, `#anchor`, invalid)."""
    raw = (ref or "").strip()
    if not raw or raw.startswith(("/", "#", ":/")):
        return None
    unescaped = re.sub(r"\\([\\() ])", r"\1", raw)
    try:
        parsed = urlsplit(unescaped)
    except ValueError:
        return None
    if parsed.scheme or parsed.netloc:
        return None
    path_part = unquote(parsed.path)
    if not path_part:
        return None
    return path_part, parsed.query, parsed.fragment


def resolve_relative_target(source_rel: str, decoded_path: str) -> str | None:
    """Resolve `decoded_path` relative to `source_rel`, rejecting upward traversal."""
    clean = decoded_path.replace("\\", "/")
    if clean.startswith("/"):
        return None
    base_dir = posixpath.dirname(source_rel)
    joined = posixpath.join(base_dir, clean) if base_dir else clean
    norm = posixpath.normpath(joined)
    if norm in ("", ".", "..") or norm.startswith("../"):
        return None
    return norm


def _escape_md_alt(alt: str) -> str:
    return (alt or "").replace("\r", " ").replace("\n", " ").replace("]", r"\]").strip()


def rewrite_local_links(
    text: str,
    source_rel: str,
    resolve_asset: Callable[[str, str], str | None],
) -> tuple[str, list[str]]:
    """Rewrite local image/asset references in Markdown & HTML to `:/<resource_id>`.

    `resolve_asset(norm_rel_or_raw, decoded_path)` receives:
      - `norm_rel`: POSIX normalized path relative to import root (or `""` if traversal)
      - `decoded_path`: unquoted path part from the link
    and returns `:/<resource_id>` when resolved, or `None` if not found.

    Returns `(rewritten_text, missing_refs)` where `missing_refs` lists local image
    references that could not be matched to any resource in the batch.
    """
    missing_refs: list[str] = []
    missing_seen: set[str] = set()

    def _record_missing(raw_ref: str) -> None:
        if raw_ref not in missing_seen:
            missing_seen.add(raw_ref)
            missing_refs.append(raw_ref)

    def _rewrite_ref(ref: str, *, track_missing: bool = True) -> tuple[str, bool]:
        split = _split_local_ref(ref)
        if split is None:
            return ref, False
        decoded_path, query, fragment = split
        norm_rel = resolve_relative_target(source_rel, decoded_path)
        if norm_rel is None:
            if track_missing:
                _record_missing(ref)
            return ref, False
        target_id = resolve_asset(norm_rel, decoded_path)
        if not target_id:
            if track_missing:
                _record_missing(ref)
            return ref, False
        suffix = (f"?{query}" if query else "") + (f"#{fragment}" if fragment else "")
        return target_id + suffix, True

    # 1. Inline Markdown images: ![alt](target "optional title")
    mask = visible_markdown(text)
    parts: list[str] = []
    offset = 0
    for match in re.finditer(r"!\[[^\]\n]*\]\(\s*", mask):
        start = match.end()
        if start < offset or start >= len(mask):
            continue
        is_angle = False
        if mask[start] == "<":
            end = mask.find(">", start + 1)
            if end < 0 or "\n" in mask[start:end]:
                continue
            is_angle = True
            inner_start = start + 1
            inner_end = end
        else:
            end = start
            depth = 0
            while end < len(mask):
                ch = mask[end]
                if ch == "\\" and end + 1 < len(mask):
                    end += 2
                    continue
                if ch == "(":
                    depth += 1
                elif ch == ")":
                    if depth == 0:
                        break
                    depth -= 1
                elif ch.isspace():
                    break
                end += 1
            if depth or end == len(mask):
                continue
            inner_start = start
            inner_end = end

        orig_ref = text[inner_start:inner_end]
        rewritten, changed = _rewrite_ref(orig_ref, track_missing=True)
        if is_angle and changed:
            # Angle brackets aren't needed for :/resource_id, drop them cleanly.
            parts.append(text[offset:start])
            parts.append(rewritten)
            offset = end + 1
        else:
            parts.append(text[offset:inner_start])
            parts.append(rewritten)
            offset = inner_end
    parts.append(text[offset:])
    text = "".join(parts)

    # 2. Reference-style Markdown images: ![alt][label] + [label]: target
    mask = visible_markdown(text)
    image_labels = {
        re.sub(r"\s+", " ", (m.group(2) or m.group(1))).strip().lower()
        for m in re.finditer(r"!\[([^\]\n]+)\](?:\[([^\]\n]*)\])?(?!\()", mask)
    }
    if image_labels:
        ref_def_re = re.compile(
            r"(?m)^( {0,3}\[([^\]\n]+)\]:[ \t]*)(<[^>]+>|[^\s]+)([^\n]*)$"
        )
        out_parts: list[str] = []
        offset = 0
        for m in ref_def_re.finditer(mask):
            orig_m = ref_def_re.match(text, m.start())
            if not orig_m or orig_m.end() != m.end():
                continue
            label_key = re.sub(r"\s+", " ", orig_m.group(2)).strip().lower()
            if label_key not in image_labels:
                continue
            raw_dest = orig_m.group(3)
            inner = raw_dest[1:-1] if raw_dest.startswith("<") and raw_dest.endswith(">") else raw_dest
            rewritten, changed = _rewrite_ref(inner, track_missing=True)
            replacement = (
                orig_m.group(1)
                + (rewritten if changed else raw_dest)
                + orig_m.group(4)
            )
            out_parts.append(text[offset : orig_m.start()])
            out_parts.append(replacement)
            offset = orig_m.end()
        out_parts.append(text[offset:])
        text = "".join(out_parts)

    # 3. HTML <img ... src="..."> -> standard Markdown ![alt](:/<id>) so frontend
    #    renders safely with `html: false` AND `extract_resource_ids` indexes it.
    mask = visible_markdown(text)
    out_parts = []
    offset = 0
    for m in _IMG_TAG_RE.finditer(mask):
        orig_tag = text[m.start() : m.end()]
        attrs_raw = text[m.start(1) : m.end(1)]
        attrs: dict[str, str] = {}
        for am in _ATTR_RE.finditer(attrs_raw):
            k = am.group(1).lower()
            v = am.group(2) if am.group(2) is not None else (
                am.group(3) if am.group(3) is not None else (am.group(4) or "")
            )
            attrs[k] = v
        src = attrs.get("src")
        if not src:
            continue
        rewritten, changed = _rewrite_ref(src, track_missing=True)
        if not changed:
            continue
        alt = _escape_md_alt(attrs.get("alt", ""))
        out_parts.append(text[offset : m.start()])
        out_parts.append(f"![{alt}]({rewritten})")
        offset = m.end()
    out_parts.append(text[offset:])
    text = "".join(out_parts)

    # 4. HTML href="..." pointing to local batch images (e.g. <a href="../a/x.png">)
    mask = visible_markdown(text)
    out_parts = []
    offset = 0
    for m in _HREF_ATTR_RE.finditer(mask):
        orig_m = _HREF_ATTR_RE.match(text, m.start())
        if not orig_m or orig_m.end() != m.end():
            continue
        rewritten, changed = _rewrite_ref(orig_m.group(2), track_missing=False)
        if not changed:
            continue
        out_parts.append(text[offset : orig_m.start()])
        out_parts.append(orig_m.group(1) + rewritten + orig_m.group(3))
        offset = orig_m.end()
    out_parts.append(text[offset:])
    text = "".join(out_parts)

    return text, missing_refs
