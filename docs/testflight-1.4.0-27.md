# TestFlight 1.4.0 (27)

## 測試內容

1. Moodle 測驗作答流程：測驗首頁可直接按「開始測驗／繼續作答／再測驗一次」。作答頁上方有答案卡（作答後題號塗黑，點題號可跳題，跨頁時會先保存本頁）與已作答進度；最後一頁按「檢查並交卷」進入交卷前檢查，未作答題會以橘色提示，可點回該題；交卷時只出現校方的確認視窗一次，交卷後進入複習頁，底部為「完成複習」。
2. 題型：配合題、下拉克漏字、綜合克漏字、拖放文字可在原生畫面作答（每格點開後選擇，可清除）；排序題以上移／下移調整；申論題（一般編輯器）可直接輸入；多選題為單一題目。圖片拖放與需要上傳附件的申論題仍會引導至校方頁面。
3. 計時測驗：上方顯示倒數，剩 5 分鐘轉橘、剩 1 分鐘轉紅；作答會即時寫入校方頁面，時間到由校方自動交卷時應保留已選的答案。
4. M 園區登入：M 園區登入過期（約 4 小時）後開啟測驗，應自動恢復登入並直接進入題目，不應出現 M 園區登入頁；只有 App 的校務帳號本身無法登入時才會要求處理。
5. 快速點名：可輸入同學分享的點名連結。
6. 自訂課程：可選擇課程顏色。
7. 選課查詢、行事曆 Widget「接下來的重要事件」與版本更新提醒（不應因快取誤判）照常運作。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟。實際開始或交卷測驗會影響校方作答紀錄，建議使用練習用測驗。

## 封存與上傳

- 程式來源：`4ca9980`，包含 1.3.0 (26) 之後的 `4376938`、`04fc726`、`919ed77`、`ef5f2c9`、`e96bc3b`、`c9e9f7b`、`564eaa4`、`0a97487`。
- 1.3.0 已在 App Store 正式發布；本批含新使用者功能，依版本規則升為 1.4.0，建置號由 26 遞增為 27，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-08/NIU-TestFlight-1.4.0-27.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.4.0 (27)，最低 iOS 分別為 18.6／18.0，簽章團隊均為 G4LXL97NF9，`codesign --verify --deep --strict` 通過，兩者皆含隱私清單；執行檔含新版測驗橋接與介面字串，不含 DEBUG 點名控制字串、測驗實驗室與模擬帳號字串。
- `scripts/check-app-store.py --archive` 在「App 與 Widget 最低 iOS 必須相同」一項失敗；兩者不同是 1.2.0 起的既有設定（App 18.6／Widget 18.0），腳本尚未更新。其餘封存項目改以相同條件手動檢查並通過；不含封存的 `check-app-store.py` 通過。
- 離線回歸：`check-moodle-question-page.py`（18 項）、`check-moodle-questions.py`（7 項）、`check-moodle-question-detail.py`、`check-lifetimes.py`、`check-sso-storage.py`、`check-sso-login.js`、`check-attendance-response.py`、`check-attendance-login.js`、`check-attendance-captcha.py` 通過。測驗流程另在本機 Moodle 5.0（Moove、zh_tw）合成資料上以瀏覽器與模擬器驗證；尚未以宜蘭大學實際測驗或真機驗證，自動恢復登入亦未以真實帳號驗證。
- 台北時間 2026-10-08 18:00:14，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`，Apple 狀態為 Uploaded package is processing；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查。
- 封存日誌：`/tmp/niu-testflight-1.4.0-27-archive.log`；上傳日誌：`/tmp/niu-testflight-1.4.0-27-upload.log`。
