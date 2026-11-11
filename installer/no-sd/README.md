# "No SD card" mode (persistence in flash)

Makes local video, Wi-Fi and PTZ **permanent without an SD card**, by writing only to the
camera's `/etc/config` (jffs2, 256 KB). **No partition reflash**, fully reversible.
ONVIF is **not** included yet (see [ROADMAP](../../ROADMAP.md)).

Normally installed **automatically by the SD liberator** (`../sd-overlay/custom/scripts/liberator.sh`),
which copies this folder from the card's `camecrack/` directory.

## What gets installed on the camera (`/etc/config/camecrack/`)

| File | Role |
|------|------|
| `boot.sh` | Boot hook. **No-op when an SD card is present**. Otherwise: creates the RTSP marker, bind-mounts settings and sounds before `anyka_ipc`, then starts `extras.sh`. |
| `extras.sh` | Cloud blocking (`/etc/hosts`), unpacks `ptzctl`, Wi-Fi station (via `wifi_up.sh`), web page (Wi-Fi settings + `/ptz`), button, telnet port 24 **only if `telnet_on` exists** (`TELNET=on` in liberator.conf). Station failing (or no `wifi.conf`) → **AP mode**. |
| `wifi_up.sh` | One station connection attempt from `wifi.conf` (`wpa_cli` direct, hex SSID). |
| `webcfg.sh`, `webcfg_handler.sh` | Wi-Fi setup web page (port 80); also the **captive portal** in AP mode. |
| `ap_mode.sh` | **AP mode (hotspot)** to re-provision offline — see [`AP-NOTES.md`](AP-NOTES.md). |
| `button_watch.sh` | 3 short presses on the reset button within 5 s → AP mode. |
| `recover_cfg.sh` | No-op replacement bound over `/usr/sbin/recover_cfg.sh`: a long press no longer wipes the Tuya config (the camera just reboots). |
| `ap-bin.tar.xz` | Static hostapd 2.8 + captive DNS (musl, ARMv5), 88 KB compressed; unpacked to RAM (`/tmp`) only in AP mode. Source/recipe: [`ap/`](ap/). |
| `ptzctl.xz`, `ptz.conf` | Motor control (36 KB compressed, unpacked to `/tmp/ptzctl`). Recipe: [`ptz/`](ptz/). |
| `jingle.mp3`, `bip.mp3` | Boot sounds (8 kHz mono), bound over the factory prompts; replaceable via `/sound`. |
| `led.sh`, `led.conf` | Status LED pattern per event (`led.conf` written through the `/led` API). |
| `TZ`, `TZ_GMT` | Time zone (system) and today's GMT offset. |
| `web_auth` | Web page password (base64 of `admin:<password>`). |
| `uninstall.sh` | Restores `sensor_driver.sh.orig` and undoes the binds. |
| `_ak39_factory.ini` | Marker that wakes up local RTSP (from the toolkit). |
| `_ht_hw_settings.ini`, `_ht_sw_settings.ini` | Local-mode settings (from the toolkit). |
| `hosts` | Tuya DNS blacklist (no cloud). |
| `wifi.conf` | **Wi-Fi credentials — stays on the camera, NEVER committed here.** |
| `sensor_driver.sh.orig` | Backup of the original before the hook. |
| `boot.log` | Persistent log (capped at 4 KB). |

The hook is a block **appended** to the end of `/etc/config/sensor_driver.sh` (no existing
line is edited) and only runs for the `install` argument.

## Mechanism

`main.sh` calls `/etc/config/sensor_driver.sh install` on **every boot, SD or not**.
The hook checks for a card (`-b /dev/mmcblk0p1`):
- **SD present** → does nothing, the SD toolkit handles everything.
- **No SD** → replays from flash what the toolkit did from the SD: `_ak39_factory.ini`
  marker, settings bind mounts (before `anyka_ipc` starts), then Wi-Fi + offline + telnet
  via `extras.sh`.

RTSP video is served by the **stock `anyka_ipc`** binary (already in flash); we only recreate
the local-mode conditions.

## Safety net

- SD present = hook idle → **inserting the SD card restores access** if the no-SD mode fails.
- Full flash backup on the card (`backup/<MAC>/`, made by the liberator).

## Install / update by hand from the PC (developers)

Camera reachable (telnet port 24), no-SD mode already in place:

```powershell
.\installer\no-sd\install-ap.ps1 -CamHost <camera-ip>
```

Pushes the scripts + `ap-bin.tar.xz` into `/etc/config/camecrack/`, checks every MD5 and the
free space. `wifi.conf` is **never** pushed. `-Only ap_mode.sh,boot.sh` for a subset.
Never push a big file straight into flash over telnet (it arrives truncated): go through
`/tmp`, check the MD5, then `cp`.

## Revert

Easiest: set `LIBERATOR=uninstall` in `custom/configs/liberator.conf` on the card and boot
with it. Or on the camera (telnet):

```sh
sh /etc/config/camecrack/uninstall.sh
reboot
```
