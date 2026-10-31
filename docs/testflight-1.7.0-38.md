# TestFlight 1.7.0 (38)

## 測試內容

1. 校務系統登入：學校 `ccsys1.niu.edu.tw` 新憑證缺少交叉憑證，iOS 無法驗證，登入後出現「登入驗證未完成」或白畫面。現在內嵌 TWCA CYBER Root CA，系統驗證失敗時才改用它驗證（#4）；並只對 ccsys1 加 ATS 例外，讓這段驗證有機會執行（#5）。M 園區、畢業門檻、在學證明、活動報名經 `Std002.aspx` 轉到 ccsys1 時也會套用。
2. 課表好友依草圖重做（#6）：首頁「課表好友」直接進好友頁；課表頁上方顯示「課表好友・N 位現在有空」；好友頁先列現在有空的好友，每位好友顯示下次共同空堂；好友個人頁有今天兩人課程對照與一週共同空堂；揪團顯示大家都有空的時段、週熱度格與差一個人的時段；加好友與分享設定改為推入的頁面。
3. 「本次更新內容」1.7.0 加入「修正校務系統登入失敗」。

## 封存與上傳

- 原因：1.7.0 尚未上架，App Store Connect 上最新為 1.7.0 (37)，維持 1.7.0，建置號由 37 遞增為 38，App／Widget 的 Debug／Release 設定同步修改。
- 程式來源：`be51a90`，在 1.7.0 (37) 之後加入 #4（`64037eb`）、#5（`89f9196`）、#6（`59e5224`），以及 `3e39bec`（check-app-store 改為只接受 ccsys1 的 ATS 例外）。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-31/NIU-TestFlight-1.7.0-38.xcarchive`，Xcode 27.1（27A9275），套件快取 `/tmp/niu-dd-release-38`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.7.0 (38)，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。封存內 `NSAppTransportSecurity` 只有 `ccsys1.niu.edu.tw` 例外（不含子網域）。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項（18.6／18.0）與先前相同，屬既有設定差異。
- 驗證範圍：模擬器編譯、`check-school-trust.py`、SSO 相關檢查（renewal、login、refresh、settings-connections、enrollment-state）、`check-lifetimes.py`、活動報名（favorites、registration、batch）、`check-moodle-questions.py`、`check-schedule-friends.py`、`check-schedule-exchange.py`、`check-class-schedule-week.py`、`check-whats-new.py`、`check-widgets.py`、`check-app-store.py`、Release 封存。以獨立測試 App 在模擬器對照：無 ATS 例外時 ccsys1 為 `-1200`，加上後 URLSession 與 WebView 皆可連線；使用者已在模擬器確認登入成功。真機尚未驗證；`check-enrollment-pdf.py` 在 main 上原本就失敗（找不到 `SSOSessionService`），與本次無關。
- 台北時間 2026-10-31 21:50:59，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態。
- 匯出上傳另有 FirebaseAnalytics 與 GoogleAppMeasurement 缺少 dSYM 的警告，與先前建置相同。
- 送審時需在 App Review 備註說明 ccsys1 的 ATS 例外（`NSExceptionAllowsInsecureHTTPLoads` 屬需說明理由的設定）。
- 本次未設定外部測試群組或送審。
- 封存日誌：`/tmp/niu-testflight-1.7.0-38-archive.log`；上傳日誌：`/tmp/niu-testflight-1.7.0-38-upload.log`。
