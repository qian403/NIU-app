import ImageIO
import Photos
import SwiftUI
import UIKit

// MARK: - Options

enum ClassScheduleWallpaperStyle: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }
    var title: String { self == .light ? "淺色" : "深色" }
    var colorScheme: ColorScheme { self == .light ? .light : .dark }
}

enum ClassScheduleWallpaperSize: String, CaseIterable, Identifiable {
    case standard, compact

    var id: String { rawValue }
    var title: String { self == .standard ? "標準" : "精簡" }
}

// MARK: - Content

/// Weekly grid for a wallpaper: Mon–Fri plus weekend days that have classes,
/// trimmed to the first and last occupied periods. No dates, since the image is static.
nonisolated struct ClassScheduleWallpaperContent {
    let periods: [ClassPeriod]
    let layout: ClassScheduleWeekLayout
    /// Absolute indices in `periods`; end is exclusive.
    let rows: Range<Int>

    var isEmpty: Bool { layout.blocks.isEmpty }

    init(schedule: ClassSchedule, now: Date) {
        let weekend = CustomCourse.weekdayHeaders.dropFirst(5).filter { header in
            guard let column = schedule.dayHeaders.firstIndex(of: header) else { return false }
            return schedule.periods.contains { $0.course(for: column) != nil }
        }
        periods = schedule.periods
        layout = ClassScheduleWeekLayout(schedule: schedule,
                                         displayDayHeaders: Array(CustomCourse.weekdayHeaders.prefix(5)) + weekend,
                                         now: now)
        if let first = layout.blocks.map(\.rows.lowerBound).min(),
           let last = layout.blocks.map(\.rows.upperBound).max() {
            rows = first..<last
        } else {
            rows = 0..<0
        }
    }
}

// MARK: - Service

enum ClassScheduleWallpaperError: LocalizedError {
    case unreadableImage
    case renderFailed
    case photoAccessDenied

    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "無法讀取這張照片，請換一張再試。"
        case .renderFailed: return "桌布產生失敗，請再試一次。"
        case .photoAccessDenied: return "尚未允許加入照片。請到「設定」>「NIU-Life」>「照片」選擇「僅加入照片」。"
        }
    }
}

enum ClassScheduleWallpaperService {
    /// Portrait screen size in points and its pixel scale, so the output matches this device.
    static func screenMetrics() -> (size: CGSize, scale: CGFloat) {
        let screen = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.screen }
            .first
        let bounds = screen?.bounds.size ?? CGSize(width: 393, height: 852)
        let size = CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height))
        return (size, screen?.scale ?? 3)
    }

    /// Decodes only as many pixels as aspect-fill needs; full-size camera photos
    /// would otherwise cost hundreds of megabytes.
    @concurrent
    static func downsampledImage(from data: Data, filling pixelSize: CGSize) async throws -> UIImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth > 0, rawHeight > 0 else {
            throw ClassScheduleWallpaperError.unreadableImage
        }
        try Task.checkCancellation()
        // EXIF orientations 5–8 rotate by 90°, swapping the displayed width and height.
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let (width, height) = orientation >= 5 ? (rawHeight, rawWidth) : (rawWidth, rawHeight)
        let scale = min(1, max(pixelSize.width / width, pixelSize.height / height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height) * scale
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ClassScheduleWallpaperError.unreadableImage
        }
        return UIImage(cgImage: image)
    }

    static func render(_ canvas: some View, scale: CGFloat) throws -> UIImage {
        let renderer = ImageRenderer(content: canvas)
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.uiImage else { throw ClassScheduleWallpaperError.renderFailed }
        return image
    }

    /// Add-only access: the app never reads the user's library.
    static var photoAccessStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// Shows the system prompt only while the user hasn't decided yet.
    static func requestPhotoAccess() async -> Bool {
        var status = photoAccessStatus
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        }
        return status == .authorized || status == .limited
    }

    static func saveToPhotos(_ image: UIImage) async throws {
        guard await requestPhotoAccess() else { throw ClassScheduleWallpaperError.photoAccessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }
    }
}
