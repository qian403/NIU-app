# TestFlight 1.7.0 (37)

## 測試內容

1. 課表好友（取代原本的課表交換）：課表頁左上角人像按鈕或首頁「課表好友」進入。好友依「有空／上課中／不確定／其他學期」分組並顯示即時狀態；加好友在同一畫面切換「掃描 QR Code」與「我的 QR Code」，可傳送 QR Code 圖片再用「從照片選取」加入；好友頁顯示今天的課與共同空堂；「揪團找空堂」點選頭像後先列出大家都有空的時段。
2. 包裹查詢：一次查詢同時取得未領取、已領取與退件，切換狀態不再重新查詢，狀態按鈕顯示筆數。校方回 429／503 時，10 分鐘內改回只查顯示中的狀態、切換時才查，並依 Retry-After 重試一次。
3. 「本次更新內容」1.7.0 改為課表好友、整週課表週次、包裹查詢一次查完三項。

## 封存與上傳

- 原因：1.7.0 尚未上架（App Store 公開版本為 1.6.0），維持 1.7.0，建置號由 36 遞增為 37，App／Widget 的 Debug／Release 設定同步修改。
- 程式來源：`041a6d8`，在 1.7.0 (36) 之後加入 `534f6ff`、`b9e57af`（課表好友與審查修正）、`9979bc6`、`1418d89`（包裹查詢一次查完與限流回退）。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-29/NIU-TestFlight-1.7.0-37.xcarchive`，Xcode 27.1（27A9275），套件快取 `/tmp/niu-dd-release-37`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.7.0 (37)，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項（18.6／18.0）與先前相同，屬既有設定差異。
- 驗證範圍：模擬器編譯、`check-schedule-friends.py`、`check-schedule-exchange.py`、`check-postal.py`、`check-postal-ui.py`（records／manual／error）、`check-class-schedule-week.py`、`check-academic-week.py`、`check-widgets.py`、`check-lifetimes.py`、`check-whats-new.py`、`check-app-store.py`、Release 封存。包裹三狀態並行查詢曾以實際校方系統小量測試，未見限流；相機掃描、照片匯入與真實限流情境尚未在真機驗證。
- 台北時間 2026-10-29 16:55:15，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態。
- 匯出上傳另有 FirebaseAnalytics 與 GoogleAppMeasurement 缺少 dSYM 的警告，與先前建置相同。
- 本次未設定外部測試群組或送審。
- 封存日誌：`/tmp/niu-testflight-1.7.0-37-archive.log`；上傳日誌：`/tmp/niu-testflight-1.7.0-37-upload.log`。
