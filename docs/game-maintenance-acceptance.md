# 遊戲維護與自動來源辨識：驗收紀錄

初始驗收日期：2026-09-21；開發分支：`codex/game-maintenance-20260921`。以下保留歷史驗收，不能把當時未啟動／未發布的狀態當成現況。

## 2026-10-03 更新下載修復

- 本輪預計 5.24／5.36／1.0.83；發布與正式端 uptake 必須分開驗證。既有正式程式沒有由測試啟停；Docker 不部署。
- 效能證據：MYDESKPC 新原生 helper 完整 Payload 34,873,180 bytes／3.709 秒，Launcher 37,516,800 bytes／4.946 秒，獨立 SHA 全部通過。MYTUF 原生 Remote worker 的同檔 curl 對照：raw 25 秒只收到約 1 MB，官方 API 完整 Payload 2.463 秒，SHA 通過。此為當次實測，不承諾所有網路／時間固定速度。
- 隔離測試：13 個 native cases 包含持續進度、斷線續傳、忽略 Range、錯誤 Range、毀損、截斷、idle／total 截止、跨 invocation 續傳、verified destination 重用、parent-exit、輸入拒絕、API 403 備援及跨來源續傳。另有實際 AHK wrapper 和正式分支錯誤傳遞，及選用 `LauncherDownloadRegressionTest.ps1 -LongTransfer` 驗證超過原 100 秒仍可成功。
- `Background` 含新增三個 test files，預期 46 檔；另跑既有 19 項 restart handoff、網站／server 和發布語法／PE 資源測試。NativeMaintenanceTest、NativePerformanceTelemetryTest、NativeRuntimeUtilitiesTest、ImagePutLifetimeTest、MainInstanceOwnershipTest、LauncherNativeHelperDrainTest 保持原零基線 guard，仍為 DEFERRED。
- 審查兩輪均 Critical 0／Important 0；不將 code review 或 loopback PASS 視為公開網路／正式客戶端更新證據。驗證紀錄放本專案 `.dev-runtime/diagnostics/game-maintenance`。

## 2026-10-01 最新驗收與剩餘界線

| 項目 | 本輪已取得的證據 | 不代表什麼 |
| --- | --- | --- |
| 發布完整性 | Launcher 5.33／Payload 5.21／server bundle 1.0.80；manifest `47b0a2e7e1a4292d04d7c9feed856966568836b5` 固定產物來源 `9dd27d5eb1e0596935c3eaf191c1fc859d9ab5bb`，三份公開下載 SHA 與兩端正式 EXE SHA 已核對 | server bundle 發布不等於中央 Docker 已部署 |
| 啟動衝突與內嵌檔 | 發布前 All 40 檔、19 項 restart handoff、108 項網站／服務端測試、AHK 編譯及最終 PE 內嵌 helper SHA 通過 | 不代表之後任何 dirty patch 已重新通過同一發布 gate |
| MYDESKPC／Steam | 19:26 正式啟動；19:29 經 Steam 入口恢復；主畫面、OKWW F11 效果、LRMCAI 真實尋路／戰鬥／下一任務已驗證；19:59 online=true／RUN、ACK120；20:52 仍有路線完成證據 | 程序存在、啟動 ACK 或這份歷史 checkpoint 不能代替之後的即時狀態 |
| MYTUF／Kuro | 19:46 正式啟動；經官方啟動器開遊戲；Asia 切服後置檢查、主畫面、F11 效果及 LRMCAI 進度已驗證；19:59 online=true／RUN、ACK119，HMT 已完成狀態保留；20:52 仍有路線完成證據 | 部分任務仍會傳送失敗，不能宣稱每條路線正常或當日全部任務完成 |
| 真實版本升級 | 來源辨識、更新策略與 adapter 邊界有隔離測試，兩種現有安裝均取得真實啟動證據 | 本輪沒有可用的真實待更新事件；Steam／Kuro 遊戲下載安裝及 Kuro 啟動器自身更新，仍不得標成完整實機通過 |
| 正式 runtime | 原生 helper 已接替可達的 PowerShell 輔助流程，未更改 ExecutionPolicy，未使用 Bypass | 開發 PS7 通過不是 PS5.1 產品相容性的替代證據；歷史 worker 的描述亦不是現行 runtime |

20:00 後新增的狀態回報補丁尚未發布：觀察窗結束時更新步驟、只以新鮮正向進度標記歷史錯誤恢復、PAUSE 重驗，以及把同步心跳留在 Critical 之外。Policy 4 檔、Transport 5 檔與網站 110 項測試通過，review Critical 0／Important 0；新版完整 All 43 檔仍待乾淨 baseline，不能借用 5.33 的發布結果宣稱補丁已部署。

可重讀原始證據均在開發專案 `.dev-runtime/diagnostics/game-maintenance/`：`release-live-acceptance-20261001.md`、`both-host-live-checkpoint-20261001-1959.json`、`published-verification-20261001-192429/result.json`、`recovery-status-20261001/checkpoint.md` 與 `remote-worker/`。不將診斷資料打包到客戶端，不偽造 adapter 驗收檔，不重下載或修改 build 製造待更新狀態。

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

## 2026-09-22 當時尚未通過的門檻（歷史紀錄；現況以上方最新章節為準）

1. Steam 真實啟動與下載／安裝／驗證鏈，以及 Kuro 真實 launcher 按鈕 layout／更新鏈；兩者均未啟動實測。程式因此未建立 `adapter-acceptance.ini`，`updateAdapterReady` 保持 false。
2. 沒有真實待更新包，因此不能宣稱已通過版本升級。合成公告、spy、假安裝只能證明程式邏輯；Steam 自主排程下載也不受腳本控制。
3. 正式兩台執行端、正式控制資料庫與郵件的端到端測試未執行。9/22 已追加發布授權，但未操作正式遊戲／服務或存取憑證，不繞過實機驗收门檻。
4. 9/22 已完成同步版本、Launcher、Payload ZIP、server bundle 的發布、固定 commit 下載雜湊及 GitHub Pages 部署；中央自架 Docker 網站部署仍未執行。

## 驗證命令

使用專案開發 PowerShell 7，不改系統 ExecutionPolicy，也不加 Bypass。完整 All 只在已安全結束正式流程、確認 AHK／遊戲的乾淨 baseline 後執行；不能移除其 baseline 保護。產品使用原生 helper，這些是開發測試命令，不是遊戲啟動入口。

### 2026-10-02 使用者指定的背景發布驗收

兩台正在執行，使用者明確指定「可以背景測試，完成 OK 就打包更新」。本輪以 `Background` 為發布範圍，不停止正式鋤地、不使用滑鼠／鍵盤、不啟動正式主腳本。隔離測試只操作自己的 fixture 程序與資料夾。

`Background` 執行 41 個維護測試檔；以下六項在輸出中明列 `DEFERRED`，不是 PASS：`NativeMaintenanceTest.ps1`、`NativePerformanceTelemetryTest.ps1`、`NativeRuntimeUtilitiesTest.ps1`、`ImagePutLifetimeTest.ps1`、`MainInstanceOwnershipTest.ps1`、`LauncherNativeHelperDrainTest.ps1`。前述完整零基線／ownership 驗收保留在預設 `All`，不得以背景測試結果宣稱本輪完整 All 或新版本實機驗收已完成。

打包仍執行其餘 AHK 語法／編譯、19 項隔離 restart handoff、網站／服務端、ZIP 內容與 PE 內嵌資源驗證。交接重試、遠端命令進入、PAUSE 清理競態與新啟動預算重置均有實際 production function 隔離回歸。發布後核對固定 commit 與三份遠端產物雜湊；不因此熱重啟現有執行端或部署 Docker。

```powershell
pwsh -NoProfile -File 測試/Invoke-GameMaintenanceTests.ps1 -Suite Background
pwsh -NoProfile -File 完整發布更新.ps1 -ValidationProfile Background -SkipDocker
```

### 完整零基線驗收（另在安全停機時進行）

```powershell
pwsh -NoProfile -File 測試/Invoke-GameMaintenanceTests.ps1 -Suite All
pwsh -NoProfile -File 測試/PowerShellDevelopmentPathPolicyTest.ps1
pwsh -NoProfile -File 測試/Build-GameMaintenanceSmoke.ps1
# npm／browser 命令先呼叫 ProjectDevelopmentPaths.ps1，讓所有 cache/log 留在專案
npm --prefix self-hosted-server run check
npm --prefix self-hosted-server test
git diff --check
```

完整測試尾端、review 結果與本次取捨另保存在專案內 `.dev-runtime/diagnostics/game-maintenance`；不得把它們一起包進客戶端。

## 2026-10-03 更新日整天略過與早晨啟動失敗修正

本次版本：Payload 5.23／Launcher 5.35／server bundle 1.0.82。依使用者新需求，取代「開服後自動更新」：官方更新日以台灣時間 00:00–23:59 整天略過並寄送一次通知；其他日期使用已驗證安裝的原廠 `Wuthering Waves.exe` 入口，仍需主畫面驗證。不改反作弊／Steam 驗證、不直接執行 Shipping 本體。遊戲若仍要求更新或登入，停止並通知，不以程序存在宣告成功。

根因：桌機 04:08 的內部重啟經 launcher 下載逾時約 405 秒，超出 180 秒交接 ACK 期限。MYTUF 04:09 舊遊戲退出後，同一安裝又產生新遊戲程序，但完整退出 guard 拒絕重啟，留下遊戲。本次內部重啟改直接接續已安裝 payload，外部全新啟動仍可更新專案；保留 ownership／nonce／錄影／切服與新啟動預算重置修正，不做整個 repository rollback。

隔離驗證包含更新日開服前後、午夜、公告故障、跨新任務通知去重、舊版本解除 pin、正式 native 公告 selector、PAUSE 保持在線和凍結逾時、PAUSE 跨日與既有視窗不能繞過日界 gate、真實 host function 接線。Background 43 測試檔、19 項 handoff、111 項網站／服務端，以及 native notice 20 項通過；最終唯讀 review Critical 0／Important 0。六項零基線 suite 仍標示 DEFERRED，不宣稱完整 All。

本次不啟動正式鋤地：桌機 07:38 的遠端 STOP 保留，MYTUF 手動啟動後 07:53 已有實際戰鬥進度，不中斷。原廠入口的真實 Steam／Kuro 登入、SMTP 送達、新版客戶端採用及中央 Docker 部署仍需各自實機證據，不能用背景測試或發布取代。
