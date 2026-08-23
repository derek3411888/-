# 一鍵啟動鋤地腳本：AI 接手速覽

## 1) 專案目的
本專案是 AutoHotkey v2 自動化流程，核心目標是：
- 啟動並維護鳴潮流程
- 協調 LRMCAI、OKWW、聲骸合成等子腳本
- 透過 OCR/模板判定流程狀態
- 進行收尾監測、重啟恢復、伺服器排程與完成記錄

## 2) 目前主流程重點（payload/全自動.ahk）
- 啟動前：
  - 讀取 CFG_FILE（優先 PACK_DATA_DIR，否則 fallback 到 ../config，再否則 Temp）
  - 前置檢查與清場
  - 啟動崩潰監看
- 執行中：
  - 鳴潮視窗/進程檢查
  - 更新/登入流程處理
  - 啟動 OKWW、聲骸合成、開啟LRMC
- 收尾：
  - 進入 MonitorRewardAndShutdown 監測 LRMCAI 日誌
  - 達標後關閉流程或切換伺服器續跑

## 3) 近期已落地的需求與行為
### 3.1 伺服器完成記錄時機
- 已改為「收尾監測達標後」才標記完成，不在主流程剛完成時立即標記。

### 3.2 收尾監測中的閃退檢測
- 收尾監測迴圈中會主動檢查鳴潮遊戲視窗：
  - 以 ahk_exe Client-Win64-Shipping.exe 判斷
  - 視窗消失即判定閃退，觸發重啟

### 3.3 日誌新鮮度判定（避免吃舊 log）
- 收尾監測逐行判定時，僅接受「近期」時間戳的 log。
- 目前容忍窗口：3600 秒（1 小時）。
- 收尾監測目前支援以 `yyyy-MM-dd HH:mm:ss` 開頭的時間戳，並接受逗號或句點後的毫秒（例如 `2026-06-29 04:09:14,789`）。
- `yyyy/MM/dd HH:mm:ss` 與 14 位 `A_Now` 格式目前不會被收尾監測接受；伺服器循環日期解析是另一套邏輯，支援的格式較多。

### 3.4 逾時參數
- 收尾監測啟動前等待：300 秒（5 分鐘）
- LRMCAI UI 視窗等待逾時：3 分鐘（60 次 * 3 秒）
- 鳴潮更新後恢復視窗等待：300 秒（5 分鐘）；更新恢復期間必須停用一般 no-window 的 180 秒重啟門檻，避免新的 300 秒設定仍被提前截斷。

### 3.5 自動重啟上限
- MAX_RESTART_COUNT 目前為 10。

### 3.6 重啟通知信
- 重啟流程會把原因寫入 `[restart_tracking]`，新程序啟動後寄送通知信。
- 通知信主旨包含「重啟次數＋原因代碼」；內文包含原因代碼、發生階段、詳細原因、恢復策略、LRMCAI 當時狀態、進程快照與異常偵測時間。
- 目前原因代碼包含遊戲更新恢復逾時、啟動無視窗、主畫面驗證逾時、聲骸旗標、聲骸逾時、UE4 致命錯誤、收尾期間遊戲進程消失、LRMCAI 無效視窗大量累積。

### 3.7 UE4 崩潰監看防重複
- 崩潰監看必須等 `CFG_FILE` 與重啟狀態載入完成後才啟動。
- 接受舊標題完全等於 `UE4-Client`，或以 `UE4-Client Game` 開頭且包含 crash／崩潰／fatal／致命等關鍵字的已知崩潰標題。
- 視窗還必須可見、未最小化、未被 DWM cloak、尺寸合理並與虛擬螢幕相交；標題命中後 OCR 仍須找到 Fatal、DXGI 或崩潰證據才會操作，避免再次出現幽靈視窗誤觸發。
- 每次有效事件以 `PID|HWND` 作為指紋，寫入 `[restart_tracking] last_ue4_crash_signature`。
- 同一事件即使在腳本重啟後仍殘留，也只能消耗一次重啟額度；日誌與重啟原因會記錄 PID、HWND、EXE、視窗座標及 OCR 錯誤摘要供後續診斷。

### 3.8 重啟上限與錄影收尾
- 一般重啟會保留既有 FFmpeg，讓下一個腳本接管同一段錄影。
- 超過 `MAX_RESTART_COUNT` 已是終止流程，不可再沿用重啟旗標。
- 達上限時會先停止崩潰監看、清除重啟旗標並向受管 FFmpeg 送出 Ctrl+C，最多等待 15 秒完成 MKV 封口；只有逾時才強制停止。
- 錄影預設每 5 分鐘寫入本機 `%LOCALAPPDATA%\WutheringAuto\recording_staging` 的獨立 MKV 分段。進行中只補傳已封口分段，不直接把尚在寫入的檔案放到網路分享。
- 正常結束後由 `RecordingFinalizeWorker.ahk` 補傳全部分段、以 FFmpeg stream copy 無損合併，再用精確檔案大小驗證目的端成品。只有驗證成功，才刪除本機工作階段與帶安全標記的目的端分段資料夾。
- 網路離線時本機錄影不中斷；收尾工具每分鐘重試最多 2 小時，之後仍保留資料並由下次主程式啟動恢復。

### 3.9 聲骸合成前的月相觀測卡畫面
- `payload/聲骸合成.ahk` 在第一次按 Esc 前，會 OCR 遊戲畫面下半部。
- 以「剩餘／剩余」、「點擊領取／点击领取」、「月相觀測卡／月相观测卡」三組特徵判斷，至少命中兩組且連續兩次才成立。
- 命中後會啟用遊戲視窗、點擊中央、等待領取文字消失，再點擊第二次。
- 第二次點擊後優先以 `icon_main.png` 連續命中確認回到主畫面，才進入既有 Esc 選單流程；若模板因縮放未命中但領取文案已消失，交回 `OpenMainMenu()` 做最後驗證。

### 3.10 LRMCAI 崩潰後接續模式
- `開啟LRMC.ahk` 只有在成功送出 `Ctrl+F1` 後，才會寫入 `[lrmc_runtime] run_started=1`、開始時間與啟動模式；不能用「主腳本已執行到 Run()」代替成功判斷。
- 收尾監測的遊戲進程消失、LRMCAI 無效視窗大量累積，以及 UE4 致命錯誤，會要求接續；`RequestRestart()` 仍會再次確認 `run_started=1`。
- 可接續時重啟命令使用 `restart resume`，後續以 `開啟LRMC.ahk resume` 略過 OCR「副本」並直接送 `Ctrl+F1`。
- 若已在 `restart resume` 恢復鏈中，遊戲更新／啟動／主畫面驗證或聲骸流程再次失敗，仍保留接續意圖；只有沒有有效 `run_started=1` 時才降級一般重跑。
- `rewardmonitor` 舊參數仍相容，但新程式統一使用 `resume`。
- resume 若無法切換 LRMCAI 前景或無法送鍵，只在同一次執行中降級一次為一般 OCR「副本」流程。
- 一般首次啟動、非接續重啟、正常／手動收尾、切換下一伺服器與超過重啟上限都會清除接續狀態。

### 3.11 日誌保留數
- 共用 `LogManager.ahk` 目前對每個腳本分類各保留最新 15 份日誌。

### 3.12 OKWW 啟動後的 F11 操作
- `全自動.ahk` 不再 OCR OKWW 視窗中的「啟動遊戲／開始／F11」文字，也不再依 OCR 座標點擊，避免把版本說明中的「启动游戏」誤當按鈕。
- 啟動 `自動開啟OKWW.ahk` 後，最多等待 90 秒，只接受由 `pythonw.exe` 承載的最終主視窗；標題同時相容 `OK-WW v版本 Global`（v3.5.18）及尾端帶 `- OK-WW` 的舊格式。
- 同一個 HWND 必須連續確認兩次才算穩定。之後以 OKWW client 截圖做嚴格 OCR：先把 RapidOCR 可能混用的 `实／實、时／時、触／觸、发／發、动／動、战／戰、斗／鬥、启／啟` 統一。左側導覽項目限定在 `rect.right <= 180 × DPI scale` 的區域內，優先精確接受 `實時觸發` 或 `即時觸發`；精確文字不存在時，才允許等長且只有一個字不同的受限容錯（例如 `即時網發` 對應 `即時觸發`）。此容錯只用於左側導覽。進入頁面後，「自動戰鬥」標題僅能在主內容第一列命中，接受獨立 exact block、以完整標題開頭的 merged block，或 OKWW v3.5.28 實測出現的最多 2 字元前綴雜訊（例如 `x,自動戰鬥...`）；狀態仍只接受 client 寬度 68% 以右、與標題中心差不超過 `24 × DPI scale` 的精確「已啟用／未啟用」，避免把相鄰第二列誤當第一列。未啟用才點開，且必須連續兩次 OCR 確認已啟用才繼續。缺失時須記錄受限區域候選，且不使用主題敏感的像素亮度門檻。
- `自動開啟OKWW.ahk` 只把最終 `pythonw.exe` 的 `OK-WW v... Global` 視窗或標題完全為 `ok-ww` 的真正升級 UI 當作互動目標；`ok-ww-siw`／service 視窗只能忽略並繼續等待。最終 pythonw 一出現就立刻交由主程式，管理器不可再激活或拿它做 `升级APP` OCR，避免兩支腳本搶同一視窗。更新檢測必須區分「有效 OCR 後未命中」與「截圖/OCR 失敗」，後者不得回報成不需更新。
- 自動戰鬥確認成功後只送出一次 `F11`。優先切到前景以 `SendEvent` 發送，無法切前景時才以 `ControlSend` 定向發送；送出後等待 2 秒立即最小化，並於約 3、7、11 秒非侵入式補掃延遲出現的 OKWW 視窗。最小化只接受 `ok-ww.exe` 的精確升級標題，或 `pythonw.exe + OK-WW v... Global`，不可碰其他 Python。
- 自動戰鬥前置確認只在同一個 OKWW 視窗嘗試 2 次。兩次仍無法確認時，不關閉、不重啟、不再開第二輪 OKWW，直接沿用同一個已鎖定 HWND 送一次 F11。
- 兩個呼叫端都統一走 `StartOKWWFlowWithLocalRecovery()` 並接收結果；此名稱只為相容既有呼叫，現在已不會重啟 OKWW，而是同視窗 F11 降級。未被降級策略成功處理的失敗仍依階段使用 `OKWW_MANAGER_LAUNCH_FAILED`、`OKWW_FINAL_WINDOW_TIMEOUT` 或 `OKWW_F11_SEND_FAILED` 進入原 `RequestRestart()`，不得繼續等待主畫面後誤報 `GAME_READY_CHECK_TIMEOUT`。
- `OKWW_AUTOBATTLE_CHECK_FAILED` 不再觸發舊的局部復原函式；wrapper 只取回同一次流程已穩定鎖定的最終 `pythonw` HWND，做相同的程序名／標題安全檢查後直接送一次 `F11`。送出成功即排程最小化並回傳成功繼續流程；只有直接送鍵本身失敗，才改回 `OKWW_F11_SEND_FAILED` 並走原 `RequestRestart()`。

### 3.13 鳴潮前景與置頂原則
- 一般 OCR 與模板輪詢均使用 ImagePut 的 `PrintWindow + PW_CLIENTONLY` 背景 client 截圖，不因輪詢而 `WinActivate` 或將鳴潮設為置頂。
- 啟動階段將鳴潮移到右上角時，普通視窗只調整 X/Y，不傳入寬高，也不執行 `WinRestore` 或 `WinActivate`；移動後需驗證尺寸與視窗狀態不變。最大化視窗保持最大化並略過移動，最小化視窗保持最小化並延後重試。
- `WaitEscMenuOCR()` 的 `icon_main.png` 驗證使用背景截圖右下 ROI；即使鳴潮被其他視窗遮住，也不應搶回前景。模板以 1280×720 UI 比例建立，捕獲尺寸不同時先正規化為 1280×720 再比對；已用 2560×1440 與 2560×1400 錄影畫面驗證可命中。
- 登入／叉叉等模板預搜尋也預設走背景 client 比對。只有確定命中並準備實際滑鼠點擊時，才短暫還原、啟用及置頂鳴潮；`finally` 必須保證取消置頂。
- 保留原本登入 OCR 主迴圈每秒呼叫 `TryAssistLoginTemplateBeforeOcr()` 的輔助點擊，也保留兩個 OKWW 啟動入口前的 `登入.png` 點擊；這些搜尋仍先走背景比對，只有模板命中並實際點擊時才短暫切到前景。

### 3.14 遠端 PAUSE 期間的收尾監測
- `MonitorRewardAndShutdown()` 在 300 秒暖機前就建立 LRMCAI 日誌游標；暖機與遠端 PAUSE 期間仍每 3 秒讀取新增日誌。
- PAUSE 期間只允許讀檔、累積命中及寫入 `[reward_monitor_runtime]`；不得重啟 LRMCAI／遊戲、點擊模板、停止錄影、關閉程式或切換伺服器。
- 日誌游標、命中數、各獎勵旗標、完成原因與實際命中時間會持久保存；同一循環日、伺服器及日誌路徑可跨程序恢復。
- 寫入持久狀態時必須最後才推進 `last_pos`，避免異常中斷造成游標已前進、命中旗標卻尚未落盤。
- 收尾條件在 PAUSE 期間成立時，先以實際命中時間標記伺服器完成，但延後關閉／切服直到收到 RUN。若已保存完成條件，RUN 不再等待登入 OCR 或送出 Ctrl+F1。
- 最後一次 PAUSE 判斷到正式收尾必須用 `Critical` 形成不可插入的提交區段，避免命令計時器卡在判斷與關閉／切服之間。
- 收尾專用等待必須走 `WaitRewardMonitorForShutdown()`／`RawSleep()`，不可再走受全域 PAUSE 閘門控制的 `Sleep()`。

### 3.15 遠端命令 nonce、ACK 與歷史
- `remote-control-web/app.js` 以 Firestore `runTransaction` 在同一交易原子遞增頂層 `nonce`、更新頂層 `desiredState` 並追加命令歷史，禁止再使用 `getDoc → nonce+1 → updateDoc`。
- 每台 client 父文件的 `commandHistory` 最多保留最近 30 筆；歷史欄位使用 `commandNonce`、`requestedState`，不可使用精確欄名 `nonce` 或 `desiredState`，避免 AHK REST regex 誤抓巢狀欄位。
- 只有 `lastAckNonce == commandNonce` 且 `lastAckState == requestedState` 才能顯示「已 ACK」。30 秒沒有精確 ACK 顯示「未回應」；ACK nonce 已前進則顯示「被後續命令跨過」。
- 命令歷史只從部署新版網頁後開始建立，無法回補舊版已送出的命令。

### 3.16 Launcher 自我更新與舊版救援
- Launcher 更新檢查與 payload 版本判斷彼此獨立；即使 payload 已是最新版，每次啟動仍須讀取 manifest 檢查 `launcher_version` 與 `launcher_sha256`。
- pending 狀態檔必須以覆寫方式寫入，並依 `version → sha256 → launcher_pending_update.tmp` 的順序提交；禁止再用 `FileAppend`，避免多次下載路徑或版本字串黏在一起。
- 新 launcher 下載後由外部 PowerShell helper 等目前 launcher PID 真正退出，再以 candidate／backup 方式替換。成功後才寫 `launcher_current_version.txt` 並清 pending；任一步失敗都要還原舊 EXE、保留 pending 供下次重試，結果寫入 `launcher_update_outcome.log`。
- 若目前 EXE SHA 已等於 manifest，應補寫版本並清除 stale pending，禁止把舊 pending 套回而降級。版本文字相同但 SHA 不同時，必須重新下載修復，不能只信版本檔。
- Launcher v4.42 的替換器本身有固定等待 2 秒、狀態檔追加寫入及成功分支未寫版本等缺陷，因此 payload 內保留一次性 bootstrap：只有啟動環境沒有 `PACK_LAUNCHER_HANDLES_SELF_UPDATE=1` 且存在 pending 時，才等待舊 launcher 退出並替換根目錄 EXE。它只接受 Temp／config 下、名稱為 `launcher_update_*.exe`、具有 MZ 標頭且大小合理的檔案；v4.42 黏接 marker 只能採用最後一個語法候選，最後候選遺失／越界即失敗，不可退回較舊 EXE 卻標成新版本。來源、candidate 與安裝後 target 必須 SHA256 相同；若有 pending SHA 也必須吻合。上次中斷留下的 `.pre_update.bak` 必須先驗證並還原，失敗 rollback 要明確記錄 `restored／FAILED`；不可操作任意路徑。
- v4.43+ launcher 啟動 payload 前會設定 `PACK_LAUNCHER_HANDLES_SELF_UPDATE=1`，避免 launcher helper 與 payload bootstrap 同時競爭同一個 EXE。

### 3.17 網路資料夾瀏覽與即時診斷
- 主流程以管理員權限執行，通常看不到一般使用者的映射磁碟。主要選擇器為 `payload/FolderPickerHelper.ahk`，由桌面 Explorer 以一般權限啟動；它主動彙整目前權杖映射、WScript.Network、`HKCU\Network` 持久映射及檔案總管 Network Shortcuts，再把結果轉成 UNC 回傳。
- 選擇器預設顯示「這台電腦」，並固定提供「瀏覽網路」及「直接輸入 UNC」，不再依賴 Windows 對話框左側欄。根目錄 launcher 的 `--pick-folder` 只作 helper 遺失時的後備，且固定從 CSIDL_DRIVES 開始。
- Launcher 維持 `#SingleInstance Off`，正式主流程改由「完整 EXE 路徑雜湊」命名的 mutex 防止重複啟動，不可恢復成會關掉 helper 的 `#SingleInstance Force`。
- 設定頁可立即做建立、寫入、讀回及刪除測試；執行時仍採本機優先，目的端暫時離線只記錄補傳等待，不中止錄影。
- 即時診斷預設每 60 秒以 ImagePut 擷取低畫質 JPEG；所有主程式／子流程產生的圖片集中到 `<程式根目錄>\診斷快照`，OCR 暫存圖位於其下 `暫存` 且使用後刪除，啟動時會搬移舊 `%LOCALAPPDATA%\WutheringAuto\diagnostics` 圖片並清除超過 24 小時的殘留暫存。`latest.jpg` 原子覆寫；WARN／ERROR 仍依設定保留固定總份數，但 Firestore 上傳硬性限制最多每 60 秒一次。
- 網路短影片功能目前暫停實作：`video_preview_enabled` 啟動時會強制遷移為 `0`，設定介面不可啟用，網站不顯示影片播放器，`RC_PublishRuntimeVideoPreview()` 也固定拒絕上傳。完整長影片維持本機／UNC 分段錄影與背景收尾，不受影響。舊版 preview FFmpeg marker 判斷保留，只為避免更新交界誤把殘留預覽程序當主錄影。
- Firestore 控制文件為 `ahk_clients/{UID}`；JPEG 放在同集合的 `{UID}__media`。為相容缺少 `docKind` 的舊 client，網頁主查詢使用 `uid != ""`（media 只有 `clientUid`），並只為目前選取裝置訂閱一份 media 文件。正常完整結束會 PATCH client 為 `OFFLINE` 後刪除 media 文件；錯誤、系統關機、強制終止與重啟交接保留最後快照。網頁開啟期間會交易式刪除最後心跳超過 7 天、且再連續觀察 10 分鐘沒有 listener 更新的 client 與 media，避免誤刪時鐘錯誤但仍持續心跳的裝置。
- AHK 命令輪詢至少 10 秒且 GET 只取 `desiredState`／`nonce`；心跳至少 60 秒（預設 90 秒）。心跳、ACK、截圖及錄影背景工具的 PATCH 回應也必須用 response field mask，禁止回傳整份文件。
- 錄影工作階段持久狀態在 `%LOCALAPPDATA%\WutheringAuto\recording_staging\recording_status.ini`，收尾 log 在同層 `recording_worker.log`；控制網頁顯示成功成品、目的端分段及本機失敗保留路徑並提供複製按鈕。
- `RecordingFinalizeWorker.ahk` 必須在主程式已退出後仍直接 PATCH 錄影欄位；網路回報失敗不可影響本機保全，下一次主程式心跳會再從 `recording_status.ini` 補報。
- `WriteStep()` 與警告／錯誤會維護最近 50 筆 runtime events；網頁只以 `textContent` 呈現。快照含桌面內容，部署端必須用 Firestore Rules／Authentication 限制讀取權限。

### 3.18 OCR 模型相容性
- `plugin\RapidOcr\models_zh_hq` 現在使用官方 PP-OCRv4 mobile 中文 det／rec 與 `ppocr_keys_v1.txt`，舊 PP-OCRv3 保留在 `models` 當回退。
- 現有 RapidOcrOnnx 1.2.2 DLL 實測無法初始化 PP-OCRv5 mobile；PP-OCRv4 server 雖可載入但全螢幕單次約 38 秒，不可用於輪詢。v4 mobile 在實際 2560×1440 錄影畫面約 0.65 秒，且能正確讀出舊 v3 誤辨的「設定任務」。
- wrapper 會略過檔名標示 v5／v6 的 ONNX，避免不相容模型使 OCR 初始化崩潰。升級到 v5／v6 必須先一併替換支援新 graph 的 OCR runtime，不可只換模型檔。

## 4) 伺服器排程與完成判定（高風險區）
### 4.1 切日規則（非常重要）
- 一個循環日定義為 04:00 到隔日 03:59。
- 04:00 前的時間會歸到前一個循環日。

### 4.2 完成判定流程
- IsServerCompletedInCurrentCycle 先看記憶體 Map，再看 ini [server_completed]。
- 透過 IsSameDayCircle/GetDayCircleKey 比對是否同一循環日。

### 4.3 常見誤判來源
- 讀到的不是你以為那份 config.ini（路徑來源不同）。
- server_schedule.enabled 沒開或 list 名稱與 key 不一致。
- 時間字串包含全形空白、毫秒或格式差異（已補強解析）。

## 5) 路徑與配置注意事項
- CFG_FILE 來源會受 PACK_DATA_DIR 影響。
- 打包啟動器會設定 PACK_DATA_DIR。
- 若用戶回報「明明 config 有值卻不生效」，先看啟動 log 中 dataDir/CFG_FILE 實際路徑。

## 6) 子腳本關係
- payload/全自動.ahk：主控流程
- payload/FolderPickerHelper.ahk：一般權限網路／映射磁碟／UNC 資料夾選擇器
- payload/RecordingFinalizeWorker.ahk：錄影分段補傳、合併、驗證與安全清理
- payload/開啟LRMC.ahk：啟動並操作 LRMCAI
- payload/自動開啟OKWW.ahk：OKWW 啟動管理
- payload/聲骸合成.ahk：聲骸流程

## 7) 本專案開發注意細節
- AutoHotkey v2 語法，傳參、ComCall、Buffer 使用需嚴格 v2 寫法。
- 盡量保留既有流程時序，避免改動造成觸發條件提前或延後。
- 視窗座標行為需區分 Screen/Client，避免誤點。
- hotkey 模式通常來自重啟/恢復路徑，不一定是手動啟動。
- #SingleInstance Force 會導致同秒二次啟動時前者被 Single 結束。

## 8) 推版流程（維運）
1. 修改腳本後先做語法/錯誤檢查
2. 編譯 payload/全自動.ahk -> payload/全自動鋤地.exe
3. 重建 payload.zip（根層直接放 payload 目錄內容，不可多包一層 payload）
4. 編譯 打包啟動器.ahk -> 根目錄 全自動鋤地.exe（必須在重建 zip 後，才能內嵌最新版 payload.zip）
5. 計算 payload.zip 與根目錄啟動器 EXE 的 SHA256
6. 同時提升 payload 與 launcher 版本，更新 manifest 兩組版本、URL 與 SHA256
7. git commit + push main，讓客戶端能直接取得更新

> 維運約定：以後每次「打包更新」都必須同時重新編譯、升版並發布 Payload 與 Launcher，不可只更新其中一個。

> 品質門檻：每次交付前都要檢查 VS Code「問題」面板並以 0 個問題為目標，同時執行可用的 AHK 編譯／語法與 Web 靜態檢查。若仍有工具誤報或確認不影響執行的診斷，交付時必須列出檔案、診斷內容與不影響理由，不可默默忽略或把非 0 說成 0。

## 9) 本檔用途
- 這份文件提供給接手 AI/開發者快速理解專案脈絡。
- 檔案放在專案根目錄，不放入 payload 目錄，避免隨用戶更新包分發。
