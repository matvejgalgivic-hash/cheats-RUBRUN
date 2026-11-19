#!/usr/bin/env python3
"""Local stand-in for the loader backend.

Serves the /api/v1 contract the client expects, entirely offline.
Any key is accepted. Packages are served from ./packages/<gameId>.zip
if present, otherwise the manifest reports has_package=false.
"""
import base64
import hashlib
import json
import os
import re
import sys
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, unquote

ROOT = os.path.dirname(os.path.abspath(__file__))
PKG_DIR = os.path.join(ROOT, "packages")
LOG = os.path.join(ROOT, "api.log")
PORT = int(os.environ.get("LOADER_API_PORT", "8765"))

KEY = "LOCAL-0000-0000-0000-0000"
LIFETIME = True
FAR_FUTURE = 4102444800  # 2100-01-01T00:00:00Z

# Key the operator actually typed in the UI. Echoed back by /me so the
# profile reflects what was entered instead of a hard-coded constant.
_live_key = KEY
_live_hwid = ""
_key_lock = threading.Lock()


LOADER_HWID = os.path.join(ROOT, "logs", "loader_hwid.txt")


def remember_loader_hwid(hwid):
    """Keep the hardware id the ORIGINAL loader computes for this PC.

    The loader sends it to us on every login, and it is the only place that
    value can be read from: the vendor derives it inside Loader.exe (no
    documented formula reproduces it). Recording it is what makes the folder
    self-describing on a fresh PC - SETUP.bat can then put it in hwid.txt
    without guessing. It never overwrites a non-empty hwid.txt, so a working
    install is not disturbed by a stray call.
    """
    hwid = (hwid or "").strip()
    if not hwid:
        return
    try:
        os.makedirs(os.path.dirname(LOADER_HWID), exist_ok=True)
        with open(LOADER_HWID, "w", encoding="utf-8") as f:
            f.write(hwid + "\n")
    except Exception:
        pass
    target = os.path.join(ROOT, "hwid.txt")
    if not current_hwid():
        try:
            with open(target, "w", encoding="utf-8") as f:
                f.write(hwid + "\n")
        except Exception:
            pass


def set_live_key(key, hwid=""):
    """Remember the last accepted key so /me and the profile match it."""
    global _live_key, _live_hwid
    key = (key or "").strip()
    if hwid:
        remember_loader_hwid(hwid)
    if not key:
        return
    with _key_lock:
        _live_key = key
        if hwid:
            _live_hwid = hwid

REAL_MANIFEST = os.path.join(ROOT, "real_manifest.json")
REAL_TICKET = os.path.join(ROOT, "real_ticket.json")
UPDATE_INFO = os.path.join(PKG_DIR, "update_info.json")


def package_version(gid="1"):
    """Build string of the package this server actually hands out.

    update.ps1 records it in packages/update_info.json. Without that file the
    signed manifest is the next best source. The old hard-coded "1.0.95" is
    only a last resort - it made /me keep reporting the previous build after
    an update, which is exactly the kind of lie that sends you debugging the
    wrong thing.
    """
    info = load_json(UPDATE_INFO) or {}
    ver = info.get("version") or info.get("previous_version")
    if ver and str(ver) != "?":
        return str(ver)
    m = real_manifest() or {}
    if m.get("version"):
        return str(m["version"])
    return "1.0.95"


def load_json(path):
    try:
        # license.json is saved by the vendor tooling with a UTF-8 BOM;
        # plain "utf-8" raises on the BOM, which silently disabled every
        # vendor ticket refresh and forced the fake local ticket.
        with open(path, "r", encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return None


def real_manifest():
    """Replay the signed manifest captured from the vendor's backend."""
    m = load_json(REAL_MANIFEST)
    if not isinstance(m, dict) or "payload" not in m:
        return None
    try:
        payload = json.loads(base64.b64decode(m["payload"]).decode("utf-8"))
    except Exception:
        payload = {}
    data = dict(payload)
    data.update(m)
    data.pop("payload", None)
    data["payload"] = payload

    # The signed manifest is a snapshot; the local zip is the truth on disk.
    # Keep the client's size/sha check pointed at the file we actually serve.
    gid = str(data.get("id") or 1)
    p = package_path(gid)
    if p:
        with open(p, "rb") as f:
            raw = f.read()
        data["has_package"] = True
        data["package_size"] = len(raw)
        data["package_sha256"] = hashlib.sha256(raw).hexdigest()
        payload["package_size"] = data["package_size"]
        payload["package_sha256"] = data["package_sha256"]
        payload["has_package"] = True
    else:
        data["has_package"] = False
    return data


def real_ticket():
    t = load_json(REAL_TICKET)
    return t if isinstance(t, dict) else None


LICENSE = os.path.join(ROOT, "license.json")
REAL_SERVER = os.environ.get("LOADER_REAL_SERVER", "https://95.85.230.17")

# Tickets are minted with OUR key, which the vendor binds to one machine. The
# hwid therefore must not travel inside license.json: hard-coding it made the
# folder useless on any other PC (auth answers 403 "Запрещено"). START_DATA.BAT
# writes the machine's own hwid into runtime_config.ini and passes it here.
VENDOR_UNAVAILABLE = os.path.join(ROOT, "logs", "vendor_down.flag")
UI_DIR = os.path.join(ROOT, "ui")


def current_hwid():
    """This machine's hardware id.

    The vendor binds a key to one hwid, so it must never travel inside
    license.json - that is exactly what made the folder useless on any other
    PC (auth answers 403 "Запрещено"). SETUP.bat writes hwid.txt with the id of
    the machine it runs on; the env var is the override for tests.
    """
    h = (os.environ.get("ROBRUN_HWID") or "").strip()
    if h:
        return h
    for name in ("hwid.txt", "runtime_config.ini"):
        p = os.path.join(ROOT, name)
        try:
            with open(p, "r", encoding="utf-8-sig") as f:
                text = f.read()
        except Exception:
            continue
        if name.endswith(".ini"):
            m = re.search(r"^\s*hwid\s*=\s*(\S+)\s*$", text, re.M | re.I)
            if m:
                return m.group(1)
        else:
            for line in text.splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    return ""


def http_json(url, method="GET", body=None, token=None, timeout=20):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    req.add_header("User-Agent", "GameLoader/1.0.14")
    if token:
        req.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def refresh_ticket(max_age=90):
    """Keep a fresh signed launch ticket while the vendor license is alive.

    The cheat receives the ticket from the loader and validates its signature
    itself, so an expired or locally-faked ticket makes RobRun.exe abort with
    0xC0000409. The vendor ticket lives 120s, so a used ticket has to be
    replaced for every launch. Needs license.json (key + hwid).

    Returns the ticket dict, or None when no trustworthy ticket is available.
    """
    t = real_ticket()
    now = time.time()
    if isinstance(t, dict) and t.get("ticket"):
        try:
            exp = float(t.get("signed_expires") or 0)
        except Exception:
            exp = 0.0
        if exp - now > 5:          # still inside its signed validity window
            return t
    cfg = load_json(LICENSE) or {}
    key, hwid = cfg.get("key"), current_hwid()
    if not key or not hwid:
        log("ticket refresh skipped: license.json has no key / no hwid for this PC")
        return None
    try:
        auth = http_json(REAL_SERVER + "/api/v1/auth", "POST", {"key": key, "hwid": hwid})
        tok = auth.get("token")
        if not tok:
            log("ticket refresh: auth returned no token")
            return None
        ticket = http_json(REAL_SERVER + "/api/v1/games/1/launch", "POST", {}, tok)
        if not isinstance(ticket, dict) or not ticket.get("ticket"):
            log("ticket refresh: launch returned no ticket")
            return None
        with open(REAL_TICKET, "w", encoding="utf-8") as f:
            json.dump(ticket, f)
        log("ticket refreshed (expires_in=%s)" % ticket.get("expires_in"))
        return ticket
    except Exception as exc:
        log("ticket refresh failed: %s" % exc)
        return None


def log(line):
    with open(LOG, "a", encoding="utf-8") as f:
        f.write("%s %s\n" % (time.strftime("%H:%M:%S"), line))


def profile():
    now = int(time.time())
    games = []
    if os.path.isdir(PKG_DIR):
        for name in sorted(os.listdir(PKG_DIR)):
            if not name.lower().endswith(".zip"):
                continue
            gid = name[:-4]
            if not gid.isdigit():
                continue
            path = os.path.join(PKG_DIR, name)
            raw = open(path, "rb").read()
            games.append({
                "id": int(gid),
                "name": "ROB RUN",
                "title": "ROB RUN",
                "image_url": "",
                "version": package_version(gid),
                "entry_file": "RobRun.exe",
                "launch_args": "",
                "run_steam": False,
                "has_package": True,
                "steam_appid": "4262460",
                "size": os.path.getsize(path),
                "package_size": os.path.getsize(path),
                "package_sha256": hashlib.sha256(raw).hexdigest(),
                # MUST match the vendor contract: the launcher only takes the
                # RobRunRuntime pipe path (driver map + signed ticket handshake)
                # when this is "robrun-v1". With an empty string it silently
                # falls back to RunEntry and spawns RobRun.exe with no pipe,
                # which aborts with 0xC0000409 before the overlay exists.
                "runtime_protocol": "robrun-v1",
            })
    if not games:
        games.append({
            "id": 1,
            "name": "ROB RUN",
            "title": "ROB RUN",
            "image_url": "",
            "version": package_version("1"),
            "has_package": False,
            "run_steam": False,
            "steam_appid": "4262460",
            "size": 0,
            "package_size": 0,
            "runtime_protocol": "robrun-v1",
        })
    with _key_lock:
        key = _live_key
    body = {
        "key": key,
        "key_remembered": True,
        "key_masked": key[:4] + "-****-****-" + key[-4:] if len(key) > 12 else key,
        "lifetime": LIFETIME,
        "days": 27375,
        "expires_at": FAR_FUTURE,
        "server_time": now,
        "created_at": now - 86400,
        "plan": "lifetime",
        "plan_name": "lifetime",
        "hwid_resets": 999,
        "games": games,
        "token": "local-token-%d" % now,
        "user": {"key": key, "plan": "lifetime"},
    }
    return body


def auth_body():
    b = profile()
    return b


def envelope(data):
    out = {"ok": True, "data": data}
    if isinstance(data, dict):
        for k, v in data.items():
            out.setdefault(k, v)
    return out


def package_path(gid):
    p = os.path.join(PKG_DIR, "%s.zip" % gid)
    return p if os.path.isfile(p) else None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def _send(self, code, body, extra=None):
        raw = json.dumps(body).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        self.wfile.write(raw)

    def _ok(self, data):
        self._send(200, envelope(data))

    def _text(self, code, body, content_type="text/plain; charset=utf-8"):
        raw = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _file(self, path):
        """Serve a file as-is (the loader UI asks for its html/css/js this way)."""
        with open(path, "rb") as f:
            raw = f.read()
        ext = os.path.splitext(path)[1].lower()
        ctype = {
            ".html": "text/html; charset=utf-8",
            ".css": "text/css; charset=utf-8",
            ".js": "application/javascript; charset=utf-8",
            ".svg": "image/svg+xml",
            ".png": "image/png",
            ".woff2": "font/woff2",
            ".woff": "font/woff",
            ".ttf": "font/ttf",
        }.get(ext, "application/octet-stream")
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)

    def _ui_file(self, rel):
        """/ui/index.html -> ui/index.html, refusing anything outside ui\\."""
        rel = rel.replace("%20", " ").lstrip("/")
        if not rel or rel.endswith("/"):
            rel += "index.html"
        root = os.path.realpath(UI_DIR)
        p = os.path.realpath(os.path.join(root, rel))
        if not p.startswith(root + os.sep) or not os.path.isfile(p):
            return None
        return p

    def _err(self, code, message):
        self._send(code, {"ok": False, "error": message, "status": code, "message": message})

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        log("GET " + path + " ua=" + self.headers.get("User-Agent", "-"))
        if path in ("/", "/api/v1/ping"):
            self._ok(True if path != "/" else {"service": "local", "version": "dev"})
            return
        if path == "/api/v1/me":
            self._ok(profile())
            return
        if path == "/api/v1/loader-update":
            # EXACT shape GameLoader.SelfUpdate.Check expects.
            #
            # Check() reads the parsed body, looks for the key "update" and
            # treats the loader as up to date when it is missing or null:
            #     update = data.ContainsKey("update") ? Json.Obj(data["update"]) : null
            #     if (update == null) return null;      // no update, UI stays quiet
            #
            # The old answer ("update_available": false, "version": ...) is
            # not part of that contract. It is a truthy object, so the WebView
            # treated it as a pending update, let the auto-click fire after
            # 3s, called loader:install with request_id = undefined and ended
            # up showing "Не удалось обновить лоадер. Запустите его снова.".
            # Always answer with an explicit null so the update branch is dead.
            self._ok({"update": None, "latest": "1.0.14", "mandatory": False})
            return
        if path.startswith("/api/v1/games/") and path.endswith("/manifest"):
            gid = path.split("/")[4]
            m = real_manifest()
            if m is None:
                m = self.manifest(gid)
                m["payload"] = dict(m)
                m["signature"] = "LOCAL-SIGNATURE"
                m["schema"] = 1
            else:
                # replaying the vendor snapshot: merge in the one thing that
                # belongs to THIS machine - whether the official loader has to
                # do the update, because our key only works on one PC
                m = dict(m)
                m.update(self.official_notice())
            self._ok(m)
            return
        if path.startswith("/api/v1/games/") and path.endswith("/package"):
            gid = path.split("/")[4]
            self.package(gid)
            return
        if path == "/api/v1/runtime/config":
            p = os.path.join(ROOT, "runtime_config.ini")
            if os.path.isfile(p):
                with open(p, "r", encoding="utf-8-sig") as f:
                    self._text(200, f.read())
            else:
                self._text(200, "[Combat]\nEnabled=1\n")
            return
        if path == "/api/v1/anticheat/status":
            self._ok({
                "status": "ok",
                "ts": int(time.time()),
                "nonce": hashlib.sha256(os.urandom(16)).hexdigest()[:32],
                "signature": hashlib.sha256(os.urandom(16)).hexdigest(),
            })
            return
        if path.startswith("/_ui/") or path == "/_ui":
            # Static files for a local copy of the loader UI (folder ui/).
            # Optional: the shipped Loader.exe renders its UI from resources,
            # so this is only used when someone drops an unpacked ui/ next to
            # the server. Missing file = 404, never a directory listing.
            rel = path[len("/_ui"):]
            p = self._ui_file(rel)
            if p:
                self._file(p)
            else:
                self._err(404, "not found")
            return
        self._err(404, "not found")

    def do_POST(self):
        path = urlparse(self.path).path.rstrip("/") or "/"
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        log("POST " + path + " body=" + raw[:400].decode("utf-8", "replace"))
        # ---------------------------------------------------------- self-update
        # SelfUpdate.Check posts here once when a "LoaderUpdateReceipt" value
        # is left in HKCU\Software\Hidden\Loader after an applied update.
        # A 404 makes the loader treat the client as broken, so acknowledge
        # the completion and let it drop the receipt.
        if path == "/api/v1/loader-update/complete":
            log("loader-update complete acknowledged (no-op)")
            self._ok(True)
            return
        if path.startswith("/api/v1/loader-update/") and path.endswith("/file"):
            log("loader-update file requested -> refusing (self-update disabled)")
            self._err(404, "no loader update")
            return
        if path == "/api/v1/auth":
            try:
                body = json.loads(raw.decode("utf-8")) if raw else {}
            except Exception:
                body = {}
            if isinstance(body, dict):
                set_live_key(body.get("key"), body.get("hwid"))
            with _key_lock:
                shown = _live_key
            log("auth accepted, hwid ignored (any key works on any PC) key=%s" % shown)
            self._ok(auth_body())
            return
        if path == "/api/v1/runtime/redeem":
            token = hashlib.sha256(raw + b"local-redeem").hexdigest()
            log("runtime token issued")
            self._text(200, token)
            return
        if path in ("/api/v1/runtime/crash", "/api/v1/anticheat/report"):
            log("runtime report accepted")
            self._ok(True)
            return
        if path.startswith("/api/v1/games/") and path.endswith("/launch"):
            gid = path.split("/")[4]
            captured = refresh_ticket()
            if captured is not None and captured.get("ticket"):
                self._ok(captured)
                return
            # Offline fallback. The launcher only checks the ticket STRUCTURE:
            # protocol == "robrun-v1", ticket/signature/hwid_digest are 64 hex,
            # and 0 < expires_in <= 120. It then hands the ticket to the local
            # runtime over the pipe, which trusts this same local server. So a
            # locally generated ticket keeps a lifetime license working even
            # when the vendor key is dead. (The old fallback emitted
            # "local-ticket" + expires_in 3600, which the launcher rejected
            # with "сервер выдал некорректный билет запуска".)
            now = int(time.time())

            def hx():
                return hashlib.sha256(os.urandom(32)).hexdigest()

            prev = real_ticket() or {}
            official = os.path.exists(VENDOR_UNAVAILABLE)
            ticket = {
                "ticket": hx(),
                "protocol": "robrun-v1",
                "signature": hx(),
                "hwid_digest": prev.get("hwid_digest") or hx(),
                # mirrors manifest(): the loader quotes this server back to the
                # runtime, and RobRun.exe only trusts the vendor url
                "server": "http://127.0.0.1:%d" % PORT if official else REAL_SERVER,
                "official_update": official,
                "signed_issued": now,
                "signed_expires": now + 120,
                "expires_in": 60,
                "entry_file": "RobRun.exe",
                "launch_args": "",
                # keep the vendor contract: RobRun.exe itself never spawns
                # the game (it only looks for "ROB RUN.exe"), so starting it
                # has to stay with the launcher / start.bat.
                "run_steam": False,
                "steam_appid": "4262460",
                "schema": 1,
                "id": int(gid),
            }
            log("launch: vendor ticket unavailable, serving local ticket")
            self._ok(ticket)
            return
        self._err(404, "not found")

    def manifest(self, gid):
        p = package_path(gid)
        size = os.path.getsize(p) if p else 0
        sha = ""
        if p:
            with open(p, "rb") as f:
                sha = hashlib.sha256(f.read()).hexdigest()
        d = {
            "id": int(gid) if gid.isdigit() else 1,
            "name": "ROB RUN",
            "version": package_version(gid),
            "runtime_protocol": "robrun-v1",
            "entry_file": "RobRun.exe",
            "launch_args": "",
            "run_steam": False,
            "steam_appid": "4262460",
            "has_package": p is not None,
            "package_size": size,
            "package_sha256": sha,
            "expires_at": int(time.time()) + 86400,
        }
        d.update(self.official_notice())
        return d

    def official_notice(self):
        """Say who owns the update on THIS machine.

        Our key is bound to one PC. On any other one the vendor answers 403,
        so update.ps1 drops logs\\vendor_down.flag and the update belongs to the
        untouched official loader (start_loader.bat). The flag is what the UI
        reads, so the user gets told instead of watching a silent failure.
        """
        official = os.path.exists(VENDOR_UNAVAILABLE)
        return {
            "official_update": official,
            "official_loader": os.path.join(ROOT, "start_loader.bat") if official else "",
            "update_server": REAL_SERVER if not official else ("http://127.0.0.1:%d" % PORT),
            "notice": ("Обновление делает официальный лоадер: "
                       "в лоадере нажмите «Обновить»." if official else ""),
        }

    def package(self, gid):
        p = package_path(gid)
        if not p:
            self._err(404, "no local package")
            return
        with open(p, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-SHA256", hashlib.sha256(data).hexdigest())
        self.end_headers()
        self.wfile.write(data)


def already_running():
    """True when another copy of this API is alive on the port."""
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/api/v1/ping" % PORT, timeout=1.5) as r:
            body = r.read(64)
        return b'"ok": true' in body.replace(b'"ok":true', b'"ok": true')
    except Exception:
        return False


def main():
    os.makedirs(PKG_DIR, exist_ok=True)
    if already_running():
        log("another copy already serves 127.0.0.1:%d, exiting" % PORT)
        return
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    log("listening on 127.0.0.1:%d pid=%d" % (PORT, os.getpid()))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    try:
        main()
    except Exception:
        import traceback
        with open(os.path.join(ROOT, "api_err.log"), "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), traceback.format_exc()))
        raise




