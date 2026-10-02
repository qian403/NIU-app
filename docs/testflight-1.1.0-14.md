# TestFlight 1.1.0 (14)

## 測試內容

- M 園區課程頁的選單與內容區可左右滑動切換公告、作業、問答、資源、出缺席及成績。
- 六個選單等寬排列，修正最右側選單被擠出畫面；放大文字時使用三欄兩列，輔助字級允許標籤換行。
- 選單與內容共用選取狀態，保留點擊切換、垂直捲動、下拉重新整理及左緣返回。

## 驗證與限制

- App 模擬器編譯通過；獨立合成資料畫面的三項 XCTest UI 測試通過，涵蓋內容與選單左右滑動、點擊連動、首尾邊界、垂直捲動、下拉更新、左緣返回、320pt 窄畫面及最大輔助字級深色模式。
- Release Archive 與發行靜態檢查通過；App／Widget 均為 1.1.0 (14)、最低 iOS 26.2，隱私宣告完整且未包含 DEBUG 點名控制。
- App／Widget 簽章驗證通過，團隊識別碼均為 G4LXL97NF9。
- Release 封存日誌沒有 warning／error。
- 未重新驗證真實校方帳戶、真機或 Instruments 長時間量測。

## 發行紀錄

- 發行程式來源：GitHub main 的 e5d79f8，加本次建置號調整。
- 台北時間 2026-10-01，App Store Connect 最新建置為 1.1.0 (13)，狀態「正在測試」；本次 App／Widget Debug／Release 建置號同步增加至 14。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：~/Library/Developer/Xcode/Archives/2026-10-01/NIU-TestFlight-1.1.0-14.xcarchive。
- 台北時間 2026-10-01 23:39:10，Xcode 回報 Upload succeeded 與 EXPORT SUCCEEDED，Apple 狀態為 Uploaded package is processing。
- 上傳後已在 Arc 的 App Store Connect 上傳表格確認 1.1.0 (14)，建立時間為 Oct 1, 2026 11:39 PM，狀態「處理中」；尚未確認可安裝測試。
