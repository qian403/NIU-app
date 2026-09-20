# NIU-Life

把課表、M 園區與校園常用服務，放進同一個 App。

NIU-Life 是為國立宜蘭大學學生打造的非官方 iOS 校務輔助工具，以 SwiftUI 開發，整合課程查詢、學年度行事曆、快速點名與圖書館通行碼，並提供主畫面小工具、鎖定畫面快捷與課表即時動態。

> 本專案為個人開發，與國立宜蘭大學並無隸屬、合作或授權關係。校務資訊、點名結果與服務狀態，請以學校官方系統為準。

## 功能

| 功能 | 說明 |
| --- | --- |
| 我的課表 | 查看每週課程與今日安排，將課程匯出為 iOS 行事曆中的每週重複事件。 |
| M 園區 | 查閱課程、公告、作業、教材與課程成績。 |
| 快速點名 | 使用相機掃描課堂 QR Code，進入 M 園區點名流程。 |
| 圖書館通行碼 | 顯示門禁 QR Code 與借書條碼。 |
| 學年度行事曆 | 切換月曆／事件模式，依學年度搜尋及分類篩選，查看校方原文與來源 PDF。 |
| 活動報名 | 瀏覽校園活動與活動詳情，進入報名流程。 |
| 成績查詢 | 查看歷年成績與 GPA。 |
| 畢業門檻 | 查詢多元時數、英文與體適能等門檻。 |
| 小工具與快捷 | 在主畫面查看課表、行事曆，從鎖定畫面或控制中心快速開啟點名與圖書館。 |
| 課表即時動態 | 在鎖定畫面與支援裝置的動態島顯示課程資訊；背景遠端更新需另行同意啟用。 |

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

- macOS 與支援專案 SDK 的 Xcode；目前 App 與 Widget Extension 的最低部署版本皆為 **iOS 26.2**。
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

| 範圍 | 指令 |
| --- | --- |
| 行事曆 App／Widget 邏輯 | `python3 scripts/check-calendar-client.py` |
| Widget 與快捷 | `python3 scripts/check-widgets.py` |
| SSO 登入與儲存 | `node scripts/check-sso-login.js`、`python3 scripts/check-sso-storage.py` |
| 歷年成績 | `node scripts/check-grade-history.js` |
| 點名回應解析 | `python3 scripts/check-attendance-response.py` |
| 特別感謝名單與快取 | `python3 scripts/check-credits.py` |
| 非同步工作與生命週期 | `python3 scripts/check-lifetimes.py` |
| 背景即時動態用戶端 | `python3 scripts/check-live-activity-client.py` |
| 匿名使用統計 | `python3 scripts/check-usage-heartbeat.py` |
| App Store 發行前靜態檢查 | `python3 scripts/check-app-store.py` |

這些檢查不等同校方服務端到端測試，也不能取代模擬器、真機與 Release archive 驗證。請勿以真實 Keychain 憑證或實際點名操作作為自動化回歸資料。

### 公開行事曆資料

```sh
python3 calendar-data/scripts/validate.py
python3 -m unittest discover -s calendar-data/tests -v
python3 calendar-data/scripts/build_review.py --check
```

資料使用 Gregorian 與 `Asia/Taipei`，學年度於 8 月 1 日切換。修訂時需保留穩定事件 ID、校方原文與來源，並更新年度 `revision`、索引及 SHA-256。完整流程見[資料契約與維護說明](calendar-data/README.md)及 [App／Widget 接入規則](docs/calendar-client.md)。單純發布行事曆資料不需增加 App 版本或重新上傳 App。

## 問題回報與參與

歡迎透過 GitHub Issues 回報問題、提出建議，或以 Pull Request 改善功能與文件。提交前請先確認現有差異，保持修改範圍集中，執行相關檢查及 `git diff --check`。

回報問題時請提供 App 版本、裝置與系統版本、重現步驟，以及預期和實際結果。截圖與日誌請先遮蔽姓名、學號、成績等個資；**不要附上密碼、token、cookie 或仍可使用的 QR Code**。

私人問題可透過 App「設定 → 回報問題」聯絡，詳見[支援說明](docs/support.md)。學校帳號、密碼重設或校務資料本身的問題，請洽學校管理單位。

## 授權與致謝

本專案原始碼採用 [MIT License](LICENSE)。校方資料與第三方內容的權利仍屬原權利人。

感謝參與測試、回報問題與提供建議的使用者。App 內的特別感謝名單及其更新方式，見 [app-content](app-content/README.md)。
