import Foundation
import Testing
@testable import AppSupport

struct InstallationTests {
    @Test func acceptsOnlyApplicationDirectories() {
        let home = URL(fileURLWithPath: "/Users/example")
        for path in ["/Applications/Plaintexter.app", "/Applications/Utilities/Plaintexter.app",
                     "/Users/example/Applications/Plaintexter.app"] {
            #expect(AppInstallation.isInstalled(URL(fileURLWithPath: path), home: home))
        }
        for path in ["/Applications-old/Plaintexter.app", "/Users/example/Applications2/Plaintexter.app",
                     "/Users/example/Downloads/Plaintexter.app", "/Volumes/Plaintexter/Plaintexter.app"] {
            #expect(!AppInstallation.isInstalled(URL(fileURLWithPath: path), home: home))
        }
    }

    @Test func resolvesSymlinksBeforeCheckingLocation() throws {
        try withTemporaryDirectory { root in
            let downloads = root.appendingPathComponent("Downloads")
            let app = downloads.appendingPathComponent("Plaintexter.app")
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
            let applications = root.appendingPathComponent("Applications")
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
            let link = applications.appendingPathComponent("Plaintexter.app")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
            #expect(!AppInstallation.isInstalled(link, home: root))
        }
    }

    @Test func stagesCompleteCopyAndKeepsSource() throws {
        try withTemporaryDirectory { root in
            let source = try fixture(in: root, name: "Download.app", text: "new")
            let destination = root.appendingPathComponent("Applications/Plaintexter.app")
            var validated = false
            try AppInstallation.install(from: source, to: destination) { (staged: URL) throws in
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(try String(contentsOf: staged.appendingPathComponent("payload"), encoding: .utf8) == "new")
                validated = true
            }
            #expect(validated)
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(try String(contentsOf: destination.appendingPathComponent("payload"), encoding: .utf8) == "new")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Plaintexter.app"])
        }
    }

    @Test func invalidSignatureLeavesInstalledAppUntouched() throws {
        try withTemporaryDirectory { root in
            let source = try fixture(in: root, name: "Download.app", text: "bad")
            let destination = try fixture(in: root, name: "Applications/Plaintexter.app", text: "old")
            enum Rejected: Error { case signature }
            #expect(throws: Rejected.signature) {
                try AppInstallation.install(from: source, to: destination) { _ in throw Rejected.signature }
            }
            #expect(try String(contentsOf: destination.appendingPathComponent("payload"), encoding: .utf8) == "old")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path) == ["Plaintexter.app"])
        }
    }

    @Test func missingSourceLeavesInstalledAppUntouched() throws {
        try withTemporaryDirectory { root in
            let destination = try fixture(in: root, name: "Applications/Plaintexter.app", text: "old")
            #expect(throws: (any Error).self) {
                try AppInstallation.install(from: root.appendingPathComponent("Missing.app"), to: destination) { _ in }
            }
            #expect(try String(contentsOf: destination.appendingPathComponent("payload"), encoding: .utf8) == "old")
        }
    }

    private func fixture(in root: URL, name: String, text: String) throws -> URL {
        let app = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try text.write(to: app.appendingPathComponent("payload"), atomically: true, encoding: .utf8)
        return app
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Plaintexter-install-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }
}
