#!/usr/bin/env python3
"""CLI tool for AI Agents to inspect notes and manage the stand-off AI Highlight & Comment Layer.

Can connect either to the running ir4anki HTTP server (`--api http://127.0.0.1:8010`)
or directly to the SQLite `data.db` storage engine (`--db /path/to/data.db`) when offline.

Examples:
  # 1. List or search notes
  python3 scripts/agent_layer.py notes --query "外科学"

  # 2. Read a note's content (whole or line range) and existing highlights
  python3 scripts/agent_layer.py read --note "2026/外科学/胃十二指肠疾病.md" --start 1 --end 120

  # 3. Add a single highlight + comment
  python3 scripts/agent_layer.py add --note "2026/外科学/胃十二指肠疾病.md" \
      --layer "22级学长重点" \
      --quote "胃大部切除术后早期最严重的并发症是十二指肠残端破裂" \
      --comment "学长总结P3：注意区分『早期最严重（十二指肠残端破裂）』与『最常见（胃出血）』，必考单选！"

  # 4. Batch apply highlights & comments from a JSON file (or stdin '-')
  python3 scripts/agent_layer.py batch --note "2026/外科学/胃十二指肠疾病.md" \
      --layer "22级学长重点" --file highlights.json

  # 5. Clear highlights on a note (or specific layer)
  python3 scripts/agent_layer.py clear --note "2026/外科学/胃十二指肠疾病.md" --layer "22级学长重点"
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_API_URL = os.getenv("IR4ANKI_API_URL", "http://127.0.0.1:8901")


def _http_json(method: str, url: str, payload: dict[str, Any] | None = None) -> dict[str, Any]:
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Accept": "application/json"}
    if data is not None:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        try:
            detail = json.loads(body).get("detail", body)
        except Exception:
            detail = body
        raise RuntimeError(f"HTTP {exc.code}: {detail}") from exc


def _open_local_engine(db_path: str | None):
    repo_root = Path(__file__).resolve().parent.parent
    sys.path.insert(0, str(repo_root / "backend"))
    from storage import LocalFsDriver, PlatformShim, SQLiteDatabaseDriver, StorageEngine

    if not db_path:
        state_dir = Path(
            os.getenv("ANKI_STATE_DIR", str(Path.home() / ".local/state/ir4anki"))
        )
        db_file = state_dir / "data.db"
    else:
        db_file = Path(db_path).resolve()
    media_dir = db_file.parent / "media"
    return StorageEngine(SQLiteDatabaseDriver(db_file), LocalFsDriver(media_dir), PlatformShim())


def cmd_notes(args: argparse.Namespace) -> None:
    if args.db:
        eng = _open_local_engine(args.db)
        try:
            if args.query:
                rows = eng.search_notes(args.query, limit=100)
                out = {"query": args.query, "notes": rows}
            else:
                notes = eng.list_notes(in_list_only=args.in_list, include_deleted=False)
                out = {
                    "notes": [
                        {
                            "id": n["id"],
                            "title": n["title"],
                            "path": n["path"],
                            "in_list": n["in_list"],
                            "chars": len(n.get("body") or ""),
                            "lines": (n.get("body") or "").count("\n") + 1
                            if n.get("body")
                            else 0,
                        }
                        for n in notes
                    ]
                }
        finally:
            eng.close()
    else:
        params: dict[str, str] = {}
        if args.in_list:
            params["in_list_only"] = "true"
        if args.query:
            params["q"] = args.query
        qs = ("?" + urllib.parse.urlencode(params)) if params else ""
        out = _http_json("GET", f"{args.api.rstrip('/')}/api/agent/notes{qs}")

    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    notes = out.get("notes") or []
    print(f"Found {len(notes)} note(s):")
    for n in notes:
        path = n.get("path") or n.get("legacy_path") or n.get("title")
        flag = "[在读]" if n.get("in_list") else "      "
        extra = (
            f" ({n.get('lines')}L, {n.get('chars')} chars)"
            if "lines" in n
            else f" — {n.get('snippet', '')}"
        )
        print(f"  {flag} {n['id']}  {path}{extra}")


def cmd_read(args: argparse.Namespace) -> None:
    if args.db:
        eng = _open_local_engine(args.db)
        try:
            note = eng.resolve_note(args.note, include_deleted=False, include_segments=True)
            if note is None:
                sys.exit(f"Error: Note not found: {args.note}")
            body = note.get("body") or ""
            lines = body.split("\n") if body else []
            total = len(lines)
            a = max(1, min(int(args.start or 1), total or 1))
            b = max(a, min(int(args.end or total or 1), total or 1))
            anns = eng.list_annotations(note["id"], status="active")
            out = {
                "note_id": note["id"],
                "path": note["path"],
                "title": note["title"],
                "total_lines": total,
                "start_line": a,
                "end_line": b,
                "text": "\n".join(lines[a - 1 : b]),
                "numbered_lines": [
                    {"line": i, "text": lines[i - 1]}
                    for i in range(a, b + 1)
                    if 1 <= i <= total
                ],
                "annotations": anns,
            }
        finally:
            eng.close()
    else:
        params: dict[str, Any] = {"path": args.note}
        if args.start:
            params["start_line"] = args.start
        if args.end:
            params["end_line"] = args.end
        qs = urllib.parse.urlencode(params)
        out = _http_json("GET", f"{args.api.rstrip('/')}/api/agent/note?{qs}")

    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    print(
        f"=== {out['title']} ({out['path']}) [note_id={out['note_id']}] "
        f"Lines {out['start_line']}..{out['end_line']} / {out['total_lines']} ==="
    )
    for item in out.get("numbered_lines") or []:
        print(f"{item['line']:4d} | {item['text']}")
    anns = out.get("annotations") or []
    if anns:
        print(f"\n--- Active AI Annotations ({len(anns)}) ---")
        for idx, a in enumerate(anns, 1):
            cmt = f" -> 💬 {a['comment']}" if a.get("comment") else ""
            print(f"  [{idx}] L{a['line_hint']} ({a['layer_name']}): 「{a['quote_exact']}」{cmt}")


def _submit_batch(
    args: argparse.Namespace,
    note_target: str,
    layer_name: str,
    replace_layer: bool,
    items: list[dict[str, Any]],
) -> dict[str, Any]:
    if args.db:
        eng = _open_local_engine(args.db)
        try:
            res = eng.add_annotations_batch(
                note_target,
                items,
                layer_name=layer_name,
                replace_layer=replace_layer,
            )
            return {"ok": True, **res}
        finally:
            eng.close()
    payload = {
        "path": note_target,
        "layer_name": layer_name,
        "replace_layer": replace_layer,
        "annotations": items,
    }
    return _http_json("POST", f"{args.api.rstrip('/')}/api/agent/annotations", payload)


def cmd_add(args: argparse.Namespace) -> None:
    item: dict[str, Any] = {
        "quote": args.quote,
        "comment": args.comment or "",
    }
    if args.line_hint:
        item["line_hint"] = args.line_hint
    out = _submit_batch(args, args.note, args.layer, False, [item])
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    print(
        f"Saved {out['saved_count']} highlight(s), unmatched {out['unmatched_count']} on {out['path']}"
    )
    for s in out.get("saved") or []:
        print(
            f"  ✓ [L{s['line_hint']} · {s['match_tier']} conf={s['confidence']}] 「{s['quote_exact']}」"
        )
    for u in out.get("unmatched") or []:
        print(f"  ✗ Unmatched: 「{u['quote']}」 ({u['reason']})", file=sys.stderr)
    if out.get("unmatched_count"):
        sys.exit(1)


def cmd_batch(args: argparse.Namespace) -> None:
    raw = (
        sys.stdin.read()
        if args.file == "-"
        else Path(args.file).read_text(encoding="utf-8")
    )
    parsed = json.loads(raw)
    if isinstance(parsed, dict):
        items = parsed.get("annotations") or []
        note_target = args.note or parsed.get("note_id") or parsed.get("path")
        layer = args.layer or parsed.get("layer_name") or "default"
        replace = bool(args.replace or parsed.get("replace_layer"))
    elif isinstance(parsed, list):
        items = parsed
        note_target = args.note
        layer = args.layer or "default"
        replace = bool(args.replace)
    else:
        sys.exit("Error: JSON payload must be a list of annotations or an object with 'annotations'")

    if not note_target:
        sys.exit("Error: --note is required (or specify 'note_id'/'path' in JSON)")

    out = _submit_batch(args, note_target, layer, replace, items)
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return
    print(
        f"Batch complete on {out['path']}: saved={out['saved_count']}, unmatched={out['unmatched_count']}"
    )
    for s in out.get("saved") or []:
        print(f"  ✓ [L{s['line_hint']} · {s['match_tier']}] 「{s['quote_exact'][:50]}」")
    for u in out.get("unmatched") or []:
        print(f"  ✗ Unmatched #{u['index']}: 「{u['quote']}」 ({u['reason']})", file=sys.stderr)


def cmd_clear(args: argparse.Namespace) -> None:
    if args.db:
        eng = _open_local_engine(args.db)
        try:
            deleted = eng.delete_annotations(
                note_id_or_path=args.note,
                annotation_id=args.id,
                layer_name=args.layer,
            )
            out = {"ok": True, "deleted": deleted}
        finally:
            eng.close()
    else:
        payload: dict[str, Any] = {}
        if args.note:
            payload["path"] = args.note
        if args.id:
            payload["annotation_id"] = args.id
        if args.layer:
            payload["layer_name"] = args.layer
        out = _http_json(
            "POST", f"{args.api.rstrip('/')}/api/agent/annotations/delete", payload
        )
    if args.json:
        print(json.dumps(out, ensure_ascii=False, indent=2))
    else:
        print(f"Deleted {out['deleted']} annotation(s).")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="CLI interface for AI Agents to read notes and write stand-off AI highlights & comments."
    )
    parser.add_argument(
        "--api",
        default=DEFAULT_API_URL,
        help=f"ir4anki backend base URL (default: {DEFAULT_API_URL})",
    )
    parser.add_argument(
        "--db",
        default=None,
        help="Optional path to SQLite data.db for direct offline access (bypasses HTTP API)",
    )
    parser.add_argument(
        "--json", action="store_true", help="Output raw JSON response"
    )

    sub = parser.add_subparsers(dest="cmd", required=True)

    p_notes = sub.add_parser("notes", help="List or search notes in the library")
    p_notes.add_argument("--query", "-q", default=None, help="Full-text search query")
    p_notes.add_argument(
        "--in-list", action="store_true", help="Only list notes in the reading queue"
    )
    p_notes.set_defaults(func=cmd_notes)

    p_read = sub.add_parser("read", help="Read note Markdown text and active AI annotations")
    p_read.add_argument("--note", "-n", required=True, help="Note UUID or relative path")
    p_read.add_argument("--start", type=int, default=None, help="1-based start line")
    p_read.add_argument("--end", type=int, default=None, help="1-based end line")
    p_read.set_defaults(func=cmd_read)

    p_add = sub.add_parser("add", help="Add a single AI highlight and optional comment")
    p_add.add_argument("--note", "-n", required=True, help="Note UUID or relative path")
    p_add.add_argument("--quote", "-q", required=True, help="Target quote substring to highlight")
    p_add.add_argument("--comment", "-c", default="", help="Optional AI annotation comment")
    p_add.add_argument("--layer", "-l", default="default", help="Layer/source name")
    p_add.add_argument("--line-hint", type=int, default=None, help="Optional 1-based line hint")
    p_add.set_defaults(func=cmd_add)

    p_batch = sub.add_parser("batch", help="Batch apply AI highlights & comments from JSON")
    p_batch.add_argument("--note", "-n", default=None, help="Note UUID or relative path")
    p_batch.add_argument("--file", "-f", required=True, help="Path to JSON file (or '-' for stdin)")
    p_batch.add_argument("--layer", "-l", default="default", help="Default layer name")
    p_batch.add_argument(
        "--replace", action="store_true", help="Replace existing annotations on this layer"
    )
    p_batch.set_defaults(func=cmd_batch)

    p_clear = sub.add_parser("clear", help="Delete AI annotations by note, layer, or ID")
    p_clear.add_argument("--note", "-n", default=None, help="Note UUID or relative path")
    p_clear.add_argument("--layer", "-l", default=None, help="Layer name to clear")
    p_clear.add_argument("--id", default=None, help="Specific annotation ID to delete")
    p_clear.set_defaults(func=cmd_clear)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
