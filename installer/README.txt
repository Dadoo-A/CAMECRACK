===========================================================
  CAMECRACK - SD card installer (plug-and-play)
===========================================================

Goal: a card you prepare once, insert in the camera, and it frees it:
local mode (RTSP / telnet / PTZ), no cloud, and the "no-SD" mode installed
into the camera's flash automatically (the "liberator"). Full guide: ../README.md

-----------------------------------------------------------
WHAT YOU NEED
-----------------------------------------------------------
- A micro-SD card formatted FAT32 (ideally <= 32 GB).
- A card reader on the PC.

-----------------------------------------------------------
PREPARE THE CARD (simplest)
-----------------------------------------------------------
1. Insert the SD card in the PC.
2. Run  python3 prepare_sd.py   (Windows: double-click Prepare-SD.bat)
3. Answer the questions: drive letter, Wi-Fi name, password.
4. Eject the card safely.

   Command-line variant:
     python3 prepare_sd.py --sd E: --ssid "My Wifi" --password "secret" --web-password "pw"
   Options: --security 3 (1=open, 2=wep, 3=wpa/wpa2)
            --dhcp 1
            --clean  (removes the old CAMECRACK payload first; backup\ is never deleted)

-----------------------------------------------------------
USE THE CARD
-----------------------------------------------------------
1. Insert the card in the camera, plug in the power.
2. Wait 2-3 min: the camera joins the Wi-Fi, backs up its flash to the card
   (backup\<MAC>\) and installs the no-SD mode.
3. Read LIBERATOR-RESULT.txt at the root of the card (on the PC).
4. Remove the card and power-cycle: the camera stays free without it.
5. Put the camera IP in ..\.env (CAMERA_IP=...), then  docker compose up -d
   from the CAMECRACK folder -> control page at http://localhost:8787/

-----------------------------------------------------------
CHANGE NETWORK OR CAMERA
-----------------------------------------------------------
Run prepare_sd.py (or Prepare-SD.bat) again with the new Wi-Fi, insert the card, power on.

-----------------------------------------------------------
WHAT THE PAYLOAD DOES (summary)
-----------------------------------------------------------
- Non-destructive root through bind mounts (SD toolkit, downloaded by prepare_sd.py).
- OFFLINE=1 : blocks the Tuya cloud.
- TELNET=1  : passwordless telnet on port 24 while the SD card is inserted.
- liberator.conf TELNET=off|on : telnet in no-SD mode (off by default).
- ONVIF=1 + ONVIF_PTZ=1 : ONVIF stack + PTZ (port 8080).
- _ak39_factory.ini : factory mode -> RTSP server (port 554).
- wifi.conf : your Wi-Fi settings (written by the script).
- custom/scripts/liberator.sh + camecrack/ : installs the no-SD mode into flash
  (setting: custom/configs/liberator.conf = install | off | uninstall).

See NOTICE.txt for where the payload comes from (open-source project).
