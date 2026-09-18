# 記憶體與效能檢查（2026-09-18）

## 範圍與修正

檢查相機、Moodle WebView／附件下載、課表／歷年成績／畢業門檻 WebView、活動登入／重新整理、OCR、Widget 與課表即時動態的物件持有關係、取消處理及重複工作；另以兩次獨立程式審查確認修正。

- 點名掃描頁：離頁清除 scanner 的 bound-method callback，避免透過 View／StateObject 保留相機。Debug 版加入不含帳號或 QR 資料的建立／釋放紀錄。
- 活動兩個分頁：取消的 `Task.sleep` 不再被忽略，避免 MainActor 忙碌迴圈；重新整理最多等待 45 秒，處理 navigation failure。離頁停止載入、解除共享登入擁有者及等待者；延遲登入與 JS 回呼用 generation 排除舊操作。
- 課表：追蹤並取消 GUID bridge／SSO task；移除 WebView 時停止 navigation 並清除回呼。取消或逾時後，舊登入結果不能重新開啟 WebView。
- OCR：以 `nonisolated` stateless processor 與 `@concurrent` 明確將影像處理／Vision 工作移出 MainActor。
- Moodle：pluginfile 附件只使用顯示中的 WebView；SSO task、Cookie completion 與延遲重試都有取消／generation 檢查。重試保留原有 WKWebView，避免重新建立未顯示的實例。
- 附件：下載綁定 SwiftUI `.task`，離頁取消；每個 viewer 使用獨立暫存目錄並清理，避免同名附件衝突及持續累積。
- 即時動態：回前景時更新既有 Activity；移除啟動與課表更新時重複的刷新呼叫。

GradeHistory／GraduationThreshold 已有 weak WebView、dismantle、timeout 與 script handler 清理，這次未確認新的永久洩漏。ActivityKit token stream 未取得永久保留的動態證據，未將它列為已證實洩漏。

## 驗證結果

- iOS Simulator 與 generic iOS Debug（App + Widget extension）均 `BUILD SUCCEEDED`；本次最終增量建置未輸出 compiler warning/error。沿用現有簽章，未建立或更改憑證。
- `python3 scripts/check-lifetimes.py`：抽取正式程式的方法離線執行，驗證兩分頁取消後快速返回、VM 釋放、舊 waiter 不取消新刷新、正常完成、取消登入 owner／waiter 及重新進頁。
- `python3 scripts/check-widgets.py`：路由 allowlist、重複／待處理導航、兩個 foreground intents，以及上課前／課中／空堂／放學／週末／無快取案例通過。
- `python3 scripts/check-attendance-response.py`：20 個回應案例與 7 個正式 WebKit DOM extractor fixture 通過。
- `node scripts/check-grade-history.js`、`node scripts/check-sso-login.js` 通過。
- `git diff --check`、Info.plist／Xcode project plist 檢查通過。

### 實際反覆進出與記憶體快照

環境：iPhone 17 Pro simulator，iOS 26.5，Debug build。XCUITest 啟動 App 後重複 12 輪：`niuapp://attendance` → 確认快速點名頁 → `niuapp://library` → 確认圖書館通行碼頁 → 返回主頁。修正前後均完成這個操作流程。

| 量測 | 修正前，12 輪後 | 修正後，12 輪後 |
| --- | ---: | ---: |
| `leaks --noContent` 偵測到的洩漏 | 0 bytes | 0 bytes |
| App physical footprint | 54.3 MB | 53.9 MB |
| App peak physical footprint | 54.9 MB | 54.3 MB |

修正後相機生命週期紀錄共建立 24 次、釋放 24 次，數量一致。小幅 footprint 差異屬單次量測波動，**不宣稱有顯著記憶體下降**。

初次接手已由 simctl 啟動的 App 時，XCTest accessibility 連線逾時；改由 XCUITest 冷啟動後，前後兩次循環測試均成功。

## 測試限制

這次動態量測限於 App 主程序及上述頁面進出，並非所有 WebKit 子程序、所有功能或長時間真機相機串流的保證。模擬器沒有真實相機，本次校務 session 也未完成重新驗證，因此不把它當作實際掃碼、取得新圖書館碼、真機幀率或耗電的測試。未送出點名、活動報名／取消或圖書館通行驗證。`leaks` 的零結果無法排除仍可達的保留物件與所有生命週期問題；相機釋放紀錄和取消測試提供額外佐證。
