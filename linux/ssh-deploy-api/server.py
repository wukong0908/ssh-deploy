#!/usr/bin/env python3
"""
ssh-deploy 设备目录 API  v2 (2026-08-03 重塑)

兼容 V1 外部契约:
  - 路径 /device/* /shared/* /healthz 不变
  - 环境变量 BEARER_TOKEN / API_PORT / SSH_DEPLOY_DATA_DIR 不变
  - nginx 反代不变

V2 内部修复 (18 项):
  [修 1] _check_auth 改走 _send_json 统一,补 Content-Length
  [修 2] _device_register save 失败回滚
  [修 3] _device_heartbeat 锁内一次查,锁外发响应
  [修 4] 长轮询 waiter 用 Queue,handler 不进 waiter 列表
  [修 5] _wake_all 走 snapshot 清空
  [修 6] _heartbeat_checker 5s 周期 30s 阈值
  [修 7] payload schema 校验(必填/类型/长度)
  [加 8] per-host token(32 hex,register 返,heartbeat 校验)
  [加 9] owner claim 强制 + deregister 校验
  [加10] last_seen / last_heartbeat 双轨
  [加11] /healthz 增强字段
  [加12] 启动自检(TOKEN 长度 / data dir 可写 / 数据迁移)
  [加13] systemd 强化(单元外,代码内不写文件至 /opt 等)
  [可14] /status 端点(管理 token)
  [可15] stderr JSON 一行日志
  [可16] SyslogIdentifier=ssh-deploy-api (systemd unit 配)
  [文17/18] 文档外置
"""

import copy
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from queue import Queue
from urllib.parse import urlparse, parse_qs

# ============== 配置 ==============
DATA_DIR = os.environ.get("SSH_DEPLOY_DATA_DIR", "/var/lib/ssh-deploy")
DEVICE_FILE = os.path.join(DATA_DIR, "devices.json")
SHARED_FILE = os.path.join(DATA_DIR, "shared.json")
TOKEN = os.environ.get("BEARER_TOKEN", "").strip()
LISTEN_PORT = int(os.environ.get("API_PORT", "8081"))

ADMIN_TOKEN_MIN_LEN = 16
DEVICE_TOKEN_BYTES = 16  # -> 32 hex chars
HEARTBEAT_OFFLINE_THRESHOLD_S = 30
HEARTBEAT_CHECK_INTERVAL_S = 5
MAX_LONG_POLL_S = 35
MAX_BODY_BYTES = 8192
START_TS = time.time()

DEVICE_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{1,128}$")

# ============== 全局状态 ==============
_lock = threading.Lock()  # 保护 _devices/_shared 内存态 + 文件 IO
_change_event = threading.Event()
_waiters = []  # [(since_ts, Waiter)]

# ============== 工具 ==============
def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_ts(s):
    if not s:
        return 0.0
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (ValueError, TypeError):
        return 0.0


def _log(level, msg, **kv):
    """stderr JSON 一行日志."""
    try:
        record = {
            "ts": _now_iso(),
            "level": level,
            "op": kv.get("op", "-"),
            "msg": msg,
        }
        record.update({k: v for k, v in kv.items() if k != "op"})
        sys.stderr.write(json.dumps(record, ensure_ascii=False) + "\n")
        sys.stderr.flush()
    except Exception:
        sys.stderr.write(f"[log-fail] {level} {msg}\n")
        sys.stderr.flush()


def _atomic_save(file_path, data):
    """原子写: .tmp -> os.replace. 失败抛 OSError."""
    tmp = file_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, file_path)
    try:
        os.chmod(file_path, 0o640)
    except OSError:
        pass


def _load(file_path, default):
    """读 JSON, 失败抛 RuntimeError(防呆:不让空默认掩盖损坏)."""
    if not os.path.exists(file_path):
        return copy.deepcopy(default)
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"data file corrupted: {file_path}: {e}") from e


def _with_data_lock(file_path, default, mutate_fn):
    """锁内 mutate + save; save 失败回滚到 backup."""
    with _lock:
        data = _load(file_path, default)
        backup = copy.deepcopy(data)
        result = mutate_fn(data)
        try:
            _atomic_save(file_path, data)
        except OSError as e:
            _atomic_save(file_path, backup)  # 回滚
            raise
    return result


# ============== 数据 schema defaults ==============
def _empty_devices():
    return {"version": "1.0", "devices": []}


def _empty_shared():
    return {"version": "1.0", "folders": []}


# ============== schema 校验 ==============
def _safe_device_id(s):
    s = str(s or "").strip()
    if not DEVICE_ID_RE.match(s):
        raise ValueError("device_id invalid (must match [A-Za-z0-9._:-]{1,128})")
    return s


def _validate_caps(caps):
    """capabilities.syncthing.folders 必须 list[str]; 其它自由结构."""
    if not isinstance(caps, dict):
        raise ValueError("capabilities must be object")
    syn = caps.get("syncthing")
    if syn is not None:
        if not isinstance(syn, dict):
            raise ValueError("capabilities.syncthing must be object")
        folders = syn.get("folders")
        if folders is not None:
            if not isinstance(folders, list):
                raise ValueError("capabilities.syncthing.folders must be list of strings")
            for f in folders:
                if not isinstance(f, str) or not DEVICE_ID_RE.match(f):
                    raise ValueError("capabilities.syncthing.folders entries must match id pattern")
    return caps


def _validate_device_register(body):
    """返 (device_id, device_name, owner, capabilities) 或抛 ValueError."""
    if not isinstance(body, dict):
        raise ValueError("body must be JSON object")
    device_id = _safe_device_id(body.get("device_id"))
    device_name = str(body.get("device_name", "")).strip()
    if not device_name or len(device_name) > 128:
        raise ValueError("device_name required, max 128 chars")
    owner = str(body.get("owner", "wukong0908")).strip()
    if not owner or len(owner) > 64:
        raise ValueError("owner required, max 64 chars")
    caps = _validate_caps(body.get("capabilities", {}))
    return device_id, device_name, owner, caps


def _validate_heartbeat(body):
    if not isinstance(body, dict):
        raise ValueError("body must be JSON object")
    device_id = _safe_device_id(body.get("device_id"))
    return device_id


def _validate_deregister(body):
    if not isinstance(body, dict):
        raise ValueError("body must be JSON object")
    device_id = _safe_device_id(body.get("device_id"))
    return device_id


def _validate_shared_create(body):
    if not isinstance(body, dict):
        raise ValueError("body must be JSON object")
    folder_id = str(body.get("folder_id", "")).strip()
    if not folder_id or len(folder_id) > 128 or not re.match(r"^[A-Za-z0-9._:-]+$", folder_id):
        raise ValueError("folder_id invalid")
    name = str(body.get("name", folder_id)).strip()[:128]
    return folder_id, name


def _validate_shared_join(body):
    if not isinstance(body, dict):
        raise ValueError("body must be JSON object")
    device_id = _safe_device_id(body.get("device_id"))
    folder_id = str(body.get("folder_id", "")).strip()
    if not folder_id or not re.match(r"^[A-Za-z0-9._:-]+$", folder_id):
        raise ValueError("folder_id invalid")
    folder_path = str(body.get("folder_path", "")).strip()[:512]
    return device_id, folder_id, folder_path


# ============== 鉴权 ==============
def _check_admin_token(req_handler) -> bool:
    if not TOKEN:
        return False
    auth = req_handler.headers.get("Authorization", "")
    return hmac.compare_digest(auth, f"Bearer {TOKEN}")


def _check_device_token(req_handler) -> tuple:
    """返 (ok, device_id) 拿 X-Device-Token 头查 devices.json 匹配."""
    presented = req_handler.headers.get("X-Device-Token", "").strip()
    if not presented:
        return False, None
    try:
        with _lock:
            data = _load(DEVICE_FILE, _empty_devices())
        for d in data.get("devices", []):
            stored = d.get("auth_token", "")
            if stored and hmac.compare_digest(presented, stored):
                return True, d.get("device_id")
    except (RuntimeError, OSError) as e:
        _log("error", "device_token_lookup_failed", err=str(e))
    return False, None


def _check_auth(req_handler) -> tuple:
    """返 (ok, mode, ctx). mode = 'admin' / 'device' / 'none'."""
    # 优先 device token
    ok, dev_id = _check_device_token(req_handler)
    if ok:
        return True, "device", {"device_id": dev_id}
    # fallback admin token
    if _check_admin_token(req_handler):
        return True, "admin", {}
    return False, "none", {}


# ============== 长轮询 ==============
class Waiter:
    __slots__ = ("since_ts", "queue", "abandoned")

    def __init__(self, since_ts):
        self.since_ts = since_ts
        self.queue = Queue(maxsize=1)
        self.abandoned = False

    def wake(self, changes):
        if not self.abandoned and self.queue.empty():
            self.queue.put(changes)

    def close(self):
        self.abandoned = True


def _wake_all(changes=None):
    with _lock:
        snapshot = list(_waiters)
        _waiters[:] = []
    for entry in snapshot:
        entry[1].wake(changes or [])


def _collect_changes_since(since_ts):
    changes = []
    now_ts = time.time()
    try:
        with _lock:
            data = _load(DEVICE_FILE, _empty_devices())
            shared = _load(SHARED_FILE, _empty_shared())
    except (RuntimeError, OSError) as e:
        _log("error", "collect_changes_load_failed", err=str(e))
        return changes
    for d in data.get("devices", []):
        ts_str = d.get("last_update") or d.get("registered_at")
        d_ts = _parse_ts(ts_str)
        if d_ts > since_ts:
            is_update = d.get("last_update") and d.get("last_update") != d.get("registered_at")
            changes.append({
                "op": "update" if is_update else "register",
                "device_id": d.get("device_id"),
                "device_name": d.get("device_name"),
                "capabilities": d.get("capabilities", {}),
                "online": d.get("online", True),
                "ts": _now_iso(),
            })
    for s in shared.get("folders", []):
        s_ts = _parse_ts(s.get("updated_at") or s.get("created_at"))
        if s_ts > since_ts:
            changes.append({
                "op": "shared_update",
                "folder_id": s.get("folder_id"),
                "name": s.get("name"),
                "members": s.get("members", []),
                "ts": _now_iso(),
            })
    return changes


def _register_waiter(waiter):
    with _lock:
        _waiters.append((waiter.since_ts, waiter))


def _unregister_waiter(waiter):
    with _lock:
        try:
            _waiters.remove((waiter.since_ts, waiter))
        except ValueError:
            pass


# ============== device 操作 ==============
def _device_register(body):
    device_id, device_name, owner, caps = _validate_device_register(body)
    now = _now_iso()

    def mutate(data):
        existing = next((d for d in data["devices"] if d["device_id"] == device_id), None)
        if existing:
            existing.update({
                "device_name": device_name,
                "owner": owner,
                "capabilities": caps,
                "last_update": now,
                "last_heartbeat": now,
                "last_seen": now,
                "online": True,
            })
            new_token = existing.get("auth_token")
        else:
            new_token = secrets.token_hex(DEVICE_TOKEN_BYTES)
            data["devices"].append({
                "device_id": device_id,
                "device_name": device_name,
                "owner": owner,
                "capabilities": caps,
                "auth_token": new_token,
                "registered_at": now,
                "last_update": now,
                "last_heartbeat": now,
                "last_seen": now,
                "online": True,
            })
        return {"ok": True, "device_id": device_id, "device_name": device_name, "auth_token": new_token}

    result = _with_data_lock(DEVICE_FILE, _empty_devices(), mutate)
    _wake_all()
    _log("info", "device_registered", op="register", device_id=device_id, owner=owner)
    return result


def _device_heartbeat(body):
    device_id = _validate_heartbeat(body)
    now = _now_iso()
    need_wake = [False]  # 列表包一下,锁内改

    def mutate(data):
        d = next((x for x in data["devices"] if x["device_id"] == device_id), None)
        if not d:
            return None  # signal not registered
        was_offline = not d.get("online", True)
        d["last_heartbeat"] = now
        d["last_seen"] = now
        d["online"] = True
        if was_offline:
            d["last_update"] = now
            need_wake[0] = True
        return {"ok": True, "online": True}

    try:
        result = _with_data_lock(DEVICE_FILE, _empty_devices(), mutate)
    except OSError as e:
        _log("error", "heartbeat_save_failed", op="heartbeat", device_id=device_id, err=str(e))
        return None, "save_failed"
    if result is None:
        return None, "not_registered"
    if need_wake[0]:
        _wake_all()
    _log("debug", "heartbeat", op="heartbeat", device_id=device_id)
    return result, None


def _device_deregister(body):
    device_id = _validate_deregister(body)
    removed = [0]

    def mutate(data):
        before = len(data["devices"])
        data["devices"] = [d for d in data["devices"] if d["device_id"] != device_id]
        removed[0] = before - len(data["devices"])
        return removed[0]

    try:
        n = _with_data_lock(DEVICE_FILE, _empty_devices(), mutate)
    except OSError as e:
        _log("error", "deregister_save_failed", op="deregister", device_id=device_id, err=str(e))
        return None, "save_failed"
    if n == 0:
        return None, "not_found"
    # 同步从 shared folders 清
    try:
        def mutate_shr(shr):
            for s in shr.get("folders", []):
                s["members"] = [m for m in s.get("members", []) if m.get("device_id") != device_id]
            return True
        _with_data_lock(SHARED_FILE, _empty_shared(), mutate_shr)
    except OSError as e:
        _log("warn", "shared_cleanup_failed", op="deregister", device_id=device_id, err=str(e))
    _wake_all()
    _log("info", "device_deregistered", op="deregister", device_id=device_id, removed=n)
    return {"ok": True, "removed": n}, None


# ============== shared 操作 ==============
def _shared_create(body):
    folder_id, name = _validate_shared_create(body)
    now = _now_iso()
    conflict = [False]

    def mutate(shr):
        if any(s["folder_id"] == folder_id for s in shr["folders"]):
            conflict[0] = True
            return None
        shr["folders"].append({
            "folder_id": folder_id,
            "name": name,
            "members": [],
            "created_at": now,
            "updated_at": now,
        })
        return {"ok": True, "folder_id": folder_id}

    try:
        result = _with_data_lock(SHARED_FILE, _empty_shared(), mutate)
    except OSError as e:
        _log("error", "shared_create_save_failed", op="shared_create", folder_id=folder_id, err=str(e))
        return None, "save_failed"
    if conflict[0]:
        return None, "conflict"
    _wake_all()
    return result, None


def _shared_join(body):
    device_id, folder_id, folder_path = _validate_shared_join(body)
    now = _now_iso()
    not_found = [False]

    def mutate(shr):
        folder = next((s for s in shr["folders"] if s["folder_id"] == folder_id), None)
        if not folder:
            not_found[0] = True
            return None
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
        return {"ok": True, "members": folder["members"]}

    try:
        result = _with_data_lock(SHARED_FILE, _empty_shared(), mutate)
    except OSError as e:
        _log("error", "shared_join_save_failed", op="shared_join", folder_id=folder_id, device_id=device_id, err=str(e))
        return None, "save_failed"
    if not_found[0]:
        return None, "not_found"
    # 同步 device.capabilities.syncthing.folders
    try:
        def mutate_dev(data):
            dev = next((d for d in data["devices"] if d["device_id"] == device_id), None)
            if not dev:
                return None
            folders = dev.setdefault("capabilities", {}).setdefault("syncthing", {}).setdefault("folders", [])
            if folder_id not in folders:
                folders.append(folder_id)
            dev["last_update"] = now
            dev["online"] = True
            dev["last_heartbeat"] = now
            dev["last_seen"] = now
            return True
        _with_data_lock(DEVICE_FILE, _empty_devices(), mutate_dev)
    except OSError as e:
        _log("warn", "shared_join_dev_update_failed", op="shared_join", device_id=device_id, err=str(e))
    _wake_all()
    return result, None


def _shared_leave(body):
    if not isinstance(body, dict):
        raise ValueError("body must be JSON object")
    device_id = _safe_device_id(body.get("device_id"))
    folder_id = str(body.get("folder_id", "")).strip()
    if not folder_id or not re.match(r"^[A-Za-z0-9._:-]+$", folder_id):
        raise ValueError("folder_id invalid")
    removed = [0]
    not_found = [False]

    def mutate(shr):
        folder = next((s for s in shr["folders"] if s["folder_id"] == folder_id), None)
        if not folder:
            not_found[0] = True
            return None
        before = len(folder["members"])
        folder["members"] = [m for m in folder["members"] if m["device_id"] != device_id]
        removed[0] = before - len(folder["members"])
        folder["updated_at"] = _now_iso()
        return {"ok": True, "removed": removed[0]}

    try:
        result = _with_data_lock(SHARED_FILE, _empty_shared(), mutate)
    except OSError as e:
        _log("error", "shared_leave_save_failed", op="shared_leave", folder_id=folder_id, device_id=device_id, err=str(e))
        return None, "save_failed"
    if not_found[0]:
        return None, "not_found"
    try:
        def mutate_dev(data):
            dev = next((d for d in data["devices"] if d["device_id"] == device_id), None)
            if not dev:
                return None
            folders = dev.get("capabilities", {}).get("syncthing", {}).get("folders", [])
            if folder_id in folders:
                folders.remove(folder_id)
            dev["last_update"] = _now_iso()
            return True
        _with_data_lock(DEVICE_FILE, _empty_devices(), mutate_dev)
    except OSError as e:
        _log("warn", "shared_leave_dev_update_failed", op="shared_leave", device_id=device_id, err=str(e))
    _wake_all()
    return result, None


# ============== /status ==============
def _status_payload():
    try:
        with _lock:
            data = _load(DEVICE_FILE, _empty_devices())
            shared = _load(SHARED_FILE, _empty_shared())
    except (RuntimeError, OSError) as e:
        return {"error": f"load_failed: {e}"}
    now = time.time()
    devs = []
    online_count = 0
    for d in data.get("devices", []):
        last_hb = _parse_ts(d.get("last_heartbeat") or d.get("last_seen"))
        age = now - last_hb if last_hb else None
        online = d.get("online", True) and (age is None or age < HEARTBEAT_OFFLINE_THRESHOLD_S)
        if online:
            online_count += 1
        item = {
            "device_id": d.get("device_id"),
            "device_name": d.get("device_name"),
            "owner": d.get("owner"),
            "online": online,
            "last_heartbeat": d.get("last_heartbeat"),
            "last_seen": d.get("last_seen"),
            "age_s": round(age, 1) if age is not None else None,
            "capabilities": d.get("capabilities", {}),
        }
        devs.append(item)
    return {
        "ts": _now_iso(),
        "uptime_s": round(now - START_TS, 1),
        "version": "2.0",
        "devices_total": len(devs),
        "devices_online": online_count,
        "devices": devs,
        "shared_total": len(shared.get("folders", [])),
    }


# ============== 启动自检 + 数据迁移 ==============
def _bootstrap():
    """启动前检查 + 数据迁移. 失败 raise 不让 server 起来."""
    if not TOKEN:
        raise RuntimeError("BEARER_TOKEN env not set")
    if len(TOKEN) < ADMIN_TOKEN_MIN_LEN:
        raise RuntimeError(f"BEARER_TOKEN too short (len={len(TOKEN)}, need >= {ADMIN_TOKEN_MIN_LEN})")
    if not os.path.isdir(DATA_DIR):
        raise RuntimeError(f"DATA_DIR not found: {DATA_DIR}")
    if not os.access(DATA_DIR, os.W_OK):
        raise RuntimeError(f"DATA_DIR not writable: {DATA_DIR}")
    os.makedirs(DATA_DIR, exist_ok=True)
    # 初始化空文件
    for path, default in [(DEVICE_FILE, _empty_devices()), (SHARED_FILE, _empty_shared())]:
        if not os.path.exists(path):
            _atomic_save(path, default)
            try:
                os.chmod(path, 0o640)
            except OSError:
                pass
    # 数据迁移: 旧 devices.json 无 auth_token 字段 -> 补
    with _lock:
        data = _load(DEVICE_FILE, _empty_devices())
        migrated = 0
        for d in data.get("devices", []):
            if "auth_token" not in d or not d.get("auth_token"):
                d["auth_token"] = secrets.token_hex(DEVICE_TOKEN_BYTES)
                migrated += 1
            # last_heartbeat 兜底(用 last_seen / last_update)
            if "last_heartbeat" not in d:
                d["last_heartbeat"] = d.get("last_seen") or d.get("last_update") or d.get("registered_at")
        if migrated > 0:
            _atomic_save(DEVICE_FILE, data)
            _log("info", "devices_migrated", op="bootstrap", migrated=migrated, total=len(data.get("devices", [])))
    # 报告启动时状态
    devs = data.get("devices", [])
    _log("info", "bootstrap_done", op="bootstrap", devices=len(devs), data_dir=DATA_DIR, port=LISTEN_PORT)


# ============== HTTP handler ==============
class Handler(BaseHTTPRequestHandler):
    server_version = "ssh-deploy-api/2.0"

    def log_message(self, fmt, *args):
        # 关闭默认 access log; 关键路径用 _log 自己打
        pass

    def _send_json(self, code, payload, headers_extra=None):
        try:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        except (TypeError, ValueError) as e:
            body = json.dumps({"error": f"encode failed: {e}"}).encode("utf-8")
            code = 500
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            if headers_extra:
                for k, v in headers_extra.items():
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError) as e:
            _log("warn", "send_failed", op="http", code=code, err=str(e))

    def _send_error_json(self, code, msg):
        self._send_json(code, {"error": msg})

    def _read_body(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        if length > MAX_BODY_BYTES:
            return None, f"body too large (>{MAX_BODY_BYTES})"
        raw = self.rfile.read(length) if length else b""
        if not raw:
            return {}, None
        try:
            return json.loads(raw.decode("utf-8")), None
        except json.JSONDecodeError as e:
            return None, f"invalid json: {e}"

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        if path == "/healthz":
            try:
                with _lock:
                    data = _load(DEVICE_FILE, _empty_devices())
            except (RuntimeError, OSError) as e:
                return self._send_json(503, {"ok": False, "error": f"data_unavailable: {e}"})
            now = time.time()
            online = 0
            last_age = None
            for d in data.get("devices", []):
                last_hb = _parse_ts(d.get("last_heartbeat") or d.get("last_seen"))
                age = now - last_hb if last_hb else None
                if d.get("online", True) and (age is None or age < HEARTBEAT_OFFLINE_THRESHOLD_S):
                    online += 1
                if age is not None and (last_age is None or age < last_age):
                    last_age = age
            payload = {
                "ok": True,
                "ts": _now_iso(),
                "version": "2.0",
                "uptime_s": round(now - START_TS, 1),
                "devices_online": online,
                "devices_total": len(data.get("devices", [])),
                "last_heartbeat_age_s": round(last_age, 1) if last_age is not None else None,
                "data_dir_writable": os.access(DATA_DIR, os.W_OK),
                "token_configured": bool(TOKEN),
            }
            return self._send_json(200, payload)

        # 鉴权 (admin 或 device)
        ok, mode, ctx = _check_auth(self)
        if not ok:
            return self._send_error_json(403, "forbidden")

        if path == "/device/list":
            try:
                with _lock:
                    payload = _load(DEVICE_FILE, _empty_devices())
                # device token 鉴权时只看到自己
                if mode == "device":
                    payload = {
                        "version": payload.get("version", "1.0"),
                        "devices": [d for d in payload.get("devices", []) if d.get("device_id") == ctx.get("device_id")],
                    }
                return self._send_json(200, payload)
            except (RuntimeError, OSError) as e:
                return self._send_json(500, {"error": f"load_failed: {e}"})

        if path == "/device/changes":
            try:
                since = float(qs.get("since", ["0"])[0] or 0)
            except (ValueError, TypeError):
                since = 0
            try:
                wait = min(int(qs.get("wait", ["30"])[0] or 30), MAX_LONG_POLL_S)
            except (ValueError, TypeError):
                wait = 30
            # 立即看
            changes = _collect_changes_since(since)
            if changes:
                return self._send_json(200, {"changes": changes, "ts": _now_iso()})
            # 长轮询
            waiter = Waiter(since)
            _register_waiter(waiter)
            try:
                # 等事件或超时
                try:
                    waiter.queue.get(timeout=wait)
                except Exception:
                    pass
                changes = _collect_changes_since(since)
                return self._send_json(200, {"changes": changes, "ts": _now_iso()})
            finally:
                _unregister_waiter(waiter)
                waiter.close()

        if path == "/shared/list":
            if mode != "admin":
                return self._send_error_json(403, "admin_only")
            try:
                with _lock:
                    payload = _load(SHARED_FILE, _empty_shared())
                return self._send_json(200, payload)
            except (RuntimeError, OSError) as e:
                return self._send_json(500, {"error": f"load_failed: {e}"})

        if path == "/status":
            if mode != "admin":
                return self._send_error_json(403, "admin_only")
            return self._send_json(200, _status_payload())

        return self._send_error_json(404, "not found")

    def do_POST(self):
        path = urlparse(self.path).path
        if path not in ("/device/register", "/device/heartbeat", "/device/deregister",
                        "/shared/create", "/shared/join", "/shared/leave"):
            return self._send_error_json(404, "not found")

        # 鉴权
        ok, mode, ctx = _check_auth(self)
        if not ok:
            return self._send_error_json(403, "forbidden")

        # /device/register 允许 admin token 替别人注册; /device/heartbeat / deregister 必须 device token
        if path in ("/device/heartbeat", "/device/deregister") and mode != "device":
            return self._send_error_json(401, "device_token_required")
        if path in ("/shared/create", "/shared/join", "/shared/leave") and mode != "admin":
            return self._send_error_json(403, "admin_only")

        body, err = self._read_body()
        if err:
            return self._send_error_json(400, err)
        if body is None:
            body = {}

        try:
            if path == "/device/register":
                payload = _device_register(body)
                # 注册返 auth_token, 但只 admin 可见
                if mode == "admin":
                    return self._send_json(200, payload)
                else:
                    return self._send_json(200, {"ok": True, "device_id": payload["device_id"], "device_name": payload["device_name"]})
            elif path == "/device/heartbeat":
                payload, err_code = _device_heartbeat(body)
                if err_code == "not_registered":
                    return self._send_error_json(404, "device not registered")
                if err_code == "save_failed":
                    return self._send_error_json(500, "save failed")
                return self._send_json(200, payload)
            elif path == "/device/deregister":
                payload, err_code = _device_deregister(body)
                if err_code == "not_found":
                    return self._send_error_json(404, "device not found")
                if err_code == "save_failed":
                    return self._send_error_json(500, "save failed")
                return self._send_json(200, payload)
            elif path == "/shared/create":
                payload, err_code = _shared_create(body)
                if err_code == "conflict":
                    return self._send_error_json(409, "folder_id_exists")
                if err_code == "save_failed":
                    return self._send_error_json(500, "save failed")
                return self._send_json(200, payload)
            elif path == "/shared/join":
                payload, err_code = _shared_join(body)
                if err_code == "not_found":
                    return self._send_error_json(404, "folder_not_found")
                if err_code == "save_failed":
                    return self._send_error_json(500, "save failed")
                return self._send_json(200, payload)
            elif path == "/shared/leave":
                payload, err_code = _shared_leave(body)
                if err_code == "not_found":
                    return self._send_error_json(404, "folder_not_found")
                if err_code == "save_failed":
                    return self._send_error_json(500, "save failed")
                return self._send_json(200, payload)
        except ValueError as e:
            return self._send_error_json(400, str(e))
        except OSError as e:
            _log("error", "io_error", op="post", path=path, err=str(e))
            return self._send_error_json(500, "io error")
        except Exception as e:
            _log("error", "unhandled", op="post", path=path, err=repr(e))
            return self._send_error_json(500, f"internal: {e}")


# ============== 后台线程 ==============
def _heartbeat_checker():
    while True:
        time.sleep(HEARTBEAT_CHECK_INTERVAL_S)
        try:
            with _lock:
                data = _load(DEVICE_FILE, _empty_devices())
                now_ts = time.time()
                changed = False
                for d in data["devices"]:
                    last_hb = _parse_ts(d.get("last_heartbeat") or d.get("last_seen"))
                    if d.get("online", True) and last_hb and (now_ts - last_hb) > HEARTBEAT_OFFLINE_THRESHOLD_S:
                        d["online"] = False
                        d["last_update"] = _now_iso()
                        changed = True
                if changed:
                    _atomic_save(DEVICE_FILE, data)
                    off_count = sum(1 for d in data["devices"] if not d.get("online", True))
                else:
                    off_count = 0
        except (RuntimeError, OSError) as e:
            _log("error", "heartbeat_checker_failed", op="checker", err=str(e))
            changed = False
            off_count = 0
        if changed:
            _wake_all()
            _log("info", "devices_marked_offline", op="checker", count=off_count)


# ============== main ==============
def main():
    try:
        _bootstrap()
    except (RuntimeError, OSError) as e:
        _log("error", "bootstrap_failed", op="main", err=str(e))
        sys.stderr.write(f"FATAL: {e}\n")
        sys.exit(1)
    threading.Thread(target=_heartbeat_checker, daemon=True, name="hb-checker").start()
    addr = ("0.0.0.0", LISTEN_PORT)
    _log("info", "listening", op="main", addr=addr)
    srv = ThreadingHTTPServer(addr, Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        _log("info", "shutdown", op="main")
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
