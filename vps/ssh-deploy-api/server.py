#!/usr/bin/env python3
"""
ssh-deploy 设备目录 API.

Devices API (全部要求 Authorization: Bearer <token>):
  GET  /device/list                 列出全部设备
  GET  /device/changes?since=&wait= 长轮询设备变更 (since=ISO ts, wait=秒, 最长 35)
  POST /device/register             注册设备 {device_id, device_name, capabilities}
  POST /device/heartbeat            心跳 (仅 device_id)
  POST /device/deregister           注销 {device_id}
  POST /shared/create               创建共享 {folder_id, name}
  POST /shared/join                 加入共享 {device_id, folder_id, folder_path}
  POST /shared/leave                退出共享 {device_id, folder_id}
  GET  /shared/list                 列出全部共享
  GET  /healthz                     健康检查 (免鉴权)

数据文件:
  /var/lib/ssh-deploy/devices.json  设备清单 (含 capabilities)
  /var/lib/ssh-deploy/shared.json   共享 folder 元数据 (跨设备)

并发: ThreadingHTTPServer 串行 accept, 内置 condition 变量用于 long polling 唤醒.
"""

import json
import os
import sys
import threading
import time
import hmac
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

DATA_DIR = os.environ.get("SSH_DEPLOY_DATA_DIR", "/var/lib/ssh-deploy")
DEVICE_FILE = os.path.join(DATA_DIR, "devices.json")
SHARED_FILE = os.path.join(DATA_DIR, "shared.json")
TOKEN = os.environ.get("BEARER_TOKEN", "").strip()
LISTEN_PORT = int(os.environ.get("API_PORT", "8081"))

# Long polling 唤醒
_change_event = threading.Event()
_lock = threading.Lock()
_waiters = []  # [(since_ts, event)]


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(s):
    """ISO ts → epoch 秒. 失败返 0."""
    if not s:
        return 0
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return 0


def _load(file_path, default):
    if not os.path.exists(file_path):
        return default
    with open(file_path, "r", encoding="utf-8") as f:
        return json.load(f)


def _save(file_path, data):
    tmp = file_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, file_path)
    try:
        os.chmod(file_path, 0o640)
    except OSError:
        pass


def _devices():
    return _load(DEVICE_FILE, {"version": "1.0", "devices": []})


def _save_devices(d):
    _save(DEVICE_FILE, d)
    _wake_waiters()


def _shared():
    return _load(SHARED_FILE, {"version": "1.0", "folders": []})


def _save_shared(s):
    _save(SHARED_FILE, s)
    _wake_waiters()


def _wake_waiters():
    """变更发生 → 唤醒所有 wait 中的长轮询."""
    _change_event.set()
    # 让 waiter 自己处理 event, 不在这里做


def _collect_changes_since(since_ts):
    """收集 since_ts 之后所有 device + shared 的变更 (内存事件流 + 当前快照)."""
    changes = []
    now = _now_iso()

    dev = _devices()
    for d in dev.get("devices", []):
        d_ts = _parse_ts(d.get("last_update", d.get("registered_at")))
        if d_ts > since_ts:
            changes.append({
                "op": "register" if d.get("registered_at") and not d.get("updated_at") else "update",
                "device_id": d["device_id"],
                "device_name": d["device_name"],
                "capabilities": d.get("capabilities", {}),
                "online": d.get("online", True),
                "ts": now,
            })

    shr = _shared()
    for s in shr.get("folders", []):
        s_ts = _parse_ts(s.get("updated_at", s.get("created_at")))
        if s_ts > since_ts:
            changes.append({
                "op": "shared_update",
                "folder_id": s["folder_id"],
                "name": s["name"],
                "members": s.get("members", []),
                "ts": now,
            })

    return changes


def _check_auth(handler):
    if not TOKEN:
        handler.send_response(503)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(b'{"error":"server token not configured"}')
        return False
    auth = handler.headers.get("Authorization", "")
    expected = f"Bearer {TOKEN}"
    if not hmac.compare_digest(auth, expected):
        handler.send_response(403)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(b'{"error":"forbidden"}')
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write(f"[{self.log_date_time_string()}] {fmt % args}\n")

    def _send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError as e:
            self._send_json(400, {"error": f"invalid json: {e}"})
            return None

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/healthz":
            self._send_json(200, {"ok": True, "ts": _now_iso()})
            return

        if not _check_auth(self):
            return

        if path == "/device/list":
            self._send_json(200, _devices())
            return

        if path == "/device/changes":
            since = float(qs.get("since", ["0"])[0] or 0)
            wait = min(int(qs.get("wait", ["30"])[0] or 30), 35)
            # 先看是否已有变更
            changes = _collect_changes_since(since)
            if changes:
                self._send_json(200, {"changes": changes, "ts": _now_iso()})
                return
            # 没有变更, 长轮询 — 等 _wake_waiters() 或超时
            evt = threading.Event()
            with _lock:
                _waiters.append((since, evt, self))
            if evt.wait(timeout=wait):
                # 被唤醒
                pass
            else:
                # 超时, 正常返空
                pass
            with _lock:
                if (since, evt, self) in _waiters:
                    _waiters.remove((since, evt, self))
            # 重新查一次 (唤醒后可能已经有变更)
            changes = _collect_changes_since(since)
            self._send_json(200, {"changes": changes, "ts": _now_iso()})
            return

        if path == "/shared/list":
            self._send_json(200, _shared())
            return

        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if not _check_auth(self):
            return
        body = self._read_body()
        if body is None:
            return

        if path == "/device/register":
            self._device_register(body)
        elif path == "/device/heartbeat":
            self._device_heartbeat(body)
        elif path == "/device/deregister":
            self._device_deregister(body)
        elif path == "/shared/create":
            self._shared_create(body)
        elif path == "/shared/join":
            self._shared_join(body)
        elif path == "/shared/leave":
            self._shared_leave(body)
        else:
            self._send_json(404, {"error": "not found"})

    # ----- device handlers -----
    def _device_register(self, body):
        device_id = str(body.get("device_id", "")).strip()
        device_name = str(body.get("device_name", "")).strip()
        caps = body.get("capabilities", {})
        if not device_id or not device_name:
            self._send_json(400, {"error": "device_id and device_name required"})
            return
        with _lock:
            data = _devices()
            now = _now_iso()
            existing = next((d for d in data["devices"] if d["device_id"] == device_id), None)
            if existing:
                existing.update({
                    "device_name": device_name,
                    "capabilities": caps,
                    "last_update": now,
                    "last_seen": now,
                    "online": True,
                })
            else:
                data["devices"].append({
                    "device_id": device_id,
                    "device_name": device_name,
                    "capabilities": caps,
                    "registered_at": now,
                    "last_update": now,
                    "last_seen": now,
                    "online": True,
                })
            # 在 lock 外保存 (避免 _save_devices → _wake_waiters → 后续 _wake_all lock 重入死锁)
        _save_devices(data)
        _wake_all()
        self._send_json(200, {"ok": True, "device_name": device_name})

    def _device_heartbeat(self, body):
        device_id = str(body.get("device_id", "")).strip()
        if not device_id:
            self._send_json(400, {"error": "device_id required"})
            return
        need_wake = False
        with _lock:
            data = _devices()
            now = _now_iso()
            d = next((x for x in data["devices"] if x["device_id"] == device_id), None)
            if d:
                was_offline = not d.get("online", True)
                d["last_seen"] = now
                d["online"] = True
                if was_offline:
                    _save_devices(data)
                    need_wake = True
            else:
                self._send_json(404, {"error": "device not registered"})
                return
        if need_wake:
            _wake_all()
        self._send_json(200, {"ok": True})

    def _device_deregister(self, body):
        device_id = str(body.get("device_id", "")).strip()
        if not device_id:
            self._send_json(400, {"error": "device_id required"})
            return
        with _lock:
            data = _devices()
            before = len(data["devices"])
            data["devices"] = [d for d in data["devices"] if d["device_id"] != device_id]
            after = len(data["devices"])
            if before == after:
                self._send_json(404, {"error": "device not found"})
                return
            # 同时从 shared folders 移除
            shr = _shared()
            for s in shr.get("folders", []):
                s["members"] = [m for m in s.get("members", []) if m.get("device_id") != device_id]
            _save_shared(shr)
            _save_devices(data)
        # NOTE: 不在 lock 内调 _wake_all(), 会死锁 (Python Lock 不可重入)
        _wake_all()
        self._send_json(200, {"ok": True, "removed": before - after})

    # ----- shared handlers -----
    def _shared_create(self, body):
        folder_id = str(body.get("folder_id", "")).strip()
        name = str(body.get("name", folder_id)).strip()
        if not folder_id:
            self._send_json(400, {"error": "folder_id required"})
            return
        with _lock:
            shr = _shared()
            if any(s["folder_id"] == folder_id for s in shr["folders"]):
                self._send_json(409, {"error": "folder_id_exists"})
                return
            now = _now_iso()
            shr["folders"].append({
                "folder_id": folder_id,
                "name": name,
                "members": [],
                "created_at": now,
                "updated_at": now,
            })
            _save_shared(shr)
        _wake_all()
        self._send_json(200, {"ok": True, "folder_id": folder_id})

    def _shared_join(self, body):
        device_id = str(body.get("device_id", "")).strip()
        folder_id = str(body.get("folder_id", "")).strip()
        folder_path = str(body.get("folder_path", "")).strip()
        if not device_id or not folder_id:
            self._send_json(400, {"error": "device_id and folder_id required"})
            return
        with _lock:
            shr = _shared()
            folder = next((s for s in shr["folders"] if s["folder_id"] == folder_id), None)
            if not folder:
                self._send_json(404, {"error": "folder_not_found"})
                return
            now = _now_iso()
            existing = next((m for m in folder["members"] if m["device_id"] == device_id), None)
            if existing:
                existing["folder_path"] = folder_path
                existing["joined_at"] = now
            else:
                folder["members"].append({
                    "device_id": device_id,
                    "folder_path": folder_path,
                    "joined_at": now,
                })
            folder["updated_at"] = now
            _save_shared(shr)
            # 同步把 device.capabilities.syncthing.folders 加上
            data = _devices()
            dev = next((d for d in data["devices"] if d["device_id"] == device_id), None)
            if dev:
                folders = dev.setdefault("capabilities", {}).setdefault("syncthing", {}).setdefault("folders", [])
                if folder_id not in folders:
                    folders.append(folder_id)
                dev["last_update"] = now
                dev["online"] = True
                _save_devices(data)
        _wake_all()
        self._send_json(200, {"ok": True, "members": folder["members"]})

    def _shared_leave(self, body):
        device_id = str(body.get("device_id", "")).strip()
        folder_id = str(body.get("folder_id", "")).strip()
        if not device_id or not folder_id:
            self._send_json(400, {"error": "device_id and folder_id required"})
            return
        with _lock:
            shr = _shared()
            folder = next((s for s in shr["folders"] if s["folder_id"] == folder_id), None)
            if not folder:
                self._send_json(404, {"error": "folder_not_found"})
                return
            before = len(folder["members"])
            folder["members"] = [m for m in folder["members"] if m["device_id"] != device_id]
            after = len(folder["members"])
            folder["updated_at"] = _now_iso()
            _save_shared(shr)
            data = _devices()
            dev = next((d for d in data["devices"] if d["device_id"] == device_id), None)
            if dev:
                folders = dev.get("capabilities", {}).get("syncthing", {}).get("folders", [])
                if folder_id in folders:
                    folders.remove(folder_id)
                dev["last_update"] = _now_iso()
                _save_devices(data)
        _wake_all()
        self._send_json(200, {"ok": True, "removed": before - after})


def _heartbeat_checker():
    """后台线程: 每 15s 检查设备心跳, 60s 没上报 → 标记 offline, 唤醒 waiter."""
    while True:
        time.sleep(15)
        with _lock:
            data = _devices()
            now_ts = time.time()
            changed = False
            for d in data["devices"]:
                last = _parse_ts(d.get("last_seen"))
                if d.get("online", True) and (now_ts - last) > 60:
                    d["online"] = False
                    d["last_update"] = _now_iso()
                    changed = True
            if changed:
                _save_devices(data)
                _wake_all()


def _wake_all():
    """唤醒所有 waiter."""
    with _lock:
        for entry in list(_waiters):
            _waiters.remove(entry)
            since_ts, evt, _handler = entry
            evt.set()


def main():
    if not TOKEN:
        print("ERROR: BEARER_TOKEN env not set", file=sys.stderr)
        sys.exit(1)
    os.makedirs(DATA_DIR, exist_ok=True)
    # 初始化空文件
    for path, default in [(DEVICE_FILE, {"version": "1.0", "devices": []}),
                           (SHARED_FILE, {"version": "1.0", "folders": []})]:
        if not os.path.exists(path):
            _save(path, default)
        try:
            os.chmod(path, 0o640)
        except OSError:
            pass

    threading.Thread(target=_heartbeat_checker, daemon=True).start()

    addr = ("127.0.0.1", LISTEN_PORT)
    print(f"ssh-deploy-api listening on {addr[0]}:{addr[1]}", file=sys.stderr)
    print(f"data: {DATA_DIR}", file=sys.stderr)
    srv = ThreadingHTTPServer(addr, Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()