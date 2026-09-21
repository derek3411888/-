# 版本維護功能：整合修正與測試

2026-09-21，`codex/game-maintenance-20260921`。範圍僅限本專案開發、隔離測試及隔離編譯，未發布／部署／執行真實遊戲或更新器。使用者原有 VS Code 設定與 OCR 實驗檔保留。

## 審查與單次修正

獨立 reviewer 檢查 `dbabea7..7d9c98f`，原結論為 8 Important，0 Critical，0 Minor。下列為作者依測試完成的一次修正，不冒稱 reviewer 已重新核准。

| 問題 | 修正 | 回歸證據 |
| --- | --- | --- |
| OCR／停錄回呼後舊狀態覆蓋遠端 ACK | intentRevision 比較後才能發布／保存；Critical 僅包短狀態寫入 | Startup 的 StopRecording／ApplyEffect × switch／complete 均 RED→GREEN |
| 更新交接後仍使用舊登入放行 | 進登入、管理器前及實際送鍵前重查同一策略；延期、PAUSE、時鐘、排程阻擋後等待 | Startup 安全測試及實際 GM_MarkF11Attempt 抽取測試 |
| Steam／Kuro 同名遊戲視窗混用 | canonical game path、PID 建立時間、HWND 鎖定；多候選、重用身分拒絕；維護入口不全域清場 | 錯安裝、重複候選、PID／HWND 重用、消失視窗測試 |
| 新事件取代公告，卻刷新舊公告時間 | 不同事件衝突或原事件未重新證實時保留舊資料但不放行 | Notice 變更起始時間／移除公告 RED→GREEN |
| Kuro 舊 Play／unknown 蓋掉 game_running | 新鮮且可信的維護／主畫面優先；否則保留 verified game_running | 真實 PS snapshot→AHK GMHost_ReadInput RED→GREEN |
| 人工略過仍被 worker 的開服時間限制擋住 | worker 表示查詢新鮮度；普通策略另驗 checkedAt 過開服時間；skip 不略過新鮮度 | 真實 snapshot→policy 的普通／略過／到期重查三分支 |
| 保存 F11 後重啟無法接續 | 原 OKWW 的 PID／建立時間／HWND／路徑與目標主畫面都吻合，才回傳 resumed；管理器前處理 | F11 身分反例、actual host resumed 與 STOP；不清除已嘗試旗標 |
| 48 小時過期判斷未傳入現在時間 | actual GM_Init 與啟動前 continuation 均傳入 UTC；動作意圖仍保留 | actual GM_Init 的過期未動作／已動作測試 |

原有 journal 缺少新的可選 `f11OkwwIdentity` 欄位時仍可讀取；缺少身分證據表示不可自動證實重用，不表示可以再次送 F11。

## 驗證結果

- `Invoke-GameMaintenanceTests.ps1 -Suite All`：15 個測試檔通過（PowerShell 5.1／AutoHotkey v2）。
- `npm --prefix self-hosted-server run check` 與測試：83 通過，0 失敗，0 跳過。
- Headless Edge：兩網站樣式、8 組版面／縮放、ACK／拒絕／離線／保留草稿；網路限定 loopback fixture。
- 隱藏 AHK 設定頁幾何測試通過，不宣稱實際 15 吋螢幕可見測試。
- 原有鎖屏、遊戲載入寬限、伺服器名稱與切換、單檔錄影及 PS／AHK 產生路徑政策通過。
- Payload＋Launcher 真實編譯、嵌入新 Payload ZIP 與排除政策；產物及 SHA-256 在 `.dev-runtime/build/game-maintenance-*/compile-result.json`，未執行產物。
- `git diff --check` 通過；未操作 VS Code 問題面板。

測試中遇到的 AHK 保留字參數、抽取函式格式與測試檔副檔名問題已在測試中修正；沒有以略過測試掩蓋失敗。

## 必須保留的未完成項目

Steam／Kuro 真實更新鏈、真實待更新包、第二台執行端、正式網站／資料庫／郵件及 native DPI 均未完成端到端驗收。兩個 update adapter 的 acceptance 仍停用，沒有建立或偽造 `adapter-acceptance.ini`。本分支與隔離編譯不是已發布版本。

完整計畫 ledger、逐任務測試及原始 review package 整理在專案內 `.dev-runtime/diagnostics/game-maintenance/plan-execution`；沒有移到專案外。

Deferred minors：無。
