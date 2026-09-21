# 鳴潮版本維護等待與自動更新設計

日期：2026-09-21（Asia/Taipei）
狀態：使用者已確認產品方向並授權實作；本文件是規格，功能仍在開發驗證，尚未部署。
對應計畫：[實作計畫](../plans/2026-09-21-game-maintenance.md)

## 1. 已確認需求

使用者要求「先計劃」，並依序確認：

1. 遊戲版本更新日，依官方公告的預計開服時間延後鋤地。
2. 支援 Steam 與庫洛官方啟動器；每台裝置自行判定安裝來源。
3. 正常使用不要求選擇 Steam／官方版。
4. 兩種來源均等到官方預計開服時間才由腳本發起更新。
5. 更新完成、登入成功後接回原本鋤地與伺服器排程。

「版本」在本功能有兩個不同欄位：`provider` 表示安裝來源；`gameVersion` 表示公告的遊戲內容版本。OKWW 版本、Payload 版本與 Steam build ID 均不可拿來代替遊戲內容版本。

## 2. 全域限制

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

### 對先前討論的技術補正

- G2 約束本腳本。Steam 或官方啟動器若早已在背景自行更新，腳本只如實顯示觀察結果，不宣稱已阻止第三方下載。不因這項功能改 Steam 的全域政策。
- 鳴潮官網目前使用公開 JSON，但它不是具有穩定性保證的公開 API；必須驗證格式、日期、來源與新鮮度。
- Steam 的 ACF／Log 是輔助證據，不是已公開保證的更新進度 API；檔案存在、大小不變、`BytesToDownload=0` 均不足以宣告更新成功。
- 現有登入由 OKWW F11 協助。登入頁沒有維護提示時才可進入該流程；真正開服成功須由遊戲主畫面驗證。不能要求先登入成功才啟動負責登入的 OKWW。

## 3. 目前程式整合位置

基準：2026-09-21 工作樹；行號僅供定位，實作前以函式與註解重新定位。

| 現有位置 | 現況 | 整合要求 |
| --- | --- | --- |
| `payload/全自動.ahk` 啟動段，約 2486–2626 | 載入設定與遠端控制後清場、啟動 crash watcher、開始錄影及遊戲 | 先完成設定與命令／排程初始化，再插入維護閘門；閘門位於清場、錄影及遊戲啟動之前 |
| `DetectWutheringAndExit()` | 辨識遊戲內更新／登入，會操作備援模板與確認按鈕 | 在任何此類操作前先檢查明確維護提示；回傳獨立 `maintenance` 結果 |
| `EnsureWutheringRunning()` | 對 WUTHERING 路徑 Run，再等遊戲程序 | 版本更新日改由已驗證 provider adapter；平日保留原入口 |
| `WaitGameReadyAfterOkwwF11()`／`WaitEscMenuOCR()` | F11 後等主畫面，超時可能中心點擊與重啟 | 回傳維護證據時停止中心點擊／重啟；正常網路失敗保留原分類 |
| `OnRemoteControlStateChanged()` 與遠端 PAUSE／RUN hook | 可能操作遊戲／LRMCAI 或排定切服重啟 | 新閘門啟用時只更新意圖；不送 F9／Ctrl+F1／F11、不啟動切服重啟 timer |
| `RuntimeFilePaths.ahk` | 統一程式內資料、暫存、快照與開發路徑 | 新狀態與 worker 全部沿用此規範 |
| `RemoteControlFirestore.ahk`／`RemoteControlSelfHost.ahk` | 既有狀態與設定傳輸 | 附加緊湊的 maintenance 狀態，沿用原輪詢與 ACK |
| `self-hosted-server/src/app.js` | 心跳 `status` 已存 JSONB | 維護狀態使用 `status.gameMaintenance`，無需新增資料表 |
| 兩套網站 `app.js/index.html/styles.css` | 總覽、診斷、設定分頁 | 總覽維護卡片、設定 ACK、進階人工延後／略過此事件 |

## 4. 公告資料與時間政策

### 4.1 官方來源

此前已實際讀取到官方前端使用的來源：

- 官網：https://wutheringwaves.kurogames.com/zh-tw/main/news
- 列表：https://hw-media-cdn-mingchao.kurogame.com/akiwebsite/website2.0/json/G152/zh-tw/MainMenu.json
- 明細路徑：同來源 `article/{articleId}.json`
- 歷史驗證範例：https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280

以列表 `articleId` 去重，再取明細 `articleContent`。列表內容可能截斷；`startTime` 是公告發布資訊，不是維護開始時間。只提取維護必要文字，不執行 HTML／JavaScript，不將整篇 HTML放進 UI 或命令。

公告有效條件：官方 HTTPS allowlist、完整本文、版本維護語意、明確起訖年月日時分及 UTC offset、國際服 PC 適用性。缺少時區／只有日期／結束早於開始／區服不符者拒絕。預下載、版本前瞻與單項系統維護不等同全服停機。

HTTP 每次最長 10 秒、一次更新檢查總預算 20 秒；單回應上限 2 MiB；最多 12 個候選明細；不自動跟隨離開 allowlist 的重新導向。啟動檢查預算用完後由背景 worker 繼續或降級，不阻塞主執行緒與 STOP。

### 4.2 標準事件

標準記錄包含：`schemaVersion=1`、`eventId`、`articleId`、`gameVersion`、`scope`、`startsAtUtc`、`expectedOpenAtUtc`、`publishedAt`、`fetchedAtUtc`、`sourceUrl`、`bodySha256`、`revisionHash`、`sourceState`。

`eventId` 由遊戲／global scope／遊戲版本／原維護開始時間組成，延長公告與原公告共用事件。`revisionHash` 隨已驗證正文更動；不同 article ID 不自動代表不同維護。

- 儲存 UTC；日期判斷和畫面顯示使用 Asia/Taipei。
- 一般維護起訖跨度需為正值且不超過 48 小時；超界進入待確認，不能自動猜測。
- 平日啟動檢查一次；活動維護期間每 5 分鐘更新；抵達預計開服時間強制重新確認一次。
- 宣告「沒有維護」的快取有效 6 小時；到日界或新的版本更新日必須重查。
- 已確認的維護事件在起始日前 14 天內可快取。已知未來開服時間即使網路暫斷也持續等待；不能因 TTL 過期提前放行。
- 已知維護到達開服時間時，公告確認需在最近 15 分鐘內且涵蓋最後一次檢查。無法取得則 `WAIT_NOTICE`，每 5 分鐘重試；人工明確略過該事件可解除時間閘門。
- 完全沒有已知維護且官網無法讀取：顯示「公告確認失敗」，在 20 秒預算後沿用平日流程；同時保留遊戲內維護偵測備援。不可把網路失敗宣稱為「今日無維護」。
- 對已結束且過期的事件不重複延後。當天錯過開服後啟動，立即進入更新檢查；跨日已持久保存且尚未完成的事件繼續接續。冷啟動只找到歷史公告時，不強制用過期公告更新。
- 延長必須能關聯同版本／區服／原事件；不確定的新公告顯示待確認。新的有效結束時間可延後；不根據提前開服消息自動早於原等待時間放行。
- 系統時鐘與單調時鐘差異突然超過 120 秒時重新確認公告與狀態；不修改 Windows 時鐘。時間閘門用 UTC，更新卡住計時用單調時鐘。

## 5. 安裝來源自動判定

輸入是目前 `[paths] WUTHERING` 的實際入口。支援 `.exe`、`.lnk`、Steam `.url` 與精確鳴潮 Steam URI；擴充設定檔案選擇器與驗證，避免 `.url` 在前置檢查被當成不存在。

1. `.lnk` 最多解析 4 層並偵測循環，只讀目標、參數、工作目錄。
2. `.url` 只接受明確的 `steam://run/3513350` 或實機確認等價的 `rungameid/3513350`；拒絕其他 App ID、任意外部 URL、額外命令與 shell 包裝。
3. 找出既有 Steam registry 安裝路徑與 `steamapps/libraryfolders.vdf`，支援舊／新 VDF 結構及非 C 槽遊戲庫；不遍歷所有磁碟。
4. 解析 `appmanifest_3513350.acf`，同時驗證 App ID、`installdir`、存在的實際安裝目錄。清單紀錄不足以代表遊戲可用。
5. 直接指向遊戲 EXE 時，使用解析後的實際路徑與 Steam 安裝根比對；不得以名稱或未處理 junction 的字串前綴判定。
6. 官方版需有對應遊戲根與啟動器設定／安裝證據；「不是 Steam」不等於「已證明是官方版」。僅在目標相鄰目錄、有限父目錄與匹配公開安裝紀錄查找。
7. 兩套同時存在時，使用入口明確指向的那套。入口與安裝證據矛盾、缺失或無法讀取時回傳 `unknown/ambiguous`；版本更新閘門保持等待。

輸出：`provider=steam|kuro|unknown|ambiguous`、`appId`、`gameRoot`、`launchEntry`、`launcherPath`、`evidence[]`、`fingerprint`、`checkedAtUtc`、`updateAdapterReady`。只有有證據的能力才設 `updateAdapterReady=true`。

保存識別快取，啟動入口、捷徑、manifest、libraryfolders、真實目錄或判定規則版本改變時失效。一般平日即使 updater 身分不明，既有合法啟動入口仍可沿用；需要託管更新時才封鎖。正常設定頁只顯示判定結果與「重新偵測」，不要求選 provider。

## 6. 本機狀態與主流程

採用一個低優先權 PowerShell worker 讀公開公告、安裝證據及 Steam 狀態；AHK 是唯一有權決定及執行啟動／鍵鼠動作的控制器。worker 不 Run 遊戲、不改 Steam 檔案、不讀任何帳戶設定。等待／更新使用同一 worker，不能每 2 秒另開 PowerShell。

純策略函式輸入「現在、公告、觀察、遠端意圖、桌面狀態、持久狀態」，輸出下一個 phase 與一個具 ID 的待執行動作。系統副作用在控制器重驗後執行。

| phase | 意義／出口 |
| --- | --- |
| `CHECKING_NOTICE` | 有限時間查公告，已知事件不因失敗提前放行 |
| `NORMAL` | 無適用事件，回到原主流程 |
| `WAIT_OPEN` | 日期是維護當天，即使尚未到維護開始也等至預計開服 |
| `WAIT_NOTICE` | 已知事件到時間，但最新公告無法確認或延長資訊不完整 |
| `CHECKING_UPDATE` | 時間與 RUN／桌面守門通過，辨識 provider／查 updater |
| `UPDATING` | 更新、配置或驗證中；進度可未知 |
| `CHECKING_LOGIN` | 程序與視窗就緒，檢查維護訊息，再沿用原登入流程 |
| `WAIT_SERVER` | 遊戲確實顯示維護；每 5 分鐘再檢查，不一般重啟、不重送 F11 |
| `READY` | 同一有效遊戲身分的主畫面已穩定確認，接回鋤地 |
| `NEEDS_ATTENTION` | 安裝來源不明、登入驗證、下載錯誤、磁碟不足或更新失去進展 |
| `STOPPED` | 使用者 STOP／離開；持久取消自動動作，下一個明確新任務才重啟 |

`PAUSE` 與 `WAIT_DESKTOP` 是 overlay，不覆寫原 phase，解除後才能繼續動作。更新器已在下載時，PAUSE/STOP 會停止本腳本的後續啟動與鍵鼠動作；不宣稱已暫停 Steam 自行進行的下載，也不殺共用 Steam。

### 主流程順序

1. 設定路徑、遠端控制及只讀診斷初始化。
2. 讀取 maintenance journal，先判定是否接續，再決定是否可用既有 fresh-cycle 重設 PAUSE 邏輯。已持久 PAUSE 不可因 Windows 重開的普通啟動參數而被清掉。
3. 初始化伺服器排程、處理既有命令 claim、套用啟動期間排隊的設定與命令。
4. 進入維護閘門。閘門所有等待均可插入遠端輪詢、STOP 與公告快取更新。
5. 閘門放行且 RUN／桌面有效後，才做原本清場、啟用 crash watcher 及版本日 updater。
6. 更新完成後啟動遊戲；若 updater 已啟動正確遊戲，採用同一身分，不重複啟動。
7. 偵測無明確維護提示後才進入既有切服與 OKWW F11。真正的 `READY` 取自主畫面穩定驗證；接續聲骸與 LRMCAI。
8. 版本日正式錄影在 `READY` 後、聲骸流程前開始。平日保留原錄影時機。

重啟接手若已有受管錄影且必須長時間維護等待，先依既有錄影所有權機制正常封口；後續開新單檔。不得影響其他錄影或直播。

### 遠端控制與伺服器

- WAIT 中 RUN 只解除 PAUSE，不送遊戲熱鍵；PAUSE 不執行原確認模板等待。
- STOP 在 2 秒內於本機取消後續動作（不含網路命令本身抵達時間），依既有 ACK／收尾處理，不先宣稱全部關閉成功。
- WAIT 中 `SWITCH_SERVER` 驗證索引與名稱後保存目標，ACK 明確為「已排定，等待版本維護結束」，不寄「已切服成功」郵件，不重新啟動。
- `COMPLETE_SERVER` 沿用 04:00 當日完成規則；尚未開始任何遊戲的目前目標被標完成時重選剩餘服，全部完成則停止。
- 等待跨越 04:00 後，在放行前依既有函式重新核對循環日、命令目標及當日完成表，不重用上一日完成／收尾命中。
- 正在鋤地的流程不因本次新公告定時掃描被強制中斷；本功能在啟動／恢復／切服入口接管。遊戲內明確維護提示可以進入等待。

## 7. 更新來源 adapter

### Steam

開服時間到了且證據充分後，使用已驗證 Steam 執行檔與固定 App ID 發起一次啟動；候選 `steam.exe -applaunch 3513350`／已存在的精確 Steam URI 需要在實作驗收中證實。相同動作 ID 在程序重啟後先對帳現有下載／遊戲，不能直接重送。

以 5 秒本機採樣讀 manifest、增量 content Log、相關程序，必要時檢查 Steam 的該 App 畫面。Log 依 App ID 過濾，不能把其他遊戲下載當鳴潮進度。Steam 顯示更新完成只讓狀態進入遊戲驗證，不能直接設 `READY`。有可信 bytes／total 時顯示該階段百分比；沒有則 `progressPercent=null`。

前 180 秒尚無下載／安裝／遊戲活動，回報明確的 queued、login_required、offline 或 `unknown`。實際下載／安裝／驗證允許長時間運作；連續 30 分鐘沒有可證實活動才 `NEEDS_ATTENTION`，只讀 log 可提供活動證據。unknown 對外顯示「無法確認」，不以 CPU／磁碟寫入猜成功。PAUSE／鎖定期間不消耗 UI 操作逾時。

若確有該 App 的可操作「更新／繼續」按鈕，最多一次安全操作並驗證結果；無法確認目標不點擊。登入、驗證、UAC 顯示需人工處理，不能把它們當等待逾時一直重試。

### 庫洛官方啟動器

只接受與所選遊戲根對應的 launcher。對更新、下載、安裝、驗證、開始遊戲採不同 observation。一般輪詢背景擷取；真正點擊前驗證 exe 路徑／PID／HWND／前景／互動桌面，輸入後驗證狀態轉變。採實機捕獲的按鈕區域規則，不把公告正文「更新」當按鈕。

與 Steam 共用 30 分鐘無進展門檻；有明確錯誤立即回報，不自動重新下載／改安裝路徑。空間預檢用實際 updater 所需容量；若無可靠容量，顯示未知並監測 updater 空間不足訊息，不以固定「剩 20 GB」保證能完成大版本更新。

### 遊戲內維護備援

只讀目標遊戲 client 的明確維護文字，至少同一身分連續兩次一致；涵蓋繁體／簡體／英文確切維護語意。`無法連接伺服器`、`網路異常`、逾時、過期 Log 均不單獨構成維護。

維護提示要在登入模板輔助、確認／退出點擊和 F11 等副作用之前檢查。F11 後才出現維護提示時保存同一個 OKWW 狀態，禁止把 F11 當可無限重試的登入鍵。提示消失且已有可用主畫面時直接放行；需新的登入動作卻無法證明 OKWW 能安全接續時顯示 `LOGIN_RESUME_UNCONFIRMED`，保留現場。不可以無證據重送可能造成開始／停止切換的 F11。

## 8. 狀態檔、重啟與程序所有權

- `<程式資料夾>/config/game-maintenance/notice-cache.json`：worker 單一寫入者，保存最近 3 個必要公告摘要及驗證資訊；總量不超過 256 KiB。
- 同目錄 `state.ini`：AHK 單一寫入者，保存 schema、event／revision、phase、provider fingerprint、run cycle、待執行 action ID／stage、remote generation、取消旗標、通知去重 key；不保存帳密或網頁原文。
- worker request／snapshot／cancel 使用 `RuntimeFiles_RuntimeDir("遊戲更新")` 的獨立 session 目錄，含隨機 request ID、父 PID 及建立時間。AHK 只接受匹配 request ID、遞增 sequence、60 秒內 snapshot。
- 持久狀態在 `config` 下，不放 24 小時會被清除的診斷暫存。temp→flush/close→原子替換，保留一份驗證過的前版；讀取截斷文件不猜欄位預設為完成。
- 每個發起更新／啟動動作先寫 intent，再做副作用，再保存 observation。意外中斷後先核對 updater／遊戲再決定是否續做；不聲稱外部 UI 動作具有 exactly-once 保證。
- 父程序消失、身份改變或 cancel 出現時 worker 退出。清理只針對該 session marker、完整 script path、PID＋建立時間匹配的 helper；不使用全域 powershell／Steam／Python kill。
- helper 失效最多於該 session 重建一次；仍失敗變成 `NEEDS_ATTENTION`，不引發主程式重啟連鎖。

## 9. 網站、本機 UI 與通知

對外狀態 `gameMaintenance`：`schemaVersion`、`capabilityVersion`、`phase`、`overlay`、`provider`、`gameVersion`、`eventId`、`sourceUrl`、`sourceState`、`expectedOpenAt`、`checkedAt`、`observedAt`、`observedUtcNow`、`progressPercent`、`progressStage`、`errorCode`、`detail`、`targetServer`。對外採 Unix epoch 毫秒；不傳本機完整安裝路徑與整篇公告，JSON 上限 4 KiB。

自架寫入 `status.gameMaintenance`；Firestore 寫入 `gameMaintenanceJson` 字串、加相應 updateMask。一般 RUN／PAUSE／OFFLINE 格式不變。倒數於瀏覽器本地計算，資料過期顯示「最後已知／離線」，不增加讀寫次數。

本機設定頁顯示自動來源及官方更新排程；來源不明時提示修正鳴潮啟動路徑／重新偵測。最低檢查 1920×1080、125%／150% 縮放，底部儲存按鈕可見；完整路徑放摺疊區。

兩網站總覽卡片優先顯示「正在等什麼、開服時間、預計下一步、Steam／官方版與目標服」。更新百分比未知時用文字；診斷展開公告／驗證時間／錯誤原因。

進階操作使用原設定 revision 管線：`maintenanceEnabled`、`maintenanceOverrideEventId`、`maintenanceDelayUntilUtc`、`maintenanceSkipEventId`、`maintenanceRefreshRequestId`。延後必須綁定當前 event、晚於現在且至多 48 小時；略過僅作用於當前 event 並在任務結束時失效。手動略過只解除時間閘門，不略過來源驗證、鎖定、PAUSE、維護畫面或版本更新。新操作只在裝置回報 capability v1 後可按。

設定頁區分已送出、裝置已 ACK、目前已生效值與拒絕原因，不能只靠 HTTP 成功顯示套用完成。「重新檢查」重複點擊去重，官方查詢仍至少間隔 60 秒。

沿用郵件總開關：首次等待、正式更新開始、主畫面就緒／流程接續、維護延長及需人工處理各發一次；以 event＋stage＋revision 去重。遠端已排定切服的郵件仍等實際成功門檻。等待時不發「鋤地已開始」通知。

## 10. 驗收與真實驗證範圍

| ID | 驗收結果 |
| --- | --- |
| R1 | 官方公告明細解析、時區、重複、延長與格式改動可測；不用發布時間推導開服 |
| R2 | 開服前 1 秒零更新動作，到時間才發起；下午才開機不等到隔天 |
| R3 | Steam／官方版／雙安裝／`.url`／非 C 槽／junction／壞 manifest 正確分流，模糊證據不猜 |
| R4 | 公告斷線、壞快取與重啟恢復不丟 waiting／PAUSE／STOP／action intent |
| R5 | WAIT 中命令、切服與標記完成可用；04:00 切日與已完成目標不重跑 |
| R6 | Steam 與官方 updater 有下載、安裝、失敗和身分驗證；未知進度不冒充 0%／100% |
| R7 | 維護提示和一般網路錯誤分開；F11 不重複送；主畫面證實後才 READY |
| R8 | 等待不錄影、不錯誤重啟、不搶前景；既有錄影正常封口、直播隔離 |
| R9 | 自架與公司網站同樣顯示狀態、設定精確 ACK，舊 client 不假裝支援 |
| R10 | 路徑政策、文件／測試排除、AHK validate／compile、Web checks、回歸與 diff 檢查通過 |

先使用注入時鐘、假安裝目錄、假 updater／假 HTTP 與 action spy 做可重現測試；不改 Windows 時鐘，不連正式控制資料庫發假命令。再執行唯讀安裝偵測，最後在獲准的實機工作階段對目前實際 provider 測試。已是最新版只能證明「無待更新」與啟動鏈，不能當成成功下載大型版本。

真實 Steam 更新與真實官方版更新須各有一次證據；缺少任一安裝來源／待更新版本時，明列該驗收未完成，不靠 fixture 宣稱雙來源全部實測。需調整遊戲進程、第三方程式或正式發布時，沿用當次使用者授權；這份規劃本身不執行它們。

## 11. 來源與版本限制

- [鳴潮官方維護公告](https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5280)：歷史格式及 PC 更新流程，並非下一次開服時間。
- [鳴潮 Steam 官方商店](https://store.steampowered.com/app/3513350/Wuthering_Waves/)：App ID 與發行來源。
- [Steamworks 更新說明](https://partner.steamgames.com/doc/store/updates)：Steam 管理更新與下載排程；不保證所有第三方遊戲沒有遊戲內補丁。
- [Steam 支援下載與更新](https://help.steampowered.com/en/faqs/view/71AB-698D-57EB-178C)：官方入口；本次工具未展開正文，不以此補猜內部 ACF 狀態碼。

先前維護公告來源已讀取驗證；Steam／Kuro 在兩台目標電腦上的更新行為尚未實測。具體來源 adapter 只有完成計畫中的 evidence gate 後才能標記可用。
