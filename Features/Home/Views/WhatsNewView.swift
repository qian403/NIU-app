import SwiftUI

/// Lists release notes. Presented once after an update (with `onContinue`) or pushed from Settings.
struct WhatsNewView: View {
    let notes: [ReleaseNotes]
    var onContinue: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                if onContinue != nil {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                        Text("本次更新內容")
                            .font(.largeTitle.bold())
                        if let latest = notes.first {
                            Text("NIU-Life \(latest.version)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, Theme.Spacing.large)
                }

                ForEach(notes) { release in
                    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                        // A single release is already named in the header or navigation title.
                        if notes.count > 1 || onContinue == nil {
                            Text("版本 \(release.version)")
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(release.items) { item in
                            WhatsNewItemRow(item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.large)
            .padding(.bottom, Theme.Spacing.large)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .navigationTitle(onContinue == nil ? "版本更新內容" : "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let onContinue {
                Button(action: onContinue) {
                    Text("開始使用")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.vertical, Theme.Spacing.small)
                .background(Color(.systemGroupedBackground))
            }
        }
    }
}

private struct WhatsNewItemRow: View {
    let item: ReleaseNotes.Item

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.medium) {
            Image(systemName: item.icon)
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxsmall) {
                Text(item.title)
                    .font(.headline)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("更新後") {
    WhatsNewView(notes: ReleaseNotes.catalog, onContinue: {})
}

#Preview("設定") {
    NavigationStack {
        WhatsNewView(notes: ReleaseNotes.catalog)
    }
}
