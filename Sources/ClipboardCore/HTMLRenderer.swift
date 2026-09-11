import Foundation

/// Parses clipboard HTML without a web view or script execution.
@MainActor
public final class HTMLRenderer {
    private let format: TextFormat
    private let assets: AssetStore
    private var protectedBlocks: [String: String] = [:]
    private var baseURL: URL?
    private var imageText: [ObjectIdentifier: String] = [:]
    public private(set) var didRecognizeImageText = false
    public var didProcessImages: Bool { !imageText.isEmpty }

    public init(format: TextFormat, assets: AssetStore = AssetStore()) {
        self.format = format
        self.assets = assets
    }

    public func render(_ data: Data, baseURL: URL? = nil, ocr: ImageOCR? = nil, clipboardImage: Data? = nil) async throws -> String {
        self.baseURL = baseURL
        protectedBlocks.removeAll()
        imageText.removeAll()
        didRecognizeImageText = false
        // The tidy parser's Data initializer assumes ASCII for fragments without a charset.
        // Clipboard HTML is normally UTF-8; decode it before handing it to the parser.
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        guard let source = String(data: data, encoding: hasUTF16BOM ? .utf16 : .utf8)
            ?? String(data: data, encoding: .windowsCP1252) else { throw ConversionError.unsupported }
        let document = try XMLDocument(xmlString: source, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        if let base = try document.nodes(forXPath: "//base/@href").first?.stringValue {
            self.baseURL = URL(string: base, relativeTo: baseURL)
        }
        let root = try document.nodes(forXPath: "//body").first ?? document
        if let ocr {
            let images = try root.nodes(forXPath: ".//img").compactMap { $0 as? XMLElement }.filter { !isHidden($0) }
            for element in images {
                var text: String?
                if images.count == 1, let clipboardImage {
                    text = await ocr.text(in: clipboardImage)
                } else if let source = element.attribute(forName: "src")?.stringValue {
                    text = await ocr.text(at: resolved(source))
                }
                imageText[ObjectIdentifier(element)] = text ?? ImageOCR.noTextMessage
                if text != nil { didRecognizeImageText = true }
            }
        }
        var output = try children(root)
        output = output.replacingOccurrences(of: #"\n[ \t]*\n(?:[ \t]*\n)+"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        for (token, block) in protectedBlocks { output = output.replacingOccurrences(of: token, with: block) }
        return output
    }

    private func children(_ node: XMLNode) throws -> String {
        try (node.children ?? []).map { try renderNode($0) }.joined()
    }

    private func renderNode(_ node: XMLNode) throws -> String {
        if node.kind == .text {
            let text = (node.stringValue ?? "").replacingOccurrences(of: #"[\s\u00a0]+"#, with: " ", options: .regularExpression)
            return format == .markdown ? Markdown.escape(text) : text
        }
        guard let element = node as? XMLElement else { return "" }
        let tag = element.name?.lowercased() ?? ""
        if ["script", "style", "head", "noscript", "template"].contains(tag) { return "" }
        let style = styles(element)
        if style["display"] == "none" || style["visibility"] == "hidden" || element.attribute(forName: "hidden") != nil { return "" }
        if tag == "br" { return format == .markdown ? "  \n" : "\n" }
        if tag == "hr" { return format == .markdown ? "\n\n---\n\n" : "\n\n" }
        if tag == "img" { return try image(element) }
        if tag == "pre" {
            let text = element.stringValue ?? ""
            let token = "\u{E000}\(UUID().uuidString)\u{E001}"
            protectedBlocks[token] = format == .markdown ? Markdown.code(text, block: true) : text
            return "\n\n" + token + "\n\n"
        }
        if tag == "ul" || tag == "ol" { return try list(element, ordered: tag == "ol") }
        if tag == "table" { return try table(element) }
        var text = try children(element)
        if tag == "a", let href = element.attribute(forName: "href")?.stringValue, !href.isEmpty {
            let target = resolved(href)
            if format == .markdown {
                let label = text.trimmingCharacters(in: .whitespacesAndNewlines)
                text = "[\(label.isEmpty ? Markdown.escape(target) : label)](<\(Markdown.destination(target))>)"
            } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = target
            }
        }
        if format == .markdown {
            if tag == "code" || tag == "kbd" || tag == "samp" || style["font-family"]?.contains("monospace") == true {
                text = Markdown.code(element.stringValue ?? "")
            } else {
                let weight = style["font-weight"] ?? ""
                let bold = weight.isEmpty ? ["b", "strong"].contains(tag) : weight == "bold" || (Int(weight) ?? 0) >= 600
                let italic = style["font-style"].map { $0 == "italic" || $0 == "oblique" } ?? ["i", "em"].contains(tag)
                if bold && !ancestorApplies("bold", to: element) { text = Markdown.wrap(text, with: "**") }
                if italic && !ancestorApplies("italic", to: element) { text = Markdown.wrap(text, with: "*") }
                if (["s", "strike", "del"].contains(tag) || (style["text-decoration"] ?? style["text-decoration-line"] ?? "").contains("line-through")) && !ancestorApplies("strike", to: element) { text = Markdown.wrap(text, with: "~~") }
            }
            if tag.count == 2, tag.first == "h", let level = Int(tag.suffix(1)), (1...6).contains(level) {
                return "\n\n" + String(repeating: "#", count: level) + " " + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            }
            if tag == "blockquote" {
                return "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n") + "\n\n"
            }
        }
        if ["p", "div", "section", "article", "header", "footer", "main", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "dl", "dt", "dd"].contains(tag) {
            return "\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
        }
        return text
    }

    private func list(_ element: XMLElement, ordered: Bool) throws -> String {
        var index = Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1
        var lines: [String] = []
        for item in element.children ?? [] where item.name?.lowercased() == "li" {
            if let value = (item as? XMLElement)?.attribute(forName: "value")?.stringValue, let number = Int(value) { index = number }
            let marker = ordered ? "\(index). " : "- "
            let content = try children(item).trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = content.components(separatedBy: "\n")
            lines.append(marker + parts.enumerated().map { $0.offset == 0 ? $0.element : String(repeating: " ", count: marker.count) + $0.element }.joined(separator: "\n"))
            index += 1
        }
        return "\n\n" + lines.joined(separator: "\n") + "\n\n"
    }

    private func table(_ element: XMLElement) throws -> String {
        let rowNodes = try element.nodes(forXPath: "./tr|./thead/tr|./tbody/tr|./tfoot/tr")
        let rows = try rowNodes.map { row in
            try (row.children ?? []).filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }.map {
                try children($0).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: format == .markdown ? "<br>" : " ")
            }
        }.filter { !$0.isEmpty }
        guard let width = rows.map(\.count).max(), width > 0 else { return "" }
        if format == .plainText { return "\n\n" + rows.map { $0.joined(separator: "\t") }.joined(separator: "\n") + "\n\n" }
        func line(_ cells: [String]) -> String { "| " + (cells + Array(repeating: "", count: width - cells.count)).joined(separator: " | ") + " |" }
        let hasHeader = rowNodes.first?.children?.contains { $0.name?.lowercased() == "th" } == true
        var output = [line(hasHeader ? rows[0] : Array(repeating: "", count: width)), line(Array(repeating: "---", count: width))]
        output += (hasHeader ? Array(rows.dropFirst()) : rows).map(line)
        return "\n\n" + output.joined(separator: "\n") + "\n\n"
    }

    private func image(_ element: XMLElement) throws -> String {
        if let text = imageText[ObjectIdentifier(element)] {
            return "\n\n" + ImageOCR.formatted(text, as: format) + "\n\n"
        }
        let alt = element.attribute(forName: "alt")?.stringValue ?? ""
        guard let source = element.attribute(forName: "src")?.stringValue, !source.isEmpty,
              let reference = try assets.imageReference(source) else { return format == .markdown ? Markdown.escape(alt) : alt }
        let target = resolved(reference)
        if format == .markdown { return Markdown.link(label: alt, destination: target, image: true) }
        if let url = URL(string: target), url.isFileURL { return url.path }
        return target
    }

    private func resolved(_ value: String) -> String {
        URL(string: value, relativeTo: baseURL)?.absoluteURL.absoluteString ?? value
    }

    private func styles(_ element: XMLElement) -> [String: String] {
        var result: [String: String] = [:]
        for declaration in (element.attribute(forName: "style")?.stringValue ?? "").split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { result[parts[0].trimmingCharacters(in: .whitespaces).lowercased()] = parts[1].trimmingCharacters(in: .whitespaces).lowercased() }
        }
        return result
    }

    private func isHidden(_ element: XMLElement) -> Bool {
        var current: XMLNode? = element
        while let node = current as? XMLElement {
            let style = styles(node)
            if node.attribute(forName: "hidden") != nil || style["display"] == "none" || style["visibility"] == "hidden" || ["head", "template", "noscript"].contains(node.name?.lowercased() ?? "") { return true }
            current = node.parent
        }
        return false
    }

    private func ancestorApplies(_ trait: String, to element: XMLElement) -> Bool {
        var ancestor = element.parent
        while let node = ancestor as? XMLElement {
            let tag = node.name?.lowercased() ?? ""
            let style = styles(node)
            if trait == "bold" {
                if let weight = style["font-weight"] { return weight == "bold" || (Int(weight) ?? 0) >= 600 }
                if ["b", "strong"].contains(tag) { return true }
            } else if trait == "italic" {
                if let value = style["font-style"] { return ["italic", "oblique"].contains(value) }
                if ["i", "em"].contains(tag) { return true }
            } else if ["s", "strike", "del"].contains(tag) || (style["text-decoration"] ?? style["text-decoration-line"] ?? "").contains("line-through") { return true }
            ancestor = node.parent
        }
        return false
    }
}
