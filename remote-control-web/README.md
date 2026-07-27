# AHK 遠端控制台

## Firebase 設定

在 `app.js` 設定：

- `FIREBASE_CONFIG.apiKey`
- `FIREBASE_CONFIG.authDomain`
- `FIREBASE_CONFIG.projectId`

目前控制台不設登入密碼；開啟頁面後可直接操作。請用 Firestore Rules 或 Firebase Authentication 控制實際存取權限。

## Firestore 資料結構

預設集合是 `ahk_clients`，每台電腦以 AHK UID 作為文件 ID。AHK 會自動寫入心跳、執行狀態與 ACK 欄位。

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
```

`uid` 留空時會由 AHK 在第一次啟動時自動產生。
