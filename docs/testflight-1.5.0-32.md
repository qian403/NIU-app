# TestFlight 1.5.0 (32)

## 測試內容

1. 校園地圖新增樓層平面圖：格致大樓（電資學院）1F–6F、綜合教學大樓 1F–4F、圖書資訊中心 1F–6F、實驗動物中心 1F–2F。總覽地圖新增宜大紅樓。
2. 格致大樓搜尋告示上的 E／格代碼（例如 E505、格106）可找到對應的「電」教室；課表教室也能直接開啟位置。
3. 綜合教學大樓兩翼分開繪製；格致大樓 2F 往電資二館等南北向連通標示改為直式。
4. 樓層平面圖下方抽屜拖曳應順暢、不抖動，放手後會滑回開啟或收起位置；請在教室較多的樓層測試。
5. 其餘同 1.5.0 (31)。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟，並說明是全新安裝或從哪一版更新。

## 封存與上傳

- 程式來源：`f14df1f`，在 1.5.0 (31) 之後加入 `6e0d57d`（同步 Android 最新圖資，來源 windlessme/niu-app-android `d13d5db`）與 `d8f95dc`（樓層抽屜拖曳卡頓）。
- 同一個尚未正式上架的 1.5.0 版本內新增內容，版本號維持 1.5.0；建置號由 31 遞增為 32，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-15/NIU-TestFlight-1.5.0-32.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error；App 內含 10 個校園地圖 JSON。
- App／Widget 均為 1.5.0 (32)，最低 iOS 分別為 18.6／18.0，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與先前相同屬既有設定差異。
- 驗證範圍：模擬器編譯、`sync-campus-map.py --check`、`check-widgets.py`、`check-lifetimes.py`，以及對照 Android `campus_map_test.dart` 的離線模型檢查。新平面圖畫面、直式連通標示與抽屜拖曳手感尚未在模擬器或真機登入後操作驗證。
- 台北時間 2026-10-15 01:36:48，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查。
- 封存日誌：`/tmp/niu-testflight-1.5.0-32-archive.log`；上傳日誌：`/tmp/niu-testflight-1.5.0-32-upload.log`。
