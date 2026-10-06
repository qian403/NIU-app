import PhotosUI
import SwiftUI

// MARK: - Editor

struct ClassScheduleWallpaperView: View {
    /// School data only; custom courses are merged here when the toggle is on.
    let schedule: ClassSchedule
    let customCourses: [CustomCourse]
    let today: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @AppStorage("classSchedule.wallpaper.style") private var style: ClassScheduleWallpaperStyle = .light
    @AppStorage("classSchedule.wallpaper.size") private var size: ClassScheduleWallpaperSize = .standard
    @AppStorage("classSchedule.wallpaper.includesCustomCourses") private var includesCustomCourses = true

    @State private var pickerItem: PhotosPickerItem?
    @State private var background: UIImage?
    @State private var isLoadingImage = false
    @State private var isSaving = false
    @State private var message: Message?
    @State private var photoAccess = ClassScheduleWallpaperService.photoAccessStatus
    @State private var previewImage: UIImage?

    private let metrics = ClassScheduleWallpaperService.screenMetrics()

    /// Inputs that change the rendered picture; the preview re-renders only when one changes.
    private struct PreviewKey: Equatable {
        let style: ClassScheduleWallpaperStyle
        let size: ClassScheduleWallpaperSize
        let includesCustomCourses: Bool
        let background: ObjectIdentifier?
    }

    private var previewKey: PreviewKey {
        PreviewKey(style: style, size: size, includesCustomCourses: includesCustomCourses,
                   background: background.map(ObjectIdentifier.init))
    }

    private struct Message: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        var opensSettings = false
    }

    private var content: ClassScheduleWallpaperContent {
        let source = includesCustomCourses ? schedule.merging(customCourses, weekContaining: today) : schedule
        return ClassScheduleWallpaperContent(schedule: source, now: today)
    }

    var body: some View {
        let content = content
        NavigationStack {
            List {
                Section {
                    preview(content)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }

                Section {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        HStack {
                            Label(background == nil ? "選擇背景照片" : "更換背景照片", systemImage: "photo.on.rectangle")
                            Spacer()
                            if isLoadingImage { ProgressView() }
                        }
                        .frame(minHeight: 44)
                    }
                    if background != nil {
                        Button(role: .destructive) {
                            pickerItem = nil
                            background = nil
                        } label: {
                            Label("移除照片，改用預設背景", systemImage: "xmark.circle")
                                .frame(minHeight: 44, alignment: .leading)
                        }
                    }
                } footer: {
                    Text("照片只在這支手機上處理，不會上傳。")
                }

                Section {
                    Picker("課表樣式", selection: $style) {
                        ForEach(ClassScheduleWallpaperStyle.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("課表大小", selection: $size) {
                        ForEach(ClassScheduleWallpaperSize.allCases) { Text($0.title).tag($0) }
                    }
                    if !customCourses.isEmpty {
                        Toggle("包含自訂課程", isOn: $includesCustomCourses)
                    }
                } footer: {
                    Text("上方保留給鎖定畫面的時間，下方避開手電筒與相機按鈕。桌布是固定的圖片，課表更新或自訂課程到期後需要重新產生。")
                }

                Section {
                    Button {
                        save(content)
                    } label: {
                        HStack {
                            Label("儲存到相簿", systemImage: "square.and.arrow.down")
                            Spacer()
                            if isSaving { ProgressView() }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(content.isEmpty || isSaving || isLoadingImage)
                } footer: {
                    if content.isEmpty {
                        Text("目前課表沒有課程，無法產生桌布。")
                    } else if photoAccess == .denied || photoAccess == .restricted {
                        Text("尚未允許加入照片，儲存前請到「設定」>「NIU-Life」>「照片」選擇「僅加入照片」。")
                    } else if photoAccess == .notDetermined {
                        Text("第一次儲存時會詢問是否允許加入照片，App 不會讀取你的相簿。")
                    } else {
                        Text("儲存後到「照片」開啟圖片，點分享按鈕並選擇「做為背景圖片」。")
                    }
                }
            }
            .navigationTitle("課表桌布")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            // `task(id:)` cancels the previous load, so a slow photo can't replace a newer pick.
            .task(id: pickerItem) { await loadBackground(from: pickerItem) }
            .onChange(of: scenePhase) { _, phase in
                // The user may change the permission in Settings and come back.
                if phase == .active { photoAccess = ClassScheduleWallpaperService.photoAccessStatus }
            }
            .alert(message?.title ?? "", isPresented: Binding(get: { message != nil },
                                                              set: { if !$0 { message = nil } }),
                   presenting: message) { message in
                if message.opensSettings, let url = URL(string: UIApplication.openSettingsURLString) {
                    Button("前往設定") { openURL(url) }
                    Button("取消", role: .cancel) {}
                } else {
                    Button("好", role: .cancel) {}
                }
            } message: { message in
                Text(message.detail)
            }
        }
    }

    private func canvas(_ content: ClassScheduleWallpaperContent) -> some View {
        ClassScheduleWallpaperCanvas(content: content, background: background,
                                     style: style, size: size, canvasSize: metrics.size)
    }

    private func preview(_ content: ClassScheduleWallpaperContent) -> some View {
        let height: CGFloat = 440
        let scale = height / metrics.size.height
        // A rendered snapshot, not the live canvas: a full-size layout scaled down inside a
        // List cell overflows the row and kept the scroll edge effect re-invalidating.
        return ZStack(alignment: .top) {
            if let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
            } else {
                Theme.Colors.secondaryFill
                ProgressView().frame(maxHeight: .infinity)
            }
            lockScreenGuide(scale: scale)
        }
            .frame(width: metrics.size.width * scale, height: height)
            .task(id: previewKey) {
                previewImage = try? ClassScheduleWallpaperService.render(canvas(content), scale: scale * displayScale)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.CornerRadius.large))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.CornerRadius.large)
                    .strokeBorder(Theme.Colors.separator, lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(content.isEmpty ? "桌布預覽，目前沒有課程" : "桌布預覽，整週課表")
    }

    private var lockScreenDate: String {
        let parts = ScheduleClock.calendar.dateComponents([.month, .day, .weekday], from: today)
        let weekday = CustomCourse.weekdayHeaders[((parts.weekday ?? 2) + 5) % 7]
        return "\(parts.month ?? 1)月\(parts.day ?? 1)日 \(weekday)"
    }

    /// Preview-only stand-in for the lock screen clock; never rendered into the saved image.
    private func lockScreenGuide(scale: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(lockScreenDate)
                .font(.system(size: 20 * scale, weight: .semibold))
            Text("9:41")
                .font(.system(size: 96 * scale, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.55))
        .shadow(color: .black.opacity(0.2), radius: 2)
        .padding(.top, metrics.size.height * 0.08 * scale)
        .allowsHitTesting(false)
    }

    private func loadBackground(from item: PhotosPickerItem?) async {
        guard let item else { return }
        isLoadingImage = true
        defer { if !Task.isCancelled { isLoadingImage = false } }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw ClassScheduleWallpaperError.unreadableImage
            }
            let pixels = CGSize(width: metrics.size.width * metrics.scale, height: metrics.size.height * metrics.scale)
            let image = try await ClassScheduleWallpaperService.downsampledImage(from: data, filling: pixels)
            try Task.checkCancellation()
            background = image
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            message = Message(title: "無法使用這張照片",
                              detail: (error as? LocalizedError)?.errorDescription ?? "請換一張照片再試。")
        }
    }

    private func save(_ content: ClassScheduleWallpaperContent) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            // Ask before rendering so the system prompt appears right after the tap.
            let granted = await ClassScheduleWallpaperService.requestPhotoAccess()
            photoAccess = ClassScheduleWallpaperService.photoAccessStatus
            guard granted else {
                message = Message(title: "無法儲存桌布",
                                  detail: ClassScheduleWallpaperError.photoAccessDenied.errorDescription ?? "",
                                  opensSettings: photoAccess == .denied)
                return
            }
            do {
                let image = try ClassScheduleWallpaperService.render(canvas(content), scale: metrics.scale)
                try await ClassScheduleWallpaperService.saveToPhotos(image)
                message = Message(title: "已儲存到相簿",
                                  detail: "到「照片」開啟這張圖片，點分享按鈕並選擇「做為背景圖片」即可設定。")
            } catch {
                message = Message(title: "無法儲存桌布",
                                  detail: (error as? LocalizedError)?.errorDescription ?? "請再試一次。")
            }
        }
    }
}

// MARK: - Canvas

/// The exact image that gets saved, laid out in screen points. Uses fixed font sizes and
/// explicit colours because the result is a picture, not a live interface.
struct ClassScheduleWallpaperCanvas: View {
    let content: ClassScheduleWallpaperContent
    let background: UIImage?
    let style: ClassScheduleWallpaperStyle
    let size: ClassScheduleWallpaperSize
    let canvasSize: CGSize

    private let palette: [Color] = [.blue, .teal, .orange, .pink, .green, .indigo]
    private let padding: CGFloat = 10
    private let headerHeight: CGFloat = 22
    private let gutterWidth: CGFloat = 28

    private var isDark: Bool { style == .dark }
    private var ink: Color { isDark ? .white : .black }

    private var cardFrame: CGRect {
        let width = canvasSize.width - 28
        // Top keeps clear of the lock screen clock; bottom of the flashlight and camera buttons.
        let bottom = canvasSize.height * 0.885
        let top = canvasSize.height * (size == .standard ? 0.34 : 0.52)
        let rows = CGFloat(max(1, content.rows.count))
        let rowHeight = min(56, (bottom - top - padding * 2 - headerHeight) / rows)
        let height = padding * 2 + headerHeight + rowHeight * rows
        return CGRect(x: 14, y: bottom - height, width: width, height: height)
    }

    private var rowHeight: CGFloat {
        (cardFrame.height - padding * 2 - headerHeight) / CGFloat(max(1, content.rows.count))
    }

    private var columnWidth: CGFloat {
        (cardFrame.width - padding * 2 - gutterWidth) / CGFloat(max(1, content.layout.columns.count))
    }

    var body: some View {
        let card = cardFrame
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        ZStack(alignment: .topLeading) {
            backdrop
            if !content.isEmpty {
                // A blurred copy of the backdrop behind the card keeps text legible on busy photos.
                backdrop
                    .blur(radius: 24, opaque: true)
                    .mask {
                        shape.frame(width: card.width, height: card.height).position(x: card.midX, y: card.midY)
                    }
                grid
                    .padding(padding)
                    .frame(width: card.width, height: card.height, alignment: .topLeading)
                    .background(isDark ? Color.black.opacity(0.45) : Color.white.opacity(0.6), in: shape)
                    .overlay { shape.strokeBorder(ink.opacity(0.12), lineWidth: 0.5) }
                    .offset(x: card.minX, y: card.minY)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, style.colorScheme)
    }

    @ViewBuilder
    private var backdrop: some View {
        if let background {
            Image(uiImage: background)
                .resizable()
                .scaledToFill()
                .frame(width: canvasSize.width, height: canvasSize.height)
                .clipped()
        } else {
            LinearGradient(colors: [Color(red: 0.33, green: 0.47, blue: 0.86), Color(red: 0.6, green: 0.38, blue: 0.78)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: canvasSize.width, height: canvasSize.height)
        }
    }

    private var grid: some View {
        let rows = content.rows, periods = content.periods
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: gutterWidth)
                ForEach(content.layout.columns) { column in
                    Text(column.shortLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink.opacity(0.7))
                        .frame(width: columnWidth)
                }
            }
            .frame(height: headerHeight, alignment: .top)

            ZStack(alignment: .topLeading) {
                ForEach(Array(rows), id: \.self) { row in
                    let y = CGFloat(row - rows.lowerBound) * rowHeight
                    VStack(spacing: 0) {
                        Text(periods[row].id)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(ink.opacity(0.75))
                        if rowHeight >= 30, !periods[row].startTimeLabel.isEmpty {
                            Text(periods[row].startTimeLabel)
                                .font(.system(size: 7.5).monospacedDigit())
                                .foregroundStyle(ink.opacity(0.5))
                        }
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(width: gutterWidth, height: rowHeight)
                    .offset(y: y)
                    ink.opacity(0.08)
                        .frame(width: columnWidth * CGFloat(content.layout.columns.count), height: 0.5)
                        .offset(x: gutterWidth, y: y)
                }
                ForEach(content.layout.blocks) { block in
                    let inset: CGFloat = 1.5
                    courseBlock(block)
                        .frame(width: columnWidth - inset * 2,
                               height: CGFloat(block.rows.count) * rowHeight - inset * 2)
                        .offset(x: gutterWidth + CGFloat(block.column) * columnWidth + inset,
                                y: CGFloat(block.rows.lowerBound - rows.lowerBound) * rowHeight + inset)
                }
            }
        }
    }

    private func courseBlock(_ block: ClassScheduleWeekLayout.Block) -> some View {
        let colour = palette[ClassScheduleWeekLayout.stableColourIndex(for: block.course.name, paletteCount: palette.count)]
        let height = CGFloat(block.rows.count) * rowHeight
        let nameSize = min(11.5, max(8.5, rowHeight * 0.3))
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return VStack(alignment: .leading, spacing: 2) {
            Text(block.course.name)
                .font(.system(size: nameSize, weight: .semibold))
                .foregroundStyle(ink)
                .lineLimit(max(1, Int((height - 16) / (nameSize * 1.25))))
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            if height >= 36, !block.classrooms.isEmpty {
                Text(block.classrooms.joined(separator: "、"))
                    .font(.system(size: 8.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(ink.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(colour.opacity(isDark ? 0.42 : 0.24), in: shape)
        .overlay(alignment: .leading) { colour.frame(width: 2.5) }
        .overlay {
            // Custom courses keep the dashed edge used in the weekly view.
            if block.course.customCourseID != nil {
                shape.strokeBorder(colour.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .clipShape(shape)
    }
}
