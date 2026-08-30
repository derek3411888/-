# 開發產物與路徑規範

本 repository 的專案根目錄是本檔所在資料夾。所有由開發、診斷、測試、編譯、打包或發布流程建立的可管理檔案，都必須位於此根目錄內，不得直接寫入 Windows Temp、使用者 AppData、桌面或其他工作目錄。

## 固定位置

- `.dev-runtime/temp`：每次命令的程序暫存與 stdout/stderr 擷取。
- `.dev-runtime/tests`、`.dev-runtime/node-tests`：AHK、PowerShell 與 Node 測試 fixture／結果。
- `.dev-runtime/npm-cache`、`.dev-runtime/npm-logs`：npm 下載快取與診斷 Log。
- `.dev-runtime/cache`：PowerShell、Node、Python、pip、NuGet 等工具快取。
- `.dev-runtime/build`：非正式的編譯中間產物。
- `.dev-runtime/diagnostics`：開發期間擷取的畫面、影片 frame、contact sheet 與診斷報告。
- repository 根目錄：正式發布的 `payload.zip`、`self-hosted-server.zip`、`全自動鋤地.exe` 與 manifest。

`.dev-runtime` 是可重建資料，因此由 Git 忽略。測試或發布失敗時可以保留該次子目錄供診斷；成功時清除一次性子目錄。

## 強制方式

- `ProjectDevelopmentPaths.ps1` 會為打包／發布子程序設定 repository 內的 `TEMP`、`TMP`、`TMPDIR` 與工具快取環境變數，結束後還原呼叫者環境。
- `self-hosted-server/.npmrc` 與 Node 測試入口會把 npm cache、npm Log、Node 測試暫存與 coverage 固定在 `.dev-runtime`。
- AHK 測試使用 repository 內的測試根，不得直接串接 `A_Temp`。
- 打包前會執行路徑政策測試；發現新的外部開發寫入方式時必須直接失敗，不可只留下警告。
- 開發者或 AI 手動產生的截圖、OCR 中間圖、影片抽幀、比對圖、命令輸出與臨時報告，也必須指定到 `.dev-runtime`，不得另建專案外暫存資料夾。

## 不屬於開發產物的部署資料

以下是正式執行或第三方平台管理的資料，不應為了開發路徑整齊而搬動：

- 使用者明確選擇的外部／網路錄影成品位置。
- 中央正式服務的 D 槽媒體、E 槽備份與 Docker named volumes／image layers。
- 工作排程器使用的 Windows `ProgramData` Codex bridge 安裝與 DPAPI 憑證。
- Git、Docker Desktop、Codex、瀏覽器及 Windows 自身不可由本專案控制的內部資料庫或系統快取。

專案程式不得把上述例外當成開發暫存位置。舊 Temp／AppData 路徑只允許作為唯讀偵測或安全遷移來源。
