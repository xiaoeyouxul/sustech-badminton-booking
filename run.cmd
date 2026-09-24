@echo off
cd /d "%~dp0"
if not exist "config.json" (
    copy "config.example.json" "config.json" >nul
    echo Created config.json. Edit and save it, then run this file again.
    notepad.exe "config.json"
    pause
    exit /b 0
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0booking.ps1" -ValidateOnly
if errorlevel 1 (
    echo Please correct config.json in Notepad, save it, and run this file again.
    notepad.exe "config.json"
    pause
    exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0booking.ps1"
echo.
pause
