# 鳴潮自動鋤地自架控制平台

這個資料夾是一套可在常開 Windows 電腦上用 Docker Desktop 執行的中央控制、診斷、直播與影片回看平台。PostgreSQL 只存索引與控制資料；影片、快照與 Log 預設放在 D 槽可直接管理的 Windows 資料夾，資料庫本體使用 Docker named volume；備份預設獨立放在 E 槽。

## 服務與公開連接埠

- `postgres`：PostgreSQL，只有 Compose 內部網路可用。
- `api`：控制 API、手機版網站、影片處理與 HLS 保護代理，只有 Compose 內部網路可用。
- `mediamtx`：接受裝置端加密 SRT，HLS 埠不公開。
- `caddy`：公開 `TCP 80/443`，自動取得 HTTPS 憑證。
- `backup`：每日與每週備份、實際還原測試工具。

路由器只需轉發到 Docker 主機：

- `TCP 80`、`TCP 443`
- `UDP 8890`

不要公開 PostgreSQL、API 的 3000、MediaMTX 的 8888 或任何管理介面。

`.env` 的 `LOCAL_SRT_HOST` 應設為 Docker 主機的固定內網 IPv4（目前主機為 `192.168.0.194`）。裝置會優先走內網 SRT，再退回 DDNS，避開許多家用路由器只支援 HTTPS、卻不支援 UDP NAT loopback 的情況。安裝工具會自動偵測預設路由所在的 IPv4，也可用 `-LocalSrtHost` 明確指定。

## 首次安裝

1. 在路由器設定 DDNS，並把上述連接埠轉發到這台常開電腦。
2. 安裝並啟動 Docker Desktop（WSL 2 backend）。
3. 準備兩個位置：預設中央影片／快照／Log 為 `D:\WutheringControlServer\data`，資料庫備份為 `E:\WutheringControlBackups`。
4. Docker Desktop 的 PostgreSQL named volume 與容器映像位於 Docker 磁碟映像內。到 **Settings > Resources > Advanced > Disk image location** 將它移到 `D:\DockerDesktopData`，套用並等待 Docker 重啟；安裝工具會檢查，避免資料庫實際仍落在 E 或 C 槽。
5. 在 PowerShell 執行：

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\Install-Server.ps1
```

直接按 Enter 就採用 D 槽資料、E 槽備份。只有在明確接受 Docker named volume 位於其他磁碟時，才使用 `-AllowDockerStorageOutsideDataDrive` 略過防呆；一般安裝不建議略過。

安裝工具會產生 `.env` 密鑰、建立服務、執行 migration、健康檢查、第一次備份與實際還原測試。網站直接開啟即可使用，不需要帳號、密碼或私人啟用連結。伺服器會自動設定 `Secure + HttpOnly + SameSite=Strict` Cookie，僅用來區分各瀏覽器的直播觀看租約，不作為人工驗證步驟。

直接存取模式代表任何知道公開網址的人都能查看狀態並操作控制台；請勿公開分享網址，且仍應只開放 Caddy 的 HTTPS 與必要的 SRT 連接埠。

## 既有兩台裝置與 7 天並行

- 安裝後執行 `Manage-Server.ps1 -Action ImportFirestore`；伺服器會匯入既有 UID、nonce、設定 revision 與實際設定，並把自架網址以 discovery 欄位寫回原 client 文件。
- Payload 自動產生個別裝置 token，以目前 Windows 使用者的 DPAPI 加密保存，不需輸入配對碼。
- `shadow` 期間 Firestore 是唯一命令與設定來源；自架端只接收鏡像心跳、事件、快照、影片與直播租約，網站控制按鈕停用。
- 必須連續 7 天無一致性錯誤、Firestore 命令／設定均已 ACK，而且每台至少有一場完整中央影片，網站才允許切換。
- 切換後 7 天內每 15 分鐘保留一次低頻 Firestore 緊急通道；到期後固定 Firestore 讀寫停止。自架 API 本身仍能把裝置切回 `fallback`。

新電腦第一次啟動 Payload 會直接自動註冊，不需要配對碼或註冊窗口。註冊後仍使用每台裝置各自的隨機憑證呼叫裝置 API，憑證由 Windows DPAPI 加密保存。

## 影片與容量規則

- 執行端仍以每 5 分鐘 MKV 安全封口，本機／網路目的地流程不變。
- 封口片段以 HTTPS、SHA-256 與 1 MiB 可續傳區塊上傳，預設每台 8 Mbps；直播期間降為 2 Mbps。
- 中央以 `-c copy` 轉為 MP4；流程中可以逐段觀看，結束後原子發布單一 MP4。
- 每台保留最近 5 場。中央可用空間低於 20 GB 時，先刪最舊的中央完整副本並產生警示，絕不刪執行端原檔。
- 中央失聯、上傳中斷或轉檔失敗不會阻塞鋤地。本機 staging 會保留並在背景或下次啟動續傳。

## 日常管理與更新

```powershell
.\Manage-Server.ps1 -Action Status
.\Manage-Server.ps1 -Action OpenLogs
.\Manage-Server.ps1 -Action RestoreTest
.\Update-Server.ps1
```

更新工具會先備份，再建立與啟動新版、執行 migration 並等待健康檢查；失敗時把 API 容器回復到上一個映像。容器 Log 使用 10 MB 輪替並保留 15 份。資料庫備份保留每日 14 份、每週 8 份與更新前 5 份。

## 驗證

```powershell
npm.cmd install
npm.cmd run check
npm.cmd test
docker compose --env-file .env -f compose.yml config --quiet
```

`test/integration-smoke.mjs` 供完整測試環境驗證註冊、命令、ACK、設定、快照、MKV 續傳、MP4 Range 播放，以及加密 SRT 到 HLS 的整條鏈路。
