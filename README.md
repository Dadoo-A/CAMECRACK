# CAMECRACK

**Free an LSC / Tuya camera (Anyka AK39xx SoC): 100 % local, no cloud, no SD card.**

> **Disclaimer.** CAMECRACK is an independent, community project. It is **not affiliated with,
> endorsed by or supported by** LSC, Action or Tuya; their names are only used to say which
> devices it works with. **No manufacturer firmware or code is included** in this repository.
> Modifying your camera may void its warranty. Use at your own risk: the software is provided
> "as is", without warranty of any kind (see [LICENSE](LICENSE)). A full backup of the camera's
> flash is made on the SD card before anything is changed.

An SD card prepared on your PC does all the work. It is **the liberator**: insert it, the
camera switches to local mode, **backs up its flash to the card** and **installs the no-SD
mode** into its own memory by itself. Remove the card, power-cycle: the camera stays free,
with video, PTZ, Wi-Fi and a setup hotspot.

| What you get | Details |
|---|---|
| Local video | RTSP `rtsp://<camera-ip>:554/main_ch` (H265 + AAC audio) |
| PTZ | Pan/tilt motors driven from the PC page (arrows, speed, re-center) |
| No cloud | Tuya domains blocked on the camera |
| Wi-Fi without an app | Web page on the camera (`http://<camera-ip>/`) or `CAMECRACK-XXXX` hotspot |
| PC tool | `http://localhost:8787` page (low-latency video + PTZ), via Docker |
| Reversible | Nothing is reflashed: only files in `/etc/config` are added, and they can be removed |

> ⚠️ **Tested on one model only** (see [Tested hardware & compatibility](#tested-hardware--compatibility)).
> The liberator checks the camera before touching anything and backs up the whole flash first.

---

## Tutorial: free your camera

### What you need

- A **micro-SD** card (FAT32, 1 GB is enough; 8 to 32 GB is perfect).
- A PC (**Windows, macOS or Linux**) with **Python 3.8+** to prepare the card (or Docker, see below).
- The **name and password** of your **2.4 GHz** Wi-Fi.
- For the PC tool: [Docker Desktop](https://www.docker.com/products/docker-desktop/).

### 1. Prepare the SD card

1. Put the card in the PC.
2. Run [`installer/prepare_sd.py`](installer/prepare_sd.py) and answer the questions (SD card,
   Wi-Fi name, Wi-Fi password, password for the camera web page):

   ```bash
   python3 installer/prepare_sd.py          # Windows: double-click installer\Prepare-SD.bat
   ```

   Or in one line (`--sd` = drive letter on Windows, mount point on macOS/Linux):

   ```bash
   python3 installer/prepare_sd.py --sd E: --ssid "MyWifi" --password "secret" --web-password "pw"
   python3 installer/prepare_sd.py --sd /Volumes/CAM ...       # macOS
   python3 installer/prepare_sd.py --sd /media/$USER/CAM ...   # Linux
   ```

   No Python? Use Docker (replace `E:\` with your card):

   ```bash
   docker run --rm -it -v "$PWD/installer:/installer" -v "E:\:/sd" python:3.12-alpine python /installer/prepare_sd.py --sd /sd
   ```

   The script downloads the SD root toolkit, copies it with the `camecrack/` folder (the no-SD mode), writes your
   Wi-Fi settings to `custom/configs/wifi.conf` and the web page password to `liberator.conf`.
3. Eject the card safely.

> 🔒 The card holds your Wi-Fi password **in clear text**. Keep it somewhere safe.

### 2. Free the camera

1. With the camera **unplugged**, insert the card.
2. Plug in the power and wait **2 to 3 minutes**.
   - The camera joins your Wi-Fi in local mode.
   - The liberator backs up **the whole flash** to the card (`backup/<MAC>/`, MD5-checked).
   - It installs the no-SD mode into the flash (`/etc/config/camecrack/`).
3. Find the camera's IP (your router's interface, or an app such as *Fing*).

To check, unplug the camera, put the card back in the PC and open
**`LIBERATOR-RESULT.txt`** at its root:

| Message | Meaning |
|---|---|
| `OK: no-SD mode installed/updated` | Done: go to step 3 |
| `OK: already up to date` | Already up to date, nothing changed |
| `REFUSED: camera not recognized` | Different model: **nothing was modified** |
| `FAILED: …` | Reason given; details in `logs/liberator.log`, camera unchanged |

The file also lists the detected hardware (Wi-Fi chip, motors, free space). The camera status
LED also tells you: **fast blink** for a few seconds = installed, **slow blink** = failed.

### 3. Run without the SD card

Unplug, **remove the card**, plug back in. At boot the camera plays the CAMECRACK jingle,
joins the Wi-Fi and serves video and PTZ, with no card and no cloud.

Keep the card: it is your **recovery tool** (see below).

### 4. Install the PC tool (video + PTZ)

```bash
cp .env.example .env        # Windows: copy .env.example .env
# edit .env: CAMERA_IP = camera IP, HOST_IP = your PC's IP
docker compose up -d --build
```

Open **http://localhost:8787/**

- **Video**: "H265 (auto)" by default. Black picture? Pick **"H264 (transcoded)"**.
  Low latency (H265 WebRTC) on **Chrome**; Edge falls back to MSE (1 to 2 s delay).
- **PTZ**: hold an arrow to move, release to stop
  (keyboard: arrows = move, space = stop). Slider = speed, **Home** re-centers.
- PTZ works with or without the SD card (`PTZCTL=auto`).
- **Boot sounds**: pick any audio (or video) file and click "Set as jingle" (max 10 s) or
  "Set as beep" (max 3 s). The PC tool converts it to the camera format (MP3 8 kHz mono) and
  sends it to the camera (no-SD mode). Active at the next boot.

After editing `.env`: `docker compose up -d --force-recreate`.
Stop: `docker compose down`.

---

## Changing Wi-Fi

Three ways, from simplest to most robust. Step by step:
[`installer/no-sd/CHANGE-WIFI.md`](installer/no-sd/CHANGE-WIFI.md).

1. **Camera web page** (still on the old network): open `http://<camera-ip>/`, enter the new
   network, save.
2. **Hotspot** (camera unreachable): **3 short presses** on the reset button within 5 s, or
   automatic after 6 failed connection attempts (a few minutes), or a long press (the camera reboots
   first). The status LED blinks fast while the hotspot starts, then slowly once it is ready. Join the open Wi-Fi `CAMECRACK-XXXX`: the
   setup page opens (otherwise `http://10.1.8.1/`). Save, and the camera reboots onto the new
   network.
3. **SD card**: run `prepare_sd.py` again with the new Wi-Fi, insert the card, power on.
   The liberator copies the new `wifi.conf` into the flash.

SSIDs and passwords with apostrophes or special characters are supported.

---

## Recovery with the SD card

As soon as the card is inserted it takes over: the no-SD mode stays idle and the camera
boots in toolkit mode, with logs you can read on the PC.

- **Logs**: `logs/` folder on the card (`liberator.log`, `wifi_fixed.log`, `entrypoint.*.log`).
- **No-SD mode log**: `/etc/config/camecrack/boot.log` on the camera (SD card inserted, or `TELNET=on`).
- **Liberator setting** in `custom/configs/liberator.conf`:

  | Value | Effect |
  |---|---|
  | `LIBERATOR=install` | Install or update the no-SD mode (default) |
  | `LIBERATOR=off` | Leave the flash alone (SD-only mode) |
  | `LIBERATOR=uninstall` | Remove the no-SD mode: without a card the camera is stock again |

- **Backups**: `backup/<MAC>/` holds the 8 flash partitions (`mtd0` to `mtd7`, `md5.txt`)
  and a copy of `/etc/config` taken before each change. **Copy them to your PC.**
  `prepare_sd.py --clean` never deletes them.

---

## Home Assistant

Ready-to-copy files are in [`homeassistant/`](homeassistant/):

| File | What it is |
|---|---|
| [`docker-compose.yml`](homeassistant/docker-compose.yml) | Home Assistant Container (e.g. a Portainer stack on a Linux host / NAS) |
| [`packages/camecrack.yaml`](homeassistant/packages/camecrack.yaml) | Package: `rest_command` for PTZ and LED, scripts `camecrack_move`, `camecrack_home`, LED on/off |
| [`dashboard-card.yaml`](homeassistant/dashboard-card.yaml) | Dashboard card: live video, PTZ arrows, LED buttons |

1. **Package**: in `configuration.yaml` add `homeassistant:` / `packages: !include_dir_named packages`,
   copy `camecrack.yaml` to `<config>/packages/`, replace `<camera-ip>`, and put
   `camecrack_password: "<WEB_PASSWORD>"` in `<config>/secrets.yaml`. Restart Home Assistant.
2. **Video**: Settings > Devices & services > Add integration > **Generic Camera**, stream source
   `rtsp://<camera-ip>:554/main_ch` (RTSP over TCP, no still image URL, no credentials). Set the
   entity id to `camera.camecrack`.
3. **Dashboard**: the default "Overview" of recent Home Assistant versions does not take custom
   cards: create a new dashboard (Settings > Dashboards > Add dashboard > New dashboard from
   scratch), then Add card > **Manual** and paste `dashboard-card.yaml`.

Notes:
- **Behind a reverse proxy** (Home Assistant 2026.x): the HTTP settings live in the UI, not in
  `configuration.yaml` (an `http:` block is only imported at the very first start). Set them in
  Settings > System > Network > HTTP server > **Reverse proxy** (use `X-Forwarded-For`, trusted
  proxies = your proxy's IP), otherwise the proxy gets HTTP 400.
- **Video latency**: the camera streams H265. Browsers rarely accept H265 over WebRTC, so Home
  Assistant falls back to HLS (several seconds of delay). For near real time, give Home Assistant
  an H264 stream, e.g. the `camecrack_h264` stream of the PC tool (`rtsp://<PC-ip>:8554/camecrack_h264`)
  or a go2rtc instance on an always-on host that transcodes it.
- **ONVIF** (PTZ): only with the SD card for now (port 8080).
- Settings (LED patterns, sounds, Wi-Fi) are stored **on the camera**, so they stay the same
  whether you use the PC tool or Home Assistant.

### Camera HTTP API (no-SD mode)

`http://<camera-ip>/…`, HTTP Basic auth (user `admin`, `WEB_PASSWORD`) when a password is set.

| Request | Effect |
|---|---|
| `GET /ptz?dir=up\|down\|left\|right\|stop\|home&speed=0.6` | Move / stop the motors |
| `GET /led` | Status LED patterns per event (JSON) |
| `GET /led?event=<event>&pattern=<pattern>` | Save a pattern (applied now for `normal`) |
| `GET /led?pattern=<pattern>&test=1` | Show a pattern for 5 s |
| `POST /sound?name=jingle\|bip` (body: MP3 8 kHz mono, ≤ 24 KB) | Replace a boot sound (next boot) |
| `GET /log` | Uptime + end of the no-SD boot log (text) |

LED events: `normal`, `wifi_connecting`, `hotspot_starting`, `hotspot_ready`, `install_ok`,
`install_failed`. Patterns: `off`, `on`, `blink:<on_ms>:<off_ms>` (50 to 5000 ms).
Home Assistant example (full version in `homeassistant/packages/camecrack.yaml`):

```yaml
rest_command:
  camecrack_led_off:
    url: "http://<camera-ip>/led?event=normal&pattern=off"
    username: admin
    password: !secret camecrack_password
```

---

## Security

- **Telnet (port 24) is OFF in no-SD mode** by default. The stock telnetd on port 23
  (root password left as the public "telnet" by the SD toolkit) is stopped too. The PC tool drives PTZ through the
  camera's web page (`/ptz`, fixed directions only, no shell). For debugging, set `TELNET=on`
  in `custom/configs/liberator.conf` and boot once with the card (passwordless root shell:
  trusted network only), or simply insert the SD card (toolkit mode has its own telnet).
- **Camera web page password** (port 80: Wi-Fi settings + PTZ): asked by `prepare_sd.py`
  (`WEB_PASSWORD` in `liberator.conf`), user `admin`, standard browser login. Put the same value in
  `CAM_WEB_PASSWORD` in `.env` for the PC tool. Not asked in hotspot mode (started by a button
  press or a failed Wi-Fi; phone captive portals handle logins badly). Empty = no password.
- The Tuya factory reset (long press on the button) is **disabled**: a long press reboots the camera into the setup hotspot.
- The setup hotspot is **open**; it only starts on request (3 presses) or when Wi-Fi fails,
  and the camera reboots after saving.
- Never commit `.env` or a filled-in `wifi.conf`.

---

## How it works (short version)

- At boot, `/usr/sbin/main.sh` calls `/etc/config/sensor_driver.sh`, the only **writable**
  boot script (256 KB jffs2 partition). The liberator appends a block to it that runs
  `/etc/config/camecrack/boot.sh`.
- Without a card, `boot.sh` recreates what the SD toolkit did: local-mode marker (RTSP video
  is served by the stock `anyka_ipc` binary), settings, sounds, then Wi-Fi, cloud blocking,
  web page, button, PTZ (`ptzctl` unpacked to RAM).
- With a card, it does nothing and the SD toolkit takes over.

Details: [`installer/no-sd/README.md`](installer/no-sd/README.md),
[`installer/no-sd/AP-NOTES.md`](installer/no-sd/AP-NOTES.md) (hotspot),
[`ROADMAP.md`](ROADMAP.md).

## Tested hardware & compatibility

| | Tested unit |
|---|---|
| Camera | **LSC Smart Connect Indoor PTZ camera** (Action, Tuya inside) |
| Board | `HT_IPC286KS3` |
| SoC | Anyka **AK3918EV330** (ARM926EJ-S, ARMv5), Linux `4.4.192V2.1` |
| Firmware | `v1.0.0 (6.2863.125)`, camera app `/usr/bin/anyka_ipc` md5 `7c2a124cdd607ebef63fb66d063b6a87` |
| Wi-Fi | **ATBM6x6x** over USB (`ATBM6x6x_wifi_usb`), 2.4 GHz |
| Flash | 8 MB SPI NOR: UBOOT, ENV, ENVBK, DTB, KERNEL, ROOTFS (squashfs), CONFIG (`/etc/config`, jffs2 256 KB), APP (squashfs) |
| Motors | `ak_motor.ko`, `/dev/motor0` (pan) and `/dev/motor1` (tilt) |
| Video | H265 + AAC, 2304×1296 |

The liberator writes the detected hardware (Wi-Fi module, motors, free space, `anyka_ipc` md5)
to `LIBERATOR-RESULT.txt`: please share it if you try another camera.

**Will it work on other cameras / firmwares?** Likely on the same family, not guaranteed:

| Part | Depends on | Other firmwares |
|---|---|---|
| Boot hook | `/usr/sbin/main.sh` calling `/etc/config/sensor_driver.sh install` (Anyka "HT" SDK) | Likely on Tuya/LSC cameras of this SDK family; **checked** by the liberator (refuses otherwise, nothing modified) |
| Local video (RTSP) | `anyka_ipc` serving RTSP when `/tmp/_ak39_factory.ini` exists | Same mechanism as the SD toolkit, so firmwares supported by the toolkit should work |
| Wi-Fi (station) | `wpa_supplicant` / `wpa_cli` in the firmware | Generic: should work with other Wi-Fi chips |
| Hotspot (AP mode) | Static **hostapd 2.8** tested on the **ATBM** chip only | Other chips (e.g. SSV): may fail. The liberator logs a warning; the SD card remains the fallback |
| PTZ | `ak_motor` ioctls (`/dev/motor0`/`1`) | Standard Anyka driver; non-PTZ models simply have no motors |
| Sounds, LED, button | Stock file names in `/usr/share`, `state_led`, `gpio-keys` code 116 | Usually identical in this family; may differ on other boards |
| Reset neutralization | `anyka_ipc` calling `/usr/sbin/recover_cfg.sh` | Same SDK = same behaviour, otherwise the long press may still reset |

Different SoC families (Ingenic, e.g. Wyze-like cameras) are **not** supported.

## Repository layout

| Path | Contents |
|---|---|
| `installer/prepare_sd.py`, `Prepare-SD.bat` | SD card preparation (Python, any OS; the .bat is a Windows launcher) |
| `installer/sd-overlay/` | CAMECRACK files added on top of the SD toolkit (liberator, Wi-Fi fix) |
| `installer/no-sd/` | No-SD mode copied to flash (scripts, hotspot, `ptzctl.xz`, sounds) and build recipes |
| `web/`, `go2rtc/`, `docker-compose.yml` | PC tool (control page + video gateway) |
| `homeassistant/` | Home Assistant examples (stack, package, dashboard card) |
| `ROADMAP.md` | Done, to do, ideas |

## Credits

- SD root: [lsc-tuya-toolkit](https://github.com/tasarren/lsc-tuya-toolkit), downloaded by `prepare_sd.py`
  (not redistributed here), see [`installer/NOTICE.txt`](installer/NOTICE.txt).
- Video gateway: [go2rtc](https://github.com/AlexxIT/go2rtc).
- Hotspot: hostapd 2.8 built statically (musl, ARMv5), lead found thanks to
  [akost-firmware](https://github.com/michelostojski/akost-firmware).

## License

[MIT](LICENSE) for the CAMECRACK code and documentation. Third-party components keep their own
terms: see [`installer/NOTICE.txt`](installer/NOTICE.txt).
