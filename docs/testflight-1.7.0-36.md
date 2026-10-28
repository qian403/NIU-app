# TestFlight 1.7.0 (36)

## 測試內容

1. 課表交換與共同空堂：用 QR Code 和同學交換課表、查看同學課表，並標出大家都沒課的時段。
2. 整週課表上方顯示學年度、學期與第幾週。教學週顯示「第 N 週」，暑假、寒假、預備週沿用校方標籤（暑六／寒一／預備週）；缺少行事曆資料時只顯示學年度與學期。
3. M 園區作業說明保留上標與下標。
4. 「本次更新內容」新增 1.7.0 兩項說明。

## 封存與上傳

- 原因：新增課表交換與週次顯示，升次版號為 1.7.0；建置號由 35 遞增為 36，App／Widget 的 Debug／Release 設定同步修改。
- 程式來源：`0470040`，在 1.6.0 (35) 之後加入 `34954d4`（Moodle 上下標）、`8852f4a`（課表交換與共同空堂）、`e5737ae`（發行檢查）、`d94edfc`（週次顯示，PR #3）與 `0470040`（更新內容）。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-28/NIU-TestFlight-1.7.0-36.xcarchive`，使用 Xcode 27.1（27A9275），套件快取 `/tmp/niu-dd-release-36`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.7.0 (36)，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項（18.6／18.0）與先前相同，屬既有設定差異。
- 驗證範圍：模擬器編譯、`check-academic-week.py`、`check-class-schedule-week.py`、`check-widgets.py`、`check-app-store.py`、`check-lifetimes.py`、`check-whats-new.py`、Release 封存。週次標頭與課表交換尚未在模擬器或真機操作驗證。
- 第一次匯出時 Xcode 帳號登入已過期而失敗；重新登入後，台北時間 2026-10-28 21:38:20，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`。尚未在 App Store Connect 確認處理狀態。
- 匯出上傳另有 FirebaseAnalytics 與 GoogleAppMeasurement 缺少 dSYM 的警告，與先前建置相同。
- 本次未設定外部測試群組或送審。
- 封存日誌：`/tmp/niu-testflight-1.7.0-36-archive.log`；上傳日誌：`/tmp/niu-testflight-1.7.0-36-upload.log`。
