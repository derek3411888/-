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
- 達上限時會先停止崩潰監看、清除重啟旗標並呼叫受管 FFmpeg 保底停錄，完成後才退出，避免錄影程序殘留或影片遭外力中止。

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
- 啟動 `自動開啟OKWW.ahk` 後，最多等待 45 秒，只接受由 `pythonw.exe` 承載的最終主視窗；標題同時相容 `OK-WW v版本 Global`（v3.5.18）及尾端帶 `- OK-WW` 的舊格式。
- 同一個 HWND 必須連續確認兩次才算穩定。之後以 OKWW client 截圖做嚴格 OCR：先把 RapidOCR 可能混用的 `实／實、时／時、触／觸、发／發、动／動、战／戰、斗／鬥、启／啟` 統一。左側導覽項目限定在 `rect.right <= 180 × DPI scale` 的區域內，優先精確接受 `實時觸發` 或 `即時觸發`；精確文字不存在時，才允許等長且只有一個字不同的受限容錯（例如 `即時網發` 對應 `即時觸發`）。此容錯只用於左側導覽，進入頁面後仍以「自動戰鬥」文字所在列為基準，只接受同列精確的「已啟用／未啟用」狀態。未啟用才點開，且必須連續兩次 OCR 確認已啟用才繼續。這裡不使用主題敏感的像素亮度門檻。
- 自動戰鬥確認成功後只送出一次 `F11`。優先切到前景以 `SendEvent` 發送，無法切前景時才以 `ControlSend` 定向發送；送出後等待 2 秒，再最小化 OKWW。
- 自動戰鬥前置確認最多在同一個 OKWW 視窗重試 3 次。只有 F11 成功才最小化；失敗時保留視窗與左側 OCR 候選文字供診斷。
- 兩個呼叫端都必須接收 `StartOKWWFlow()` 回傳值；失敗時依階段使用 `OKWW_MANAGER_LAUNCH_FAILED`、`OKWW_FINAL_WINDOW_TIMEOUT`、`OKWW_AUTOBATTLE_CHECK_FAILED` 或 `OKWW_F11_SEND_FAILED` 記錄重啟，不得繼續等待主畫面後誤報 `GAME_READY_CHECK_TIMEOUT`。

### 3.13 鳴潮前景與置頂原則
- 一般 OCR 與模板輪詢均使用 ImagePut 的 `PrintWindow + PW_CLIENTONLY` 背景 client 截圖，不因輪詢而 `WinActivate` 或將鳴潮設為置頂。
- 啟動階段將鳴潮移到右上角時，普通視窗只調整 X/Y，不傳入寬高，也不執行 `WinRestore` 或 `WinActivate`；移動後需驗證尺寸與視窗狀態不變。最大化視窗保持最大化並略過移動，最小化視窗保持最小化並延後重試。
- `WaitEscMenuOCR()` 的 `icon_main.png` 驗證使用背景截圖右下 ROI；即使鳴潮被其他視窗遮住，也不應搶回前景。
- 登入／叉叉等模板預搜尋也預設走背景 client 比對。只有確定命中並準備實際滑鼠點擊時，才短暫還原、啟用及置頂鳴潮；`finally` 必須保證取消置頂。
- 保留原本登入 OCR 主迴圈每秒呼叫 `TryAssistLoginTemplateBeforeOcr()` 的輔助點擊，也保留兩個 OKWW 啟動入口前的 `登入.png` 點擊；這些搜尋仍先走背景比對，只有模板命中並實際點擊時才短暫切到前景。

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

## 9) 本檔用途
- 這份文件提供給接手 AI/開發者快速理解專案脈絡。
- 檔案放在專案根目錄，不放入 payload 目錄，避免隨用戶更新包分發。
