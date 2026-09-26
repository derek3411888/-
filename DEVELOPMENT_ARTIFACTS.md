# 開發產物與路徑規範

本 repository 的專案根目錄是本檔所在資料夾。所有由開發、診斷、測試、編譯、打包或發布流程建立的可管理檔案，都必須位於此根目錄內，不得直接寫入 Windows Temp、使用者 AppData、桌面或其他工作目錄。

## 固定位置

- `.dev-runtime/temp`：每次命令的程序暫存與 stdout/stderr 擷取。
- `.dev-runtime/tests`、`.dev-runtime/node-tests`：AHK、PowerShell 與 Node 測試 fixture／結果。
- `.dev-runtime/npm-cache`、`.dev-runtime/npm-logs`：npm 下載快取與診斷 Log。
- `.dev-runtime/cache`：PowerShell、Node、Python、pip、NuGet 等工具快取。
- `.dev-runtime/build`：非正式的編譯中間產物。
- `.dev-runtime/diagnostics`：開發期間擷取的畫面、影片 frame、contact sheet 與診斷報告。
- `.dev-runtime/diagnostics/releases/<版本>`：每次發布的建置／驗證紀錄；下載驗證副本確認雜湊後可清除，但保留驗證結果。
- `.dev-runtime/backups`：明確標記的更新回復備份與 recovered 資料；不是可自動刪除的暫存。
- `.dev-runtime/tests/archive-<日期>`：已結束的人工測試 fixture，與目前測試輸出分開。
- `.dev-runtime/runtime`、`.dev-runtime/ui-preview`、`.dev-runtime/ui-qa-deps`：現有工具與相依環境，未確認用途前不得刪除或搬移。
- repository 根目錄：正式發布的 `payload.zip`、`self-hosted-server.zip`、`全自動鋤地.exe` 與 manifest。

`.dev-runtime` 由 Git 忽略，但不表示整個資料夾都能刪除：快取與一次性輸出通常可重建，回復備份、歷史診斷證據和工具相依檔則必須分別判斷。測試或發布失敗時可以保留該次子目錄供診斷；成功後只清除已確認無用途、未被使用的一次性子目錄。

## 整理與清理規則

- 根目錄只保留開發／發布固定入口與正式檔案；索引見 `README.md`。不要直接搬動根目錄的 EXE、ZIP、manifest 或打包腳本，它們有固定引用。
- 新增診斷資料使用 `.dev-runtime/diagnostics/<工作名稱>`，不要再新增 `.codex_tmp` 或在 `.dev-runtime` 根層散放日期資料夾。舊 `.codex_tmp` 已歸檔到 `.dev-runtime/diagnostics/legacy-codex-202608`。
- 舊版操作指令放 `docs/archive/<日期>` 並標示過期版本；歸檔指令不構成新的執行或刪除授權。
- 清理前確認完整路徑、Git 追蹤狀態、使用中程序與目錄連結；含 junction／symlink 的樹不得直接遞迴刪除。只能刪除已確認的目標，不用廣域 `git clean` 清空專案。
- 搬移資料時不得覆寫目的地；核對搬移前後的相對檔名、檔案數、大小與修改時間，並保留需要追溯的證據。
- 清理後核對正式發布檔與使用者設定未變，回報實際刪除與歸檔的差異。歸檔不算釋放空間；刪除受工具政策拒絕時明確回報，不能改用其他方式繞過。
- 需要留存但不應再次直接執行的一次性驗證腳本，歸檔成 `.ps1.txt` 等文字檔；這類歷史副本可能依賴原工作目錄，不能當成可直接重跑的現行工具。

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
