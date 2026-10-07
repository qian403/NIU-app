import AppIntents
import SwiftUI

struct CampusShortcutsView: View {
    var body: some View {
        List {
            Section {
                ShortcutsLink()
                    .frame(minHeight: 44)
                    .accessibilityLabel("在捷徑 App 查看 NIU-Life 動作")
                Text("開啟「捷徑」，新增捷徑並搜尋 NIU-Life，即可把下列動作加入自己的流程或個人自動化。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section {
                action("啟動課表即時動態", symbol: "rectangle.topthird.inset.filled",
                       detail: "在背景啟用即時動態，依儲存課表啟動或更新內容。")
                action("更新課表即時動態", symbol: "arrow.clockwise",
                       detail: "在背景更新動態，必要時重新啟動；適合接在時間或開啟 App 等自動化條件之後。")
                action("關閉課表即時動態", symbol: "stop.circle",
                       detail: "結束動態並停用自動更新；再次啟動即可恢復。")
            } header: {
                Text("即時動態與靈動島")
            } footer: {
                Text("鎖定畫面與靈動島使用同一份即時動態。顯示時段為當天第一堂課前 30 分鐘至最後一堂課結束；不在時段內會結束舊動態。首次啟動需允許系統即時動態。")
            }

            Section {
                action("取得今天的課表", symbol: "calendar",
                       detail: "傳回今日課程、時間與教室，可接續「朗讀文字」或「顯示通知」。")
                action("取得下一堂課", symbol: "clock",
                       detail: "查詢未來 7 天尚未開始的下一堂課，包含日期、時間與教室。")
                action("重新整理校園小工具", symbol: "square.grid.2x2",
                       detail: "請求系統重新整理課表與行事曆小工具，實際更新時機由 iOS 安排。")
            } header: {
                Text("課表與小工具")
            } footer: {
                Text("捷徑讀取目前帳號已儲存的課表，包含自訂課程。請先登入並載入課表；更新校方課程資料仍需到 App 的課表重新整理。")
            }

            Section {
                action("開啟校園頁面", symbol: "arrow.up.forward.app",
                       detail: "可選課表、行事曆、快速點名、圖書館 QR Code、校園信箱或 M 園區。尚未登入時，完成登入後繼續前往。")
            } header: {
                Text("快速開啟")
            } footer: {
                Text("快速點名會開啟相機，仍需掃描校方 QR Code 完成點名。")
            }

            Section {
                action("上課前更新", symbol: "alarm",
                       detail: "先啟用課表即時動態，再設定時間自動化執行「更新課表即時動態」，即可更新或重新啟動動態。")
                action("早上朗讀課表", symbol: "speaker.wave.2",
                       detail: "依序加入「取得今天的課表」及「朗讀文字」，將課表結果作為朗讀內容。")
            } header: {
                Text("自動化範例")
            } footer: {
                Text("涉及個人課表的動作需解鎖裝置。自動化能否直接執行及背景更新時機依 iOS 設定與排程決定。")
            }
        }
        .navigationTitle("Siri 與捷徑")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func action(_ title: String, symbol: String, detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor)
        }
        .accessibilityElement(children: .combine)
    }
}
