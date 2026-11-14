@echo off
title CAMECRACK - webcam + tracking
cd /d "%~dp0"
rem Webcam "Unity Video Capture" for Discord / Teams / the browser, with tracking and a preview.
rem Options: --no-track  --no-webcam  --target cat  --invert-pan  --speed 0.6  (see --help)
rem FFmpeg decoder messages go to camecrack_cam.log instead of flooding this window.
rem Same Python as Install-Cam.bat (3.12 first).
set "PY="
py -3.12 -c "" >nul 2>nul && set "PY=py -3.12"
if not defined PY py -3 -c "" >nul 2>nul && set "PY=py -3"
if not defined PY set "PY=python"
%PY% "%~dp0camecrack_cam.py" --preview %* 2> "%~dp0camecrack_cam.log"
if errorlevel 1 (
  echo.
  echo *** The camera app stopped with an error. Last lines of camecrack_cam.log:
  powershell -NoProfile -Command "Get-Content '%~dp0camecrack_cam.log' -Tail 8"
  echo *** Missing module? Run Install-Cam.bat once, then try again.
  pause
)
