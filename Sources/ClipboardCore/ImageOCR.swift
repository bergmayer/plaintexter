import Foundation
import CryptoKit
import ImageIO
import Vision

/// One conversion's image cache. Recognition runs off the main actor and never uploads pixels.
@MainActor
public final class ImageOCR {
    nonisolated public static let noTextMessage = "No text found to OCR."
    public typealias Recognizer = @Sendable (Data) async -> String?
    public typealias ImageLoader = @Sendable (URL) async -> Data?
    private struct Result { let text: String? }
    private let recognize: Recognizer?
    private let load: ImageLoader?
    private var results: [String: Result] = [:]
    private var sources: [String: Result] = [:]

    public init(
        recognize: Recognizer? = nil,
        load: ImageLoader? = nil
    ) {
        self.recognize = recognize
        self.load = load
    }

    public func text(in data: Data, minimumCharacters: Int = 40) async -> String? {
        guard !Task.isCancelled else { return nil }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let result = results[hash] { return result.text.flatMap { Self.substantialText($0, minimumCharacters: minimumCharacters) } }
        let text: String?
        if let recognize { text = await recognize(data) }
        else { text = await Self.recognizeText(data) }
        let result = Result(text: text)
        results[hash] = result
        return result.text.flatMap { Self.substantialText($0, minimumCharacters: minimumCharacters) }
    }

    public func text(at source: String) async -> String? {
        guard !Task.isCancelled else { return nil }
        if let result = sources[source] { return result.text }
        var data: Data?
        if source.lowercased().hasPrefix("data:image/"), let comma = source.firstIndex(of: ","), source[..<comma].lowercased().contains(";base64") {
            data = Data(base64Encoded: String(source[source.index(after: comma)...]), options: .ignoreUnknownCharacters)
        } else if let url = URL(string: source), url.isFileURL || ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            if let load { data = await load(url) }
            else { data = await Self.loadImage(url) }
        }
        let text: String?
        if let data { text = await self.text(in: data) } else { text = nil }
        sources[source] = Result(text: text)
        return text
    }

    /// Ignore a logo, a short caption, and isolated uncertain glyphs. This also works without spaces (e.g. Chinese).
    nonisolated static func substantialText(_ text: String, minimumCharacters: Int = 40) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let characters = text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return characters >= max(1, minimumCharacters) ? text : nil
    }

    nonisolated static func formatted(_ text: String, as format: TextFormat) -> String {
        if format == .plainText { return text }
        // OCR supplies text, not inferred formatting. Escape literal Markdown syntax and retain line breaks.
        return text.components(separatedBy: "\n").map(Markdown.escape).joined(separator: "  \n")
    }

    nonisolated public static func recognizeText(_ data: Data) async -> String? {
        await Task.detached(priority: .userInitiated) {
            autoreleasepool {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width >= 40, height >= 20 else { return nil }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 6000
                ]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do { try VNImageRequestHandler(cgImage: image).perform([request]) }
                catch { return nil }
                // Retain Vision's line order and line boundaries.
                let lines = (request.results ?? []).compactMap { observation -> String? in
                    guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.5 else { return nil }
                    return candidate.string
                }
                return substantialText(lines.joined(separator: "\n"), minimumCharacters: 1)
            }
        }.value
    }

    nonisolated public static func loadImage(_ url: URL) async -> Data? {
        let limit = 20 * 1024 * 1024
        if url.isFileURL {
            return await Task.detached(priority: .userInitiated) {
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= limit else { return nil }
                return try? Data(contentsOf: url)
            }.value
        }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode),
                  response.expectedContentLength <= limit,
                  response.mimeType?.lowercased().hasPrefix("image/") == true else { return nil }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit, !Task.isCancelled else { return nil }
                data.append(byte)
            }
            return data
        } catch { return nil }
    }
}
