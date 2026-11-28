import AppKit
import CUpaaCore

/// Entry point of the app. The executable (Sources/upaa/main.swift) calls only this.
///
/// Arguments:
///   --version                            Print the version and exit
///   --snapshot <png> [--command <command>] [--input <string>]
///                                        Send a string to the shell (or to --command if given), write the resulting screen to a PNG, and exit
///   --compare-png <baseline> <current> [--max-diff <ratio>]
///                                        Compare two PNGs. Fail if the ratio of differing pixels exceeds the limit (default 0.01)
///   --bench-headless <file> [--max-frame-ms <ms>] [--min-mb-per-s <MB/s>]
///                                        Without a window, measure how fast the file is cat'ed and how long one frame takes to build. Fail if outside the upper or lower limit
public enum UpaaApp {
    public static func main() -> Never {
        let arguments = CommandLine.arguments

        if arguments.contains("--version") {
            print(String(cString: upaa_version()))
            exit(0)
        }

        let defaults = Config()
        do {
            if let path = value(after: "--snapshot", in: arguments) {
                try Snapshot.write(
                    to: URL(fileURLWithPath: path), cols: defaults.cols, rows: defaults.rows,
                    command: value(after: "--command", in: arguments), input: value(after: "--input", in: arguments))
                exit(0)
            }

            if let index = arguments.firstIndex(of: "--compare-png"), index + 2 < arguments.count {
                let difference = try Snapshot.difference(
                    URL(fileURLWithPath: arguments[index + 1]), URL(fileURLWithPath: arguments[index + 2]))
                let limit = value(after: "--max-diff", in: arguments).flatMap(Double.init) ?? 0.01
                print(String(format: "Differing pixels: %.4f%% (limit %.4f%%)", difference * 100, limit * 100))
                exit(difference <= limit ? 0 : 1)
            }

            if let file = value(after: "--bench-headless", in: arguments) {
                let result = try Snapshot.bench(file: file, cols: defaults.cols, rows: defaults.rows)
                let maxFrame = value(after: "--max-frame-ms", in: arguments).flatMap(Double.init) ?? .infinity
                let minSpeed = value(after: "--min-mb-per-s", in: arguments).flatMap(Double.init) ?? 0
                print(String(format: "cat (no rendering): %.1f MB/s (min %.1f)", result.megabytesPerSecond, minSpeed))
                print(String(format: "1 frame build: %.3f ms (max %.1f)", result.frameMilliseconds, maxFrame))
                exit(result.megabytesPerSecond >= minSpeed && result.frameMilliseconds <= maxFrame ? 0 : 1)
            }
        } catch {
            FileHandle.standardError.write(Data("upaa: \(error)\n".utf8))
            exit(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.mainMenu = makeMainMenu()
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
        exit(0)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        // The items every Mac app has, in their usual order.
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "About upaa"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Settings…"), action: #selector(AppDelegate.showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(.separator())
        let services = NSMenu(title: String(localized: "Services"))
        appMenu.addItem(withTitle: String(localized: "Services"), action: nil, keyEquivalent: "").submenu = services
        NSApplication.shared.servicesMenu = services
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Hide upaa"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: String(localized: "Hide Others"), action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: String(localized: "Show All"), action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: String(localized: "Quit upaa"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // New Window goes to AppDelegate; the tab and pane items go to the key window's TabbedWindow (its delegate).
        // The keys for upaa's own commands are all set here.
        let fileItem = NSMenuItem()
        fileItem.submenu = NSMenu(title: String(localized: "File"))
        fileItem.submenu?.addItem(withTitle: String(localized: "New Window"), action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n")
        fileItem.submenu?.addItem(withTitle: String(localized: "New Tab"), action: #selector(TabbedWindow.newTab(_:)), keyEquivalent: "t")
        fileItem.submenu?.addItem(withTitle: String(localized: "Reopen Closed Tab"), action: #selector(TabbedWindow.reopenClosedTab(_:)), keyEquivalent: "T")
        fileItem.submenu?.addItem(withTitle: String(localized: "Split Right"), action: #selector(TabbedWindow.splitRight(_:)), keyEquivalent: "d")
        fileItem.submenu?.addItem(withTitle: String(localized: "Split Down"), action: #selector(TabbedWindow.splitDown(_:)), keyEquivalent: "D")
        fileItem.submenu?.addItem(withTitle: String(localized: "Close"), action: #selector(TabbedWindow.closePane(_:)), keyEquivalent: "w")
        mainMenu.addItem(fileItem)

        // The actions go to the first responder (TerminalView).
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: String(localized: "Edit"))
        editItem.submenu?.addItem(withTitle: String(localized: "Copy"), action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
        editItem.submenu?.addItem(withTitle: String(localized: "Paste"), action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: String(localized: "Select All"), action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu?.addItem(.separator())
        let findMenu = NSMenu(title: String(localized: "Find"))
        findMenu.addItem(withTitle: String(localized: "Find…"), action: #selector(TerminalView.showFindBar(_:)), keyEquivalent: "f")
        findMenu.addItem(withTitle: String(localized: "Find Next"), action: #selector(TerminalView.findNextMatch(_:)), keyEquivalent: "g")
        findMenu.addItem(withTitle: String(localized: "Find Previous"), action: #selector(TerminalView.findPreviousMatch(_:)), keyEquivalent: "G")
        editItem.submenu?.addItem(withTitle: String(localized: "Find"), action: nil, keyEquivalent: "").submenu = findMenu
        mainMenu.addItem(editItem)

        let viewItem = NSMenuItem()
        viewItem.submenu = NSMenu(title: String(localized: "View"))
        // AppKit names the item Show or Hide Sidebar as the tab list is hidden or shown.
        viewItem.submenu?.addItem(withTitle: String(localized: "Show Sidebar"), action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "b")
        viewItem.submenu?.addItem(withTitle: String(localized: "Changes Panel"), action: #selector(TabbedWindow.toggleSidePanel(_:)), keyEquivalent: "j")
        viewItem.submenu?.addItem(withTitle: String(localized: "Links Panel"), action: #selector(TabbedWindow.toggleLinksPanel(_:)), keyEquivalent: "J")
        viewItem.submenu?.addItem(.separator())
        viewItem.submenu?.addItem(withTitle: String(localized: "Default Font Size"), action: #selector(AppDelegate.defaultFontSize(_:)), keyEquivalent: "0")
        viewItem.submenu?.addItem(withTitle: String(localized: "Bigger"), action: #selector(AppDelegate.biggerFont(_:)), keyEquivalent: "+")
        // Cmd-= as well, since + needs Shift on a US keyboard.
        let bigger = viewItem.submenu!.addItem(withTitle: String(localized: "Bigger"), action: #selector(AppDelegate.biggerFont(_:)), keyEquivalent: "=")
        bigger.isHidden = true
        bigger.allowsKeyEquivalentWhenHidden = true
        viewItem.submenu?.addItem(withTitle: String(localized: "Smaller"), action: #selector(AppDelegate.smallerFont(_:)), keyEquivalent: "-")
        mainMenu.addItem(viewItem)

        // upaa draws its own tabs, so AppKit's window tabs (and the menu items it adds for them) are turned off.
        NSWindow.allowsAutomaticWindowTabbing = false
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: String(localized: "Window"))
        windowMenu.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: String(localized: "Show Previous Pane"), action: #selector(TabbedWindow.showPreviousPane(_:)), keyEquivalent: "[")
        windowMenu.addItem(withTitle: String(localized: "Show Next Pane"), action: #selector(TabbedWindow.showNextPane(_:)), keyEquivalent: "]")
        windowMenu.addItem(withTitle: String(localized: "Show Previous Tab"), action: #selector(TabbedWindow.showPreviousTab(_:)), keyEquivalent: "{")
        windowMenu.addItem(withTitle: String(localized: "Show Next Tab"), action: #selector(TabbedWindow.showNextTab(_:)), keyEquivalent: "}")
        // Cmd-1 to Cmd-9 pick a tab without listing nine items in the menu.
        for number in 1...9 {
            let item = windowMenu.addItem(withTitle: "Show Tab \(number)", action: #selector(TabbedWindow.showTab(_:)), keyEquivalent: "\(number)")
            item.tag = number
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
        }
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApplication.shared.windowsMenu = windowMenu
        return mainMenu
    }
}
