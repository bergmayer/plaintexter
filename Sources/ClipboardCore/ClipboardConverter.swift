import AppKit
import UniformTypeIdentifiers

public enum ConversionError: LocalizedError {
    case empty, unsupported, changed, writeFailed, nothingToUndo, busy

    public var errorDescription: String? {
        switch self {
        case .empty: "The clipboard is empty or clipboard access was denied."
        case .unsupported: "This clipboard content cannot be converted to text. It has been left unchanged."
        case .changed: "The clipboard changed during conversion. Try again."
        case .writeFailed: "The converted text could not be written to the clipboard."
        case .nothingToUndo: "There is no conversion to undo for the current clipboard."
        case .busy: "A clipboard conversion is already running."
        }
    }
}

@MainActor
public final class ClipboardConverter {
    private let pasteboard: NSPasteboard
    private let assets: AssetStore
    private var previous: [[NSPasteboard.PasteboardType: Data]]?
    private var convertedChangeCount: Int?
    private var isConverting = false
    private let makeOCR: @MainActor () -> ImageOCR

    public init(pasteboard: NSPasteboard = .general, assets: AssetStore = AssetStore(), makeOCR: @escaping @MainActor () -> ImageOCR = { ImageOCR() }) {
        self.pasteboard = pasteboard
        self.assets = assets
        self.makeOCR = makeOCR
    }

    public var canUndo: Bool { !isConverting && previous != nil && convertedChangeCount == pasteboard.changeCount }

    @discardableResult
    public func convert(to format: TextFormat) async throws -> String {
        guard !isConverting else { throw ConversionError.busy }
        isConverting = true
        defer { isConverting = false }
        let initialChangeCount = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { throw ConversionError.empty }
        // Capture every available representation before replacing anything; undo remains in memory only.
        let snapshot = items.map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { representations[type] = data } }
            return representations
        }
        // Work from immutable data after suspension, even if the user copies again during OCR.
        let frozenItems = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        let ocr = makeOCR()
        var outputs: [String] = []
        for item in frozenItems {
            try Task.checkCancellation()
            guard pasteboard.changeCount == initialChangeCount else { throw ConversionError.changed }
            guard let output = try await convert(item, to: format, ocr: ocr) else { throw ConversionError.unsupported }
            outputs.append(output)
        }
        let output = outputs.joined(separator: "\n")
        try Task.checkCancellation()
        guard pasteboard.changeCount == initialChangeCount else { throw ConversionError.changed }
        pasteboard.clearContents()
        guard pasteboard.setString(output, forType: .string) else {
            restore(snapshot)
            throw ConversionError.writeFailed
        }
        previous = snapshot
        convertedChangeCount = pasteboard.changeCount
        return output
    }

    public func undo() throws {
        guard canUndo, let previous else { throw ConversionError.nothingToUndo }
        guard restore(previous) else { throw ConversionError.writeFailed }
        self.previous = nil
        convertedChangeCount = nil
    }

    @discardableResult
    private func restore(_ snapshot: [[NSPasteboard.PasteboardType: Data]]) -> Bool {
        let items = snapshot.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        pasteboard.clearContents()
        return pasteboard.writeObjects(items)
    }

    private func convert(_ item: NSPasteboardItem, to format: TextFormat, ocr: ImageOCR) async throws -> String? {
        if let data = item.data(forType: .pdf) {
            return try await PDFRenderer().render(data, format: format, ocr: ocr)
        }
        if let raw = item.string(forType: .fileURL), let url = URL(string: raw), url.isFileURL {
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
                return try await PDFRenderer().render(file: url, format: format, ocr: ocr)
            }
            if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                let text = await ocr.text(at: url.absoluteString)
                return ImageOCR.formatted(text ?? ImageOCR.noTextMessage, as: format)
            }
            return reference(url, format: format)
        }
        let imageData = ([NSPasteboard.PasteboardType.png, .tiff] + item.types.filter { UTType($0.rawValue)?.conforms(to: .image) == true })
            .lazy.compactMap { item.data(forType: $0) }.first
        let plainText = item.string(forType: .string)
        let usablePlainText = plainText.flatMap { !$0.isEmpty && !$0.contains("\u{FFFC}") ? $0 : nil }
        var richTexts: [NSAttributedString] = []
        for (type, documentType) in [(NSPasteboard.PasteboardType.rtfd, NSAttributedString.DocumentType.rtfd), (.rtf, .rtf)] {
            if let data = item.data(forType: type), let attributed = try? NSAttributedString(data: data, options: [.documentType: documentType], documentAttributes: nil), attributed.length > 0 {
                richTexts.append(attributed)
            }
        }
        // Native attachments carry actual pixels even when an HTML alternative has only broken image URLs.
        if let rich = richTexts.first(where: Self.hasAttachments) {
            return try await RichTextRenderer(assets: assets).render(rich, format: format, ocr: ocr)
        }
        if let html = item.data(forType: .html) {
            let renderer = HTMLRenderer(format: format, assets: assets)
            if let rendered = try? await renderer.render(html, baseURL: item.string(forType: .URL).flatMap(URL.init(string:)), ocr: ocr, clipboardImage: imageData), !rendered.isEmpty {
                if format == .plainText, !renderer.didProcessImages, let usablePlainText { return usablePlainText }
                return rendered
            }
        }
        if let rich = richTexts.first {
            if format == .plainText, let usablePlainText { return usablePlainText }
            return try await RichTextRenderer(assets: assets).render(rich, format: format, ocr: ocr)
        }
        if let imageData {
            let text = await ocr.text(in: imageData)
            return ImageOCR.formatted(text ?? ImageOCR.noTextMessage, as: format)
        }
        if let raw = item.string(forType: .URL), let url = URL(string: raw) {
            if format == .plainText { return url.absoluteString }
            let title = item.string(forType: NSPasteboard.PasteboardType("public.url-name")) ?? url.absoluteString
            return Markdown.link(label: title, destination: url.absoluteString)
        }
        if let usablePlainText { return usablePlainText }
        if let text = item.string(forType: .string), text.isEmpty { return text }
        return nil
    }

    private static func hasAttachments(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, stop in
            if value is NSTextAttachment { found = true; stop.pointee = true }
        }
        return found
    }

    private func reference(_ url: URL, format: TextFormat) -> String {
        if format == .plainText { return url.path }
        let image = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        return Markdown.link(label: url.lastPathComponent, destination: url.absoluteString, image: image)
    }
}
