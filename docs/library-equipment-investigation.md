# 圖書館設備預約流程調查

調查日期：2026-10-01（Asia/Taipei）。

本次完成網站流程調查，並加入 App 的單日時段設備預約功能。實際校方驗證僅涵蓋登入與唯讀查詢；未建立、取消、續借或歸還任何真實設備預約。

## 驗證方式與界線

- 使用瀏覽器登入 [校方設備預約頁](https://webpacx.niu.edu.tw/equipment)，查看設備群組、單日時段概況與個人預約／借閱紀錄。
- Playwright Extension 無法使用；後續改用本機 Playwright 與獨立 Chrome context，透過 request／response 事件擷取瀏覽器實際請求。
- 從網站實際載入的公開 JavaScript 確認 GraphQL operation、variables、加密與 session 同步流程。
- 依公開程式使用相同格式，另行重播登入與唯讀 HTTP 請求，驗證實際回應。帳密以隱藏輸入提供；帳密、cookie 與 CSRF token 僅保留在該程序記憶體。
- Playwright 完成登入、從群組卡片進入時段頁、選取 iSmart 504 的 15:00–16:00，並開啟確認視窗；未按視窗內最終送出按鈕。獨立 browser context 未保存 storage state，檢查完已關閉。
- 瀏覽器實測另設 mutation 攔截防護：只允許此次授權的 `SSOLogin`，其餘設備異動會被阻擋。本次紀錄沒有設備異動 mutation，也沒有觸發這項攔截。
- 實際請求紀錄共 12 筆，保存為去識別化資料：登入 variables 隱去帳密／驗證碼，cookie／CSRF 僅記錄是否存在，`/datases` 只記錄 HTTP 狀態；未保存原始 session 回應。
- 預約、週期預約及取消 mutation 僅確認公開程式格式，未執行；不能將它們列為已通過實際操作驗證。
- 以下設備 ID、政策與數量是本次觀察值，實作需以即時 API 為準。

## 網站流程

1. 未登入時，設備入口顯示「該功能需要登入才能使用」並開啟讀者登入視窗。
2. 登入說明為校內讀者使用 webmail 帳密。這是圖書館網站自己的登入與 session，不能僅依 App 的校務／Moodle 登入狀態認定可用。
3. 登入後先顯示設備群組、預約日期、起訖時段與目前可用數量。
4. 單日時段概況可選設備、切日期、切平行／垂直檢視，並區分他人占用／不可預約與自己的預約。
5. Playwright 實測確認：選取時段後，畫面上的第一個「確認預約」會開啟確認視窗並查詢政策；視窗內的送出才呼叫預約 mutation。本次確認視窗顯示 iSmart 504、2026/10/01、15:00–16:00、共 1 小時、每次最小 1 小時、每次最大 4 小時與可預約總上限 28 小時。
6. 個人紀錄頁分成目前借閱與目前預約，另有預約歷史入口。本次瀏覽器顯示目前沒有借閱／預約資料。

網站具有「單日時段」與「全日／多日」模式，另有週期預約程式。本次有政策的四個可選群組皆為 `timeType: 0`（時段）；沒有驗證可用的全日／多日設備或週期預約送出結果。

## HTTP 與登入

GraphQL 入口：

```text
POST https://webpacx.niu.edu.tw/api/HyLibWS/graphql
Content-Type: application/json
X-CSRF-Token: <目前 session 的 CSRF token>
Cookie: <同一個網站 session，由 cookie 容器管理>
```

Body：

```json
{
  "operationName": "<operation 名稱>",
  "variables": {},
  "query": "<GraphQL 文件>"
}
```

網站有 `<base href="/">`，所以程式中的相對路徑 `api/HyLibWS/graphql` 指向站台根目錄，不是 `/equipment/api/...`。Apollo client 使用 `credentials: "include"`，並為請求加入 `X-CSRF-Token`。

登入前，網頁的 `__NEXT_DATA__.props.pageProps.session` 提供初始 session／CSRF 資訊；這些值不得寫入版本庫、診斷紀錄或公開 fixture。

### 帳密登入

```graphql
mutation SSOLogin($user: String!, $pass: String!, $captcha: String) {
  ssoLogin(user: $user, pass: $pass, captcha: $captcha, encrypt: true) {
    success
    message
    sessionID
    errorType
    licenseStatus
    chPaLink
    ttl
    loginChooseReaderList {
      readerId
      readerCode
      readerName
      licenseStatusId
      readerTypeId
      keepsiteId
      memberPic
    }
  }
}
```

- `user` 與 `pass` 各自使用 AES-256-CBC、PKCS#7 padding。
- 每個值產生獨立的隨機 16-byte IV，格式為 `<IV 的 hex>:<ciphertext 的 Base64>`。
- 加密參數來自校方公開前端。這不取代 HTTPS，也不代表可以持久化加密後的帳密。
- 登入前查詢 `hyLibCore.webpac.Login.IschkImg`；本次不需要 CAPTCHA，`captcha` 傳空字串。實作仍須支援校方改為要求人機驗證時的可見互動。
- 網站登入後呼叫 `/datases` 同步 session，公開程式會解碼其中資料。Playwright 已擷取到 `GET /datases` 的 HTTP 200 回應；較早的 HTTP 重播則重新取得 `/equipment`，確認 `auth` 並取得更新的 CSRF token，後續查詢成功。
- `errorType` 不只有帳密錯誤：公開程式包含密碼規則／到期、借閱證狀態與選擇借閱證等分支。須以 `success`、`message`、`errorType` 判斷，不能以 HTTP 200 判斷登入成功。

## 設備與時段查詢

| 用途 | operation／欄位 | 主要 variables | 本次驗證 |
| --- | --- | --- | --- |
| 登入前確認 CAPTCHA 設定 | `getIschkImg` → `getRedisHyLibCoreDetailByKeys` | `Input.keys` 為 `hyLibCore.webpac.Login.IschkImg` | HTTP 200；本次無需 CAPTCHA |
| 帳密登入 | `SSOLogin` → `ssoLogin` | 加密的 `user`、`pass`；`captcha` | HTTP 200；`success: true`，`errorType: 0`；重新載入頁面 `auth: true` |
| 群組與可用數量 | `getEquipmentGroupInfo` | `groupId: 0` | HTTP 200；取得群組、政策與設備數量 |
| 指定群組當日時段資料 | `getEquipmentInfo` | `groupId: 5`、`startdate: "2026/10/01"` | HTTP 200；取得設備清單與占用期間 |
| 指定設備預約限制 | `getDayReservedByReader` | `groupId: 5`、`equipId: 56`、`reserveDate: "2026/10/01"` | HTTP 200；取得可解析的政策 JSON 字串 |
| 個人預約／借閱紀錄 | `getEquipmentByReader` | 欄位參數 `status: "Reserve"`／`"Borrow"` | 瀏覽器確認空紀錄；operation 格式由公開程式確認 |

Playwright 實際擷取的關鍵順序：

```text
POST /api/HyLibWS/graphql  SSOLogin                 -> HTTP 200, success: true
GET  /datases                                     -> HTTP 200
POST /api/HyLibWS/graphql  getEquipmentGroupInfo   -> HTTP 200
POST /api/HyLibWS/graphql  getEquipmentInfo        -> HTTP 200
POST /api/HyLibWS/graphql  getDayReservedByReader  -> HTTP 200, success: true
```

上述四個 GraphQL 請求均確認帶有 cookie 與 CSRF header。時段頁實際 variables 為 `{"groupId":"5","startdate":"2026/10/01"}`，確認視窗為 `{"groupId":"5","equipId":56,"reserveDate":"2026/10/01"}`。網站部分欄位雖宣告 GraphQL `Int`，前端實際仍傳群組 ID 字串；App 接入需以實際驗證結果處理型別。

### 群組回應

`getEquipmentGroupInfo.eqgroupitemlist` 包含：

- `equipmentGroup`：`id`、`name`、`genreId`、`webpacDisplay`。
- `ebPolicy`：`id`、`timeType`，可能為 `null`。
- `useNum`、`equipmentNum`、`linenum`。

| groupId | 群組 | 設備數量 | ebPolicy.timeType | 網站本次是否列為可選群組 |
| --- | --- | --- | --- | --- |
| 5 | 宜思智慧小間 | 3 | 0 | 是 |
| 6 | Switch相關設備 | 1 | 0 | 是 |
| 7 | 長期研究小間511 | 1 | 無政策（`ebPolicy: null`） | 否 |
| 8 | 臨時研究小間 | 2 | 0 | 是 |
| 10 | 大型討論室 | 3 | 0 | 是 |

不能單純把 API 回傳的所有群組都顯示為可預約。應沿用網站的政策／模式篩選，並確認 `webpacDisplay` 的實際用途。

宜思智慧小間的本次設備清單：

| equipId | 名稱 |
| --- | --- |
| 56 | iSmart 504 |
| 57 | iSmart 505 |
| 58 | iSmart 506 |

### 時段與政策

`getEquipmentInfo` 是前端組合查詢，包含：

- `getEquipmentGroupInfo(groupId)`：群組與開放時間調整資訊。
- `getReserveEquipmentList(groupId, startdate)`：設備、占用 `equipmentCir.startDate/endDate` 與 `reserveCountByUser`。
- `getEquipmentInfoList(groupId)`：完整設備清單。
- `getEquipmentByReader(status: "Reserve")`：個人預約數量。
- `getDayReservedByReader(...)`：預約規則；確認視窗也會用實際 `equipId` 另外查詢。

網站時段頁的初始組合查詢把政策欄位的 `equipId` 寫成 `1`；本次這個欄位回傳 `success: false`，但設備清單與占用時段仍有資料。開啟 iSmart 504 確認視窗後，另以實際 `equipId: 56` 查詢政策才回傳 `success: true`。App 應查詢所選設備的規則，不沿用這個固定 ID，也不能將初始組合查詢某個欄位失敗直接當成整個設備清單失敗。

政策欄位 `data` 是 JSON **字串**，需要再解析。以下為智慧小間本次回應：

```json
{
  "canReserveMinUnit": "1.0",
  "canReserveMaxUnit": "4.0",
  "maxCanReserveTotalUnit": "28.0",
  "inReserve": "0.0",
  "openTime": "08:00",
  "closeTime": "21:30"
}
```

網站在時段模式以小時計算這些使用單位：最短 1 小時、單次最多 4 小時；剩餘總額度採 `maxCanReserveTotalUnit - inReserve`。`28` 的後端統計期間尚未確認，不自行標示為每日／每週額度。

時段格的刻度是 30 分鐘，不能直接視為最低可預約長度。起訖需連續，不得跨過已占用時段；過去時段、他人預約與自己的預約需分別處理。

網站也讀取下列公開設定；不能把首頁的通用開閉館時間硬套所有設備：

```text
GET /hylibcore/hyLibCore.circulate.calendars.openTime
GET /hylibcore/hyLibCore.circulate.calendars.closeTime
```

時段頁還會套用群組 `starttime/endtime` 調整或政策回應的 `openTime/closeTime`。

## 預約 mutation（僅確認格式，未送出）

### 單次預約

```graphql
mutation reserveEquipmentCir(
  $starttime: String
  $endtime: String
  $equipId: Int
  $groupId: Int
  $muserid: Int
) {
  reserveEquipmentCir(
    starttime: $starttime
    endtime: $endtime
    equipId: $equipId
    groupId: $groupId
    muserid: $muserid
  ) {
    success
    message
  }
}
```

以下為格式示意，**沒有送出**：

```json
{
  "starttime": "2026/10/01 15:00",
  "endtime": "2026/10/01 16:00",
  "equipId": 56,
  "groupId": 5,
  "muserid": 100
}
```

網站前端傳 `muserid: 100`，不能把這個值解讀為目前登入者的 reader ID；其後端語意仍待確認。真實帳號身分與權限必須由校方 session 決定。

成功判斷依 `data.reserveEquipmentCir.success` 與 `message`；之後重新取得個人紀錄與該設備時段，不能只因頁面跳轉或 HTTP 200 就顯示預約完成。網路逾時可能發生在後端已成功之後，不應盲目重送 mutation，應先查紀錄核對。

### 週期／批次預約

公開程式使用 `reserveEquipmentCirList`，variables 為：

- `rsvdate`（該前端分支傳空字串）。
- `rsvstarttime`、`rsvendtime`（`HH:mm`）。
- `rsvdatelist`（以逗號分隔的 `YYYY/MM/DD` 清單）。
- `equipId`、`groupId`、`muserid`。

回應包含 `success`、`data`、`message`。`data` 還有 JSON 字串與每筆成功／失敗訊息的解析，不能把批次操作簡化為全部成功。此流程尚未實際送出驗證。

### 取消

公開程式有不同取消入口，不可混用 ID：

| 入口 | mutation | variables |
| --- | --- | --- |
| 個人預約紀錄 | `cancelEquipmentCir` | 單筆 `eccId`；或以 `eccIds` 傳清單，單筆前端傳 `eccIds: ""` |
| 時段頁自己的預約區塊 | `cancelEquipmentCirByReader` | `ecId`、`startdate`、`enddate`、`starttime`、`endtime` |

個人紀錄同時回傳 `equipmentCir.id` 與 `equipmentCirContent.id`；實作取消前要核對對應。續借與歸還也是另外的 mutation，未包含在本次操作範圍。

公開前端的個人紀錄取消事件使用 `equipmentCirContent.id`，App 沿用此識別值。另以實作中的查詢再次確認：已登入但沒有預約時，`getEquipmentByReader` 回傳 `success: false` 與 `eqgroupitemlist: []`，須辨識為空結果；缺少清單或失敗卻帶有非空清單仍判為異常。

## App 實作

首頁「小工具」分類以原有格子排列呈現「設備租借」與「郵件包裹查詢」；設備租借開啟設備預約畫面，兩項子功能皆可返回小工具，再返回首頁。原有通行碼與借書條碼由 `LibraryCodeService.swift`／`LibraryCodeView.swift` 繼續處理。

設備功能位於 `Features/Library/LibraryEquipment*.swift`：

- Models：解析校方資料、政策數字字串、日期與占用區間，使用 Gregorian／Asia/Taipei。
- Service：獨立 `.nonPersistent()` WK session，從匹配帳號的既有 Keychain 憑證填入校方表單，由校方處理加密。每次查詢及異動前重新核對非空 `session.readerCode` 與 App 帳號，CSRF／cookie 留在 session。
- ViewModel：管理載入、選擇、確認與異動，日期／設備／帳號切換丟棄過期回應。離開畫面會取消工作並清除個人資料與獨立網站 session。
- View：原生設備／日期選擇、可直接點選的 30 分鐘時段、政策額度、確認預約、個人預約與取消確認。需要登入或 CAPTCHA 時，同一 WKWebView 切換為可見且可操作；替換 browser 時移除容器內的舊 WK。
- 互動流程採「先選日期、點開始時間、拖曳滑塊調整時長」，首次與切換設備／日期後不預選時段。每次改選開始時間採政策最短長度，再拉選時長，整段同步標示；滑塊以 30 分鐘調整，上限依單次政策、剩餘額度、關閉時間及連續空檔計算，不跨占用時段。僅有一個合法時長時直接顯示固定長度，不建立無法拖曳的滑塊。滑塊與摘要、核對按鈕固定在底部。
- 時段分別標示可選、已占用、已開始、連續空檔不足與額度不足。詳細規則以 DisclosureGroup 收起；刷新後已失效的選取會清除，不自動換成另一個時段。
- 預約確認與最終送出前均重新查詢時段及所選設備政策，檢查最短／最長／剩餘額度、連續可用區間及已開始時段。
- 異動不自動重試。結果不確定時先禁止再次送出，重新整理個人預約並明確核對後才解除限制。已成功但更新失敗會保留成功訊息。
- 校方確認預約／取消成功後提供明確提示，包含設備、日期與時段；預約成功可直接查看「我的預約」。確認 sheet 關閉後才呈現成功提示，避免兩個 modal 同時呈現。成功後清單刷新失敗仍提示操作已成功，不將結果不確定誤報為成功。
- 「我的預約」沿用「已報名活動」卡片的 12 pt 圓角、細框與淡陰影：設備名稱及「已預約」標記在上方，日期、時段、時長以次要資訊排列，保留期限與取消操作在底部。放大文字時標記及底部操作可換行，跨日預約的結束時間包含日期。
- 清單可依日期範圍（全部日期／今天／明天／一週）及設備篩選；一週涵蓋台北時間今天起連續七天，跨午夜的預約會顯示在期間重疊的日期。可搜尋設備名稱、日期、時間與星期。條件可組合與清除，空清單與無匹配結果分開顯示；這仍是校方目前預約清單的篩選，並非新增歷史紀錄查詢。
- 本次僅提供單日時段原生預約；全日／多日／週期預約、續借、歸還與歷史紀錄維持校方網站入口。

### 驗證

- 使用 Playwright 執行實作中的登入 JavaScript，登入成功；唯讀群組、設備時段、政策與個人紀錄查詢均取得 HTTP 200 且無 GraphQL errors。session 確認有 `readerCode` 並與授權帳號一致；只記錄欄位及布林結果，未保存 session 或憑證。
- `python3 scripts/check-library-equipment.py`：以實際 Models／ViewModel 與合成 service 驗證時區、政策、時段邊界、空紀錄、取消識別值、過期回應、帳號切換、重新連線、重複送出、結果不確定與清理；另驗證初始不預選、完整區間標示、時長調整、失敗保留原選取、切日期及失效確認清除選取。
- `python3 scripts/check-library-equipment-ui.py --device <已啟動的模擬器 UDID>`：獨立測試 bundle，使用實際 SwiftUI 畫面與 WK JavaScript、合成登入 HTML 及記憶體 fetch；不讀 Keychain、不連校方、不送真實 mutation。檢查首次建立 WK 後連線失敗可重試、舊 WK 脫離容器、登入可見性、CAPTCHA、帳號核對、POST／CSRF、WebView 掛載、選時／時長 state 及確認畫面。可用 `--dark --large-text` 檢查深色及無障礙大字，合成日期使用 2099 年以穩定驗證未來時段。
- App target 使用 `NIU-APP` scheme、Debug、iOS Simulator、`CODE_SIGNING_ALLOWED=NO` 編譯。校方真實建立／取消預約尚未實測，模擬器測試不等同真機或真實異動驗證。

## 公開前端依據

本次網站 Next.js build 為 `DhTpg9zSi1TVjY_5TFLp0`。以下是調查時實際載入的資源路徑，build／hash 可能更新：

```text
/_next/static/DhTpg9zSi1TVjY_5TFLp0/pages/_app.js
/_next/static/DhTpg9zSi1TVjY_5TFLp0/pages/equipment.js
/_next/static/DhTpg9zSi1TVjY_5TFLp0/pages/equipment/HourReserve.js
/_next/static/DhTpg9zSi1TVjY_5TFLp0/pages/personal/myEquipment.js
/_next/static/chunks/897589f116ea7ba8cb644fd334212e14d6f8b5b0.8f8bcae4888c35724df2.js
/_next/static/chunks/aad7faf96597fd8e651f27f6d2da6f97c15f11cb.9b34e4a6e5146aab9acd.js
/_next/static/chunks/6e32fc9f103bc45ac41d185ec1ff5a79279d2fbd.406dae615a02b64c3510.js
```
