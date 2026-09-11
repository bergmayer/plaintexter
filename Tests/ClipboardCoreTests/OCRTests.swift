import AppKit
import Testing
@testable import ClipboardCore

@Suite @MainActor
struct OCRTests {
    nonisolated static let recognized = "Clipboard image recognition\nThis is a screenshot with several lines of readable text.\nAll recognition happens locally on this computer."

    private func stubOCR() -> ImageOCR {
        ImageOCR(recognize: { _ in Self.recognized }, load: { _ in nil })
    }

    @Test func visionReadsActualPixels() async throws {
        let data = try textImage()
        let result = try #require(await ImageOCR().text(in: data))
        #expect(result.contains("Clipboard image recognition"))
        #expect(result.contains("several lines of readable text"))
        #expect(result.contains("locally on this computer"))
    }

    @Test func realImageClipboardUsesOCRAndUndoPreservesPixels() async throws {
        let data = try textImage()
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        // Some applications supply alt text as well; it must not prevent OCR of actual image content.
        item.setString("Screenshot", forType: .string)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board)
        let result = try await converter.convert(to: .plainText)
        #expect(result.contains("Clipboard image recognition"))
        #expect(!result.hasPrefix("/"))
        #expect(board.data(forType: .png) == nil)
        try converter.undo()
        #expect(board.data(forType: .png) == data)
        #expect(board.string(forType: .string) == "Screenshot")
    }

    @Test func shortCaptionAndBlankImageDoNotCountAsSubstantialText() async throws {
        #expect(await ImageOCR().text(in: try textImage(lines: ["A short caption"])) == nil)
        #expect(await ImageOCR().text(in: try textImage(lines: [])) == nil)
        #expect(ImageOCR.substantialText("Logo 123") == nil)
        #expect(ImageOCR.substantialText(String(repeating: "漢", count: 40)) != nil)
    }

    @Test func noTextMessageOverridesImageAltTextAndURLWithoutSaving() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = try textImage(lines: [])
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType("public.jpeg")] {
            let item = NSPasteboardItem()
            item.setData(data, forType: type)
            item.setString("Screenshot", forType: .string)
            item.setString("https://example.com/photo.png", forType: .URL)
            let board = pasteboard([item])
            defer { board.releaseGlobally() }
            let converter = ClipboardConverter(pasteboard: board, assets: AssetStore(directory: folder), makeOCR: { ImageOCR(recognize: { _ in nil }) })
            for format in [TextFormat.plainText, .markdown] {
                #expect(try await converter.convert(to: format) == "No text found to OCR.")
                #expect(board.string(forType: .string) == "No text found to OCR.")
                #expect(board.data(forType: type) == nil)
                try converter.undo()
                #expect(board.data(forType: type) == data)
                #expect(board.string(forType: .string) == "Screenshot")
            }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func embeddedHTMLFailureKeepsTextAndDoesNotSaveImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = "<img src='data:image/png;base64,\(try textImage(lines: []).base64EncodedString())' alt='Screenshot'>"
        for html in [image, "<p>Before</p>" + image + "<p><b>After</b></p>"] {
            let item = NSPasteboardItem()
            item.setString(html, forType: .html)
            item.setString("Alternate clipboard text", forType: .string)
            let board = pasteboard([item])
            defer { board.releaseGlobally() }
            let converter = ClipboardConverter(pasteboard: board, assets: AssetStore(directory: folder), makeOCR: { ImageOCR(recognize: { _ in nil }) })
            for format in [TextFormat.plainText, .markdown] {
                let expected = html == image ? "No text found to OCR." : "Before\n\nNo text found to OCR.\n\n" + (format == .markdown ? "**After**" : "After")
                #expect(try await converter.convert(to: format) == expected)
                try converter.undo()
                #expect(board.string(forType: .html) == html)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func unreadableNativeImageAttachmentWritesMessageWithoutSaving() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrapper = FileWrapper(regularFileWithContents: try textImage(lines: []))
        wrapper.preferredFilename = "screenshot.png"
        let text = NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper))
        let data = try #require(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let item = NSPasteboardItem()
        item.setData(data, forType: .rtfd)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, assets: AssetStore(directory: folder), makeOCR: { ImageOCR(recognize: { _ in nil }) })
        for format in [TextFormat.plainText, .markdown] {
            #expect(try await converter.convert(to: format) == "No text found to OCR.")
            try converter.undo()
            #expect(board.data(forType: .rtfd) == data)
        }
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func newerClipboardSurvivesAnEmptyOCRResult() async throws {
        let gate = OCRGate()
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: {
            ImageOCR(recognize: { _ in await gate.wait(); return nil })
        })
        let task = Task { try await converter.convert(to: .plainText) }
        await gate.waitUntilStarted()
        board.clearContents()
        board.setString("A newer copy", forType: .string)
        await gate.release()
        do { _ = try await task.value; Issue.record("An empty OCR result should not overwrite a newer copy") }
        catch { #expect(error as? ConversionError == .changed) }
        #expect(board.string(forType: .string) == "A newer copy")
        #expect(!converter.canUndo)
    }

    @Test func embeddedHTMLImageKeepsSurroundingTextInBothFormats() async throws {
        let item = NSPasteboardItem()
        item.setString("<p>Before</p><img src='data:image/png;base64,AQID' alt='Screenshot'><p><b>After</b></p>", forType: .html)
        item.setString("Before\nAfter", forType: .string)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: stubOCR)
        let plain = try await converter.convert(to: .plainText)
        #expect(plain == "Before\n\n" + Self.recognized + "\n\nAfter")
        try converter.undo()
        let markdown = try await converter.convert(to: .markdown)
        #expect(markdown.hasPrefix("Before\n\nClipboard image recognition"))
        #expect(markdown.hasSuffix("\n\n**After**"))
        #expect(!markdown.contains("!["))
    }

    @Test func nativeImageAttachmentTakesPriorityOverHTMLAndPlainText() async throws {
        let wrapper = FileWrapper(regularFileWithContents: try textImage())
        wrapper.preferredFilename = "screenshot.png"
        let text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        text.append(NSAttributedString(string: " After"))
        let data = try #require(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let item = NSPasteboardItem()
        item.setData(data, forType: .rtfd)
        item.setString("Before After", forType: .string)
        item.setString("<p>Before <img src='missing.png'> After</p>", forType: .html)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: stubOCR)
        let plain = try await converter.convert(to: .plainText)
        #expect(plain.contains(Self.recognized))
        #expect(plain.hasPrefix("Before"))
        #expect(plain.hasSuffix("After"))
        try converter.undo()
        let markdown = try await converter.convert(to: .markdown)
        #expect(markdown.contains("Clipboard image recognition"))
        #expect(!markdown.contains("![screenshot.png]"))
    }

    @Test func copiedImageFileAndMultipleClipboardItems() async throws {
        let text = NSPasteboardItem()
        text.setString("Introduction", forType: .string)
        let image = NSPasteboardItem()
        image.setString("file:///tmp/screenshot.png", forType: .fileURL)
        let board = pasteboard([text, image])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: {
            ImageOCR(recognize: { _ in Self.recognized }, load: { _ in Data([1, 2, 3]) })
        })
        #expect(try await converter.convert(to: .plainText) == "Introduction\n" + Self.recognized)
    }

    @Test func ocrTextEscapesMarkdownWithoutInventingFormatting() async throws {
        let text = "# This is literal text in an image, with [brackets] and *asterisks*.\n1. A literal numbered line."
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: { ImageOCR(recognize: { _ in text }) })
        let result = try await converter.convert(to: .markdown)
        #expect(result.hasPrefix("\\# This is literal"))
        #expect(result.contains("\\[brackets\\] and \\*asterisks\\*"))
        #expect(result.contains("  \n1\\. A literal numbered line."))
    }

    @Test func clipboardChangeDuringOCRIsNeverOverwritten() async throws {
        let gate = OCRGate()
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: {
            ImageOCR(recognize: { _ in await gate.wait(); return Self.recognized })
        })
        let task = Task { try await converter.convert(to: .plainText) }
        await gate.waitUntilStarted()
        board.clearContents()
        board.setString("Something copied during OCR", forType: .string)
        await gate.release()
        do {
            _ = try await task.value
            Issue.record("A stale conversion should not succeed")
        } catch { #expect(error as? ConversionError == .changed) }
        #expect(board.string(forType: .string) == "Something copied during OCR")
        #expect(!converter.canUndo)
    }

    @Test func cancellationAndConcurrentClicksDoNotReplaceClipboard() async throws {
        let gate = OCRGate()
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: .png)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: {
            ImageOCR(recognize: { _ in await gate.wait(); return Self.recognized })
        })
        let task = Task { try await converter.convert(to: .plainText) }
        await gate.waitUntilStarted()
        do {
            _ = try await converter.convert(to: .markdown)
            Issue.record("Concurrent conversion should be rejected")
        } catch { #expect(error as? ConversionError == .busy) }
        task.cancel()
        await gate.release()
        do { _ = try await task.value; Issue.record("Cancelled conversion should not succeed") }
        catch { #expect(error is CancellationError) }
        #expect(board.data(forType: .png) == Data([1, 2, 3]))
    }

    @Test func remoteImageUsesClipboardPixelsBeforeNetwork() async throws {
        let renderer = HTMLRenderer(format: .plainText)
        let ocr = ImageOCR(recognize: { _ in Self.recognized }, load: { _ in Issue.record("Image pixels were already on the clipboard"); return nil })
        let result = try await renderer.render(Data("<img src='https://example.com/screenshot.png'>".utf8), ocr: ocr, clipboardImage: Data([1, 2, 3]))
        #expect(result == Self.recognized)
    }

    @Test func remoteImageCanBeLoadedAndFailureBecomesMessage() async throws {
        let html = Data("<p>Before</p><img src='https://example.com/screenshot.png'><p>After</p>".utf8)
        let ocr = ImageOCR(recognize: { _ in Self.recognized }, load: { _ in Data([1, 2, 3]) })
        let result = try await HTMLRenderer(format: .plainText).render(html, ocr: ocr)
        #expect(result.contains(Self.recognized))
        let failed = try await HTMLRenderer(format: .markdown).render(html, ocr: ImageOCR(load: { _ in nil }))
        #expect(failed == "Before\n\nNo text found to OCR.\n\nAfter")
    }

    @Test func shortTextInClipboardImageDoesNotCauseRedundantDownload() async throws {
        let ocr = ImageOCR(recognize: { _ in "Short caption" }, load: { _ in Issue.record("Image pixels were already available"); return nil })
        let result = try await HTMLRenderer(format: .markdown).render(Data("<img src='https://example.com/photo.png'>".utf8), ocr: ocr, clipboardImage: Data([1, 2, 3]))
        #expect(result == "No text found to OCR.")
    }

    @Test func hiddenImagesAreNotFetched() async throws {
        let ocr = ImageOCR(load: { _ in Issue.record("Hidden images must not be fetched"); return nil })
        let result = try await HTMLRenderer(format: .plainText).render(Data("<p>Visible</p><div hidden><img src='https://example.com/hidden.png'></div>".utf8), ocr: ocr)
        #expect(result == "Visible")
    }

    private func pasteboard(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.writeObjects(items)
        return board
    }

    private func textImage(lines: [String] = recognized.components(separatedBy: "\n")) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1500, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1500, height: 360).fill()
        for (index, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.black])
                .draw(at: NSPoint(x: 40, y: 270 - index * 85))
        }
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}

private actor OCRGate {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        observer?.resume()
        observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { observer = $0 } }
    }
    func release() { continuation?.resume(); continuation = nil }
}
