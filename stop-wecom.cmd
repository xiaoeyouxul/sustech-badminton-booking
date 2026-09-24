@echo off
echo This will force-close Enterprise WeChat. Unsaved content may be lost.
taskkill.exe /F /T /IM WXWork.exe
echo.
pause
