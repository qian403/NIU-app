# TestFlight 1.2.0 (19)

## 測試內容

- M 園區新增依學期的課程首頁、跨課程即將截止作業及課程總覽；改善未知繳交狀態、繳交後跨頁更新與公告分頁。
- 「即將截止」可點標題收合／展開，保留作業數量及錯誤提示，搭配箭頭旋轉與收折動畫。
- 活動新增收藏、多選、逐筆批次報名與已報名活動本機提醒；長按後的選取勾勾置於愛心旁，加入選取動畫。
- 修正活動舊頁回呼、結果不明時重複送出、換帳號狀態隔離及通知容量／失敗快取處理。
- 建議測試 M 園區切換學期、作業入口與收折、活動收藏與多選；批次報名確認後會實際送出校方紀錄。

## 驗證與限制

- 本輪開發已通過 Moodle、活動、生命週期、通知、Widget 及 SSO 相關離線檢查，詳見功能驗收文件。
- 收折修改通過 Debug 編譯及 Moodle 首頁／即將截止兩項檢查；iPhone 17 Pro／iOS 26.5 模擬器以合成資料確認收合、展開與「查看全部」，並檢查深色模式、最大輔助字級及無障礙按鈕狀態。
- Release 裝置編譯與 Archive 均成功，日誌各為 0 warning／0 error。
- `scripts/check-app-store.py --archive` 通過，App／Widget 均為 1.2.0 (19)、最低 iOS 26.2，隱私清單與內嵌 extension 完整。
- App／Widget 的 `codesign --verify --deep --strict` 通過，團隊均為 G4LXL97NF9；Release 二進位不含 Moodle、活動及郵件 DEBUG fixture 啟動標記。
- 未以真實帳號執行批次報名，未驗證真機通知或進行 Instruments 長時間量測。

## 發行紀錄

- 程式來源：`119d544`；包含截至 `f86f5a4` 的功能修改，並將 App／Widget 的 Debug／Release 建置號同步由 18 增為 19。
- 上傳前已透過 Arc 的 App Store Connect 核對最新版本為 1.2.0 (18)，本次沿用 1.2.0。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-05/NIU-TestFlight-1.2.0-19.xcarchive`。
- 台北時間 2026-10-05 02:22:14，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`。
- 上傳後已透過 Arc 的 App Store Connect 確認上傳清單出現 1.2.0 (19)，建立時間為 2026-10-05 02:22，當下狀態為「處理中」；尚未確認可安裝測試。
- 本次未手動加入測試群組、送 Beta 審查或正式審查。
