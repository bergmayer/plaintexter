import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

public enum PDFConversionError: LocalizedError {
    case invalidDocument, locked, copyingNotAllowed, noReadableText, unreadablePage(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument: "This PDF could not be opened. The clipboard has been left unchanged."
        case .locked: "This PDF requires a password. Unlock it before copying it."
        case .copyingNotAllowed: "This PDF does not allow copying its text."
        case .noReadableText: "No readable text was found in this PDF, including after OCR. The clipboard has been left unchanged."
        case .unreadablePage(let page): "PDF page \(page) could not be read. The clipboard has been left unchanged."
        }
    }
}

@MainActor
public struct PDFRenderer {
    public init() {}

    public func render(_ data: Data, format: TextFormat, ocr: ImageOCR) async throws -> String {
        let reader = PDFPageReader()
        let count = try await reader.open(data)
        var pages: [String] = []
        var foundText = false
        for index in 0..<count {
            try Task.checkCancellation()
            let page = try await reader.readPage(index, includeFormatting: format == .markdown)
            try Task.checkCancellation()
            if let image = page.image, let recognized = await ocr.text(in: image, minimumCharacters: 1) {
                let recognizedWords = " " + normalizedWords(recognized) + " "
                let missing = page.nativeFragments.filter {
                    !recognizedWords.contains(" " + normalizedWords($0.text) + " ")
                }
                let combined = (missing.filter(\.isHeader).map(\.text) + [recognized] + missing.filter { !$0.isHeader }.map(\.text)).joined(separator: "\n")
                pages.append(ImageOCR.formatted(combined, as: format))
                foundText = true
            } else if !page.text.isEmpty {
                var text = page.text
                if format == .markdown {
                    if let rtf = page.rtf, let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                        text = try await RichTextRenderer().render(attributed, format: .markdown)
                    } else { text = ImageOCR.formatted(text, as: .markdown) }
                }
                if page.image != nil {
                    text += "\n\n" + notice("No readable text found in the scanned content on PDF page \(index + 1).", format: format)
                }
                pages.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                foundText = true
            } else if page.image != nil {
                pages.append(notice("No readable text found on PDF page \(index + 1).", format: format))
            }
        }
        try Task.checkCancellation()
        guard foundText else { return ImageOCR.noTextMessage }
        return pages.joined(separator: "\n\n")
    }

    public func render(file url: URL, format: TextFormat, ocr: ImageOCR) async throws -> String {
        let data = try await Task.detached(priority: .userInitiated) { try Data(contentsOf: url) }.value
        try Task.checkCancellation()
        return try await render(data, format: format, ocr: ocr)
    }

    nonisolated static func isPDF(_ data: Data) -> Bool {
        // The PDF header is permitted within the first 1024 bytes.
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    private func notice(_ text: String, format: TextFormat) -> String {
        format == .markdown ? "> " + Markdown.escape(text) : "[" + text + "]"
    }

    private func normalizedWords(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct PDFNativeFragment: Sendable {
    let text: String
    let isHeader: Bool
}

struct PDFPageContent: Sendable {
    let text: String
    let rtf: Data?
    let image: Data?
    let nativeFragments: [PDFNativeFragment]
}

/// PDFKit objects stay on one actor. Only immutable text and data cross to the UI actor.
actor PDFPageReader {
    private var document: PDFDocument?

    func open(_ data: Data) throws -> Int {
        guard let document = PDFDocument(data: data) else { throw PDFConversionError.invalidDocument }
        guard !document.isLocked else { throw PDFConversionError.locked }
        guard document.allowsCopying else { throw PDFConversionError.copyingNotAllowed }
        guard document.pageCount > 0 else { throw PDFConversionError.noReadableText }
        self.document = document
        return document.pageCount
    }

    func readPage(_ index: Int, includeFormatting: Bool) throws -> PDFPageContent {
        try Task.checkCancellation()
        return try autoreleasepool {
            guard let page = document?.page(at: index) else { throw PDFConversionError.unreadablePage(index + 1) }
            let rawText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let alphanumericCount = rawText.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
            let badCharacters = rawText.unicodeScalars.filter { $0 == "\u{FFFD}" || $0 == "\u{0000}" }.count
            let usableText = alphanumericCount > 0 && badCharacters * 5 < max(1, rawText.unicodeScalars.count)
            let text = usableText ? rawText : ""
            // Digital filing stamps, headers, or footers are not a complete text layer for a scanned page.
            let needsOCR = !usableText || (containsImages(page) && textCoverage(page) < 0.12)
            let rtf = includeFormatting && usableText ? richText(page) : nil
            let image = needsOCR ? try rasterize(page, index: index) : nil
            let fragments = needsOCR && usableText ? nativeFragments(page) : []
            return PDFPageContent(text: text, rtf: rtf, image: image, nativeFragments: fragments)
        }
    }

    private func nativeFragments(_ page: PDFPage) -> [PDFNativeFragment] {
        guard let reference = page.pageRef,
              let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else { return [] }
        let box = reference.getBoxRect(.cropBox)
        let rotated = abs(reference.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let transform = reference.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true)
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return PDFNativeFragment(text: text, isHeader: line.bounds(for: page).applying(transform).midY >= size.height / 2)
        }
    }

    private func textCoverage(_ page: PDFPage) -> CGFloat {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0,
              let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else { return 0 }
        let area = selection.selectionsByLine().reduce(CGFloat.zero) { total, line in
            let rect = line.bounds(for: page).intersection(bounds)
            return total + (rect.isNull ? 0 : rect.width * rect.height)
        }
        return area / (bounds.width * bounds.height)
    }

    private func richText(_ page: PDFPage) -> Data? {
        guard let attributed = page.attributedString else { return nil }
        let text = NSMutableAttributedString(attributedString: attributed)
        for annotation in page.annotations {
            guard let url = annotation.url, let selection = page.selection(for: annotation.bounds) else { continue }
            for index in 0..<selection.numberOfTextRanges(on: page) {
                let range = selection.range(at: index, on: page)
                if range.location != NSNotFound, NSMaxRange(range) <= text.length {
                    text.addAttribute(.link, value: url, range: range)
                }
            }
        }
        return text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:])
    }

    private func rasterize(_ page: PDFPage, index: Int) throws -> Data? {
        guard let reference = page.pageRef else { throw PDFConversionError.unreadablePage(index + 1) }
        let box = reference.getBoxRect(.cropBox)
        let rotated = abs(reference.rotationAngle) % 180 == 90
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            throw PDFConversionError.unreadablePage(index + 1)
        }
        let scale = min(3, 4000 / max(size.width, size.height))
        let width = max(1, Int(ceil(size.width * scale)))
        let height = max(1, Int(ceil(size.height * scale)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw PDFConversionError.unreadablePage(index + 1)
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        // CGPDF's fitting transform does not reliably upscale small pages. Apply the pixel scale explicitly.
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.concatenate(reference.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(reference)
        guard hasVisibleMarks(context) else { return nil }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw PDFConversionError.unreadablePage(index + 1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw PDFConversionError.unreadablePage(index + 1) }
        return data as Data
    }

    private func hasVisibleMarks(_ context: CGContext) -> Bool {
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        for y in 0..<context.height {
            for x in 0..<context.width {
                let offset = y * context.bytesPerRow + x * 4
                if bytes[offset] < 245 || bytes[offset + 1] < 245 || bytes[offset + 2] < 245 { return true }
            }
        }
        return false
    }

    private func containsImages(_ page: PDFPage) -> Bool {
        guard let reference = page.pageRef else { return false }
        var dictionary: CGPDFDictionaryRef? = reference.dictionary
        for _ in 0..<16 {
            guard let current = dictionary else { break }
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources), let resources {
                return containsImages(in: resources, depth: 0)
            }
            var parent: CGPDFDictionaryRef?
            CGPDFDictionaryGetDictionary(current, "Parent", &parent)
            dictionary = parent
        }
        return false
    }

    private func containsImages(in resources: CGPDFDictionaryRef, depth: Int) -> Bool {
        guard depth < 16 else { return false }
        var objects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return false }
        var found = false
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream) else { return true }
            var name: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &name), let name else { return true }
            if String(cString: name) == "Image" { found = true; return false }
            if String(cString: name) == "Form" {
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    found = self.containsImages(in: nested, depth: depth + 1)
                }
            }
            return !found
        }, nil)
        return found
    }
}
