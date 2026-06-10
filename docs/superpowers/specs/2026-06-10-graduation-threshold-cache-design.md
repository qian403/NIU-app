# 畢業門檻本地快取 — 設計文件

日期：2026-06-10

## 背景與動機

畢業門檻頁（`Features/GraduationThreshold`）目前每次開啟都會啟動一個隱形
`WKWebView`，走完一連串 SSO 導向頁面（`MainFrame → ENRG010_01`）重新抓取資料。
這類資料「久久才變動一次」，每次都重抓造成不必要的等待與網路請求。

本案改為**本地快取優先**，對齊專案內既有的 `ClassSchedule` 快取模式。

## 目標

- 有快取且在有效期（7 天）內時，開頁立即顯示，**完全不連網**。
- 快取過期時仍先顯示舊資料，背景靜默重抓並更新。
- 首次使用（無快取）維持現有 `.loading` 行為。
- 背景刷新若失敗（session 過期 / 抓取失敗），保留既有快取畫面，不報錯破壞畫面。

## 非目標

- 不顯示「更新中」指示或快取時間（保持畫面乾淨）。
- 不寫入 App Group / 不支援 widget（此功能無 widget）。
- 不更動 `GraduationData` 既有欄位、不更動 WebView 抓取邏輯。

## 設計

### 資料結構（`GraduationThresholdModels.swift`）

`GraduationData` **維持不變**——它直接由 JS 回傳的 JSON 解碼，新增欄位會導致解碼失敗。
改為新增一個快取信封結構：

```swift
struct CachedGraduationData: Codable {
    let data: GraduationData
    let fetchedAt: Date

    /// 7 天 TTL，與 ClassSchedule 一致
    var isCacheValid: Bool {
        Date().timeIntervalSince(fetchedAt) < 7 * 24 * 3600
    }
}
```

### 快取儲存

- 後端：`UserDefaults.standard`
- Key：`"graduationThreshold.v1.cachedData"`
- 編碼：`JSONEncoder` / `JSONDecoder`

### ViewModel 流程（`GraduationThresholdViewModel.swift`）

新增狀態：

```swift
@Published var isFetchingInBackground = false
private let cacheKey = "graduationThreshold.v1.cachedData"
```

`loadGraduationData()` 改為快取優先：

```
if let cached = loadFromCache() {
    graduationData = cached.data
    loadState = .loaded
    if cached.isCacheValid {
        return                      // 有效快取，不連網
    }
    isFetchingInBackground = true   // 過期：背景重抓
    showWebView = true
} else {
    loadState = .loading            // 無快取：首次抓取
    showWebView = true
}
```

`handleWebResult(_:)` 調整：

- `.success(data)`：
  - `saveToCache(CachedGraduationData(data: data, fetchedAt: Date()))`
  - `graduationData = data`，`loadState = .loaded`
  - `isFetchingInBackground = false`，`sessionRefreshAttempted = false`
- `.sessionExpired`：維持既有單次 SSO 重試邏輯；**但最終失敗時，僅在 `graduationData == nil` 才設 `.error`**，已有快取則靜默保留。重試結束都要把 `isFetchingInBackground = false`。
- `.failure(message)`：**僅在 `graduationData == nil` 才設 `.error`**，否則靜默保留快取。`isFetchingInBackground = false`。

`refresh()` 加入清快取並強制重抓：

```
clearCache()
graduationData = nil
isFetchingInBackground = false
sessionRefreshAttempted = false
loadState = .loading
showWebView = true
```

新增私有方法：

```swift
private func loadFromCache() -> CachedGraduationData? {
    guard let data = UserDefaults.standard.data(forKey: cacheKey),
          let decoded = try? JSONDecoder().decode(CachedGraduationData.self, from: data)
    else { return nil }
    return decoded
}

private func saveToCache(_ cached: CachedGraduationData) {
    if let data = try? JSONEncoder().encode(cached) {
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

private func clearCache() {
    UserDefaults.standard.removeObject(forKey: cacheKey)
}
```

### View（`GraduationThresholdView.swift`）

**不更動。** `switch` 仍為 `.idle / .loading / .error / .loaded`，有資料即走 `.loaded`。
背景刷新時畫面持續顯示既有快取，使用者無感。

## 受影響檔案

| 檔案 | 改動 |
|------|------|
| `GraduationThresholdModels.swift` | 新增 `CachedGraduationData` 信封結構 |
| `GraduationThresholdViewModel.swift` | 快取優先載入、存/取/清快取、背景刷新失敗保留舊資料、`refresh()` 清快取 |
| `GraduationThresholdView.swift` | 無 |

## 邊界情況

- **無快取 + 抓取失敗**：`graduationData == nil` → 顯示 `.error`（同現狀）。
- **有快取 + 背景刷新失敗**：保留快取畫面，不報錯。
- **快取結構升級**：key 帶 `v1`，未來改結構可換 key 自然失效。
- **重新整理鈕**：永遠清快取強制重抓，給使用者手動更新出口。

## 測試方式

iOS 專案以手動驗證為主：

1. 首次開啟（清除 app 資料）→ 顯示 loading → 抓到資料顯示。
2. 立即再次開啟 → 秒顯示快取、無 WebView 載入。
3. 將 `fetchedAt` 設為 8 天前（或暫時把 TTL 改短）→ 開啟仍秒顯示舊資料，背景靜默更新。
4. 背景刷新時模擬 session 過期 → 畫面保留舊資料、不跳錯誤。
5. 按重新整理 → 清快取並重抓。
