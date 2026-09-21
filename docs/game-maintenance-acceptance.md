# 遊戲維護與自動來源辨識：驗收紀錄

初始驗收日期：2026-09-21；開發分支：`codex/game-maintenance-20260921`。當時僅開發、隔離測試與編譯，沒有推送、發布、部署或執行遊戲。2026-09-22 已獲授權發布，結果另見下方補充；正式 `E:\Downloads\自動鋤地` 未覆寫或重啟。

## 2026-09-22 發布補充

- 已推送 Payload 5.02／Launcher 5.13／Server bundle 1.0.65。產物固定在 `318363f`；manifest 固定來源提交為 `f84b98ba8513d391fa995e90fbd6f57d54e425e4`。
- Release ID：`p5.02-l5.13-s1.0.65-C7072342-634F29DB-662012DF-E330B944`。
- 維護 15 個測試檔、既有 AHK 回歸、語法檢查與網站 83 項測試重新通過；Launcher 在新 Payload ZIP 後重新編譯。發布檢查攔到既有發布／Codex bridge 腳本的 UTF-8 無 BOM 相容問題，已補 BOM 並新增 Windows PowerShell 5.1 實際 ParseFile 回歸，沒有改橋接業務邏輯。
- [公司用 GitHub Pages 部署](https://github.com/derek3411888/-/actions/runs/35628387088) 成功；實際首頁、app.js 版號為 `p5.02-l5.13-s1.0.65`，維護顯示模組 HTTP 200。
- 正式本機 Docker 未部署或重啟，正式客戶端未重啟；仍不得宣稱兩台已載入新版或真實遊戲更新已驗收。第 1、2、3 項實機門檻仍保留。
- 2026-09-21T16:58:50Z（台灣 9/22 00:58:50）直接呼叫官方公告模組：`outcome=ok`、`notice=null`、`fromCache=false`，符合當日返回平日流程的條件。
- 官方繁中前瞻 article 5456 與 KURO 官方新聞稿確認 3.7 日期為 2026-09-30（三）。截至本次查詢沒有 3.7 維護時間正文，不能拿上一版時段推定。
- 同聊天室 heartbeat `3-7` 已啟用：9/29 複核公告，9/30 03:30、10:30、11:30、12:30、14:30、18:30、20:30 追蹤（Asia/Taipei），正式時間公布後調整。排程截止 9/30，沒有年度重複；只追蹤與回報，不自動操作遊戲／服務或造假驗收旗標。
- 開發下載核對與官方查詢產物統一在 `.dev-runtime/diagnostics/game-maintenance/release-20260922/`；初次完整 HTTP 下載偏慢／中斷不視為校驗成功，必須以完成檔案的 SHA-256 為準。
- 三份遠端產物已完整讀取並核對 SHA-256 全部一致；下載 Payload ZIP 的模組清單、開發檔排除及內部 EXE 雜湊也已檢查，Server ZIP 內版本為 1.0.65。可重讀證據為上述目錄的 `download-verification.json`。

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
3. 正式兩台執行端、正式控制資料庫與郵件的端到端測試未執行。9/22 已追加發布授權，但未操作正式遊戲／服務或存取憑證，不繞過實機驗收门檻。
4. 9/22 已完成同步版本、Launcher、Payload ZIP、server bundle 的發布、固定 commit 下載雜湊及 GitHub Pages 部署；中央自架 Docker 網站部署仍未執行。

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
