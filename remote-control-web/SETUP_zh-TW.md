# Firebase 接線說明（ww-control-a3988）

目前已幫你先填好：
- projectId = ww-control-a3988
- authDomain = ww-control-a3988.firebaseapp.com

控制台目前不使用網頁登入密碼或共享密鑰，開啟後可直接操作。

## 你要做的事

### 1. 在 Firebase 建立 Web App
進到 Firebase 主控台：
- 專案設定
- 一般
- 你的應用程式
- 新增應用程式
- 選 Web（</>）

建立後你會看到 Firebase SDK 設定，裡面會有：
- apiKey
- authDomain
- projectId

### 2. 把 Web API key 填到這 2 個檔案
檔案一：remote-control-web/app.js
要改：
- FIREBASE_CONFIG.apiKey

檔案二：payload/remote_control.ini.example
要改：
- api_key=YOUR_WEB_API_KEY

### 3. AHK 遠端控制設定
檔案：config.ini（實際執行檔會讀這個，不是 example）
新增：

[remote_control]
enabled=1
project_id=ww-control-a3988
api_key=你的 Web API key
collection=ahk_clients
display_name=客廳電腦
heartbeat_interval_ms=90000
poll_interval_ms=10000
http_timeout_ms=2500
clear_snapshot_on_clean_exit=1
last_nonce=0
last_settings_seen_revision=0
applied_settings_revision=0

### 4. Firestore 建議先用這個集合
- ahk_clients

每台 client 啟動後，會自動寫一筆 document：
- 文件 ID：A_ComputerName + MAC
- 欄位包含：displayName、computerName、status、lastHeartbeat、desiredState、nonce、lastAckNonce、serverScheduleEnabled、serverScheduleJson

### 5. 先測試
1. 開 AHK 主程式
2. 去 Firestore 看 ahk_clients 是否出現文件
3. 打開 remote-control-web/index.html
4. 選電腦後送 RUN / PAUSE
5. 若程式已啟用至少 2 個伺服器的排程，確認網頁的「跳下一個伺服器」選單會依設定順序顯示；否則應顯示「無設定」。
6. 更新到支援 `remoteSettingsSchemaVersion=1` 的 Payload 後，進入「設定」頁調整一個非敏感欄位並儲存；確認畫面依序顯示「已送出／等待 ACK／已套用」或「已儲存，下次流程採用」。

正常完整結束只會刪除雲端最新快照，電腦仍以 `OFFLINE` 顯示。控制網站開啟時，最後心跳超過 7 天且再觀察 10 分鐘沒有更新的裝置，會連同 `UID__media` 一起自動刪除。

## 免費額度注意事項

- 遠端設定不新增 collection、listener 或輪詢 timer，設定資料直接放在既有 client 文件。
- 每次儲存通常使用 transaction 1 read + 1 write，client 再回 1 次 ACK write；若碰到心跳同時更新，transaction 可能自動重試。
- 目前兩台全天裝置的固定 10 秒輪詢約 17,280 reads/day；90 秒心跳加 60 秒快照上限約 4,800 writes/day，低於 Firestore Standard 免費層的 50,000 reads/day 與 20,000 writes/day。
- 網頁只在「總覽」且分頁可見時訂閱一台裝置的 media 文件，背景分頁會取消訂閱；快照單張硬上限 140,000 字元。不要長時間同時開多個可見總覽分頁。新增裝置或縮短間隔前必須重新估算。
- 最新限制請看 [Firebase 官方 Firestore 免費額度](https://firebase.google.com/docs/firestore/pricing#free-quota)。

## 現在已經幫你預填的檔案
- remote-control-web/app.js
- payload/remote_control.ini.example

## 目前直接可測
1. Web API key 已填進範例檔
2. 控制台不設密碼；請以 Firestore Rules 或 Firebase Authentication 決定誰可以存取。
