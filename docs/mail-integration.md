# 校園信箱整合

## 使用方式與範圍

首頁「校園信箱」會沿用目前 App 帳號的 Keychain 登入資訊，自動取得校方驗證圖、在裝置上辨識並登入，再開啟 App 內的校方 NUMail 手機介面。正常登入不需要再輸入帳密。

完整功能由校方網頁提供，包含收信、寫信、回覆／全部回覆、轉寄、附件上傳、草稿、寄件備份、信件匣、搜尋和郵件管理。右上角郵件選單提供手機版、完整版與郵件設定入口；進階功能及可用設定仍以校方對該帳號開放的項目為準。這是 App 內的 Webmail 整合，並非所有畫面都以 SwiftUI 重寫。

App 補上以下行為：

- 將已確認帳號的 cookie 移交給獨立、非持久的 WebKit 儲存區；顯示信箱前再次從 WebKit 核對 `/api/auth/user`。
- 以子視窗堆疊保留附件預覽、撰寫視窗及 opener；外部網頁另在 App 內 Safari 顯示。
- 支援原生 JavaScript 確認／輸入對話框、校方列印按鈕、附件下載、Quick Look 預覽及系統分享／儲存。
- 一般返回 App 其他畫面時保留 Webmail 草稿與頁面；切換版面或重新載入前提醒儲存草稿。
- 登出、換帳號或 Webmail 登入失效時撤銷整個郵件工作階段，關閉視窗、取消下載，清除 cookie、網站資料及附件暫存。
- 不重播寄信或其他寫入請求。連線中斷或 WebKit 終止後，使用者應先核對寄件備份，再決定是否重寄。
- 附件上傳沿用 WebKit 系統選擇器，保留拍照、照片與檔案選取；實際選項依校方欄位接受的類型而定。相機用途包含郵件附件，錄製含聲音的影片附件時使用麥克風。網頁直接要求即時相機／麥克風串流仍不開放。

校方強制二次驗證時，在 App 內輸入二次驗證碼並沿用原登入工作階段。校方要求變更密碼時，需要完成校方流程並更新 App 登入資訊；無法保證此類必要互動可以省略。驗證圖辨識最多三次，失敗後可手動重試連線。

## 程式分工

- `Features/Mail/Services/MailService.swift`：隔離的 API session、校方登入、二次驗證、帳號核對及 cookie 匯出。
- `Features/Mail/Services/MailCaptchaRecognizer.swift`：受限 SVG 解析與本機 Vision 辨識。
- `Features/Mail/ViewModels/MailViewModel.swift`：App 帳號綁定、有限重試、取消／過期回應判定與 session 撤銷。
- `Features/Mail/Services/MailBrowser.swift`：WebKit 工作階段、身分閘門、子視窗、原生對話框、下載及暫存生命週期。
- `Features/Mail/Views/MailView.swift`：連線與二次驗證畫面、Webmail 容器、功能選單及附件預覽。

不將帳密、cookie 或信件內容寫入日誌。下載檔案使用獨立暫存目錄，清理檔名並啟用檔案保護；使用者透過分享另存的檔案由使用者管理。郵件不經由 NIU App 自有後端轉送。

## 驗證

```sh
python3 scripts/check-mail.py
python3 scripts/check-lifetimes.py
```

`check-mail.py` 使用 URLProtocol、合成 SVG 與隔離憑證提供者，測試登入／二次驗證、三次辨識上限、帳號核對、cookie 範圍、session 撤銷、過期回應與連線錯誤。macOS Vision 執行時需要允許本機系統服務。

開發期間使用的獨立 WebKit 範例 App 已移除。附件挑選／上傳、系統分享／列印及真實寄信，仍須在裝置上完成端到端驗收。

2026-09-30 曾以使用者授權帳號做唯讀實測：自動登入成功、收件匣 API 解析成功、cookie 移交 WebKit 後再次核對同一帳號成功，並進入 `/NUMail/Mobile/Box/INBOX`，沒有再次出現登入表單。未自行寄信、刪信、修改設定或上傳真實附件；不可把唯讀實測與合成測試當成真實寄收信全流程驗證。
