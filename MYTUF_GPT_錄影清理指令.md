# MyTUF GPT：更新並清除舊錄影

請在 MyTUF 電腦完整執行下列工作，不要猜測或擴大刪除路徑：

1. 唯一允許操作的安裝根目錄是 `C:\Users\derek\Downloads\自動鋤地`；先確認實際存在。另確認設定中的錄影目的地，預期可能是 `\\192.168.0.194\分享\MyTUF\操作過程`。
2. 只關閉此專案精確命中的 `全自動.ahk`、正式錄影 FFmpeg 或舊錄影 worker。不得依映像名稱全殺 AutoHotkey、Python 或 FFmpeg，也不得碰其他程式。
3. 從以下不變 manifest 取得正式發布，不可使用快取、舊 ZIP 或自行修改的檔案：
   `https://raw.githubusercontent.com/derek3411888/-/23ee7d7d46df5f4dbdb10c0d6a806508acfaaf50/update_manifest.example.json`
4. 先將安裝版更新並驗證為：
   - Payload `4.85`
   - Launcher `4.96`
   - Release ID `p4.85-l4.96-s1.0.45-E7347545-B99AB837-FB8AA968-E741D5F2`
   - Launcher SHA-256 `B99AB837F24CF20B540EAFA4D513CC655E0AA574E7541B9C8A4D1401AB8E2418`
   - Payload ZIP SHA-256 `E7347545BED8B44160512EBD216DE39C8D1D19940BB641A852B1DF5C7D068B22`
5. 若目前 Launcher 已是 `4.96` 且雜湊正確，執行：

   ```powershell
   & "C:\Users\derek\Downloads\自動鋤地\全自動鋤地.exe" --cleanup-recordings
   ```

   若仍是舊版 Launcher，不可直接執行上面的參數，因舊版不會轉送清理模式。請先從 manifest 的 `launcher_url` 與 `payload_url` 下載，逐一核對 SHA-256，再以可回復方式更新安裝版；更新過程不得啟動遊戲流程。更新完成後再執行上述命令。
6. 清理命令只允許刪除：
   - 設定錄影目的地中的 `wuthering_auto_recording_*.mkv`、`wuthering_auto_recording_*.mp4`。
   - 具有 `.wuthering_recording_segments` 標記的 `wuthering_auto_recording_*_segments` 資料夾。
   - 具有 `.wuthering_recording_session` 標記的本機 `操作過程\錄影暫存` 工作階段。
   - 舊的 `recording_status.ini`、`recording_worker.log`。
7. 不得刪除 Log、config.ini、診斷快照、程式本體、其他影片、沒有安全標記的資料夾或其他使用者檔案。
8. 驗收時確認 `config\config.ini` 具有：
   - `recording_mode=direct`
   - `segment_minutes=0`
   - `auto_merge=0`
   - `direct_mode_legacy_cleanup_completed=1`
9. 確認本次命令沒有啟動鳴潮、OKWW、LRMCAI、效能採集、遠端控制或新的錄影 FFmpeg；列出剩餘受管錄影檔數量，並回報清理前後 C 槽及錄影目的地的可用空間。
10. 任一步驟失敗就停止，保留可回復備份並回報第一個錯誤；不得改用廣域 `Remove-Item -Recurse` 猜路徑刪除。
