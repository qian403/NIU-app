# 圖書館通行碼

2026-09-18 以本人學生帳號確認官方學生入口網及 API。首頁入口提供門禁 QR Code 與櫃台借書條碼；目前沿用 App 的學生帳號模型。

## 官方流程

- 入口：`https://ccsys1.niu.edu.tw/SSO/libqrcode`。
- 網頁可從登入狀態取得帳號；帶 `guid` 時先經 `/SSO/API/GUID/ByGuid/{guid}` 取得帳號。GUID 不是 QR Code 內容，App 不保存或硬編碼它。
- 門禁：`POST https://sso.niu.edu.tw/QRCode/Number/`，JSON 為 `{"role":"student","acnt":"<登入帳號>"}`，回傳 `{"no":"<驗證碼>"}`。
- 圖片：`GET https://sso.niu.edu.tw/QRCode/Create?u=<URL encoded validation URL>`；validation URL 為 `https://sso.niu.edu.tw/QRCode/Validate/<驗證碼>`。只向 Create 取得圖片，不呼叫 Validate。
- 借書：`POST https://sso.niu.edu.tw/QRCode/Create/Barcode`，JSON 為 `{"ou":"student","acnt":"<登入帳號>"}`，直接回傳 PNG。
- 官方前端對這個獨立的 QRCode 網域沒有附加入口網 JWT；本人 API 呼叫已確認可取得兩種 PNG，App 不向該網域傳送 SSO JWT 或密碼。
- 官方頁面註明門禁 QR Code 僅限當日使用，每 300 秒更新目前頁籤；300 秒是重新整理週期，並非已知的驗證碼失效時間。

## App 行為與驗證

只使用 `AppState.currentUser`，沒有輸入任意學號的介面。圖碼使用 ephemeral URLSession，停用磁碟快取；不寫入日誌、UserDefaults 或相簿。切換帳號／頁籤、離開前景時隱藏舊圖片並取消請求，回到前景重新取得；台灣午夜也會更新。失敗時移除舊圖並提供重試。

驗證：iOS Simulator Debug 編譯通過；本機 Apple Vision 成功解讀官方兩種圖片，門禁 QR 內容與 API 回傳的 validation URL 相符，借書圖碼為 Code 128。未呼叫 Validate，未執行入館或借書操作。

需現場以本人帳號確認門禁機與櫃台掃描結果；API 圖片取得成功不等於實際通行或借書已驗證。教職員角色未納入本次支援。
