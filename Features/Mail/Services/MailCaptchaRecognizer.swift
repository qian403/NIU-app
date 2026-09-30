import Foundation
import CoreGraphics
import Vision

/// NUMail supplies small SVG paths. Rasterize the supported subset locally;
/// never execute SVG scripts, fetch resources, or send the image to an OCR service.
nonisolated enum MailCaptchaRecognizer {
    @concurrent
    static func recognize(svg: String) async throws -> String? {
        try Task.checkCancellation()
        let image = try rasterize(svg: svg)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.15
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        try Task.checkCancellation()
        let observations = (request.results ?? []).sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined()
        return candidate(from: text)
    }

    static func candidate(from text: String) -> String? {
        let compact = text.filter { !$0.isWhitespace }
        guard compact.count == 6,
              compact.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            return nil
        }
        return compact
    }

    static func rasterize(svg: String) throws -> CGImage {
        guard svg.utf8.count <= 256_000,
              !svg.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !svg.localizedCaseInsensitiveContains("<!ENTITY") else { throw CampusMailError.invalidResponse }
        let delegate = SVGPaths()
        let parser = XMLParser(data: Data(svg.utf8))
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let bounds = delegate.bounds,
              delegate.paths.count == 6 else { throw CampusMailError.captchaRecognitionFailed }
        let scale: CGFloat = 4
        guard let context = CGContext(data: nil, width: Int(bounds.width * scale), height: Int(bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CampusMailError.captchaRecognitionFailed
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
        context.translateBy(x: 0, y: bounds.height * scale)
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for path in delegate.paths {
            context.addPath(path)
            context.fillPath()
        }
        guard let image = context.makeImage() else { throw CampusMailError.captchaRecognitionFailed }
        return image
    }

    private final class SVGPaths: NSObject, XMLParserDelegate {
        var bounds: CGRect?
        var paths: [CGPath] = []
        var invalid = false
        private var depth = 0

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String]) {
            depth += 1
            if elementName == "svg", depth == 1, bounds == nil {
                let numbers = attributes["viewBox"]?.split(whereSeparator: { $0 == "," || $0.isWhitespace })
                    .compactMap { Double($0) } ?? []
                guard numbers.count == 4, numbers.allSatisfy(\.isFinite),
                      numbers[2] > 0, numbers[3] > 0, numbers[2] <= 512, numbers[3] <= 256 else {
                    invalid = true; return
                }
                bounds = CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            } else if elementName == "path", depth == 2,
                      Set(attributes.keys).isSubset(of: ["d", "fill", "stroke", "stroke-width"]) {
                // Stroke-only paths are the CAPTCHA's crossing lines, not character outlines.
                guard attributes["fill"] != "none" else { return }
                guard let d = attributes["d"], let path = Self.path(d), paths.count < 6 else {
                    invalid = true; return
                }
                paths.append(path)
            } else {
                invalid = true
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            depth -= 1
        }

        private static func path(_ data: String) -> CGPath? {
            let scanner = Scanner(string: data)
            scanner.locale = Locale(identifier: "en_US_POSIX")
            scanner.charactersToBeSkipped = .whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
            let path = CGMutablePath()
            var command = ""
            var hasStart = false
            var segments = 0
            func point() -> CGPoint? {
                guard let x = scanner.scanDouble(), let y = scanner.scanDouble(),
                      x.isFinite, y.isFinite, abs(x) < 10_000, abs(y) < 10_000 else { return nil }
                return CGPoint(x: x, y: y)
            }
            while !scanner.isAtEnd {
                segments += 1
                guard segments <= 10_000 else { return nil }
                _ = scanner.scanCharacters(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",")))
                let index = scanner.currentIndex
                if index < data.endIndex, data[index].isLetter {
                    command = String(data[index])
                    scanner.currentIndex = data.index(after: index)
                }
                switch command {
                case "M":
                    guard let p = point() else { return nil }
                    path.move(to: p); hasStart = true; command = "L"
                case "L":
                    guard hasStart, let p = point() else { return nil }
                    path.addLine(to: p)
                case "C":
                    guard hasStart, let a = point(), let b = point(), let end = point() else { return nil }
                    path.addCurve(to: end, control1: a, control2: b)
                case "Q":
                    guard hasStart, let a = point(), let end = point() else { return nil }
                    path.addQuadCurve(to: end, control: a)
                case "Z":
                    guard hasStart else { return nil }
                    path.closeSubpath(); command = ""
                default:
                    return nil
                }
            }
            return hasStart ? path : nil
        }
    }
}
