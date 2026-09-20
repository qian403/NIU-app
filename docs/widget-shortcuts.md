# 課表小工具與校園快捷

## 加入 iPhone 主畫面

長按主畫面空白處 → 編輯 → 加入小工具 → 搜尋 NIU。

- **NIU 小工具**：小型／中型，可顯示當日課表或行事曆。長按小工具 → 編輯小工具，可將「點按開啟」設為課表／行事曆、快速點名或圖書館 QR Code。中型當日課表另有兩個獨立快捷按鈕。
- **NIU 完整課表**：大型，保留完整課表、當日課表及行事曆選項，也可設定點按目的地。
- **NIU 校園快捷**：小型可選快速點名或圖書館；中型同時顯示兩個入口。

課表取自 App 已同步的資料，先在 App 開啟「我的課表」取得最新內容。當日與完整課表預先建立七日的上下課與午夜時間線，並在 App 同步課表後要求系統更新；實際顯示時機仍由 WidgetKit 排程。

## 加入鎖定畫面

- **時鐘下方小工具**：長按鎖定畫面 → 自訂 → 鎖定畫面 → 加入小工具 → NIU 校園快捷。支援圓形、長方形，以及日期列的行內樣式；可設定點名或圖書館。
- **底部快捷控制**：在鎖定畫面自訂模式，移除原本的底部按鈕，按加號並搜尋「快速點名」或「圖書館 QR Code」。這兩個控制也能加入控制中心。

鎖定時須先完成裝置驗證，才會開啟 App。尚未登入時先顯示登入頁，登入後保留並開啟原本目的地。捷徑僅開啟掃描器／圖碼頁，不代替使用者送出點名，也不在小工具中保存圖書館 QR Code。

## 開發驗證

- `python3 scripts/check-widgets.py`：離線驗證允許的連結、重複請求、foreground intents，以及課程時間與週末判讀。
- App 和 extension 都必須編譯 `CampusNavigation.swift`，使鎖定畫面的 OpenIntent 在 App 前景執行。
- `niuapp://class-schedule`、`niuapp://academic-calendar`、`niuapp://attendance`、`niuapp://library` 是允許的導頁入口。
- 裝置端仍需確認鎖定畫面底部控制在驗證後正確開啟 App，以及相機和現場掃碼行為。


## 即時動態與遠端更新

App／Widget 共用 `NIU-LiveActivities/ClassScheduleModels.swift` 的 Gregorian、Asia/Taipei 日期及模型。舊本機快取讀取時修復 App Group 副本。週末依實際星期顯示課程，不跳過週末課程。

即時動態使用系統倒數；前景在課程邊界更新，背景 refresh 只作補充。staleDate 就是下一個狀態切換點，資料過期顯示「待更新」，不假裝旧課程仍在進行。本機更新不等待 Moodle 網路同步。

「背景即時動態更新」另行詢問同意，預設關閉；未設定 `NIU_ACTIVITY_API_BASE_URL` 時不能啟用。Release 僅接受 HTTPS，App 不接受 redirect，不儲存伺服器 cookie。推播環境 Debug=development、Release=production；仍需 Apple developer portal 正確能力／描述檔，這次不操作 portal。APNs 使用 App Bundle ID `dev.chienniuapp`，不是 extension ID。

後端契約與本地測試步驟位於 NIU_APP_API 的 `docs/live-activities.md`。課表與 Widget 不需要此 API；特別感謝與公共行事曆的 GitHub JSON 不受影響。真機 APNs、鎖屏、低耗電、實際停機行為必須獨立驗證，模擬器與離線測試不能代替。
