# NIU-Life

把課表、M 園區與校園常用服務，放進同一個 App。

NIU-Life 是為國立宜蘭大學學生打造的非官方 iOS 校務輔助工具，以 SwiftUI 開發，整合課程查詢、學年度行事曆、快速點名與圖書館通行碼，並提供主畫面小工具、鎖定畫面快捷與課表即時動態。

> 本專案為個人開發，與國立宜蘭大學並無隸屬、合作或授權關係。校務資訊、點名結果與服務狀態，請以學校官方系統為準。

## 功能

| 功能         | 說明                                                                   |
| ------------ | ---------------------------------------------------------------------- |
| 我的課表     | 查看每週課程與今日安排，將課程匯出為 iOS 行事曆中的每週重複事件。      |
| M 園區       | 查閱課程、公告、作業、教材與課程成績。                                 |
| 快速點名     | 使用相機掃描課堂 QR Code，進入 M 園區點名流程。                        |
| 圖書館通行碼 | 顯示門禁 QR Code 與借書條碼。                                          |
| 學年度行事曆 | 切換月曆／事件模式，依學年度搜尋及分類篩選，查看校方原文與來源 PDF。   |
| 活動報名     | 瀏覽與報名校園活動、管理已報名活動，分享活動資訊及報名連結。             |
| 成績查詢     | 查看歷年成績與 GPA。                                                   |
| 畢業門檻     | 查詢多元時數、英文與體適能等門檻。                                     |
| 請假         | 先列出自己的假單與審核結果，校方開放時可撤回、修改或補交證明；新請假原生填寫假別、日期、節次與附件。 |
| 小工具與快捷 | 在主畫面查看課表、行事曆，從鎖定畫面或控制中心快速開啟點名與圖書館。   |
| 版本更新提醒 | 每天首次開啟時檢查台灣 App Store 版本，有新版可選擇「前往更新」或「我知道了」。 |
| 課表即時動態 | 在鎖定畫面與支援裝置的動態島顯示課程資訊；背景遠端更新需另行同意啟用。 |

活動詳情中的「分享」提供「分享活動資訊」與「只分享連結」兩種方式，可報名與已報名活動皆適用。完整分享內容依序包含活動名稱、活動編號、主辦單位、活動時間、活動地點、報名時間與活動連結；連結依活動編號產生，例如 `https://ccsys.niu.edu.tw/MvcTeam/Act/Apply/16157`。

### 版本更新彈窗

每天第一次啟動 App 或回到前景時，會檢查台灣 App Store 已上架的正式版本，未登入也會檢查。只有商店版本比目前安裝版本更新時，才顯示以下彈窗：

> **有新版本可下載**
>
> NIU-Life {最新版本號} 已推出，前往 App Store 下載最新版本。

| 按鈕 | 行為 |
| ---- | ---- |
| 前往更新 | 開啟 NIU-Life 的 App Store 頁面，讓使用者下載更新。 |
| 我知道了 | 關閉彈窗並繼續使用 App，當天不再提醒。 |

檢查以裝置當地日期為準，取得 App Store 回應後當天不再檢查，每天最多提醒一次，重開 App 也不會重複提醒。若尚未更新，隔天首次開啟時會再次檢查。離線或查詢失敗時不打斷使用，也不算當天已檢查：當天之後回到前景會再試，每天最多嘗試 3 次，仍失敗就等隔天；已是最新版或安裝版本較新時不顯示彈窗，也不提示 TestFlight 建置更新。

## 使用須知

- 校務功能需使用有效的學校帳號登入；校務系統、SSO 與 M 園區可能分別要求重新驗證。
- 第一次使用課表小工具前，請先在 App 開啟「我的課表」同步資料。設定方式見[小工具與校園快捷指南](docs/widget-shortcuts.md)。
- 行事曆提供內建資料與已下載快取；校務查詢、重新登入與實際點名仍需連線。離線快取不代表校方最新資料。
- 快捷入口只負責開啟掃描器或圖碼頁，不會代替使用者自動送出點名；是否完成點名以校方回應為準。
- Widget 與即時動態的更新受 iOS 排程、網路與服務狀態影響，不保證 App 關閉後準時刷新。

## 隱私與權限

- **登入資料**：登入憑證使用裝置 Keychain 儲存；學校帳密與校務登入憑證不傳送至開發者伺服器。課表、成績等查詢資料會在裝置上暫存。
- **背景即時動態**：服務已設定且使用者同意啟用後，會將活動所需的課程名稱、教師、教室、時間及推播識別碼傳送至開發者服務，不包含學號、密碼或校務登入憑證。
- **匿名使用統計**：登入成功或已登入的 App 回到前景時，會以隨機安裝 UUID 回報當日活躍，不包含帳號、姓名、課表或廣告識別碼。
- **裝置權限**：相機用於掃描點名 QR Code、行事曆寫入權限用於匯出課表、通知權限用於提醒。
- **登出**：清除本機登入資料、個人快取與相關排程；已自行匯出或分享的副本需在目的 App 中刪除。

完整資料用途、保留方式與聯絡資訊，請閱讀[隱私權政策](docs/privacy-policy.md)。

## 本機開發

### 環境需求

- macOS 與支援專案 SDK 的 Xcode；目前 App 最低部署版本為 **iOS 18.6**，Widget Extension（含即時動態）為 **iOS 18.0**；iOS 26 起使用 Liquid Glass，較舊系統改用相同形狀的材質效果。
- Swift 語言模式為 **Swift 5**，介面以 SwiftUI 為主，校方網頁互動使用 WebKit。
- Python 3、Node.js：用於執行對應的離線檢查腳本；不是啟動 App 的必要條件。部分檢查會呼叫本機 Swift 工具鏈。

### 開啟與執行

```sh
git clone https://github.com/qian403/NIU-app.git
cd NIU-app
open NIU-App.xcodeproj
```

1. 在 Xcode 選擇 `NIU-APP` scheme。
2. 選擇符合最低部署版本的 iPhone／iPad 模擬器，執行 App。
3. 若要測試校務資料，使用自己的有效學校帳號登入；不要將帳密寫入原始碼或測試資料。

真機執行需具備適用的簽章與權限。自行 fork 時，請在自己的開發環境設定 App、Extension 與 App Group；不要修改或撤銷原專案團隊的憑證與描述檔，也不要將個人簽章設定混入貢獻提交。

僅檢查模擬器編譯、不執行 App：

```sh
xcodebuild \
  -project NIU-App.xcodeproj \
  -scheme NIU-APP \
  -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath .deriveddata \
  CODE_SIGNING_ALLOWED=NO \
  build
```

### 遠端服務設定

目前 Xcode Build Settings 透過 `NIU_ACTIVITY_API_BASE_URL` 與 `NIU_USAGE_API_BASE_URL`，分別設定背景即時動態與匿名使用統計的服務位址，並由 `App/Info.plist` 注入 App。

這些服務的後端不在本版本庫內。自行部署或測試相關功能時，請使用自己的服務設定，不要將正式服務當作自動化測試環境；也不要把伺服器密鑰或 Apple 推播金鑰放進 App。

Firebase 透過 Swift Package Manager 固定使用 `12.19.2`，主 App 連結 `FirebaseCore` 與不含 IDFA 的 `FirebaseAnalyticsCore`，並由 SwiftUI 的 AppDelegate 在一般啟動時初始化及啟用 Analytics。設定檔位於 `App/GoogleService-Info.plist`，僅打包到主 App；自行部署時請從自己的 Firebase 專案下載對應 Bundle ID 的設定檔。Analytics 計算首次啟動、工作階段與使用時長；廣告儲存、廣告使用者資料、個人化廣告、IDFV 與自動畫面紀錄均停用，不設定 User ID 或上傳校務及郵件內容。其餘 Firebase 預設資料收集與 AppDelegate 代理仍關閉。Debug 的合成資料 UI 測試會停用 Analytics，且不初始化 Firebase。

`NIU-APP` scheme 的 Debug Run 已加入 `-FIRDebugEnabled`，執行一般 App 後，可於 Firebase Console 的 Analytics → DebugView 查看 `first_open`、`session_start` 與 `user_engagement` 等事件。若需關閉 Debug 模式，先停用該引數，改用 `-FIRDebugDisabled` 執行一次，再移除停用引數；Release Archive 不使用 Run 引數。Debug 模式會縮短事件上傳延遲，但測試流量不會自動從所有報表或 BigQuery 匯出排除，需於 Google Analytics 資源設定開發者流量資料篩選器。離線檢查執行 `python3 scripts/check-firebase-analytics.py`。

## 專案結構

```text
App/                    App 入口、根畫面與應用程式設定
Core/                   共用狀態、登入與網路服務
Features/               各功能的 View、ViewModel、Model 與服務
Shared/                 共用 UI 元件、Theme、導覽與擴充
NIU-LiveActivities/     Widget Extension、即時動態與 App 共用資料邏輯
Resources/              圖像資源、內建行事曆、隱私宣告與系統設定
calendar-data/          公開行事曆資料、來源與維護工具
app-content/            公開的特別感謝名單與維護說明
docs/                   隱私、支援與功能設計文件
scripts/                離線回歸與發行前檢查
NIU-App.xcodeproj/      Xcode 專案與共用 schemes
```

View 負責呈現與互動，ViewModel 管理畫面狀態，Service／Repository／Store 處理資料來源與持久化。App 與 Widget 共用的資料模型、日期規則與導覽邏輯集中維護。

## 檢查與驗證

從版本庫根目錄執行，依修改範圍選擇檢查：

| 範圍                     | 指令                                                                      |
| ------------------------ | ------------------------------------------------------------------------- |
| 行事曆 App／Widget 邏輯  | `python3 scripts/check-calendar-client.py`                                |
| Widget 與快捷            | `python3 scripts/check-widgets.py`                                        |
| SSO 登入與儲存           | `node scripts/check-sso-login.js`、`python3 scripts/check-sso-storage.py` |
| SSO 背景更新與取消       | `python3 scripts/check-sso-refresh.py`                                    |
| SSO 背景／手動登入畫面（隔離模擬器） | `python3 scripts/check-sso-refresh-webview.py --device <UDID>`              |
| 請假表單與送出保護       | `node scripts/check-leave-application.js` |
| 活動分享文字與連結       | `python3 scripts/check-event-sharing.py` |
| 歷年成績                 | `node scripts/check-grade-history.js`                                     |
| 成績載入與取消           | `python3 scripts/check-grade-state.py`                                    |
| 首頁／成績導覽（隔離模擬器） | `python3 scripts/check-home-navigation.py --device <UDID>`                |
| 點名回應解析             | `python3 scripts/check-attendance-response.py`                            |
| 點名驗證碼與登入         | `python3 scripts/check-attendance-captcha.py`、`node scripts/check-attendance-login.js` |
| 點名 OCR 正確率與耗時（離線） | `python3 scripts/check-attendance-captcha.py --benchmark`；自備已標註圖片可用 `--manifest <JSON>`，舊版比較用 `--processor <Swift>` |
| 特別感謝名單與快取       | `python3 scripts/check-credits.py`                                        |
| 非同步工作與生命週期     | `python3 scripts/check-lifetimes.py`                                      |
| 背景即時動態用戶端       | `python3 scripts/check-live-activity-client.py`                           |
| 匿名使用統計             | `python3 scripts/check-usage-heartbeat.py`                                |
| 每日版本更新提醒         | `python3 scripts/check-app-update.py`                                     |
| App Store 發行前靜態檢查 | `python3 scripts/check-app-store.py`                                      |

這些檢查不等同校方服務端到端測試，也不能取代模擬器、真機與 Release archive 驗證。請勿以真實 Keychain 憑證或實際點名操作作為自動化回歸資料。

OCR benchmark 分別統計正確、誤讀、拒絕辨識、首次耗時及後續 P50／P95，不會提交登入或點名。預設使用 120 張固定合成圖片；自備 manifest 格式為 `[{"path":"sample.png","expected":"12345"}]`，圖片路徑相對於 manifest。真實驗證圖與標註留在版本庫外；離線圖片正確率不代表實際登入成功率。比較耗時時依序執行，避免同時編譯或跑其他 OCR 影響結果。

### 公開行事曆資料

```sh
python3 calendar-data/scripts/validate.py
python3 -m unittest discover -s calendar-data/tests -v
python3 calendar-data/scripts/build_review.py --check
```

資料使用 Gregorian 與 `Asia/Taipei`，學年度於 8 月 1 日切換。修訂時需保留穩定事件 ID、校方原文與來源，並更新年度 `revision`、索引及 SHA-256。完整流程見[資料契約與維護說明](calendar-data/README.md)及 [App／Widget 接入規則](docs/calendar-client.md)。單純發布行事曆資料不需增加 App 版本或重新上傳 App。

## 問題回報與參與

歡迎透過 GitHub Issues 回報問題、提出建議，或以 Pull Request 改善功能與文件。提交前請先確認現有差異，保持修改範圍集中，執行相關檢查及 `git diff --check`。

第一次參與可先閱讀[貢獻指南](CONTRIBUTING.md)，了解開發流程、程式慣例、驗證方式與 PR 應附上的資訊。文件修正、介面與無障礙改善、錯誤修復及校曆資料校對都歡迎參與。

回報問題時請提供 App 版本、裝置與系統版本、重現步驟，以及預期和實際結果。截圖與日誌請先遮蔽姓名、學號、成績等個資；**不要附上密碼、token、cookie 或仍可使用的 QR Code**。

私人問題可透過 App「設定 → 回報問題」聯絡，詳見[支援說明](docs/support.md)。學校帳號、密碼重設或校務資料本身的問題，請洽學校管理單位。

## 授權與致謝

本專案原始碼採用 [MIT License](LICENSE)。校方資料與第三方內容的權利仍屬原權利人。

感謝參與測試、回報問題與提供建議的使用者。App 內的特別感謝名單及其更新方式，見 [app-content](app-content/README.md)。
