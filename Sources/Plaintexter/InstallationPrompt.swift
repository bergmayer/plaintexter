import AppKit
import AppSupport
import Security

@MainActor
enum InstallationPrompt {
    /// Returns true when this process is quitting after installation.
    static func offerIfNeeded() -> Bool {
        let source = Bundle.main.bundleURL
        // A SwiftPM command-line development build is not an installable app bundle.
        guard source.pathExtension == "app", !AppInstallation.isInstalled(source) else { return false }
        let destination = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Plaintexter.app")
        let alert = NSAlert()
        alert.messageText = "Move Plaintexter to Applications?"
        alert.informativeText = "Plaintexter will move to ~/Applications and reopen there. You can then eject the disk image, if one is open."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            if let bundleID = Bundle.main.bundleIdentifier,
               NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                throw InstallProblem.runningCopy
            }
            if FileManager.default.fileExists(atPath: destination.path) {
                guard Bundle(url: destination)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                    throw InstallProblem.differentApp
                }
                let replace = NSAlert()
                replace.messageText = "Replace the installed Plaintexter?"
                replace.informativeText = "The previous copy will go to the Trash. Your settings will be kept."
                replace.addButton(withTitle: "Replace")
                replace.addButton(withTitle: "Cancel")
                guard replace.runModal() == .alertFirstButtonReturn else { return false }
            }
            try AppInstallation.install(from: source, to: destination, validate: verifySignature)

            // A separate process waits until this instance has exited. Passing paths as
            // arguments (never interpolating shell code) handles spaces and punctuation.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", """
                count=0
                while /bin/kill -0 "$1" 2>/dev/null; do
                    count=$((count + 1))
                    [ "$count" -lt 150 ] || exit 1
                    /bin/sleep 0.1
                done
                exec /usr/bin/open "$2"
                """, "plaintexter-relaunch", String(ProcessInfo.processInfo.processIdentifier), destination.path]
            relaunch.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            relaunch.standardInput = FileHandle.nullDevice
            relaunch.standardOutput = FileHandle.nullDevice
            relaunch.standardError = FileHandle.nullDevice
            try relaunch.run()
            // A mounted DMG or translocated bundle is read-only; leave that source alone.
            if FileManager.default.isWritableFile(atPath: source.deletingLastPathComponent().path) {
                try? FileManager.default.trashItem(at: source, resultingItemURL: nil)
            }
            NSApp.terminate(nil)
            return true
        } catch {
            let failure = NSAlert(error: error)
            failure.runModal()
            return false
        }
    }

    private static func verifySignature(_ url: URL) throws {
        var code: SecStaticCode?
        var result = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        if result == errSecSuccess, let code {
            result = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
        }
        guard result == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: [
                NSLocalizedDescriptionKey: "The copied app failed its signature check. The installed copy has not been replaced."
            ])
        }
    }

    private enum InstallProblem: LocalizedError {
        case runningCopy, differentApp
        var errorDescription: String? {
            switch self {
            case .runningCopy: "Quit the other copy of Plaintexter, then open this copy again to install it."
            case .differentApp: "A different app already exists at ~/Applications/Plaintexter.app. Move or rename it before installing."
            }
        }
    }
}
