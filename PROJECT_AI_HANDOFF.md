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
- MAX_RESTART_COUNT 目前為 6。

### 3.6 重啟通知信
- 重啟流程會寄送通知信，且內文包含「重啟原因」。

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
3. 重建 payload.zip
4. 計算 payload.zip SHA256
5. 更新 update_manifest.example.json 版本與 payload_sha256
6. git commit + push

## 9) 本檔用途
- 這份文件提供給接手 AI/開發者快速理解專案脈絡。
- 檔案放在專案根目錄，不放入 payload 目錄，避免隨用戶更新包分發。
