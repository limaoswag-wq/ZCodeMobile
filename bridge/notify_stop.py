#!/usr/bin/env python3
"""ZCode Stop hook: optional Bark push when a session ends."""
from __future__ import annotations

import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

CFG = Path(__file__).resolve().parent / "config.json"


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
    title = "ZCode 任务结束"
    body = str(payload.get("preview") or payload.get("session_id") or "会话已停止")[:180]
    target = f"{url}/{urllib.parse.quote(title)}/{urllib.parse.quote(body)}"
    try:
        urllib.request.urlopen(target, timeout=6).read()
    except Exception:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
