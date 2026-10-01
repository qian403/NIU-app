# TestFlight 1.1.0 (9)

## 測試內容

- 優化活動系統登入與清單載入：移除固定等待，避免分頁重複啟動請求，改善取消、登入失敗與解析失敗後的恢復。
- 可報名／已報名活動詳情新增分享選單，可分享活動摘要及校方連結，或只分享連結。
- 活動說明、相關連結與備註中的網址可點擊，保留網址查詢參數。
- 包含先前 Build 8 的在學證明功能，以及課表即時動態顯示修正。

請檢查活動登入、快速切換分頁、空清單與重新整理；確認活動資訊分享正確，並可開啟表單與會議網址。分享內容不應包含個人報名資訊或登入憑證。

## 發行紀錄

- 原始碼：`f6bcef621c969bf3f6ca20689836577f8acbe1fa`，另同步調整 App／Widget 的 Debug／Release 為 1.1.0 (9)。
- 上傳前已於 App Store Connect 核對最新 TestFlight 為 1.0.1 (8)，正式 1.0.1 顯示「已可發佈」。本次新增使用者功能，依專案版本規則採次版本更新。
- 團隊：Very Fast Network LTD（`G4LXL97NF9`）。
- 已通過活動分享／網址辨識、生命週期與 Widget 離線回歸檢查，以及上架靜態檢查。生命週期測試程式出現既有 weak var 可改為 let 的警告，測試結果通過。
- 此次未重做真機登入耗時量測。
- Release Archive 成功，編譯日誌無 warning/error；封存檢查確認 App／Widget 均為 1.1.0 (9)，隱私宣告完整，未包含 DEBUG 點名控制。
- `codesign --verify --deep --strict` 在系統簽章環境驗證通過。
- 封存：`~/Library/Developer/Xcode/Archives/2026-09-30/NIU-TestFlight-1.1.0-9.xcarchive`。
- 台北時間 2026-09-30 14:06:40，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`，Apple 已開始處理上傳套件。
- 已於 App Store Connect 確認新上傳列為 1.1.0 (9)，建立時間 Sep 30, 2026 2:06 PM；本次最後核對狀態為「處理中」，尚不能視為可安裝測試或已通過審查。
- 未另行加入內部／外部測試群組，未送 Beta 或正式 App Store 審查。版本設定及本文件保留在本機，尚未另行提交推送 GitHub。
