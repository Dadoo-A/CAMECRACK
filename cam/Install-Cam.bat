@echo off
title CAMECRACK - webcam setup
cd /d "%~dp0"
rem One-time setup (re-run on any new PC): Python packages, detection models, virtual webcam driver.
rem Python 3.12 first: it is the version the packages are pinned for (and "py -3" may pick a
rem newer Python without them).
set "PY="
py -3.12 -c "" >nul 2>nul && set "PY=py -3.12"
if not defined PY py -3 -c "" >nul 2>nul && set "PY=py -3"
if not defined PY python -c "" >nul 2>nul && set "PY=python"
if not defined PY (
  echo Python 3 is not installed: winget install Python.Python.3.12  ^(or https://www.python.org/downloads/^)
  goto :end
)
echo Using %PY%
%PY% "%~dp0setup_cam.py" %*
:end
echo.
pause
