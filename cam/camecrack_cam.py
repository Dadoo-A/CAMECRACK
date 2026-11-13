#!/usr/bin/env python3
"""CAMECRACK cam - the camera as a PC webcam (Discord, Teams, browser...) with active tracking.

Reads the camera RTSP stream, publishes it as the virtual webcam "Unity Video Capture" and,
if tracking is on, keeps a target centred by driving the PTZ through the camera web page:
  1. a face (YuNet), otherwise 2. a person, otherwise 3. a cat (MobileNet-SSD).

Settings come from CAMECRACK/.env (CAMERA_IP, CAM_WEB_PASSWORD) or the command line.
Run setup_cam.py once first. Keys in the preview window (--preview): t = tracking on/off,
h = PTZ home, q = quit.
"""
import argparse
import base64
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

os.environ.setdefault("OPENCV_FFMPEG_CAPTURE_OPTIONS", "rtsp_transport;tcp")
import socket         # noqa: E402
import subprocess     # noqa: E402
import cv2            # noqa: E402
import numpy as np    # noqa: E402

HERE = Path(__file__).resolve().parent
MODELS = HERE / "models"
# %LOCALAPPDATA% may be missing depending on how the app is started: default to its usual place
GO2RTC = (Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local")
          / "CAMECRACK" / "go2rtc" / "go2rtc.exe")


def port_open(host, port):
    try:
        with socket.create_connection((host, port), timeout=1):
            return True
    except OSError:
        return False


def video_source(ip):
    """The camera's own RTSP server numbers its packets oddly (OpenCV then drops/garbles
    frames: ~4 fps, grey picture), go2rtc cleans it up: use the Docker go2rtc if it runs,
    otherwise start our own go2rtc.exe (installed by setup_cam.py) on private ports."""
    if port_open("127.0.0.1", 8554):
        print("video: through the Docker go2rtc")
        return "rtsp://127.0.0.1:8554/camecrack", None
    exe = next((c for c in (GO2RTC, HERE / "go2rtc.exe", HERE.parent / "go2rtc.exe") if c.is_file()), None)
    if exe is None:
        print("*** go2rtc.exe NOT FOUND (looked for", GO2RTC, ")")
        print("*** Run Install-Cam.bat. Falling back to the camera's own stream: expect freezes.")
        return f"rtsp://{ip}:554/main_ch", None
    cfg = Path(os.environ.get("TEMP", str(HERE))) / "camecrack_cam_go2rtc.yaml"
    cfg.write_text(f'api:\n  listen: "127.0.0.1:11984"\nrtsp:\n  listen: "127.0.0.1:18554"\n'
                   f'webrtc:\n  listen: ""\nlog:\n  level: error\n'
                   f'streams:\n  camecrack: rtsp://{ip}:554/main_ch\n', encoding="utf-8")
    proc = subprocess.Popen([str(exe), "-config", str(cfg)], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
    for _ in range(50):
        if port_open("127.0.0.1", 18554):
            break
        time.sleep(0.1)
    if proc.poll() is not None or not port_open("127.0.0.1", 18554):
        print("*** go2rtc did not start (blocked by an antivirus / Smart App Control?):", exe)
        print("*** Falling back to the camera's own stream: expect freezes.")
        return f"rtsp://{ip}:554/main_ch", None
    print("video: through a local go2rtc (", exe, ")")
    return "rtsp://127.0.0.1:18554/camecrack", proc


SSD_CLASSES = {15: "person", 8: "cat"}      # MobileNet-SSD (VOC) class ids


def read_env():
    env = {}
    f = HERE.parent / ".env"
    if f.exists():
        for line in f.read_text(encoding="utf-8").splitlines():
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


class Grabber(threading.Thread):
    """Keeps only the latest frame (no buffering = low latency); reconnects on errors."""

    def __init__(self, url, hw=False):
        super().__init__(daemon=True)
        self.url, self.frame, self.lock, self.alive, self.hw = url, None, threading.Lock(), True, hw
        self.count, self.t_last, self.max_gap = 0, 0.0, 0.0     # stats printed every 10 s
        self.threads = 1

    def run(self):
        while self.alive:
            # Latency (measured 2026-11-13, PTZ command -> motion seen): FFmpeg's default
            # 12-thread frame decoding queues ~11 frames = 1.4 s; 2 threads = 0.7 s (default).
            # Hardware decoding (D3D11, --hw) = 0.4 s but the Intel decoder rejects part of this
            # camera's frames (garbled picture), so it is opt-in.
            hw = False
            if self.hw:
                cap = cv2.VideoCapture(self.url, cv2.CAP_FFMPEG,
                                       [cv2.CAP_PROP_HW_ACCELERATION, cv2.VIDEO_ACCELERATION_D3D11])
                hw = cap.isOpened() and cap.get(cv2.CAP_PROP_HW_ACCELERATION) > 0
                if not hw:
                    cap.release()
            if not hw:
                # 1 thread = least latency (each extra frame thread queues one more frame);
                # switched to 2 below if the decoder cannot keep up (15 img/s in daylight).
                cap = cv2.VideoCapture(self.url, cv2.CAP_FFMPEG, [cv2.CAP_PROP_N_THREADS, self.threads])
            if not cap.isOpened():
                print("stream: cannot open, retrying in 3 s ...")
                time.sleep(3)
                continue
            print("stream: connected, decoding:",
                  "hardware (D3D11)" if hw else f"CPU, {self.threads} thread(s)")
            fails = reads = instant = 0
            while self.alive:
                t_read = time.time()
                ok, f = cap.read()
                if ok and not hw and self.threads == 1:
                    # a read that returns at once means frames were already waiting = falling behind
                    reads += 1
                    instant += (time.time() - t_read) < 0.012
                    if reads >= 90:
                        if instant > 60:
                            print("stream: decoder falling behind, switching to 2 threads")
                            self.threads = 2
                            break
                        reads = instant = 0
                if not ok:
                    # the first reads can fail while the decoder starts: give it 3 s
                    fails += 1
                    if fails > 30:
                        print("stream: lost, reconnecting ...")
                        break
                    time.sleep(0.1)
                    continue
                fails = 0
                now = time.time()
                self.max_gap = max(self.max_gap, now - self.t_last) if self.t_last else 0.0
                self.t_last, self.count = now, self.count + 1
                with self.lock:
                    self.frame = f
            cap.release()

    def latest(self):
        with self.lock:
            return None if self.frame is None else self.frame


class PTZ:
    """Pan/tilt through the camera web page (/ptz), one short 'nudge' at a time."""

    def __init__(self, ip, password, speed):
        self.base, self.speed = f"http://{ip}/ptz?", speed
        self.headers = {}
        if password:
            tok = base64.b64encode(f"admin:{password}".encode()).decode()
            self.headers["Authorization"] = "Basic " + tok
        self.busy = False

    def cmd(self, d, speed=None):
        q = urllib.parse.urlencode({"dir": d, "speed": f"{speed or self.speed:.2f}"})
        # the camera page serves one request at a time: "connection refused" = busy, retry
        for attempt in range(10):
            try:
                with urllib.request.urlopen(urllib.request.Request(self.base + q, headers=self.headers),
                                            timeout=3) as r:
                    r.read()
                return
            except urllib.error.URLError as e:
                if isinstance(e.reason, (ConnectionRefusedError, ConnectionResetError)) and attempt < 9:
                    time.sleep(0.05)
                    continue
                print("ptz:", e)
                return
            except ConnectionResetError:          # camera page closed the socket: busy, retry
                if attempt < 9:
                    time.sleep(0.05)
                    continue
                return
            except OSError as e:
                print("ptz:", e)
                return

    def cont(self, d, speed):
        """Continuous move (camera /ptz?cont=1) or 'stop', in the background. The camera stops
        by itself after 2 s unless the move is renewed. Returns at once."""
        q = {"dir": d, "speed": f"{speed:.2f}"}
        if d != "stop":
            q["cont"] = "1"
        url = self.base + urllib.parse.urlencode(q)

        def run():
            for attempt in range(10):
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers=self.headers),
                                                timeout=3) as r:
                        self.cont_ok = b'"cont-' in r.read() if d != "stop" else self.cont_ok
                    return
                except (urllib.error.URLError, ConnectionResetError) as e:
                    reason = getattr(e, "reason", e)
                    if isinstance(reason, (ConnectionRefusedError, ConnectionResetError)) and attempt < 9:
                        time.sleep(0.05)
                        continue
                    return
                except OSError:
                    return
        threading.Thread(target=run, daemon=True).start()

    cont_ok = None

    def rel(self, pan_deg, tilt_deg, done=None):
        """Relative move of both axes at once (camera /ptz?rel=, ptzctl -J), in the background.
        pan > 0 = right, tilt > 0 = up. done(ok) gets False if the camera page is too old."""
        if self.busy:
            return
        self.busy = True
        q = urllib.parse.urlencode({"rel": f"{pan_deg / 180:.4f},{tilt_deg / 98:.4f}"})

        def run():
            ok = False
            try:
                for attempt in range(10):
                    try:
                        req = urllib.request.Request(self.base + q, headers=self.headers)
                        with urllib.request.urlopen(req, timeout=3) as r:
                            ok = b'"rel"' in r.read()
                        break
                    except (urllib.error.URLError, ConnectionResetError) as e:
                        reason = getattr(e, "reason", e)
                        if isinstance(reason, (ConnectionRefusedError, ConnectionResetError)) and attempt < 9:
                            time.sleep(0.05)
                            continue
                        break
                    except OSError:
                        break
                # let ptzctl finish before the next correction (measured: 0.3-0.5 s for ~9 degrees)
                time.sleep(0.15 + max(abs(pan_deg), abs(tilt_deg)) / 60)
            finally:
                self.busy = False
                if done:
                    done(ok)
        threading.Thread(target=run, daemon=True).start()

    def nudge(self, d, seconds, speed):
        """Move for `seconds` then stop, in the background (one nudge at a time)."""
        if self.busy:
            return
        self.busy = True

        def run():
            try:
                self.cmd(d, speed)
                time.sleep(seconds)
                self.cmd("stop")
            finally:
                self.busy = False
        threading.Thread(target=run, daemon=True).start()


class Detector:
    """Face first (YuNet), then person, then cat (MobileNet-SSD), on a small copy of the frame."""

    def __init__(self, w=640, h=360):
        self.w, self.h = w, h
        self.face = cv2.FaceDetectorYN.create(str(MODELS / "face_detection_yunet_2023mar.onnx"),
                                              "", (w, h), 0.75, 0.3, 50)
        self.ssd = cv2.dnn.readNetFromCaffe(str(MODELS / "deploy.prototxt"),
                                            str(MODELS / "mobilenet_iter_73000.caffemodel"))

    def detect(self, frame):
        """Return (kind, (x, y, w, h)) in small-frame pixels, or None."""
        small = cv2.resize(frame, (self.w, self.h))
        _, faces = self.face.detect(small)
        if faces is not None and len(faces):
            f = max(faces, key=lambda r: r[2] * r[3])
            return "face", tuple(int(v) for v in f[:4]), small
        blob = cv2.dnn.blobFromImage(cv2.resize(small, (300, 300)), 0.007843, (300, 300), 127.5)
        self.ssd.setInput(blob)
        out = self.ssd.forward()[0, 0]
        best = {}
        for det in out:
            cls, conf = int(det[1]), float(det[2])
            if cls in SSD_CLASSES and conf > 0.5:
                x1, y1, x2, y2 = (det[3:7] * [self.w, self.h, self.w, self.h]).astype(int)
                area = (x2 - x1) * (y2 - y1)
                name = SSD_CLASSES[cls]
                if area > best.get(name, (0,))[0]:
                    best[name] = (area, (x1, y1, x2 - x1, y2 - y1))
        for name in ("person", "cat"):
            if name in best:
                return name, best[name][1], small
        return None, None, small


class Tracker(threading.Thread):
    """Detection + PTZ in its own thread, at its own pace: the webcam output never waits for it."""

    def __init__(self, grab, det, ptz, args):
        super().__init__(daemon=True)
        self.grab, self.det, self.ptz, self.a = grab, det, ptz, args
        self.enabled = not args.no_track
        self.alive = True
        self.kind = self.box = None
        self.last_seen = 0.0

    def run(self):
        """Continuous tracking: every detection (8/s) sends a small relative pan+tilt correction
        towards the target. Corrections sent during the last `latency` seconds are not visible in
        the video yet, so they are subtracted from the measured error (no overshoot/oscillation).
        Falls back to short left/right/up/down nudges with an older camera page."""
        from collections import deque
        a = self.a
        last_frame, last_cmd, pending = None, 0.0, deque()
        while self.alive:
            frame = self.grab.latest()
            if not self.enabled or frame is None or frame is last_frame:
                time.sleep(0.01)
                continue
            last_frame = frame
            if time.time() - getattr(self, "_last_det", 0) < 0.125:   # up to 8 detections/s
                time.sleep(0.01)
                continue
            self._last_det = time.time()
            kind, box, _ = self.det.detect(frame)
            self.kind, self.box = kind, box
            now = time.time()
            if not box:
                if self.pan_dir and now - self.last_seen > 0.5:
                    self.ptz.cont("stop", 0)
                    self.pan_dir, self.pan_speed = 0, 0.0
                continue
            self.last_seen = now
            x, y, bw, bh = box
            # error from the centre, -1..1; for a person aim at the upper body
            ex = (x + bw / 2) / self.det.w * 2 - 1
            ey = ((y + (bh * 0.3 if kind == "person" else bh / 2)) / self.det.h) * 2 - 1
            if a.invert_pan:
                ex = -ex
            if a.invert_tilt:
                ey = -ey
            if self.rel_ok is False:                       # old camera page: nudges
                if now - last_cmd > 0.7 and not self.ptz.busy:
                    if abs(ex) > 0.15 and abs(ex) >= abs(ey):
                        self.ptz.nudge("right" if ex > 0 else "left", 0.08 + 0.25 * abs(ex), a.speed)
                        last_cmd = now
                    elif abs(ey) > 0.2:
                        self.ptz.nudge("down" if ey > 0 else "up", 0.06 + 0.2 * abs(ey), a.speed)
                        last_cmd = now
                continue
            # degrees to turn (x > 0 = right, y > 0 = down)
            while pending and now - pending[0][0] > a.latency:
                pending.popleft()
            cx = ex * a.hfov / 2
            cy = ey * a.hfov * 9 / 16 / 2 - sum(q[2] for q in pending)
            if a.track_mode == "cont" and self.ptz.cont_ok is not False:
                # PAN = velocity control: turn continuously towards the target, speed proportional
                # to the error, minus the turn that the video does not show yet (latency).
                cx -= self.pan_dir * self.pan_speed * a.pan_rate * a.latency
                if abs(cx) < a.deadzone:
                    want_dir, want_speed = 0, 0.0
                else:
                    want_dir = 1 if cx > 0 else -1
                    want_speed = round(min(a.max_speed, max(0.05, abs(cx) * a.gain / 30)) * 20) / 20
                if want_dir == 0 and self.pan_dir != 0:
                    self.ptz.cont("stop", 0)
                    self.pan_dir, self.pan_speed = 0, 0.0
                elif want_dir and (want_dir != self.pan_dir or want_speed != self.pan_speed
                                   or now - self.pan_t > 1.2):     # renew before the 2 s auto-stop
                    self.ptz.cont("right" if want_dir > 0 else "left", want_speed)
                    self.pan_dir, self.pan_speed, self.pan_t = want_dir, want_speed, now
                mx = 0
            else:
                cx -= sum(q[1] for q in pending)
                mx = 0 if abs(cx) < a.deadzone else int(round(max(-25, min(25, a.gain * cx))))
            # TILT (and PAN on an older camera page): small relative corrections
            my = 0 if abs(cy) < a.deadzone * 1.5 else int(round(max(-15, min(15, a.gain * cy))))
            if (mx or my) and not self.ptz.busy and now - last_cmd > 0.1:
                self.ptz.rel(mx, -my, done=self._rel_result)
                pending.append((now, mx, my))
                last_cmd = now

    rel_ok = None
    pan_dir, pan_speed, pan_t = 0, 0.0, 0.0

    def _rel_result(self, ok):
        if self.rel_ok is None:
            self.rel_ok = ok
            print("tracking:", "continuous (relative moves)" if ok else
                  "step by step (update the camera with the SD card for continuous tracking)")


def main():
    env = read_env()
    ap = argparse.ArgumentParser(description="CAMECRACK camera as a PC webcam, with tracking")
    ap.add_argument("--ip", default=env.get("CAMERA_IP"), help="camera IP (default: .env)")
    ap.add_argument("--password", default=env.get("CAM_WEB_PASSWORD", ""))
    ap.add_argument("--source", help="video URL (default rtsp://<ip>:554/main_ch)")
    ap.add_argument("--size", default="1280x720", help="webcam size (default 1280x720)")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--no-track", action="store_true", help="webcam only, no tracking")
    ap.add_argument("--no-webcam", action="store_true", help="tracking only (no virtual webcam)")
    ap.add_argument("--preview", action="store_true", help="show a preview window with boxes")
    ap.add_argument("--speed", type=float, default=0.6, help="PTZ speed 0.2..1")
    ap.add_argument("--hw", action="store_true", help="hardware video decoding (lower latency, "
                    "but may garble this camera's picture)")
    ap.add_argument("--hfov", type=float, default=85, help="camera horizontal field of view (deg)")
    ap.add_argument("--gain", type=float, default=0.9, help="tracking correction gain 0.2..1")
    ap.add_argument("--deadzone", type=float, default=3, help="degrees left uncorrected")
    ap.add_argument("--latency", type=float, default=0.9, help="video latency to compensate (s)")
    ap.add_argument("--pan-rate", type=float, default=60, help="pan degrees/s at speed 1 (continuous)")
    ap.add_argument("--max-speed", type=float, default=0.6, help="max continuous pan speed 0.05..1")
    ap.add_argument("--track-mode", choices=["rel", "cont"], default="rel",
                    help="rel = small relative corrections (default); cont = continuous pan (experimental)")
    ap.add_argument("--invert-pan", action="store_true")
    ap.add_argument("--invert-tilt", action="store_true")
    a = ap.parse_args()
    if not a.ip and not a.source:
        raise SystemExit("Camera IP unknown: put CAMERA_IP in CAMECRACK/.env or use --ip")
    W, H = (int(v) for v in a.size.lower().split("x"))

    src, g2r = (a.source, None) if a.source else video_source(a.ip)
    grab = Grabber(src, hw=a.hw)
    grab.start()
    cv2.setNumThreads(2)          # leave CPU cores to the video decoder (laptops!)
    det = Detector()
    ptz = PTZ(a.ip, a.password, a.speed)
    trk = Tracker(grab, det, ptz, a)
    trk.start()

    cam = None
    if not a.no_webcam:
        import pyvirtualcam
        cam = pyvirtualcam.Camera(width=W, height=H, fps=a.fps, backend="unitycapture")
        print(f"webcam: '{cam.device}' {W}x{H}@{a.fps} - pick it in Discord / Teams / the browser")
    print("tracking:", "on (face > person > cat)" if trk.enabled else "off")

    black = np.zeros((H, W, 3), np.uint8)
    stats_t = time.time()
    try:
        while True:
            t0 = time.time()
            frame = grab.latest()
            out = black if frame is None else cv2.resize(frame, (W, H))
            kind, box = trk.kind, trk.box
            if t0 - stats_t >= 10:
                print(f"video: {grab.count / (t0 - stats_t):.1f} img/s received, "
                      f"longest freeze {grab.max_gap * 1000:.0f} ms (last 10 s)")
                grab.count, grab.max_gap, stats_t = 0, 0.0, t0

            if cam:
                cam.send(cv2.cvtColor(out, cv2.COLOR_BGR2RGB))
            if a.preview:
                view = out.copy()
                if box and frame is not None and t0 - trk.last_seen < 1:
                    sx, sy = W / det.w, H / det.h
                    x, y, bw, bh = box
                    cv2.rectangle(view, (int(x * sx), int(y * sy)), (int((x + bw) * sx), int((y + bh) * sy)),
                                  (0, 255, 0), 2)
                    cv2.putText(view, kind, (int(x * sx), int(y * sy) - 6), cv2.FONT_HERSHEY_SIMPLEX,
                                0.7, (0, 255, 0), 2)
                cv2.putText(view, "tracking " + ("ON" if trk.enabled else "off") + "  (t/h/q)", (10, 25),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 200, 255), 2)
                cv2.imshow("CAMECRACK", view)
                k = cv2.waitKey(1) & 0xFF
                if k == ord("q"):
                    break
                if k == ord("t"):
                    trk.enabled = not trk.enabled
                    print("tracking:", trk.enabled)
                if k == ord("h"):
                    ptz.cmd("home")
            if cam:
                cam.sleep_until_next_frame()
            else:
                time.sleep(max(0, 1 / a.fps - (time.time() - t0)))
    except KeyboardInterrupt:
        pass
    finally:
        grab.alive = trk.alive = False
        if g2r:
            g2r.terminate()
        if cam:
            cam.close()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
