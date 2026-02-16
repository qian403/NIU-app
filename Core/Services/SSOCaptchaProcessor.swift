#if os(macOS)
import AppKit
public typealias CaptchaImage = NSImage
#else
import UIKit
public typealias CaptchaImage = UIImage
#endif
import Vision

public final class SSOCaptchaProcessor {
    public static let shared = SSOCaptchaProcessor()
    private init() {}

    public func recognize(from image: CaptchaImage, completion: @escaping (String?) -> Void) {
        guard let pre = preprocess(image: image) else {
            print("[Captcha] preprocess failed")
            completion(nil)
            return
        }

        guard let cgImage = pre.cgImage else {
            print("[Captcha] cgImage nil")
            completion(nil)
            return
        }

        let request = VNRecognizeTextRequest { [weak self] request, error in
            guard let self = self else { return }
            if let error = error {
                print("[Captcha] OCR error: \(error.localizedDescription)")
                completion(nil)
                return
            }

            guard let results = request.results as? [VNRecognizedTextObservation], !results.isEmpty else {
                print("[Captcha] OCR result empty")
                completion(nil)
                return
            }

            var raw = ""
            var elements: [(text: String, frame: CGRect)] = []

            for obs in results {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let text = candidate.string
                raw.append(text)
                elements.append((text, obs.boundingBox))
            }

            let fixed = self.fixZeroSix(on: pre, elements: elements)
            let mapped = self.mapChars(fixed)
            let digitsOnly = mapped.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
            print("[Captcha] raw=\(raw) fixed=\(fixed) mapped=\(mapped) digits=\(digitsOnly)")

            guard digitsOnly.count == 6 else {
                completion(nil)
                return
            }
            completion(digitsOnly)
        }

        request.recognitionLanguages = ["en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            completion(nil)
        }
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
            default: c = ch
            }
            out.append(c)
        }
        return out
    }
}
