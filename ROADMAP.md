# Roadmap — CAMECRACK

Taking an LSC/Tuya camera (Anyka AK3918EV330) **100 % local**, with no cloud.

> **🗝️ Vision: the SD card is "the liberator".** Prepare a card, insert it, and it frees the
> camera end to end: root, local mode, **automatic install of the no-SD mode into flash**, then
> it stays the **recovery tool** (logs readable on a PC). Goal: **the universal liberator for
> this camera family** (LSC/Tuya on Anyka AK39xx SoCs and variants), not just our unit — so
> detect hardware (Wi-Fi chip, sensor, flash space, firmware version) instead of hardcoding.
>
> ✅ **Liberator v1 (2026-11-11)**: on every boot with the card, `custom/scripts/liberator.sh`
> backs up the whole flash (`backup/<MAC>/`, MD5), installs or updates the no-SD mode in
> `/etc/config/camecrack/` (differential copy, priorities depending on free space, boot hook
> added last) and writes `LIBERATOR-RESULT.txt` on the card. `custom/configs/liberator.conf`:
> `install` | `off` | `uninstall`. Tested on our camera: up to date, uninstall, full reinstall
> (18 files), then a successful no-SD boot. Still to do: test on a **fresh camera / other
> variant** (SSV Wi-Fi chip, other firmware), PC page that reads
> the result.

## ✅ Done
- **Non-destructive** SD root (bind mounts; removing the card = stock firmware).
- Local mode: **RTSP** (`main_ch`, H265+AAC), **ONVIF** (8080, PTZ, SD only), **telnet** (24).
- **Full flash backup** (8 partitions mtd0–7, MD5-checked), now done automatically by the liberator.
- **Dockerized PC tool**: go2rtc (video + H265→H264 transcoding) + web service (page + PTZ relay).
- **Plug-and-play SD installer** (`installer/prepare_sd.py`, Windows/macOS/Linux): root payload + Wi-Fi settings + no-SD payload.
- **No-SD mode** (2026-11-08): video, Wi-Fi, cloud blocking, telnet from `/etc/config` only, reversible.
- **PTZ without SD** (2026-11-09): `ptzctl` rebuilt with musl (79 KB, 36 KB xz), unpacked to RAM at boot.
- **Wi-Fi without cloud** (2026-11-08/09): on-camera web page (port 80) + **AP hotspot with captive
  portal** (static hostapd 2.8) + 3 short button presses; apostrophes in SSID/password supported.
- **Custom sounds**: English voice jingle and custom beep instead of the Chinese factory prompts.
- **Low-latency video**: WebRTC H265 on Chrome (MSE fallback on Edge); no audio over WebRTC.

## 🧭 To do

### 1. Hardening & reliability (high priority before sharing)
- ✅ **Telnet off by default** (2026-11-11): PTZ goes through the camera web page (`/ptz`); the stock
  port-23 telnetd is stopped as well (verified: 23 and 24 closed without SD);
  `TELNET=on` in `liberator.conf` to enable it. Camera web page password (`WEB_PASSWORD`, HTTP Basic, user admin) done too.
- ✅ **Reset button** (2026-11-11): the Tuya factory reset (long press → `anyka_ipc` runs
  `/usr/sbin/recover_cfg.sh`) is neutralized by a bind-mounted no-op `recover_cfg.sh`: nothing is
  wiped anymore. `anyka_ipc` still beeps and reboots by itself afterwards (long press = plain
  reboot). 3 short presses → AP mode unchanged.
- **Watchdog / auto-heal**: restart `anyka_ipc` if it crashes, retry Wi-Fi (partly in `extras.sh`).
- **Multi-unit robustness** (the "universal" part): test on other cameras, handle variants.
- **No plain-text secrets**: `wifi.conf` stays on the camera; maybe light encryption.
- **Flash space**: ~44 KB free in `/etc/config` since the unused Tuya pairing DB `tuya_user.db` (39 KB) was removed on 2026-11-11 (copy on the SD card `backup/<MAC>/`). Check it is not recreated by `anyka_ipc`.

### 2. ONVIF without SD
PTZ in Home Assistant through ONVIF currently needs the SD card (lighttpd + ONVIF server are
SD-resident). Options: a tiny ONVIF responder, or PTZ through MQTT/HA instead.

### 3. Home Assistant integration
- Documented: RTSP (554 or go2rtc `:8554/camecrack`), ONVIF (8080, SD only).
- Maybe a ready-made config / add-on.

### 4. Polish
- ✅ Camera time zone (2026-11-11): the clock was right (UTC); `TIMEZONE` in liberator.conf sets the
  system time zone (logs, `date`). The video overlay ignored it (computed elsewhere in the closed
  code), so the **time overlay is turned off** (`bool_osd_time = 0` in `_ht_sw_settings.ini`):
  timestamps come from the PC side (go2rtc / Home Assistant / recorder).
  anyka_ipc reads `/tmp/TZ` ONCE at startup and only parses `GMT-HH:MM`: the liberator and
  extras.sh store today's offset in `TZ_GMT`, boot.sh copies it before the camera app starts
  (a summer/winter change shows up after the next reboot).
- ✅ **Change the jingle/beep on the fly** (2026-11-11): "Boot sounds" card in the PC tool (ffmpeg
  conversion, upload to the camera web page `/sound`). ✅ End-of-install signal on the status LED.
- ⚠️ **Beep persistence** (seen 2026-11-09): the beep (`hutong_sound2.mp3`) once disappeared after a
  reboot while the voice jingle stayed (flash was full at the time); back since the cleanup. Watch it:
  check `bip bound` in `boot.log` after a bad reboot.
- Low-resolution sub-stream for HA (bandwidth).
- Simple authentication on the control page (if exposed beyond the PC).

### 5. Automatic face tracking
Detect a face in the stream and **make the camera follow it** (closed-loop PTZ).
- **PC side**: go2rtc stream → face detector (OpenCV Haar/DNN or a light model) → PTZ commands
  through the existing web relay; proportional pan/tilt + dead zone + auto stop.
- **On-device lead**: `anyka_ipc` links **`libaiot_person_detect.so`** (person detection on the
  camera) → tracking without a PC.
- Ideas: several faces (follow the closest/central one), back to home after inactivity.
- **Status (2026-11-13)**: the `cam/` app tracks with relative moves (`ptzctl -J`). Measured
  without SD: one pan unit of `-J` is **~15°, not 180°** → corrections were ~10× too small
  (now `--pan-unit 15`). Tilt not measured: after one downward move it stopped answering (up/down
  and `-J`) until `home`. Likely cause: `ptz.conf` keeps `STATE_DIR`/`LOG_FILE` on the absent SD
  card → fixed in `extras.sh` (RAM copy `/tmp/ptz.conf`), installed.
  Retest after the fix (pixels at 1280 width): pan stays roughly linear (0.1→22, 0.2→45,
  0.3→63, 0.4→112, i.e. ~15°/unit); **tilt up saturates** (0.1 and 0.3 both ≈ 22 px) and **tilt
  down barely moves**. `-J` sends 64-step chunks every 30 ms (`ABSREL_CHUNK_STEPS`,
  `ABSREL_INTERVAL_MS`) to an asynchronous motor driver. Next: with the SD card (shell), try
  bigger chunks / longer interval for tilt, read `/tmp/ptz.log` (now also shown by `/log`).
- **Bench with the SD card (2026-11-13 evening)**, `ptzctl -J` with overridden `ptz.conf`:
  - one big chunk (4000 steps) = **no move at all**; 256/512-step chunks move less than 64:
    the driver seems to drop or replace a move that arrives before the previous one ends;
  - longer interval = full moves: tilt up 0.1→21 px, 0.3→58 px at 300 ms; pan 0.3→122 px
    (63 with the default 30 ms) → the "15°/unit" pan figure was measured with truncated moves;
  - **best so far: `ABSREL_CHUNK_STEPS=32`, `ABSREL_INTERVAL_MS=60`** → tilt up 0.2 ≈ 80 px,
    repeatable, 1.3 s per command;
  - **tilt reversal loses the first command** (backlash or driver): after going up, the first
    down move (up to 0.3 unit) does nothing, the next ones move. `-m down/up` shows the same;
- **Calibration (2026-11-14, clear view)** with 32 steps / 60 ms: pan ~800 px per `-J` unit at
  1280 px width (0.1→73-92 px, 0.2→155 px), **no pan backlash**; tilt ~380 px per unit
  (0.1→38 px), **tilt backlash ≈ 0.14 unit** (first reversal command lost, second partial).
  Applied: `extras.sh` writes `ABSREL_CHUNK_STEPS=32` / `ABSREL_INTERVAL_MS=60` into
  `/tmp/ptz.conf`; the `cam/` app uses `--pan-unit 53`, `--tilt-unit 25` (degrees at an 85° field
  of view), adds `--tilt-backlash 0.14` on each tilt reversal and waits for the real move time.
  **Tested live without the SD card (2026-11-14): tracking follows well.**
- **Target choice** (2026-11-14): `--target me|cat|auto` and key `c` in the preview. `cat` looks
  for a cat face (OpenCV Haar cascade), then a cat body aimed at its upper part.
- **Video glitches** (2026-11-14): measured 44-48 decoder errors per 5 s with the camera still,
  53 while panning → **not caused by PTZ**. Bursts drop the stream to 5-10 img/s every ~20 s.
  Ping stayed < 100 ms throughout (Wi-Fi fine); the stalls matched the camera's TCP send queue
  growing (up to 6 KB) with its CPU at 3 % idle. Direct read for 60 s: **TCP 0.4 img/s, UDP
  14.9 img/s** with no second under 10 img/s. **Fix: go2rtc pulls the camera over UDP**
  (`rtsp://…/main_ch#transport=udp`, in the `cam/` app): app at 15.2 img/s, freezes ~140 ms
  (worst 334 ms, was 375-531 ms). Docker `go2rtc.yaml` left on TCP (incoming UDP into a Windows
  container not tested).
- **Arrow keys** in the `cam/` preview move the camera (`--arrow-step`, default 6°, tilt 60 %);
  tracking pauses on a manual move (`t` resumes). Key `o` hides/shows the preview overlay
  (the webcam output never has it). Cat target tested live: works.
- **Discord** (2026-11-14): the Unity Capture webcam kept loading forever. Discord's log:
  `Failed to bind to the selected capture device -2147024770` (0x8007007E, module not found):
  its sandboxed capture process cannot load a DLL from the user profile. `setup_cam.py` now copies
  the DLLs to `%ProgramFiles%\CAMECRACK\UnityCapture` and registers them there → works in Discord.
  `--webcam-backend obs` is also available (OBS Virtual Camera, needs OBS Studio installed).
- **Burnt-in clock removed** (2026-11-14): `anyka_ipc` reads `bool_osd_time` but never applies it
  at startup (its logs never show "disable main channel osd"; only a Tuya cloud command does).
  It draws the clock with the raw 8x16 font `/usr/local/ak_font_16.bin`: `boot.sh` now binds an
  all-zero copy (RAM, same size) over it before `anyka_ipc` starts → no clock, no empty box.
  Create `osd_clock_on` in the flash folder to keep the clock. The `cam/` app keeps a
  `--hide-time` crop option for cameras without this fix.

### 6. Wi-Fi & reset (remaining ideas)
- **"QR like LSC"**: the app generates a **standard Wi-Fi QR** scanned by **your phone** to join the hotspot.
- **Feedback** on the 3 presses / AP mode: a **beep** (`ht_audio_codec_play_audio_file`) and/or a
  **fast LED blink** (`state_led.sh` / `ak_leds.ko`); same for Wi-Fi connected, AP ready.
- **QR read by the lens (stretch)**: the camera can decode QR codes (**zbar** in `anyka_ipc`), but
  the flow is **tied to the Tuya cloud** (the QR carries an appid/token/shorturl). Doing it
  cloud-free = heavy reverse engineering of a proprietary binary. Deferred.

---

## 🆕 Ideas to sort

### 7. Detection & notifications
- **Motion / person → phone alert** (Telegram / ntfy / via Home Assistant).
- Based on `libaiot_person_detect` (on-device) or PC-side detection.
- Zones of interest + anti-spam (cooldown).

### 8. Recording (PC-side mini NVR)
- **Continuous or event** recording on the PC (nothing on the camera in no-SD mode).
- **Frigate** option (object/person detection + NVR, integrated with HA).

### 9. Advanced home automation
- **MQTT**: publish state + events to HA (beyond ONVIF/RTSP).
- **Privacy mode**: the camera turns to the wall / cuts the stream when you are home (via HA).

### 10. Advanced PTZ
- **Presets** (saved positions, one-click recall) — the toolkit already has `ptz_presets.sh`.
- **Patrol mode**: automatic sweep between presets.

### 11. Audio & media
- **Two-way audio**: microphone listening + speaker talk-back.
- **Image / IR controls**: day/night (ICR), flip/mirror, exposure.
- ✅ **Status LED** (2026-11-11): the camera app no longer drives it (`bool_led_enable = 0`); a pattern
  per event (normal, Wi-Fi connecting, hotspot starting/ready, SD install OK/failed) chosen in the PC
  tool or through the camera API `/led`, stored on the camera (`led.conf`, `led.sh`).

### 12. Management & deployment
- **OTA**: push `camecrack` script updates to the camera (today: update the SD card, the liberator copies the changes).
- **Multi-camera** in the PC tool; one-click config backup/restore.
