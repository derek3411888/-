@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
set "DEV_RUNTIME_ROOT=%~dp0.dev-runtime"
set "DEV_RUN_ROOT=%DEV_RUNTIME_ROOT%\temp\batch-%RANDOM%-%RANDOM%"
if not exist "%DEV_RUN_ROOT%" mkdir "%DEV_RUN_ROOT%"
if not exist "%DEV_RUNTIME_ROOT%\npm-cache" mkdir "%DEV_RUNTIME_ROOT%\npm-cache"
if not exist "%DEV_RUNTIME_ROOT%\cache" mkdir "%DEV_RUNTIME_ROOT%\cache"
set "TEMP=%DEV_RUN_ROOT%"
set "TMP=%DEV_RUN_ROOT%"
set "TMPDIR=%DEV_RUN_ROOT%"
set "NPM_CONFIG_CACHE=%DEV_RUNTIME_ROOT%\npm-cache"
set "XDG_CACHE_HOME=%DEV_RUNTIME_ROOT%\cache"

echo ==========================================
echo 全自動鋤地 - 完整發布更新
echo Launcher、Payload、網站與 Docker 會一起更新
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0完整發布更新.ps1"
set "RELEASE_EXIT=%ERRORLEVEL%"
if exist "%DEV_RUN_ROOT%" rmdir /s /q "%DEV_RUN_ROOT%"
if not "%RELEASE_EXIT%"=="0" (
    echo.
    echo [失敗] 完整發布未完成；未通過的步驟已顯示在上方。
    pause
    exit /b 1
)

echo.
echo [完成] 四個元件已打包、推送、部署並通過整合測試。
pause
exit /b 0
