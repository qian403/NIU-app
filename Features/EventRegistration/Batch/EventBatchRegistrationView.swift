import SwiftUI

struct EventBatchRegistrationView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: EventBatchRegistrationViewModel

    init(events: [EventData], service: (any EventRegistrationServing)? = nil) {
        _model = StateObject(wrappedValue: EventBatchRegistrationViewModel(events: events, service: service))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    status
                }
                if !model.items.isEmpty {
                    Section(model.phase == .ready ? "確認清單" : "逐筆結果") {
                        ForEach(model.items) { item in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.event.name).font(.headline)
                                Text("活動編號：\(item.id)").font(.caption).foregroundStyle(.secondary)
                                if model.phase == .ready {
                                    Label(item.eligibility.canSubmit ? "可送出" : "排除・未送出",
                                          systemImage: item.eligibility.canSubmit ? "checkmark.circle" : "minus.circle")
                                        .font(.subheadline.weight(.semibold))
                                    Text(item.eligibility.reason).font(.subheadline)
                                    if !item.event.eventRegisterTime.isEmpty {
                                        Text("報名時間：\(item.event.eventRegisterTime)").font(.caption).foregroundStyle(.secondary)
                                    }
                                } else {
                                    Text(item.result.title).font(.subheadline.weight(.semibold))
                                    if let reason = item.result.reason { Text(reason).font(.subheadline) }
                                }
                            }
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
                Section {
                    Text("結果不明時，請關閉此畫面並切換到「已報名活動」重新整理，或開啟校方網頁查詢。本次登入不會再次送出結果不明的活動。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("批次活動報名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { model.leave(); dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                        .disabled(model.isSubmitting)
                }
            }
            .interactiveDismissDisabled(model.isSubmitting)
            .task { model.check() }
            .onDisappear { model.leave() }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .idle, .checking:
            ProgressView("正在核對校方可報名與已報名清單…")
                .padding(.vertical, 8)
        case .failed(let reason):
            Text("無法完成核對").font(.headline)
            Text(reason)
            Text("尚未送出任何報名；請重新核對後再確認。")
            Button("重試核對") { model.check() }.frame(minHeight: 44)
        case .ready:
            Text("可送出 \(model.eligibleCount) 項，排除 \(model.items.count - model.eligibleCount) 項。")
                .font(.headline)
            Text("請先確認下方清單。按確認後，App 將逐筆寫入校方報名紀錄；每項資格與名額以校方當時回應為準。")
            Button("確認報名 \(model.eligibleCount) 項") { model.confirm() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.borderedProminent)
                .disabled(!model.canConfirm)
        case .submitting:
            Text("已處理 \(model.processedCount)／\(model.eligibleCount) 項").font(.headline)
            ProgressView(model.stopRequested ? "等待目前這筆的校方結果…" : "正在逐筆報名…")
            Text("停止只會略過尚未送出的項目。目前這筆會繼續確認結果，完成後即可關閉。")
            Button(model.stopRequested ? "已要求停止" : "停止後續報名", role: .cancel) { model.stop() }
                .frame(minHeight: 44).disabled(model.stopRequested)
        case .finished:
            Text("批次處理完成").font(.headline)
            Text("請查看每一項的結果。失敗、未送出及結果不明的活動不會自動重送。")
        case .sessionChanged:
            Text("登入狀態已變更").font(.headline)
            Text("已停止後續報名並清除這個畫面的舊帳號資料。已送出的項目請登入原帳號後查看「已報名活動」。")
        }
    }
}
