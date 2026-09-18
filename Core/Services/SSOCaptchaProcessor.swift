#if os(macOS)
import AppKit
public typealias CaptchaImage = NSImage
#else
import UIKit
public typealias CaptchaImage = UIImage
#endif
import Vision

public nonisolated final class SSOCaptchaProcessor: Sendable {
    public static let shared = SSOCaptchaProcessor()
    private init() {}

    public func recognize(from image: CaptchaImage, completion: @escaping (String?) -> Void) {
        Task {
            let code = await recognize(from: image)
            await MainActor.run {
                completion(code)
            }
        }
    }

    @concurrent
    public func recognize(from image: CaptchaImage) async -> String? {
        let variants = buildRecognitionVariants(from: image)
        var bestCandidate: OCRCandidate?

        for variant in variants {
            guard !Task.isCancelled else { return nil }
            guard let candidate = await recognizeVariant(variant) else { continue }
            if bestCandidate == nil || candidate.score > (bestCandidate?.score ?? Int.min) {
                bestCandidate = candidate
            }
            if candidate.digits.count == 6 {
                print("[Captcha] selected variant=\(variant.name) digits=\(candidate.digits)")
                return candidate.digits
            }
        }

        if let bestCandidate {
            print("[Captcha] best partial digits=\(bestCandidate.digits) score=\(bestCandidate.score)")
        } else {
            print("[Captcha] no OCR candidate")
        }
        return nil
    }

    private func preprocess(image: CaptchaImage) -> CaptchaImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        let drawOK: Bool = buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawOK else { return nil }

        let tol = 21
        let targets: [(Int, Int, Int)] = [
            (0x29, 0x2C, 0x29),
            (0x64, 0x65, 0x6D),
            (0x5B, 0x50, 0x54),
            (0x48, 0x3F, 0x3B),
            (0x64, 0x64, 0x65)
        ]

        @inline(__always) func isNearTarget(_ r: Int, _ g: Int, _ b: Int) -> Bool {
            for t in targets {
                if abs(t.0 - r) <= tol && abs(t.1 - g) <= tol && abs(t.2 - b) <= tol { return true }
            }
            return false
        }

        let replR = UInt8(0xE2), replG = UInt8(0xE0), replB = UInt8(0xE0)
        for y in 0..<height {
            let row = y * bytesPerRow
            var x = 0
            while x < width {
                let i = row + x * bytesPerPixel
                let r = Int(buffer[i + 0])
                let g = Int(buffer[i + 1])
                let b = Int(buffer[i + 2])

                if isNearTarget(r, g, b) {
                    buffer[i + 0] = replR
                    buffer[i + 1] = replG
                    buffer[i + 2] = replB
                }

                let lum = (77 * Int(buffer[i + 0]) + 150 * Int(buffer[i + 1]) + 29 * Int(buffer[i + 2])) >> 8
                let gray = UInt8(max(0, min(255, lum)))
                buffer[i + 0] = gray
                buffer[i + 1] = gray
                buffer[i + 2] = gray
                x += 1
            }
        }

        let outCG: CGImage? = buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return nil }
            guard let outCtx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return outCtx.makeImage()
        }
        guard let cgimg = outCG else { return nil }
        #if os(macOS)
        return CaptchaImage(cgImage: cgimg, size: NSSize(width: cgimg.width, height: cgimg.height))
        #else
        return CaptchaImage(cgImage: cgimg, scale: image.scale, orientation: image.imageOrientation)
        #endif
    }

    private struct ImageVariant {
        let name: String
        let image: CaptchaImage
    }

    private struct OCRCandidate {
        let variantName: String
        let raw: String
        let fixed: String
        let mapped: String
        let digits: String
        let confidence: Float
        let score: Int
    }

    private func buildRecognitionVariants(from image: CaptchaImage) -> [ImageVariant] {
        var variants: [ImageVariant] = []
        if let preprocessed = preprocess(image: image) {
            variants.append(ImageVariant(name: "preprocessed", image: preprocessed))
            if let scaled = scaled(image: preprocessed, factor: 2.0) {
                variants.append(ImageVariant(name: "preprocessed-x2", image: scaled))
            }
            for threshold in [140, 170, 200] {
                if let binarized = binarized(image: preprocessed, threshold: UInt8(threshold)) {
                    variants.append(ImageVariant(name: "threshold-\(threshold)", image: binarized))
                    if let scaled = scaled(image: binarized, factor: 2.0) {
                        variants.append(ImageVariant(name: "threshold-\(threshold)-x2", image: scaled))
                    }
                }
            }
        } else {
            variants.append(ImageVariant(name: "original", image: image))
        }
        return variants
    }

    private func recognizeVariant(_ variant: ImageVariant) async -> OCRCandidate? {
        guard let cgImage = variant.image.cgImage else {
            print("[Captcha] cgImage nil for \(variant.name)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { [weak self] request, error in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                if let error {
                    print("[Captcha] OCR error (\(variant.name)): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }

                guard let results = request.results as? [VNRecognizedTextObservation], !results.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                let orderedResults = results
                    .compactMap { observation -> (VNRecognizedText, CGRect)? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        return (candidate, observation.boundingBox)
                    }
                    .sorted { lhs, rhs in
                        if abs(lhs.1.minX - rhs.1.minX) > 0.015 {
                            return lhs.1.minX < rhs.1.minX
                        }
                        return lhs.1.minY > rhs.1.minY
                    }

                let raw = orderedResults.map { $0.0.string }.joined()
                let confidence = orderedResults.reduce(Float.zero) { $0 + $1.0.confidence }
                let elements = orderedResults.map { ($0.0.string, $0.1) }

                let fixed = self.fixZeroSix(on: variant.image, elements: elements)
                let mapped = self.mapChars(fixed)
                let digitsOnly = mapped.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)

                let score =
                    digitsOnly.count * 100
                    - abs(6 - digitsOnly.count) * 80
                    + Int(confidence * 100)
                    - max(0, raw.count - digitsOnly.count) * 12

                print("[Captcha] variant=\(variant.name) raw=\(raw) fixed=\(fixed) mapped=\(mapped) digits=\(digitsOnly) score=\(score)")

                continuation.resume(returning: OCRCandidate(
                    variantName: variant.name,
                    raw: raw,
                    fixed: fixed,
                    mapped: mapped,
                    digits: digitsOnly,
                    confidence: confidence,
                    score: score
                ))
            }

            request.recognitionLanguages = ["en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.12

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                print("[Captcha] OCR perform failed (\(variant.name)): \(error.localizedDescription)")
                continuation.resume(returning: nil)
            }
        }
    }

    private func scaled(image: CaptchaImage, factor: CGFloat) -> CaptchaImage? {
        guard factor > 1, let cg = image.cgImage else { return nil }
        let width = max(1, Int(CGFloat(cg.width) * factor))
        let height = max(1, Int(CGFloat(cg.height) * factor))
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let out = ctx.makeImage() else { return nil }
        #if os(macOS)
        return CaptchaImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        #else
        return CaptchaImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
        #endif
    }

    private func binarized(image: CaptchaImage, threshold: UInt8) -> CaptchaImage? {
        guard let cg = image.cgImage else { return nil }
        let width = cg.width
        let height = cg.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var buffer = [UInt8](repeating: 0, count: height * bytesPerRow)

        let ok: Bool = buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        for index in stride(from: 0, to: buffer.count, by: bytesPerPixel) {
            let gray = buffer[index]
            let value: UInt8 = gray < threshold ? 0 : 255
            buffer[index + 0] = value
            buffer[index + 1] = value
            buffer[index + 2] = value
            buffer[index + 3] = 255
        }

        let out: CGImage? = buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return nil }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return ctx.makeImage()
        }
        guard let out else { return nil }
        #if os(macOS)
        return CaptchaImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        #else
        return CaptchaImage(cgImage: out, scale: image.scale, orientation: image.imageOrientation)
        #endif
    }

    private func fixZeroSix(on image: CaptchaImage, elements: [(text: String, frame: CGRect)]) -> String {
        var out = ""
        for (t, frame) in elements {
            var c = t
            if t == "6" || t == "G" {
                if let crop = crop(image: image, rect: frame) {
                    if looksLikeZero(crop) { c = "0" }
                }
            }
            out.append(c)
        }
        return out
    }

    private func crop(image: CaptchaImage, rect: CGRect) -> CaptchaImage? {
        guard let cg = image.cgImage else { return nil }
        let r = CGRect(x: rect.origin.x * CGFloat(cg.width),
                       y: (1 - rect.origin.y - rect.height) * CGFloat(cg.height),
                       width: rect.width * CGFloat(cg.width),
                       height: rect.height * CGFloat(cg.height))
        guard let cut = cg.cropping(to: r.integral) else { return nil }
        #if os(macOS)
        return CaptchaImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
        #else
        return CaptchaImage(cgImage: cut, scale: image.scale, orientation: image.imageOrientation)
        #endif
    }

    private func looksLikeZero(_ img: CaptchaImage) -> Bool {
        guard let cg = img.cgImage else { return false }
        let w = cg.width, h = cg.height
        let bytesPerPixel = 4, bytesPerRow = bytesPerPixel * w
        var buf = Data(count: h * bytesPerRow)
        guard buf.withUnsafeMutableBytes({ ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }) else { return false }

        let black: (UInt8, UInt8, UInt8) -> Bool = { r, g, b in Int(r) < 64 }

        let topH = max(1, h / 2)
        let leftW = max(1, w / 2)
        var lt = 0, rt = 0, ltAll = 0, rtAll = 0
        buf.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
            guard let p = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<topH {
                let row = p.advanced(by: y * bytesPerRow)
                for x in 0..<leftW {
                    let px = row.advanced(by: x * bytesPerPixel)
                    if black(px[0], px[1], px[2]) { lt += 1 }
                    ltAll += 1
                }
                for x in leftW..<w {
                    let px = row.advanced(by: x * bytesPerPixel)
                    if black(px[0], px[1], px[2]) { rt += 1 }
                    rtAll += 1
                }
            }
        }
        let rLT = Double(lt) / Double(max(1, ltAll))
        let rRT = Double(rt) / Double(max(1, rtAll))
        let isZero = (rLT > 0.08 && rRT < 0.06) || abs(rLT - rRT) > 0.06
        return isZero
    }

    private func mapChars(_ s: String) -> String {
        var out = ""
        for ch in s {
            let c: Character
            switch ch {
            case "A", "a", "I", "l", "|": c = "1"
            case "O", "o", "Q", "e", "@": c = "0"
            case "S": c = "5"
            case "B": c = "8"
            case "Z": c = "2"
            case ">", "}": c = "7"
            default: c = ch
            }
            out.append(c)
        }
        return out
    }
}
