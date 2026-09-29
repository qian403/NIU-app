# 在學證明

首頁「在學證明」可查詢當學期註冊資料，顯示校方原始 PDF，並使用 iOS 分享選單儲存檔案或開啟系統列印。列印仍需使用者選擇印表機並送出。

## 校方流程

2026-09-29 透過使用者已登入的 Arc 確認：

- 教務系統 → 學籍及畢審 → 註冊作業 → 查詢註冊。
- 入口為 `/NIU/Application/ENR/ENR50/ENR5020_.aspx?progcd=ENR5020`，內容框架為 `ENR5020_01.aspx`。
- `DataGrid` 使用 `th` 標頭，保留註冊學年期、在學狀態、註冊狀態與日期原文。
- `GoToPrint` 按鈕的 `doGoToPrint()` 會開啟 `https://ccsys.niu.edu.tw/MvcTeam/AcadeExport/StudyProved/{學號}`，瀏覽器顯示含校方章戳的 PDF。App 僅使用本次登入帳號匹配的學號，不提供查詢他人學號的輸入。

App 先使用共用 WKWebsiteDataStore 的 acade cookie 直接進入 MainFrame；有效時不交換 GUID，也不重跑 SSO 登入。只有主頁或實際註冊內容框架確認登入失效，才以既有 SSO token 交換一次新 GUID 補建 acade session；該步仍確認登入失效時，ViewModel 最多更新一次 SSO 後重建查詢。離線、逾時與解析錯誤不觸發重新登入。

進入 MainFrame 後，從 `menuFrame` 找到「查詢註冊」並呼叫校方選單連結，保留其 target 與原本框架；不把 `ENR5020_.aspx` 替換成最上層頁面。解析僅接受 `ENR5020_01.aspx` 的資料。逾時偵測限定選單指定的內容框架及其子孫、或 src 指向註冊外框的框架，不將 MainFrame 預載的隱藏逾時頁視為使用者登入失效。

點選選單時記住目標框架的舊文件，新文件載入前跳過整個舊子樹，避免讀到前一次註冊資料或將舊 Default 頁誤判為本次登入失效。註冊子框架轉往校方 SSO 登入頁時，在導覽提交前確認其框架範圍，再啟動有限次登入恢復；不放寬其他網域的導覽限制。

查詢用 WebView 由 SwiftUI 掛在原生清單後方，保留正常尺寸；不再使用未掛載的零尺寸頁面。右上角「校方頁面」可顯示同一個 WebView，等候超過 8 秒也會自動顯示，以便完成校方互動或查看停留位置。載入文字區分讀取校務資料、沿用既有登入連接教務系統、開啟註冊查詢與讀取註冊結果；診斷日誌只記階段、路徑及錯誤碼，不記 GUID、cookie 或帳號。

舊版入口僅放行 `ccsys.niu.edu.tw/SSO/Std002.aspx` 與 `StdMain.aspx`，完成後接續 acade MainFrame；未知主頁重新導向立即回報錯誤，不因自行取消導覽而一直等待。`ccsys` 與 `ccsys1` 的 `/SSO/login` 都視為登入失效。後續使用者日誌確認已到 MainFrame 及註冊外框 ENR5020_.aspx；登入轉接已完成，但並未取得內層註冊結果，因此改為保留校方框架並從選單進入。

PDF 的 MvcTeam session 與現代 SSO 分開處理。若伺服器要求登入，顯示「開啟校方登入頁」，使用者可在可見的校方頁面操作，完成後返回再按「顯示在學證明」。不以更新 JWT 假設 MvcTeam 已登入，也不將任意重新導向當成登入頁。

## 個人資料與生命週期

App 不另存註冊資料與 PDF；原生畫面資料僅留於畫面生命週期的記憶體中。PDF 請求使用 ephemeral URLSession，不寫入 App 的文件快取或 UserDefaults。校方網頁沿用既有 WKWebsiteDataStore，其 cookie 與網站資料由 App 登出流程清理。分享使用 PDF DataRepresentation，僅在使用者開啟系統分享後匯出。系統或使用者另存的文件不屬於 App 的記憶體資料。

離開頁面、登出或換帳號會取消工作並清除資料。回應必須同時匹配請求世代、登入 session 與帳號；舊請求不能恢復已清除的資料。PDF 驗證 HTTP、來源、MIME、檔頭、可讀頁數與 15 MiB 上限；不將登入 HTML 當 PDF，也不重製或修改校方證明。

## 驗證

```sh
node scripts/check-enrollment-page.js
python3 scripts/check-enrollment-state.py
python3 scripts/check-enrollment-pdf.py
node scripts/check-sso-login.js
python3 scripts/check-sso-storage.py
python3 scripts/check-lifetimes.py
# 指定已啟動的模擬器；安裝獨立測試 App，不使用主 App 的網站資料或 Keychain
python3 scripts/check-enrollment-webview.py --device <模擬器-UDID>
```

新增檢查均使用合成資料，不發出證明請求、不使用真實 Keychain 帳密。SSO 儲存檢查使用隨機隔離的 Keychain service。

本次結果（2026-09-29）：上述離線檢查與 `git diff --check` 通過；App 及 Widget 的 Debug 模擬器編譯通過。iPhone 12 mini 的隔離測試使用實際 SwiftUI 畫面、WebView、Service 及 ViewModel，並以 WKURLSchemeHandler 提供全本機的 MainFrame、menuFrame、隱藏逾時頁、註冊外框與內層資料頁。確認 WebView 的 `window` 非空、尺寸正常，顯示校方頁面後仍是同一個實例；選單導覽保留 MainFrame，能解析內層註冊紀錄。模擬有效 session 時 GUID 呼叫為零；主頁或註冊外框直接轉向登入頁時，只補建一次連線，無須呼叫現代 SSO 登入。完成、重查與取消會停止載入並清除舊頁面的 delegate 及畫面引用。沒有向校方送出測試請求。

桌面控制工具無法讀取模擬器視窗，因此尚未目視確認深色模式、放大文字、分享與列印介面的實際呈現。Arc 已登入情境下確認校方原始 PDF；沒有驗證無 cookie 的端點行為。

再次複查增加舊文件／新文件切換與跨來源 SSO 重新導向測試。隔離 WebKit 測試確認延遲導覽期間不讀取舊註冊資料、真正註冊子框架轉向 SSO 時只橋接一次，隱藏且無關的登入框架不觸發橋接；這些結果來自本機合成回應。

正式使用前仍應於登入的 App／真機核對完整校方串接，並使用實際 AirPrint 印表機檢查紙張輸出；瀏覽器成功顯示校方 PDF、離線測試及模擬器 UI 驗證不能取代上述檢查。
