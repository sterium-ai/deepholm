@echo off
rem Deepholm - play the latest main. Updates the clone, re-imports and launches Godot (GUI).
setlocal
set REPO=%~dp0..
cd /d "%REPO%" || exit /b 1
if "%GODOT%"=="" set GODOT=C:\dev\Going Deeper\tools\godot\Godot_v4.7.2-stable_win64_console.exe
set GODOT_GUI=%GODOT:_console.exe=.exe%
if not exist "%GODOT_GUI%" set GODOT_GUI=%GODOT%
echo [play] updating main...
git fetch -q origin main && git merge -q --ff-only origin/main
if errorlevel 1 echo [play] WARNING: could not fast-forward main (local changes?); playing the current checkout.
if exist tools\sync_pack_assets.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_pack_assets.ps1
echo [play] importing...
"%GODOT%" --headless --path game --import >nul 2>&1
echo [play] launching %GODOT_GUI%
start "" "%GODOT_GUI%" --path "%REPO%\game" --resolution 1600x900
endlocal
