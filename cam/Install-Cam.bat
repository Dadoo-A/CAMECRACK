@echo off
title CAMECRACK - webcam setup
cd /d "%~dp0"
rem One-time setup (re-run on any new PC): Python packages, detection models, virtual webcam driver.
where py >nul 2>nul && (py -3 "%~dp0setup_cam.py" %* & goto :end)
where python >nul 2>nul && (python "%~dp0setup_cam.py" %* & goto :end)
echo Python 3 is not installed: winget install Python.Python.3.12  (or https://www.python.org/downloads/)
:end
echo.
pause
