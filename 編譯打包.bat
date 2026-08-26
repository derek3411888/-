@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

echo ==========================================
echo 全自動鋤地 - 完整發布更新
echo Launcher、Payload、網站與 Docker 會一起更新
echo ==========================================
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0完整發布更新.ps1"
if errorlevel 1 (
    echo.
    echo [失敗] 完整發布未完成；未通過的步驟已顯示在上方。
    pause
    exit /b 1
)

echo.
echo [完成] 四個元件已打包、推送、部署並通過整合測試。
pause
exit /b 0
