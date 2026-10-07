# TestFlight 1.3.0 (26)

## 測試內容

1. 成績查詢「歷年成績」：各學期卡片的排名應顯示「班排 第 n 名 / 總人數 人 · 系排 第 n 名 / 總人數 人」，數字與校務系統「歷年學業成績及排名」頁頂端表格一致；不應再出現第 3 名、第 0 名這類由學分數誤讀的名次。學期平均也應與校方「學業平均成績」相同。更新後第一次進入會重新抓取歷年成績（舊快取已清除）。
2. 畢業門檻「多元時數」：標題旁新增「時數紀錄」，開啟後顯示多元學習認證的活動與時數明細；離線時應保留上次資料。
3. 活動報名：活動編號旁有「報名中」或認證標籤的活動，應能正常報名與查詢；關閉提示視窗後不應吃掉隨後出現的新提示。
4. Moodle 測驗作答：題目以「試題 n：題目文字」標示，選項文字完整；未啟用計時的測驗不應被迫改用網頁，翻頁（下一頁）可保存作答，交卷仍須經過校方的總覽頁面。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟。

## 封存與上傳

- 程式來源：`a683af4`、`e28e0ad`、`7d5444d`、`17776fa`，接續 1.3.0 (25)。
- 1.3.0 尚未在 App Store 正式發布，維持版本 1.3.0；建置號由 25 遞增為 26，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-07/NIU-TestFlight-1.3.0-26.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.3.0 (26)，最低 iOS 分別為 18.6／18.0，簽章團隊均為 G4LXL97NF9，`codesign --verify --deep --strict` 通過，兩者皆含隱私清單；執行檔含本次系排名、時數紀錄與活動編號解析字串，不含 DEBUG 點名控制字串與成績 UI fixture 參數。
- 離線回歸：`check-grade-history.js`、`check-grade-state.py`、`check-event-registration.py`、`check-moodle-question-page.py`、`check-learning-hours.py`、`check-lifetimes.py` 通過。歷年成績解析另以測試帳號在校方實際頁面核對 4 個學期的班排、系排與平均。沒有執行 `scripts/check-app-store.py --archive`，也沒有模擬器／真機驗證。
- 台北時間 2026-10-07 17:24:41，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`，Apple 狀態為 Uploaded package is processing；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 封存日誌：`/tmp/niu-testflight-1.3.0-26-archive.log`；上傳日誌：`/tmp/niu-testflight-1.3.0-26-upload.log`。
