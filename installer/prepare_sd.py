#!/usr/bin/env python3
"""CAMECRACK - plug-and-play SD card preparer (Windows, macOS, Linux).

1. Downloads the SD root toolkit (github.com/tasarren/lsc-tuya-toolkit, pinned to the tested
   commit; it is not redistributed here) and copies its sd_card/ folder to the card.
2. Adds the CAMECRACK files on top (sd-overlay/) and the no-SD mode (no-sd/ -> camecrack/),
   with two small edits of toolkit files (liberator start in entrypoint.sh; status LED and
   time overlay off in _ht_sw_settings.ini).
3. Writes your Wi-Fi settings and the camera web page password.
Then: insert the card in the camera, power on -> local mode, no cloud, and the "liberator"
installs the no-SD mode into the camera's flash by itself.
Offline: --toolkit-zip <file> uses a zip of the toolkit downloaded beforehand.

Interactive (simplest):  python3 prepare_sd.py        (Windows: double-click Prepare-SD.bat)
Direct:
  python3 prepare_sd.py --sd E: --ssid "My Wifi" --password "secret" --web-password "pw"
  python3 prepare_sd.py --sd /Volumes/CAM ...        (macOS)
  python3 prepare_sd.py --sd /media/$USER/CAM ...    (Linux)
Options: --security 3 (1=open, 2=wep, 3=wpa/wpa2)  --dhcp 1  --clean (remove the old payload)
         --toolkit-zip FILE (offline)  --yes (no confirmation)

The backup/ folder on the card (flash backups made by the liberator) is never deleted.
Python 3.8+ standard library only.
"""
import argparse
import getpass
import os
import re
import io
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
OVERLAY = HERE / "sd-overlay"
NO_SD = HERE / "no-sd"
TOOLKIT_COMMIT = "396db8a835d9787b2997de038b48f645c837e754"   # tested version
TOOLKIT_URL = f"https://github.com/tasarren/lsc-tuya-toolkit/archive/{TOOLKIT_COMMIT}.zip"
# Old payload entries removed by --clean. backup/ is NEVER in this list.
CLEAN = ["custom", "logs", "hostapd", "hack.sh", "shadow", "TZ", "_ak39_factory.ini",
         "_ak39_factory_done", "_ht_ap_mode.conf", "_ht_av_mode.conf.disabled",
         "_ht_get_log.conf.disabled", "camecrack"]
SHELL_SPECIAL = re.compile(r'["$`\\]')   # these break files that the camera reads with sh


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def ask(prompt, secret=False):
    try:
        return getpass.getpass(prompt + ": ") if secret else input(prompt + ": ")
    except (EOFError, KeyboardInterrupt):
        print()
        sys.exit(1)


def removable_candidates():
    """Best-effort list of mounted removable volumes: [(path, description)]."""
    out = []
    if os.name == "nt":
        import ctypes
        k32 = ctypes.windll.kernel32
        mask = k32.GetLogicalDrives()
        for i in range(26):
            if mask >> i & 1:
                root = f"{chr(65 + i)}:\\"
                if k32.GetDriveTypeW(root) == 2:          # DRIVE_REMOVABLE
                    out.append((root, f"{fs_type(root) or '?'}  {size_gb(root)}"))
    else:
        user = os.environ.get("USER", "")
        for base in ("/Volumes", f"/media/{user}", f"/run/media/{user}", "/media"):
            p = Path(base)
            if p.is_dir():
                for d in sorted(p.iterdir()):
                    if d.is_dir() and os.path.ismount(d) and str(d) != "/":
                        out.append((str(d), f"{fs_type(str(d)) or '?'}  {size_gb(str(d))}"))
    return out


def size_gb(path):
    try:
        return f"{shutil.disk_usage(path).total / 1e9:.1f} GB"
    except OSError:
        return ""


def fs_type(path):
    """File system name (FAT32, vfat, exfat...) or '' if unknown."""
    if os.name == "nt":
        import ctypes
        buf = ctypes.create_unicode_buffer(32)
        ok = ctypes.windll.kernel32.GetVolumeInformationW(
            ctypes.c_wchar_p(path), None, 0, None, None, None, buf, len(buf))
        return buf.value if ok else ""
    try:
        best = ("", "")
        with open("/proc/mounts") as f:            # Linux
            for line in f:
                parts = line.split()
                mnt = parts[1].replace("\\040", " ")
                if path.startswith(mnt) and len(mnt) > len(best[0]):
                    best = (mnt, parts[2])
        return best[1]
    except OSError:
        return ""                                    # macOS: unknown, no warning


def load_toolkit(zip_path=None):
    """Return {relative path on the card: bytes} from the toolkit's sd_card/ folder."""
    if zip_path:
        data = Path(zip_path).read_bytes()
    else:
        print(f"Downloading the SD toolkit ({TOOLKIT_COMMIT[:7]}) from GitHub ...")
        try:
            req = urllib.request.Request(TOOLKIT_URL, headers={"User-Agent": "camecrack-prepare-sd"})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
        except OSError as e:
            die(f"download failed ({e}). Download {TOOLKIT_URL} by hand and use --toolkit-zip")
    files = {}
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            for name in z.namelist():
                parts = name.split("/", 2)          # <repo>-<sha>/sd_card/<path>
                if len(parts) == 3 and parts[1] == "sd_card" and parts[2] and not name.endswith("/"):
                    files[parts[2]] = z.read(name)
    except zipfile.BadZipFile:
        die("the toolkit file is not a valid zip")
    for needed in ("hack.sh", "hostapd", "custom/scripts/entrypoint.sh",
                   "custom/configs/_ht_sw_settings.ini", "custom/bin/ptzctl"):
        if needed not in files:
            die(f"unexpected toolkit content: {needed} missing")
    return files


def patch_toolkit(root):
    """The only two edits of toolkit files (kept as small, checked text substitutions)."""
    ep = root / "custom" / "scripts" / "entrypoint.sh"
    t = ep.read_bytes().decode("utf-8")
    line = '/bin/sh "${SCRIPTS_DIR}/liberator.sh" >/dev/null 2>&1 &\n'
    if line not in t:
        anchor = '/bin/sh "${SCRIPTS_DIR}/telnet.sh"'
        if anchor not in t:
            die("entrypoint.sh: unexpected content, cannot add the liberator")
        t = t.replace(anchor, "# CAMECRACK: install/update the no-SD mode into the flash "
                      "(see liberator.sh)\n" + line + anchor, 1)
        ep.write_bytes(t.encode("utf-8"))
    sw = root / "custom" / "configs" / "_ht_sw_settings.ini"
    t = sw.read_bytes().decode("utf-8")
    # status LED driven by CAMECRACK only; time overlay off (it ignores the time zone)
    t = re.sub(r"(?m)^(bool_led_enable\s*=\s*)1", r"\g<1>0", t)
    t = re.sub(r"(?m)^(bool_osd_time\s*=\s*)1", r"\g<1>0", t)
    sw.write_bytes(t.encode("utf-8"))


def normalize_target(sd):
    sd = sd.strip().strip('"')
    if os.name == "nt" and re.fullmatch(r"[A-Za-z]:?\\?", sd):
        sd = sd[0].upper() + ":\\"
    return Path(sd)


def main():
    ap = argparse.ArgumentParser(description="Prepare a CAMECRACK SD card.")
    ap.add_argument("--sd", help="SD card: drive letter (E:) or mount point (/Volumes/CAM)")
    ap.add_argument("--ssid", help="Wi-Fi network name (2.4 GHz)")
    ap.add_argument("--password", help="Wi-Fi password")
    ap.add_argument("--web-password", help="camera web page password (user admin); '' = none")
    ap.add_argument("--security", type=int, default=3, choices=[1, 2, 3],
                    help="1=open, 2=wep, 3=wpa/wpa2 (default 3)")
    ap.add_argument("--dhcp", type=int, default=1, choices=[0, 1])
    ap.add_argument("--clean", action="store_true", help="remove the old payload first")
    ap.add_argument("--yes", action="store_true", help="don't ask for confirmations")
    ap.add_argument("--toolkit-zip", help="use this toolkit zip instead of downloading it")
    a = ap.parse_args()

    if not OVERLAY.is_dir() or not NO_SD.is_dir():
        die(f"CAMECRACK files not found next to this script ({OVERLAY}, {NO_SD})")

    # --- 1. SD card -----------------------------------------------------------
    if not a.sd:
        cands = removable_candidates()
        print("Removable volumes found:")
        for path, desc in cands:
            print(f"   {path}   {desc}")
        if not cands:
            print("   (none found - insert the SD card, or type its path)")
        a.sd = ask("SD card (drive letter like E, or mount point)")
    root = normalize_target(a.sd)
    if not root.is_dir():
        die(f"{root} not found")
    if root.resolve() == Path(root.anchor).resolve() and os.name != "nt":
        die("refused: that is the root of the system disk")
    if os.name == "nt" and str(root).upper().startswith("C:"):
        die("refused: C: is the system drive")
    if root.resolve() == Path.home().resolve():
        die("refused: that is your home folder")
    if str(root) not in [c[0] for c in removable_candidates()] and not a.yes:
        if ask(f"WARNING: {root} was not detected as a removable card. Continue? (yes/no)") != "yes":
            die("cancelled")
    fs = fs_type(str(root)).lower()
    if fs and fs not in ("fat32", "fat", "vfat", "msdos"):
        print(f"Note: the card is {fs}. The camera expects FAT32 - reformat it if it does not boot.")

    # --- 2. Wi-Fi + web password ---------------------------------------------
    ssid = a.ssid if a.ssid is not None else ask("Wi-Fi network name (SSID, 2.4 GHz)")
    pw = a.password if a.password is not None else ask("Wi-Fi password", secret=True)
    web = a.web_password
    if web is None:
        web = ask("Password for the camera web page (Wi-Fi settings + PTZ, user admin; empty = none)",
                  secret=True)
    if not ssid:
        die("empty SSID")
    if SHELL_SPECIAL.search(web):
        die('the web page password cannot contain " $ ` or \\ (the file is read by a shell)')
    if SHELL_SPECIAL.search(ssid) or SHELL_SPECIAL.search(pw):
        print('Warning: the SSID/password contains " $ ` or \\ which may cause trouble '
              "(file read by a shell). Check it if the connection fails.")

    # --- 3. toolkit (downloaded before touching the card: fail early) ---------
    toolkit = load_toolkit(a.toolkit_zip)

    # --- 4. optional cleanup --------------------------------------------------
    if a.clean:
        print(f"Removing the old payload from {root} ...")
        for name in CLEAN:
            p = root / name
            if p.is_dir():
                shutil.rmtree(p, ignore_errors=True)
            elif p.exists():
                p.unlink()

    # --- 5. copy (binary: keeps ptzctl and LF line endings) -------------------
    print(f"Copying the toolkit ({len(toolkit)} files) to {root} ...")
    for rel, data in toolkit.items():
        dst = root / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_bytes(data)
    print("Adding the CAMECRACK files ...")
    shutil.copytree(OVERLAY, root, dirs_exist_ok=True)
    patch_toolkit(root)
    cc = root / "camecrack"            # no-SD mode installed into the flash by the liberator
    cc.mkdir(exist_ok=True)
    for f in NO_SD.iterdir():
        if f.is_file() and f.suffix in (".sh", ".xz", ".mp3"):
            shutil.copyfile(f, cc / f.name)

    # --- 6. config files (UTF-8, LF: read by the camera's shell) --------------
    cfg = root / "custom" / "configs"
    (cfg / "wifi.conf").write_bytes(
        f'# Generated by prepare_sd.py\nMODE=sta\nSSID="{ssid}"\nPASS="{pw}"\n'
        f"SECURITY={a.security}\nDHCP={a.dhcp}\n".encode("utf-8"))
    lc = cfg / "liberator.conf"
    text = lc.read_text(encoding="utf-8")
    text = re.sub(r'(?m)^WEB_PASSWORD=.*$', lambda _: f'WEB_PASSWORD="{web}"', text)
    lc.write_bytes(text.encode("utf-8"))

    print()
    print("=============================================")
    print(" SD card ready!")
    print(f"   Card  : {root}")
    print(f"   Wi-Fi : {ssid}")
    if web:
        print("   Web page: user admin + your password (also set CAM_WEB_PASSWORD in CAMECRACK/.env)")
    print("=============================================")
    print("1) Eject the card safely.")
    print("2) Insert it in the camera (unplugged), then plug in the power.")
    print("3) Wait 2-3 min: the camera joins the Wi-Fi, backs up its flash to the card")
    print("   and installs the no-SD mode. Result: LIBERATOR-RESULT.txt on the card.")
    print("4) Remove the card and power-cycle: the camera stays free without it.")
    print("   Find its IP (router) and put it in CAMECRACK/.env (CAMERA_IP).")
    print()
    print("To change network/camera later: run this script again.")


if __name__ == "__main__":
    main()
