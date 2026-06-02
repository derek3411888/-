# Firebase 接線說明（ww-control-a3988）

目前已幫你先填好：
- projectId = ww-control-a3988
- authDomain = ww-control-a3988.firebaseapp.com

## 目前預設值
1. CONTROL_PASSWORD = okww-control-2026
2. CONTROL_SECRET = ww-control-a3988-shared-2026

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

### 3. 控制密碼與共享密鑰
檔案：remote-control-web/app.js
目前已先設成：
- CONTROL_PASSWORD = "okww-control-2026"
- CONTROL_SECRET = "ww-control-a3988-shared-2026"

你可以先直接測，之後再自行改掉。

檔案：config.ini（實際執行檔會讀這個，不是 example）
新增：

[remote_control]
enabled=1
project_id=ww-control-a3988
api_key=你的 Web API key
collection=ahk_clients
display_name=客廳電腦
control_secret=ww-control-a3988-shared-2026
heartbeat_interval_ms=30000
poll_interval_ms=5000
http_timeout_ms=2500
delete_on_exit=0
last_nonce=0

### 4. Firestore 建議先用這個集合
- ahk_clients

每台 client 啟動後，會自動寫一筆 document：
- 文件 ID：A_ComputerName + MAC
- 欄位包含：displayName、computerName、status、lastHeartbeat、desiredState、nonce、lastAckNonce

### 5. 先測試
1. 開 AHK 主程式
2. 去 Firestore 看 ahk_clients 是否出現文件
3. 打開 remote-control-web/index.html
4. 輸入 CONTROL_PASSWORD
5. 選電腦後送 RUN / PAUSE

## 現在已經幫你預填的檔案
- remote-control-web/app.js
- payload/remote_control.ini.example

## 目前直接可測
1. Web API key 已填進範例檔
2. 網頁密碼：okww-control-2026
3. 共享密鑰：ww-control-a3988-shared-2026

建議先測通，再改成你自己的密碼。
