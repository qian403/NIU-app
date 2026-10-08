# TestFlight 1.4.0 (28)

## 測試內容

1. M 園區登入（本版重點）：M 園區登入過期（約 4 小時）後開啟測驗，應只看到「正在讀取題目…」，接著直接進入題目，不應出現 M 園區登入頁。App 會依序嘗試：現有登入、App 登入金鑰、學校 SSO、以 App 保存的帳號自動登入 M 園區（含驗證碼辨識）、背景重新登入校務後再經 SSO；全部失敗才顯示登入頁。
2. 若最後仍出現登入頁，手動登入後應自動回到原本的測驗。
3. 其餘測試項目同 1.4.0 (27)：原生測驗作答流程、各題型、計時測驗、快速點名分享連結、自訂課程顏色。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟；登入問題請註明當時是否剛登入 App、距離上次使用 M 園區多久。實際開始或交卷測驗會影響校方作答紀錄，建議使用練習用測驗。

## 封存與上傳

- 程式來源：`8da1c79`，在 1.4.0 (27) 之後加入 `8a61dad`（測驗頁依序自動恢復 M 園區登入）。
- 1.4.0 (27) 的測驗頁在 M 園區登入過期時仍會顯示登入頁：App 登入金鑰失敗時跳過學校 SSO、背景重新登入成功後未經 SSO 轉入 M 園區，且未使用既有的保存帳號 M 園區自動登入。本版修正。
- 1.4.0 尚未在 App Store 正式發布，維持版本 1.4.0；建置號由 27 遞增為 28，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-08/NIU-TestFlight-1.4.0-28.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.4.0 (28)，最低 iOS 分別為 18.6／18.0，簽章團隊均為 G4LXL97NF9，`codesign --verify --deep --strict` 通過，兩者皆含隱私清單；執行檔不含 DEBUG 點名控制字串、測驗實驗室與模擬帳號字串。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與 (27) 相同屬既有設定差異，其餘封存項目以相同條件手動檢查通過。
- 離線回歸：`check-moodle-questions.py`（7 項，含直接抽取正式程式碼驗證登入恢復順序與次數上限）、`check-moodle-question-page.py`（18 項）、`check-moodle-question-detail.py`、`check-lifetimes.py`、`check-sso-storage.py`、`check-sso-login.js`、`check-attendance-login.js`、`check-attendance-captcha.py`、`check-attendance-response.py` 通過。登入恢復尚未以宜蘭大學真實帳號或真機驗證。
- 台北時間 2026-10-08 18:27:10，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查。
- 封存日誌：`/tmp/niu-testflight-1.4.0-28-archive.log`；上傳日誌：`/tmp/niu-testflight-1.4.0-28-upload.log`。
