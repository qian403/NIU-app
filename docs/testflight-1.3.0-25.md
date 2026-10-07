# TestFlight 1.3.0 (25)

## 測試內容

1. 成績查詢「歷年成績」：最上方為 GPA 總覽（累計 GPA、加權平均、實得學分、課程數），兩個學期以上時顯示各學期 GPA 走勢圖；各學期卡片預設全部收合，點選才展開。學期標題應為「114 學年度下學期」格式，班級排名獨立一行、不被截斷。
2. GPA 旁的 i 按鈕：應說明校方沒有提供 GPA、App 依各科成績換算可能有誤差且僅供參考，並列出公式、4.3 制分數對照與採計規則。抵免、通過等文字成績與 0 學分課程不計入 GPA，但算實得學分。
3. 成績查詢「期中／期末」：沒有成績時只顯示空狀態；有成績時數據卡顯示「已公布 n / 總數 科」。
4. 課表設定頁：本機自訂課程與製作課表桌布。
5. 畢業門檻全數達成時應顯示彩帶。
6. 捷徑：新增的校園操作與課表即時動態更新；動態島應在第一堂課前 30 分鐘才顯示。
7. 請假：登入與頁面載入、狀態標籤對齊。郵件：連線失敗時應提示校內網路可能阻擋 SMTP。
8. 版本更新提醒：目前 App Store 正式版為 1.2.0，比此建置舊，因此不應跳出更新提示。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟。

## 封存與上傳

- 程式來源：`ccd0d66`；包含 1.2.0 (24) 之後的 `a9ccbd7`、`beea1a1`、`d04dc80`、`07f845c`、`a82787a`、`69d76e5`、`39a9a21`、`248b91f`。
- 1.2.0 已於台北時間 2026-10-06 15:34 在 App Store 正式發布，不能再上傳同版本建置；本次含新增功能，依版本規則升為 1.3.0。建置號由 24 遞增為 25，App／Widget 的 Debug／Release 設定同步修改。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-07/NIU-TestFlight-1.3.0-25.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.3.0 (25)，最低 iOS 分別為 18.6／18.0，簽章團隊均為 G4LXL97NF9，`codesign --verify --deep --strict` 通過，兩者皆含隱私清單；執行檔不含 DEBUG 點名控制字串與成績 UI fixture 參數，含本次成績頁文字。
- 本次沒有執行 `scripts/check-app-store.py --archive`（先前建置會因 App 與 Widget 最低 iOS 不同而在 `MinimumOSVersion` 斷言失敗），以上項目為手動核對。也沒有執行離線回歸測試或模擬器／真機驗證。
- 台北時間 2026-10-07 14:51:56，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`，Apple 狀態為 Uploaded package is processing；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 封存日誌：`/tmp/niu-testflight-1.3.0-25-archive.log`；上傳日誌：`/tmp/niu-testflight-1.3.0-25-upload.log`。
