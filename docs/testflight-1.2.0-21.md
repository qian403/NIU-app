# TestFlight 1.2.0 (21)

## 更新內容

- 課表新增「單日／整週」切換並記住顯示偏好；一般字級下，整週日期、所有節次與課程依可用畫面高度配置，週末有課時一併呈現。
- 整週課表重新設計日期標籤、今天的欄位背景、六種課程配色、時間軸與格線；課名置頂、教室置底，保留目前時間紅線與課程點擊導覽。
- 底部顯示本週日期範圍與更新狀態；輔助使用字級保留捲動配置與完整課程無障礙標籤。
- 調整 iOS 相容性：App 最低 iOS 18.6，Widget Extension 最低 iOS 18.0。

## 封存與上傳

- 程式來源：`a4e3e4d`；包含整週課表與 iOS 相容性修改 `2a34540`、課表視覺修改 `4962d6e`，App／Widget 的 Debug／Release 建置號同步由 20 增為 21。
- 上傳前透過 App Store Connect 核對最高建置號為 1.2.0 (20)，狀態為「正在測試」；本次沿用版本號 1.2.0。
- 發行團隊：Very Fast Network LTD（G4LXL97NF9）。
- 封存：`~/Library/Developer/Xcode/Archives/2026-10-06/NIU-TestFlight-1.2.0-21.xcarchive`。
- Release archive 成功，封存日誌為 0 warning／0 error；App／Widget 的版本、建置號、最低 iOS 與簽章團隊已核對，`codesign --verify --deep --strict` 通過。
- 台北時間 2026-10-06 02:13:48，Xcode 回報 `Upload succeeded`，隨後回報 `EXPORT SUCCEEDED`，Apple 已開始處理上傳的套件。
- 上傳後已透過 App Store Connect 確認清單出現 1.2.0 (21)，建立日期為 2026-10-06 02:13，當下狀態為「處理中」；尚未確認可安裝測試。
- 匯出上傳另有兩項除錯符號警告：FirebaseAnalytics 與 GoogleAppMeasurement 缺少對應 dSYM；Xcode 仍確認套件上傳成功。
- 封存日誌：`/tmp/niu-testflight-1.2.0-21-archive.log`；上傳日誌：`/tmp/niu-testflight-1.2.0-21-upload.log`。

## 驗證範圍

- 依使用者要求，本次未執行自動化功能測試、模擬器或真機驗證；僅執行上傳所需的 Release 封存與封存資訊／簽章檢查。
- 本次未手動新增測試群組、送 Beta 審查或正式 App Store 審查。
