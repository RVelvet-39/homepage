#!/usr/bin/env python3
"""Read open tasks out of Memos (new /api surface; API v1 is gone).

Token: ~/.config/memos/token (mode 600). Base URL via MEMOS_URL.
Conventions detected, not imposed:
    - Markdown checkboxes "- [ ] thing"   -> open task
    - "#task" or "#todo" tag anywhere     -> memo counts as a task list
    - "- [x]"/"- [X]"                     -> done, skipped

Usage:
    memos.py tasks            open tasks, one per line
    memos.py tasks --all      also show done items in brackets
    memos.py raw [N]          dump the N most recent memos (default 5)
    memos.py health           show auth + counts, for debugging
"""
from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

BASE = os.environ.get("MEMOS_URL", "https://hyacinth.angora-puffin.ts.net:8443").rstrip("/")
TOKEN_FILE = Path(os.environ.get("MEMOS_TOKEN_FILE", "~/.config/memos/token")).expanduser()

CHECKBOX_OPEN = re.compile(r"^\s*[-*]\s*\[[ ]\]\s*(.+?)\s*$")
CHECKBOX_DONE = re.compile(r"^\s*[-*]\s*\[[xX]\]\s*(.+?)\s*$")
TAG_TASK = re.compile(r"#(task|todo)\b", re.I)


def token() -> str:
    if not TOKEN_FILE.exists():
        sys.exit(f"token file missing: {TOKEN_FILE}")
    return TOKEN_FILE.read_text().strip()


def api(path: str) -> dict:
    req = urllib.request.Request(BASE + path, headers={"Authorization": f"Bearer {token()}"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()[:200]
        sys.exit(f"HTTP {e.code} on {path}: {body}")
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach {BASE}: {e.reason}")


def all_memos(limit_pages: int = 5) -> list[dict]:
    out: list[dict] = []
    page = ""
    for _ in range(limit_pages):
        q = "/api/memos?pageSize=100" + (f"&pageToken={page}" if page else "")
        d = api(q)
        out.extend(d.get("memos", []))
        page = d.get("nextPageToken") or ""
        if not page:
            break
    return out


def cmd_health(_args=()):
    me = api("/api/users/me")
    memos = all_memos()
    print(f"base      : {BASE}")
    print(f"identity  : {json.dumps(me)[:160]}")
    print(f"memos     : {len(memos)}")
    if memos:
        m = memos[0]
        print(f"fields    : {sorted(m)[:14]}")


def cmd_tasks(args):
    show_done = "--all" in args
    memos = all_memos()
    found = 0
    for m in memos:
        content = str(m.get("content", ""))
        lines = content.splitlines()
        open_items, done_items = [], []
        for ln in lines:
            mo = CHECKBOX_OPEN.match(ln)
            md = CHECKBOX_DONE.match(ln)
            if mo:
                open_items.append(mo.group(1))
            elif md:
                done_items.append(md.group(1))
        if not open_items and not TAG_TASK.search(content):
            if not (show_done and done_items):
                continue
        for item in open_items:
            print(f"[ ] {item}")
            found += 1
        if show_done:
            for item in done_items:
                print(f"[x] {item}")
        if not open_items and not done_items and TAG_TASK.search(content):
            # a task memo with no checkboxes: use the first non-tag line
            first = next((l.strip() for l in lines if l.strip() and not l.strip().startswith("#")), "")
            if first:
                print(f"[ ] {first}")
                found += 1
    if found == 0:
        print("no open tasks")


def cmd_raw(args):
    n = int(args[0]) if args else 5
    for m in all_memos()[:n]:
        print(f"--- {m.get('name','?')}  {m.get('createTime','')}")
        print(str(m.get("content", ""))[:400])


COMMANDS = {"tasks": cmd_tasks, "raw": cmd_raw, "health": cmd_health}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit(__doc__)
    COMMANDS[sys.argv[1]](sys.argv[2:])
