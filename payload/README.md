# 自動開啟OKWW - 修復打包EXE後重複啟動問題

## 問題

打包成EXE後啟動器會開啟兩個OKWW實例。

## 解決方案

1. 添加了全域互斥量確保即使打包為EXE也只會有一個實例運行
2. 增強了窗口檢測和進程管理邏輯
3. 添加了更詳細的日誌記錄
4. 改進了啟動前後的進程檢查
5. 擴展了OKWW窗口的搜尋條件

## 如何使用

直接執行腳本或打包為EXE:

```
AutoHotkey64.exe 自動開啟OKWW.ahk
```

## 主要變更

- 添加了全域互斥量 `OKWW_AutoUpdater_SingleInstance`
- 改進了進程檢測和窗口搜索邏輯
- 添加了更詳細的日誌輸出
- 改進了錯誤處理
- 擴展了OKWW窗口的搜尋條件

## 診斷

如果還有問題，請檢查 `okww.log` 日誌文件中的詳細記錄。

## 網路資料夾與分段錄影

- 設定介面的錄影輸出選擇器會明確列出「這台電腦」、偵測到的映射磁碟／檔案總管網路位置、「瀏覽網路」與「直接輸入 UNC」，不依賴 Windows 對話框左側欄；映射磁碟會轉成 `\\電腦\共用\資料夾` 的 UNC 路徑保存。
- 錄影先寫入 `%LOCALAPPDATA%\WutheringAuto\recording_staging`，預設每 5 分鐘封口一段，再把已完成分段補傳到目的端。網路暫斷不會中止錄影。
- 正常結束時會先讓 FFmpeg 完成最後一段，再無損合併。只有成品複製與大小驗證成功，才清除本機暫存與目的端分段。
- 收尾時共用資料夾離線會保留本機檔案並背景重試；下次啟動也會恢復未完成工作階段。
- 成功且開啟自動合併：成品在 `<輸出資料夾>\wuthering_auto_recording_日期_時間.mkv`。
- 錄影中或收尾失敗：可播放分段保留在 `%LOCALAPPDATA%\WutheringAuto\recording_staging\<工作階段>`；已補傳的五分鐘分段在 `<輸出資料夾>\wuthering_auto_recording_日期_時間_segments`。
- 最後狀態固定保存在 `%LOCALAPPDATA%\WutheringAuto\recording_staging\recording_status.ini`，背景收尾紀錄在同層 `recording_worker.log`。控制網站會同步顯示這些路徑並提供「複製路徑」。

## 即時回看

- 啟用 `[runtime_diagnostics]` 後，所有執行期圖片集中在 `<程式資料夾>\診斷快照`；`latest.jpg` 會持續覆寫，警告／錯誤畫面則依設定份數保留，OCR 暫存圖放在其下的 `暫存` 並於使用後刪除。
- 遠端控制啟用時，控制網頁會顯示每 60 秒更新的低畫質最新畫面、錄影成功／失敗位置與最近 50 筆流程事件。
- 網路短影片目前停用且不會上傳；完整 6～7 小時影片仍只保存在設定的本機／網路輸出資料夾。
- 畫面改寫入同集合的 `UID__media` companion 文件，控制／心跳文件不再夾帶 JPEG；AHK 每 10 秒輪詢時只下載 `desiredState` 與 `nonce`，降低 Firestore 讀取流量。
- 正常完整結束會刪除 `UID__media` 但保留 client 的 `OFFLINE` 狀態；錯誤、系統關機或重啟交接會保留最後畫面。控制網站會清除最後心跳超過 7 天且連續觀察 10 分鐘沒有更新的 client 與 media 文件。

## OCR 模型

- 預設高品質模型已由實際重複的 PP-OCRv3 更新為官方 PP-OCRv4 mobile 中文偵測／辨識模型，混合繁體、簡體與英文的鳴潮／OKWW 畫面辨識較穩。
- 舊 PP-OCRv3 仍保留在 `plugin\RapidOcr\models` 作相容回退。
- 目前隨附的 RapidOcrOnnx 1.2.2 DLL 無法載入 PP-OCRv5／v6，因此程式會略過檔名標示為 v5／v6 的模型，避免初始化崩潰。
