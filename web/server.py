#!/usr/bin/env python3
"""
CAMECRACK - control web service (container).

- Serves the control page (camecrack.html) on HTTP_PORT.
- Relays PTZ commands to the camera: through its web page (/ptz, no-SD mode),
  or over telnet (TELNET_PORT, SD toolkit mode) by running ptzctl.

No external dependency: Python standard library only.
Nothing is written to the camera: only movement commands are sent.
"""
import base64
import json
import os
import re
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, urlencode
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

CAMERA_IP = os.environ.get("CAMERA_IP", "").strip()
TELNET_PORT = int(os.environ.get("TELNET_PORT", "24"))
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8787"))
# "auto" (default): ptzctl in RAM (no-SD mode), otherwise the SD card one (toolkit mode).
PTZCTL = os.environ.get("PTZCTL", "auto").strip() or "auto"
PTZ_CONF = os.environ.get("PTZ_CONF", "auto").strip() or "auto"
if PTZCTL == "auto":
    PTZ_PREFIX = ("P=/tmp/ptzctl; C=/etc/config/camecrack/ptz.conf; "
                  "[ -x $P ] || { P=/tmp/sd/custom/bin/ptzctl; C=/tmp/sd/custom/configs/ptz.conf; }; ")
    PTZCTL, PTZ_CONF = "$P", "$C"
else:
    PTZ_PREFIX = ""

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, "camecrack.html"), "r", encoding="utf-8") as fh:
    PAGE = fh.read().encode("utf-8")

ALLOWED_DIR = {"up", "down", "left", "right", "stop", "home"}
SPEED_RE = re.compile(r"^[0-9](\.[0-9]+)?$")


class CameraLink:
    """Persistent telnet connection to the camera, with reconnection."""

    def __init__(self):
        self._sock = None
        self._lock = threading.Lock()

    def _connect(self):
        sock = socket.create_connection((CAMERA_IP, TELNET_PORT), timeout=4)
        sock.settimeout(0.6)
        time.sleep(0.35)
        try:  # drain telnet negotiation / initial prompt
            while True:
                if not sock.recv(1024):
                    break
        except socket.timeout:
            pass
        sock.settimeout(4)
        self._sock = sock

    def send(self, cmd):
        if not CAMERA_IP:
            return False
        with self._lock:
            for _ in range(2):
                try:
                    if self._sock is None:
                        self._connect()
                    self._sock.sendall((cmd + "\n").encode("ascii"))
                    return True
                except OSError:
                    self._close()
            return False

    def _close(self):
        try:
            if self._sock:
                self._sock.close()
        except OSError:
            pass
        self._sock = None


LINK = CameraLink()


CAM_HTTP_PORT = int(os.environ.get("CAM_HTTP_PORT", "80"))
PTZ_LOCK = threading.Lock()
# Password of the camera web page (WEB_PASSWORD in the SD card liberator.conf), user "admin".
CAM_WEB_PASSWORD = os.environ.get("CAM_WEB_PASSWORD", "")
CAM_AUTH = {"Authorization": "Basic " + base64.b64encode(
    ("admin:" + CAM_WEB_PASSWORD).encode("utf-8")).decode("ascii")} if CAM_WEB_PASSWORD else {}


def ptz_http(direction, speed):
    """No-SD mode: the camera's own web page runs ptzctl (/ptz), no shell needed.
    Returns True/False, or None when the camera doesn't offer /ptz (e.g. SD toolkit mode)."""
    url = f"http://{CAMERA_IP}:{CAM_HTTP_PORT}/ptz?" + urlencode({"dir": direction, "speed": speed})
    # The camera page (nc) serves one request at a time and re-listens right after: a
    # refused connection just means "busy", so retry quickly instead of falling back to
    # telnet. One request at a time and in order, so a "stop" never overtakes its "move".
    with PTZ_LOCK:
        for attempt in range(10):
            try:
                with urlopen(Request(url, headers=CAM_AUTH), timeout=3) as r:
                    return bool(json.loads(r.read().decode("utf-8", "replace")).get("ok"))
            except HTTPError as e:
                if e.code == 401:
                    print("PTZ: camera web page refused the password (set CAM_WEB_PASSWORD in .env)",
                          flush=True)
                    return False
                return None
            except URLError as e:
                if isinstance(e.reason, ConnectionRefusedError) and attempt < 9:
                    time.sleep(0.05)
                    continue
                return None
            except (OSError, ValueError):
                return None
    return None


# Boot sounds: any audio file -> MP3 8 kHz mono 16 kbit/s (what the camera app plays),
# trimmed, then uploaded to the camera web page (/sound). Active at the next boot.
SOUND_MAX_SECONDS = {"jingle": 10, "bip": 3}


def send_sound(name, data):
    with tempfile.TemporaryDirectory() as tmp:
        src, dst = os.path.join(tmp, "in"), os.path.join(tmp, "out.mp3")
        with open(src, "wb") as fh:
            fh.write(data)
        cmd = ["ffmpeg", "-v", "error", "-y", "-i", src, "-vn", "-t", str(SOUND_MAX_SECONDS[name]),
               "-ac", "1", "-ar", "8000", "-b:a", "16k", "-map_metadata", "-1", "-f", "mp3", dst]
        try:
            res = subprocess.run(cmd, capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as e:
            return False, f"conversion failed: {e}"
        if res.returncode != 0 or not os.path.exists(dst):
            return False, "conversion failed: " + res.stderr.decode("utf-8", "replace")[-200:]
        with open(dst, "rb") as fh:
            mp3 = fh.read()
    url = f"http://{CAMERA_IP}:{CAM_HTTP_PORT}/sound?" + urlencode({"name": name})
    req = Request(url, data=mp3, method="POST",
                  headers=dict(CAM_AUTH, **{"Content-Type": "audio/mpeg"}))
    try:
        with urlopen(req, timeout=30) as r:
            reply = json.loads(r.read().decode("utf-8", "replace"))
    except HTTPError as e:
        try:
            reply = json.loads(e.read().decode("utf-8", "replace"))
        except ValueError:
            reply = {"ok": False, "error": f"camera answered HTTP {e.code}"}
    except (OSError, ValueError) as e:
        return False, f"camera unreachable (no-SD mode needed): {e}"
    if reply.get("ok"):
        return True, f"{name} updated ({len(mp3)} bytes). Reboot the camera to hear it."
    return False, "camera refused: " + str(reply.get("error"))


def camera_get(path, params):
    """GET a camera web page API (with the password); returns (http_code, json_bytes)."""
    url = f"http://{CAMERA_IP}:{CAM_HTTP_PORT}{path}" + ("?" + urlencode(params) if params else "")
    try:
        with urlopen(Request(url, headers=CAM_AUTH), timeout=8) as r:
            return 200, r.read()
    except HTTPError as e:
        return e.code, e.read() or json.dumps({"ok": False, "error": f"HTTP {e.code}"}).encode()
    except OSError as e:
        return 502, json.dumps({"ok": False, "error": f"camera unreachable (no-SD mode needed): {e}"}).encode()


def ptz(direction, speed):
    if not CAMERA_IP:
        return False
    ok = ptz_http(direction, speed)
    if ok is not None:
        return ok
    return ptz_telnet(direction, speed)   # SD toolkit mode: telnet port 24


def ptz_telnet(direction, speed):
    if direction == "stop":
        cmd = f"{PTZCTL} -c {PTZ_CONF} -m stop"
    elif direction == "home":
        cmd = f"{PTZCTL} -c {PTZ_CONF} -h"
    else:
        cmd = f"{PTZCTL} -c {PTZ_CONF} -m {direction} -s {speed}"
    return LINK.send(PTZ_PREFIX + cmd)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/led":
            # Relay to the camera's /led API (settings live on the camera: led.conf).
            q = {k: v[0] for k, v in parse_qs(u.query).items() if k in ("event", "pattern", "test")}
            code, body = camera_get("/led", q)
            self._reply(code, "application/json", body)
            return
        if u.path == "/ptz":
            q = parse_qs(u.query)
            direction = (q.get("dir", [""])[0] or "").lower()
            speed = q.get("speed", ["0.6"])[0]
            if direction not in ALLOWED_DIR:
                self._reply(400, "application/json",
                            b'{"ok":false,"error":"bad dir"}')
                return
            if not SPEED_RE.match(speed):
                speed = "0.6"
            ok = ptz(direction, speed)
            body = json.dumps({"ok": ok, "dir": direction}).encode("utf-8")
            self._reply(200, "application/json", body)
        elif u.path in ("/", "/index.html"):
            self._reply(200, "text/html; charset=utf-8", PAGE)
        elif u.path == "/healthz":
            self._reply(200, "text/plain", b"ok")
        else:
            self._reply(404, "text/plain", b"not found")

    def do_POST(self):
        u = urlparse(self.path)
        if u.path != "/sound":
            self._reply(404, "application/json", b'{"ok":false,"error":"not found"}')
            return
        name = (parse_qs(u.query).get("name", [""])[0] or "").lower()
        length = int(self.headers.get("Content-Length") or 0)
        if name not in SOUND_MAX_SECONDS or not 0 < length <= 30 * 1024 * 1024:
            self._reply(400, "application/json", b'{"ok":false,"error":"bad name or size"}')
            return
        ok, msg = send_sound(name, self.rfile.read(length))
        body = json.dumps({"ok": ok, "message": msg}).encode("utf-8")
        self._reply(200 if ok else 400, "application/json", body)

    def log_message(self, *args):  # silencieux
        pass


def main():
    print(f"CAMECRACK web : http://0.0.0.0:{HTTP_PORT}/  (camera={CAMERA_IP or '??'}:{TELNET_PORT})",
          flush=True)
    srv = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
