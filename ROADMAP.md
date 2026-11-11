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
