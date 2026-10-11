@echo off
rem Ready or Not sound import: picks the officer lines (SWATEli) and the weapon sounds (Weapons[0]),
rem puts them in the game, checks every file it wrote and replaces bad ones.
rem Report: assets\audio\_import\REPORT.md   Folders and line table: tools\audio\import_ron.json
rem Options are passed on, e.g.  import_ron.bat --dry-run   or   import_ron.bat --only voice
setlocal
set "ROOT=%~dp0..\.."
set "BASE_PY=D:\tools\sao\Scripts\python.exe"
set "ASR_ENV=D:\tools\ron_asr"
set "PYTHONIOENCODING=utf-8"
if not exist "%BASE_PY%" set "BASE_PY=python"

rem Speech recognition (faster-whisper) lives in its own environment so the sound generator stays untouched.
if not exist "%ASR_ENV%\Scripts\python.exe" "%BASE_PY%" -m venv "%ASR_ENV%"
"%ASR_ENV%\Scripts\python.exe" -c "import numpy, scipy, soundfile, faster_whisper" 2>nul
if not errorlevel 1 goto run
echo Installing speech recognition into %ASR_ENV% (once, a few hundred MB)...
"%ASR_ENV%\Scripts\python.exe" -m pip install --upgrade pip
"%ASR_ENV%\Scripts\python.exe" -m pip install numpy scipy soundfile faster-whisper
"%ASR_ENV%\Scripts\python.exe" -c "import numpy, scipy, soundfile, faster_whisper" 2>nul
if errorlevel 1 goto noasr

:run
"%ASR_ENV%\Scripts\python.exe" "%ROOT%\tools\audio\import_ron.py" %*
goto done

:noasr
echo Speech recognition could not be installed: matching by the line table and file names only.
"%BASE_PY%" "%ROOT%\tools\audio\import_ron.py" --no-asr %*

:done
echo.
echo Report: %ROOT%\assets\audio\_import\REPORT.md
pause
