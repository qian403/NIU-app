# TestFlight 1.1.0 (12)

## 測試內容

- 「可報名」與「已報名」活動列表、詳情頁新增活動編號；詳情中的編號可選取複製。
- 搜尋支援完整或部分活動編號、全形數字及忽略前後空白，保留名稱、主辦單位、內容與已報名狀態查詢。
- 修正深色模式卡片與頁面背景融在一起的問題，採用不同層級的系統背景色及細框線。
- 更新搜尋提示與清除按鈕的無障礙標籤及點擊範圍。

## 驗證與限制

- 活動搜尋與分享離線回歸通過；測試使用合成資料，不存取帳密或校方報名紀錄。
- 模擬器使用合成資料檢查淺色、深色、放大文字與活動詳情畫面。
- Widget 回歸、發行靜態檢查、模擬器編譯與 Release Archive 通過。
- Release 封存編譯日誌沒有 warning／error；App 與 Widget 同為 1.1.0 (12)，最低 iOS 26.2，隱私宣告完整且未包含 DEBUG 點名控制。
- `codesign --verify --deep --strict` 通過。
- 本次未做真機驗證或實際報名操作。

## 發行紀錄

- 台北時間 2026-10-01，上傳前使用 Arc 核對 App Store Connect：最新建置為 1.1.0 (11)，上傳處理狀態為「完成」。
- 正式 1.1.0 當時為「正在等待審查」。本次沿用 1.1.0，只上傳新的 TestFlight 建置，不撤回或替換正式送審版本，不另行發布外部測試。
- App／Widget 的 Debug／Release 建置號同步增加至 12。
- 發行團隊：Very Fast Network LTD（`G4LXL97NF9`）。
- 功能程式來源：`de1de32756f7f6a6001a28e7bd1c883c7909a3a4`，另加本次建置號調整。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-01/NIU-TestFlight-1.1.0-12.xcarchive`。
- 台北時間 2026-10-01 02:25:08，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`。
- 上傳完成時 Xcode 回報 `Uploaded package is processing`。隨後使用 Arc 重新整理並重新開啟 App Store Connect，但建置表格持續載入，新分頁亦未載入內容，因此尚未從 App Store Connect 確認後續處理結果或可安裝測試狀態。
