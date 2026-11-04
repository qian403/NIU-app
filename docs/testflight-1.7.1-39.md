# TestFlight 1.7.1 (39)

## 測試內容

1. 圖書館通行碼：學校的 `sso.niu.edu.tw/QRCode/Number/` 與 `QRCode/Create/Barcode` 改為要求 ccsys1 SSO Bearer token。App 取碼時改帶目前帳號的 token，快到期先續期；被拒時續期重試一次，仍失敗則用已存帳密在背景重新登入後再取碼。門禁 QR 圖片（`QRCode/Create?u=...`）仍不需 token。日誌只記路徑與狀態碼。
2. 「本次更新內容」新增 1.7.1「修正圖書館通行碼」。

## 封存與上傳

- 原因：先以 1.7.0 (39) 匯出上傳時，Apple 回報 1.7.0 已通過審查、該版本 train 已關閉。本次只修錯誤，依版本規則改為 Patch 版 1.7.1，建置號由 38 遞增為 39（39 未被先前的失敗上傳使用），App／Widget 的 Debug／Release 設定同步修改。
- 程式來源：`d98e2a2`（分支 `codex/library-code-bearer-token`），包含 `df814da` 圖書館通行碼修正。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-11-04/NIU-TestFlight-1.7.1-39.xcarchive`，套件快取 `/tmp/niu-dd-release-39`。Release archive 成功，封存日誌 0 warning。
- App／Widget 均為 1.7.1 (39)，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項（18.6／18.0）與先前相同，屬既有設定差異。
- 驗證範圍：模擬器編譯、`check-sso-storage.py`、`check-lifetimes.py`、`check-whats-new.py`、`check-app-store.py`、Release 封存；使用者已在模擬器確認圖書館通行碼可正常取得。真機尚未驗證。
- 台北時間 2026-11-04 16:27:11，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態。
- 匯出上傳另有 FirebaseAnalytics 與 GoogleAppMeasurement 缺少 dSYM 的警告，與先前建置相同。
- 本次未設定外部測試群組或送審。
- 封存日誌：`/tmp/niu-testflight-1.7.1-39-archive.log`；上傳日誌：`/tmp/niu-testflight-1.7.1-39-upload.log`。
