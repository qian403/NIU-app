# TestFlight 1.1.0 (13)

## 測試內容

- 課表中的課程卡片可開啟對應的 M 園區課程；優先比對當學期，同名多筆時提供選擇，找不到時可前往完整課程列表。
- 同一課程的連續節次合併為一個課表即時動態，顯示各節進度及下課節點；修正精簡動態島倒數換行。
- 活動報名共用登入流程，改善登入失效後重試，依校方回應驗證報名、取消與修改結果。
- 圖書館設備登入失效時先嘗試重新登入，再顯示需要操作的校方頁面。
- 改善郵件包裹查詢輸入及連線初始化的卡頓；M 園區上傳內容移至背景組裝，並重用點名解析規則。

## 驗證與限制

- Widget、背景即時動態、公共行事曆、SSO 登入／隔離儲存、圖書館設備、活動報名、郵件包裹查詢、M 園區請求內容與生命週期離線回歸通過。
- 活動報名使用本機合成網站與 WKWebView，未操作真實校方報名紀錄。
- 生命週期回歸的合成測試程式有一則 weak 變數未變更警告；測試結果通過。Release 封存日誌無 warning／error。
- Release Archive 及發行靜態檢查通過；App 與 Widget 均為 1.1.0 (13)、最低 iOS 26.2，隱私宣告完整且未包含 DEBUG 點名控制。
- `codesign --verify --deep --strict` 通過，App 與 Widget 團隊識別碼均為 `G4LXL97NF9`。
- 本次未重新做模擬器畫面或真機驗證，也未做 Instruments 長時間量測。

## 發行紀錄

- 台北時間 2026-10-01，透過 Arc 核對 App Store Connect：最新建置為 1.1.0 (12)，已加入內部 test 群組並有安裝紀錄；正式 1.1.0 顯示「被開發者拒絕」。
- 維持待發行版本 1.1.0，App／Widget 的 Debug／Release 建置號同步增加至 13。
- 發行團隊：Very Fast Network LTD（`G4LXL97NF9`）。
- 功能程式來源：`58cc5e8`，另加本次建置號調整。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-01/NIU-TestFlight-1.1.0-13.xcarchive`。
- 台北時間 2026-10-01 18:52:38，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；當時為 `Uploaded package is processing`。
- 上傳後已在 Arc 的 App Store Connect 上傳表格確認 1.1.0 (13)，建立時間為 Oct 1, 2026 6:52 PM，狀態「處理中」；尚未確認可安裝測試。
- 本次僅上傳 TestFlight，未推送 GitHub、發布外部測試或提交正式 App Store 審查。
