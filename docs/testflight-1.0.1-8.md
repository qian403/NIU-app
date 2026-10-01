# TestFlight 1.0.1 (8)

## 測試內容

- 新增首頁「在學證明」：查詢註冊資料、顯示校方原始 PDF，並透過系統分享或列印。
- 包含先前的 M 園區點名登入與驗證碼處理優化；點名結果仍以校方回應為準。
- 包含設定頁連線檢查的逾時與取消修正。

請確認在學證明可以讀取註冊資料、顯示 PDF；登入失效時可完成校方要求的互動。請檢查離開畫面、重新查詢及切換帳號後不會顯示前一次資料。PDF 列印需選擇實際印表機並確認輸出。

點名請檢查成功、已完成、QR Code 過期與需要重新登入的結果是否清楚；請勿在回報中附上帳密、登入憑證、完整在學證明或有效點名連結。

## 建置與驗證紀錄

- 2026-09-30，來源為 `b619ba1`，另將 App／Widget 的 Debug／Release Build 同步由 7 增至 8；版本維持 1.0.1，發行團隊為 `G4LXL97NF9`。
- 上傳前以 Arc 核對 App Store Connect：最新建置為 1.0.1 (7)，上傳處理完成；正式版本 1.0.1 正在等待審查。本次未替換該審查建置。
- Release Archive 成功，編譯日誌無 warning/error。上架靜態檢查、封存版本／隱私宣告／Widget 一致性與 `codesign --verify --deep --strict` 通過。
- 同一來源在前一步 GitHub 推送驗證中，App／Widget Debug 模擬器編譯、點名登入與回應、SSO 登入與隔離儲存、連線狀態、在學證明解析／PDF／狀態及生命週期檢查通過。
- 在學證明另以 iPhone 17 Pro 模擬器執行獨立測試 App，使用合成 WebKit 頁面驗證掛載、框架解析、沿用登入、有限次恢復與取消清理。測試腳本有 sysroot 工具鏈警告，執行結果通過；未連線校方點名、未重做真機或 AirPrint 驗收。
- 封存：`~/Library/Developer/Xcode/Archives/2026-09-30/NIU-TestFlight-1.0.1-8.xcarchive`。
- 台北時間 2026-09-30 00:15:43，Xcode 回報 `Upload succeeded`、`EXPORT SUCCEEDED`。隨後以 Arc 確認 App Store Connect 出現 1.0.1 (8)，狀態為「準備提交」、90 天後到期；尚未列入測試群組。建置 ID 為 `77f7c8b9-22d2-4e58-a116-35bd0a91dc0b`。
- 本次只上傳建置，未新增內部／外部測試群組、未送出 Beta 或正式 App Store 審查、未替換等待審查的既有版本。Build 與本文件更新留在本機，未另行推送 GitHub。
