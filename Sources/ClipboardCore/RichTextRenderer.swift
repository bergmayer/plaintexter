import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
public final class RichTextRenderer {
    private let assets: AssetStore
    private var imageText: [ObjectIdentifier: String] = [:]
    private var pdfText: [ObjectIdentifier: String] = [:]
    public private(set) var didRecognizeImageText = false

    public init(assets: AssetStore = AssetStore()) { self.assets = assets }

    public func render(_ text: NSAttributedString, format: TextFormat, ocr: ImageOCR? = nil) async throws -> String {
        imageText.removeAll()
        pdfText.removeAll()
        didRecognizeImageText = false
        if let ocr {
            var attachments: [NSTextAttachment] = []
            text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment { attachments.append(attachment) }
            }
            for attachment in attachments {
                let wrapper = attachment.fileWrapper
                let data = wrapper?.isRegularFile == true ? wrapper?.regularFileContents : attachment.image?.tiffRepresentation ?? attachment.contents
                if let data, PDFRenderer.isPDF(data) {
                    pdfText[ObjectIdentifier(attachment)] = try await PDFRenderer().render(data, format: format, ocr: ocr)
                } else if isImage(attachment, data: data) {
                    let recognized: String?
                    if let data { recognized = await ocr.text(in: data) }
                    else { recognized = nil }
                    imageText[ObjectIdentifier(attachment)] = recognized ?? ImageOCR.noTextMessage
                    if recognized != nil { didRecognizeImageText = true }
                }
            }
        }
        if format == .plainText { return try inline(text, format: format) }
        let string = text.string as NSString
        var offset = 0
        var paragraphs: [String] = []
        var listCounts: [ObjectIdentifier: Int] = [:]
        while offset < string.length {
            let range = string.paragraphRange(for: NSRange(location: offset, length: 0))
            var contentRange = range
            while contentRange.length > 0, let scalar = UnicodeScalar(string.character(at: NSMaxRange(contentRange) - 1)), CharacterSet.newlines.contains(scalar) { contentRange.length -= 1 }
            let paragraph = text.attributedSubstring(from: contentRange)
            let style = text.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
            var content = try inline(paragraph, format: format)
            if let list = style?.textLists.last {
                let id = ObjectIdentifier(list)
                let number = listCounts[id] ?? list.startingItemNumber
                listCounts[id] = number + 1
                // Cocoa list text includes a literal tab, marker, and tab before the content.
                content = content.replacingOccurrences(of: #"^\t[^\t]*\t"#, with: "", options: .regularExpression)
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha") || list.markerFormat.rawValue.contains("roman")
                let indent = String(repeating: "    ", count: max(0, (style?.textLists.count ?? 1) - 1))
                content = indent + (ordered ? "\(number). " : "- ") + content
            } else if let level = style?.headerLevel, (1...6).contains(level) {
                content = String(repeating: "#", count: level) + " " + content
            }
            paragraphs.append(content)
            offset = NSMaxRange(range)
        }
        // Retain paragraph boundaries, including blank paragraphs in the source.
        return paragraphs.joined(separator: "\n\n")
    }

    private struct Style: Equatable {
        var bold = false
        var italic = false
        var strike = false
        var code = false
        var link: String?
    }

    private func inline(_ text: NSAttributedString, format: TextFormat) throws -> String {
        var output = ""
        var pending = ""
        var pendingStyle = Style()
        func flush() {
            guard !pending.isEmpty else { return }
            var rendered = pending
            if format == .markdown {
                rendered = pendingStyle.code ? Markdown.code(pending) : Markdown.escape(pending)
                if pendingStyle.bold { rendered = Markdown.wrap(rendered, with: "**") }
                if pendingStyle.italic { rendered = Markdown.wrap(rendered, with: "*") }
                if pendingStyle.strike { rendered = Markdown.wrap(rendered, with: "~~") }
                if let link = pendingStyle.link { rendered = "[\(rendered)](<\(Markdown.destination(link))>)" }
            }
            output += rendered
            pending = ""
        }
        var failure: Error?
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, stop in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                flush()
                do { output += try attachmentText(attachment, format: format) }
                catch { failure = error; stop.pointee = true }
                return
            }
            var style = Style()
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                style.bold = traits.contains(.boldFontMask)
                style.italic = traits.contains(.italicFontMask)
                style.code = traits.contains(.fixedPitchFontMask)
            }
            style.strike = ((attributes[.strikethroughStyle] as? NSNumber)?.intValue ?? 0) != 0
            if let url = attributes[.link] as? URL { style.link = url.absoluteString }
            else if let url = attributes[.link] as? String { style.link = url }
            if style != pendingStyle { flush(); pendingStyle = style }
            pending += text.attributedSubstring(from: range).string
        }
        flush()
        if let failure { throw failure }
        return output
    }

    private func attachmentText(_ attachment: NSTextAttachment, format: TextFormat) throws -> String {
        if let text = pdfText[ObjectIdentifier(attachment)] {
            return text == ImageOCR.noTextMessage ? text : "\n\n" + text + "\n\n"
        }
        if let text = imageText[ObjectIdentifier(attachment)] {
            if text == ImageOCR.noTextMessage { return text }
            return "\n\n" + ImageOCR.formatted(text, as: format) + "\n\n"
        }
        guard let wrapper = attachment.fileWrapper, wrapper.isRegularFile, let data = wrapper.regularFileContents else {
            if let data = attachment.image?.tiffRepresentation ?? attachment.contents, let url = try assets.saveImage(data) {
                return format == .plainText ? url.path : Markdown.link(label: "Image", destination: url.absoluteString, image: true)
            }
            return attachment.fileWrapper?.preferredFilename ?? "[Attachment]"
        }
        let name = wrapper.preferredFilename ?? wrapper.filename ?? "Attachment"
        let ext = URL(fileURLWithPath: name).pathExtension
        let url = try assets.save(data, extension: ext.isEmpty ? "dat" : ext, name: name)
        if format == .plainText { return url.path }
        let isImage = NSBitmapImageRep(data: data) != nil
        return Markdown.link(label: name, destination: url.absoluteString, image: isImage)
    }

    private func isImage(_ attachment: NSTextAttachment, data: Data?) -> Bool {
        if let name = attachment.fileWrapper?.preferredFilename ?? attachment.fileWrapper?.filename,
           UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension)?.conforms(to: .image) == true { return true }
        if let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
           CGImageSourceGetType(source) != nil { return true }
        // AppKit supplies a display icon for ordinary file attachments too.
        if attachment.fileWrapper?.isRegularFile == true { return false }
        if let type = attachment.fileType, UTType(type)?.conforms(to: .image) == true { return true }
        return attachment.image != nil
    }
}
