# Moodle 首頁與課程總覽

## 使用方式

- 首頁依學期顯示課程；「即將截止」彙整所選學期各課程尚未繳交的作業，範圍為逾期 7 天內至未來 14 天，首頁最多 5 筆。
- 課程總覽顯示下一份待繳、已結算出席率及可取得的課程總分，並預覽 3 筆待繳作業與 3 則公告。
- 作業、公告、資源、問答、出缺席及成績各有完整子頁；原有搜尋、作業排序、出缺席篩選仍保留。
- 總覽搜尋涵蓋整門課，依六種類別顯示數量與預覽。公告完整頁及搜尋會補載後續頁面；首頁總覽先載入首批。

## 資料與錯誤處理

總覽與子頁共用 ViewModel 和請求；資源與問答延後至開啟或搜尋時載入。每個區塊獨立呈現錯誤與重試，更新失敗保留有效資料。強制刷新、取消及帳號切換以請求／session 版本隔離，繳交後更新共用作業狀態。

跨課程作業優先使用 Moodle 行事曆 action events。介面未開放時退回作業清單及繳交狀態查詢，最多同時 4 筆；查詢失敗不能當成沒有待繳作業。點擊時重新解析作業 ID／課程模組 ID。

Moodle 公告 API 在分頁後才過濾無權限的討論，因此回傳少於 20 則不一定是末頁。分頁計算包含已辨識的 `post` 權限警告；未知警告、重複頁面或超過頁數上限保留為錯誤，不宣告搜尋完整。[上游實作](https://github.com/moodle/moodle/blob/MOODLE_405_STABLE/mod/forum/externallib.php#L395-L410)

## 離線驗證

`scripts/check-moodle-course-overview.py` 覆蓋摘要、六組搜尋、部分失敗、共享請求取消、過期回應、公告完整分頁與權限過濾。其餘 `check-moodle-*.py` 覆蓋首頁、即將截止、排序、問答、網路參數與 token 範圍；`scripts/check-lifetimes.py` 檢查既有生命週期情境。

Debug App 支援純合成資料，不需帳密、Keychain 或網路：

```sh
xcrun simctl launch --terminate-running-process booted dev.chienniuapp -NIUMoodleUIFixtureScreen course
```

`-NIUMoodleUIFixtureScreen` 可替換為 `course-search`、`course-assignments`、`course-resources`、`course-attendance`、`course-partial-error`、`home`、`upcoming`、`home-upcoming-empty` 或 `home-upcoming-error`。`-NIUMoodleUIFixtureCalendarUnavailable` 可驗證行事曆介面不可用時的備案。入口與合成資料皆由 `#if DEBUG` 限制。

2026-10-04 已重新通過 12 個 Moodle 檢查（含實際 WebKit fixture）、生命週期檢查，以及公告權限分頁新增回歸；Debug 模擬器編譯與上述六種課程畫面檢視完成，另檢視深色模式及最大輔助字級的總覽／搜尋／部分錯誤畫面。這些結果不代表已使用真實帳號確認校方 API 或在真機完成作業操作。
