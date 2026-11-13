#!/usr/bin/env python3
"""CAMECRACK cam - one-time setup on a Windows PC (re-run it on any new PC).

  1. Python packages (requirements.txt)
  2. Detection models (face: YuNet, person/cat: MobileNet-SSD) -> cam/models/
  3. Virtual webcam driver (Unity Capture, DirectShow) -> %LOCALAPPDATA%\\CAMECRACK\\UnityCapture,
     registered with regsvr32 (Windows asks for administrator rights once).
  4. go2rtc.exe (cleans up the camera stream when Docker is not running).

Everything is downloaded from pinned versions and checked with SHA-256.
Uninstall the driver:  python setup_cam.py --uninstall
Needs the Microsoft Visual C++ Redistributable (2015-2022, x64): the script tells you if missing.
"""
import argparse
import hashlib
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
MODELS = HERE / "models"
DRIVER_DIR = Path(os.environ.get("LOCALAPPDATA") or Path.home() / "AppData" / "Local") / "CAMECRACK" / "UnityCapture"

UC = "https://raw.githubusercontent.com/schellingb/UnityCapture/3ed54c325e0ad71afcf4f246c07e5e17b3d7f2d2/Install/"
ZOO = ("https://media.githubusercontent.com/media/opencv/opencv_zoo/48b10fa505aeb51fbd127fc60a5c660040e823b7/"
       "models/face_detection_yunet/")
SSD = "https://raw.githubusercontent.com/chuanqi305/MobileNet-SSD/bb17b6c3eef36d80be441ae8e5339be66e8e3b7a/"

FILES = [  # (url, destination folder, sha256)
    (ZOO + "face_detection_yunet_2023mar.onnx", MODELS,
     "8f2383e4dd3cfbb4553ea8718107fc0423210dc964f9f4280604804ed2552fa4"),
    (SSD + "deploy.prototxt", MODELS,
     "2d180f723b3109e21f8287f6b3c691390d07b60eed998327cd3259ffa0e50608"),
    (SSD + "mobilenet_iter_73000.caffemodel", MODELS,
     "52eed8be80522c152a17fb56740de705b79881bde1a167e0e747310523685fc7"),
    (UC + "UnityCaptureFilter64.dll", DRIVER_DIR,
     "72812f5363d8ecb45632253f8c8c888844b1b62e27616f3c8cc21064ccde25e5"),
    (UC + "UnityCaptureFilter32.dll", DRIVER_DIR,
     "aa3ebdf03dea7f3aab3dd7b724751f49ed71672256b57c6a19aa6809cabf30ba"),
]
# go2rtc cleans up the camera's RTSP stream (its packet numbering confuses OpenCV/FFmpeg:
# grey, smeared frames at ~4 fps instead of a clean 15 fps). Used when Docker isn't running.
GO2RTC_ZIP = ("https://github.com/AlexxIT/go2rtc/releases/download/v1.9.15/go2rtc_win64.zip",
              "5b448fc90f15c925406d8da0984301985e385050222c1c2bbdf0a76fe4b1e9cb")
GO2RTC_DIR = DRIVER_DIR.parent / "go2rtc"


def sha256(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url, folder, digest):
    folder.mkdir(parents=True, exist_ok=True)
    dst = folder / url.rsplit("/", 1)[1]
    if dst.exists() and sha256(dst) == digest:
        print(f"  ok        {dst.name}")
        return dst
    print(f"  download  {dst.name}")
    req = urllib.request.Request(url, headers={"User-Agent": "camecrack-setup"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != digest:
        sys.exit(f"ERROR: checksum mismatch for {dst.name} (download corrupted or changed upstream)")
    dst.write_bytes(data)
    return dst


def regsvr32(dll, unregister=False):
    """Run regsvr32 elevated (UAC prompt); the 32-bit DLL goes through SysWOW64."""
    sysdir = "SysWOW64" if dll.name.endswith("32.dll") else "System32"
    exe = Path(os.environ.get("SystemRoot", r"C:\Windows")) / sysdir / "regsvr32.exe"
    args = ("/u " if unregister else "") + f'/s "{dll}"'
    ps = f"Start-Process -FilePath '{exe}' -ArgumentList '{args}' -Verb RunAs -Wait"
    return subprocess.run(["powershell", "-NoProfile", "-Command", ps]).returncode == 0


def driver_registered():
    """Is "Unity Video Capture" in the 64-bit DirectShow video input devices (what Discord,
    Teams and browsers use)?"""
    import winreg
    key = r"CLSID\{860BB310-5D01-11d0-BD3B-00A0C911CE86}\Instance\{5C2CD55C-92AD-4999-8666-912BD3E70010}"
    try:
        winreg.CloseKey(winreg.OpenKey(winreg.HKEY_CLASSES_ROOT, key, 0,
                                       winreg.KEY_READ | winreg.KEY_WOW64_64KEY))
        return True
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser(description="CAMECRACK cam setup")
    ap.add_argument("--uninstall", action="store_true", help="unregister the virtual webcam driver")
    a = ap.parse_args()
    if os.name != "nt":
        sys.exit("The virtual webcam part is Windows-only (Unity Capture driver).")

    dlls = [DRIVER_DIR / "UnityCaptureFilter64.dll", DRIVER_DIR / "UnityCaptureFilter32.dll"]
    if a.uninstall:
        for d in dlls:
            if d.exists():
                print(f"Unregistering {d.name} (Windows will ask for administrator rights) ...")
                regsvr32(d, unregister=True)
        print("Done. You can now delete", DRIVER_DIR)
        return

    print("1/3 Python packages ...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--disable-pip-version-check",
                           "-q", "-r", str(HERE / "requirements.txt")])
    msvcp = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32" / "msvcp140.dll"
    if not msvcp.exists():
        print("\nThe Microsoft Visual C++ Redistributable (x64) is missing. Install it, then re-run:\n"
              "  winget install --id Microsoft.VCRedist.2015+.x64 -e\n"
              "  or https://aka.ms/vs/17/release/vc_redist.x64.exe")
        sys.exit(1)

    print("2/3 Models and driver files (pinned, SHA-256 checked) ...")
    for url, folder, digest in FILES:
        fetch(url, folder, digest)
    exe = GO2RTC_DIR / "go2rtc.exe"
    if not exe.exists():
        import zipfile
        z = fetch(GO2RTC_ZIP[0], GO2RTC_DIR, GO2RTC_ZIP[1])
        with zipfile.ZipFile(z) as zf:
            exe.write_bytes(zf.read("go2rtc.exe"))
        z.unlink()
    print(f"  ok        go2rtc.exe ({GO2RTC_DIR})")

    if driver_registered():
        print("3/3 Virtual webcam already registered")
    else:
        print("3/3 Registering the virtual webcam 'Unity Video Capture' "
              "(Windows asks for administrator rights) ...")
        for d in dlls:
            if not regsvr32(d):
                sys.exit(f"ERROR: could not register {d.name}")

    import pyvirtualcam  # noqa: E402  (installed in step 1)
    try:
        with pyvirtualcam.Camera(width=640, height=360, fps=10, backend="unitycapture") as cam:
            print(f"Virtual webcam OK: '{cam.device}'")
    except Exception as e:  # noqa: BLE001
        sys.exit(f"ERROR: the virtual webcam does not open ({e})")
    print("\nSetup done. Start the camera with Start-Cam.bat (or: python camecrack_cam.py).")


if __name__ == "__main__":
    main()
