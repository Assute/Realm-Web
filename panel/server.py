#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import secrets
import signal
import socketserver
import subprocess
import sys
import threading
import time
from http import HTTPStatus
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse


BASE_DIR = Path(__file__).resolve().parent
TEMPLATE_DIR = BASE_DIR / "templates"
REALM_DIR = Path(os.environ.get("REALM_DIR", "/root/realm"))
CONFIG_FILE = REALM_DIR / "config.toml"
DATA_FILE = BASE_DIR / "panel_data.json"
DEFAULT_BG_PC = "https://img.inim.im/file/1769439286929_61891168f564c650f6fb03d1962e5f37.jpeg"
DEFAULT_BG_MOBILE = "https://img.inim.im/file/1764296937373_bg_m_2.png"
DEFAULT_PORT = 3060
LOCK = threading.RLock()
SESSIONS = {}


def now_ms():
    return int(time.time() * 1000)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def default_data():
    return {
        "username": "admin",
        "password_hash": sha256_text("123456"),
        "secret": secrets.token_hex(32),
        "port": DEFAULT_PORT,
        "bg_pc": DEFAULT_BG_PC,
        "bg_mobile": DEFAULT_BG_MOBILE,
        "rules": [],
    }


def ensure_data():
    BASE_DIR.mkdir(parents=True, exist_ok=True)
    TEMPLATE_DIR.mkdir(parents=True, exist_ok=True)
    if not DATA_FILE.exists():
        save_data(default_data())
    data = load_data()
    changed = False
    for key, value in default_data().items():
        if key not in data:
            data[key] = value
            changed = True
    if changed:
        save_data(data)
    return data


def load_data():
    with LOCK:
        if not DATA_FILE.exists():
            return default_data()
        with DATA_FILE.open("r", encoding="utf-8") as f:
            data = json.load(f)
        data.setdefault("rules", [])
        data.setdefault("port", DEFAULT_PORT)
        data.setdefault("username", "admin")
        data.setdefault("password_hash", sha256_text("123456"))
        data.setdefault("secret", secrets.token_hex(32))
        data.setdefault("bg_pc", DEFAULT_BG_PC)
        data.setdefault("bg_mobile", DEFAULT_BG_MOBILE)
        data["rules"] = [normalize_rule(rule, keep_id=True) for rule in data["rules"]]
        return data


def save_data(data):
    with LOCK:
        tmp = DATA_FILE.with_suffix(".tmp")
        with tmp.open("w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
        tmp.replace(DATA_FILE)


def normalize_listen(value: str) -> str:
    value = str(value or "").strip()
    if value and ":" not in value:
        return f"0.0.0.0:{value}"
    return value


def normalize_rule(payload, keep_id=False):
    rule_id = payload.get("id") if keep_id else None
    rule = {
        "id": rule_id or secrets.token_hex(8),
        "name": str(payload.get("name", "")).strip() or "未命名",
        "listen": normalize_listen(payload.get("listen", "")),
        "remote": str(payload.get("remote", "")).strip(),
        "enabled": bool(payload.get("enabled", True)),
        "expire_date": int(payload.get("expire_date", 0) or 0),
        "traffic_limit": int(float(payload.get("traffic_limit", 0) or 0)),
        "traffic_used": int(float(payload.get("traffic_used", 0) or 0)),
        "created_at": int(payload.get("created_at", now_ms()) or now_ms()),
        "updated_at": int(payload.get("updated_at", now_ms()) or now_ms()),
    }
    return rule


def validate_rule(rule):
    if not rule["name"] or not rule["listen"] or not rule["remote"]:
        raise ValueError("name/listen/remote 不能为空")
    if ":" not in rule["listen"]:
        raise ValueError("listen 格式错误")
    if ":" not in rule["remote"]:
        raise ValueError("remote 格式错误")


def find_rule(data, rule_id):
    for rule in data["rules"]:
        if rule["id"] == rule_id:
            return rule
    return None


def match_rule(data, name, listen, remote, panel_id=None):
    for rule in data["rules"]:
        if panel_id and rule["id"] == panel_id:
            return rule
        if rule["listen"] == listen and rule["remote"] == remote:
            return rule
        if rule["name"] == name and rule["listen"] == listen and rule["remote"] == remote:
            return rule
    return None


def parse_config_rules():
    if not CONFIG_FILE.exists():
        return [], "[network]\nno_tcp = false\nuse_udp = true\n"

    content = CONFIG_FILE.read_text(encoding="utf-8", errors="ignore")
    lines = content.splitlines()
    header_lines = []
    blocks = []
    cur = None

    for line in lines:
        stripped = line.strip()
        if stripped == "[[endpoints]]":
            if cur:
                blocks.append(cur)
            cur = {"raw": [line]}
            continue

        if cur is None:
            header_lines.append(line)
            continue

        cur["raw"].append(line)
        if stripped.startswith("# 备注:"):
            cur["name"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("listen ="):
            cur["listen"] = line.split('"', 2)[1] if '"' in line else ""
        elif stripped.startswith("remote ="):
            cur["remote"] = line.split('"', 2)[1] if '"' in line else ""
        elif stripped.startswith("# panel_id:"):
            cur["panel_id"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("# enabled:"):
            cur["enabled"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("# expire_date:"):
            cur["expire_date"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("# traffic_limit:"):
            cur["traffic_limit"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("# traffic_used:"):
            cur["traffic_used"] = stripped.split(":", 1)[1].strip()

    if cur:
        blocks.append(cur)

    header = "\n".join(header_lines).strip()
    if not header:
        header = "[network]\nno_tcp = false\nuse_udp = true"

    rules = []
    for block in blocks:
        if block.get("listen") and block.get("remote"):
            rules.append(
                {
                    "id": block.get("panel_id", ""),
                    "name": block.get("name", "未命名"),
                    "listen": block["listen"],
                    "remote": block["remote"],
                    "enabled": block.get("enabled", "1") != "0",
                    "expire_date": int(block.get("expire_date", "0") or 0),
                    "traffic_limit": int(block.get("traffic_limit", "0") or 0),
                    "traffic_used": int(block.get("traffic_used", "0") or 0),
                }
            )
    return rules, header + "\n"


def merge_config_rules_into_data(data):
    config_rules, _ = parse_config_rules()
    changed = False
    for item in config_rules:
        item = normalize_rule(item, keep_id=True)
        try:
            validate_rule(item)
        except ValueError:
            continue
        existing = match_rule(
            data,
            item["name"],
            item["listen"],
            item["remote"],
            panel_id=item["id"] or None,
        )
        if existing:
            if existing["name"] != item["name"]:
                existing["name"] = item["name"]
                changed = True
            if existing["listen"] != item["listen"] or existing["remote"] != item["remote"]:
                existing["listen"] = item["listen"]
                existing["remote"] = item["remote"]
                changed = True
            if item["id"] and existing["id"] != item["id"]:
                existing["id"] = item["id"]
                changed = True
            if existing.get("enabled", True) != item.get("enabled", True):
                existing["enabled"] = item.get("enabled", True)
                changed = True
            for meta_key in ("expire_date", "traffic_limit", "traffic_used"):
                if int(existing.get(meta_key, 0) or 0) != int(item.get(meta_key, 0) or 0):
                    existing[meta_key] = int(item.get(meta_key, 0) or 0)
                    changed = True
        else:
            data["rules"].append(item)
            changed = True
    return changed


def rule_runtime_state(rule):
    if not rule.get("enabled", True):
        return False, None
    expire_date = int(rule.get("expire_date", 0) or 0)
    traffic_limit = int(rule.get("traffic_limit", 0) or 0)
    traffic_used = int(rule.get("traffic_used", 0) or 0)
    if expire_date and expire_date < now_ms():
        return False, "已过期"
    if traffic_limit > 0 and traffic_used >= traffic_limit:
        return False, "流量耗尽"
    return True, None


def write_config_from_data(data):
    _, header = parse_config_rules()
    if not header.strip():
        header = "[network]\nno_tcp = false\nuse_udp = true\n"
    content = header.rstrip() + "\n"
    for rule in data["rules"]:
        active, _ = rule_runtime_state(rule)
        if not active:
            continue
        name = str(rule["name"]).replace("\n", " ").replace("\r", " ")
        content += (
            "\n[[endpoints]]\n"
            f"# 备注: {name}\n"
            f"listen = \"{rule['listen']}\"\n"
            f"remote = \"{rule['remote']}\"\n"
            f"# panel_id: {rule['id']}\n"
            f"# enabled: {1 if rule.get('enabled', True) else 0}\n"
            f"# expire_date: {int(rule.get('expire_date', 0) or 0)}\n"
            f"# traffic_limit: {int(rule.get('traffic_limit', 0) or 0)}\n"
            f"# traffic_used: {int(rule.get('traffic_used', 0) or 0)}\n"
        )
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = CONFIG_FILE.with_suffix(".tmp")
    tmp.write_text(content.strip() + "\n", encoding="utf-8")
    tmp.replace(CONFIG_FILE)


def restart_realm_service():
    try:
        subprocess.run(
            ["systemctl", "restart", "realm.service"],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except Exception:
        pass


def persist_and_apply(data):
    save_data(data)
    write_config_from_data(data)
    restart_realm_service()


def sync_from_config():
    ensure_data()
    data = load_data()
    if merge_config_rules_into_data(data):
        save_data(data)
    return data


def cli_register_rule(name, listen, remote):
    ensure_data()
    data = load_data()
    merge_config_rules_into_data(data)
    existing = match_rule(data, name, listen, remote)
    if existing:
        existing["name"] = name or existing["name"]
        existing["listen"] = normalize_listen(listen)
        existing["remote"] = remote
        existing["enabled"] = True
        existing["updated_at"] = now_ms()
    else:
        rule = normalize_rule({"name": name, "listen": listen, "remote": remote, "enabled": True})
        validate_rule(rule)
        data["rules"].append(rule)
    save_data(data)


def cli_remove_rule(listen, remote):
    ensure_data()
    data = load_data()
    before = len(data["rules"])
    data["rules"] = [r for r in data["rules"] if not (r["listen"] == listen and r["remote"] == remote)]
    if len(data["rules"]) != before:
        save_data(data)


def set_port(port):
    ensure_data()
    data = load_data()
    data["port"] = int(port)
    save_data(data)


def serialize_rule(rule):
    _, status_msg = rule_runtime_state(rule)
    return {
        "id": rule["id"],
        "name": rule["name"],
        "listen": rule["listen"],
        "remote": rule["remote"],
        "enabled": bool(rule.get("enabled", True)),
        "expire_date": int(rule.get("expire_date", 0) or 0),
        "traffic_limit": int(rule.get("traffic_limit", 0) or 0),
        "traffic_used": int(rule.get("traffic_used", 0) or 0),
        "status_msg": status_msg,
    }


def render_template(filename, data):
    template = (TEMPLATE_DIR / filename).read_text(encoding="utf-8")
    for key, value in data.items():
        template = template.replace(f"__{key}__", str(value))
    return template.encode("utf-8")


def parse_json_body(handler):
    length = int(handler.headers.get("Content-Length", "0") or 0)
    raw = handler.rfile.read(length) if length > 0 else b"{}"
    if not raw:
        return {}
    return json.loads(raw.decode("utf-8"))


def get_cookie_session(handler):
    cookie_header = handler.headers.get("Cookie", "")
    if not cookie_header:
        return None
    cookie = SimpleCookie()
    cookie.load(cookie_header)
    token = cookie.get("realm_panel_session")
    if not token:
        return None
    return SESSIONS.get(token.value)


class RealmPanelHandler(BaseHTTPRequestHandler):
    server_version = "RealmPanel/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - - [%s] %s\n" % (self.address_string(), self.log_date_time_string(), fmt % args))

    def send_json(self, payload, status=200, headers=None):
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, body, status=200, headers=None):
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        if headers:
            for k, v in headers.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def require_auth(self):
        if get_cookie_session(self):
            return True
        self.send_json({"status": "error", "message": "未登录"}, status=401)
        return False

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/":
            if not get_cookie_session(self):
                return self.redirect("/login")
            data = load_data()
            return self.send_html(
                render_template(
                    "index.html",
                    {
                        "BG_PC": data.get("bg_pc", DEFAULT_BG_PC),
                        "BG_MOBILE": data.get("bg_mobile", DEFAULT_BG_MOBILE),
                        "USERNAME": data.get("username", "admin"),
                    },
                )
            )

        if path == "/login":
            data = load_data()
            return self.send_html(
                render_template(
                    "login.html",
                    {
                        "BG_PC": data.get("bg_pc", DEFAULT_BG_PC),
                        "BG_MOBILE": data.get("bg_mobile", DEFAULT_BG_MOBILE),
                    },
                )
            )

        if path == "/api/rules":
            if not self.require_auth():
                return
            data = sync_from_config()
            rules = [serialize_rule(rule) for rule in data["rules"]]
            return self.send_json({"rules": rules})

        if path == "/api/backup":
            if not self.require_auth():
                return
            data = sync_from_config()
            rules = [serialize_rule(rule) for rule in data["rules"]]
            body = json.dumps(rules, ensure_ascii=False, indent=2).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Disposition", 'attachment; filename="realm-backup.json"')
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        self.send_json({"status": "error", "message": "Not Found"}, status=404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/login":
            try:
                payload = parse_json_body(self)
            except Exception:
                return self.send_json({"status": "error", "message": "请求体格式错误"}, status=400)
            data = load_data()
            username = str(payload.get("username", "")).strip()
            password = str(payload.get("password", ""))
            if username == data["username"] and sha256_text(password) == data["password_hash"]:
                token = secrets.token_urlsafe(32)
                SESSIONS[token] = {"username": username, "created_at": time.time()}
                return self.send_json(
                    {"status": "ok"},
                    headers={"Set-Cookie": f"realm_panel_session={token}; Path=/; HttpOnly; SameSite=Lax"},
                )
            return self.send_json({"status": "error", "message": "账号或密码错误"}, status=401)

        if path == "/logout":
            token = None
            cookie_header = self.headers.get("Cookie", "")
            if cookie_header:
                cookie = SimpleCookie()
                cookie.load(cookie_header)
                token_obj = cookie.get("realm_panel_session")
                if token_obj:
                    token = token_obj.value
            if token:
                SESSIONS.pop(token, None)
            return self.send_json(
                {"status": "ok"},
                headers={"Set-Cookie": "realm_panel_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"},
            )

        if not self.require_auth():
            return

        try:
            payload = parse_json_body(self)
        except Exception:
            return self.send_json({"status": "error", "message": "请求体格式错误"}, status=400)

        data = load_data()
        merge_config_rules_into_data(data)

        if path == "/api/rules":
            try:
                rule = normalize_rule(payload)
                validate_rule(rule)
            except ValueError as exc:
                return self.send_json({"status": "error", "message": str(exc)}, status=400)
            data["rules"].append(rule)
            persist_and_apply(data)
            return self.send_json({"status": "ok", "message": "添加成功", "id": rule["id"]})

        if path == "/api/rules/batch":
            count = 0
            if not isinstance(payload, list):
                return self.send_json({"status": "error", "message": "请求格式错误"}, status=400)
            for item in payload:
                try:
                    rule = normalize_rule(item)
                    validate_rule(rule)
                except ValueError:
                    continue
                data["rules"].append(rule)
                count += 1
            persist_and_apply(data)
            return self.send_json({"status": "ok", "message": f"成功导入 {count} 条规则"})

        if path.endswith("/toggle") and path.startswith("/api/rules/"):
            rule_id = path.split("/")[3]
            rule = find_rule(data, rule_id)
            if not rule:
                return self.send_json({"status": "error", "message": "规则不存在"}, status=404)
            rule["enabled"] = not bool(rule.get("enabled", True))
            rule["updated_at"] = now_ms()
            persist_and_apply(data)
            return self.send_json({"status": "ok", "message": "状态已更新"})

        if path.endswith("/reset_traffic") and path.startswith("/api/rules/"):
            rule_id = path.split("/")[3]
            rule = find_rule(data, rule_id)
            if not rule:
                return self.send_json({"status": "error", "message": "规则不存在"}, status=404)
            rule["traffic_used"] = 0
            rule["updated_at"] = now_ms()
            save_data(data)
            return self.send_json({"status": "ok", "message": "已重置"})

        if path == "/api/admin/account":
            username = str(payload.get("username", "")).strip()
            password = str(payload.get("password", ""))
            if not username:
                return self.send_json({"status": "error", "message": "用户名不能为空"}, status=400)
            data["username"] = username
            if password:
                data["password_hash"] = sha256_text(password)
            save_data(data)
            return self.send_json({"status": "ok", "message": "账户已更新"})

        if path == "/api/admin/bg":
            data["bg_pc"] = str(payload.get("bg_pc", DEFAULT_BG_PC)).strip() or DEFAULT_BG_PC
            data["bg_mobile"] = str(payload.get("bg_mobile", DEFAULT_BG_MOBILE)).strip() or DEFAULT_BG_MOBILE
            save_data(data)
            return self.send_json({"status": "ok", "message": "背景已更新"})

        if path == "/api/restore":
            if not isinstance(payload, list):
                return self.send_json({"status": "error", "message": "请求格式错误"}, status=400)
            new_rules = []
            for item in payload:
                try:
                    rule = normalize_rule(item, keep_id=True)
                    validate_rule(rule)
                except ValueError:
                    continue
                new_rules.append(rule)
            data["rules"] = new_rules
            persist_and_apply(data)
            return self.send_json({"status": "ok", "message": "恢复成功"})

        self.send_json({"status": "error", "message": "Not Found"}, status=404)

    def do_PUT(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.require_auth():
            return
        if not path.startswith("/api/rules/"):
            return self.send_json({"status": "error", "message": "Not Found"}, status=404)

        try:
            payload = parse_json_body(self)
        except Exception:
            return self.send_json({"status": "error", "message": "请求体格式错误"}, status=400)

        data = load_data()
        merge_config_rules_into_data(data)
        rule_id = path.split("/")[3]
        rule = find_rule(data, rule_id)
        if not rule:
            return self.send_json({"status": "error", "message": "规则不存在"}, status=404)

        try:
            updated = normalize_rule({**rule, **payload, "id": rule["id"]}, keep_id=True)
            validate_rule(updated)
        except ValueError as exc:
            return self.send_json({"status": "error", "message": str(exc)}, status=400)

        index = data["rules"].index(rule)
        data["rules"][index] = updated
        persist_and_apply(data)
        self.send_json({"status": "ok", "message": "保存成功"})

    def do_DELETE(self):
        parsed = urlparse(self.path)
        path = parsed.path
        if not self.require_auth():
            return

        data = load_data()
        merge_config_rules_into_data(data)

        if path == "/api/rules/all":
            data["rules"] = []
            persist_and_apply(data)
            return self.send_json({"status": "ok", "message": "已清空"})

        if path.startswith("/api/rules/"):
            rule_id = path.split("/")[3]
            before = len(data["rules"])
            data["rules"] = [rule for rule in data["rules"] if rule["id"] != rule_id]
            if len(data["rules"]) == before:
                return self.send_json({"status": "error", "message": "规则不存在"}, status=404)
            persist_and_apply(data)
            return self.send_json({"status": "ok", "message": "删除成功"})

        self.send_json({"status": "error", "message": "Not Found"}, status=404)


class ReusableThreadingHTTPServer(ThreadingHTTPServer):
    allow_reuse_address = True
    daemon_threads = True


def run_server():
    ensure_data()
    sync_from_config()
    data = load_data()
    port = int(data.get("port", DEFAULT_PORT) or DEFAULT_PORT)
    server = ReusableThreadingHTTPServer(("0.0.0.0", port), RealmPanelHandler)

    def shutdown_handler(signum, frame):
        server.shutdown()

    signal.signal(signal.SIGTERM, shutdown_handler)
    signal.signal(signal.SIGINT, shutdown_handler)
    server.serve_forever()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ensure-data", action="store_true")
    parser.add_argument("--sync-from-config", action="store_true")
    parser.add_argument("--print-port", action="store_true")
    parser.add_argument("--set-port", type=int)
    parser.add_argument("--register-rule", nargs=3, metavar=("NAME", "LISTEN", "REMOTE"))
    parser.add_argument("--remove-rule", nargs=2, metavar=("LISTEN", "REMOTE"))
    args = parser.parse_args()

    if args.ensure_data:
        ensure_data()
        return
    if args.sync_from_config:
        sync_from_config()
        return
    if args.print_port:
        ensure_data()
        print(load_data().get("port", DEFAULT_PORT))
        return
    if args.set_port is not None:
        if args.set_port < 1 or args.set_port > 65535:
            print("端口范围必须为 1-65535", file=sys.stderr)
            sys.exit(1)
        set_port(args.set_port)
        return
    if args.register_rule:
        name, listen, remote = args.register_rule
        cli_register_rule(name, listen, remote)
        return
    if args.remove_rule:
        listen, remote = args.remove_rule
        cli_remove_rule(listen, remote)
        return

    run_server()


if __name__ == "__main__":
    main()
