# TestFlight 1.5.0 (34)

## 測試內容

1. App 內「本次更新內容」校園地圖一項改為「新增 17 棟大樓的樓層平面圖，改用原生手勢縮放與拖曳，也不會再拖出地圖範圍。」，不再提及其他平台。
2. 其餘同 1.5.0 (33)。

## 封存與上傳

- 原因：1.5.0 (33) 送審被 App Review 依 Guideline 2.3.10（Accurate Metadata）退回，要求更新說明移除 Android 字樣（Submission ID 765075f1-0e70-4c3e-9a98-e20373cfbc3a，2026-10-16）。
- 程式來源：`8cd4173`，在 1.5.0 (33) 之後加入 `99abc64`（`Core/Services/WhatsNewStore.swift` 文案）。全專案其餘 Android 字樣僅在程式註解，不會顯示。
- 版本號維持 1.5.0；建置號由 33 遞增為 34，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-16/NIU-TestFlight-1.5.0-34.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error；App 內含 18 個校園地圖 JSON；App 執行檔含新文案，不含「Android」字串。
- App／Widget 均為 1.5.0 (34)，最低 iOS 分別為 18.6／18.0，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與先前相同屬既有設定差異。
- 驗證範圍：`check-whats-new.py` 離線測試、Release 封存。更新內容畫面未在模擬器或真機操作驗證。
- 台北時間 2026-10-16 14:35:04，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態。
- 匯出上傳另有 FirebaseAnalytics 與 GoogleAppMeasurement 缺少 dSYM 的警告，與先前建置相同。
- 本次未更換送審建置或重新送審；需由使用者在 App Store Connect 操作。
- 封存日誌：`/tmp/niu-testflight-1.5.0-34-archive.log`；上傳日誌：`/tmp/niu-testflight-1.5.0-34-upload.log`。
