# AHK Remote Control Web (Firestore MVP)

## 1) Fill Firebase config
Edit `app.js`:
- `FIREBASE_CONFIG.apiKey`
- `FIREBASE_CONFIG.authDomain`
- `FIREBASE_CONFIG.projectId`

目前控制台不設登入密碼；開啟頁面後可直接操作。請用 Firestore Rules 或 Firebase Authentication 控制實際存取權限。

## 2) Firestore collection
Default collection: `ahk_clients`
Each client doc ID is AHK UID. Required fields are auto-written by AHK.

## 3) Run locally
Open `index.html` directly for quick test.

## 4) Deploy to GitHub Pages
Push this folder and configure Pages root.

## 5) AHK config.ini sample
Add section in `config.ini`:

[remote_control]
enabled=1
project_id=YOUR_PROJECT_ID
api_key=YOUR_API_KEY
collection=ahk_clients
display_name=客廳電腦
heartbeat_interval_ms=30000
poll_interval_ms=5000
http_timeout_ms=2500

`uid` is auto-generated on first run if empty.
