import Foundation

public enum AppInstallation {
    public static func isInstalled(_ app: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = app.resolvingSymlinksInPath().standardizedFileURL.path
        let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
        return roots.contains { path.hasPrefix($0.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }

    /// Stage and validate the complete copy before replacing any installed version.
    /// Retain the previous bundle in the Trash; restore it if the final move fails.
    public static func install(from source: URL, to destination: URL,
                               validate: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let stage = parent.appendingPathComponent(".Plaintexter-install-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        let copy = stage.appendingPathComponent("Plaintexter.app")
        let previous = stage.appendingPathComponent("Previous.app")
        var retainStage = false
        defer { if !retainStage { try? fm.removeItem(at: stage) } }
        try fm.copyItem(at: source, to: copy)
        try validate(copy)

        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious { try fm.moveItem(at: destination, to: previous) }
        do {
            try fm.moveItem(at: copy, to: destination)
        } catch {
            if hadPrevious {
                // Do not let cleanup erase the previous app if rollback itself fails.
                do { try fm.moveItem(at: previous, to: destination) }
                catch {
                    retainStage = true
                    throw InstallationError.recoveryRequired(previous.path)
                }
            }
            throw error
        }
        if hadPrevious {
            // The new copy is installed. Keep a recoverable backup if Trash is unavailable.
            do { try fm.trashItem(at: previous, resultingItemURL: nil) }
            catch {
                let backup = parent.appendingPathComponent("Plaintexter-previous-" + UUID().uuidString + ".app")
                do { try fm.moveItem(at: previous, to: backup) }
                catch { retainStage = true }
            }
        }
    }
}

public enum InstallationError: LocalizedError {
    case recoveryRequired(String)
    public var errorDescription: String? {
        switch self {
        case .recoveryRequired(let path): "Installation could not finish. Your previous app is at \(path)."
        }
    }
}
