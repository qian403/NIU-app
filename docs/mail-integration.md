# 校園信箱整合

## 原生收發信

首頁「校園信箱」使用 SwiftUI 呈現，不載入 Webmail。使用者登入 App 後，開啟信箱或寄信時從 `LoginRepository` 讀取目前帳號的 Keychain 帳密，直接登入校方郵件伺服器。App 登入成功不代表郵件驗證必然成功；郵件服務拒絕帳密或要求額外設定時，畫面會另外提示。

校方[Outlook 設定文件，第 4 頁](https://lic.niu.edu.tw/var/file/10/1010/img/673/180945043.pdf)列出的設定：

- IMAP：`mail.niu.edu.tw:993`，implicit TLS。
- SMTP：`mail.niu.edu.tw:465`，implicit TLS。
- 保留完整憑證及主機名稱驗證，最低 TLS 1.2；不降級至明文。

目前功能：

- Apple Mail 風格的信箱首頁、帳號分區與角色圖示；沿用 HomeView 的 NavigationStack，推入信件列表及讀信頁。STATUS 未讀數最多查詢 12 個信件匣，更多信件匣時只查目前信件匣，不把未知數量顯示為零。
- 列表顯示未讀、寄件者名稱、相對日期、主旨、附件與旗標；搜尋可選寄件者／主旨／全部，範圍限已載入的中繼資料與摘要。到底自動每次增加 50 封，單次工作階段最多 1,000 封；保留手動載入與下拉更新。
- 本文摘要對每個載入區塊（最多 50 封）的所有郵件，各取純文字部分最多 1 KiB BODY.PEEK，最多保留 240 字；不存在純文字、伺服器拒絕部分讀取或截斷後無法解碼時省略，不下載整封信作為摘要。沿用累積載入範圍：載入更多或重新整理會重新讀取已載入範圍的摘要，總數上限仍為 1,000 封。
- 信件匣的 `role` 決定標題、圖示與刪除目標，由 IMAP SPECIAL-USE 屬性判定；只有協定保留名稱 INBOX 可作為收件匣備援，不以「垃圾桶」或 Sent 等顯示名稱猜測角色。未提供 Trash／Sent 屬性時，分別走刪除確認／已寄出但備份未儲存提示。
- 依 UIDVALIDITY + UID 讀信。**使用者開啟郵件、本文成功載入後，會以獨立的 UID STORE 將郵件標為已讀**；列表摘要、回覆預填與附件下載本身不改已讀狀態。失敗不標已讀，已讀／未讀操作可手動切換。
- 旗標、已讀／未讀、移到垃圾桶支援滑動與長按選單；樂觀更新失敗會回復並提示。每封信的操作互斥，讀信途中已有旗標操作時，會排程補上已讀更新。
- 刪信優先使用 MOVE；無 MOVE 時只在 UIDPLUS 可用時採 COPY + \Deleted + UID EXPUNGE，絕不使用清空整個信件匣的 EXPUNGE。沒有可移入垃圾桶（包括已在垃圾桶）時先確認，再僅標記 \Deleted。可能部分完成的移動會要求重新整理核對，不自動重試。
- 讀信顯示寄件者頭像、地址、收件人／副本、日期與可選取本文；有 `text/html` 時保留原文，背景以 SwiftSoup 清理後由唯讀 WKWebView 呈現；同時保留純文字供回覆引用、預覽、搜尋及無障礙備援。純文字信件維持 Text 與既有連結偵測；HTML 清理或渲染失敗時才標示「已轉為文字顯示」。
- 本文下方以等比例、滿寬圓角縮圖列出這封信自身的 `image/*` inline／Content-ID parts，排除巢狀 `message/rfc822` 的內部圖片；HTML 引用的 CID 圖片會還原原位置，不在下方重複顯示；未引用的圖片仍列在本文下方。開信先取 BODYSTRUCTURE 清單與大小，縮圖逐張按需下載，與附件共用最多兩個工作的佇列。
- 自動縮圖單張上限 10 MiB、整封預算 15 MiB（以 BODYSTRUCTURE 傳輸編碼大小保守計算，實際回應與解碼資料另做上限檢查）；超限顯示「圖片過大，點擊下載」，大小不明也須手動下載，沿用附件下載的 15 MiB 單檔限制。ImageIO 在背景降採樣至最長邊 1600 px；無法產生縮圖的格式仍可透過檔案卡預覽。HTML 已引用但大小未知、超過自動預算或下載失敗的 CID，另提供下載／重試控制項，不重複列圖；手動下載完成後重載 HTML，沿用既有 15 MiB 手動下載限制。
- 點擊縮圖開 QuickLook 預覽，並提供系統分享／儲存。inline 且有檔名的部分（含圖片）也出現在附件卡片，列表附件圖示採相同判斷；兩處以 MIME section 共用下載工作及 `MailLocalFiles` 暫存。關信、切信及登出取消圖片工作並釋放縮圖，以 detailToken／epoch 丟棄過期回應；登出清除暫存，進入背景取消後回前景可從已下載檔案重建縮圖。
- 附件卡片顯示檔案類型、名稱、大小及下載中狀態；下載後可 QuickLook 預覽與系統分享／另存。附件按需下載，以檔案挑選器加入寄信附件。
- 寫信採全高度文字編輯器、收件人驗證標籤、副本／密件副本與唯讀寄件人；回覆／全部回覆／轉寄保留適當引用與 References。全部回覆去除自己的地址與重複地址，回覆自己寄出的郵件使用原收件人。Re:／Fwd: 不重複附加；轉寄可選擇下載並加入原附件。
- 寄出後立即關閉寫信頁；由信箱根畫面持有的共用 outbox 狀態在各推入頁疊加底部通知：傳送中、已寄出、已寄出但備份失敗、無法寄出及寄送結果不明。成功有觸覺及 VoiceOver 通知，約 3 秒收起；失敗提示以一行顯示受控錯誤原因，VoiceOver 朗讀完整原因，並可重開完整草稿。未提供收回寄送。
- 草稿暫存在目前 App 工作階段，取消時可選儲存或刪除；不做伺服器草稿同步。登出／換帳號清除草稿、通知、本文、清單與下載暫存。
- 附件合計上限 15 MB、本文上限 2 MB；轉寄附件也遵守相同上限，採不完整則不加入的方式。

SMTP 以伺服器最終接受回覆作為「校方已接受寄送」；這不代表每位收件人已實際收到。拒絕任一收件人時中止該次寄送。無法確認送達結果時鎖住這份草稿的寄出按鈕，不自動重送。寄送成功後以相同 Message-ID 寫入校方寄件備份；備份失敗另行提示，不能因此重寄。

未包含：任意信件匣搬移、伺服器全文搜尋、未載入郵件的本文摘要、富文字編輯、執行郵件內腳本或表單、載入外部樣式表、背景即時收信通知、伺服器草稿同步、多份本機草稿、收回寄送與 Webmail 進階設定。校方若不支援 MOVE 及 UIDPLUS，App 不執行不安全的移動備援；下載指示為不定進度，SwiftMail 此路徑未提供逐位元組進度回呼。

## HTML 顯示與隱私

- plain／HTML MIME alternatives 各以 2 MiB 上限取得；一種 alternative 失敗時保留另一種可用本文，取消仍傳遞。原始 HTML 僅留在記憶體，WebView 只接收清理版本。
- 背景 SwiftSoup 移除腳本、框架、外嵌物件、表單與控制項、所有來源 meta／base／link（包括外部 stylesheet、prefetch）、事件 `on*` 屬性，以及 `javascript:`／`vbscript:`／`data:text/html` 連結與來源。另移除音訊／影片／SVG／MathML、srcdoc、srcset 與 ping；保留 style／inline style。這是受限 HTML 郵件呈現，不保證所有瀏覽器排版功能。
- WKWebView 關閉信件來源 JavaScript、inline media、自動播放及連結預覽，僅以 weak handler 接收 App 隔離腳本的圖片完成／失敗通知，不讀取信件傳入的 payload；使用 `.nonPersistent()` 儲存區，不共用 SSO／Webmail session。先編譯並安裝 content rules 才載入 HTML；規則失敗則回退純文字。
- 預設 content rules 以 `.*` 封鎖資源，再只對 CID／自訂 scheme／data 圖片與 data 字型做例外。CSP 為 `default-src 'none'; img-src cid: niu-mail-cid: data:; style-src 'unsafe-inline'; font-src data:; base-uri 'none'; form-action 'none'`；另加入 no-referrer。
- 偵測 img src、background 或 CSS url 中的 HTTP(S) 圖片後，顯示「這封信含外部圖片。載入外部圖片」。點選後僅這次開啟的當封信開放 **HTTPS 圖片**：CSP 只在 img-src 加入 https:，content rules 只放行 https:// 的 image 類型；HTTP 圖片即使同意後仍封鎖，腳本、外部 CSS、框架與其他資源維持封鎖。關信、切信或登出重設同意狀態。載圖會直接連到寄件者指定的主機，可能讓對方得知已開信；圖片提示在同意前後均顯示「僅允許載入 HTTPS 圖片。部分未加密（http）的圖片不會載入。」
- CID 改寫為 `niu-mail-cid://part/<MIME section>`，scheme handler 僅讀當封信 catalog 中的圖片，共用 ViewModel 既有下載佇列、檔案、10／15 MiB 自動預算與手動下載限制。等待及磁碟讀取後再次檢查 epoch／detailToken／message key，過期資料不送入 WebView。
- 導覽僅允許首次 loadHTMLString 的 about:blank。使用者點擊 HTTP(S) 連結交給系統 openURL；mailto 預填 App 內草稿的收件人／主旨，已有草稿時保留現有草稿。其他 scheme、自動導覽與子框架導覽一律取消。
- WebView 放在標頭與附件之間，由外層 ScrollView 垂直捲動。App 在 `.defaultClient` 隔離世界唯讀量測 scrollWidth／scrollHeight、clientWidth 與所有元素 rect 的最大 right／bottom，避免祖先 overflow 隱藏自然尺寸。原生 UIView 容器讓 WebView 以量到的自然寬度排版，`pageZoom` 固定 1，viewport 僅指定 `initial-scale=1`；UIKit transform 將整頁等比例縮至容器寬度，避開 pageZoom 與 device-width 的重新排版。窄信件不放大，移除 0.5 下限與水平捲動 fallback；百分比寬度加 padding 等持續擴寬的排版最多連續重排四次，未收斂則退回既有純文字呈現。寬度改變後重新量測高度，SwiftUI 高度與 WebView 排版高度分開，避免 scrollHeight 的 viewport 下限持續增高。contentSize KVO 及 `.defaultClient` 的 img load／error 通知會重新量測；圖片事件先清除舊排版高度下限。切換信件以文件世代排除舊回應，離頁移除 handler。DEBUG Logger：subsystem `dev.chienniuapp`、category `MailHTML`，每行八個純數字依序為容器 bounds.width、WebView bounds.width、scrollWidth、scrollHeight、clientWidth、最大 rect.right、pageZoom、計算的原生縮放比例；不記錄內容或網址。
- `allowsContentJavaScript = false` 仍允許 App 注入程式執行，依 [WebKit 官方 API 標頭](https://github.com/WebKit/WebKit/blob/main/Source/WebKit/UIProcess/API/Cocoa/WKWebpagePreferences.h)；[Apple 文件](https://developer.apple.com/documentation/webkit/wkwebpagepreferences/allowscontentjavascript) 說明此設定封鎖網頁來源腳本。量測字串固定、不插入信件內容、不修改 DOM，信件本身腳本仍由清理器、CSP 及 WebKit 設定封鎖。
- HTML 保留寄件者的固定字級與排版，`-webkit-text-size-adjust:100%`，不額外套用 App 的 Dynamic Type 放大，避免固定高度標題被放大文字擠出；移除全域 overflow-wrap，保留 `img{max-width:100%;height:auto}`。純文字本文及原生郵件控制項維持 Dynamic Type；保留 WebKit 原生 VoiceOver 與系統輔助使用行為，未另外實作 HTML 無障礙放大。
- 沒有自訂背景／文字色時跟隨系統 Canvas／CanvasText 與 light dark；偵測到 bgcolor、背景或文字色樣式時使用淺色底板，保留原信配色，避免系統深色底板讓黑字不可讀。
- 載入期間顯示 ProgressView；WebContent process terminated 或主文件載入失敗時顯示提示與可選取純文字。WebView 保留原生 VoiceOver 內容樹，不以單一 accessibilityLabel 覆蓋。離頁、進背景、換信／登出時拆除容器、stopLoading、移除 KVO、取消 scheme 工作；Coordinator／handler 對 ViewModel 為 weak 參照。

## 分工與生命週期

- `Features/Mail/Native/NativeMailModels.swift`：郵件模型、驗證與服務介面。
- `NativeMailService.swift`：SwiftMail 的 IMAP／SMTP 轉接、TLS、郵件解析、寄送狀態與寄件備份。
- `NativeMailViewModel.swift`：Keychain 帳號綁定、App session／請求世代檢查、取消、暫存與草稿。
- `NativeMailView.swift`：根畫面生命週期、推入導覽與共用寫信 sheet。
- `MailboxListView.swift`、`MessageListView.swift`（含 MessageRow）、`MessageDetailView.swift`、`ComposeView.swift`：信箱、列表、讀信與寫信呈現。
- `MailHTMLPolicy.swift`：背景 SwiftSoup 清理、CSP／content rules、CID 改寫與純函式導覽決策。
- `MailHTMLView.swift`：隔離的唯讀 WKWebView、DOM 尺寸量測與 CID scheme handler。
- `MailComponents.swift`：共用選單、底部工具列、通知、格式化與錯誤元件。

每個操作使用獨立且短暫的連線，不跨帳號重用。讀取工作離頁或進入背景時取消；SMTP 不因一般畫面切換而自動重送，寄送期間提示保持 App 開啟。登出／換帳號取消所有相關工作並阻擋過期回應。附件存入 App 專屬暫存目錄並使用檔案保護；下次程序啟動會清理前次終止留下的檔案。自行分享另存的檔案由使用者管理。

郵件不經開發者後端。SwiftMail 的 swift-log backend 設為 no-op，避免其協定／MIME／伺服器回應日誌洩漏個資；目前 App 沒有其他 swift-log 使用者。錯誤畫面只顯示受控文字，不直接呈現原始 server error。

## 相依套件

- SwiftMail 固定在 `b45ab8cbb08d989ec7dcad139b8bfbc0f1f080cc`，包含 SMTP all-or-nothing 收件人、取消及 acceptance 分類修正。1.9.2 的 sendEmail 未檢查部分 SMTP 命令的 Bool 結果，不可直接退回該版本。
- SwiftSoup 2.9.6；Swift Logging 1.6.4。完整傳遞相依鎖於 Xcode 的 `Package.resolved`。
- 固定版 SwiftMail 會把 Content-ID 合成為 `filename`，未公開原始檔名來源。App 對等同 CID 備援值的名稱保守視為無原始檔名，下載時依 MIME 產生副檔名；若寄件者刻意把真正檔名設得與 CID 完全相同，該 inline 圖片只列在圖片區，仍可下載／分享。精確區分需套件另提供原始 MIME 檔名資訊。
- 不自行跟隨上游 main；日後換版需重跑收發信回歸。

舊的 Webmail service／browser／view 留作既有離線回歸與遷移參考，首頁不再導向它們。AppState 同時撤銷舊及新郵件工作階段。

## 驗證

### DEBUG UI 截圖入口

安裝 Debug App 後，bundle ID 為 `dev.chienniuapp`。fixture 根畫面直接使用 `NavigationStack { NativeMailView(...) }`，不建立正式 RootView／AppState，不執行正式登入或背景工作。fixture root 與 service 全部包在 `#if DEBUG`，Release 不包含這些型別或入口。

```sh
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMailUIFixture
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMailUIFixture -NIUMailUIFixtureScreen inline
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMailUIFixture -NIUMailUIFixtureSendFailure
```

「detail-expanded」直接開啟已展開詳細資訊的合成信，含兩位具名收件人、兩位副本及不同於寄件者的回覆地址。可檢查兩欄標頭、完整日期、收合切換，以及長按地址的拷貝／撰寫選單：

```sh
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMailUIFixtureScreen detail-expanded
```

「html」直接開啟表格、固定字級、彩色按鈕、CID 圖片、各一張封鎖中的外部 HTTPS 與 HTTP 圖片與深色 newsletter 配色的合成信：

```sh
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMailUIFixtureScreen html
```

「notification」直接開啟校務登入通知合成模板：700 px table、48 px 藍色標題列／26 px 粗體長標題、灰底資訊區、紅字時間與底部驗收標記，無真實帳號／姓名／IP。

```sh
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMailUIFixtureScreen notification
```

驗收時切換預設及 Accessibility 最大字級、深色模式與橫直向，確認 HTML 標題未被放大裁切、右側可見（極窄畫面可水平捲動），底部驗收標記及後續附件可完整捲到。純文字信件另確認隨 Dynamic Type 放大。

fixture 的「載入外部圖片」操作保持封鎖，所有連結也由 fixture root 攔截，不連網。可在模擬器切換深色模式及 Accessibility Dynamic Type 檢查同一封信。

「inline」直接開啟兩張程式產生的小 PNG 合成信：一張有檔名的 inline 圖片（亦列附件），另一張只有 CID、無檔名；全程不讀取真實帳密或外部圖片。

也可於 Xcode Scheme → Run → Arguments Passed On Launch 加入相同參數。有效的 `-NIUMailUIFixtureScreen` 也會直接啟用 fixture，不必另加 `-NIUMailUIFixture`。

假帳號為 `test@niu.edu.tw`，使用合成 session／憑證、獨立附件暫存目錄及記憶體 service，不讀寫真實 Keychain、不連接郵件或其他網路服務。5 個信件匣共 20 封（收件匣 16 封，其餘各 1 封），包含未讀數、旗標、附件、長主旨、中英文寄件者與摘要。收件匣第一封包含連結和 2 個可在本機下載的合成附件。寄送延遲 1.5 秒後成功；加上失敗參數則回傳受控拒絕原因。重新啟動會還原合成資料。

fixture 暫存附件使用獨立 `NIUMailUIFixture` 子目錄，亦不讀寫真實 UserDefaults；本文的合成連結點擊由 fixture root 攔截，避免離線預覽開啟網路頁面。

### 本次審查修正

- 移除逐封顯示的已讀說明；本文載入成功才標為已讀的行為仍保留，規則見上方文件。
- 已查核固定 revision 的 SwiftMail checkout：`IMAPServer+Fetch.swift` 的 `fetchPart(section:of:offset:count:)` 支援部分讀取；`FetchCommands.swift` 使用 `.bodySection(peek: true, section, range)`，摘要實際請求為 `BODY.PEEK[section]<0.1024>`，並驗證回應 section、offset 與大小上限，不設定 `\Seen`。
- 列表日期格式器共用快取，行事曆及時區與裝置 `Calendar.current` 一致；設定改變時重建快取。
- 收件人標籤為約 30 pt 的膠囊外觀，外加點擊留白；點選開啟「移除」選單，保留無障礙標籤。
- 使用者提供 Claude 的修正前沙盒外結果：iOS Simulator Debug `BUILD SUCCEEDED`；`check-native-mail`／`check-mail`／`check-lifetimes`／`check-sso-storage` 全部 PASS。下方原有兩個失敗與編譯阻擋屬先前沙盒限制，不能作為本次修正後的驗證結果。

本輪修正後檢查：

| 檢查 | 實際結果 |
| --- | --- |
| `python3 scripts/check-native-mail.py` | PASS；包含真假垃圾桶 role、垃圾桶內刪除確認、failure 原因／開啟草稿，以及真正 DEBUG fixture 的 5 信箱／20 封、連結／2 附件、已讀狀態、1.5 秒成功／失敗寄送 |
| `python3 scripts/check-lifetimes.py` | PASS；既有 weak 變數警告仍在 |
| Service 與 DEBUG fixture Swift 型別檢查 | exit 0；service 使用現有 SwiftMail／SwiftSoup 模組，fixture 同時以專案的 MainActor 預設隔離檢查 |
| 不定義 DEBUG 的模型／fixture 動態函式庫 | 編譯 exit 0；`nm` 確認不含 `NativeMailUIFixtureService` 符號，非完整 Release archive |
| `git diff --check` 與未追蹤 Native 檔案空白檢查 | 無錯誤 |
| Debug iOS Simulator `xcodebuild` | 套件解析受阻：`Could not resolve package dependencies`，ModuleCache／ManifestLoading 寫入 `Operation not permitted`；尚未進入 App 編譯 |
| 模擬器畫面／真機 | 本輪未執行；完整編譯及畫面驗證待沙盒外進行 |

### 2026-10-03 內嵌圖片修正驗證

- `check-native-mail.py` 通過：MIME/CID 所屬範圍、有檔名 inline/CID 附件、10/15 MiB 邊界、最多兩張並行、下載共用、ImageIO 解碼、不支援格式、切信過期回應、關信取消、登出清理及前景暫存重用。
- `check-lifetimes.py` 通過，既有 weak 變數警告仍在；`git diff --check` 無輸出，未追蹤 Native 檔案另做空白檢查。
- 服務層使用現有固定套件模組型別檢查通過。Native UI 暫存副本以 SwiftUI.State 型別別名避開 SDK macro 啟動限制後，型別檢查 exit 0；原有 `.shared` 預設參數的 actor 隔離警告仍在。此補充檢查不是完整 App 建置。
- Xcode Debug iOS Simulator build 在套件解析階段失敗：ModuleCache／ManifestLoading 寫入 `Operation not permitted`。未完成完整 App 編譯或模擬器／真機畫面驗證，需在沙盒外執行。

### 2026-10-03 HTML 渲染驗證

- `check-native-mail.py` 使用現有鎖定版本的 SwiftSoup 本機 checkout，在暫存目錄編譯測試模組，不解析、下載或修改相依套件。需要時以 `NIU_SWIFTSOUP_SOURCE` 指定該 checkout。
- 覆蓋實際清理器、CID 改寫、外部圖片判定、CSP／規則內容、導覽決策、配色與 Dynamic Type CSS、CID 手動下載與切信過期回應，以及既有原生郵件回歸。
- 最終 `python3 scripts/check-native-mail.py` 與 `python3 scripts/check-lifetimes.py` 均 exit 0、所有 PASS；前者包含手動 CID 大於 10 MiB 而不超過 15 MiB 的讀取。SwiftSoup 自身的 Comparable／nil-coalescing 與既有 lifetime fixture weak 變數警告仍在，未修改套件。`git diff --check` 無輸出，未追蹤 Native／測試檔另做空白檢查通過。
- 現有套件模組的 service 型別檢查及隔離 Native UI 型別檢查均 exit 0；UI 暫存副本以 SwiftUI.State 型別別名避開 SDK macro 的沙盒限制，不改動正式原始碼。
- 本輪 Xcode Debug Simulator build 在套件解析階段因 `Could not resolve host: github.com` 失敗；未完成完整 App 編譯或模擬器／真機截圖。使用現有套件模組另做 service 與隔離 Native UI 型別檢查；此項不等同完整 App build。實際執行輸出見本次交付報告。

### 2026-10-03 登入通知 HTML 寬度與字級修正

- 改用 App 隔離世界的 DOM 尺寸量測、縮放後重測高度與圖片完成通知；HTML 不再依 Dynamic Type 放大。新增 `notification` 合成模板，保留既有 `html`／`inline` fixture。
- `python3 scripts/check-native-mail.py`：exit 0，包含原生 fittingScale 回歸、100% text-size-adjust、量測腳本在禁止 DOM 寫入的測試物件上執行，以及 700 px／48 px／26 px 模板與底部標記。
- `python3 scripts/check-lifetimes.py`：exit 0；既有 fixture weak 變數警告仍在。SwiftSoup 既有 Comparable／nil-coalescing 警告未修改。
- `git diff --check` 與本次修改的未追蹤檔案空白檢查通過。
- 使用現有套件模組的隔離 Native UI Swift 型別檢查 exit 0；暫存副本以 SwiftUI.State 型別別名避開 SDK macro 沙盒限制，未改正式原始碼。
- 完整 Debug Simulator `xcodebuild` exit 74：套件解析所需 ModuleCache／ManifestLoading 無寫入權限，尚未進入 App 編譯。CoreSimulator 連線失敗，未完成模擬器畫面或真機驗證；上述測試不代表已在裝置確認裁切消失。

### 離線回歸

```sh
python3 scripts/check-native-mail.py
python3 scripts/check-mail.py
python3 scripts/check-lifetimes.py
```

原生離線測試使用合成資料與注入憑證，涵蓋 inline／CID 與巢狀 MIME 分類、有檔名 inline 附件、10／15 MiB 邊界、最多兩張並行、下載共用、ImageIO 縮圖、不支援格式、切信過期圖片回應與登出圖片清理，以及帳號／信件匣／讀信競態、更新保留快取、帳密不一致、寄送單一工作、未知結果禁止重寄、備份失敗不重寄、登出清理與輸入限制。不讀取真實 Keychain，也不寄送真實郵件。

校方真實帳號登入、寄件備份實際名稱、實際收寄信／附件／二次驗證相容性仍需裝置驗收。既有 2026-09-30 Webmail 唯讀測試不能當作原生 IMAP／SMTP 驗收。

### 原生郵件初版的既有驗證紀錄（非本次 UI 重構驗收）

- Xcode 27 的 App／Extension 模擬器 Debug 編譯通過。
- `check-native-mail.py`、既有 `check-mail.py`、`check-lifetimes.py`、`check-sso-storage.py` 通過。
- 固定版本 SwiftMail 的本機 SMTP fixture 測試 4 項通過：最終接受、本文被拒、送出終止符後取消造成結果不明、收件人被拒時中止交易。
- 以隔離的合成資料預覽 App 檢視原生列表、讀信、寫信及深色／放大字級；未在真實帳號中操作。
- 使用 macOS Network.framework 的系統憑證驗證連線至校方 993／465，TLS 握手通過；未送出帳密或真實郵件。


### 2026-10-03 UI 重構原有沙盒驗證紀錄（修正前）

- `check-native-mail.py` 使用合成 fixture，不接觸真實 Keychain 或校方服務；新增寄送通知、失敗重開草稿、未知結果鎖定、已讀／旗標／刪除 rollback、舊帳號回應、回覆／全部回覆／轉寄、BCC，以及加旗標途中讀信的回歸。
- 本次完整 Xcode Debug build 與模擬器實際畫面驗證仍受執行環境限制；不可沿用上方初版的通過紀錄作為本次結果。詳細執行結果於交付報告列出。

| 本次檢查 | 結果 |
| --- | --- |
| `python3 scripts/check-native-mail.py` | 通過，包含寄送通知、失敗草稿、rollback、帳號競態、開信與旗標競態、BCC 與回覆預填 |
| `python3 scripts/check-lifetimes.py` | 通過；既有 fixture 有一項 weak 變數警告 |
| `python3 scripts/check-mail.py` | 失敗：`Foundation._GenericObjCError.nilError`；隔離診斷確認在 Vision OCR 階段拋錯，後續 fixture 未執行 |
| `python3 scripts/check-sso-storage.py` | 失敗：`migration must persist in isolated Keychain`；未修改 SSO 程式或真實 Keychain |
| `xcodebuild -list`／NIU-APP Debug iOS Simulator build | 阻擋：套件 manifest 執行 `sandbox-exec: sandbox_apply: Operation not permitted`；移到可寫暫存目錄仍失敗 |
| 服務層 Swift 型別檢查 | 通過，使用現有固定版本 SwiftMail／SwiftSoup 模組 |
| 隔離 UI Swift 型別檢查 | 通過；合成 service，暫存副本以既有 SwiftUI.State property-wrapper 型別別名避開無法啟動的 SDK macro。非完整 App 建置 |
| 模擬器／真機 UI、真實收發信 | 未完成；CoreSimulator 回報 `Connection refused`，未操作真實帳號 |

沒有在本次宣稱真機收發信、長時間效能、無記憶體洩漏或正式發行驗證完成。
