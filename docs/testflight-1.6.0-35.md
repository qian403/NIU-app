# TestFlight 1.6.0 (35)

## 測試內容

1. 校園地圖：新增人文管理學院及外文系 1F–4F 樓層平面圖；斜向樓梯的階梯線垂直於梯段並裁在梯段內。可搜尋「103」「外文系」「院長」確認。
2. 捷徑：新增「查詢校園郵件包裹」動作，可查詢自己或指定收件人的未領取、已領取或退件郵件；郵件查詢、課表查詢與課表即時動態捷徑可在鎖定時執行。
3. 「本次更新內容」新增 1.6.0 兩項說明。

## 封存與上傳

- 原因：1.5.0 已於 2026-10-17 正式上架，新增功能升次版號為 1.6.0；建置號由 34 遞增為 35，App／Widget 的 Debug／Release 設定同步修改。
- 程式來源：`03051b9`，在 1.5.0 (34) 之後加入 `8c3fe57`（郵件包裹捷徑）與 `8349299`（同步 Android 最新圖資，來源 windlessme/niu-app-android `849353c`）。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-19/NIU-TestFlight-1.6.0-35.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error；App 內含 19 個校園地圖 JSON。原 `/tmp/niu-dd-release` 套件快取殘缺，改用 `/tmp/niu-dd-release-35`。
- App／Widget 均為 1.6.0 (35)，最低 iOS 分別為 18.6／18.0，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與先前相同屬既有設定差異。
- 驗證範圍：模擬器編譯、`sync-campus-map.py --check`、`check-whats-new.py`、`check-widgets.py`、`check-lifetimes.py`、Release 封存。新平面圖、斜向樓梯與郵件捷徑尚未在模擬器或真機操作驗證。
- 台北時間 2026-10-19 19:13:53，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態。
- 匯出上傳另有 FirebaseAnalytics 與 GoogleAppMeasurement 缺少 dSYM 的警告，與先前建置相同。
- 本次未設定外部測試群組或送審。
- 封存日誌：`/tmp/niu-testflight-1.6.0-35-archive.log`；上傳日誌：`/tmp/niu-testflight-1.6.0-35-upload.log`。
