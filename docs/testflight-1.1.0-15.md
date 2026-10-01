# TestFlight 1.1.0 (15)

## 測試內容

- 修正 M 園區課程選單的圖示和文字高低不齊，包含「資源」與「出缺席」。
- 圖示使用一致且隨 Dynamic Type 縮放的高度；輔助字級為各選單預留兩行文字空間，換行時仍對齊首行。
- 請檢查一般字級、放大文字與深色模式，並確認左右滑動、點擊切換、垂直捲動、下拉更新及左緣返回。

## 驗證與限制

- App 模擬器編譯通過；Astra 複查通過。
- 一般字級與最大輔助字級的模擬器截圖確認圖示中心、文字首行及選單外框對齊。
- 獨立新建模擬器的三項 XCTest UI 回歸通過，涵蓋分頁與選單左右滑動、點擊連動、首尾邊界、垂直捲動、下拉更新、左緣返回、320pt 窄畫面及最大輔助字級深色模式。
- 共用模擬器的測試曾遭其他 App 移除對話框干擾；交付依獨立模擬器的最終通過結果。
- Release Archive 與發行靜態檢查通過，封存日誌無 warning／error；App／Widget 均為 1.1.0 (15)、最低 iOS 26.2。
- App／Widget 簽章驗證通過，團隊識別碼均為 G4LXL97NF9。
- 未重新驗證真實校方帳戶、真機或 Instruments 長時間量測。

## 發行紀錄

- 程式來源：GitHub main 的 e35fdd6；封存來源的所有追蹤檔案與此提交一致。
- 台北時間 2026-10-02，App Store Connect 最新建置為 1.1.0 (14)，狀態「正在測試」；本次 App／Widget Debug／Release 建置號同步增加至 15。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：~/Library/Developer/Xcode/Archives/2026-10-02/NIU-TestFlight-1.1.0-15.xcarchive。
- 台北時間 2026-10-02 00:54:51，Xcode 回報 Upload succeeded 與 EXPORT SUCCEEDED；Apple 狀態為 Uploaded package is processing。
- 上傳後已在 App Store Connect 上傳表格確認 1.1.0 (15)，建立時間為 Oct 2, 2026 12:54 AM，狀態「處理中」；尚未確認可安裝測試。
