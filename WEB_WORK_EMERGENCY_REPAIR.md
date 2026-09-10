# 網站回報故障時的 Codex Web 備援

固定網址：<https://derek3411888.github.io/-/web-work-fallback.html>

這個頁面只由 GitHub Pages 提供靜態 HTML，不讀取 Firestore、不連中央主機，也不依賴 CodexSupportBridge。正式網站的「通知目前 Codex 任務」如果卡住，仍可用它整理問題、複製修復訊息、下載 TXT，再開啟 Codex Web 貼到目前專案任務。

## 使用順序

1. 開啟上面的固定網址。
2. 填寫裝置、問題描述，以及已移除敏感資訊的 Log 尾端。
3. 按「複製修復訊息」；若公司瀏覽器禁止剪貼簿，就按「下載 TXT 備份」。
4. 按「開啟 Codex Web」，回到目前這個專案任務後貼上並送出。
5. 不要貼密碼、Token、Cookie、私密金鑰或完整憑證檔。

## 三條路的差異

- 家中自架網站：直接寫入 PostgreSQL，由中央橋接送到目前 Codex 任務。
- 公司 GitHub Pages：透過 Firestore 傳回中央橋接，網站可顯示每一階段和 Codex 最終回覆。
- 獨立備援頁：完全人工複製／下載，不會誤稱「已自動送出」，也不會因前兩條路故障而一起失效。
