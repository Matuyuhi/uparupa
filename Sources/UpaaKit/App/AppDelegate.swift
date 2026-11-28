import AppKit
import Metal

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var config = Config.load()
    private lazy var fontFamily = config.fontFamily
    /// The config's font could not be found, so a terminal kept its font or took the default.
    private var fontMissing = false
    /// What in the config could not be used, shown in every window's footer and in Settings.
    private var problems: [String] {
        config.problems + (fontMissing ? [String(localized: "Font not found: \(config.fontFamilies[0])")] : [])
    }
    /// AppKit does not keep a window alive by itself, so open windows are held here until they close.
    private var windows: [TabbedWindow] = []
    /// Every open terminal, for a change of font.
    private let terminals = NSHashTable<TerminalView>.weakObjects()
    private var settings: SettingsWindow?
    private var watchers: [DispatchSourceFileSystemObject] = []
    /// The socket the upaa command reaches the app through from a pane, open while the config turns it on. Made with
    /// the delegate, so that the panes' shells get its path from the first one on.
    private let remote = RemoteControl()
    /// Points Cmd-+ and Cmd-− added to the config's size.
    private var zoom = 0.0
    private var fontSize: Double { min(200, max(4, config.fontSize + zoom)) }

    private var scale: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The windows open at the last quit are back by now, where they were (restoreWindow), unless the system closes
        // windows on quit. Otherwise one window opens where the last one used was; the config's size is for the first
        // launch and for new windows.
        if windows.isEmpty {
            guard let window = makeWindow() else {
                NSLog("upaa: failed to start the terminal")
                NSApp.terminate(nil)
                return
            }
            if window.setFrameUsingName(TabbedWindow.frameName) { TabbedWindow.keepOnScreen(window) } else { window.center() }
            window.makeKeyAndOrderFront(nil)
        }
        watchConfig()
        remote.windows = { [weak self] in self?.windows ?? [] }
        remote.enabled = config.remoteControl
        UpdateCheck.run { [weak terminal = terminals.anyObject] message in terminal?.showNote(message) }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        remote.enabled = false
        if let window = NSApp.orderedWindows.first(where: { $0.delegate is TabbedWindow }) { TabbedWindow.saveFrame(of: window) }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Cmd-Q asks first while a program runs in one of the panes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = windows.flatMap(\.running)
        guard !running.isEmpty else { return .terminateNow }
        let alert = TabbedWindow.alert(String(localized: "Quit upaa?"), button: String(localized: "Quit"), running: running)
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Cmd-N. Opens a window slightly below and to the right of the current one.
    @objc func newWindow(_ sender: Any?) {
        guard let window = makeWindow() else { return NSSound.beep() }
        if let current = NSApp.keyWindow {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: current.frame.minX, y: current.frame.maxY)))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// Cmd-,.
    @objc func showSettings(_ sender: Any?) {
        let settings = settings ?? SettingsWindow(
            families: config.fontFamilies, size: config.fontSize, problems: problems
        ) { [weak self] in self?.saveFont(families: $0, size: $1) }
        self.settings = settings
        settings.showWindow(nil)
    }

    /// Cmd-+, Cmd-− and Cmd-0. They change the size in every window until upaa quits, without touching the config file.
    @objc func biggerFont(_ sender: Any?) { zoom(by: 1) }
    @objc func smallerFont(_ sender: Any?) { zoom(by: -1) }
    @objc func defaultFontSize(_ sender: Any?) { zoom(by: -zoom) }

    private func zoom(by points: Double) {
        let size = min(200, max(4, fontSize + points))
        guard size != fontSize else { return }
        zoom = size - config.fontSize
        applyFont()
    }

    /// Saves the font to the config file. The file's change puts it in the windows.
    private func saveFont(families: [String], size: Double) {
        do {
            try Config.saveFont(families: families, size: size)
        } catch {
            if let window = settings?.window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        configChanged()
    }

    /// Watches the config file, its folder (an editor may save by replacing the file) and the folder above it (for a
    /// folder made later). Each source is made again after a change, since the file it was opened on may be gone.
    private func watchConfig() {
        watchers.forEach { $0.cancel() }
        let file = Config.fileURL.resolvingSymlinksInPath()
        watchers = [file, file.deletingLastPathComponent(), file.deletingLastPathComponent().deletingLastPathComponent()]
            .compactMap { url in
                let descriptor = open(url.path, O_EVTONLY)
                guard descriptor >= 0 else { return nil }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor, eventMask: [.write, .extend, .delete, .rename], queue: .main)
                source.setEventHandler { [weak self] in self?.configChanged() }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                return source
            }
    }

    /// Reads the config file again and puts what it says in every window and in Settings.
    private func configChanged() {
        watchConfig()
        let new = Config.load()
        guard new.text != config.text else { return }
        // A size chosen in the settings or written in the file is the size to show, not one to add Cmd-+/- to.
        if new.fontSize != config.fontSize { zoom = 0 }
        config = new
        fontFamily = config.fontFamily
        remote.enabled = config.remoteControl
        for terminal in terminals.allObjects {
            terminal.session.config = config
            terminal.session.setColors(dark: terminal.effectiveAppearance.isDark)
        }
        for window in NSApp.windows where window.delegate is TabbedWindow {
            window.appearance = config.backgroundIsDark.map { NSAppearance(named: $0 ? .darkAqua : .aqua)! }
            // The window's colors come from config when drawn, so draw them again.
            var views = window.contentView.map { [$0] } ?? []
            while let view = views.popLast() {
                view.needsDisplay = true
                views += view.subviews
            }
        }
        fontMissing = false
        applyFont()
        for window in windows { window.problems = problems }
        settings?.show(families: config.fontFamilies, size: config.fontSize, problems: problems)
    }

    /// Puts the font in every open terminal, and steps every window's size by the new cell.
    private func applyFont() {
        for terminal in terminals.allObjects where !terminal.setFont(name: fontFamily, size: fontSize) {
            fontMissing = true
        }
        guard let cell = terminals.anyObject?.renderer.cellSize else { return }
        for window in NSApp.windows where window.delegate is TabbedWindow {
            window.contentResizeIncrements = NSSize(width: Double(cell.width) / scale, height: Double(cell.height) / scale)
        }
    }

    /// A window sized for the config's columns and rows, with one tab.
    private func makeWindow() -> NSWindow? {
        guard let terminal = makeTerminal() else { return nil }
        let renderer = terminal.renderer
        let pixels = renderer.pixelSize(cols: config.cols, rows: config.rows)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Double(pixels.width) / scale, height: Double(pixels.height) / scale)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        // The system keeps where it is, to bring it back at the next launch.
        window.identifier = NSUserInterfaceItemIdentifier("terminal")
        window.restorationClass = Self.self
        // Make the size change in steps of one cell.
        window.contentResizeIncrements = NSSize(
            width: Double(renderer.cellSize.width) / scale, height: Double(renderer.cellSize.height) / scale)
        // A background the config names sets light or dark mode for the whole window; otherwise the system's does.
        if let dark = config.backgroundIsDark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        let background = NSColor(name: nil) { [weak self] in
            let config = self?.config ?? Config()
            let rgb = config.background(dark: $0.isDark)
            return NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                           blue: CGFloat(rgb & 0xff) / 255, alpha: config.backgroundOpacity)
        }
        let tabs = TabbedWindow(window: window, first: terminal, background: background) { [weak self] cwd in
            self?.makeTerminal(cwd: cwd)
        }
        tabs.onClose = { [weak self, weak tabs] in self?.windows.removeAll { $0 === tabs } }
        tabs.problems = problems
        windows.append(tabs)
        return window
    }

    /// A terminal view with its own shell, started in cwd (nil for the home directory).
    private func makeTerminal(cwd: String? = nil) -> TerminalView? {
        let scale = scale
        func makeRenderer(device: MTLDevice) -> Renderer? {
            // The window's card behind the terminal has its default background, so the terminal draws none.
            try? Renderer(device: device, fontName: fontFamily, fontSize: fontSize, scale: scale, mascot: true,
                         backgroundOpacity: 0)
        }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = makeRenderer(device: device) ?? {
                  fontMissing = true
                  fontFamily = Config().fontFamily
                  return makeRenderer(device: device)
              }(),
              let session = TerminalSession(cols: UInt16(config.cols), rows: UInt16(config.rows), cwd: cwd, config: config)
        else { return nil }
        let view = TerminalView(session: session, renderer: renderer)
        terminals.add(view)
        return view
    }
}

extension AppDelegate: NSWindowRestoration {
    /// The system brings back a window that was open at the last quit: a new window with one tab, which is then put
    /// where that window was, at its size, and full screen if it was (didDecodeRestorableState).
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        completionHandler((NSApp.delegate as? AppDelegate)?.makeWindow(), nil)
    }
}
