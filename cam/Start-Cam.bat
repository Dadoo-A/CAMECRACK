@echo off
title CAMECRACK - webcam + tracking
cd /d "%~dp0"
rem Webcam "Unity Video Capture" for Discord / Teams / the browser, with tracking and a preview.
rem Options: --no-track  --no-webcam  --invert-pan  --invert-tilt  --speed 0.6  (see --help)
rem FFmpeg decoder messages go to camecrack_cam.log instead of flooding this window.
where py >nul 2>nul && (py -3 "%~dp0camecrack_cam.py" --preview %* 2> "%~dp0camecrack_cam.log" & goto :end)
python "%~dp0camecrack_cam.py" --preview %* 2> "%~dp0camecrack_cam.log"
:end
