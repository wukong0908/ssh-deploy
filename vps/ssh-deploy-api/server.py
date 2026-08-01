#!/usr/bin/env python3
"""
ssh-deploy 主机注册中心 API.

Endpoints (全部要求 Authorization: Bearer <token>):
  GET  /ssh-deploy/hosts           列出所有主机
  POST /ssh-deploy/register        注册新主机(JSON body)
  POST /ssh-deploy/unregister      注销主机(JSON body 含 name)
  GET  /healthz                    健康检查(免鉴权)

数据文件:/var/lib/ssh-deploy/hosts.json
并发:stdlib http.server 单进程串行(只一个 VPS 实例,够用)
"""

import json
import os
import sys
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DATA_DIR = os.environ.get("SSH_DEPLOY_DATA_DIR", "/var/lib/ssh-deploy")
DATA_FILE = os.path.join(DATA_DIR, "hosts.json")
TOKEN = os.environ.get("BEARER_TOKEN", "").strip()

_lock = threading.Lock()


def _load():
    if not os.path.exists(DATA_FILE):
        return {"version": "1.0", "servers": []}
    with open(DATA_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def _save(data):
    tmp = DATA_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    os.replace(tmp, DATA_FILE)


def _now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _check_auth(handler):
    """验证 Bearer token. 失败返回 False."""
    if not TOKEN:
        # 未设 token = 关闭服务(防误启)
        handler.send_response(503)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(b'{"error":"server token not configured"}')
        return False
    auth = handler.headers.get("Authorization", "")
    if auth != f"Bearer {TOKEN}":
        handler.send_response(403)
        handler.send_header("Content-Type", "application/json")
        handler.end_headers()
        handler.wfile.write(b'{"error":"forbidden"}')
        return False
    return True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # 静默日志(stderr)
        sys.stderr.write(f"[{self.log_date_time_string()}] {fmt % args}\n")

    def _send_json(self, code, payload):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/healthz":
            self._send_json(200, {"ok": True, "ts": _now_iso()})
            return
        if path in ("/ssh-deploy/hosts", "/ssh-deploy/"):
            if not _check_auth(self):
                return
            with _lock:
                data = _load()
            self._send_json(200, data)
            return
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        if not _check_auth(self):
            return
        # 读 body
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except json.JSONDecodeError as e:
            self._send_json(400, {"error": f"invalid json: {e}"})
            return

        if path == "/ssh-deploy/register":
            self._register(body)
        elif path == "/ssh-deploy/unregister":
            self._unregister(body)
        else:
            self._send_json(404, {"error": "not found"})

    def _register(self, body):
        # 必填:name / ssh_port / ssh_user
        required = ["name", "ssh_port", "ssh_user"]
        missing = [k for k in required if k not in body]
        if missing:
            self._send_json(400, {"error": f"missing fields: {missing}"})
            return
        name = str(body["name"]).strip()
        if not name:
            self._send_json(400, {"error": "name empty"})
            return
        # 端口范围
        try:
            port = int(body["ssh_port"])
            if not (1 <= port <= 65535):
                raise ValueError
        except (ValueError, TypeError):
            self._send_json(400, {"error": "ssh_port must be 1..65535"})
            return

        entry = {
            "name": name,
            "vps_host": str(body.get("vps_host", "")).strip(),
            "ssh_port": port,
            "ssh_user": str(body["ssh_user"]).strip(),
            "alias": str(body.get("alias", f"wpc-{name}")).strip(),
            "desc": str(body.get("desc", "")).strip(),
            "owner": str(body.get("owner", "wukong0908")).strip(),
            "added_at": body.get("added_at") or _now_iso(),
        }
        with _lock:
            data = _load()
            # 端口冲突检测:同 port + 同 vps_host 已存在另一台 name → 拒(避免 frps 随机路由)
            existing_servers = [s for s in data.get("servers", []) if s.get("name") != name]
            conflict = next(
                (s for s in existing_servers
                 if s.get("ssh_port") == port
                 and s.get("vps_host", "") == entry["vps_host"]),
                None
            )
            if conflict:
                self._send_json(
                    409,
                    {
                        "error": "port conflict",
                        "detail": f"port {port} on {entry['vps_host']} already used by '{conflict['name']}' (user={conflict.get('ssh_user')})",
                        "conflict_with": conflict["name"],
                        "existing_port": port,
                    },
                )
                return
            data["servers"] = existing_servers
            data["servers"].append(entry)
            _save(data)
        self._send_json(200, {"ok": True, "registered": entry})

    def _unregister(self, body):
        name = str(body.get("name", "")).strip()
        if not name:
            self._send_json(400, {"error": "name required"})
            return
        with _lock:
            data = _load()
            before = len(data.get("servers", []))
            data["servers"] = [s for s in data.get("servers", []) if s.get("name") != name]
            after = len(data["servers"])
            _save(data)
        self._send_json(200, {"ok": True, "removed": before - after})


def main():
    if not TOKEN:
        print("ERROR: BEARER_TOKEN env not set", file=sys.stderr)
        sys.exit(1)
    os.makedirs(DATA_DIR, exist_ok=True)
    if not os.path.exists(DATA_FILE):
        _save({"version": "1.0", "servers": []})
        os.chmod(DATA_FILE, 0o644)
    port = int(os.environ.get("API_PORT", "8081"))
    addr = ("127.0.0.1", port)
    print(f"ssh-deploy-api listening on {addr[0]}:{addr[1]}", file=sys.stderr)
    print(f"data: {DATA_FILE}", file=sys.stderr)
    srv = ThreadingHTTPServer(addr, Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()