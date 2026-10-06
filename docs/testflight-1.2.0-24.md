# TestFlight 1.2.0 (24)

## 測試內容

1. 行事曆「月曆」模式：月曆下方應列出所顯示月份所屬學期的全部事項（第 1 學期 8～1 月、第 2 學期 2～7 月），依月份與日期分組，跨日事件只出現一次；第 2 學期最上方另列從上學期延續的「跨學期期間」。
2. 開啟行事曆時應停在頁面頂端的月曆，不自動捲動。點選月曆日期應捲到該日事項，日期旁標示「已選取」或「今天」，包含該日的事件以文字與外框標示；該日沒有新開始的事項時，應在下一筆事項前顯示提示列。
3. 月曆捲出畫面後，右下角應出現「回到月曆」，按下後回到頂端；清單最後一張卡片不應被按鈕遮住。右上角「今天」在月曆模式捲到今天的事項，在事件模式捲回頂端。
4. 搜尋、分類篩選、切換學年度與月份箭頭應照常運作；請留意深色模式、放大文字與 VoiceOver。
5. 活動報名「我的活動」：請確認不再出現「無法辨識活動系統的頁面內容」。若仍失敗，請回報錯誤訊息最後的代碼（E201～E207）。
6. 版本更新提醒：目前 App Store 正式版為 1.1.0，比此建置舊，因此不應跳出更新提示。

若遇到問題，請附上截圖、裝置型號、iOS 版本及重現步驟。

## 封存與上傳

- 程式來源：`2f005c7`；包含 `5d8df49`（我的活動）、`7677849`（版本檢查重試）、`bbe7705`（整學期行事曆）。App／Widget 的 Debug／Release 建置號同步由 23 增為 24。
- 1.2.0 (23) 已於台北時間 2026-10-06 11:26 上傳，封存早於上述版本檢查與行事曆提交，不含這兩項修改，因此改用 24。本次沿用版本號 1.2.0。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-06/NIU-TestFlight-1.2.0-24.xcarchive`。Release archive 成功，封存日誌 0 warning／0 error。
- App／Widget 均為 1.2.0 (24)，最低 iOS 分別為 18.6／18.0，簽章團隊均為 G4LXL97NF9，`codesign --verify --deep --strict` 通過，兩者皆含隱私清單，執行檔不含 DEBUG 點名控制字串。
- `scripts/check-app-store.py --archive` 因 App 與 Widget 最低 iOS 不同（18.6／18.0）而在 `MinimumOSVersion` 斷言失敗；此設定自 `2a34540` 起即存在，21～23 建置相同，本次未變更部署目標，其餘項目改為手動核對。
- 台北時間 2026-10-06 13:07:50，Xcode 回報 `Upload succeeded` 與 `EXPORT SUCCEEDED`，Apple 已開始處理上傳的套件；尚未在 App Store Connect 確認處理狀態或可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；與先前建置相同。
- 封存日誌：`/tmp/niu-testflight-1.2.0-24-archive.log`；上傳日誌：`/tmp/niu-testflight-1.2.0-24-upload.log`。
- 本次未新增測試群組、送 Beta 審查或正式 App Store 審查，也未推送 GitHub。
