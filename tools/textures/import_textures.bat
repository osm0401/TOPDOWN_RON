@echo off
rem Free photo textures (ambientCG / Poly Haven zips) into the game.
rem Put each download in assets\textures\_download\ as <name>.zip (names: import_textures.bat --list).
setlocal
set "ROOT=%~dp0..\.."
set "PYTHONIOENCODING=utf-8"
python -c "import PIL" 2>nul || python -m pip install pillow
python "%ROOT%\tools\textures\import_textures.py" %*
pause
