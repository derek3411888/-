# AHK 遠端控制台

## Firebase 設定

在 `app.js` 設定：

- `FIREBASE_CONFIG.apiKey`
- `FIREBASE_CONFIG.authDomain`
- `FIREBASE_CONFIG.projectId`

目前控制台不設登入密碼；開啟頁面後可直接操作。請用 Firestore Rules 或 Firebase Authentication 控制實際存取權限。

## 頁面配置

- 「總覽」：執行控制、指定切換伺服器、命令 ACK 與最新畫面。
- 「診斷記錄」：完整錄影狀態／路徑、最近流程事件與命令歷史。
- 「設定」：可安全遠端同步的執行端設定。

三頁共用固定在上方的裝置選擇列。桌面版的總覽與診斷使用雙欄，窄螢幕與手機會自動堆疊；事件與命令表格在手機上會改成卡片，不需要橫向捲動。

## Firestore 資料結構

預設集合是 `ahk_clients`，每台電腦以 AHK UID 作為文件 ID。AHK 會自動寫入心跳、執行狀態與 ACK 欄位。

新版 client 會寫入低畫質最新畫面、錄影收尾狀態／檔案位置與最近 50 筆流程事件。控制文件使用 UID，畫面改放在同集合的 `UID__media` companion 文件；控制台主查詢使用新舊 client 都具備的非空 `uid`，選定裝置後才監聽該裝置的 media 文件，避免心跳、ACK 與命令輪詢反覆傳輸 JPEG。由於內容可能包含桌面畫面與本機／網路路徑，正式使用前請收緊 Firestore Rules，不要把集合公開給不受信任的使用者。

正常完整結束時，AHK 會將 client 標記為 `OFFLINE` 並刪除該裝置的 `UID__media`，因此網站不再保留最後畫面；錯誤、系統關機、強制終止與流程重啟交接則保留最後畫面供診斷。控制網站開啟期間會自動清理最後心跳超過 7 天的 client 與 media 文件；為避免誤刪時鐘錯誤但仍持續心跳的裝置，候選文件必須再連續 10 分鐘沒有任何 listener 更新才會刪除。

網路短影片目前停用且不會上傳。完整影片仍由錄影背景工具存到設定的本機或 UNC 目的地；網站的錄影狀態卡會顯示成功成品、目的端分段、本機失敗保留位置及 `recording_worker.log`，並提供複製路徑按鈕。

控制台使用 Firestore 即時監聽，只在文件變更時接收新內容；只有停在「總覽」且瀏覽器分頁可見時才訂閱所選裝置的 media 文件，切到背景或其他頁面會立即取消，「立即重讀」只會重新訂閱該文件。AHK 命令輪詢固定至少 10 秒，使用 field mask 只取命令欄位與 `desiredSettings*` 設定欄位；PATCH 回應也使用 field mask。

網頁送出命令時會使用 Firestore `runTransaction`，在同一筆交易內：

1. 讀取目前頂層 `nonce`。
2. 原子遞增 `nonce`。
3. 更新頂層 `desiredState`；切換伺服器時，同時寫入頂層 `requestedServerIndex` 與 `requestedServerName`。
4. 將命令加入父文件的 `commandHistory` 陣列。

`commandHistory` 最多保留最近 30 筆，避免文件無限增長。歷史項目使用以下欄位：

- `commandId`
- `commandNonce`
- `requestedState`
- `targetServerIndex`
- `targetServerName`
- `sentAt`
- `status`
- `ackAt`
- `ackResult`
- `ackDetail`
- `statusUpdatedAt`
- `statusReason`

歷史項目刻意不使用 `nonce` 或 `desiredState` 這兩個精確欄名，避免 AHK 的 Firestore REST 回應解析誤抓巢狀欄位。頂層欄位仍維持原協定，不需要新增子集合，也不需要額外放寬子集合規則。

## ACK 顯示規則

控制台不會在交易完成後直接顯示成功：

- `lastAckNonce` 與命令的 `commandNonce` 相同，而且 `lastAckState` 與 `requestedState` 相同：再依 `lastAckResult` 顯示「已 ACK」或「未執行」。切服命令還要求 ACK 的目標序號與名稱完全相符。
- `lastAckNonce` 已大於命令的 `commandNonce`：顯示「被後續命令跨過」，代表這筆沒有被逐筆 ACK。
- 30 秒後 `lastAckNonce` 仍小於命令的 `commandNonce`：顯示「未回應」。
- 其餘狀況：顯示「等待 ACK」。

控制台開啟期間會把判定結果同步回 `commandHistory`，因此之後仍可查閱已確認的 ACK 時間及失敗原因。

## 網頁切換伺服器

- Client 心跳會以 `serverScheduleEnabled` 與 `serverScheduleJson` 發佈完整排程順序，不增加心跳頻率。
- 排程未啟用或少於 2 個伺服器時，選單顯示「無設定」，按鈕不可用。
- 有多個伺服器時，選單依設定順序顯示，預設選擇目前伺服器的下一個，也可指定其他目標。
- `SWITCH_SERVER` 命令同時帶序號與名稱；網頁交易與 client 都會重新驗證，避免設定變動時跳錯伺服器。
- Client 會先 ACK，再延後關閉現有流程並依選定目標重啟；「無設定」、「設定已變更」、「已是目前伺服器」或忙碌中都會保留在命令歷史。

## 網頁遠端設定

新版 client 以 `remoteSettingsSchemaVersion=1` 宣告支援。網頁把以下非敏感欄位直接寫在原本的 client 文件，不建立設定子集合：

- 伺服器排程開關、清單與順序（最多 10 個，每個名稱最多 80 字元）。
- 最大重啟次數（1～50）。
- 診斷快照開關、間隔（60～600 秒）與本機錯誤圖保留數（5～200）。
- 郵件通知開關。

SMTP 主機、帳號、密碼、收寄件人、程式路徑、本機／UNC 路徑及操作座標都不會上傳。網頁只會讀取 `mailNotifyConfigured` 布林值；本機 SMTP 欄位未完成時，可以遠端停用但不能遠端啟用寄信。

按下儲存後，網頁以 Firestore transaction 建立遞增的 `desiredSettingsRevision`。Client 在啟動與既有命令輪詢中處理它，先用暫存檔驗證並保留精確備份，再替換本機 `config.ini`；處理結果寫入 `lastSettingsAck*`，有效值由 `effectiveSettings*` 回報。離線儲存不依賴 command nonce，裝置下次上線仍會套用。伺服器清單在流程中變更時不切走目前伺服器，從下一次伺服器決策採用新順序。

## Firestore 免費額度保護

截至 2026-08-24，Firestore Standard 免費層為每天 50,000 次文件讀取、20,000 次文件寫入、20,000 次刪除，另有 1 GiB 儲存與每月 10 GiB outbound data transfer；以 [Firebase 官方 Firestore 計費文件](https://firebase.google.com/docs/firestore/pricing#free-quota) 為準。

這次遠端設定沿用原 client 文件、主 listener 與既有 10 秒 poll，不新增固定背景用量。每次按「儲存」通常增加：網頁 transaction 1 read + 1 write，以及裝置設定 ACK 1 write；若 transaction 剛好與心跳衝突，Firestore 可能自動重試。

目前 2 台裝置全天運作的固定排程估算：

- 10 秒 poll：`2 × 8,640 = 17,280 reads/day`。
- 90 秒 heartbeat：`2 × 960 = 1,920 writes/day`。
- 60 秒診斷快照上限：`2 × 1,440 = 2,880 writes/day`。
- 固定寫入合計：`4,800 writes/day`，尚有 15,200 次寫入餘裕供流程事件、命令、ACK 與少量設定儲存。

網頁 listener 的讀取量取決於同時可見的控制台分頁數。設計基準是 2 台裝置加 1 個可見控制台分頁；media 單張上傳硬上限為 140,000 字元，超過 125,000 字元會先縮成 400px，仍超限就略過，因此單一可見總覽即使全天開啟也對每月 10 GiB outbound 留有餘裕。不要長時間同時開多個「總覽」分頁。增加裝置、縮短既有間隔或新增 listener 前必須重新估算，不能只看設定功能本身。

## 本機執行與部署

可直接開啟 `index.html` 測試。正式使用時，將此資料夾部署到 GitHub Pages，並更新 `index.html` 的 `app.js` 快取版本字串。

## AHK `config.ini` 範例

```ini
[remote_control]
enabled=1
project_id=YOUR_PROJECT_ID
api_key=YOUR_API_KEY
collection=ahk_clients
display_name=客廳電腦
heartbeat_interval_ms=90000
poll_interval_ms=10000
http_timeout_ms=2500
clear_snapshot_on_clean_exit=1
last_settings_seen_revision=0
applied_settings_revision=0

[runtime_diagnostics]
enabled=1
snapshot_interval_sec=60
error_keep_count=30
video_preview_enabled=0

[restart_tracking]
max_restart_count=10
```

`uid` 留空時會由 AHK 在第一次啟動時自動產生。
本機圖片統一放在 `<程式資料夾>\診斷快照`；舊版 `%LOCALAPPDATA%\WutheringAuto\diagnostics` 圖片會在下次啟動時搬入。
