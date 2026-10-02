# TestFlight 1.2.0 (17)

## 測試內容

- 修正登入過期時 App 於開啟或回到前景時主動更新 SSO 的行為，改為功能遇到登入失效時才更新；先前主動更新在學校登入需要人機驗證時可能失敗並觸發冷卻，導致多數功能暫時無法使用。請檢查登入過期後開啟各項功能，確認能恢復使用且不會被冷卻阻擋。
- 請假遇到教務系統「閒置逾時」時會自動重新連線一次，保留已填的假別、日期、事由與補交設定；節次需重新查詢，附件以重新讀取結果為準，重新連線失敗時表單提供「重新連線」。送出與補檔不會自動重送。
- 請將請假表單閒置至校方連線過期，或將 App 放在背景較長時間後再回來查詢節次／繼續操作，檢查重新連線、草稿保留、節次重新查詢與附件清單是否符合預期。

## 驗證與限制

- 以下為 Claude 已驗證的結果與回報限制，本文件未另行重跑編譯或測試。
- Release Archive 成功，封存日誌 0 warning／0 error。
- `scripts/check-app-store.py --archive` 通過：archive 為 1.2.0 (17)、最低 iOS 26.2，包含內嵌 extension 與隱私清單，不含 DEBUG 點名控制。
- App／Widget 均為 1.2.0 (17)、最低 iOS 26.2；`codesign --verify --deep --strict` 通過，團隊識別碼均為 G4LXL97NF9。
- 完整模擬器編譯通過；全部離線檢查通過，含新增的 `scripts/check-leave-state.py`，涵蓋草稿保留、節次重設、附件重新讀取、各表單內恢復路徑、有界重試、手動重新連線與不重送。
- SSO 主動更新回退後，`check-sso-refresh`、`check-sso-login`、`check-sso-storage`、`check-lifetimes`、`check-app-update`、`check-enrollment-state`、`check-moodle-questions` 通過。
- 「閒置逾時」頁面內容係以未登入方式讀取校方 `/NIU/TimeoutPage.aspx` 確認；實際閒置逾時與恢復流程未在真機或真實帳號驗證。
- 使用者回報刪除 App 重新安裝後可正常登入；校方 SSO 登入頁已載入 Cloudflare Turnstile。
- 未驗證真機、實際請假送出／撤回或 Instruments 長時間量測。

## 發行紀錄

- 程式來源：本機 main 的 51c0b6f（建置號調整）；其上一個提交 7fb713d 已推送 GitHub，51c0b6f 尚未推送，預計與本紀錄一併推送。本次變更已對照 `git log 5780095..51c0b6f`，包含 8c0aede（停止主動更新 SSO）與 7fb713d（請假閒置逾時恢復）。
- 版本規則：1.2.0 尚未正式上架，沿用版本號，建置號由 16 遞增為 17。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：~/Library/Developer/Xcode/Archives/2026-10-03/NIU-TestFlight-1.2.0-17.xcarchive。
- 台北時間 2026-10-03 04:43:34，Xcode 回報 Upload succeeded 與 EXPORT SUCCEEDED；Apple 狀態為 Uploaded package is processing。
- 尚未在 App Store Connect 確認處理完成或可安裝測試（瀏覽器擴充未連線）；未加入測試群組，未送 Beta 或正式審查。
- 1.2.0 (16) 含上述 SSO 主動更新問題，建議測試改用 1.2.0 (17)。
