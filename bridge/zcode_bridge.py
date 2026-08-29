#!/usr/bin/env python3
"""Local bridge between the ZCode desktop databases and the iOS client."""
from __future__ import annotations

import json
import os
import secrets
import socket
import sqlite3
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path(os.environ.get("USERPROFILE") or os.environ.get("HOME") or ".")
ZCODE = Path(os.environ.get("ZCODE_HOME") or (HOME / ".zcode"))
ROOT = Path(__file__).resolve().parent
CONFIG_PATH = ROOT / "config.json"
DEFAULT_PORT = 18765


def load_config() -> dict:
    if CONFIG_PATH.exists():
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    else:
        data = {}
    data.setdefault("port", DEFAULT_PORT)
    data.setdefault("token", secrets.token_urlsafe(18))
    data.setdefault("zcodeHome", str(ZCODE))
    data.setdefault("zcodeCallbackUrl", "")
    data.setdefault("zcodeBotId", "")
    data.setdefault("zcodeUserId", "zcode-mobile")
    data.setdefault("zcodeWebhookSecret", "")
    data.setdefault("barkEnabled", False)
    data.setdefault("barkUrl", "")
    CONFIG_PATH.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return data


CFG = load_config()
ZHOME = Path(CFG["zcodeHome"])
TASKS_DB = ZHOME / "v2" / "tasks-index.sqlite"
CLI_DB = ZHOME / "cli" / "db" / "db.sqlite"
INBOX = ZHOME / "v2" / "mobile-inbox.jsonl"

STATE = {
    "revision": 0,
    "currentTaskId": None,
    "lastEvent": None,
    "lock": threading.Lock(),
    "known": {},
    "barkSent": set(),
}


def _is_usable_lan(ip: str) -> bool:
    if ip.startswith("127.") or ip.startswith("169.254."):
        return False
    # Clash/TUN fake ranges that look local but phones cannot reach.
    if ip.startswith("198.18.") or ip.startswith("198.19."):
        return False
    return True


def lan_addresses() -> list[str]:
    found: list[str] = []
    try:
        hostname = socket.gethostname()
        for info in socket.getaddrinfo(hostname, None, socket.AF_INET):
            ip = info[4][0]
            if ip not in found and _is_usable_lan(ip):
                found.append(ip)
    except OSError:
        pass
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ip = sock.getsockname()[0]
        sock.close()
        if _is_usable_lan(ip) and ip not in found:
            found.insert(0, ip)
        elif ip in found:
            found.remove(ip)
            found.insert(0, ip)
    except OSError:
        pass
    preferred = [ip for ip in found if ip.startswith("192.168.") or ip.startswith("10.")]
    rest = [ip for ip in found if ip not in preferred]
    ordered = preferred + rest
    return ordered or ["127.0.0.1"]


def connect(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        return None
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2)
    con.row_factory = sqlite3.Row
    return con


def connect_rw(path: Path) -> sqlite3.Connection | None:
    if not path.exists():
        return None
    con = sqlite3.connect(str(path), timeout=5)
    con.row_factory = sqlite3.Row
    return con


def list_tasks() -> list[dict]:
    con = connect(TASKS_DB)
    if con is None:
        return []
    try:
        rows = con.execute(
            """
            select task_id, title, task_status, mode, model, workspace_path, created_at, updated_at
            from tasks
            where deleted = 0 and archived = 0
            order by pinned desc, updated_at desc
            limit 80
            """
        ).fetchall()
    finally:
        con.close()
    tasks = []
    for row in rows:
        tasks.append(
            {
                "id": row["task_id"],
                "title": row["title"] or "未命名任务",
                "status": row["task_status"] or "idle",
                "mode": row["mode"],
                "model": row["model"],
                "workspacePath": row["workspace_path"],
                "createdAt": row["created_at"] or 0,
                "updatedAt": row["updated_at"] or 0,
            }
        )
    return tasks


def visible_message(data: dict) -> bool:
    if data.get("synthetic"):
        return False
    sem = data.get("semantics") or {}
    vis = sem.get("uiVisibility") or data.get("metadata", {}).get("visibility")
    if vis in ("hidden", "model-only"):
        return False
    return data.get("role") in ("user", "assistant")


def load_messages(task_id: str) -> list[dict]:
    con = connect(CLI_DB)
    if con is None:
        return []
    try:
        messages = con.execute(
            "select id, data, time_created from message where session_id = ? order by time_created asc, id asc",
            (task_id,),
        ).fetchall()
        parts = con.execute(
            "select message_id, id, data, time_created from part where session_id = ? order by time_created asc, id asc",
            (task_id,),
        ).fetchall()
    finally:
        con.close()
    grouped: dict[str, list] = {}
    for part in parts:
        grouped.setdefault(part["message_id"], []).append(part)
    out = []
    for message in messages:
        try:
            payload = json.loads(message["data"])
        except json.JSONDecodeError:
            continue
        if not visible_message(payload):
            continue
        blocks = []
        for part in grouped.get(message["id"], []):
            try:
                pdata = json.loads(part["data"])
            except json.JSONDecodeError:
                continue
            kind = pdata.get("type") or "text"
            if kind == "text":
                text = (pdata.get("text") or "").strip()
                if text:
                    blocks.append({"id": part["id"], "kind": "text", "text": text})
            elif kind == "reasoning":
                text = (pdata.get("text") or "").strip()
                if text:
                    blocks.append({"id": part["id"], "kind": "reasoning", "text": text})
            elif kind == "tool":
                state = pdata.get("state") or {}
                blocks.append(
                    {
                        "id": part["id"],
                        "kind": "tool",
                        "text": pdata.get("tool") or "工具",
                        "tool": pdata.get("tool"),
                        "status": state.get("status"),
                    }
                )
        if not blocks:
            continue
        out.append(
            {
                "id": message["id"],
                "role": payload.get("role") or "assistant",
                "createdAt": message["time_created"] or 0,
                "blocks": blocks,
            }
        )
    return out[-120:]


def desktop_online() -> bool:
    return TASKS_DB.exists() and CLI_DB.exists()


def snapshot() -> dict:
    tasks = list_tasks()
    running_ids = [task["id"] for task in tasks if task["status"] in ("running", "waiting")]
    with STATE["lock"]:
        current = STATE["currentTaskId"]
        if not current:
            current = (running_ids[0] if running_ids else (tasks[0]["id"] if tasks else None))
            STATE["currentTaskId"] = current
        if current and all(task["id"] != current for task in tasks) and tasks:
            current = running_ids[0] if running_ids else tasks[0]["id"]
            STATE["currentTaskId"] = current
        revision = STATE["revision"]
        last_event = STATE["lastEvent"]
    running = any(task["id"] == current and task["status"] in ("running", "waiting") for task in tasks)
    workspace = tasks[0]["workspacePath"] if tasks else None
    return {
        "revision": revision,
        "health": {
            "ok": True,
            "desktopOnline": desktop_online(),
            "version": "1.0.0",
            "workspace": workspace,
            "lanAddresses": lan_addresses(),
        },
        "tasks": tasks,
        "currentTaskId": current,
        "messages": load_messages(current) if current else [],
        "running": running,
        "lastEvent": last_event,
    }


def bump(event: str) -> None:
    with STATE["lock"]:
        STATE["revision"] += 1
        STATE["lastEvent"] = event


def append_inbox(item: dict) -> None:
    INBOX.parent.mkdir(parents=True, exist_ok=True)
    with INBOX.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(item, ensure_ascii=False) + "\n")


def post_json(url: str, body: dict, headers: dict | None = None) -> tuple[bool, str]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    for key, value in (headers or {}).items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=8) as response:
            return True, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        return False, f"HTTP {exc.code}: {exc.read().decode('utf-8', errors='replace')[:300]}"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)


def send_zcode_text(text: str) -> tuple[bool, str]:
    callback = (CFG.get("zcodeCallbackUrl") or "").strip()
    bot_id = (CFG.get("zcodeBotId") or "").strip()
    user_id = CFG.get("zcodeUserId") or "zcode-mobile"
    secret = (CFG.get("zcodeWebhookSecret") or "").strip()
    if callback and bot_id:
        headers = {}
        if secret:
            headers["x-zcode-bot-secret"] = secret
            headers["webhookSecret"] = secret
        ok, detail = post_json(
            callback,
            {
                "botId": bot_id,
                "userId": user_id,
                "text": text,
                "chatType": "private",
                "displayName": "ZCode Mobile",
                "messageId": str(uuid.uuid4()),
                "webhookSecret": secret,
            },
            headers,
        )
        if ok:
            return True, "webhook"
        return False, detail
    return enqueue_session_input(text)


def enqueue_session_input(text: str) -> tuple[bool, str]:
    task_id = STATE["currentTaskId"]
    if not task_id:
        return False, "没有当前任务"
    con = connect_rw(CLI_DB)
    if con is None:
        return False, "找不到 ZCode 会话数据库"
    now = int(time.time() * 1000)
    queue_id = f"queue_{uuid.uuid4()}"
    command_id = uuid.uuid4().hex
    payload = {
        "text": text,
        "intent": {
            "sourceCommandId": command_id,
            "queueItemId": queue_id,
            "clientId": "zcode-mobile",
            "kind": "sendText",
            "admissionSeq": 1,
            "admittedAt": now,
            "requestedDelivery": "startNow",
            "admittedDelivery": "startNow",
            "attachmentRefs": [],
        },
        "conversationInputIntent": {
            "sourceCommandId": command_id,
            "queueItemId": queue_id,
            "clientId": "zcode-mobile",
            "kind": "sendText",
            "text": text,
            "attachments": [],
            "delivery": {"requested": "startNow", "admitted": "startNow"},
            "order": {"admissionSeq": 1},
            "steer": {"state": "notRequested"},
            "dispatch": {"state": "admitted"},
            "admittedAt": now,
        },
        "attachments": [],
        "sourceCommandType": "sendText",
    }
    try:
        seq = con.execute(
            "select coalesce(max(admitted_sequence), 0) from session_input where session_id = ?",
            (task_id,),
        ).fetchone()[0]
        con.execute(
            """
            insert into session_input (
                id, session_id, kind, delivery, payload, admitted_sequence,
                promoted_sequence, promoted_message_id, status, status_reason,
                time_created, time_updated
            ) values (?, ?, 'sendText', 'startNow', ?, ?, null, null, 'admitted', null, ?, ?)
            """,
            (queue_id, task_id, json.dumps(payload, ensure_ascii=False), int(seq) + 1, now, now),
        )
        con.commit()
        return True, "session_input"
    except Exception as exc:  # noqa: BLE001
        return False, str(exc)
    finally:
        con.close()


def bark(title: str, body: str) -> None:
    if not CFG.get("barkEnabled"):
        return
    url = (CFG.get("barkUrl") or "").strip().rstrip("/")
    if not url:
        return
    encoded_title = urllib.parse.quote(title)
    encoded_body = urllib.parse.quote(body[:180])
    target = f"{url}/{encoded_title}/{encoded_body}"
    try:
        urllib.request.urlopen(target, timeout=6).read()
    except Exception:
        pass


def watch_tasks() -> None:
    while True:
        try:
            tasks = list_tasks()
            changed = False
            with STATE["lock"]:
                known = STATE["known"]
                for task in tasks:
                    previous = known.get(task["id"])
                    if previous != task["status"]:
                        known[task["id"]] = task["status"]
                        changed = True
                        if previous in ("running", "waiting") and task["status"] not in ("running", "waiting"):
                            key = task["id"] + task["status"]
                            if key not in STATE["barkSent"]:
                                STATE["barkSent"].add(key)
                                title = "任务出错" if task["status"] == "error" else "任务完成"
                                threading.Thread(target=bark, args=(title, task["title"]), daemon=True).start()
                if STATE["currentTaskId"] is None and tasks:
                    STATE["currentTaskId"] = tasks[0]["id"]
                    changed = True
            if changed:
                bump("tasks")
        except Exception:
            pass
        time.sleep(1.0)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:
        return

    def _auth(self) -> bool:
        token = CFG.get("token") or ""
        got = self.headers.get("x-zcode-mobile-token") or ""
        return got == token

    def _read_json(self) -> dict:
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if not raw:
            return {}
        return json.loads(raw.decode("utf-8"))

    def _send(self, code: int, payload: dict) -> None:
        data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, x-zcode-mobile-token")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        if self.path.startswith("/v1/snapshot"):
            if not self._auth():
                self._send(401, {"ok": False, "error": "token mismatch"})
                return
            self._send(200, snapshot())
            return
        if self.path == "/health":
            self._send(200, {"ok": True, "addresses": lan_addresses(), "port": CFG["port"]})
            return
        self._send(404, {"ok": False, "error": "not found"})

    def do_POST(self) -> None:  # noqa: N802
        if self.path == "/zcode/outbound":
            body = self._read_json()
            append_inbox({"kind": "outbound", "body": body, "at": int(time.time() * 1000)})
            bump("outbound")
            self._send(200, {"ok": True})
            return
        if not self._auth():
            self._send(401, {"ok": False, "error": "token mismatch"})
            return
        body = self._read_json()
        if self.path == "/v1/send":
            text = (body.get("text") or "").strip()
            task_id = body.get("taskId")
            if task_id:
                with STATE["lock"]:
                    STATE["currentTaskId"] = task_id
            if not text:
                self._send(400, {"ok": False, "error": "empty text"})
                return
            append_inbox({"kind": "send", "text": text, "taskId": STATE["currentTaskId"]})
            ok, detail = send_zcode_text(text)
            bump("send")
            self._send(200 if ok else 500, {"ok": ok, "taskId": STATE["currentTaskId"], "error": None if ok else detail})
            return
        if self.path == "/v1/command":
            name = (body.get("name") or "").strip()
            value = body.get("value")
            task_id = body.get("taskId")
            if task_id:
                with STATE["lock"]:
                    STATE["currentTaskId"] = task_id
            if name == "open" and task_id:
                bump("open")
                self._send(200, {"ok": True, "taskId": task_id})
                return
            if name == "new":
                ok, detail = send_zcode_text("/new")
                bump("new")
                self._send(200 if ok else 500, {"ok": ok, "error": None if ok else detail})
                return
            if name == "stop":
                ok, detail = send_zcode_text("/stop")
                bump("stop")
                self._send(200 if ok else 500, {"ok": ok, "error": None if ok else detail})
                return
            if name and value:
                ok, detail = send_zcode_text(f"/{name} {value}")
            elif name:
                ok, detail = send_zcode_text(f"/{name}")
            else:
                ok, detail = False, "missing command"
            bump("command")
            self._send(200 if ok else 500, {"ok": ok, "error": None if ok else detail})
            return
        if self.path == "/v1/settings":
            CFG["barkEnabled"] = bool(body.get("enabled"))
            if "url" in body:
                CFG["barkUrl"] = str(body.get("url") or "")
            CONFIG_PATH.write_text(json.dumps(CFG, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            self._send(200, {"ok": True})
            return
        self._send(404, {"ok": False, "error": "not found"})


def main() -> None:
    threading.Thread(target=watch_tasks, daemon=True).start()
    server = ThreadingHTTPServer(("0.0.0.0", int(CFG["port"])), Handler)
    addrs = lan_addresses()
    print("ZCode Mobile bridge")
    print(f"  port    {CFG['port']}")
    print(f"  token   {CFG['token']}")
    for ip in addrs:
        print(f"  url     http://{ip}:{CFG['port']}")
    print("Fill these into the iOS app settings.")
    if not CFG.get("zcodeCallbackUrl"):
        print("Optional: set zcodeCallbackUrl / zcodeBotId / zcodeWebhookSecret in bridge/config.json")
        print("to send through ZCode's webhook bot. Without that, send uses session_input.")
    server.serve_forever()


if __name__ == "__main__":
    main()
