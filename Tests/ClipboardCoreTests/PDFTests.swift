import AppKit
import CoreText
import PDFKit
import Testing
@testable import ClipboardCore

@Suite @MainActor
struct PDFTests {
    private let scannedText = "Scanned middle page\nThese words are pixels rather than embedded PDF text.\nThe extracted pages should stay in their original order."

    @Test func embeddedPDFTextTakesPriorityAndUndoRestoresAllRepresentations() async throws {
        let data = try pdf([.text("First PDF page\nEmbedded text should be extracted directly.")])
        let item = NSPasteboardItem()
        item.setData(data, forType: .pdf)
        item.setString("An incomplete alternative", forType: .string)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: noOCR)
        let result = try await converter.convert(to: .plainText)
        #expect(result.contains("First PDF page"))
        #expect(result.contains("Embedded text should be extracted directly."))
        #expect(!result.contains("incomplete alternative"))
        #expect(board.data(forType: .pdf) == nil)
        try converter.undo()
        #expect(board.data(forType: .pdf) == data)
        #expect(board.string(forType: .string) == "An incomplete alternative")
    }

    @Test func markdownPreservesNativeEmphasisAndLinks() async throws {
        let document = try #require(PDFDocument(data: pdf([.text("Bold title\nItalic body\nVisit example")], styled: true)))
        let page = try #require(document.page(at: 0))
        let link = PDFAnnotation(bounds: CGRect(x: 35, y: 619, width: 500, height: 23), forType: .link, withProperties: nil)
        link.url = URL(string: "https://example.com")!
        page.addAnnotation(link)
        let data = try #require(document.dataRepresentation())
        let result = try await PDFRenderer().render(data, format: .markdown, ocr: noOCR())
        #expect(result.contains("**Bold title**"))
        #expect(result.contains("*Italic body*"))
        #expect(result.contains("https://example.com"))
    }

    @Test func mixedNativeAndScannedPagesUseRealOCRInOrder() async throws {
        let data = try pdf([.text("Native first page"), .scan(scannedText), .text("Native last page")])
        let original = try #require(PDFDocument(data: data))
        #expect(original.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false)
        let result = try await PDFRenderer().render(data, format: .plainText, ocr: ImageOCR())
        let first = try #require(result.range(of: "Native first page"))
        let scanned = try #require(result.range(of: "Scanned middle page"))
        let last = try #require(result.range(of: "Native last page"))
        #expect(first.lowerBound < scanned.lowerBound && scanned.upperBound < last.lowerBound)
        #expect(result.contains("pixels rather than embedded PDF text"))
        if let path = ProcessInfo.processInfo.environment["PLAINTEXTER_PDF_QA_DIR"] {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: folder.appendingPathComponent("mixed.pdf"))
            let reader = PDFPageReader()
            _ = try await reader.open(data)
            let content = try await reader.readPage(1, includeFormatting: false)
            try content.image?.write(to: folder.appendingPathComponent("ocr-input.png"))
        }
    }

    @Test func scannedPageWithDigitalFooterStillUsesOCR() async throws {
        let data = try pdf([.scanWithFooter(scannedText)])
        let document = try #require(PDFDocument(data: data))
        #expect(document.page(at: 0)?.string?.contains("17") == true)
        let result = try await PDFRenderer().render(data, format: .plainText, ocr: ImageOCR())
        #expect(result.contains("Scanned middle page"))
        #expect(result.contains("17"))
    }

    @Test func shortScannedTextIsRetainedAndMarkdownEscaped() async throws {
        let data = try pdf([.scan("PAID")])
        let result = try await PDFRenderer().render(data, format: .plainText, ocr: ImageOCR())
        #expect(result == "PAID")
        let markdown = try await PDFRenderer().render(data, format: .markdown, ocr: ImageOCR(recognize: { _ in "# PAID [invoice]" }))
        #expect(markdown == "\\# PAID \\[invoice\\]")
    }

    @Test func longDigitalFilingStampDoesNotHideScannedPageText() async throws {
        let data = try pdf([.scanWithStamp(scannedText)])
        let document = try #require(PDFDocument(data: data))
        #expect((document.page(at: 0)?.string?.count ?? 0) > 40)
        let result = try await PDFRenderer().render(data, format: .plainText, ocr: ImageOCR())
        #expect(result.contains("Scanned middle page"))
        #expect(result.contains("Electronic filing reference"))
    }

    @Test func ordinaryImageThresholdStillAppliesWhenCacheIsShared() async throws {
        let ocr = ImageOCR(recognize: { _ in "PAID" })
        #expect(await ocr.text(in: Data([1, 2])) == nil)
        #expect(await ocr.text(in: Data([1, 2]), minimumCharacters: 1) == "PAID")
        #expect(await ocr.text(in: Data([1, 2])) == nil)
    }

    @Test func copiedPDFFilesAndMultipleItemsBecomeTheirContents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let items = try ["First file", "Second file"].enumerated().map { index, text in
            let url = folder.appendingPathComponent("document-\(index).PDF")
            try pdf([.text(text)]).write(to: url)
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        let board = pasteboard(items)
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: noOCR)
        #expect(try await converter.convert(to: .plainText) == "First file\nSecond file")
        try converter.undo()
        #expect(board.pasteboardItems?.count == 2)
        #expect(try await converter.convert(to: .markdown).contains("Second file"))
    }

    @Test func nativePDFAttachmentIsConvertedAlongsideSurroundingText() async throws {
        let wrapper = FileWrapper(regularFileWithContents: try pdf([.text("Text inside PDF attachment")]))
        wrapper.preferredFilename = "attachment.pdf"
        let text = NSMutableAttributedString(string: "Before ")
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        text.append(NSAttributedString(string: " After"))
        let result = try await RichTextRenderer().render(text, format: .plainText, ocr: noOCR())
        #expect(result.contains("Before"))
        #expect(result.contains("Text inside PDF attachment"))
        #expect(result.hasSuffix("After"))
    }

    @Test func blankPagesAreSkippedButUnreadableScansAreMarked() async throws {
        let data = try pdf([.text("Readable first page"), .blank, .scan("unreadable"), .text("Readable last page")])
        let result = try await PDFRenderer().render(data, format: .plainText, ocr: ImageOCR(recognize: { _ in nil }))
        #expect(!result.contains("page 2"))
        #expect(result.contains("[No readable text found on PDF page 3.]"))
        #expect(result.contains("Readable last page"))
    }

    @Test func invalidAndLockedPDFsLeaveClipboardUnchanged() async throws {
        let document = try #require(PDFDocument(data: pdf([.text("Locked contents")])) )
        let locked = try #require(document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "test-password", PDFDocumentWriteOption.ownerPasswordOption: "test-owner"]))
        for data in [Data("%PDF-invalid".utf8), locked] {
            let item = NSPasteboardItem()
            item.setData(data, forType: .pdf)
            let board = pasteboard([item])
            defer { board.releaseGlobally() }
            let count = board.changeCount
            let converter = ClipboardConverter(pasteboard: board, makeOCR: { ImageOCR(recognize: { _ in nil }) })
            await #expect(throws: PDFConversionError.self) { try await converter.convert(to: .plainText) }
            #expect(board.changeCount == count)
            #expect(board.data(forType: .pdf) == data)
        }
    }

    @Test func blankAndUnreadablePDFsWriteMessageAndSupportUndo() async throws {
        for data in [try pdf([.blank]), try pdf([.scan("Unreadable")])] {
            let item = NSPasteboardItem()
            item.setData(data, forType: .pdf)
            let board = pasteboard([item])
            defer { board.releaseGlobally() }
            let converter = ClipboardConverter(pasteboard: board, makeOCR: { ImageOCR(recognize: { _ in nil }) })
            for format in [TextFormat.plainText, .markdown] {
                #expect(try await converter.convert(to: format) == "No text found to OCR.")
                #expect(board.string(forType: .string) == "No text found to OCR.")
                #expect(board.data(forType: .pdf) == nil)
                try converter.undo()
                #expect(board.data(forType: .pdf) == data)
            }
        }
    }

    @Test func rotatedCropBoxControlsOCRImageDimensions() async throws {
        let document = try #require(PDFDocument(data: pdf([.scan(scannedText)])))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 10, y: 20, width: 500, height: 700), for: .cropBox)
        page.rotation = 90
        let reader = PDFPageReader()
        _ = try await reader.open(try #require(document.dataRepresentation()))
        let content = try await reader.readPage(0, includeFormatting: false)
        let image = try #require(content.image)
        let bitmap = try #require(NSBitmapImageRep(data: image))
        #expect(bitmap.pixelsWide == 2100)
        #expect(bitmap.pixelsHigh == 1500)
    }

    @Test func rasterizedPageFillsTheCanvasAtOCRResolution() async throws {
        let reader = PDFPageReader()
        _ = try await reader.open(try pdf([.scan(scannedText)]))
        let page = try await reader.readPage(0, includeFormatting: false)
        let image = try #require(page.image)
        let bitmap = try #require(NSBitmapImageRep(data: image))
        // The source text starts near the upper-left corner, not in the center of the bitmap.
        var hasInkNearTopLeft = false
        for y in stride(from: 0, to: bitmap.pixelsHigh / 3, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide / 5, by: 4) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.redComponent < 0.5 {
                    hasInkNearTopLeft = true
                    break
                }
            }
            if hasInkNearTopLeft { break }
        }
        #expect(hasInkNearTopLeft)
    }

    @Test func newerClipboardSurvivesWhileScannedPDFIsProcessing() async throws {
        let gate = PDFOCRGate()
        let item = NSPasteboardItem()
        item.setData(try pdf([.scan(scannedText)]), forType: .pdf)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, makeOCR: { ImageOCR(recognize: { _ in await gate.pause(); return "Scanned text" }) })
        let task = Task { try await converter.convert(to: .plainText) }
        await gate.waitUntilStarted()
        board.clearContents()
        board.setString("New clipboard contents", forType: .string)
        await gate.resume()
        await #expect(throws: ConversionError.self) { try await task.value }
        #expect(board.string(forType: .string) == "New clipboard contents")
    }

    private func noOCR() -> ImageOCR {
        ImageOCR(recognize: { _ in Issue.record("Native PDF text should not require OCR"); return nil })
    }

    private func pasteboard(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.writeObjects(items)
        return board
    }

    private enum Page { case text(String), scan(String), scanWithFooter(String), scanWithStamp(String), blank }

    private func pdf(_ pages: [Page], styled: Bool = false) throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text): draw(text, to: context, styled: styled)
            case .scan(let text), .scanWithFooter(let text), .scanWithStamp(let text):
                let bitmap = try #require(CGContext(data: nil, width: 1224, height: 1584, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 1224, height: 1584))
                bitmap.scaleBy(x: 2, y: 2)
                draw(text, to: bitmap)
                context.draw(try #require(bitmap.makeImage()), in: box)
                if case .scanWithFooter = page { draw("17", to: context, origin: CGPoint(x: 300, y: 20)) }
                if case .scanWithStamp = page {
                    draw("Electronic filing reference number 1234567890\nFiled September 11, 2026. Document 17, page 1 of 3.", to: context, origin: CGPoint(x: 40, y: 90))
                }
            case .blank: break
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func draw(_ text: String, to context: CGContext, styled: Bool = false, origin: CGPoint = CGPoint(x: 40, y: 700)) {
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let name = styled ? (index == 0 ? "Helvetica-Bold" : index == 1 ? "Helvetica-Oblique" : "Helvetica") : "Helvetica"
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                           NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)])
            context.textPosition = CGPoint(x: origin.x, y: origin.y - CGFloat(index * 36))
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
    }
}

private actor PDFOCRGate {
    private var started = false
    private var observer: CheckedContinuation<Void, Never>?
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        started = true
        observer?.resume(); observer = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { observer = $0 } }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
