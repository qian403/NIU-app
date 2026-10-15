# TestFlight 1.5.0 (33)

## 測試內容

1. 校園地圖新增 8 棟樓層平面圖：學生活動中心 1F–5F、語言中心 1F–2F、通識教育中心 1F–2F、行政大樓 1F–5F、體育館 B1–4F、經德大樓 1F–7F、生資大樓 1F–8F、食品系實習工廠 1F–3F，共 17 棟。
2. 圖書資訊中心重畫為 B1–7F，房間採圖書館名稱（例如 523 討論室、電腦教室一）；總覽搜尋「圖書館」可找到。
3. 圖書資訊中心的獨立區域與行政區域以灰底虛線標示，1F 有「獨立入口」標示；點選區域內房間，抽屜顯示區域說明。
4. L 形房間的名稱放在房間內；學生活動中心等上層較小的樓層會單獨填滿畫面。
5. 總覽地圖選取的建築名稱改為深色粗體。
6. 其餘同 1.5.0 (32)。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟，並說明是全新安裝或從哪一版更新。

## 封存與上傳

- 程式來源：`c635f8c`，在 1.5.0 (32) 之後加入 `b4ac344`（同步 Android 最新圖資，來源 windlessme/niu-app-android `79a2af2`）。
- 同一個尚未正式上架的 1.5.0 版本內新增內容，版本號維持 1.5.0；建置號由 32 遞增為 33，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-16/NIU-TestFlight-1.5.0-33.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error；App 內含 18 個校園地圖 JSON。
- App／Widget 均為 1.5.0 (33)，最低 iOS 分別為 18.6／18.0，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與先前相同屬既有設定差異。
- 驗證範圍：模擬器編譯、`sync-campus-map.py --check`、`check-widgets.py`、`check-lifetimes.py`、`check-whats-new.py`，以及對照 Android `campus_map_test.dart` 的離線模型檢查。新平面圖、區域標示與小樓層取景尚未在模擬器或真機登入後操作驗證。
- 台北時間 2026-10-16 04:28:17，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查。
- 封存日誌：`/tmp/niu-testflight-1.5.0-33-archive.log`；上傳日誌：`/tmp/niu-testflight-1.5.0-33-upload.log`。
