import AppKit
import Testing
@testable import ClipboardCore

@Suite @MainActor
struct ConversionTests {
    private func html(_ input: String, _ format: TextFormat = .markdown) async throws -> String {
        try await HTMLRenderer(format: format).render(Data(input.utf8))
    }

    @Test func htmlStructureAndStyles() async throws {
        let result = try await html("<h2>Title</h2><p>Hello <strong>bold</strong> and <em>italic</em>.</p><p><a href='https://example.com/a?q=1&amp;b=2'>A link</a></p>")
        #expect(result == "## Title\n\nHello **bold** and *italic*.\n\n[A link](<https://example.com/a?q=1&b=2>)")
    }

    @Test func inlineCSSFromOfficeAndGoogleDocs() async throws {
        let result = try await html("<b style='font-weight:normal'><span style='font-weight:700'>Bold</span> <span style='font-style:italic'>italic</span></b>")
        #expect(result.contains("**Bold**"))
        #expect(result.contains("*italic*"))
        #expect(!result.hasPrefix("****"))
    }

    @Test func listsAndQuotes() async throws {
        let result = try await html("<ol start='3'><li>Three</li><li>Four<ul><li>Nested</li></ul></li></ol><blockquote><p>A quote</p></blockquote>")
        #expect(result.contains("3. Three\n4. Four"))
        #expect(result.contains("   - Nested"))
        #expect(result.contains("> A quote"))
    }

    @Test func codePreservesWhitespaceAndChoosesFence() async throws {
        let result = try await html("<pre>a\n\n\n```\n  b</pre><p><code>a`b</code></p>")
        #expect(result.contains("````\na\n\n\n```\n  b\n````"))
        #expect(result.contains("``a`b``"))
    }

    @Test func lineBreaks() async throws {
        #expect(try await html("<p>One<br>Two</p>") == "One  \nTwo")
    }

    @Test func malformedHTMLAndEntities() async throws {
        let result = try await html("<p>Café &amp; tea<p>猫&nbsp;dog")
        #expect(result == "Café & tea\n\n猫 dog")
    }

    @Test func hiddenAndExecutableContentExcluded() async throws {
        let result = try await html("<script>alert('x')</script><style>b {color:red}</style><p>Visible<span hidden>Secret</span><span style='display:none'>Hidden</span></p>")
        #expect(result == "Visible")
    }

    @Test func tablePreservesRowsAndEscapesPipes() async throws {
        #expect(try await html("<table><tr><th>A</th><th>B</th></tr><tr><td>x|y</td><td><b>z</b></td></tr></table>") == "| A | B |\n| --- | --- |\n| x\\|y | **z** |")
    }

    @Test func imageAndRelativeLink() async throws {
        let renderer = HTMLRenderer(format: .markdown)
        let result = try await renderer.render(Data("<p><img src='/image.png' alt='A photo'></p>".utf8), baseURL: URL(string: "https://example.com/page"))
        #expect(result == "![A photo](<https://example.com/image.png>)")
        #expect(try await html("<img src='https://example.com/a.png'>", .plainText) == "https://example.com/a.png")
    }

    @Test func literalMarkdownCharacters() async throws {
        #expect(try await html("<p>*literal* [brackets] #hashtag</p>") == "\\*literal\\* \\[brackets\\] \\#hashtag")
        #expect(Markdown.escape("- item") == "\\- item")
        #expect(Markdown.escape("1. item") == "1\\. item")
    }

    @Test func richTextRoundTripStylesAndLink() async throws {
        let text = NSMutableAttributedString(string: "Bold italic link", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: 4))
        text.addAttribute(.font, value: NSFontManager.shared.convert(NSFont.systemFont(ofSize: 14), toHaveTrait: .italicFontMask), range: NSRange(location: 5, length: 6))
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 12, length: 4))
        let data = try #require(text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let item = NSPasteboardItem()
        item.setData(data, forType: .rtf)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board)
        #expect(try await converter.convert(to: .markdown) == "**Bold** *italic* [link](<https://example.com>)")
        try converter.undo()
        #expect(try await converter.convert(to: .plainText) == text.string)
    }

    @Test func richTextStyleRunsCoalesce() async throws {
        let text = NSMutableAttributedString(string: "Word", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        text.addAttribute(.foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 2))
        #expect(try await RichTextRenderer().render(text, format: .markdown) == "**Word**")
    }

    @Test func richTextHeadingAndList() async throws {
        let heading = NSMutableParagraphStyle()
        heading.headerLevel = 2
        let text = NSMutableAttributedString(string: "Heading\n", attributes: [.paragraphStyle: heading])
        let listStyle = NSMutableParagraphStyle()
        listStyle.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        text.append(NSAttributedString(string: "\t•\tFirst\n\t•\tSecond", attributes: [.paragraphStyle: listStyle]))
        #expect(try await RichTextRenderer().render(text, format: .markdown) == "## Heading\n\n- First\n\n- Second")
    }

    @Test func clipboardRichTextPriorityAndUndo() async throws {
        let item = NSPasteboardItem()
        item.setString("Hello bold", forType: .string)
        item.setString("<p>Hello <b>bold</b></p>", forType: .html)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board)
        #expect(try await converter.convert(to: .markdown) == "Hello **bold**")
        #expect(board.types?.contains(.string) == true)
        #expect(board.types?.contains(.html) == false)
        #expect(board.types?.contains(.rtf) == false)
        #expect(converter.canUndo)
        try converter.undo()
        #expect(board.string(forType: .html) == "<p>Hello <b>bold</b></p>")
        #expect(board.string(forType: .string) == "Hello bold")
        #expect(!converter.canUndo)
        #expect(try await converter.convert(to: .plainText) == "Hello bold")
    }

    @Test func newCopyInvalidatesUndo() async throws {
        let item = NSPasteboardItem()
        item.setString("one", forType: .string)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board)
        try await converter.convert(to: .plainText)
        board.clearContents()
        board.setString("new copy", forType: .string)
        #expect(!converter.canUndo)
        #expect(throws: ConversionError.self) { try converter.undo() }
        #expect(board.string(forType: .string) == "new copy")
    }

    @Test func plainTextIsIdempotent() async throws {
        let item = NSPasteboardItem()
        let text = "# Existing Markdown\n\n**Keep it**\n  spaces\n👩🏽‍💻 e\u{301}"
        item.setString(text, forType: .string)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board)
        #expect(try await converter.convert(to: .markdown) == text)
        #expect(try await converter.convert(to: .plainText) == text)
    }

    @Test func unsupportedItemLeavesEntireClipboardIntact() async throws {
        let known = NSPasteboardItem()
        known.setString("keep", forType: .string)
        let unknown = NSPasteboardItem()
        let type = NSPasteboard.PasteboardType("com.example.unknown")
        unknown.setData(Data([1, 2, 3]), forType: type)
        let board = pasteboard([known, unknown])
        defer { board.releaseGlobally() }
        let count = board.changeCount
        await #expect(throws: ConversionError.self) { try await ClipboardConverter(pasteboard: board).convert(to: .plainText) }
        #expect(board.changeCount == count)
        #expect(board.pasteboardItems?.count == 2)
        #expect(board.pasteboardItems?.last?.data(forType: type) == Data([1, 2, 3]))
    }

    @Test func filesBecomeReferencesAndImagesWithoutTextBecomeMessages() async throws {
        let items = ["file:///Users/test/My%20Photo.png", "file:///Users/test/report.txt"].map { path in
            let item = NSPasteboardItem()
            item.setString(path, forType: .fileURL)
            return item
        }
        let board = pasteboard(items)
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board)
        #expect(try await converter.convert(to: .plainText) == "No text found to OCR.\n/Users/test/report.txt")
        try converter.undo()
        #expect(try await converter.convert(to: .markdown) == "No text found to OCR.\n[report.txt](<file:///Users/test/report.txt>)")
    }

    @Test func imageWithoutTextBecomesMessageAndUndoRestoresBytes() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, assets: AssetStore(directory: folder))
        #expect(try await converter.convert(to: .plainText) == "No text found to OCR.")
        #expect(board.string(forType: .string) == "No text found to OCR.")
        #expect(board.data(forType: .png) == nil)
        try converter.undo()
        #expect(board.data(forType: .png) == data)
        #expect(try await converter.convert(to: .markdown) == "No text found to OCR.")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func namedURL() async throws {
        let item = NSPasteboardItem()
        item.setString("https://example.com", forType: .URL)
        item.setString("Example", forType: NSPasteboard.PasteboardType("public.url-name"))
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        #expect(try await ClipboardConverter(pasteboard: board).convert(to: .markdown) == "[Example](<https://example.com>)")
    }

    @Test func richTextEndingInEmoji() async throws {
        let text = NSAttributedString(string: "Hello 🌍", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        #expect(try await RichTextRenderer().render(text, format: .markdown) == "**Hello 🌍**")
    }

    @Test func emptyClipboardIsNotOverwritten() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let count = board.changeCount
        await #expect(throws: ConversionError.self) { try await ClipboardConverter(pasteboard: board).convert(to: .plainText) }
        #expect(board.changeCount == count)
    }

    @Test func rtfdAttachmentBecomesFileReference() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wrapper = FileWrapper(regularFileWithContents: Data("Example attachment".utf8))
        wrapper.preferredFilename = "notes.txt"
        let text = NSMutableAttributedString(string: "See ")
        text.append(NSAttributedString(attachment: NSTextAttachment(fileWrapper: wrapper)))
        let data = try #require(text.rtfd(from: NSRange(location: 0, length: text.length), documentAttributes: [:]))
        let item = NSPasteboardItem()
        item.setData(data, forType: .rtfd)
        item.setString(text.string, forType: .string)
        let board = pasteboard([item])
        defer { board.releaseGlobally() }
        let converter = ClipboardConverter(pasteboard: board, assets: AssetStore(directory: folder))
        let plain = try await converter.convert(to: .plainText)
        #expect(plain.hasPrefix("See " + folder.path))
        #expect(!plain.contains("\u{FFFC}"))
        try converter.undo()
        let markdown = try await converter.convert(to: .markdown)
        #expect(markdown.contains("[notes.txt](<file://"))
    }

    @Test func inlineBase64ImageSavedLocally() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 3, bitsPerPixel: 24))
        bitmap.setColor(.blue, atX: 0, y: 0)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let result = try await HTMLRenderer(format: .markdown, assets: AssetStore(directory: folder)).render(Data("<img src='data:image/png;base64,\(data.base64EncodedString())' alt='Blue'>".utf8))
        #expect(result.hasPrefix("![Blue](<file://"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1)
    }

    @Test func utf16ClipboardHTML() async throws {
        let data = try #require("<p>Café 猫</p>".data(using: .utf16))
        #expect(try await HTMLRenderer(format: .markdown).render(data) == "Café 猫")
    }

    @Test func nestedEquivalentFormattingDoesNotDuplicateDelimiters() async throws {
        #expect(try await html("<p><strong><b>Bold</b></strong> <i><em>italic</em></i></p>") == "**Bold** *italic*")
    }

    private func pasteboard(_ items: [NSPasteboardItem]) -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.writeObjects(items)
        return board
    }
}
