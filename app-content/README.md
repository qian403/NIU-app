# 特別感謝名單

`credits.json` 是唯一維護來源。App 從本專案 `main` 分支讀取，同一份檔案也由 Xcode 打包為 `credits.json`，供首次離線開啟使用。

## 修改與發布

1. 修改 `entries`：每筆有穩定且唯一的 `id`、`name`、`description`、`projectName`、HTTPS `url` 與整數 `order`（小的先顯示，相同時依 ID 排序）。現有項目改名時保留 ID。
2. 每次內容變動增加 `revision`，`schemaVersion` 維持 `1`。名單完整取代，可刪除已撤下的項目；空陣列會顯示空結果。
3. 執行 `python3 scripts/check-credits.py`，確認資料與離線更新回歸通過。
4. 將資料提交並推送至 GitHub `main`。App 下次開啟此頁時檢查更新，成功檢查後 6 小時內使用快取；下拉更新可立即重試（仍受 GitHub CDN 傳播時間影響）。

回復舊內容時，請把舊內容發布為更大的 revision，不要降低 revision。相同 revision 不得對應不同內容。支援 HTTPS 網址，禁止 URL 內含使用者名稱／密碼。

App 驗證格式、大小、ID 唯一性及 revision 後才原子替換快取。網路錯誤、未知 schema、舊版或有問題的資料不會清空有效名單。取消或過期請求不會覆寫較新的回應。這是公開內容，登出不需刪除；不會上傳校務帳號或個資。

僅更新名單不需增加 App Build 或重新上架。首次導入此功能，以及修改原生呈現／解析邏輯，才需要發行新 App。開源授權文件另隨 App 打包，不依賴此感謝名單。
