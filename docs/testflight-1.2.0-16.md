# TestFlight 1.2.0 (16)

## 測試內容

- 請假首頁先列出自己的假單與審核結果，可依校方開放的操作申請、撤回、修改或補交證明；撤回後明確區分「已撤回假單」與「撤回結果尚未確認」，假單內容新增簽核流程與退回原因。
- 在學證明新增查詢進度、目前學期摘要與狀態標籤，底部提供顯示證明按鈕，查詢時間使用中文日期；修正登入過期時未及時辨識登出頁而等待過久的情況。
- 修正 M 園區漏接 SSO 登入失效頁面的情況，並清理可能包含敏感資訊的登入與 Moodle 日誌；請檢查登入過期後重新開啟 M 園區的流程。
- 點名登入驗證碼辨識失敗時，先自動點擊驗證碼圖片換新並重新辨識；重試仍有次數上限，必要時顯示手動登入頁。
- 每日首次回到前景時查詢 App Store 版本，僅在商店版本較新時顯示更新提醒，可選擇「前往更新」或「我知道了」；比商店版本新的 TestFlight 建置不會提醒。
- 郵件包裹優先顯示個人包裹，手動查詢獨立操作；請檢查個人包裹與手動查詢結果的切換。
- 更新特別感謝名單與頭像顯示，改善淺色模式卡片對比；修正 M 園區課程標題與圖示對齊，活動分享文字新增活動編號。

## 驗證與限制

- 以下為 Claude 已驗證的結果與回報限制，本文件未另行重跑編譯或測試。
- Release Archive 成功，封存日誌 0 warning／0 error。
- `scripts/check-app-store.py --archive` 通過：archive 為 1.2.0 (16)、最低 iOS 26.2，包含內嵌 extension 與隱私清單，不含 DEBUG 點名控制。
- App／Widget 均為 1.2.0 (16)、最低 iOS 26.2；`codesign --verify --deep --strict` 通過，團隊識別碼均為 G4LXL97NF9。
- 封存前於 main 完整模擬器編譯通過；全部 30 項離線檢查通過。
- 模擬器檢查 `check-home-navigation`、`check-enrollment-webview`、`check-postal-ui` 通過；`check-sso-refresh-webview` 偶發失敗，涉及冷啟動與「Hidden refresh blocked the app」，以不含本次變更的基準版本重複比對確認為既有不穩定，暖機後通過。
- 真實校方驗證碼離線測試共 30 張樣本，24 張辨識全對、0 誤判、6 張放棄；模擬器上每張約 2.5–11 秒，實機時間未量測，未以真實帳號登入或送出。
- 未驗證真機、實際點名、實際撤回／修改／補檔送出或 Instruments 長時間量測。

## 發行紀錄

- 程式來源：本機 main 的 9147bf2（版本號與建置號調整）；其上一個提交 95413db 已推送 GitHub，9147bf2 尚未推送。
- 版本規則：1.1.0 已於 App Store 公開，台灣 App Store lookup 回傳 1.1.0，故開新版本列；新增使用者功能採次版本 1.2.0，建置號延續 15 遞增為 16。
- 上傳前未能以 App Store Connect 網頁核對最新建置（瀏覽器擴充未連線）；以所有分支、工作樹、本機封存與上傳紀錄確認最新為 1.1.0 (15)。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：~/Library/Developer/Xcode/Archives/2026-10-03/NIU-TestFlight-1.2.0-16.xcarchive。
- 台北時間 2026-10-03 03:29:31，Xcode 回報 Upload succeeded 與 EXPORT SUCCEEDED；Apple 狀態為 Uploaded package is processing。
- 尚未在 App Store Connect 確認處理完成或可安裝測試；未加入測試群組，未送 Beta 或正式審查。
