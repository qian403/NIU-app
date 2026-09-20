# 設定頁連線指示燈

學號下方橫排顯示校務系統、M 園區與 App 後端的連線檢查結果。綠燈表示服務入口可連線，不代表帳號登入、各服務 session、資料庫或推播傳送已驗證成功。

- 開啟設定頁、回到前景或點擊指示燈列時，並行檢查三個服務。
- 離開畫面、進入背景、登出或切換帳號會取消畫面工作；過期回應不更新新狀態。
- 檢查使用獨立的 ephemeral URLSession，不讀取或傳送帳密、token、cookie、裝置識別碼或個人資料，不觸發重新登入。
- 文字區分尚未檢查、檢查中、可連線、裝置離線、連線逾時、暫無法連線與尚未設定；不只依燈色表達狀態。
- 一般字級維持三欄橫排；無障礙放大字級保留橫向排列並可左右捲動，不強制縮小文字。

## 探測契約

| 服務 | 匿名 GET 入口 | 可連線判定 |
| --- | --- | --- |
| 校務系統 | `https://ccsys1.niu.edu.tw/SSO/login` | 同主機、同 scheme 的最終 HTTP 2xx 回應 |
| M 園區 | `https://euni.niu.edu.tw/login/index.php` | 同主機、同 scheme 的最終 HTTP 2xx 回應 |
| App 後端 | `NIUUsageAPIBaseURL` 下的 `/v1/usage/heartbeat` | 同主機、同 scheme，HTTP 405 且 JSON `error.code` 為 `method_not_allowed` |

後端部署的公開 gateway 不開放 `/healthz` 與 `/readyz`，因此不以這兩個路徑的 404 誤判服務故障。既有 heartbeat handler 在檢查 HTTP method 時就拒絕 GET，尚未讀取 payload 或寫入資料；此處只確認預期的拒絕回應來證明 API 可達，**不發送 POST、不回報使用統計**。未來若公開專用連線端點，需同步更新此契約及測試，不應將任意 4xx 視為成功。

## 驗證

執行 `python3 scripts/check-settings-connections.py`，以隔離的 URLProtocol fixture 驗證三個服務、錯誤回應、離線、逾時、取消與過期回應；不連線真實服務，也不讀取 Keychain。
