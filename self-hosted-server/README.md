# 鳴潮自動鋤地自架控制平台

## 遊戲版本維護（待下一次正式發布）

新版 Payload 將小型 `status.gameMaintenance` 隨原心跳傳入，包含來源、公告時間、等待／更新／需要確認階段與當前目標伺服器。資料上限 4 KiB，不含本機完整安裝路徑、帳密或公告全文；伺服器不替裝置發起更新。

總覽顯示維護卡；設定卡使用原 revision／ACK 管線傳遞 `maintenanceEnabled`、`maintenanceOverrideEventId`、`maintenanceDelayUntilUtc`、`maintenanceSkipEventId`、`maintenanceRefreshRequestId`。伺服器在裝置行鎖內檢查 capability、新鮮度、目前事件與 48 小時延後範圍；未提供欄位保留原值，不因一般設定儲存清空維護意圖。

兩網站共用 `public/game-maintenance-view.js`，已加入 Web 資產 checksum；不增加 Firestore 流量、migration 或資料表。來源無法判定、更新無進展、桌面鎖定、備份恢復不確定時均顯示原因，不把 HTTP 200 當成已套用或遊戲已更新。實際 Steam／Kuro 更新能力需另外完成裝置端實機驗收。

這個資料夾是一套可在常開 Windows 電腦上用 Docker Desktop 執行的中央控制、診斷與直播平台。PostgreSQL 只存控制資料；快照與 Log 預設放在 D 槽可直接管理的 Windows 資料夾，資料庫本體使用 Docker named volume；備份預設獨立放在 E 槽。正式錄影不進中央主機，只保存在各執行端設定的位置。

## 服務與公開連接埠

- `postgres`：PostgreSQL，只有 Compose 內部網路可用。
- `api`：控制 API、手機版網站與 HLS 保護代理，只有 Compose 內部網路可用。
- `mediamtx`：接受裝置端加密 SRT，HLS 埠不公開。
- `caddy`：公開 `TCP 80/443`，自動取得 HTTPS 憑證。
- `backup`：每日與每週備份、實際還原測試工具。

路由器只需轉發到 Docker 主機：

- `TCP 80`、`TCP 443`
- `UDP 8890`

不要公開 PostgreSQL、API 的 3000、MediaMTX 的 8888 或任何管理介面。

網站採用一致的 Apple 風格響應式介面：半透明卡片、分段式頁籤、明確狀態色與輕量進場動畫；系統開啟「減少動態效果」時會停用非必要動畫。頁籤支援滑鼠、觸控與左右方向鍵／Home／End 操作，版面以 1080p 桌面及 390px 手機寬度作為實際驗證基準。

固定公網 IPv4 填入 `.env` 的 `PUBLIC_IP_ADDRESS`。Caddy 會使用 Let's Encrypt 的短效公開 IP 憑證提供主要 HTTPS 入口，例如 `https://203.0.113.10/`；控制 API、GitHub Pages 導向及外網 SRT 都使用這個固定 IP，不依賴 DDNS。`PUBLIC_HOSTNAME` 只保留舊網址相容與憑證入口，不會發布給執行端。

`.env` 的 `LOCAL_SRT_HOST` 應設為 Docker 主機的固定內網 IPv4（目前主機為 `192.168.0.194`）。裝置會優先走內網 SRT，再退回固定公網 IP，避開許多家用路由器只支援 HTTPS、卻不支援 UDP NAT loopback 的情況。安裝工具會自動偵測預設路由所在的 IPv4，也可用 `-LocalSrtHost` 明確指定。

瀏覽器租約仍在最後一次觀看活動後 90 秒失效。裝置端收到的本機 FFmpeg 截止時間會額外保留 600 秒失聯保險，涵蓋長時間被主流程占用及舊版 Payload 更新前的過渡期；Payload 在計時器延遲後會先讀取最新控制狀態再判斷截止時間，避免忙碌流程在每次續租交界重建串流。伺服器一旦明確回報沒有觀看者，Payload 仍會立即停止，不會等待保險時間用完。

## 首次安裝

1. 確認固定公網 IPv4，並在路由器把上述連接埠轉發到這台常開電腦。`PUBLIC_HOSTNAME` 只為舊網址相容保留；新版裝置與主要網站不依賴 DDNS。
2. 安裝並啟動 Docker Desktop（WSL 2 backend）。
3. 準備兩個位置：預設中央快照／Log 為 `D:\WutheringControlServer\data`，資料庫備份為 `E:\WutheringControlBackups`。
4. Docker Desktop 的 PostgreSQL named volume 與容器映像位於 Docker 磁碟映像內。到 **Settings > Resources > Advanced > Disk image location** 將它移到 `D:\DockerDesktopData`，套用並等待 Docker 重啟；安裝工具會檢查，避免資料庫實際仍落在 E 或 C 槽。
5. 在 PowerShell 執行：

```powershell
.\Install-Server.ps1
```

使用符合主機現行執行原則的 PowerShell 環境；若執行遭拒，先處理正式安裝條件，不使用 Bypass 或降低系統執行原則。直接按 Enter 就採用 D 槽資料、E 槽備份。只有在明確接受 Docker named volume 位於其他磁碟時，才使用 `-AllowDockerStorageOutsideDataDrive` 略過防呆；一般安裝不建議略過。

安裝工具會產生 `.env` 密鑰、建立服務、執行 migration、健康檢查、第一次備份與實際還原測試。網站直接開啟即可使用，不需要帳號、密碼或私人啟用連結。伺服器會自動設定 `Secure + HttpOnly + SameSite=Strict` Cookie，僅用來區分各瀏覽器的直播觀看租約，不作為人工驗證步驟。

直接存取模式代表任何知道公開網址的人都能查看狀態並操作控制台；請勿公開分享網址，且仍應只開放 Caddy 的 HTTPS 與必要的 SRT 連接埠。

## 既有兩台裝置與 7 天並行

- 安裝後執行 `Manage-Server.ps1 -Action ImportFirestore`；伺服器會匯入既有 UID、nonce、設定 revision 與實際設定，並把自架網址以 discovery 欄位寫回原 client 文件。
- Payload 自動產生個別裝置 token，以目前 Windows 使用者的 DPAPI 加密保存，不需輸入配對碼。
- `shadow` 期間 Firestore 是唯一命令與設定來源；自架端只接收鏡像心跳、事件、快照與直播租約，網站控制按鈕停用。
- 必須連續 7 天無一致性錯誤、Firestore 命令／設定均已 ACK，且所有匯入裝置都已取得個別憑證，網站才允許切換；正式發布的整合測試會另驗證加密 SRT 到 HLS。
- 切換後 7 天內每 15 分鐘保留一次低頻 Firestore 緊急通道；到期後固定 Firestore 讀寫停止。自架 API 本身仍能把裝置切回 `fallback`。

新電腦第一次啟動 Payload 會直接自動註冊，不需要配對碼或註冊窗口。註冊後仍使用每台裝置各自的隨機憑證呼叫裝置 API，憑證由 Windows DPAPI 加密保存。

新版 Payload 內建固定公網 HTTPS 入口 `https://220.135.218.98` 作為全新安裝預設，因此第三台電腦即使位於不同住家、行動網路或其他外網，也不必先匯入 Firestore。裝置只會主動向中央主機連線：控制與快照使用 TCP 443；直播先嘗試家中 `LOCAL_SRT_HOST`，外網無法到達時自動改用 `PUBLIC_SRT_HOST` 的 UDP 8890。

外部網路若封鎖 UDP 8890，控制、快照與本機正式錄影仍會正常，只有即時畫面無法建立。網站會顯示裝置正在使用的直播路徑及「公網 UDP 可能被封鎖」，不再只顯示無限重新連線。執行端不需要任何入站連接埠；路由器轉發只設在中央 Docker 主機。

## 直播與本機錄影

- 正式錄影固定為單一 MKV，從開始便直接寫入執行端設定的本機、映射磁碟或 UNC 資料夾。
- 不再產生五分鐘分段、中央 HTTPS 上傳、MP4 轉換、背景合併或中央影片回看；`FORMAL_MEDIA_ENABLED` 預設且正式環境固定為 `false`。
- 正常停止會向 FFmpeg 送出 Ctrl+C 並等待最多 30 秒完成 Matroska 索引。指定位置不可寫時只略過本次錄影，鋤地主流程照常執行。
- 網站的診斷頁只顯示目前單一 MKV、指定位置與封口結果；「直播」頁只負責近即時畫面。
- 直播畫質可逐台設定：省流量 `720p/12fps/1.5 Mbps`、預設平衡 `720p/30fps/3.5 Mbps`、流暢 `720p/60fps/6 Mbps`。所有畫質與正式錄影都優先自動選用 NVENC、QSV 或 AMF，無可用硬體編碼器時才回退 libx264，避免錄影完全失敗。
- 各執行端依本機設定保留最近數場；中央主機不保存正式影片。直播快取由 MediaMTX 管理，觀看租約結束後自動停止。

## 效能分析與保留

- Payload 以獨立低優先權背景程序每 2 秒取樣，不會在 AHK 主流程中執行 WMI／GPU 查詢。遊戲 FPS 與 frame time 取自官方 PresentMon 的實際 present 資料；工具下載會先驗證固定 SHA-256，失敗時只顯示無資料，不影響鋤地。
- 採集 CPU、遊戲／OKWW／LRMCAI／FFmpeg 個別 CPU 與記憶體、GPU／VRAM／溫度／功耗／編碼器、RAM、磁碟、網路，以及正式錄影與直播的 FFmpeg fps／丟幀進度。
- 2 秒原始資料只放在執行端 `<程式資料夾>\效能分析` 並保留 24 小時；心跳只把完成的每分鐘彙整送到自架 API，不寫入 Firestore。
- PostgreSQL 效能分鐘資料保留 14 天；同一分鐘採 `(uid, bucket_start)` 原子 upsert，網路重送不會產生重複資料。網站圖上的紅色虛線對應最近錯誤事件，可直接查看故障前後趨勢。
- 診斷頁預設以效能摘要與四張趨勢圖為主；本機單檔錄影位置與封口狀態預設收起，需要時才展開。

## 日常管理與更新

```powershell
.\Manage-Server.ps1 -Action Status
.\Manage-Server.ps1 -Action OpenLogs
.\Manage-Server.ps1 -Action RestoreTest
.\Update-Server.ps1
```

更新工具會先備份，再建立與啟動新版、執行 migration 並等待健康檢查；失敗時把 API 容器回復到上一個映像。容器 Log 使用 10 MB 輪替並保留 15 份。資料庫備份保留每日 14 份、每週 8 份與更新前 5 份。

## Cloudflare Tunnel、同站直連與 Codex 登入

網站與 API 仍由同一組 Caddy／Node／PostgreSQL 提供，不另外建立公司版後端。可設定三個 HTTPS 入口：一般控制站走 named Tunnel、另一個 DNS-only 網址直連 Caddy、獨立 Codex 網址由 Cloudflare Access 保護。只有 Codex／管理功能要求允許帳號登入；一般控制仍可匿名使用。任何知道一般站網址的人仍能操作鋤地控制，這是產品的公開控制模式，不是靠 Docker 或隱藏網址提供身分驗證。

- 在 `.env` 設定 `PUBLIC_URL`、精確列舉的 `ALLOWED_ORIGINS`、`DIRECT_HOSTNAME`；必須保留仍在使用的舊入口，不使用萬用來源。
- 設定 `CLOUDFLARE_ACCESS_ISSUER`、`CLOUDFLARE_ACCESS_AUDIENCE`、`CODEX_ALLOWED_EMAILS`、`CODEX_LOGIN_URL`。issuer 必須是該帳戶的 HTTPS `*.cloudflareaccess.com`，login URL 指向受保護的 Codex 網址。
- Access application 保護整個 Codex hostname，policy 只允許指定帳號。named Tunnel 的 Codex ingress 也驗證 Access；一般控制 hostname 不套互動登入。兩者 origin 都指向 Docker 網路內的 `http://caddy:8080`，最後一條 ingress 為404。
- Tunnel token 放受限 ACL 的本機檔案，`CLOUDFLARED_TOKEN_FILE` 指向它；不放命令列／Git／更新包。`cloudflared` profile 不公開 host port、不使用 host network 或 Docker socket。
- 完成設定及備份後，只部署這個專案需要的服務；不重啟 Docker 引擎或資料庫。連接器使用 `docker compose --profile tunnel up -d --no-deps cloudflared`，API／Caddy 設定更新須按既有 scoped 部署流程套用。
- origin 本身驗證 RS256 JWT 的 issuer、audience、期限及 Email，舊 IP／直連不能繞過 Codex 授權。機器 bearer 與 loopback bridge token 維持獨立；公開 Caddy 路由拒絕 `/internal` 及其子路徑。

一般控制網頁用 SSE 接收事件，隧道須使用支援 SSE 的正式 named Tunnel。即時性仍受裝置回報／命令輪詢頻率影響；只部署網域不會讓舊版腳本自動加速。SRT UDP 直播也不是 HTTP Tunnel 的功能，維持原通道。

部署驗收須分開記錄 HTTPS／SSE、未登入拒絕、允許帳號登入、舊 IP／direct 旁路拒絕及公司實際連通。若網站或兩台腳本尚未移轉完成，不要提前停用一般裝置的 Firestore import／mirror／fallback；既有資料保留。

## 裝置自架獨立模式與 Firestore 退役順序

安裝新版不會自行切換控制權。先用既有 migration readiness／cutover 流程完成中央 `primary`（且未凍結寫入），再於各裝置安全更新點，在既有 `config.ini` 的 `[self_hosted]` 設定 `transport=selfhost_only` 與已驗證的 HTTPS `server_url`。保留原 UID、DPAPI 機器憑證、nonce、claim／ACK、PAUSE／STOP、設定版本及完成清單；不可用清零或重新註冊身分代替移轉。

獨立模式預設每 10 秒回報 heartbeat、每 2 秒查詢命令；可在同區段設定 `heartbeat_interval_ms`（最低 5000）與 `poll_interval_ms`（最低 1000）。舊 `migration` 模式仍維持原 Firestore 額度下限，兩種設定不互相覆寫。請求有總回應期限、失敗退避及非重入保護；ACK 回覆遺失會沿用持久紀錄補送，不重做已套用命令或設定。網站 SSE 可立即轉送收到的變化，但不代表畫面、裝置心跳或命令有零延遲保證。

`selfhost_only` 不讀 Firestore discovery、不再建立 Firebase 設定，也不會因舊 fallback 設定或自架故障切回 Firebase。中央若仍回報 shadow／fallback，裝置保留狀態等待，不採用尚未移交控制權的命令。這項 fail-closed 行為是切換前先驗證中央的原因。

只有所有裝置已完成新 Log、heartbeat、命令／設定 ACK、快照及預期任務進度驗收後，才把中央 `SELFHOST_ONLY=true` 與 `FIRESTORE_IMPORT_ENABLED=false` 套用到本專案 API。此時原始 Firestore HTTP、import／mirror／discovery 與回退管理入口都停用。若中央尚未 primary 或 writesFrozen，回報 `SELFHOST_CUTOVER_REQUIRED`，不擅改資料庫 epoch／游標；必須先完成原遷移程序。舊資料與憑證保留，不刪除 Firebase 專案。這些設定說明不表示任何實機已完成移轉。

## 通知目前 Codex 任務

一般控制頁點選 Codex 會前往固定的 Access 登入網址，不把 token 放入 URL。登入後由同一後端的 PostgreSQL 中央佇列接收請求，不再經 Firestore 傳送 Codex 訊息。舊公司頁的 Codex 入口只導向新站；一般裝置 Firestore 通道的退役另依移轉驗收處理。

Windows bridge 將請求持久保存到指定的既有 Codex 聊天，取消、來源間隔與本機 journal 避免重複投遞。它不建立新的聊天。第一次在 Docker 主機安裝時，從 Codex 聊天資訊取得 UUID，執行：

```powershell
pwsh -NoProfile -File .\windows\Install-CodexSupportBridge.ps1 -ThreadId '你的-Codex-任務-UUID' -Workspace 'E:\Downloads\一鍵啟動鋤地腳本'
```

安裝工具驗證中央 loopback API、本機 Codex CLI 與工作區，將 bridge、watchdog 與 bootstrap 放到 Task Scheduler 可見的 ProgramData。`FirestoreSupportEnabled` 預設 false，缺少也視為停用；舊設定仍需明確遷移為 false。此開關同時封鎖 Firestore 收件、舊 in-flight 恢復與回覆寫入，不會清除 journal。只有顯式 legacy opt-in 才驗證及啟用 Firestore，正式新站不可再開啟這條未登入的 Codex 入口。

設定保留穩定 dispatcher ID。安裝器遇到進行中的 queue worker 會延後，不強制終止它；原主 bridge 與 watchdog 才在精確路徑核對後更新。Log／設定位於 `%ProgramData%\WutheringAutomation\CodexSupportBridge`，ACL 僅允許目前使用者與 SYSTEM。所有啟動都遵循現行 ExecutionPolicy；安裝器、排程 bootstrap、watchdog 與 bridge 統一使用 PowerShell 7（新裝從 PATH 尋找 `pwsh.exe`，更新沿用 `BridgePowerShellPath`，不存在或不是 PS7 時停止，不回退 PS5.1）。`CodexSupportBootstrap.ps1 -ValidateOnly` 只驗證 bootstrap/watchdog 設定、不啟動 bridge；仍須另外以真正排程啟動、新 Log 與中央橋接心跳驗收。移除時執行 `windows\Uninstall-CodexSupportBridge.ps1`。

新版網站使用 `QUEUE_MESSAGE_V1`，提供三種預設訊息及最多 1,000 字元的自訂訊息，也可選擇一台裝置並附上經截斷、遮蔽敏感字串的最近 Log。橋接端會再次檢查動作、長度、空白與控制字元，並相容舊版 `FIX_SCRIPT`。Codex task ID 仍只存在主機本機。網頁會顯示收到、驗證、嘗試、重試與排入時間、嘗試次數、訊息 SHA-256 指紋及錯誤代碼；尚未開始送出的請求可取消，失敗或安全判定卡住的請求會以新 nonce 重送；「已排入」不會被描述成 Codex 已完成。自架網站只在載入時讀取一次，開啟對話框後才以 3～15 秒間隔查詢；橋接主機每 90 秒回報心跳，兩次成功排入至少間隔 5 分鐘。

請勿在自訂訊息中輸入密碼、金鑰或其他敏感資料。橋接 Log 只記錄 nonce、長度、指紋與結果，不記錄訊息本文。

Bridge 3.5.0 將入列與實際執行分開：短暫 stdio App Server 只讀取歷史、查詢及保存持久佇列，不呼叫 `thread/resume` 或 `thread/queue/start`，模型執行由原生 Codex Desktop owner 負責。舊 `-QueueWorker` 入口明確拒絕；目前 API 可在同一 submission ID 下更新內容，卻不提供 expected hash/revision 的原子啟動契約，橋接不可用先查再啟動冒充安全驗證。這是自動喚醒功能的限制，並不代表原生桌面自動執行已通過實測。

佇列 ACK 對應 `WAITING`，相符訊息的真實 Turn 才對應 `IN_PROGRESS`。有限頁 history／queue 找不到項目，或暫時 reader 回報 interrupted／failed，不構成允許重送的證據；中斷須有本機對應 Turn 的終局紀錄。傳送前連線錯誤最多自動嘗試3次；送出結果不明時保留狀態，不重送。標準輸入輸出固定無 BOM UTF-8，JSONL 增量游標保留第一筆新紀錄，回覆同步失敗保留快取。實際網站送達、原生聊天起跑及回覆同步必須另外驗收，不能以測試或 ACK 代替。

專案根目錄的 `完整發布更新.ps1` 是正式發布唯一入口；舊的 `編譯打包.bat` 也只會呼叫它。它會強制同次產生 Launcher、Payload、網站與 Docker 套件，推送 GitHub 後等待遠端 manifest 與雜湊一致，再從遠端套件部署 Docker、核對公開網站版本並執行控制／正式影片停用／直播整合測試。任何一段失敗都不會顯示「完整發布完成」。

## 驗證

所有 Node/npm 開發產物固定放在 repository 根目錄的 `.dev-runtime`：

- Node 測試 fixture 與程序暫存：`.dev-runtime/node-tests`
- npm 套件下載快取：`.dev-runtime/npm-cache`
- npm 診斷 Log：`.dev-runtime/npm-logs`（最多 15 份）
- 額外啟用的 V8 raw coverage：`.dev-runtime/node-coverage`
- 直接在主機執行 Node 伺服器時的本機資料：`.dev-runtime/self-hosted-runtime`

`npm test` 會先把 `TEMP`、`TMP`、`TMPDIR`、Node cache 與 REPL history 指向上述範圍，再啟動測試；路徑防回歸測試也會實際執行 `npm config get cache`／`logs-dir`，拒絕落到使用者 AppData 或系統 Temp。正式 Docker runtime 的 D 槽資料、E 槽備份、Docker named volumes 與 Windows bridge 的 ProgramData 則屬部署資料，不是開發產物，維持原設計。

```powershell
npm.cmd install
npm.cmd run check
npm.cmd test
docker compose --env-file .env -f compose.yml config --quiet
```

`test/integration-smoke.mjs` 供完整測試環境驗證註冊、命令、ACK、設定、快照、中央錄影 API 拒絕上傳／播放，以及加密 SRT 到 HLS 的整條鏈路。

部署 smoke 不使用真實 Access 憑證：匿名 Codex/admin 請求必須回 401；登入後的輸入與 CSRF 檢查由隔離 HTTP 測試搭配測試簽章驗證。真實登入／公司網路及兩台裝置移轉仍須分別驗收。
伺服器 ZIP 排除 `secrets/`，安裝端亦在解壓前拒絕含此目錄的套件。更新既有 Windows bridge 時，即使外層更新器是 PS5.1，也會驗證設定的 PS7 並以正常 `-File` 啟動專用更新入口；只傳設定檔路徑，不把憑證放在命令列，不改 ExecutionPolicy。
