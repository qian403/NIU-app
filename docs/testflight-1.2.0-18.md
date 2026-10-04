# TestFlight 1.2.0 (18)

## 測試內容

- 校園信箱改為原生收發信（IMAP／SMTP），不再載入 Webmail：
  - 信箱列表、信件列表（未讀、預覽、附件／旗標、左右滑動與長按操作、搜尋）。
  - 讀信頁：詳細資訊、附件下載／預覽／分享、內嵌圖片。
  - HTML 信件以安全方式顯示：停用網頁 JavaScript，外部圖片預設不載入，可手動載入 HTTPS 圖片；寬版信件會縮小到符合螢幕寬度。
  - 寫信：收件人標籤、副本／密件副本、附件、回覆／全部回覆／轉寄；寄出後顯示「正在傳送」、「郵件已寄出」或失敗原因與「開啟草稿」。
  - 開啟信件會標為已讀。
- Moodle 作業可依截止日排序，預設「近的在上」。
- Moodle 課程頁新增搜尋，公告、作業、問答、資源、出缺席、成績共用同一個關鍵字。
- 請用真實帳號測試：收信與換信件匣、讀 HTML 通知信（例如校務入口登入通知）、下載附件、寄信給自己（含副本／密件副本與附件）、回覆與轉寄、登出後再登入確認郵件清空。

## 驗證與限制

- 發行前審查：Codex 對抗式審查 2b8e0a2..e53a972，發現兩項中度問題並已修正（寄件備份遺失密件副本、附件大小以編碼後大小判斷），複審時另修正 Base64 預算向下取整，最終複審無發現。另修正 `check-moodle-questions.py` 缺少 `MoodleSearch.swift`。
- Release Archive 成功，封存日誌 0 warning／0 error。
- `scripts/check-app-store.py --archive` 通過：archive 為 1.2.0 (18)、最低 iOS 26.2，包含內嵌 extension 與隱私清單，不含 DEBUG 點名控制。
- App／Widget 均為 1.2.0 (18)；`codesign --verify --deep --strict` 通過，團隊識別碼均為 G4LXL97NF9。Release 二進位不含郵件 DEBUG UI fixture。
- 模擬器 Debug 編譯通過；所有不需裝置的離線檢查（Python／Node）通過；行事曆資料 validate、unittest、build_review --check 通過。需 `--device` 的 UI 檢查本次未執行。
- 郵件畫面以 DEBUG 合成資料在 iOS 26.5 模擬器截圖檢查（列表、讀信、HTML、寫信、寄送提示、深色模式、大字級）；模擬器無法點擊，互動未實測。
- 未以真實帳號收寄信、未在真機驗證郵件與 Moodle 搜尋／排序；未做 Instruments 長時間量測。

## 發行紀錄

- 程式來源：本機 main 的 2caaaa7（建置號調整）；本次變更為 `git log b5b5c5f..2caaaa7`：2b8e0a2（原生郵件）、927ae9f（作業排序）、e53a972（課程搜尋）、5f1cdbb（審查修正）、2caaaa7（建置號）。2b8e0a2..e53a972 已推送 GitHub；5f1cdbb 之後尚未推送。
- 版本規則：1.2.0 尚未正式上架，沿用版本號，建置號由 17 遞增為 18（依 1.2.0 (17) 發行紀錄判斷先前最大建置號為 17）。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：~/Library/Developer/Xcode/Archives/2026-10-04/NIU-TestFlight-1.2.0-18.xcarchive。
- 台北時間 2026-10-04 14:08:30，Xcode 回報 Upload succeeded 與 EXPORT SUCCEEDED；Apple 狀態為 Uploaded package is processing。
- 尚未在 App Store Connect 確認處理完成或可安裝測試；未加入測試群組，未送 Beta 或正式審查。
