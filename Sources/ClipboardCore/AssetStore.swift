import AppKit
import CryptoKit

public struct AssetStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Plaintexter/Clipboard Images", isDirectory: true)
    }

    func save(_ data: Data, extension ext: String, name: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let hash = SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
        let stem = name.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        let safeStem = (stem ?? "Clipboard").replacingOccurrences(of: #"[^\p{L}\p{N} ._-]"#, with: "-", options: .regularExpression)
        let url = directory.appendingPathComponent("\(safeStem.prefix(80))-\(hash).\(ext)")
        if !FileManager.default.fileExists(atPath: url.path) { try data.write(to: url, options: .atomic) }
        return url
    }

    func saveImage(_ data: Data) throws -> URL? {
        guard let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return try save(png, extension: "png")
    }

    func imageReference(_ source: String) throws -> String? {
        guard source.lowercased().hasPrefix("data:") else { return source }
        guard let comma = source.firstIndex(of: ","), source[..<comma].lowercased().hasPrefix("data:image/"),
              source[..<comma].lowercased().contains(";base64"),
              let data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters),
              let url = try saveImage(data) else { return nil }
        return url.absoluteString
    }
}
