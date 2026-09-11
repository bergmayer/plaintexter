import Foundation

public enum TextFormat: Sendable {
    case plainText, markdown
}

enum Markdown {
    static func escape(_ text: String) -> String {
        var result = text
        for character in ["\\", "`", "*", "_", "~", "[", "]", "<", ">", "|", "#"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result.replacingOccurrences(
            of: #"(?m)^(\s*)([-+])(?=\s)"#,
            with: "$1\\\\$2", options: .regularExpression
        ).replacingOccurrences(
            of: #"(?m)^(\s*)(\d+)([.)])(?=\s)"#,
            with: "$1$2\\\\$3", options: .regularExpression
        )
    }

    static func wrap(_ text: String, with marker: String) -> String {
        let core = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !core.isEmpty, let range = text.range(of: core) else { return text }
        return String(text[..<range.lowerBound]) + marker + core + marker + text[range.upperBound...]
    }

    static func destination(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "%20")
            .replacingOccurrences(of: "<", with: "%3C")
            .replacingOccurrences(of: ">", with: "%3E")
            .replacingOccurrences(of: "\n", with: "%0A")
            .replacingOccurrences(of: "\r", with: "%0D")
    }

    static func link(label: String, destination: String, image: Bool = false) -> String {
        "\(image ? "!" : "")[\(escape(label))](<\(self.destination(destination))>)"
    }

    static func code(_ text: String, block: Bool = false) -> String {
        let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(block ? 3 : 1, longest + 1))
        if block { return fence + "\n" + text + (text.hasSuffix("\n") ? "" : "\n") + fence }
        let pad = text.hasPrefix("`") || text.hasSuffix("`") || (text.hasPrefix(" ") && text.hasSuffix(" "))
        return fence + (pad ? " " : "") + text + (pad ? " " : "") + fence
    }
}
