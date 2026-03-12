@echo off
chcp 65001 >nul
echo ==========================================
echo 全自動鋤地程式 - 編譯打包工具
echo ==========================================
echo.

echo 步驟 1: 清理專案中的無用檔案...
echo ==========================================

REM 刪除 payload 中的測試檔案
if exist "payload\debug_test.ahk" del "payload\debug_test.ahk" && echo ✅ 刪除: debug_test.ahk
if exist "payload\simple_test.ahk" del "payload\simple_test.ahk" && echo ✅ 刪除: simple_test.ahk
if exist "payload\test_*.ahk" del "payload\test_*.ahk" && echo ✅ 刪除: test_*.ahk
if exist "payload\fix_*.ahk" del "payload\fix_*.ahk" && echo ✅ 刪除: fix_*.ahk
if exist "payload\*_fixed.ahk" del "payload\*_fixed.ahk" && echo ✅ 刪除: *_fixed.ahk
if exist "payload\*_backup.ahk" del "payload\*_backup.ahk" && echo ✅ 刪除: *_backup.ahk

REM 刪除備份目錄中的檔案
if exist "backups\*.ahk" del "backups\*.ahk" && echo ✅ 刪除: backups 中的備份檔案
if exist "backups\*.md" del "backups\*.md" && echo ✅ 刪除: backups 中的文檔

REM 刪除臨時檔案
if exist "payload\temp*.png" del "payload\temp*.png" && echo ✅ 刪除: 臨時圖片
if exist "payload\ue4crash*.png" del "payload\ue4crash*.png" && echo ✅ 刪除: 崩潰截圖
if exist "payload\menu*.png" del "payload\menu*.png" && echo ✅ 刪除: 選單截圖
if exist "payload\*fallback*.log" del "payload\*fallback*.log" && echo ✅ 刪除: 備用日誌

REM 刪除根目錄的無用檔案
if exist "*.tmp" del "*.tmp" && echo ✅ 刪除: 暫存檔案
if exist "*.bak" del "*.bak" && echo ✅ 刪除: 備份檔案
if exist "*_test.bat" del "*_test.bat" && echo ✅ 刪除: 測試批次檔
if exist "debug.log" del "debug.log" && echo ✅ 刪除: 除錯日誌
if exist "*_fallback.log" del "*_fallback.log" && echo ✅ 刪除: 啟動器日誌

echo 專案清理完成！
echo.

echo 步驟 2: 檢查必要檔案...
echo ==========================================

if not exist "打包啟動器.ahk" (
    echo ❌ 找不到 打包啟動器.ahk
    pause
    exit /b 1
)
echo ✅ 打包啟動器.ahk

if not exist "payload.zip" (
    echo ❌ 找不到 payload.zip
    echo    請確保 payload.zip 包含所有程式檔案
    pause
    exit /b 1
)
echo ✅ payload.zip

if not exist "AutoHotkey64.exe" (
    echo ❌ 找不到 AutoHotkey64.exe
    echo    請從 https://www.autohotkey.com 下載 AutoHotkey v2
    pause
    exit /b 1
)
echo ✅ AutoHotkey64.exe

REM 檢查 Ahk2Exe 是否可用
echo.
echo 正在檢查編譯器...

set "AHK2EXE_FOUND="
REM 嘗試多個可能的路徑
if exist "%ProgramFiles%\AutoHotkey\Compiler\Ahk2Exe.exe" (
    set "AHK2EXE=%ProgramFiles%\AutoHotkey\Compiler\Ahk2Exe.exe"
    set "AHK2EXE_FOUND=YES"
) else if exist "C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe" (
    set "AHK2EXE=C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe"
    set "AHK2EXE_FOUND=YES"
) else if exist "Ahk2Exe.exe" (
    set "AHK2EXE=Ahk2Exe.exe"
    set "AHK2EXE_FOUND=YES"
)

if "%AHK2EXE_FOUND%"=="YES" (
    echo ✅ 找到編譯器: %AHK2EXE%
) else (
    echo ❌ 找不到 Ahk2Exe.exe 編譯器
    echo    請確保已安裝 AutoHotkey v2
    pause
    exit /b 1
)

echo.
echo ==========================================
echo 開始編譯...
echo ==========================================
echo.

REM 編譯指令
echo 執行編譯指令...
"%AHK2EXE%" /in "打包啟動器.ahk" /out "全自動鋤地.exe" /base "AutoHotkey64.exe"

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ✅ 編譯成功！
    echo.
    echo 生成的檔案：
    if exist "全自動鋤地.exe" (
        for %%F in ("全自動鋤地.exe") do echo    全自動鋤地.exe ^(%%~zF bytes^)
    )
    echo.
    echo 🎉 現在可以將 全自動鋤地.exe 分發給用戶使用！
    echo.
    echo 用戶使用說明：
    echo 1. 以系統管理員身分執行 全自動鋤地.exe
    echo 2. 程式會自動解壓所需檔案到同一目錄
    echo 3. 不需要預先安裝 AutoHotkey
) else (
    echo.
    echo ❌ 編譯失敗！錯誤代碼: %ERRORLEVEL%
    echo.
    echo 可能的原因：
    echo 1. 腳本語法錯誤
    echo 2. 檔案被佔用
    echo 3. 權限不足
    echo.
    echo 請檢查錯誤訊息並修正後重試。
)

echo.
pause
