# NIU-Life 上架前檢查（2026-09-18）

## 2026-09-19 TestFlight 更新

- App 已建立於 Very Fast Network LTD：Apple ID `6813616626`，Bundle ID `dev.chienniuapp`。
- 最新工作目錄重新完成 Release Archive：`/tmp/NIU-TestFlight-20260919.xcarchive`，版本 **1.0 (1)**；封存 log 無編譯 warning/error。
- 登入、歷年成績、Widget／捷徑、WebView 生命週期、點名（20 回應及 7 WebKit fixtures）、隔離 Keychain 儲存測試全部通過；封存 metadata／圖示／privacy manifests／extension 版號與 `codesign --verify --deep --strict` 亦通過。
- 命令列匯出最初因缺少主程式與 extension 的 App Store provisioning profiles 失敗；改由 Xcode Organizer 正式發行流程完成簽章及上傳。
- Xcode 已確認 **NIU-APP 1.0 (1) uploaded / Uploaded to Apple**。後續在 App Store Connect 已確認建置處理完成，版本 1.0 的 build 1 狀態為「準備提交」，上傳日期為 2026-09-19 02:06。
- 使用者已建立內部 `test` 與「外部測試」群組。已在外部群組新增流程選取 build 1，並填寫 Beta 描述及已知聯絡資料；表單尚待聯絡電話與目前審查登入密碼，尚未完成新增／提交 Beta 審查或啟用公開連結。表單暫留 Arc，未邀請測試人員。
- 本次未重做真機完整功能操作、長時間 Instruments 記憶體分析或 IPv6-only 網路測試。既有離線測試與先前實機驗證不等於這些項目全部已重驗。

以下為 2026-09-18 的檢查紀錄；上傳狀態以上方最新更新為準。

結論：本機發現的程式／封存問題已修正並驗證；App Store Connect 資料及 Apple 端驗證尚未完成，因此不能視為已可送審或保證通過審核。本次未上傳 build、未提交審查、未建立或更動 Apple 簽章憑證。

## ❌ 送審前仍需完成

1. **2.1 審查存取方式**：2026-09-19 使用者決定提供本人的校務帳號供 Apple 審查，不另建示範模式。帳密尚未填入 App Store Connect。帳密只填入審查登入欄位，不寫入版本庫；仍需核實帳號在審查期間可登入。
2. **5.1.1 公開政策與商店隱私資料**：已建立 `docs/privacy-policy.md` 和 `docs/support.md`，目前是本機文件，尚未發布或填入 App Store Connect。需提供免登入可開啟的 HTTPS 隱私政策／支援網址，並依實際校方服務與資料處理確認 App Privacy 回答。
3. **2.3 商店內容**：App 紀錄、分類、年齡分級、描述、審查聯絡人、iPhone／iPad 截圖、版本與 build 選擇均未核實。本機沒有已設定的 asc CLI；可用瀏覽器工具未能讀取 App Store Connect，因此未對這些欄位給予通過判定。
4. **發行驗證**：Release Archive 成功不等於 App Store Connect 驗證完成。仍需經 Organizer 的發行驗證、App Store 發行簽署及上傳處理；若 1.0 (1) 已上傳，須先增加 build number。

## ⚠️ 注意事項

- 最低版本仍為 **iOS／iPadOS 26.2**，支援 iPhone 與 iPad。這不是拒審問題，但較舊系統無法安裝；本次未擅自擴充支援範圍。
- 本版本為**本機課表即時動態**，不支援開發者後端遠端更新。App 回到前景或取得系統背景執行時間時更新；不能在描述中承諾 App 關閉後一定準時更新。
- 需確認第三方校務服務及使用素材符合服務條款與權利要求（5.2）。App 已標示非官方，不代表學校；本次不替開發者認定已取得授權。
- 本次沒有實測真機長時間相機串流、IPv6-only 網路、校方完整登入和真實點名提交。先前功能確認及本機測試不能代替完整 TestFlight 驗收。
- App 只使用既有學校帳號，未提供自行建立帳號／社群登入。未找到必須在 App 中刪除「校方帳號」或新增 Sign in with Apple 的明確適用條件；審查備註應說明教育機構帳號用途。

## 已修正的問題

| 項目 | 原始問題 | 修正 |
| --- | --- | --- |
| 登出與隱私承諾 | 登出保留校務密碼、SSO token、網站 session、個人快取與 Widget 課表 | 同步清憑證／個人快取，取消通知工作、清網站資料與附件暫存、結束即時動態；完成前顯示清理狀態。中斷後可恢復清理 |
| 登出競態 | 舊課表或 EUNI 完成回呼可能在登出後恢復舊狀態 | Live Activity 與 MoodleSession generation 防護 |
| 敏感儲存 | SSO bearer token 位於 UserDefaults | 遷移至 device-only Keychain，移除明文舊值；保留 delayed rejection 防護 |
| 未完成後端 | 會嘗試將課表／installation ID／token 傳向 placeholder 網址 | 移除未完成遠端路徑，Activity 使用 `pushType: nil` |
| 隱私內容 | 登入／設定各有不同政策，宣稱不存在的 DAU／點擊分析 | 共用一份符合實作的政策，說明權限、資料保存、分享副本及本機活動 |
| 敏感診斷 | 部分日誌輸出姓名、系級及 EUNI／SSO 完整網址 | 移除直接個資、入口回應內容及敏感 URL query |
| App Icon | RGB 顏色完整但檔案仍有多餘 alpha channel | 兩張 1024×1024 圖改為 RGB，所有原始 alpha 為 255，外觀不變 |
| Bundle metadata | Archive 沒有 NIU-Life 顯示名稱，版號硬編碼 | 明確設定顯示名稱，版號引用 Xcode settings；宣告只使用豁免加密，移除未使用 frequent-updates 宣告 |

## ✅ 已通過

- Xcode **27.0 / SDK 27.0**：正式 Release Archive 與 iOS Simulator Debug build 成功；最終建置未輸出編譯 warning/error。Apple 官方 [Xcode 支援頁](https://developer.apple.com/support/xcode/)已列 Xcode 27，仍以 Apple 上傳驗證為準。
- `/tmp/NIU-App-Preflight.xcarchive`：App／Widget extension 的 `codesign --verify --deep --strict` 通過。
- `python3 scripts/check-app-store.py --archive /tmp/NIU-App-Preflight.xcarchive`：顯示名稱、版本 **1.0 (1)**、最低系統一致、App 與 extension privacy manifests 皆存在、必要權限說明、無廣泛 ATS 例外、圖示無 alpha、正式 binary 沒有 DEBUG 點名選單／scanner 診斷及 placeholder 後端字串。
- 兩份 privacy manifest 的 UserDefaults 理由 `CA92.1`、`1C8F.1` 與 standard／App Group 使用相符；未找到其他明確的 required-reason API 漏項。
- `python3 scripts/check-sso-storage.py`：使用全新隨機 Keychain service 及合成 token，驗證遷移、持久化重新讀取、新 token 覆寫、舊 401 不清新資料，以及刪除；測試後清除 fixture，不接觸真實憑證。
- 隔離 iPad Pro 13 吋／iOS 26.5 UI test：合成帳號進入設定、閱讀隱私政策、確認登出、重啟仍停留登入頁。另查核 App／App Group 個人快取與合成附件暫存均已刪除。未使用真實學生帳號。
- `check-widgets.py`、`check-attendance-response.py`（20 回應 + 7 WebKit fixtures）、`check-sso-login.js`、`check-grade-history.js`、`check-lifetimes.py` 均通過。生命週期離線 fixture 有 weak 變數風格警告，不是 App 編譯警告。
- `git diff --check` 通過；兩個獨立程式審查角色確認修正與登出競態收尾。
