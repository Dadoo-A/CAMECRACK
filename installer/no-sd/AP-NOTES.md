# AP mode (hotspot) — re-provisioning Wi-Fi offline

The camera creates an **open** hotspot `CAMECRACK-<last 4 hex digits of the MAC>` (ours:
`CAMECRACK-ABCD`), takes `10.1.8.1`, hands out IPs (DHCP) and answers **every** DNS request
with `10.1.8.1`: the phone shows "Sign in to network" and opens the `webcfg` page. Enter the
new Wi-Fi → `wifi.conf` is written → **reboot** → the camera joins that network as a station.
100 % local, no cloud.

## When the camera enters AP mode

| Trigger | Where |
|---|---|
| No station config (`wifi.conf` missing or `MODE` ≠ `sta`) | `extras.sh`, at boot |
| Station failing after 6 attempts (~3 min) | `extras.sh`, at boot |
| **3 short presses** on the reset button within 5 s | `button_watch.sh` |
| By hand (telnet): `sh /etc/config/camecrack/ap_mode.sh` | — |

Leaving AP mode — **always through a reboot** (the ATBM driver refuses AP→station on the fly
and `rmmod` panics the kernel):
- new Wi-Fi saved on the page → reboot → station;
- **no client for 10 min** (`AP_TIMEOUT=600`) → reboot → new station attempt
  (typical case: power cut, the router boots slower than the camera);
- hostapd died or `wlan0` left Master mode → reboot.

In AP mode, `anyka_ipc` (video) is stopped and **telnet is off** (open hotspot = anyone in
range); `touch /etc/config/camecrack/ap_telnet` to keep it (debugging).

## What runs (all in RAM)

`ap_mode.sh`:
1. stops the camera app **cleanly**: `killall -12 daemon` (closes the hardware watchdog, like
   the stock `service.sh stop`), `killall daemon`, `killall -9 anyka_ipc`.
   **Required**: `anyka_ipc` manages `wlan0` itself; seeing the station drop, it runs
   `ifconfig wlan0 down` (→ the AP stops, `NL80211_CMD_STOP_AP`, seen in the first test) or even
   `wifi_driver_new.sh stop` (→ `rmmod` → panic);
2. `xzcat ap-bin.tar.xz | tar -x -C /tmp` → `/tmp/hostapd`, `/tmp/captive-dns`;
3. generates `/tmp/hostapd.conf` + `/tmp/udhcpd.conf` (nothing written to flash);
4. `hostapd -B` (switches `wlan0` STA→AP **on the fly**, that works), `ifconfig wlan0 10.1.8.1`,
   `udhcpd` (stock), `captive-dns 10.1.8.1 -d`, `webcfg` page (already running);
5. checks every 30 s (hostapd alive, Master mode, clients in `/proc/net/arp`).

## hostapd 2.8: verdict and build

**It works on our chip** (test of 2026-11-08, debug binary run from `/tmp`):
`nl80211: Setup AP(wlan0) - device_ap_sme=0 use_monitor=1` → `mon.wlan0` created → beacon
`CAMECRACK-ABCD` → `AP-ENABLED`, `wlan0 Mode:Master`.

- The **monitor interface** fallback is **upstream** (not a vendor patch). Checked in the
  sources: the `use_monitor` logic (`driver_nl80211_capa.c`) and
  `nl80211_create_monitor_interface()` are identical in 2.8, 2.9, 2.10 and still present in
  2.11. hostapd enables it by itself when the driver doesn't advertise poll + TX status (the
  ATBM case). We stay on **2.8**, the version known to work on ATBM (akost); if detection ever
  failed: `driver_params=use_monitor=1` in the config.
- **Build**: [`ap/build-hostapd.sh`](ap/build-hostapd.sh), in a throwaway Debian container
  (Docker Desktop, no WSL distro needed): gcc `arm-linux-gnueabi` (armel = ARMv5TE, soft-float
  EABI) → **musl 1.2.5** built with it → libnl-tiny (OpenWrt) → hostapd 2.8 (tarball SHA-256
  checked). **Static** binaries: no dependency on the camera's uClibc. Reproducible (same
  SHA-256 from one build to the next, see `ap/SHA256SUMS`).

  ```powershell
  docker run --rm -v "${PWD}\installer\no-sd\ap:/recipe:ro" -v "${PWD}\out:/out" debian:bookworm bash /recipe/build-hostapd.sh
  ```

### Fitting it into 256 KB of flash

`/etc/config` = 256 KB jffs2. Progress (xz size):

| Step | raw hostapd | xz |
|---|---|---|
| minimal hostapd 2.8 (open AP, nl80211, libnl-tiny), debug + ctrl socket | 524 KB | 202 KB |
| no stdout debug, no control socket, LTO | 315 KB | 138 KB |
| + security stack removed (WPA/802.1X/EAP/crypto → [`open_ap_stubs.c`](ap/open_ap_stubs.c)), no 802.11n | 266 KB | 113 KB |
| + 65 station/P2P/TDLS/mesh/scan ops removed from the nl80211 table | 229 KB | 100 KB |
| + [`mini_config.c`](ap/mini_config.c) (instead of the ~300 options of `config_file.c`) + [`libc_overrides.c`](ap/libc_overrides.c) (syslog/time zones) | **200 KB** | **87 KB** |
| **`ap-bin.tar.xz`** = hostapd + `captive-dns` in **one** xz stream | 217 KB | **88 KB** |

Pitfalls:
- **xz: explicit dictionary required** (`--lzma2=preset=9e,dict=256KiB`). In a pipe, `xz -9`
  announces a 64 MB dictionary; the camera's busybox `xzcat` (32 MB RAM) then says
  "corrupted data".
- **No BCJ filter**: busybox `xzcat` doesn't support it (would have saved 4 KB).
- **No `dnsd`** in the camera's busybox → [`ap/captive_dns.c`](ap/captive_dns.c)
  (~100 lines: answers `10.1.8.1` to every A query, NODATA otherwise → forces IPv4).
- The `.c` files added to the flash build are compiled with **make's exact CFLAGS**
  (`-DCONFIG_*`): hostapd's struct layout depends on them.
- `open_ap_stubs.c` = **no security at all**: a `wpa=` config would have NO effect. This build
  is only for the open provisioning AP; `mini_config.c` rejects any unknown key.

## Tests on the real camera (2026-11-08/09)

| Test | Result |
|---|---|
| **Debug** hostapd 2.8 from `/tmp`, station → AP on the fly | ✅ `use_monitor=1` auto, `AP-ENABLED`, `Mode:Master`. ❌ the AP stopped by itself: `anyka_ipc` ran `ifconfig wlan0 down` → fixed (step 1 of `ap_mode.sh`) |
| **Installed** `ap_mode.sh` (flash build) | ✅ AP up in 10 s; hostapd + udhcpd + captive-dns running; `anyka_ipc`/`daemon` stopped **without a watchdog reboot** |
| Captive DNS (from the camera) | ✅ `connectivitycheck.gstatic.com` → `10.1.8.1` |
| Portal (`GET /generate_204`) | ✅ `200` + Wi-Fi page (→ "sign in" popup on the phone) |
| No-client timeout → reboot | ✅ reboot, then `WIFI OK` 22 s after boot |
| Phone joins `CAMECRACK-ABCD`, DHCP lease, save → station reboot | ✅ **OK**: hotspot joined, portal opened, Wi-Fi saved → reboot → station, RTSP up |
| 3 button presses → AP mode | ✅ **OK** (2026-11-09): the camera leaves the LAN = AP mode. Button = `gpio-keys`, `/dev/input/event0`, code 116 |
| Real station failure (bad `wifi.conf`) → automatic AP | ⏳ not provoked on purpose; same call as the manual test |

## Recovery if things go wrong

- AP mode **always** ends in a reboot (10 min timeout without a client) → back to station.
- Unplug/replug = reboot = back to station (with the current `wifi.conf`).
- **Insert the SD card** = toolkit mode (no-SD hook idle) → telnet is back.
- Disable AP mode: `rm /etc/config/camecrack/ap-bin.tar.xz` (everything else ignores it).
- Full flash backup: `backup/<MAC>/` on the SD card.

## Reference

akost-firmware (same SoC): <https://github.com/michelostojski/akost-firmware>,
`docs/04-wifi-portal.md` — same flow (from thingino); akost extracts its hostapd 2.8 from its
camera's APP partition, ours has none → hence this build.
