import SwiftUI

struct SpecialThanksView: View {
    @StateObject private var viewModel = CreditsViewModel()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                if let document = viewModel.snapshot?.document {
                    Text(document.introduction)
                        .font(.body)
                        .foregroundStyle(.secondary)

                    if document.entries.isEmpty {
                        Text("目前沒有特別感謝項目。")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(document.sortedEntries) { entry in
                        Link(destination: entry.url) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                                Label(entry.name, systemImage: "person.fill")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(entry.description)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                Label(entry.projectName, systemImage: "arrow.up.right.square")
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Spacing.medium)
                            .background(Color(.secondarySystemGroupedBackground),
                                        in: RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .combine)
                        .accessibilityHint("開啟 \(entry.projectName) 專案網頁")
                    }
                    Text("來源：\(viewModel.snapshot?.source.rawValue ?? "") · 修訂 \(document.revision)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !viewModel.isLoading {
                    Text("目前無法取得感謝名單，請重新整理。")
                }

                if let message = viewModel.snapshot?.message {
                    Label(message, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(viewModel.isLoading ? "正在檢查更新⋯" : "下拉可更新感謝名單")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.large)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .navigationTitle("特別感謝")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await viewModel.load(force: true) }
        .task { await viewModel.load() }
        .onDisappear { viewModel.cancel() }
    }
}
