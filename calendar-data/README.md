# 宜蘭大學完整學年度行事曆

公開校務日程的結構化資料，供 NIU-Life App、Widget 及未來 ICS 訂閱共用。這是非官方整理；各業務主管單位的後續公告仍可能調整日期。本目錄只保存公開年度行事曆，不保存帳號、個人課表或使用者資料。

## 資料與來源

| 學年度 | 日期範圍 | 事件 | PDF 週次區段 | 指定來源的維護日期 |
| --- | --- | --- | --- | --- |
| 114 | 2025-08-01 ～ 2026-07-31 | 93 | 53 | 2026-03-11 |
| 115 | 2026-08-01 ～ 2027-07-31 | 92 | 54 | 2026-07-15，v2 |

兩份來源都是完整年度 PDF，各有兩頁，依序為第一、第二學期。沒有加入獨立寒假或暑假版本。日期與備註已逐頁核對這兩份指定檔案；未宣稱已查遍校方網站所有後續修訂。

- [114 學年度校方 PDF](https://academic.niu.edu.tw/var/file/3/1003/img/1202/663121759.pdf)
- [115 學年度校方 PDF](https://academic.niu.edu.tw/var/file/3/1003/img/1202/503560003.pdf)
- [逐筆核對表](REVIEW.md)
- [年度 Schema](schema/calendar.schema.json)、[索引 Schema](schema/index.schema.json)

## GitHub 讀取入口

本目錄直接隨目前的 `qian403/NIU-app` 發布，使用 GitHub Raw 即可，不需要額外後端、資料庫或變更現有網站設定。

```text
https://raw.githubusercontent.com/qian403/NIU-app/main/calendar-data/index.json
https://raw.githubusercontent.com/qian403/NIU-app/main/calendar-data/years/114.json
https://raw.githubusercontent.com/qian403/NIU-app/main/calendar-data/years/115.json
```

`index.json` 列出可用學年度、revision、相對 path 與年度檔案的 SHA-256（檔案原始 UTF-8 bytes，包含結尾換行）。App 應先讀索引，再決定是否抓取年度檔。這些網址需在本次資料合併／推送後才存在。

目前 App 與 Widget 尚使用舊資料來源及格式；本次建立 v1 資料契約，不直接替換舊 URL。切換前必須一併實作新格式解析、快取與日期規則。

## v1 契約

年度檔的核心欄位：

| 欄位 | 意義 |
| --- | --- |
| `schemaVersion` | 資料契約版本，目前固定 1；不相容修改才升版 |
| `academicYear` | 民國學年度整數，例如 115 |
| `revision` | 該年度資料發布版本，任何內容修改都需增加 |
| `updatedAt` | 本份資料修訂時間，UTC RFC 3339，以 Z 結尾；不是校方維護日期 |
| `timeZone` | 固定 `Asia/Taipei` |
| `startDate` / `endDate` | 完整學年度：8 月 1 日至隔年 7 月 31 日，包含結束日 |
| `sources` | 校方 PDF URL、下載檔案 SHA-256、頁數、維護日期、文件版本、核定及更新說明 |
| `notes` | 校方共通備註，保留來源 ID 和頁碼 |
| `semesters` | 兩學期起訖與 `classesStartDate`；學期開始不等於正式開學 |
| `events` | 完整事件清單，按 `startDate`、`id` 排序 |
| `weeks` | 原 PDF 週次表，按日期排序 |

所有日期都是 `YYYY-MM-DD` 的校園民用日期，不應補成 UTC 午夜再轉換時區。App 判斷今天應採台北日期，避免使用者旅行後事件平移。全天區間兩端都包含：單日事件的開始、結束日相同；匯出 ICS 時才將 DTEND 轉為 endDate 的下一日。PDF 只有「截止日」時，不自行新增 23:59 截止時間。

### 事件

每筆必填：`id`、`title`、`startDate`、`endDate`、`category`、`semester`、`note`、`sourceId`、`sourcePage`、`sourceText`。`note` 沒內容填 `null`，不用空字串。

- ID 例如 `115-1-032`：首次建立後固定不變；改日期、名稱仍保留 ID，不按排序重新編號。新增事件使用該學年／學期歷來未使用的編號；刪除後的 ID 不回收。歷史比對能攔截原文不變卻重編 ID，但語意大幅修改仍需人工審查。
- `semester` 是事件在原文件的所屬學期，值為 1 或 2。依日期出現在某一學期頁面的前學期離校截止事項，仍屬該頁，原標題內的前學期資訊完整保留。
- `sourceText` 是原始日期條目，僅整理排版空白與換行。不同日期的同一行拆成多筆；同一日期下原本合併的多項截止事項保留為一筆，避免擅自改寫校方語意。
- 例如「9/21 期中預警開始（至11月20日止）」需存完整起訖；「12/21～1/10」的結束日期屬隔年。
- 文件中「寒假開始／暑假開始」是單日里程碑，不自行推測一段寒暑假區間。
- 放假一天、適逢假日、停課另擇期補課、評量自行安排等原文條件保存在 `note` 及 `sourceText`。不能只靠 `category == holiday` 改寫個人課表或取消提醒。

| category | 用途 |
| --- | --- |
| `semester` | 學期起訖、正式開學、寒暑假開始 |
| `registration` | 選課、加退選、申請停修期間 |
| `exam` | 真正的考試期間，不含教學評量問卷或成績預警 |
| `holiday` | 校方列出的節日及補假；是否停課仍須看原文 |
| `deadline` | 申請、繳費、繳交截止及退費基準日 |
| `activity` | 校慶、典禮、入宿、校際活動等 |
| `academic` | 教學評量、預警期間、成績公告、教學彈性週、暑修等 |
| `other` | 其他事項 |

### 週次

`weeks` 忠實保存 PDF 左側的週次欄。每段含起訖、semester、kind、number、label、sourceId、sourcePage。

- `kind`：`teaching`、`preparation`、`winter`、`summer`。
- `number`：對應原週次數字；預備週填 `null`。
- `label`：原標示，例如「一」「十八」「寒四」「暑五」「預備週」。
- PDF 採星期日至星期六，月界線的重複列合併；學年度和學期界線則截斷，全年每一天恰有一段。
- 115 年度的「寒四」因此分成 2027-01-31（第 1 頁）與 2027-02-01～02-06（第 2 頁）。
- 週次不是每日上課狀態。例如 115 年度 2027-01-10 落在「寒一」列，但期末考期間到當日才結束，寒假開始是 1/11。不得用 week.kind 直接取消課程。

### 校方版本與我們的版本

`sources[].maintainedOn`、`version` 記錄校方文件標示；PDF 沒有版本號就填 null，不用猜測。`sha256` 對應實際下載的 PDF，便於偵測相同 URL 下換檔。`approvalNotes` 與 `updateNotes` 保留原文，不自行核實或改寫校方敘述。

我們的 `revision` 與 `updatedAt` 獨立管理。修正轉錄錯字也要增加 revision，但不改校方維護日期。

## 更新、檢查、發布

```sh
python3 -m pip install -r calendar-data/requirements.txt
# 修改年度 JSON，增加該年的 revision，填入新的 updatedAt。
python3 calendar-data/scripts/update_index.py
python3 calendar-data/scripts/build_review.py
python3 calendar-data/scripts/validate.py --base-ref HEAD
python3 -m unittest discover -s calendar-data/tests -v
python3 calendar-data/scripts/build_review.py --check
```

`--base-ref` 應指向修改前的 commit；在 PR 中由 workflow 自動使用 base SHA。驗證包含 Schema、真實日期、索引與內容雜湊、來源頁碼、重複事件、完整年度與週次覆蓋、版本遞增及未變原文的 ID 穩定性。CI 不下載 PDF，也不宣稱機器能代替來源核對。

後續資料更新建議走 PR：下載校方新 PDF → 對照變更並保留 ID → 核對表人工檢查 → CI 通過 → 合併。GitHub Actions 設定於根目錄 `.github/workflows/calendar-data.yml`，只有讀取權限。本次沒有修改 GitHub 分支保護設定；push 檢查本身不會阻擋 main 的 Raw 網址發布。

僅提交 `calendar-data/` 與該 workflow，避免把其他尚未完成的 App 修改一起發布。不要把帳號、權杖、真實個人課表加入資料。

## App／Widget 接入規則

1. 使用同一份日期／事件模型及 App Group 快取；啟動先顯示上次驗證成功的資料，再檢查索引更新。
2. 依台北日期判斷「本學年度」，不是直接取索引中最大的年度（校方可能提早公布下一年）。
3. 年度檔通過 Schema、學年度、revision、SHA-256 與語意檢查後，才原子取代該年度快取。它是完整清單，不能永遠只追加；已撤回事件也要消失。
4. 更新失敗保留舊內容並顯示上次成功更新時間；當年度尚未公布就明確顯示未公布，不用上一年度冒充。
5. GitHub Raw/CDN 的索引與檔案可能暫時不同步；hash 不符應保留快取並稍後重試，不接受部分更新。需要固定快照時可將 URL 的 `main` 改成同一個 commit SHA。
6. 快取需依 academicYear/schemaVersion/revision 區分；Widget 不可只因快取非空就永久跳過更新。iOS 背景更新由系統排程，不能保證即時。
7. 不支援的 schemaVersion 不覆蓋現有可讀快取，提示需要更新 App。

目前尚未實作 App／Widget 接入或 ICS 輸出，這些規則是下一階段的共用契約。
