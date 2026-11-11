@echo off
title CAMECRACK - Prepare the SD card
cd /d "%~dp0"
rem prepare_sd.py runs on Windows, macOS and Linux (Python 3.8+, standard library only).
where py >nul 2>nul && (py -3 "%~dp0prepare_sd.py" %* & goto :end)
where python >nul 2>nul && (python "%~dp0prepare_sd.py" %* & goto :end)
echo Python 3 is not installed.
echo   - Install it:  winget install Python.Python.3.12   (or https://www.python.org/downloads/)
echo   - Or with Docker (replace E: with your SD card):
echo       docker run --rm -it -v "%~dp0:/installer" -v E:\:/sd python:3.12-alpine python /installer/prepare_sd.py --sd /sd
:end
echo.
pause
