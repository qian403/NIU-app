import SwiftUI

struct GraduationThresholdView: View {
    @StateObject private var vm = GraduationThresholdViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(.systemBackground),
                        Color(.systemGroupedBackground)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                switch vm.loadState {
                case .idle, .loading:
                    ProgressView("載入畢業門檻資料…")
                        .progressViewStyle(.circular)
                        .tint(.primary)

                case .error(let message):
                    errorView(message: message)

                case .loaded:
                    if let data = vm.graduationData {
                        contentView(data: data)
                    }
                }
            }
            .navigationTitle("畢業門檻")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: Theme.Spacing.small) {
                        if vm.graduationData != nil {
                            Button(action: vm.toggleWebView) {
                                Image(systemName: vm.isWebVisible ? "doc.text" : "globe")
                                    .font(.system(size: 16, weight: .light))
                            }
                        }
                        Button(action: vm.refresh) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16, weight: .light))
                        }
                    }
                }
            }
        }
        .overlay {
            if vm.showWebView {
                GraduationThresholdWebView(onResult: vm.handleWebResult)
                    .frame(width: 360, height: 640)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func contentView(data: GraduationData) -> some View {
        if vm.isWebVisible {
            if vm.showWebView {
                GraduationThresholdWebView(onResult: vm.handleWebResult)
            } else {
                Text("載入網頁中…")
                    .foregroundColor(.secondary)
            }
        } else {
            ScrollView {
                VStack(spacing: Theme.Spacing.large) {
                    overallCard(data: data)
                    diverseHoursCard(data: data)
                    abilityCards(data: data)
                    creditCard(data: data)
                    if hasCreditCourse(data) {
                        creditCourseCard(data: data)
                    }
                }
                .padding(.horizontal, Theme.Spacing.large)
                .padding(.top, Theme.Spacing.medium)
                .padding(.bottom, Theme.Spacing.large)
            }
        }
    }

    // MARK: - Overall Hero Card

    private func overallCard(data: GraduationData) -> some View {
        let progress = overallProgress(data)
        let percent = Int((progress * 100).rounded())

        return HStack(spacing: Theme.Spacing.large) {
            VStack(alignment: .leading, spacing: 8) {
                Text("整體達成度")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))

                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    Text("\(percent)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("%")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.bottom, 6)
                }

                Text(progressDescription(progress))
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                Circle()
                    .stroke(.white.opacity(0.22), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, progress)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "graduationcap.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(.white)
            }
            .frame(width: 92, height: 92)
        }
        .padding(Theme.Spacing.large)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor,
                    Color.accentColor.opacity(0.75)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous))
        .shadow(color: Color.accentColor.opacity(0.25), radius: 10, x: 0, y: 6)
    }

    // MARK: - 多元時數

    private func diverseHoursCard(data: GraduationData) -> some View {
        let d = data.diverseHours
        let rows: [(String, String, String)] = [
            ("服務", value(d, 0), value(d, 1)),
            ("多元", value(d, 2), value(d, 3)),
            ("專業", value(d, 4), value(d, 5)),
            ("綜合", value(d, 6), value(d, 7))
        ]

        return sectionCard {
            sectionHeader(icon: "clock.badge.checkmark", title: "多元時數")

            VStack(spacing: 14) {
                ForEach(rows, id: \.0) { row in
                    DiverseHoursProgressRow(title: row.0, current: row.1, total: row.2)
                }
            }
        }
    }

    // MARK: - 英語 / 體適能

    private func abilityCards(data: GraduationData) -> some View {
        HStack(spacing: Theme.Spacing.medium) {
            abilityTile(title: "英語能力", value: data.englishAbility, icon: "character.book.closed")
            abilityTile(title: "體適能", value: data.physicalFitness, icon: "figure.run")
        }
    }

    private func abilityTile(title: String, value: String, icon: String) -> some View {
        let passed = isPassed(value)
        let tint: Color = passed ? .green : .orange
        let statusLabel = value.isEmpty ? "尚未登錄" : value

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer(minLength: 0)
            }

            HStack(spacing: 6) {
                Image(systemName: passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                Text(statusLabel)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }

    // MARK: - 學分

    private func creditCard(data: GraduationData) -> some View {
        let required = Double(data.creditRequired.first ?? "") ?? 0
        let earned = data.creditRequired.count >= 2 ? (Double(data.creditRequired[1]) ?? 0) : 0
        let progress = required > 0 ? min(1.0, earned / required) : 0

        return sectionCard {
            sectionHeader(icon: "books.vertical.fill", title: "應修學分")

            VStack(spacing: 14) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(numberText(earned))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                    Text("/")
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text(numberText(required))
                        .font(.system(size: 20, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)

                    Text(required > 0 ? "\(Int((progress * 100).rounded()))%" : "—")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                LinearProgress(progress: progress)
            }
        }
    }

    // MARK: - 學分學程

    private func creditCourseCard(data: GraduationData) -> some View {
        sectionCard {
            sectionHeader(icon: "graduationcap", title: "學分學程")

            Text(data.creditCourse.replacingOccurrences(of: "、", with: "\n"))
                .font(.system(size: 15))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hasCreditCourse(_ data: GraduationData) -> Bool {
        let trimmed = data.creditCourse.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "無" && trimmed.count >= 2
    }

    // MARK: - Shared chrome

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            content()
        }
        .padding(Theme.Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.CornerRadius.large, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }

    private func sectionHeader(icon: String, title: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: Theme.Spacing.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button(action: vm.refresh) {
                Text("重試")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, Theme.Spacing.large)
                    .padding(.vertical, Theme.Spacing.small)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.CornerRadius.medium)
                            .fill(Color.accentColor)
                    )
            }
        }
        .padding(Theme.Spacing.large)
    }

    // MARK: - Helpers

    private func value(_ arr: [String], _ index: Int) -> String {
        guard index < arr.count else { return "0" }
        return arr[index]
    }

    private func numberText(_ n: Double) -> String {
        if n.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", n)
        }
        return String(format: "%.1f", n)
    }

    private func isPassed(_ s: String) -> Bool {
        if s.isEmpty { return false }
        if s.contains("未") || s.contains("不") { return false }
        return true
    }

    private func overallProgress(_ data: GraduationData) -> Double {
        var samples: [Double] = []

        // 多元時數: average of 4 categories
        let d = data.diverseHours
        for (doneIdx, totalIdx) in [(0,1),(2,3),(4,5),(6,7)] {
            guard doneIdx < d.count, totalIdx < d.count else { continue }
            let done = Double(d[doneIdx]) ?? 0
            let total = Double(d[totalIdx]) ?? 0
            guard total > 0 else { continue }
            samples.append(min(1.0, done / total))
        }

        // 英語 / 體適能
        samples.append(isPassed(data.englishAbility) ? 1.0 : 0.0)
        samples.append(isPassed(data.physicalFitness) ? 1.0 : 0.0)

        // 學分
        if data.creditRequired.count >= 2,
           let required = Double(data.creditRequired[0]), required > 0,
           let earned = Double(data.creditRequired[1]) {
            samples.append(min(1.0, earned / required))
        }

        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0, +) / Double(samples.count)
    }

    private func progressDescription(_ progress: Double) -> String {
        switch progress {
        case ..<0.4: return "起步階段，繼續加油"
        case ..<0.7: return "穩定推進中"
        case ..<0.95: return "即將達成各項門檻"
        default: return "已接近全數達成"
        }
    }
}

// MARK: - Diverse Hours Progress Row

private struct DiverseHoursProgressRow: View {
    let title: String
    let current: String
    let total: String

    var body: some View {
        let cur = Double(current) ?? 0
        let tot = Double(total) ?? 0
        let progress = tot > 0 ? min(1.0, cur / tot) : 0
        let tint = progressTint(progress)

        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Spacer()
                Text("\(formatNumber(cur)) / \(formatNumber(tot))")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            LinearProgress(progress: progress, tint: tint)
        }
    }

    private func formatNumber(_ n: Double) -> String {
        if n.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", n)
        }
        return String(format: "%.1f", n)
    }

    private func progressTint(_ p: Double) -> Color {
        if p >= 1 { return .green }
        if p >= 0.6 { return Color.accentColor }
        return .orange
    }
}

// MARK: - Linear Progress Bar

private struct LinearProgress: View {
    let progress: Double
    var tint: Color = Color.accentColor

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.85), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, proxy.size.width * CGFloat(max(0, min(1, progress)))))
            }
        }
        .frame(height: 8)
    }
}
