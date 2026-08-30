#!/usr/bin/env python3
"""ZCode Stop hook: optional Bark push when a session ends."""
from __future__ import annotations

import json
import sqlite3
import sys
import urllib.parse
import urllib.request
from pathlib import Path

CFG = Path(__file__).resolve().parent / "config.json"
ZHOME = Path.home() / ".zcode"
TASK_DBS = [
    ZHOME / "v2" / "tasks-index.sqlite",
    ZHOME / "cli" / "db" / "db.sqlite",
]


def task_title(session_id: str) -> str | None:
    """用 session_id 去 ZCode 本地任务库查真实标题。"""
    if not session_id:
        return None
    for db in TASK_DBS:
        if not db.exists():
            continue
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=2)
            row = con.execute(
                "select title from tasks where task_id = ? limit 1",
                (session_id,),
            ).fetchone()
            con.close()
            if row and row[0] and str(row[0]).strip():
                return str(row[0]).strip()
        except Exception:
            continue
    return None


def main() -> int:
    raw = sys.stdin.read()
    payload = {}
    if raw.strip():
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            payload = {"preview": raw[:200]}
    if not CFG.exists():
        return 0
    cfg = json.loads(CFG.read_text(encoding="utf-8"))
    if not cfg.get("barkEnabled"):
        return 0
    url = (cfg.get("barkUrl") or "").strip().rstrip("/")
    if not url:
        return 0
    title = (cfg.get("barkTitle") or "ZCode").strip()
    session_id = str(payload.get("session_id") or "")
    body = (
        task_title(session_id)
        or str(payload.get("preview") or "").strip()
        or "会话已结束"
    )[:180]
    icon = (cfg.get("barkIcon") or "").strip()
    target = f"{url}/{urllib.parse.quote(title)}/{urllib.parse.quote(body)}"
    if icon:
        target += "?" + urllib.parse.urlencode({"icon": icon})
    try:
        urllib.request.urlopen(target, timeout=6).read()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
