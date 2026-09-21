# 遊戲維護與自動來源辨識：驗收紀錄

日期：2026-09-21；開發分支：`codex/game-maintenance-20260921`。本次僅開發、隔離測試與編譯，沒有推送、發布、部署或執行遊戲。正式 `E:\Downloads\自動鋤地` 未覆寫。

## 已有證據

- 官方公開 HTTPS 唯讀查詢：2026-09-21T12:45:41Z，成功讀取來源且無當前適用維護事件。這不是實際版本更新成功證據。
- **同一台本機**兩套安裝唯讀識別：Kuro 位於 `D:\GAME\Wuthering Waves\Wuthering Waves Game`，官方 launcher metadata 指向 Guangzhou Kuro；Steam 位於 `D:\GAME\steam\steamapps\common\Wuthering Waves`，固定 App 3513350。未存取帳號資料，未對另一台電腦做實機驗收。
- Windows PowerShell 5.1／AHK 測試涵蓋官方正文時間／時區、TTL／延長／衝突／失敗、入口與 junction、自動來源、原子 journal、STOP／PAUSE／時鐘、04:00 排程、F11 去重、安全 OCR、JSON／Firestore／ACK、通知去重、套件包含與排除。
- 真實隔離 AHK→PowerShell helper→snapshot→停止生命週期測試通過；此模式不查網路、不開遊戲，只讀測試路徑。
- Headless Edge 兩網站樣式共 8 組排版（390×844、1920×1080、CSS 125%／150%）：無橫向溢出；已送出／拒絕／已套用／離線與保留草稿通過。只有 loopback fixture 網路，沒有正式命令或資料庫寫入。截圖在 `.dev-runtime/diagnostics/game-maintenance/browser`。
- 本機新增分頁以實際隱藏 AHK 控制項檢查位置，不遮住 Save footer；不是實際 15 吋裝置的可見 DPI 驗收。
- `測試/Build-GameMaintenanceSmoke.ps1` 實際編譯 Payload 與嵌入新 Payload ZIP 的 Launcher，validate／ZIP 檢查通過；產物在 `.dev-runtime/build/game-maintenance-*`，附 SHA-256、長度與 `compile-result.json`，**未執行、不可當成正式發布版**。
- 打包腳本新增源碼 parser／全部維護測試、必要模組與 ZIP 排除政策；測試並修正 PS 5.1 UTF-8 BOM 與 GUI 子程序 ExitCode 可能為空的問題。

## 最後一輪整合審查修正

一次獨立審查提出 8 項 Important，沒有 Critical／Minor；已依失敗回歸測試修正，並重新跑全套。這不是正式環境上線或真實遊戲更新的驗收。詳細紀錄見 [整合修正與測試](game-maintenance-final-review.md)。

- 15 個維護測試檔全部通過；網站 83 項測試全部通過，沒有跳過。
- 停錄、更新器／OCR 回呼期間收到的已 ACK 切服／全部完成意圖，不會被旧判斷覆蓋。
- 登入及送 F11 前重新檢查最新公告、時間、PAUSE、日循環、目標伺服器與實際遊戲視窗；變更時等待，不套用一般前景失敗重啟。
- 維護路徑只接受設定對應安裝的 canonical exe、PID 建立時間與 HWND；多個候選或身分變更不任選，也不進全域清場。
- 已送過 F11 的接續，只有原 OKWW 身分與目標主畫面都通過才可跳過管理器／送鍵。未知旧狀態不清除嘗試旗標來重送。
- 公告替換／消失不會刷新旧開服資料；人工略過只取消時間等待。Kuro 舊的 Play／未知觀察不會蓋掉已啟動的遊戲。
- 過期且尚無更新動作的事件使用實際 UTC 判斷；已保存的動作意圖仍受保護。

## 尚未通過的實機／發布門檻

1. Steam 真實啟動與下載／安裝／驗證鏈，以及 Kuro 真實 launcher 按鈕 layout／更新鏈；兩者均未啟動實測。程式因此未建立 `adapter-acceptance.ini`，`updateAdapterReady` 保持 false。
2. 沒有真實待更新包，因此不能宣稱已通過版本升級。合成公告、spy、假安裝只能證明程式邏輯；Steam 自主排程下載也不受腳本控制。
3. 正式兩台執行端、正式控制資料庫、網站與郵件的端到端測試未執行。本次限制不允許存取憑證、改系統／服務、啟動遊戲或自行推送；等授權工作階段再測，不繞過安全門檻。
4. 正式發布前仍需同步版本、Launcher、Payload ZIP、server bundle，驗證固定 commit 下載 hash 與兩網站部署；本次只做不發布的編譯。

## 驗證命令

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 測試/Invoke-GameMaintenanceTests.ps1 -Suite All
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 測試/PowerShellDevelopmentPathPolicyTest.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File 測試/Build-GameMaintenanceSmoke.ps1
# npm／browser 命令先呼叫 ProjectDevelopmentPaths.ps1，讓所有 cache/log 留在專案
npm --prefix self-hosted-server run check
npm --prefix self-hosted-server test
git diff --check
```

完整測試尾端、review 結果與本次取捨另保存在專案內 `.dev-runtime/diagnostics/game-maintenance`；不得把它們一起包進客戶端。
