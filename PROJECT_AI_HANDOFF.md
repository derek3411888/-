# 一鍵啟動鋤地腳本：AI 接手速覽

## 1) 專案目的
本專案是 AutoHotkey v2 自動化流程，核心目標是：
- 啟動並維護鳴潮流程
- 協調 LRMCAI、OKWW、聲骸合成等子腳本
- 透過 OCR/模板判定流程狀態
- 進行收尾監測、重啟恢復、伺服器排程與完成記錄

## 2) 目前主流程重點（payload/全自動.ahk）
- 啟動前：
  - CFG_FILE 唯一正式位置為 `<程式根目錄>\config\config.ini`；舊 Temp 設定只作一次性驗證搬移，不再作執行後備
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
- 錄影預設每 5 分鐘寫入本機 `<程式根目錄>\操作過程\錄影暫存` 的獨立 MKV 分段。進行中只補傳已封口分段，不直接把尚在寫入的檔案放到網路分享。
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
- 自動戰鬥確認成功後只嘗試注入一次 `F11`。主程式會先保存既有 final 的 `PID+HWND` 快照，再以唯一 nonce、runtime 暫存回報路徑與共同的 `GetTickCount64` absolute deadline 啟動 manager。manager 只有在重新確認 healthy final 後才以 temp→`FileMove` 原子回報 nonce/result/PID/HWND/title/candidateCount；因此本次 manager 明確接手的既有 final 可以使用，沒有合法 handoff 時則只能接受 snapshot 外唯一新 final。兩端都必須重新枚舉所有健康 final（包含 baseline），總數不是 1 一律回 `OKWW_FINAL_WINDOW_AMBIGUOUS`，真正送鍵的 `Critical` 區段再驗一次，不能把 F11 猜送到最大 PID。manager request 以具所有權的 named mutex 依 deadline 排隊，`#SingleInstance` 不得搶殺前一個 nonce；handoff 模式不可顯示選路 GUI／MsgBox，持有全域 mutex 後任何模式都不可進入互動設定。manager 的長等待、OCR 與每個 Run／ProcessClose／WinActivate／MouseClick／Send 副作用前後都要輪詢 deadline/cancel；handoff cleanup 以 per-nonce mutex 與保留到 absolute deadline 後的 cancel tombstone 防止提權換 PID 或舊程序晚寫孤兒檔。
- 最終候選必須可見、啟用、未 DWM cloak、未 hung、沒有 `WS_EX_NOACTIVATE` 且尺寸合理。一般 `WinActivate` 失敗才短暫使用 `AttachThreadInput + BringWindowToTop + SetForegroundWindow`，最後只在 WTS Active、同一 input desktop、`UOI_IO=true` 且實體 Alt 未按下時允許一次 Alt pulse。真正注入 F11 前須在短 `Critical` 內重驗原 PID／視窗身分，且實際 foreground 只接受 exact／same-root；任何 same-root-owner Qt popup／modal 即使同 PID 且尺寸很大也不准接收。F11 以 `SendEvent` down/up 注入，`finally` 保證放鍵；這只能證明在驗證過的前景完成鍵盤注入嘗試，不能宣告 OKWW 已處理。登入入口另以鳴潮主畫面穩定命中作效果後置條件；遊戲原已在主畫面時明確記錄無可觀察效果。禁止再用 `ControlSend` 當成功。前景失敗紀錄必須包含 target/actual foreground 的 HWND、PID、process、class、owner/root、session、elevation、GUI thread、interactive desktop 與各 Win32 API 結果。注入後等待 2 秒立即最小化，並於約 3、7、11 秒非侵入式補掃延遲出現的 OKWW 視窗；最小化只接受 `ok-ww.exe` 的精確升級標題，或 `pythonw.exe + OK-WW v... Global`，不可碰其他 Python。
- 自動戰鬥前置確認只在同一個 OKWW 視窗嘗試 2 次。兩次仍無法確認時，不關閉、不重啟、不再開第二輪 OKWW，直接沿用同一個已鎖定 HWND 送一次 F11。
- 兩個呼叫端都統一走 `StartOKWWFlowWithLocalRecovery()` 並接收結果；此名稱只為相容既有呼叫，現在已不會重啟 OKWW，而是同視窗 F11 降級。未被降級策略成功處理的失敗仍依階段使用 `OKWW_MANAGER_LAUNCH_FAILED`、`OKWW_FINAL_WINDOW_TIMEOUT`，或細分為 `OKWW_F11_TARGET_INVALID`／`OKWW_F11_TARGET_UNUSABLE`／`OKWW_F11_FOREGROUND_FAILED`／`OKWW_F11_FOREGROUND_LOST`／`OKWW_F11_EXCEPTION` 進入原 `RequestRestart()`，不得繼續等待主畫面後誤報 `GAME_READY_CHECK_TIMEOUT`。
- `OKWW_AUTOBATTLE_CHECK_FAILED` 不再觸發舊的局部復原函式；wrapper 只取回同一次流程已穩定鎖定的最終 `pythonw` HWND，做相同的程序名／標題安全檢查後嘗試注入一次 `F11`。通過前景輸入安全條件後會排程最小化並讓主流程繼續，但回傳資料明確拆成 `f11InputAttempted=true`、`f11EffectConfirmed=false`；只有登入入口後續主畫面驗證通過才可把效果視為確認。直接送鍵本身失敗時，才依實際 F11 失敗原因走原 `RequestRestart()`。
- 登入畫面完成 OKWW F11 鍵盤注入後，先以 `WaitEscMenuOCR()` 背景等待主畫面 20 秒；兩次穩定命中必須來自同一 `{HWND, PID, class}`，擷取失敗、身分變更或 HWND 重建都須清空累積。未命中才短暫啟用／置頂鳴潮，對遊戲客戶區正中央送一次實體滑鼠左鍵；點擊前同一 `Critical` 內須再次驗 input desktop、PID、`Client-Win64-Shipping.exe`、`UnrealWindow`、root 與 `WindowFromPoint`，`finally` 立即取消置頂，再背景等待 30 秒。20／30／90 秒期限使用 pause-aware clock，遠端 PAUSE 的時間不能被誤算成逾時；一般 `Sleep()` 以最多 100ms 分片，讓命令輪詢、心跳與 STOP timer 可插入。中心點擊失敗必須當場固化 code/detail（包含 foreground denied、occluded、target changed），不能 30 秒後才讀可能被其他 timer 覆蓋的全域。最小化視窗依 `WINDOWPLACEMENT/WPF_RESTORETOMAXIMIZED` 還原，不得把最大化後最小化的遊戲改成普通尺寸。第二階段仍未命中才觸發重啟；鎖屏、RDP 斷線或非互動 input desktop 時停止 UI 計時器、診斷快照及目前錄影並等待，同時保留遠端輪詢／心跳／STOP。桌面已可互動但目標 hung/disabled/主窗失效時連續 2 次便乾淨重建；單純 foreground-lock 低頻探測約 5 分鐘仍失敗也只做一次不計額度的乾淨重啟，不能永久卡住或消耗 10 次一般重啟額度。遊戲本來已在主畫面的入口仍維持既有 90 秒驗證，不做中心點擊。

### 3.13 鳴潮位置、前景與置頂原則
- 一般 OCR 與模板輪詢均使用 ImagePut 的 `PrintWindow + PW_CLIENTONLY` 背景 client 截圖，不因輪詢而 `WinActivate` 或將鳴潮設為置頂。
- 啟動檢測抓到同一個有效鳴潮主視窗 HWND 連續 2 次後，普通視窗須先定位到「該視窗所在螢幕」工作區右上角；使用 `SetWindowPos` 的 `NOSIZE + NOZORDER + NOACTIVATE + NOOWNERZORDER`，不得改寬高、不得啟用、不得置頂或改變 Z-order。實際位置、原尺寸與視窗狀態全部驗證通過前，登入輔助、OCR 與 OKWW 一律不可繼續。20 秒仍未完成時以 `GAME_WINDOW_POSITION_FAILED` 進入重啟，不可帶錯誤位置往下跑。最大化本身已貼齊工作區，可保留原狀並視為通過；最小化無法驗證位置，必須保持封鎖並重試。
- 除上述一次性位置處理外，程式不得在 OCR／模板輪詢階段主動移動鳴潮視窗，也不得改變其寬高或最大化狀態。只有確實需要鍵鼠輸入且視窗原本最小化時，才依原 `WINDOWPLACEMENT/WPF_RESTORETOMAXIMIZED` 還原；其他時候完全保留使用者版面。
- `WaitEscMenuOCR()` 的 `icon_main.png` 驗證使用背景截圖右下 ROI；即使鳴潮被其他視窗遮住，也不應搶回前景。模板以 1280×720 UI 比例建立，捕獲尺寸不同時先正規化為 1280×720 再比對；已用 2560×1440 與 2560×1400 錄影畫面驗證可命中。
- 登入／叉叉等模板預搜尋也預設走背景 client 比對。只有確定命中並準備實際滑鼠點擊時，才短暫還原、啟用及置頂鳴潮；`finally` 必須保證取消置頂。
- 保留原本登入 OCR 主迴圈每秒呼叫 `TryAssistLoginTemplateBeforeOcr()` 的輔助點擊，也保留兩個 OKWW 啟動入口前的 `登入.png` 點擊；這些搜尋仍先走背景比對，只有模板命中並實際點擊時才短暫切到前景。
- `登入.png` 是帳號被登出時重新登入的備援，不是一般「点击连接」流程，也不是 OKWW 前景失敗的判定依據；不可擴充成 OCR 找到「点击连接」就由主程式直接點擊，正常登入仍交由 OKWW 的 F11 自動登入。
- 遠端 RUN 對 `登入.png` 只做一次背景 client 檢查；沒有命中代表一般狀態，必須立即繼續主畫面驗證，不可把異地登入備援變成 60 秒必經閘門。

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
- 只有 `lastAckNonce == commandNonce` 且 `lastAckState == requestedState` 才能顯示「已 ACK」。`SWITCH_SERVER` 與 `COMPLETE_SERVER` 還必須同時比對 ACK 的目標序號與名稱。30 秒沒有精確 ACK 顯示「未回應」；ACK nonce 已前進則顯示「被後續命令跨過」。
- `SWITCH_SERVER` 與 `COMPLETE_SERVER` 都以同一筆交易寫入頂層 `requestedServerIndex` 與 `requestedServerName`，歷史對應使用 `targetServerIndex` 與 `targetServerName`。Client 必須同時比對序號及名稱，不可只信其中一個。
- Client 心跳以 `serverScheduleEnabled` 與 JSON 字串 `serverScheduleJson` 發佈完整設定順序，不增加心跳頻率。未啟用或少於 2 個時網頁必須顯示「無設定」。
- 切服 callback 必須在 `Critical` 區段先回覆含 `lastAckResult`、`lastAckDetail` 及目標的 ACK，再由延後 timer 停止錄影／關閉流程。失敗回覆顯示「未執行」；`NO_SERVER_CONFIG` 必須顯示「無設定」。
- 網頁不可切入當日已完成的目標。`COMPLETE_SERVER` 會沿用 `[server_completed]` 與 04:00 循環日規則；標記目前伺服器只影響後續排程，不可強制中斷正在執行的流程。所有正常續跑與遠端指定切服都必須略過當日已完成目標；全部完成時不可回頭執行預設伺服器。
- 啟動時不可用雲端頂層 command nonce 直接覆寫本機 `last_nonce`，但每次 GET 必須同時讀取 `lastAckNonce` 並只向前對帳本機游標；若 `lastAckNonce > 當前 command nonce`，視為不一致資料並拒絕推進。Poll 同時會由 timer、`RC_Start()` 與 runtime-ready 入口呼叫，必須用 `RC_POLL_IN_PROGRESS` 阻止重入；`RC_ApplyRemoteState()` 還要在任何 callback／ACK／狀態副作用前，用短 `Critical` 重驗重啟旗標並將完整命令寫入獨立的原子 claim journal（nonce 最後提交），之後才推進本機游標。程序在 callback 前硬崩時，新程序只會在雲端 nonce、state 與切服目標仍完整相符且沒有 durable ACK 時重播；若 callback 已產生完整 pending ACK、但尚未清 claim 就中斷，啟動對帳會以 nonce／state／目標完整比對後清 claim，不可再重播 PAUSE／RUN toggle。較新 nonce 仍採 latest-wins，可明確跨過較舊命令；所有可重播 handler 必須維持冪等，不能宣稱 exactly-once。
- PAUSE／RUN 的 `ACCEPTED` 是「desired state 已原子保存，且本程序已同步軟狀態並排程 LRMCAI 背景 hook」的 durable receipt，不是 F9／Ctrl+F1 已完成證明。重啟／切服接手程序必須先從 `config.ini.remote_desired_state.ini` 恢復 RUN／PAUSE，runtime-ready 前不得啟動 pause-aware `Sleep()` 閘門；雲端較新 nonce 仍可覆蓋。沒有 handoff 參數的正常全新日循環是明確解除舊 PAUSE 的本機 RUN 操作。每個背景 hook 都要攜帶 state／nonce generation，並在 UI 輸入緊鄰的 `Critical` 區段再次核對，較新命令會淘汰舊 hook。UI `SendEvent` 與 journal 無法形成同一交易，崩潰後也無法可靠判定熱鍵是否送達，因此不可將背景 hook 誤稱 exactly-once，亦不可為了補送任意重播可能反向切換狀態的輸入。
- 命令 ACK 先寫入 `config.ini.pending_command_ack.ini` 的同目錄暫存檔，再以 nonce 最後提交並原子替換；command claim、pending ACK、desired state 與 `last_nonce` 的 save/clear/readback 都必須共用同一個依 UID 命名的跨程序 mutex，並在鎖內重讀磁碟。舊 handoff 程序不得覆寫較新 nonce、刪除較新 claim/pending，或把 config 游標倒寫成較小值。HTTP 失敗時由原有 poll／heartbeat／OnExit 重送，不新增固定 timer。雲端 ACK 只有完整匹配 nonce、state、result、detail、serverIndex/name 與 ackAt 才可清除同 nonce pending；較大 nonce 才能直接跨過。ACK PATCH 前的少量 GET 會取得 Firestore 文件 `updateTime`，PATCH 必須帶 `currentDocument.updateTime` precondition；衝突最多做 3 次 conditional PATCH，最後再純 GET 對帳，避免重啟交疊時舊程序倒寫新 ACK。這些額外讀取只在實際有命令 ACK 時發生，不增加全天固定免費額度。
- STOP 不可在 handler 開始前假報完成。收到 STOP 後只保留記憶體中的候選 APPLIED ACK 與 durable claim；`ShutdownGameLrmcOkww()` 必須在錄影封口、程式關閉與通知都完成後呼叫 `RC_MarkActiveStopSideEffectsComplete()`。此 tail marker 必須立即把 terminal ACK durable stage 並清理相符 claim，再由 OnExit／既有 retry 嘗試送雲端，避免 marker 到 `ExitApp` 間硬崩而重播完整關閉副作用；若 durable stage 失敗則保留 claim。Reload、`#SingleInstance`、系統關機或外部 Close 在 marker 前打斷時也必須保留 claim，下一程序才能重新完成關閉。
- 命令歷史只從部署新版網頁後開始建立，無法回補舊版已送出的命令。
- 關閉通知信必須顯示「停止類型」：網頁 `STOP` 為「網頁手動停止」、系統匣「離開腳本（立即）」為「程式手動停止」、收尾監測命中 LRMCAI 日誌為「程式偵測到 Log 後自動停止」。三個入口應明確傳入來源代碼，不可只靠共用旗標事後猜測。

### 3.16 網頁遠端設定與免費額度護欄
- 控制網站分為 `#overview`、`#diagnostics`、`#settings` 三頁，共用 sticky 裝置列；桌面總覽／診斷為雙欄，1180px 以下堆疊，700px 以下事件與命令表格改卡片。所有 grid/card 子項必須保留 `min-width: 0` 與長文字斷行，避免 UNC、log 或 OCR 內容撐出手機寬度。
- 遠端設定 schema 目前為 1。Web transaction 在既有 `ahk_clients/{UID}` 頂層寫入 `desiredSettingsRevision`、`desiredSettingsSchemaVersion` 及 `desiredServerSchedule*`／`desiredMailNotifyEnabled`／`desiredRuntimeDiagnostics*`／`desiredMaxRestartCount`，不可建立設定 collection、subcollection 或另一個 listener。
- Client 必須把遠端設定掛在現有 `RC_FirestoreGetClientDoc()` 的啟動 GET 與 10 秒命令輪詢上，禁止為設定新增 GET timer。`last_settings_seen_revision`、`applied_settings_revision` 與最後 ACK 必須落到本機 `[remote_control]`，讓離線儲存、重啟及 ACK 網路失敗仍可收斂，且同一 rejected revision 不可每 10 秒重寫一次。
- Client 先驗證完整 desired revision，再以 `config.ini.remote_settings_*.tmp` 複製完整本機設定（包含但不外傳 secrets），保存精確 `.remote_settings.bak` 後原子替換；失敗必須回復舊檔並回 ACK。只允許遠端設定伺服器排程／順序、最大重啟數、診斷開關／60～600 秒間隔／5～200 份錯誤圖，以及郵件開關。
- SMTP、收寄件人、程式路徑、錄影位置、UNC 與座標只留本機。雲端只能收到 `mailNotifyConfigured` readiness；本機 SMTP 不完整時只能遠端停用，不能啟用。伺服器最多 10 個、單名最多 80 字；執行中變更只影響下一次伺服器決策，不可半途切服。
- ACK 使用 `lastSettingsAck*`，有效值使用 `effectiveSettings*` 並由同一次 ACK PATCH 帶回；正常心跳再重播本機最後 ACK，不能為 ACK 另加定時器。`APPLIED`、`SAVED_NEXT_RUN`、拒絕原因與離線等待必須在網頁分開呈現。
- Firestore Standard 免費額度（2026-08-24 官方值）為 50,000 reads/day、20,000 writes/day、20,000 deletes/day、1 GiB stored、10 GiB/month outbound。以 2 台全天裝置估算：10 秒 poll 固定 17,280 reads/day；90 秒 heartbeat 1,920 writes/day；60 秒快照上限 2,880 writes/day，固定寫入合計 4,800/day。一次設定儲存通常只增加 transaction 1 read + 1 write 與 client ACK 1 write；交易可能因同文件心跳衝突重試。Media 只能在 `#overview` 且 `document.hidden=false` 時訂閱；單張 data URI 硬上限 140,000 字元，125,000 以上先降成 400px，仍超限則不上傳。新增裝置、縮短間隔、增加 listener 或長期多開總覽前必須重新估算。

### 3.17 Launcher 自我更新與舊版救援
- Launcher 更新檢查與 payload 版本判斷彼此獨立；即使 payload 已是最新版，每次啟動仍須讀取 manifest 檢查 `launcher_version` 與 `launcher_sha256`。
- pending 狀態檔必須以覆寫方式寫入，並依 `version → sha256 → launcher_pending_update.tmp` 的順序提交；禁止再用 `FileAppend`，避免多次下載路徑或版本字串黏在一起。
- 新 launcher 下載後由外部 PowerShell helper 等目前 launcher PID 真正退出，再以 candidate／backup 方式替換。成功後才寫 `launcher_current_version.txt` 並清 pending；任一步失敗都要還原舊 EXE、保留 pending 供下次重試，結果寫入 `launcher_update_outcome.log`。
- 若目前 EXE SHA 已等於 manifest，應補寫版本並清除 stale pending，禁止把舊 pending 套回而降級。版本文字相同但 SHA 不同時，必須重新下載修復，不能只信版本檔。
- Launcher v4.42 的替換器本身有固定等待 2 秒、狀態檔追加寫入及成功分支未寫版本等缺陷，因此 payload 內保留一次性 bootstrap：只有啟動環境沒有 `PACK_LAUNCHER_HANDLES_SELF_UPDATE=1` 且存在 pending 時，才等待舊 launcher 退出並替換根目錄 EXE。它只接受 Temp／config 下、名稱為 `launcher_update_*.exe`、具有 MZ 標頭且大小合理的檔案；v4.42 黏接 marker 只能採用最後一個語法候選，最後候選遺失／越界即失敗，不可退回較舊 EXE 卻標成新版本。來源、candidate 與安裝後 target 必須 SHA256 相同；若有 pending SHA 也必須吻合。上次中斷留下的 `.pre_update.bak` 必須先驗證並還原，失敗 rollback 要明確記錄 `restored／FAILED`；不可操作任意路徑。
- v4.43+ launcher 啟動 payload 前會設定 `PACK_LAUNCHER_HANDLES_SELF_UPDATE=1`，避免 launcher helper 與 payload bootstrap 同時競爭同一個 EXE。

### 3.18 網路資料夾瀏覽與即時診斷
- 主流程以管理員權限執行，通常看不到一般使用者的映射磁碟。主要選擇器為 `payload/FolderPickerHelper.ahk`，由桌面 Explorer 以一般權限啟動；它主動彙整目前權杖映射、WScript.Network、`HKCU\Network` 持久映射及檔案總管 Network Shortcuts，再把結果轉成 UNC 回傳。
- 選擇器預設顯示「這台電腦」，並固定提供「瀏覽網路」及「直接輸入 UNC」，不再依賴 Windows 對話框左側欄。根目錄 launcher 的 `--pick-folder` 只作 helper 遺失時的後備，且固定從 CSIDL_DRIVES 開始。
- Launcher 維持 `#SingleInstance Off`，正式主流程改由「完整 EXE 路徑雜湊」命名的 mutex 防止重複啟動，不可恢復成會關掉 helper 的 `#SingleInstance Force`。
- 設定頁可立即做建立、寫入、讀回及刪除測試；執行時仍採本機優先，目的端暫時離線只記錄補傳等待，不中止錄影。
- 即時診斷預設每 60 秒以 ImagePut 擷取低畫質 JPEG；所有主程式／子流程產生的圖片集中到 `<程式根目錄>\診斷快照`，OCR 暫存圖位於其下 `暫存` 且使用後刪除，啟動時會搬移舊 `%LOCALAPPDATA%\WutheringAuto\diagnostics` 圖片並清除超過 24 小時的殘留暫存。`latest.jpg` 原子覆寫；WARN／ERROR 仍依設定保留固定總份數，但 Firestore 上傳硬性限制最多每 60 秒一次。
- 舊 Firestore Base64「網路短影片」目前停用：`video_preview_enabled` 啟動時會強制遷移為 `0`，舊網站不顯示播放器，`RC_PublishRuntimeVideoPreview()` 也固定拒絕上傳。這不包含自架平台的按需 SRT／HLS 近即時畫面；自架直播使用獨立 FFmpeg marker，也不得被正式錄影接管或停止邏輯誤殺。
- Firestore 控制文件為 `ahk_clients/{UID}`；JPEG 放在同集合的 `{UID}__media`。為相容缺少 `docKind` 的舊 client，網頁主查詢使用 `uid != ""`（media 只有 `clientUid`），並只為目前選取裝置訂閱一份 media 文件。正常完整結束會 PATCH client 為 `OFFLINE` 後刪除 media 文件；錯誤、系統關機、強制終止與重啟交接保留最後快照。網頁開啟期間會交易式刪除最後心跳超過 7 天、且再連續觀察 10 分鐘沒有 listener 更新的 client 與 media，避免誤刪時鐘錯誤但仍持續心跳的裝置。
- AHK 命令輪詢至少 10 秒且 GET 只取命令欄位與 `desiredSettings*` 欄位；心跳至少 60 秒（預設 90 秒）。心跳、命令 ACK、設定 ACK、截圖及錄影背景工具的 PATCH 回應也必須用 response field mask，禁止回傳整份文件。
- 錄影工作階段持久狀態在 `<程式根目錄>\操作過程\錄影暫存\recording_status.ini`，收尾 log 在同層 `recording_worker.log`；控制網頁顯示成功成品、目的端分段及本機失敗保留路徑並提供複製按鈕。舊 LocalAppData 工作階段仍在收尾時只讀相容並繼續恢復，清空後才搬回，不能為了路徑整齊而破壞正在寫入的影片。
- 執行端可管理輸出統一為 `<程式根目錄>\{config,log,診斷快照,效能分析,操作過程,執行暫存}`。相對錄影輸出也以程式根目錄解析；只有使用者明確選擇的外部／網路成品位置例外。Windows DPAPI 憑證、中央 PostgreSQL named volume、D 槽媒體與 E 槽備份屬安全／中央基礎設施，不得誤搬進 Payload。
- `RecordingFinalizeWorker.ahk` 必須在主程式已退出後仍直接 PATCH 錄影欄位；網路回報失敗不可影響本機保全，下一次主程式心跳會再從 `recording_status.ini` 補報。
- `WriteStep()` 與警告／錯誤會維護最近 50 筆 runtime events；網頁只以 `textContent` 呈現。快照含桌面內容，部署端必須用 Firestore Rules／Authentication 限制讀取權限。

### 3.19 OCR 模型相容性
- `plugin\RapidOcr\models_zh_hq` 現在使用官方 PP-OCRv4 mobile 中文 det／rec 與 `ppocr_keys_v1.txt`，舊 PP-OCRv3 保留在 `models` 當回退。
- 現有 RapidOcrOnnx 1.2.2 DLL 實測無法初始化 PP-OCRv5 mobile；PP-OCRv4 server 雖可載入但全螢幕單次約 38 秒，不可用於輪詢。v4 mobile 在實際 2560×1440 錄影畫面約 0.65 秒，且能正確讀出舊 v3 誤辨的「設定任務」。
- wrapper 會略過檔名標示 v5／v6 的 ONNX，避免不相容模型使 OCR 初始化崩潰。升級到 v5／v6 必須先一併替換支援新 graph 的 OCR runtime，不可只換模型檔。

### 3.20 伺服器進度、切換完成提醒與重啟空窗命令
- Client schema 為 5，`serverProgressSchemaVersion=1`。心跳沿用既有 PATCH 發佈循環 key、今日完成清單、目前流程伺服器、切換確認中與上次切換／寄信結果；不得新增固定 Firestore 讀寫頻率。
- 網頁總覽頂端必須醒目顯示目前流程伺服器，並列出每個排程目標的「目前流程／待執行／今日已完成」。`COMPLETE_SERVER` 是 target-aware nonce 命令，需原子寫入歷史並精確比對 ACK 目標。
- 網頁標記完成使用既有 `[server_completed]` 與每日 04:00 循環。標記目前流程不立即停止，後續才略過；全部完成時新程序必須乾淨退出，不可執行已完成目標。
- `nextserver` 新程序會先把切換提醒寫入 `[server_switch_notify]`。只有 `開啟LRMC.ahk` 成功送出 Ctrl+F1 並寫入 `[lrmc_runtime] run_started=1` 後才算切換完成、寄信並清除 pending；失敗／停用也要保存並在網頁顯示結果。
- 程式啟動期間收到的新 nonce 必須排隊到伺服器排程 runtime ready，不可把它當成啟動基準吞掉。完整 claim journal 必須先於 `last_nonce` 與 callback 落盤；中斷後依相同 nonce/state/目標與 durable ACK 決定恢復或跳過。若排隊的 `COMPLETE_SERVER` 標記了剛載入的目前目標，`RefreshServerScheduleAfterStartupCommands()` 必須在主流程開始前重選下一個待執行目標或全部完成後退出；執行中收到完成命令才維持不中斷。


### 3.21 自架 Docker 控制、直播與影片平台
- `self-hosted-server/` 包含 PostgreSQL、Node API/網站、Caddy、MediaMTX、備份與一鍵安裝／更新工具。
- `payload/RemoteControlSelfHost.ahk` 沿用既有 durable nonce／claim／ACK 狀態機；shadow 期間 Firestore 是唯一命令來源，primary 才切換到 PostgreSQL。裝置 token 只存伺服器雜湊，本機以 Windows DPAPI 保存。
- `payload/SelfHostMediaUpload.ps1` 由錄影 worker 呼叫，以 SHA-256、Content-Range 續傳封口 MKV；中央故障不阻塞本機錄影，未完成前不得清除 staging。
- 直播使用獨立 `WUTHERING_RUNTIME_PREVIEW_V1` FFmpeg marker 與加密 SRT；正式錄影掃描會排除它，啟動時只清理由該 marker 識別的孤兒預覽程序。每台可由自架網站選擇 `economy=720p12/1.5Mbps`、預設 `balanced=720p30/3.5Mbps` 或 `smooth=720p60/6Mbps`；所有畫質以及正式錄影都會依序實測 NVENC、QSV、AMF 並優先使用 GPU，只有硬體編碼不可用時才回退 libx264。關鍵影格均為 2 秒。
- 切換門檻會核對 Firestore 命令與設定 ACK、兩端 nonce、一致性錯誤、7 天時間及每台完整錄影。GitHub Pages 固定入口 `https://derek3411888.github.io/-/` 保留公司用 Firestore 控制、快照、效能與 Codex 回報，不轉址；自架完整影片／直播與中央 API 使用 `https://220.135.218.98/`，不依賴 DDNS。primary 模式的每次 device control 回應仍帶 `selfHostedServerUrl/mode/epoch/fallbackUntil`，讓已停止 Firestore 輪詢的舊裝置也能自行從 DDNS 遷移。
- 完整部署、網路埠、備份／還原與維運指令見 `self-hosted-server/README.md`。

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
- payload/RemoteControlSelfHost.ahk：自架 discovery、裝置憑證、命令傳輸、心跳、快照與直播 FFmpeg
- payload/SelfHostMediaUpload.ps1：中央片段 SHA-256／Content-Range 續傳與完成通知
- payload/開啟LRMC.ahk：啟動並操作 LRMCAI
- payload/自動開啟OKWW.ahk：OKWW 啟動管理
- payload/聲骸合成.ahk：聲骸流程

## 7) 本專案開發注意細節
- AutoHotkey v2 語法，傳參、ComCall、Buffer 使用需嚴格 v2 寫法。
- 盡量保留既有流程時序，避免改動造成觸發條件提前或延後。
- 視窗座標行為需區分 Screen/Client，避免誤點。
- hotkey 模式通常來自重啟/恢復路徑，不一定是手動啟動。
- #SingleInstance Force 會導致同秒二次啟動時前者被 Single 結束。
- 所有開發、測試、編譯、打包、診斷與人工分析產物必須放在 repository 內；一次性內容統一使用 `.dev-runtime`。禁止把截圖、影片抽幀、contact sheet、stdout/stderr、測試 fixture 或下載快取寫到 Windows Temp、AppData、桌面或其他專案外資料夾。完整規則見 `DEVELOPMENT_ARTIFACTS.md`。

## 8) 推版流程（維運）
1. 修改腳本後先做語法/錯誤檢查
2. 編譯 payload/全自動.ahk -> payload/全自動鋤地.exe
3. 重建 payload.zip（根層直接放 payload 目錄內容，不可多包一層 payload）
4. 編譯 打包啟動器.ahk -> 根目錄 全自動鋤地.exe（必須在重建 zip 後，才能內嵌最新版 payload.zip）
5. 計算 payload.zip 與根目錄啟動器 EXE 的 SHA256
6. 建立同版 `self-hosted-server` 套件並計算 SHA256
7. 同時提升 payload、launcher 與 server 版本，更新 manifest 三組版本、URL 與 SHA256
8. git commit + push main，讓客戶端與 Docker 主機都能取得更新

> 維運約定：以後每次「打包更新」都必須同時重新編譯、升版並發布 Payload 與 Launcher，不可只更新其中一個。

> 品質門檻：每次交付前以 AHK 編譯／語法、Web 靜態檢查、協定欄位對應與 `git diff --check` 為主。依使用者最新要求，不再為了查看 VS Code「問題」面板而操作使用者桌面或 VS Code UI；除非使用者當次明確要求。若仍有工具誤報或確認不影響執行的診斷，交付時必須列出檔案、診斷內容與不影響理由，不可默默忽略或把非 0 說成 0。

## 9) 本檔用途
- 這份文件提供給接手 AI/開發者快速理解專案脈絡。
- 檔案放在專案根目錄，不放入 payload 目錄，避免隨用戶更新包分發。
