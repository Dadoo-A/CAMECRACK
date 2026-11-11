# Changing the camera's Wi-Fi (no-SD mode)

The camera runs **without an SD card**. Its Wi-Fi credentials live in
`/etc/config/camecrack/wifi.conf` (on the camera). Here is how to change them.

> ⚠️ If you can, do it **while the camera is still reachable** on the current network
> (before switching the old network off). Once the new credentials are saved, it leaves the
> old network and joins the new one.

Supported: **2.4 GHz** networks, **WPA2** or mixed WPA2/WPA3 (not WPA3-only). Apostrophes and
special characters work. **Double-check the SSID spelling**: one typo is enough to lose the camera.

---

## Method 1 — Web page (simplest) ✅

1. PC or phone on the **same network** as the camera.
2. Find its IP (see "Finding the IP" below).
3. Open **`http://<camera-ip>/`** in a browser.
4. Enter the **new SSID** + **password**, keep "WPA/WPA2", click **Save & reconnect**.
5. The camera writes `wifi.conf` and reconnects (~30 s). If you moved it to **another**
   network, it disappears from the current one → find it on the new one.

The page starts by itself at every boot.

---

## Finding the camera's IP (DHCP)

From the PC, on the same network as the camera (replace the MAC with yours, printed in
`LIBERATOR-RESULT.txt` on the SD card):

```bash
$t = 1..254 | ForEach-Object { (New-Object Net.NetworkInformation.Ping).SendPingAsync("192.168.1.$_",300) }
[Threading.Tasks.Task]::WaitAll($t) | Out-Null; Start-Sleep 1
(arp -a) | Select-String 'xx-xx-xx-xx-xx-xx'   # your camera's MAC, lowercase with dashes
```

(Adapt `192.168.1` to your network prefix.) Otherwise, check the device list on your router.

---

## Method 2 — Telnet (command line)

```bash
telnet <camera-ip> 24      # no password
```
Then on the camera:
```sh
vi /etc/config/camecrack/wifi.conf      # change SSID="..." and PASS="..."
sh /etc/config/camecrack/wifi_up.sh     # apply now
```
`wifi.conf` format: `MODE=sta`, `SSID="My Network"`, `PASS="password"`,
`SECURITY=3` (WPA/WPA2) or `0` (open), `DHCP=1`.

---

## Method 3 — Camera hotspot (camera offline, no PC) ✅

If the camera can no longer find its network (new router, new password, moving house…), about
2 minutes after boot it opens an **open** Wi-Fi network **`CAMECRACK-XXXX`** (last 4
characters of its MAC).

1. Phone → Wi-Fi → **`CAMECRACK-XXXX`** (turn mobile data off). The setup page opens by
   itself ("Sign in to network"); otherwise open **`http://10.1.8.1/`**.
2. Enter the **new SSID** + **password**, **Save**.
3. The camera reboots and joins that network (~1 min). Put the phone back on its usual Wi-Fi
   and find the camera's IP.

Force the hotspot while the camera is connected: **3 short presses** on the reset button
within 5 s. A long press only reboots the camera (the Tuya factory reset is disabled).
With no client for 10 min, the camera reboots and retries its Wi-Fi.
Technical details: [`AP-NOTES.md`](AP-NOTES.md).

---

## Method 4 — SD card (fallback, camera offline)

Prepare a card with the new network and insert it. From the PC:
```bash
python3 installer/prepare_sd.py --sd E: --ssid "My Network" --password "password"
```
The camera boots in **toolkit mode** (the no-SD hook stays idle) and the **liberator copies
the new `wifi.conf` into the flash** (it changed since the last install). Remove the card and
reboot: the no-SD mode uses the new network.

---

## If something goes wrong

- The camera keeps the previous `wifi.conf` as **`/etc/config/camecrack/wifi.conf.bak`**
  (last known network) — restore it over telnet if needed.
- Worst case: **insert the SD card** → toolkit mode → telnet access is back.
- Full flash backup: `backup/<MAC>/` on the SD card (copy it to your PC).
