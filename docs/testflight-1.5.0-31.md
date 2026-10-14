# TestFlight 1.5.0 (31)

## 測試內容

1. 本次更新內容（本版重點）：從舊版更新後，第一次登入進到主畫面會跳出「本次更新內容」，按「開始使用」或下滑關閉後不再出現；全新安裝不會跳出。設定 → 關於 →「本版更新內容」可再次查看。
2. 已安裝 1.5.0 (30) 的測試者會直接看到這個畫面，因為 (30) 尚未留下「已看過」的記錄。
3. 其餘同 1.5.0 (30)。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟，並說明是全新安裝或從哪一版更新。

## 封存與上傳

- 程式來源：`c8d2bb0`，在 1.5.0 (30) 之後加入 `1ff0766`（更新後首次開啟顯示本次版本更新內容）。
- 同一個尚未正式上架的 1.5.0 版本內新增功能，版本號維持 1.5.0；建置號由 30 遞增為 31，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-14/NIU-TestFlight-1.5.0-31.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.5.0 (31)，最低 iOS 分別為 18.6／18.0，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過；執行檔不含暫時測試用字串。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與先前相同屬既有設定差異。
- 驗證範圍：`scripts/check-whats-new.py` 離線測試、模擬器編譯，以及暫時移除登入條件後的淺色／深色靜態截圖。登入後實際跳出、關閉後不再出現與設定頁入口尚未在模擬器或真機操作驗證。
- 台北時間 2026-10-14 23:41:14，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查。
- 封存日誌：`/tmp/niu-testflight-1.5.0-31-archive.log`；上傳日誌：`/tmp/niu-testflight-1.5.0-31-upload.log`。
