# 鳴潮自動鋤地專案

這裡是開發與發布用的專案資料夾，不是正式執行端的錄影、設定或 Log 資料夾。整理檔案時先看下列分類，不要依副檔名把所有 EXE、ZIP 或 Log 一次刪掉。

## 從這裡開始

- [自架伺服器說明](self-hosted-server/README.md)
- [公司版遠端控制網站說明](remote-control-web/README.md)
- [網站回報故障時的人工救援](WEB_WORK_EMERGENCY_REPAIR.md)

開發日記、AI 交接、主機設定、內部驗收與歷史操作紀錄僅留本機，不隨 GitHub 發布。公開版本說明位於 `docs/releases/`。

## 資料夾用途

| 位置 | 用途 | 整理原則 |
| --- | --- | --- |
| `payload/` | 主程式、子腳本、圖像模板與執行依賴 | 原始碼與執行資源，保留既有路徑 |
| `self-hosted-server/` | Docker、API、中央網站與橋接 | 不移動設定、部署資料或憑證 |
| `remote-control-web/` | GitHub Pages 公司版網站 | 正式網站來源，不能當暫存清掉 |
| `測試/`、`文字識別/`、`郵件測試/` | 測試原始碼與人工測試工具 | 不是測試輸出；保留使用者未提交的檔案 |
| `docs/` | 公開版本說明；內部文件另行忽略 | `docs/archive/` 與 `docs/superpowers/` 僅留本機 |
| `.dev-runtime/` | 開發期間產生的資料 | 按下方分類管理，不可整包刪除 |
| `.venv/`、`.vscode/`、`.github/`、`.superpowers/`、`.git/` | 工具、編輯器、CI、工作紀錄與版本控制 | 不屬於一般清理範圍 |

### 開發資料只放這裡

```text
.dev-runtime/
├─ temp/                      每次命令的暫存；清理前檢查使用中程序和目錄連結
├─ tests/、node-tests/        測試輸出與 fixture
│  └─ archive-20260925/       已結束的舊人工測試資料
├─ build/                     非正式編譯產物，打包時可能重新建立
├─ diagnostics/              截圖、分析、Log 與歷史驗證證據
│  ├─ legacy-codex-202608/    原 .codex_tmp 的非空輸出和舊實測證據
│  └─ releases/5.03/          5.03 建置紀錄及驗證程式的文字歸檔
├─ backups/                   更新回復備份與 recovered 資料，不自動清除
├─ cache/、npm-cache/         開發工具快取
├─ npm-logs/                  套件工具 Log
└─ runtime/、ui-preview/、ui-qa-deps/  現有開發工具與相依環境
```

`build/` 等可重建目錄沒有內容時可以不存在，不需要為了目錄樹預先建立空資料夾。歸檔不是刪除，也不代表釋放了磁碟空間。

## 根目錄哪些檔案不能搬走

以下位置已被打包、更新或下載網址使用，保留在根目錄：

- 正式發布：`全自動鋤地.exe`、`payload.zip`、`self-hosted-server.zip`、`update_manifest.example.json`。
- 打包入口：`打包啟動器.ahk`、`打包更新.ps1`、`完整發布更新.ps1`、`編譯打包.bat`。
- 共用工具：`AutoHotkey64.exe`、`ProjectDevelopmentPaths.ps1`、`LauncherProcessCleanupPolicy.ahk`。
- 公開網站救援文件與 `ReleaseRepositoryPolicy.ps1`：保留文件與發布檢查入口。

根目錄不再新增一次性測試副本、抽幀、截圖或 `*.out`。舊版產生的 `打包啟動器_fallback.log` 已歸入診斷區，正式安裝端的 Log 與錄影不在本次整理範圍。

## GitHub 發布邊界

`.gitignore` 排除本機日記、AI 指令、編輯器／遠端 worker 設定及診斷產物。已追蹤的內部檔案須用 `git rm --cached -- <精確路徑>` 取消追蹤，這不會刪除本機副本。

`完整發布更新.ps1` 會在提交前檢查整個 Git 暫存區，推送前再檢查 HEAD 的檔案樹；即使以 `git add -f` 加入已列管的本機資料，也會阻止正式發布。手動發布亦須先執行同一檢查；這不是 GitHub 端的全域攔截器。

```powershell
. ./ReleaseRepositoryPolicy.ps1
Assert-ReleaseRepositoryPrivacy -ProjectRoot $PWD.Path
Assert-ReleaseRepositoryPrivacy -ProjectRoot $PWD.Path -Revision HEAD
```

回歸測試：`測試/ReleaseRepositoryPolicyTest.ps1`。產品原始碼、測試程式、公開說明與必要更新 EXE／ZIP／manifest 仍可發布。移除目前分支的檔案不會抹除過去 Git 歷史。
