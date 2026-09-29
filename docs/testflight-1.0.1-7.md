# TestFlight 1.0.1 (7)

## 測試內容

- 點名回應確認成功或已完成後，可選擇分享本次點名連結。
- 調整課表即時動態的動態島版面，顯示課程狀態、倒數、教室、節次與教師；資料過期時提示開啟 App 更新。
- 包含設定頁連線檢查的逾時與取消修正。

請確認點名失敗、QR Code 過期或需要登入時不會出現完成分享提示；檢查動態島展開、收合與資料過期的顯示，並確認設定頁各服務不會持續停在「檢查中」。實際點名以校方回應為準；分享連結不代表收件者已完成點名。即時動態背景更新仍受 iOS 排程限制。

## 建置與驗證紀錄

- 2026-09-23，來源為 commit `afa068f` 與目前工作目錄修改；上傳前在 App Store Connect 核對最新建置為 1.0.1 (6)，處理完成。
- App 與 Widget 的 Debug／Release Build 同步增加為 7，版本維持 1.0.1，團隊為 `G4LXL97NF9`。
- Release Archive 成功，封存 log 無編譯 warning/error；上架靜態檢查、封存 metadata／privacy manifests／extension 版本一致性、系統權限下的簽章驗證通過。
- 設定連線、Widget、點名回應（20 回應案例與 7 WebKit fixtures）、點名登入腳本及生命週期離線檢查通過。WebKit fixture 初次受沙盒阻擋，使用正常系統權限後通過；生命週期 fixture 有既有 weak 變數風格警告。
- 本次未重新執行模擬器／真機 UI 驗收、實際校方點名或 Instruments 長時間量測。
- 台北時間 2026-09-23 13:25:30，Xcode 回報 `Upload succeeded`、`EXPORT SUCCEEDED`。隨後在 App Store Connect 確認 1.0.1 (7) 的上傳狀態為「完成」，建置狀態為「準備提交」，已列入既有內部 `test` 群組；未列入外部測試群組。這不等於 Beta 外部審查或 App Store 正式審查通過。
- 封存保留於 `~/Library/Developer/Xcode/Archives/2026-09-23/NIU-TestFlight-1.0.1-7.xcarchive`。
- 本次範圍為 TestFlight 上傳，未提交正式 App Store 審查、未另行發布外部測試、未推送 GitHub。
