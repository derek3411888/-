# AHK 遠端控制台

## Firebase 設定

在 `app.js` 設定：

- `FIREBASE_CONFIG.apiKey`
- `FIREBASE_CONFIG.authDomain`
- `FIREBASE_CONFIG.projectId`

目前控制台不設登入密碼；開啟頁面後可直接操作。請用 Firestore Rules 或 Firebase Authentication 控制實際存取權限。

## Firestore 資料結構

預設集合是 `ahk_clients`，每台電腦以 AHK UID 作為文件 ID。AHK 會自動寫入心跳、執行狀態與 ACK 欄位。

新版 client 也會寫入低畫質最新畫面、最近 6 秒 MP4 短影片、錄影收尾狀態／檔案位置與最近 50 筆流程事件。畫面與短影片存在同一個 client 文件，定時覆寫而不累積；本機可在設定中停用短影片。由於內容可能包含桌面畫面與本機／網路路徑，正式使用前請收緊 Firestore Rules，不要把集合公開給不受信任的使用者。

短影片預設每 60 秒重新擷取一次，只用來快速確認當下卡在哪裡，不是完整錄影。完整影片仍由錄影背景工具存到設定的本機或 UNC 目的地；網站的錄影狀態卡會顯示成功成品、目的端分段、本機失敗保留位置及 `recording_worker.log`，並提供複製路徑按鈕。

控制台使用 Firestore 即時監聽，只在文件變更時接收新內容；不再每 5 秒重複下載同一張畫面。「立即重讀」仍可手動發出一次完整查詢。

網頁送出命令時會使用 Firestore `runTransaction`，在同一筆交易內：

1. 讀取目前頂層 `nonce`。
2. 原子遞增 `nonce`。
3. 更新頂層 `desiredState`。
4. 將命令加入父文件的 `commandHistory` 陣列。

`commandHistory` 最多保留最近 30 筆，避免文件無限增長。歷史項目使用以下欄位：

- `commandId`
- `commandNonce`
- `requestedState`
- `sentAt`
- `status`
- `ackAt`
- `statusUpdatedAt`
- `statusReason`

歷史項目刻意不使用 `nonce` 或 `desiredState` 這兩個精確欄名，避免 AHK 的 Firestore REST 回應解析誤抓巢狀欄位。頂層欄位仍維持原協定，不需要新增子集合，也不需要額外放寬子集合規則。

## ACK 顯示規則

控制台不會在交易完成後直接顯示成功：

- `lastAckNonce` 與命令的 `commandNonce` 相同，而且 `lastAckState` 與 `requestedState` 相同：顯示「已 ACK」。
- `lastAckNonce` 已大於命令的 `commandNonce`：顯示「被後續命令跨過」，代表這筆沒有被逐筆 ACK。
- 30 秒後 `lastAckNonce` 仍小於命令的 `commandNonce`：顯示「未回應」。
- 其餘狀況：顯示「等待 ACK」。

控制台開啟期間會把判定結果同步回 `commandHistory`，因此之後仍可查閱已確認的 ACK 時間及失敗原因。

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
heartbeat_interval_ms=30000
poll_interval_ms=5000
http_timeout_ms=2500

[runtime_diagnostics]
enabled=1
snapshot_interval_sec=30
error_keep_count=30
video_preview_enabled=1
```

`uid` 留空時會由 AHK 在第一次啟動時自動產生。
