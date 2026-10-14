# TestFlight 1.5.0 (30)

## 測試內容

1. 校園地圖（本版重點，與 Android 版同步）：小工具 →「校園地圖」。全校總覽地圖可雙指縮放、拖曳與雙擊放大，地圖邊緣只能拖到畫面邊緣；點建築會出現卡片，有平面圖的建築可「查看樓層平面圖」。右上角可切換地圖／清單，下次開啟沿用。
2. 樓層平面圖：教穡大樓、工學院大樓、時習大樓、電資二館、時化學舍。右上角切換樓層，點教室會標示；底部抽屜往上拉可看本層教室，點選後放大置中；右上角放大鏡可搜尋本棟教室。
3. 搜尋：總覽的搜尋列可找建築與教室，例如「教305」「305」「環工」。
4. 課表：日／週檢視長按課程，地圖上有該教室時會出現「在校園地圖上查看教室」。
5. 其餘同 1.4.1 (29)。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟；手勢問題請說明是在總覽或哪一棟、哪一層。

## 封存與上傳

- 程式來源：`74cd252`，在 1.4.1 (29) 之後加入 `618636d`（校園地圖與 Android 版同步，圖資來源 niu-app-android `290cce9`）與 `a612eb0`（改用原生手勢並限制拖曳範圍）。
- 新增使用者功能，依版本規則由 1.4.1 改為 1.5.0；建置號由 29 遞增為 30，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-14/NIU-TestFlight-1.5.0-30.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.5.0 (30)，最低 iOS 分別為 18.6／18.0，簽章團隊 G4LXL97NF9，`codesign --verify --deep --strict` 通過；App 內含 `CampusMap/` 六份圖資，執行檔不含暫時測試用字串。
- `scripts/check-app-store.py --archive` 的「App 與 Widget 最低 iOS 相同」一項與先前相同屬既有設定差異，其餘封存項目以相同條件檢查通過。
- 驗證範圍：模擬器編譯與靜態畫面截圖（總覽、清單、深色模式、各大樓樓層、從教室代碼開啟）；以程式驅動捲動視圖確認縮放後畫面重畫與拖曳範圍。雙指縮放、拖曳、雙擊與抽屜手勢尚未在真機以手指驗證。
- 台北時間 2026-10-14 23:12:04，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查。
- 封存日誌：`/tmp/niu-testflight-1.5.0-30-archive.log`；上傳日誌：`/tmp/niu-testflight-1.5.0-30-upload.log`。
