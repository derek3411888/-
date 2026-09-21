# Game Maintenance and Provider Update Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 此計畫採同一工作階段逐項執行；沒有另開代理、重問模型或自行發布的要求。

**Goal:** 鳴潮版本更新日自動讀官方維護時間，自動辨識 Steam／官方啟動器，等預計開服後才更新並接回原鋤地流程。

**Architecture:** Windows PowerShell worker 負責唯讀公告、安裝來源與更新證據；AutoHotkey 純策略決定狀態，控制器管理持久接續與安全輸入。兩套網站共用狀態契約，沿用既有心跳、命令及設定 revision，不增加 Firestore 輪詢。資料來源不可用時依是否已有已知事件區分等待與平日降級。

**Tech Stack:** AutoHotkey v2、Windows PowerShell 5.1／.NET Framework、既有 Node >=22、PostgreSQL JSONB、既有 Firestore REST、HTML／CSS／JavaScript。

**Spec:** [2026-09-21-game-maintenance-design.md](../specs/2026-09-21-game-maintenance-design.md)；必須與本計畫一起讀取。

**Status:** 使用者於 2026-09-21 授權開始實作；以下核取項目依驗證證據逐項更新，未勾選不代表已完成。正式程式尚未部署。

## Global Constraints

- G1：預設自動判定安裝來源；不得要求每台裝置先手動選 Steam／官方版。
- G2：腳本發起的更新不得早於已驗證公告的預計開服時間；不主動預下載。
- G3：維護、更新、等待解鎖與遠端暫停時間不計入一般錯誤重啟次數。
- G4：維護等待與更新期間不新開正式錄影；維持單一 MKV 與既有直播程序隔離。
- G5：RUN／PAUSE／STOP、設定 revision、命令 nonce／claim／ACK 與心跳保持可用。
- G6：不得因等待、查公告或讀取進度而持續啟用、置頂或縮放遊戲／Steam 視窗。
- G7：維持現有 04:00 循環日、已完成伺服器、切服驗證與 LRMCAI 接續意圖。
- G8：中央 API、Firestore 或公司網站離線時，本機仍可自行查公告、保存狀態及等待。
- G9：開發產物均位於 repository；暫存、測試及截圖位於 `.dev-runtime`；正式客戶端狀態位於程式資料夾。
- G10：保留 `.vscode/settings.json` 與 `文字識別/LRMCAI主視窗OCR測試.ahk` 的使用者變更。
- G11：Windows PowerShell 5.1、AutoHotkey v2 與既有 Node >=22；客戶端不新增 Node、Python 或付費 API 相依。
- G12：自架與公司網站均顯示相同功能；不增加既有 Firestore 輪詢／心跳頻率或另建倒數寫入。
- G13：正式發布時 Launcher、Payload、Payload ZIP 與伺服器套件一起更新；本次規劃不執行打包、推送或部署。
- G14：一般網路錯誤不能歸類為維護；更新就緒、遊戲啟動、登入頁出現與主畫面可操作必須分開驗證。
- G15：不改 Steam 全域下載政策、不讀帳密、不自動操作登入驗證／UAC，也不停止其他 Steam 遊戲或共用 Steam 程序。

## Review Focus

1. 遠端 PAUSE 於維護等待時保存，Windows 重開後普通啟動參數不能清掉它；Task 5、8 做啟動參數與持久 journal 測試。
2. Steam 安裝存在，但設定入口指向另一套官方版／junction；Task 3 必須按實際入口判斷，含證據矛盾及非 C 槽測試。
3. F11 已嘗試後才出現維護提示；Task 7、8 應回到 WAIT_SERVER 且不重送切換型熱鍵，也不顯示鋤地成功。
4. 開服前一秒收到 STOP／較新延長公告、或時鐘突跳；Task 5、8 在副作用前重新比對 event revision、時間與 command generation。
5. 更新日跨過 04:00，使用者又標記目前服已完成；Task 8 放行前對帳現有日循環並重新選服，Task 10 網頁顯示實際目標與 ACK。

## File Structure

| 檔案 | 責任 |
| --- | --- |
| `payload/GameMaintenanceNotice.ps1`（新） | 官網來源限制、本文／日期解析、事件選取、公告快取 |
| `payload/GameInstallDiscovery.ps1`（新） | 捷徑／URI、Valve KeyValues、已安裝路徑證據、自動 provider |
| `payload/GameMaintenanceWorker.ps1`（新） | 單一背景 helper、請求／觀察 snapshot、Steam 狀態增量讀取 |
| `payload/GameMaintenancePolicy.ahk`（新） | 純時間／狀態轉移，不含 Run／鍵鼠／HTTP |
| `payload/GameMaintenance.ahk`（新） | journal、worker 所有權、遠端意圖守門、主流程協調及 public JSON |
| `payload/GameUpdateAdapters.ahk`（新） | Steam／Kuro 被驗證後的啟動與 UI 動作 |
| `payload/GameUpdateOcrPolicy.ahk`（新） | launcher 按鈕／階段、遊戲維護文字的純 OCR 判定 |
| `payload/全自動.ahk`（改） | 插入閘門、更新後登入、錄影時機、遠端 hook／排程與本機設定 UI |
| `payload/RuntimeFilePaths.ahk`（改） | 新持久維護資料夾 helper |
| `payload/RemoteControlFirestore.ahk`、`payload/RemoteControlSelfHost.ahk`（改） | 小型狀態欄位、設定 revision 往返 |
| `self-hosted-server/src/game-maintenance.js`（新） | 對外狀態／新設定的白名單與限制 |
| `self-hosted-server/src/app.js`、`settings.js`、`firestore-bridge.js`（改） | JSONB 心跳與既有雙來源設定／命令橋 |
| `self-hosted-server/public/game-maintenance-view.js`（新） | 維護卡片純 view model 與 DOM renderer |
| `remote-control-web/game-maintenance-view.js`（新） | 同一來源的發布副本，驗證兩檔 SHA256 相同 |
| 兩網站 `app.js`、`index.html`、`styles.css`（改） | 卡片入口、設定欄位、行動版排版 |
| `測試/Invoke-GameMaintenanceTests.ps1`（新） | 專案內測試總入口、逾時／退出碼與結果 |
| `測試/GameMaintenanceTestHelpers.ps1`、`測試/GameMaintenanceFixtures.ahk`（新） | 純 fixture／assert、假時鐘／假副作用，不碰遊戲 |
| `測試/GameMaintenance*Test.*`、`測試/GameInstallDiscoveryTest.ps1`、`測試/GameUpdateAdaptersTest.ahk`、`測試/GameUpdateOcrPolicyTest.ahk`（新） | 各責任的行為測試 |
| `self-hosted-server/test/game-maintenance*.test.js`（新） | API 協定、設定來回、兩網站呈現 |
| `打包更新.ps1`、`self-hosted-server/package.json`（改） | 新測試／靜態檢查、資產同步與套件完整性 |
| `PROJECT_AI_HANDOFF.md`、`self-hosted-server/README.md`、`remote-control-web/README.md`（改） | 完成功能後更新使用與維運說明 |

不重新整理整個 1 萬多行主腳本；新增模組只接必要函式。正式 `config`、nonce journal、其他功能設定不整份覆寫。

## 共用介面與資料契約

PowerShell 所有輸出為單一 PSCustomObject（列表使用陣列）；記錄使用 verbose／獨立 Log，不把額外字串混進函式回傳。

```powershell
# Task 2: GameMaintenanceNotice.ps1
ConvertFrom-GMNotice -Article <object> -SourceUrl <uri> -FetchedAt <DateTimeOffset>
# -> { valid, reason, notice }; notice 與 Spec 4.2 相同
Select-GMNotice -Notices <object[]> -Now <DateTimeOffset> -Previous <object|null>
# -> { notice, sourceState, requiresReview }; 不直接放行 AHK
Get-GMOfficialNotice -CacheDirectory <string> -Now <DateTimeOffset> -Force <bool>
# -> { outcome, notice, checkedAt, errorCode }; outcome=ok|unavailable|invalid

# Task 3: GameInstallDiscovery.ps1
ConvertFrom-GMValveKeyValues -Text <string>                 # -> hashtable
Get-GMInstallInventory -LaunchEntry <string>               # -> 已讀取並過濾的安裝證據
Resolve-GMInstallEvidence -LaunchEntry <object> -Inventory <object>
# -> { provider, appId, gameRoot, launcherPath, launchEntry,
#      evidence, fingerprint, checkedAtUtc, updateAdapterReady }

# Task 4: GameMaintenanceWorker.ps1（函式可 dot-source，不自動開始 worker）
Get-GMSteamObservation -Install <object> -Previous <object|null> -Now <DateTimeOffset>
# -> { provider, phase, evidenceKind, progressPercent, progressStage,
#      lastProgressAtUtc, observedAtUtc, gamePid, errorCode, detail }
Write-GMSnapshot -Path <string> -RequestId <string> -Sequence <long> -Value <object>
# -> void；原子 INI；UTF-8 編碼、固定欄位、文字移除 CR/LF/section 注入
```

AHK 在 INI 讀出 UTC epoch 毫秒與 observation，再建立普通物件給純策略。所有缺值進入 `unknown`，不得預設為完成。

```autohotkey
; Task 5: Policy
GM_Evaluate(state, input) ; -> { phase, overlay, errorCode, effect }
; effect = { type: "none|check_notice|check_install|start_update|observe|resume_flow|stop",
;            actionId, expectedRevision, expectedRemoteGeneration }
; input = { nowUtcMs, elapsedMs, clockStable, desiredState, remoteGeneration,
;           desktopAvailable, noticeState, notice, install, observation }
; notice = { eventId, revision, startsAt, expectedOpenAt, freshForRelease }
; state = { phase, eventId, revision, actionId, actionStage,
;           f11InputAttempted, cancelled, runCycle, targetServer }

; Task 5/8: controller
GM_HasActiveContinuation(cfgPath)            ; -> bool，讀持久 state 與取消標記
GM_Init(cfgPath, launchEntry, flowContext)    ; -> controller object
GM_IsGateActive()                           ; -> bool
GM_WaitForStartupGate()                     ; -> { mode: "normal|managed_update|stop", detail }
GM_RunManagedUpdate()                       ; -> { ok, readyForLogin, errorCode, detail }
GM_HandleRemoteIntent(state, command)        ; -> { handled, code, detail }
GM_ObserveGameStage(stage, observation)      ; -> { disposition: "continue|wait|stop", detail }
GM_BuildPublicJson()                        ; -> JSON string <= 4096 UTF-8 bytes
GM_Shutdown(reason)                         ; -> void，只管理自己的 helper／journal

; Task 6/7: adapters
GMU_Start(install, action, hooks)            ; -> { ok, attemptId, errorCode, detail }
GMU_Observe(install, workerObservation, ocr) ; -> observation
GMU_ApplyAction(target, action, hooks)       ; -> { ok, errorCode, detail }
GMU_ClassifyLauncher(blocks, identity)       ; -> { kind, button, percent, evidence }
GMU_ClassifyMaintenance(blocks, identity)    ; -> { confirmed, evidence, identityKey }
```

所有 `hooks` 明確提供 `CanAct`、`PersistIntent`、`LaunchSteam`、`LaunchKuro`、`ClickVerified`、`ReadObservation`；測試使用 spy，正式控制器重驗 remote generation、時間、來源、PID／HWND。OCR 判定函式不直接點擊。

對外 epoch 單位統一毫秒，內部 DateTimeOffset 轉換只在 PowerShell snapshot writer。狀態 JSON 不使用與命令 parser 衝突的頂層 `nonce/desiredState`。

## Task 1: 建立受控測試入口與當前基準

**Files:** Create `測試/Invoke-GameMaintenanceTests.ps1`、`測試/GameMaintenanceTestHelpers.ps1`、`測試/GameMaintenanceFixtures.ahk`。

**Interfaces:** 沿用 `ProjectDevelopmentPaths.ps1` 與 `測試/TestRuntimePaths.ahk`；產出 `Assert-GMEqual`、`GMTest_Assert`、`GMTest_State`、`GMTest_Input`，後續測試均使用它們。

- [ ] 讀本規格、`PROJECT_AI_HANDOFF.md`、`DEVELOPMENT_ARTIFACTS.md`；檢查 `git status --short`，記錄 HEAD 與 dirty 檔案，禁止一開始打包。
- [ ] 寫測試 helper；Windows PowerShell 含中文的新增檔採 UTF-8 BOM，需經 5.1 parser 驗證。AHK 測試失敗回傳 exit 1 並輸出標準錯誤，不開 MsgBox。

```powershell
function Assert-GMEqual($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message : expected=$Expected actual=$Actual" }
}
```

```autohotkey
GMTest_Assert(value, message) {
    if !value
        throw Error(message)
}
GMTest_State() {
    return {phase:"WAIT_OPEN", eventId:"fixture-global-1", revision:"r1",
        actionId:"", actionStage:"", f11InputAttempted:false,
        cancelled:false, runCycle:"fixture", targetServer:"Asia"}
}
GMTest_Input(nowMs := 9999) {
    return {nowUtcMs:nowMs, elapsedMs:0, clockStable:true, desiredState:"RUN",
        remoteGeneration:1, desktopAvailable:true, noticeState:"valid",
        notice:{eventId:"fixture-global-1", revision:"r1", startsAt:1000,
            expectedOpenAt:10000, freshForRelease:true},
        install:{provider:"steam", updateAdapterReady:true, fingerprint:"i1"},
        observation:{phase:"not_started", observedAt:nowMs}}
}
```

- [ ] 總入口 `-Suite` 支援 `Notice,Install,Worker,Policy,Adapters,Ocr,Startup,Transport,All`，每個映射到下列任務的確切測試；禁止吃掉子程序非零退出碼。`-Suite All` 在尚缺任一檔案時明確失敗。
- [ ] 總入口使用 `Initialize-ProjectDevelopmentPaths`／`finally Complete-ProjectDevelopmentPaths`；AHK 子程序用 `/ErrorStdOut`、`Start-Process -WindowStyle Hidden -PassThru` 與 60 秒上限；只終止這個測試 PID 並重驗建立時間，輸出到該 `RunRoot`。
- [ ] 用一個失敗 fixture 確認 exit 1、成功 fixture 確認 exit 0，並確認 `.dev-runtime` 以外沒有輸出。這是 runner 驗收，不算任何 updater 實測。

**Verification:** `powershell.exe -NoProfile -File .\測試\PowerShellDevelopmentPathPolicyTest.ps1`。本階段完成後可單獨審查與提交新測試基礎檔；不 stage 使用者檔案。

## Task 2: 官方公告、時間與快取

**Files:** Create `payload/GameMaintenanceNotice.ps1`、`測試/GameMaintenanceNoticeTest.ps1`。

**Interfaces:** 實作共用介面的 `ConvertFrom-GMNotice`、`Select-GMNotice`、`Get-GMOfficialNotice`；輸入時間可注入，HTTP getter 可於測試用 scriptblock 取代。

- [ ] 先寫合成公告測試：不要把官方整篇文章收入 Git；必要歷史片段引用只留最短時間行與 source URL。測試資料在測試執行時寫到 `.dev-runtime`。

```powershell
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
. (Join-Path $PSScriptRoot '..\payload\GameMaintenanceNotice.ps1')
$article = [pscustomobject]@{
    articleId = 1
    articleTitle = '《鳴潮》9.9版本更新維護預告（測試資料）'
    startTime = '2026-08-13 11:00:01'
    articleContent = '<p>維護期間無法登入遊戲。</p><p>更新維護時間：2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+8）</p>'
}
$result = ConvertFrom-GMNotice -Article $article `
    -SourceUrl 'https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1' `
    -FetchedAt ([DateTimeOffset]'2026-08-20T02:00:00Z')
Assert-GMEqual $result.valid $true '有效公告'
Assert-GMEqual $result.notice.startsAtUtc '2026-08-19T20:00:00Z' '維護開始'
Assert-GMEqual $result.notice.expectedOpenAtUtc '2026-08-20T03:00:00Z' '採本文而非發布時間'
$article.articleContent = $article.articleContent.Replace('（UTC+8）', '')
Assert-GMEqual (ConvertFrom-GMNotice -Article $article `
    -SourceUrl 'https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1' `
    -FetchedAt ([DateTimeOffset]'2026-08-20T02:00:00Z')).valid $false '缺時區拒絕'
```

- [ ] 執行 `powershell.exe -NoProfile -File .\測試\Invoke-GameMaintenanceTests.ps1 -Suite Notice`，先確認因尚無實作失敗。
- [ ] 解析 JSON 明細，HTML entity decode 與文字提取後用限定日期 regex、`DateTimeOffset.TryParseExact` 及數值 UTC offset 轉換；完整年月日不足時不猜年份。版本維護／區服檢查通過才產生事件。
- [ ] 加入非維護、預下載、壞 JSON、重複 article、國服／global 不匹配、不同 UTC offset、跨日、提前公告、晚啟動、已結束舊公告、48 小時上限測試。
- [ ] 實作白名單 URL／redirect／2 MiB 限制與 20 秒總預算；只抓最多 12 個近期必要 candidate。`Get-GMOfficialNotice` 內不允許 `Invoke-Expression`、外部 shell 或從文章產生路徑。
- [ ] 實作 3 事件／256 KiB cache，依 Spec 4.2 的 6 小時／15 分鐘／5 分鐘規則；原子替換前 reload 驗證。加入 HTTP 500、timeout、格式變動、截斷、舊新延長衝突、完全無快取以及已知事件到時間仍斷線測試。
- [ ] 重跑 Notice suite，記錄通過數；只有資料來源冒煙測試可使用真實官方 HTTPS，不能把公開來源暫時不可用當 unit test 的隨機失敗。

**Deliverable:** 正式公告與降級結果可重現，沒有遊戲／Windows 副作用。

## Task 3: 安裝來源自動判定

**Files:** Create `payload/GameInstallDiscovery.ps1`、`測試/GameInstallDiscoveryTest.ps1`。

**Interfaces:** `Get-GMInstallInventory` 只提供公開安裝證據；`Resolve-GMInstallEvidence` 是純函式，輸入假 inventory 即可測多來源。`LaunchEntry` 包含 `kind,target,arguments,workingDirectory,realPath`，Inventory 包含 `steamLibraries,steamInstalls,kuroInstalls`。

- [ ] 先寫 Steam 明確入口、直接 EXE 路徑、兩套安裝衝突與錯 App ID 測試。

```powershell
$entry = [pscustomobject]@{ kind='steam-uri'; target='steam://run/3513350';
    arguments=''; workingDirectory=''; realPath='' }
$inventory = [pscustomobject]@{
    steamLibraries=@('D:\SteamLibrary')
    steamInstalls=@([pscustomobject]@{ appId=3513350; installed=$true;
        root='D:\SteamLibrary\steamapps\common\Wuthering Waves';
        realRoot='D:\SteamLibrary\steamapps\common\Wuthering Waves';
        launcherPath='C:\Program Files (x86)\Steam\steam.exe'; identityVerified=$true })
    kuroInstalls=@()
}
$resolved = Resolve-GMInstallEvidence -LaunchEntry $entry -Inventory $inventory
Assert-GMEqual $resolved.provider 'steam' 'URI 與有效安裝相符'
$entry.target='steam://run/999999'
Assert-GMEqual (Resolve-GMInstallEvidence -LaunchEntry $entry -Inventory $inventory).provider 'unknown' '錯 App ID'
```

- [ ] 先跑 Install suite 看失敗；實作 Valve KeyValues tokenizer（quoted string／escape／brace，拒絕不完整結構），不要用一條 regex 解析完整嵌套 VDF。
- [ ] 讀 `.lnk`、`.url`、精確 URI，限制鏈長 4、拒絕循環／shell 包裝；查有限 Steam 安裝紀錄、libraryfolders 與 ACF，canonicalize 真實路徑。
- [ ] Kuro 使用實際安裝唯讀樣本建立「launcher 與 gameRoot 的關係」規則。尚無該機器證據時回 `updateAdapterReady=false`，不猜 `launcher.exe` 名稱。實際機器 probe 只讀白名單路徑、公開安裝紀錄與相符子目錄，不讀帳戶檔。
- [ ] 加測非 C 槽、空 library、移除中的安裝、大小寫、空白中文、`..`、junction 到不同根、可讀性不足、半寫 ACF、不同來源共用 exe 名稱、官方版明確入口但 Steam 也存在。
- [ ] 驗證 cache fingerprint 涵蓋入口＋捷徑目標＋library＋manifest＋規則版本，命中快取仍確認檔案存在；所有異常回傳 evidence 不直接啟動。
- [ ] 跑 Install suite 與開發路徑政策，保存可讀的 provider evidence 測試結果。

**Deliverable:** 證據充分才自動選 updater；使用者不需選 provider。

## Task 4: 背景觀察、原子 snapshot 與 helper 生命週期

**Files:** Create `payload/GameMaintenanceWorker.ps1`、`測試/GameMaintenanceWorkerTest.ps1`；Modify `payload/RuntimeFilePaths.ahk`；Create `測試/GameMaintenanceWorkerTest.ahk`。

**Interfaces:** worker CLI 為 `-RequestPath -OutputPath -StopPath -StateDirectory -ParentPid -ParentStartUtc`；`RuntimeFiles_GameMaintenanceDir()` 返回 `<config>/game-maintenance`。Request JSON含 `schemaVersion=1,requestId,generation,launchEntry,mode,createdAtUtc`；mode 只支援 `notice/install/observe`。Snapshot INI 固定 `[meta] [notice] [install] [observation]`，meta 含 requestId／sequence／observedAtUtcMs。

- [ ] 先測原子讀寫、舊 request ID、倒退 sequence、超過 60 秒 snapshot、超出 root、內容包含換行與 INI section 注入；期望拒絕而非默認為成功。
- [ ] 確認 Worker suite 失敗後實作單一 loop，Steam 觀察 5 秒一次、公告 5 分鐘一次；所有 HTTP 限時，主程式不等 HTTP。
- [ ] worker 只有內容有變或每 30 秒存活標記才原子寫 snapshot，不能每秒写 config；公告快取與 AHK journal 各單一寫入者。
- [ ] 設定 marker `WUTHERING_GAME_MAINTENANCE_WORKER_V1`，比對 parent PID＋建立時間，每個 session 最多一個 worker；停止檔／父死後退出，異常最多重建一次。
- [ ] AHK 路徑測試建立的所有檔案使用 `TestRuntime_NewCaseDir()`；helper mock 的存活／退出皆用 repo 內腳本，不啟動 Steam。
- [ ] 採樣針對目標 App ID 的 ACF／有限 Log 尾端，使用前次 cursor、處理 Log rotation，避免每 5 秒讀整個 Steam Log 或枚舉全系統 CIM。

```powershell
# GameMaintenanceWorkerTest.ps1: 其他 App 的進展不得更新鳴潮進度。
$previous = [pscustomobject]@{ lastProgressAtUtc='2026-08-20T03:00:00Z'; cursor=0 }
$install = [pscustomobject]@{ provider='steam'; appId=3513350;
    manifestPath=$fixtureManifest; contentLogPath=$fixtureContentLog }
$obs = Get-GMSteamObservation -Install $install -Previous $previous `
    -Now ([DateTimeOffset]'2026-08-20T03:10:00Z')
Assert-GMEqual $obs.progressPercent $null '未知百分比保留 null'
Assert-GMEqual $obs.lastProgressAtUtc $previous.lastProgressAtUtc '不吃其他 App 活動'
```

上述 `$fixtureManifest/$fixtureContentLog` 在本測試建立於 runner 的 `TestsRoot`，使用空進度／另一 App ID 的合成內容，不讀真 Steam。

**Verification:** Worker suite、既有 `測試/RuntimeFilePaths測試.ahk` 與 `測試/AhkGeneratedPathPolicyTest.ahk`。

## Task 5: 純狀態策略與跨重啟接續

**Files:** Create `payload/GameMaintenancePolicy.ahk`、`payload/GameMaintenance.ahk`、`測試/GameMaintenancePolicyTest.ahk`、`測試/GameMaintenancePersistenceTest.ahk`。

**Interfaces:** 實作 `GM_Evaluate` 與 controller 共用函式。journal 位於 `RuntimeFiles_GameMaintenanceDir()`；pure policy 不呼叫 Windows、HTTP 或 AHK global 狀態。

- [ ] 寫開服前後、PAUSE、鎖定、STOP、時鐘突跳及失效公告測試；所有測試採 action spy 驗證副作用為零，不只檢查來源文字。

```autohotkey
state := GMTest_State()
input := GMTest_Input(9999)
decision := GM_Evaluate(state, input)
GMTest_Assert(decision.phase = "WAIT_OPEN", "開服前 1ms 必須等待")
GMTest_Assert(decision.effect.type = "none", "不可提早觸發更新")
input.nowUtcMs := 10000
input.desiredState := "PAUSE"
decision := GM_Evaluate(state, input)
GMTest_Assert(decision.overlay = "PAUSE" && decision.effect.type = "none", "到時仍需尊重 PAUSE")
input.desiredState := "STOP"
GMTest_Assert(GM_Evaluate(state, input).effect.type = "stop", "STOP 不受等待時間限制")
```

- [ ] Policy suite 先失敗後實作 Spec 6 狀態表。正常開服邊界先 `check_notice`，freshForRelease=true 且 identityReady 才產生 `start_update`；`READY` 必須來自 `observation.phase=game_ready`。
- [ ] journal 的 `{actionId,actionStage=intent|observed|cancelled}` 在動作前原子寫，I/O失敗便不做動作。重啟恢復先 observe，不直接重送 `start_update`。加 write failure、temp 殘留、截斷 state、合法上一版、重複啟動和取消後重開測試。
- [ ] `GM_HasActiveContinuation` 在現有 fresh-cycle 重設 PAUSE 之前執行。維護 active journal＋persisted PAUSE 維持暫停，完成／STOP／已失效 event 不永遠攔住新任務。
- [ ] controller 每次 commit effect 都重驗 `expectedRevision/expectedRemoteGeneration`，持久與實際狀態不一致則重新評估；不可只在迴圈入口驗一次。
- [ ] 加入 04:00 跨日訊號、無 active event 網路降級、有 active event 斷網繼續 wait、延長公告、來源 unknown、30 分鐘無進展、每 5 分鐘 WAIT_SERVER 觀察與不重送 F11 測試。
- [ ] Policy suite、Persistence suite（由 Policy suite一併執行）通過後記錄各斷點的恢復結果。

**Deliverable:** 在完全不啟動遊戲的測試中證明核心排程不提前、不重啟循環、不丟命令意圖。

## Task 6: Steam adapter 與更新完成證據

**Files:** Create `payload/GameUpdateAdapters.ahk`、`測試/GameUpdateAdaptersTest.ahk`；Modify `payload/GameMaintenanceWorker.ps1`。

**Interfaces:** `GMU_Start/Observe/ApplyAction` 用 hooks 注入副作用；Steam 正式 hook 只能使用已驗證路徑＋固定 `3513350`。Steam `update_ready` 僅可進入 `CHECKING_LOGIN`，不會回 `game_ready`。

- [ ] 先測錯 provider、缺 launcher identity、錯 App ID、過期 fingerprint、過期 remote generation、已存在正確遊戲、已持久 intent 的重啟接管。

```autohotkey
calls := []
hooks := {CanAct: (*) => false,
    PersistIntent: (*) => true,
    LaunchSteam: (args*) => calls.Push(args),
    LaunchKuro: (*) => 0, ClickVerified: (*) => false,
    ReadObservation: (*) => {phase:"unknown"}}
install := {provider:"steam", appId:3513350, updateAdapterReady:true,
    launcherPath:"C:\fixture\steam.exe", fingerprint:"i1"}
action := {type:"start_update", actionId:"e1-start", expectedRevision:"r1",
    expectedRemoteGeneration:1}
result := GMU_Start(install, action, hooks)
GMTest_Assert(!result.ok && calls.Length = 0, "守門不通過時不可啟動")
```

- [ ] 跑 Adapters suite 確認失敗；實作單次發起＋observe 的流程。Steam 命令候選來自已解析入口或固定 `-applaunch 3513350`；先以 fake launcher 驗證引用與參數，真正是否會先更新再啟動留到 Task 11 實機驗收。
- [ ] ACF／Log 內部碼只在讀取樣本對照後定義；不能因 manifest 標記 installed 或 bytes=0 就設 ready。已確認同根遊戲進程啟動、Steam 目標狀態及後續 client 驗證組合使用。
- [ ] 加入 180 秒無觀察、queued、paused download、login required、offline、磁碟錯誤、網路無進展、安裝／驗證仍活動與百分比重設（不同階段）測試。
- [ ] Steam 已自行下載時只 observe；PAUSE/STOP 不殺 Steam，不假稱下載已被暫停；client automation 不再發後續 launch。驗證其他 Steam App 活動及其他 Steam 遊戲存活不被更動。
- [ ] Adapters suite 與 Worker suite 通過；完成 `Steam adapter ready` 的最低證據 gate 前，公開能力標記只說偵測到 Steam，不說已實測更新。

## Task 7: 官方 updater OCR 與遊戲維護判斷

**Files:** Create `payload/GameUpdateOcrPolicy.ahk`、`測試/GameUpdateOcrPolicyTest.ahk`；Modify `payload/GameUpdateAdapters.ahk`、`測試/GameUpdateAdaptersTest.ahk`。

**Interfaces:** `blocks=[{text,left,top,right,bottom}]`；`identity={key,provider,clientWidth,clientHeight,verified}`。`GMU_ClassifyMaintenance` 的單次命中為候選；controller 需同 key 連續兩次才 confirmed。

- [ ] 寫純 OCR negatives：公告內「更新」、別的列的「開始」、空結果、不同語系、擷取失敗、錯 PID、一般「無法連接伺服器」。

```autohotkey
identity := {key:"game-p1-h1", provider:"kuro", clientWidth:1280,
    clientHeight:720, verified:true}
network := [{text:"無法連接伺服器，請檢查網路", left:400,top:300,right:900,bottom:350}]
GMTest_Assert(!GMU_ClassifyMaintenance(network, identity).confirmed,
    "一般網路失敗不等同維護")
maintenance := [{text:"伺服器維護中，暫時無法登入", left:400,top:300,right:900,bottom:350}]
GMTest_Assert(GMU_ClassifyMaintenance(maintenance, identity).confirmed,
    "明確維護語意成為候選；控制器另驗兩次穩定命中")
```

- [ ] 跑 Ocr suite 看失敗；實作白名單詞組＋版面／身分條件，不模糊命中任意「更新」「錯誤」「連線」。OEM／新語系未驗證回 unknown。
- [ ] 官方 launcher adapter 對 update/download/install/verify/play 各有 observation。實際按鈕 ROI 與視窗身分根據 Task 11 所獲畫面／唯讀資料建立，未驗證不加入可用 adapter；不得拿 OKWW 視窗當官方 launcher。
- [ ] 操作前沿用現有互動桌面與前景身分驗證邏輯；為 launcher 提供 target-exe-specific wrapper，不為了可重用而放寬遊戲／OKWW 原有安全條件。
- [ ] 測維護在 F11 前／後出現、同一 HWND 換 PID、遊戲彈窗重建、同一提示持續数小時、提示消失後主畫面已可用，以及需要登入但 OKWW狀態未知回 `LOGIN_RESUME_UNCONFIRMED`。
- [ ] Ocr suite 與 Adapters suite通過；記錄未取得真實 launcher 畫面的來源不能宣稱已完成官方 updater 實測。

## Task 8: 接上主流程、遠端控制與錄影生命週期

**Files:** Modify `payload/全自動.ahk` 的啟動段、`OnRemoteControlStateChanged`、`RemotePauseHookTick`、`RemoteRunResumeHookTick`、`PrepareRemoteServerSwitch`、`CompleteServerForTodayFromRemote`、`DetectWutheringAndExit`、`WaitGameReadyAfterOkwwF11`、`RestoreWutheringAudioOnExit`；Create `測試/GameMaintenanceStartupTest.ahk`。

**Interfaces:** 此任務是唯一把 Task 5 決策接到現有流程的地方；使用現有函式名稱，不引入第二套 RC nonce／伺服器排程。

- [ ] 寫 startup harness 注入假流程 steps，斷言 before-open 的 action 序列沒有 `cleanup/start_recording/start_game/start_okww/send_f11`，命令與 heartbeat spy仍持續。
- [ ] 將啟動段整理成以下次序；`GM_HasActiveContinuation` 必須插入 RC fresh-run 判斷，不能等清場後才檢查。

```autohotkey
; 設定初始化後、RC_BeginFreshRunCycle 判斷之前：
maintenanceContinuation := GM_HasActiveContinuation(CFG_FILE)
; 將此值納入既有 remoteContinuationLaunch，不改一般新任務的既有語意。

; 排程與遠端命令處理已就緒，清場／錄影／遊戲尚未開始：
GM_Init(CFG_FILE, IniReadSafe(CFG_FILE, "paths", "WUTHERING", ""),
    {isRestart:isRestart, isNextServerCycle:isNextServerCycle,
     resumeLrmc:CRASH_RESTART_MODE, targetServer:CURRENT_SERVER_TARGET})
gate := GM_WaitForStartupGate()
if (gate.mode = "stop")
    ExitApp
; 接續原清場與 watcher，版本日走 GM_RunManagedUpdate，平日走原 EnsureWutheringRunning。
```

- [ ] RC callbacks 的閘門分支先處理意圖；只有 `handled=false` 才進入原 hook。維護 WAIT 切服只原子保存與 ACK `SWITCH_SCHEDULED`，不呼叫 `RemoteServerSwitchCommitTick`。詳細 ACK寫明「等待開服，尚未完成切服」。
- [ ] `COMPLETE_SERVER` 全部完成時仍能乾淨退出；等待中完成目前服會重選。恢復前調用既有循環日／完成狀態函式，不依靠過期記憶體 Map。
- [ ] 在登入備援模板、退出／確認按鈕之前加入 maintenance observation；F11 後主畫面等待接受 `maintenance` 結果，停止一般重啟與中心點擊。保持 F11 已嘗試標記跨等待，不反覆注入。
- [ ] 版本日錄影移到 `game_ready`、聲骸前；若 restart 已接管錄影，進長等待前正常封口。一般日錄影、restart resume、鎖屏、直播 marker 行為維持既有測試期望。
- [ ] 加入 STOP／延長公告在 commit 前到達、PAUSE後普通參數重開、source格式變動、更新中 worker死、在 HMT 等待卻收到 Asia、跨04:00與全部完成測試。
- [ ] Startup suite 通過後跑既有 `InteractiveDesktopGuardTest.ahk`、`GameReadyLoadingGracePolicyTest.ahk`、`伺服器名稱與切服判斷測試.ahk`、`ScreenRecordingDirectOutputPolicyTest.ahk`；不啟動實機壓力切服測試。

**Deliverable:** 主流程真的由閘門控制，且遙控不會在等待時偷偷走原 UI hook。

## Task 9: 雙網站傳輸、設定 revision 與通知

**Files:** Create `self-hosted-server/src/game-maintenance.js`、`self-hosted-server/test/game-maintenance.test.js`、`self-hosted-server/test/game-maintenance-settings.test.js`；Modify `payload/RemoteControlFirestore.ahk`、`payload/RemoteControlSelfHost.ahk`、`payload/GameMaintenance.ahk`、`payload/全自動.ahk`、`self-hosted-server/src/app.js`、`settings.js`、`firestore-bridge.js`。

**Interfaces:** `normalizeGameMaintenance(value,nowMs)` 回傳 Spec 9 狀態或 null；`normalizeMaintenanceSettings(value)` 回傳已驗證的 maintenance 設定子集合。設定相容策略：舊欄位維持 schema v1，新能力由 `capabilityVersion=1` 宣告；未知新欄位的舊 client 不提供新操作。不可盲目將全域 schema 升版導致既有設定失效。

- [ ] 寫 parser與設定往返測試：錯型別、空值、超長detail／4KiB上限、null百分比、錯sourceURL、未知phase、future timestamp、不支援 capability、過期event override、只延後當前event。

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import { normalizeGameMaintenance } from "../src/game-maintenance.js";

test("unknown update progress stays null", () => {
  const value = normalizeGameMaintenance({schemaVersion:1, capabilityVersion:1,
    phase:"UPDATING", provider:"steam", progressPercent:null,
    observedAt:1770000000000}, 1770000001000);
  assert.equal(value.progressPercent, null);
  assert.equal(value.phase, "UPDATING");
});
```

- [ ] `GM_BuildPublicJson` 與兩端 heartbeat 串接；自架 `status.gameMaintenance` 使用白名單 normalization，Firestore field為`gameMaintenanceJson`並加updateMask，Bridge把兩者保持同一語意。
- [ ] 新設定欄位完整加入 normalize／desired／effective／AHK校驗／原子apply／ACK管線；舊表單未帶新欄位要保留既有maintenance值，不能設回預設。將「enabled」與人工略過切到不同意圖，保存draft時不得意外改timing。
- [ ] 人工延後／略過要檢查`eventId`及能力；只解除時間閘門，不跳過PAUSE/locked/provider/maintenance畫面。refresh requestId在60秒內合併，不另外建Firestore命令。
- [ ] 使用假transport比較新增功能前後 request count 相同；傳輸maintenance狀態時也不能重讀官方來源。公開detail與sourceURL採有界純文字，拒絕javascript/data URL。
- [ ] 通知沿用既有郵件開關及寄信函式；persist event＋stage＋revision去重key。測試用mail spy，測試不寄真正郵件；只有 game_ready後能發「可開始鋤地」，不把SWITCH_SCHEDULED說成切服完成。
- [ ] 執行 Transport suite與 `node self-hosted-server/test/run-tests.mjs`；測試 fake DB／transport和現有一體測試，不改正式兩台裝置設定。

## Task 10: 兩套網站與本機設定 UI

**Files:** Create `self-hosted-server/public/game-maintenance-view.js`、`remote-control-web/game-maintenance-view.js`、`self-hosted-server/test/game-maintenance-ui.test.js`；Modify 兩網站 app/index/styles、`payload/全自動.ahk` 的`ReadCombinedConfigState/ShowCombinedConfigSetupGui/OnCombinedSetupSave/GetPathWithAsk`及`.url`支援、`打包更新.ps1`資產同步。

**Interfaces:** `maintenanceViewModel(value,nowMs,deviceFresh)` 為純函式；`renderMaintenanceCard(root,model)` 使用textContent與可驗證URL。自架app與公司app只負責把來源不同的狀態交給相同view model。

- [ ] 寫資料fixture測WAIT_OPEN、WAIT_NOTICE、Steam/Kuro更新、未知%、離線、舊client與設定已送出／ACK／拒絕，不以文字匹配代替所有行為。

```javascript
import test from "node:test";
import assert from "node:assert/strict";
import { maintenanceViewModel } from "../public/game-maintenance-view.js";

test("updating is not reported as farming or 0 percent", () => {
  const model = maintenanceViewModel({schemaVersion:1,capabilityVersion:1,
    phase:"UPDATING",provider:"steam",progressPercent:null,
    expectedOpenAt:1770000000000,observedAt:1770000001000},1770000002000,true);
  assert.equal(model.progressText,"進度未知");
  assert.equal(model.canClaimReady,false);
});
```

- [ ] 在兩套總覽既有流程控制附近加入維護卡；只在有能力／活動事件時顯示，日常不擠掉效能卡。detail與安裝路徑摺疊，sourceUrl明確標官方公告。
- [ ] 倒數僅瀏覽器timer更新文字，用最近observedUtcNow與elapsed校正，document hidden時降低頻率；逾時顯示資料過期，不觸發網路寫入。
- [ ] 設定頁新操作沿用revision ACK，操作返回HTTP成功顯示「已送出」，待裝置revision與結果吻合才「已套用」；失敗保留draft可重試。
- [ ] 本機鳴潮入口接受`.exe/.lnk/.url`和精確Steam URI，不能通用FileExist拒絕URI；介面顯示唯讀「Steam（自動判定）」或問題原因與重新偵測。新的重新偵測是只讀探測，非啟動測試。
- [ ] 打包時以自架public為view模組來源複製到公司web，兩者SHA256必須相同；兩套app加入module import，新增檔納入web版本hash與node --check。無必要不抽改其他UI模組。
- [ ] 行為測試後，以假資料瀏覽本機測試頁，驗證390×844、1920×1080、瀏覽器125%/150%與長繁中文字；所有截圖在`.dev-runtime/diagnostics/game-maintenance`。AHK設定UI也用測試config／假path，不觸發正式鋤地。

**Verification:** `npm --prefix self-hosted-server run check`、`npm --prefix self-hosted-server test`、兩網站SHA與新增DOM手動驗證。若UI工具缺失，記錄UI驗收未完成，不能說已手機實測。

## Task 11: 回歸、受控實機驗收與發布交付

**Files:** Modify `打包更新.ps1`、`self-hosted-server/package.json`、`PROJECT_AI_HANDOFF.md`、兩端README；驗收報告位於`.dev-runtime/diagnostics/game-maintenance`。

**Interfaces:** 套件必須含新增payload worker/modules與網站view檔；不得把規格、測試、fixtures、`.dev-runtime`、帳戶資料包入客戶端。

- [ ] 將新AHK validate/test與PowerShell parser及suites加到打包前，新增JS放入check；公開資產checksum涵蓋新module。保留已存在的路徑／ZIP excludes測試。
- [ ] Run以下非發布命令，必須檢查退出碼與新錯誤，不只看「完成」文字：

```powershell
powershell.exe -NoProfile -File .\測試\Invoke-GameMaintenanceTests.ps1 -Suite All
powershell.exe -NoProfile -File .\測試\PowerShellDevelopmentPathPolicyTest.ps1
npm --prefix self-hosted-server run check
npm --prefix self-hosted-server test
git diff --check
```

- [ ] AHK `/Validate`與compile使用現有打包函式或抽出的純驗證入口，輸出到`.dev-runtime/build`。正式config與執行中的payload不覆寫。測試名稱、數量、退出碼與未測的gate寫入結果。
- [ ] 實機先唯讀確認實際兩台來源：入口鏈、安裝manifest、launcher關係、Steam更新觀察可讀性。只讀模式不得開遊戲、按更新或改設定；UI所需畫面在後續已授權工作階段取得。
- [ ] 獲准的實機工作階段，在新程式及repo內測試設定注入「開服在2分鐘後」的合成公告（以顯眼TEST標記隔離，正式程式不可從網頁任意指定fixture）。確認等待期間零更新動作、控制可用、到時間才發起、停止測試後清理自己helper。
- [ ] 每個實際provider檢查到達時間的啟動／更新／遊戲身分／主畫面鏈。真正待更新包不存在時只記「已是最新版／啟動成功」；日後遇到真實更新才補「下載＋安裝＋驗證」證據，不能重下載或修改build偽造更新。
- [ ] 遇到登入驗證／UAC／權限拒絕時保留明確原因；沒有允許的工具能力就列未完成。不能以更改Windows／服務、或繞過第三方安全流程讓驗收通過。
- [ ] 更新handoff/README，列固定等待規則、Steam自主更新限制、來源unknown處理、設定ACK、可觀測欄位，以及兩個provider各自實測狀態。
- [ ] 若之後使用者要求「打包更新」，先重新確認當前版本與dirty tree，再按既有完整發布工作流同步Launcher/Payload/server；同時驗證客戶端可下載新fixed-commit manifest與hash、兩網站檔案已發布。未收到本次發布指示前不執行這一步。

**最終交付:** 實作變更與測試報告清楚區分unit/integration、實機無更新啟動、實機有更新成功、尚未驗證來源。不操作VS Code問題面板、不憑fixture宣告全部流程已完美。

## 自我審查與需求對應

| 規格驗收 | 實作任務 | 關鍵證據 |
| --- | --- | --- |
| R1 | 2 | 正文時間／timezone／延長／過期／失敗fixture與官方只讀冒煙 |
| R2 | 5、8 | fake UTC開服前1ms，after-open副作用spy，時鐘突跳 |
| R3 | 3、6、7 | 雙安裝／非C／junction／`.url`／unknown cases與provider evidence |
| R4 | 2、4、5 | 原子寫中斷、父死、PAUSE與action journal恢復 |
| R5 | 5、8、9 | 命令generation競爭、04:00、切服ACK與完成skip |
| R6 | 4、6、7、11 | unknown進度不假報、目標App活動與兩來源實機gate |
| R7 | 7、8 | 維護vs網路，F11後維護，不重送，game_ready證據 |
| R8 | 8 | 錄影封口、直播marker、Foreground spy、restart_count未增 |
| R9 | 9、10 | JSON/Firestore往返、revision ACK、capability、手機畫面 |
| R10 | 1、10、11 | 路徑/ZIP/validate/compile/Web/regression/diff |

所有新函式的責任、來源與回傳型別列於共用介面及對應任務；現有函式以2026-09-21讀到的程式為依據。未對正式payload、遊戲、Docker、網站或GitHub作任何功能變更。
