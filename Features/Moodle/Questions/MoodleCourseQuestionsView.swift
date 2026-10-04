import SwiftUI

struct MoodleCourseQuestionsView: View {
    let courseId: Int
    @ObservedObject var viewModel: MoodleQuestionsViewModel
    @State private var reloadID = 0

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.sections.isEmpty {
                ProgressView("正在載入問答活動…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        if let error = viewModel.errorMessage {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle")
                                if !viewModel.sections.isEmpty {
                                    Text("以下保留上次載入的活動。")
                                }
                                Button("重試") { reloadID += 1 }
                                    .frame(minHeight: 44)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }

                        if !MoodleSearch.trimmed(viewModel.searchText).isEmpty && viewModel.filteredSections.isEmpty
                            && (viewModel.errorMessage == nil || !viewModel.sections.isEmpty) {
                            MoodleSearchEmptyView(searchText: viewModel.searchText)
                        } else if viewModel.sections.isEmpty && viewModel.errorMessage == nil {
                            ContentUnavailableView {
                                Label("目前沒有問答活動", systemImage: "questionmark.bubble")
                            } description: {
                                Text("此處顯示老師已開放的測驗、即時問答、選擇與問卷。")
                            } actions: {
                                Button("重新整理") { reloadID += 1 }
                            }
                        } else if !viewModel.sections.isEmpty {
                            Text("選擇活動後，即可在 App 內查看題目與作答。開放時間、提交與結果以 M 園區顯示為準。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            ForEach(viewModel.filteredSections) { section in
                                Text(section.name)
                                    .font(.headline)
                                    .accessibilityAddTraits(.isHeader)
                                ForEach(section.modules) { module in
                                    if module.questionActivityURL != nil {
                                        NavigationLink {
                                            MoodleQuestionDetailView(module: module)
                                        } label: {
                                            questionRow(module, available: true)
                                        }
                                        .buttonStyle(.plain)
                                    } else {
                                        questionRow(module, available: false)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.medium)
                }
                .refreshable { await viewModel.load(courseId: courseId, force: true) }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .task(id: reloadID) { await viewModel.load(courseId: courseId, force: reloadID > 0) }
        .onDisappear { viewModel.cancel() }
    }

    private func questionRow(_ module: MoodleModule, available: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: module.iconName)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(module.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(module.questionActivityKind?.title ?? "問答")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !available {
                    Label("尚未開放或未符合存取條件", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if available {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }
}
