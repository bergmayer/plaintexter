import AppKit
import ClipboardCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var plainMenuItem: NSMenuItem!
    private var markdownMenuItem: NSMenuItem!
    private var undoMenuItem: NSMenuItem!
    private var launchMenuItem: NSMenuItem!
    private let converter = ClipboardConverter()
    private var feedbackTask: Task<Void, Never>?
    private var conversionTask: Task<Void, Never>?
    private var selectedFormat: TextFormat {
        get { UserDefaults.standard.string(forKey: "ConversionFormat") == "markdown" ? .markdown : .plainText }
        set { UserDefaults.standard.set(newValue == .markdown ? "markdown" : "plainText", forKey: "ConversionFormat") }
    }
    private var defaultHelp: String {
        "Click to convert clipboard to \(selectedFormat == .plainText ? "plain text" : "Markdown"). Right-click or Control-click for options."
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if InstallationPrompt.offerIfNeeded() { return }
        // A second launch should not add duplicate menu bar buttons.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Plaintexter.pt"
        guard let button = statusItem.button else { return }
        button.title = "pt"
        button.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        button.target = self
        button.action = #selector(iconClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = defaultHelp
        button.setAccessibilityLabel("Plaintexter")
        button.setAccessibilityHelp(defaultHelp)

        menu.delegate = self
        menu.autoenablesItems = false
        plainMenuItem = addMenuItem("Convert to Plain Text", action: #selector(selectPlainText), to: menu)
        markdownMenuItem = addMenuItem("Convert to Markdown", action: #selector(selectMarkdown), to: menu)
        menu.addItem(.separator())
        undoMenuItem = addMenuItem("Undo Last Conversion", action: #selector(undo), to: menu)
        menu.addItem(.separator())
        launchMenuItem = addMenuItem("Open at Launch", action: #selector(toggleOpenAtLaunch), to: menu)
        launchMenuItem.toolTip = "Start Plaintexter automatically when you log in to your Mac."
        addMenuItem("Help", action: #selector(openHelp), to: menu)
        menu.addItem(.separator())
        addMenuItem("Quit Plaintexter", action: #selector(quit), to: menu)
        updateMenuState()
    }

    @objc private func iconClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            present(menu)
        } else {
            // Capture the selected mode for this conversion, even if it changes during OCR.
            perform(selectedFormat)
        }
    }

    private func feedback(title: String, message: String? = nil) {
        guard let button = statusItem.button else { return }
        feedbackTask?.cancel()
        button.title = title
        if let message { button.toolTip = message }
        let help = defaultHelp
        feedbackTask = Task { @MainActor [weak button] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            button?.title = "pt"
            button?.toolTip = help
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { updateMenuState() }

    private func updateMenuState() {
        plainMenuItem.state = selectedFormat == .plainText ? .on : .off
        markdownMenuItem.state = selectedFormat == .markdown ? .on : .off
        undoMenuItem.isEnabled = conversionTask == nil && converter.canUndo
        switch SMAppService.mainApp.status {
        case .enabled: launchMenuItem.state = .on
        case .requiresApproval: launchMenuItem.state = .mixed
        default: launchMenuItem.state = .off
        }
    }

    private func presentError(_ error: Error) {
        let errorMenu = NSMenu()
        errorMenu.addItem(withTitle: error.localizedDescription, action: nil, keyEquivalent: "")
        errorMenu.addItem(.separator())
        addMenuItem("Quit Plaintexter", action: #selector(quit), to: errorMenu)
        present(errorMenu)
    }

    private func present(_ menu: NSMenu) {
        statusItem.menu = menu
        defer { statusItem.menu = nil }
        statusItem.button?.performClick(nil)
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func selectPlainText() { select(.plainText) }
    @objc private func selectMarkdown() { select(.markdown) }

    @objc private func openHelp() {
        NSWorkspace.shared.open(URL(string: "https://bergmayer.net/plaintexter")!)
    }

    @objc private func toggleOpenAtLaunch() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    let alert = NSAlert()
                    alert.messageText = "Allow Plaintexter to open at login"
                    alert.informativeText = "Enable Plaintexter in System Settings → General → Login Items."
                    alert.addButton(withTitle: "Open System Settings")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                }
            }
            updateMenuState()
        } catch {
            updateMenuState()
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func select(_ format: TextFormat) {
        selectedFormat = format
        updateMenuState()
        statusItem.button?.setAccessibilityHelp(defaultHelp)
        if conversionTask == nil {
            feedbackTask?.cancel()
            statusItem.button?.title = "pt"
            statusItem.button?.toolTip = defaultHelp
        }
    }

    private func perform(_ format: TextFormat) {
        guard conversionTask == nil, let button = statusItem.button else { return }
        feedbackTask?.cancel()
        button.title = "…"
        button.toolTip = "Converting clipboard and reading text in images…"
        conversionTask = Task { @MainActor in
            defer {
                conversionTask = nil
                updateMenuState()
            }
            do {
                try await converter.convert(to: format)
                feedback(title: "✓")
            } catch {
                feedback(title: "!", message: error.localizedDescription)
                NSSound.beep()
                presentError(error)
            }
        }
        updateMenuState()
    }

    @objc private func undo() {
        do {
            try converter.undo()
            feedback(title: "↶")
        } catch {
            NSSound.beep()
            presentError(error)
        }
        updateMenuState()
    }

    @objc private func quit() { conversionTask?.cancel(); NSApp.terminate(nil) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
