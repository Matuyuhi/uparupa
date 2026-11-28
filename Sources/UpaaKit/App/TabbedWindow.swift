import AppKit

/// One window with tabs, laid out as design M5 on AppKit's own window parts. A tab is one terminal, or split views with
/// terminals (panes) at their ends. Each pane has its own shell, and a tab is named after the title its focused pane's
/// program set.
/// A split view controller holds the tab list as its sidebar, the selected tab in the middle with a footer under it
/// (the shell, the focused pane's size, what in the config could not be used and the main keys), and the changed files
/// of the focused pane's git repository as the right panel (Cmd-J). The toolbar holds the split buttons and the right
/// panel's, and shows the tab's name with its directory and branch. Cmd-B hides the tab list, and the tabs move into
/// the toolbar, in place of the title (design A3, tabs along the top). Where the traffic lights, the glass, the toolbar
/// and the panels go, and how they move, is AppKit's. Behind them all is one card of the terminal's background color,
/// translucent over a color gradient; the terminal draws no background of its own and runs up under the toolbar, its
/// text below it.
/// The menu actions reach this object through the responder chain, as the window's delegate.
final class TabbedWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private final class Tab {
        /// The terminal, or the split view that holds the tab's panes.
        var top: NSView
        /// The pane that has (or last had) the keyboard.
        var focus: TerminalView
        /// A pane wrote to its screen while another tab was shown, and the tab has not been shown since.
        var unseen = false

        init(_ terminal: TerminalView) {
            top = terminal
            focus = terminal
        }

        /// Panes from left to right, top to bottom.
        var panes: [TerminalView] { terminals(in: top) }
    }

    private let window: NSWindow
    /// Makes a terminal whose shell starts in the given directory.
    private let makeTerminal: (String?) -> TerminalView?
    private var tabs: [Tab] = []
    private var selected = 0
    /// Closed tabs, the last closed at the end: where each was in the order and its focused pane's directory.
    private var closed: [(index: Int, cwd: String)] = []
    /// The window closed (its last tab closed, or the window itself).
    var onClose: (() -> Void)?
    private var timer: Timer?

    /// The tab list, the selected tab and the right panel, side by side.
    private let columns = NSSplitViewController()
    private let tabList: TabList
    /// The tabs in the toolbar while the tab list is hidden.
    private let tabStrip = TabStrip()
    /// The host's left and right edges, moved in from the window's edges while the tabs are along the top.
    private var hostEdges: [NSLayoutConstraint] = []
    /// Holds the selected tab's view.
    private let host = Host()
    private let sizeLabel = Chrome.label("", size: 11, mono: true, color: .secondaryLabelColor)
    /// The first of the problems, and how many more. A click opens Settings, which lists them all.
    private let problemButton = NSButton(title: "", image: NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                                   accessibilityDescription: nil)!,
                                         target: nil, action: #selector(AppDelegate.showSettings(_:)))
    /// What in the config could not be used. The footer shows it until a reload of the config finds none.
    var problems: [String] = [] {
        didSet {
            problemButton.isHidden = problems.isEmpty
            guard let first = problems.first else { return }
            problemButton.title = problems.count == 1 ? first : String(localized: "\(first) (\(problems.count - 1) more)")
            problemButton.toolTip = problems.joined(separator: "\n")
        }
    }
    private let changes = ChangesPanel()
    private var panel: NSSplitViewItem!
    /// The focused pane's branch, from the last read of the changes.
    private var branch: String?

    /// background is the card's color: the terminal's default background, as translucent as the config says.
    init(window: NSWindow, first: TerminalView, background: NSColor, makeTerminal: @escaping (String?) -> TerminalView?) {
        self.window = window
        self.makeTerminal = makeTerminal
        tabList = TabList(background: background)
        super.init()

        // The window was made to fit the terminal; the parts around it are added here.
        let terminalSize = window.contentRect(forFrameRect: window.frame).size
        let root = NSViewController()
        // Sized to the terminal, so that the window does not shrink below its title bar when the root is set.
        root.view = Backdrop(frame: NSRect(origin: .zero, size: terminalSize))
        let card = Fill(background)
        root.view.addSubview(card)
        card.pin(to: root.view)
        root.addChild(columns)
        root.view.addSubview(columns.view)
        columns.view.pin(to: root.view)

        let sidebar = NSSplitViewItem(sidebarWithViewController: tabList)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 360
        if #available(macOS 14.0, *) {
            panel = NSSplitViewItem(inspectorWithViewController: Self.controller(changes, inset: 8))
        } else {
            panel = NSSplitViewItem(viewController: Self.controller(changes, inset: 8))
            panel.canCollapse = true
        }
        panel.minimumThickness = Chrome.sidePanelWidth
        panel.maximumThickness = 480
        panel.isCollapsed = true
        columns.splitViewItems = [sidebar, NSSplitViewItem(viewController: terminalArea()), panel]
        tabStrip.onSelect = { [weak self] index in
            guard let self, index != self.selected else { return }
            self.select(index)
        }
        tabStrip.onClose = { [weak self] index in
            guard let self else { return }
            let tab = self.tabs[index]
            self.ask(String(localized: "Close this tab?"), about: tab.panes) { [weak self] in
                if let self, let index = self.tabs.firstIndex(where: { $0 === tab }) { self.closeTab(at: index) }
            }
        }
        tabStrip.onMove = { [weak self] in self?.moveTab(from: $0, to: $1) }
        tabList.onClose = tabStrip.onClose
        tabList.onMove = tabStrip.onMove
        NotificationCenter.default.addObserver(self, selector: #selector(placeTabs(_:)),
                                               name: NSSplitView.didResizeSubviewsNotification, object: columns.splitView)
        tabList.onSelect = { [weak self] index in
            guard let self, index != self.selected else { return }
            self.select(index)
        }
        changes.onUpdate = { [weak self] branch, count in
            guard let self else { return }
            // A mark on the right panel's button that the focused pane's repository has changes (macOS 26 and later).
            if #available(macOS 26.0, *) {
                let item = self.window.toolbar?.items.first { $0.itemIdentifier == Self.panelButton }
                item?.badge = count > 0 ? .count(count) : nil
            }
            guard branch != self.branch else { return }
            self.branch = branch
            self.refresh()
        }

        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.contentViewController = root
        let toolbar = NSToolbar(identifier: "upaa")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.delegate = self
        // The terminal runs under the toolbar, so the window is taller by the toolbar, and wider by the tab list.
        let toolbarHeight = window.frame.height - window.contentLayoutRect.height
        window.setContentSize(NSSize(
            width: terminalSize.width + Chrome.tabPanelWidth + columns.splitView.dividerThickness,
            height: terminalSize.height + toolbarHeight + Chrome.footerHeight))
        root.view.layoutSubtreeIfNeeded()
        columns.splitView.setPosition(Chrome.tabPanelWidth, ofDividerAt: 0)
        windowDidResize(Notification(name: NSWindow.didResizeNotification))

        watch(first)
        tabs.append(Tab(first))
        select(0)
        // The tabs follow the shells' directories and programs, and the panel the files, without a signal from any.
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refresh()
            self?.readChanges()
        }
    }

    /// The tabs along the top get the window's width less what the traffic lights and the buttons beside them take.
    func windowDidResize(_ notification: Notification) {
        tabStrip.room = max(0, window.frame.width - 340)
        window.invalidateRestorableState()
    }

    /// The frame kept for the system's saved window (willEncodeRestorableState) is kept again after a move or a resize.
    func windowDidMove(_ notification: Notification) {
        window.invalidateRestorableState()
    }

    /// The system's saved window comes back at the frame it had when it was made, so the frame is kept here as well
    /// and put back once the system has restored the window. A full-screen window is left to the system.
    func window(_ window: NSWindow, willEncodeRestorableState state: NSCoder) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        state.encode(window.frameDescriptor, forKey: "frame")
    }

    func window(_ window: NSWindow, didDecodeRestorableState state: NSCoder) {
        guard let frame = state.decodeObject(of: NSString.self, forKey: "frame") else { return }
        window.setFrame(from: frame as String)
        Self.keepOnScreen(window)
    }

    /// The window's close button and Cmd-Shift-W ask first while a program runs in one of its panes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard running.isEmpty else {
            ask(String(localized: "Close this window?"), about: tabs.flatMap(\.panes)) { [weak self] in self?.window.close() }
            return false
        }
        return true
    }

    /// The programs running in the panes, other than their shells.
    var running: [String] { tabs.flatMap(\.panes).compactMap(\.session.running) }

    /// Does then at once when no pane among panes runs a program other than its shell; otherwise asks first, in a
    /// sheet, as Terminal does, since closing ends those programs.
    private func ask(_ question: String, about panes: [TerminalView], then: @escaping () -> Void) {
        let running = panes.compactMap(\.session.running)
        guard !running.isEmpty else { return then() }
        Self.alert(question, button: String(localized: "Close"), running: running).beginSheetModal(for: window) {
            if $0 == .alertFirstButtonReturn { then() }
        }
    }

    /// Asks whether to end the programs named, with the button that does it and Cancel.
    static func alert(_ question: String, button: String, running: [String]) -> NSAlert {
        let names = running.filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let alert = NSAlert()
        alert.messageText = question
        alert.informativeText = names.isEmpty
            ? String(localized: "A program is running. Closing will end it.")
            : String(localized: "\(ListFormatter.localizedString(byJoining: names)) is running. Closing will end it.")
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert
    }

    func windowWillClose(_ notification: Notification) {
        Self.saveFrame(of: window)
        timer?.invalidate()
        onClose?()
    }

    /// The name of the frame that a launch opens its window at when the system brings back none.
    static let frameName = "upaa"

    /// Keeps where the window is and its size for the next launch, unless it is full screen, which fills its screen.
    /// The window closed or quit last wins.
    static func saveFrame(of window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        window.saveFrame(usingName: frameName)
    }

    /// A window that a frame saved with other screens would leave partly off the screen comes back onto the screen it
    /// is mostly on, or the main one, made smaller if it does not fit.
    static func keepOnScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size = NSSize(width: min(frame.width, visible.width), height: min(frame.height, visible.height))
        frame.origin = NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
                               y: min(max(frame.minY, visible.minY), visible.maxY - frame.height))
        if frame != window.frame { window.setFrame(frame, display: false) }
    }

    /// The middle of the window: the selected tab, and the footer under it with the shell, the focused pane's size and
    /// the main keys, its text in line with the terminal's.
    private func terminalArea() -> NSViewController {
        let space = NSView()
        space.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [
            Chrome.label(Self.shell, size: 11, color: .secondaryLabelColor), sizeLabel,
            Chrome.label("UTF-8", size: 11, color: .secondaryLabelColor), space, problemButton,
            Chrome.label(String(localized: "⌘D Split · ⌘F Find · ⌘B Tabs"), size: 11, color: .secondaryLabelColor),
        ])
        footer.spacing = 14
        problemButton.isBordered = false
        problemButton.imagePosition = .imageLeading
        problemButton.font = .systemFont(ofSize: 11)
        problemButton.symbolConfiguration = .init(pointSize: 10, weight: .regular)
        problemButton.contentTintColor = Chrome.warning
        problemButton.lineBreakMode = .byTruncatingTail
        problemButton.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        problemButton.isHidden = problems.isEmpty
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        for subview in [host, footer] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        hostEdges = [host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                     view.trailingAnchor.constraint(equalTo: host.trailingAnchor)]
        NSLayoutConstraint.activate(hostEdges + [
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: Renderer.paddingPoints.horizontal),
            footer.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -Renderer.paddingPoints.horizontal),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Chrome.footerHeight),
        ])
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    /// A controller whose view holds content inside its safe area (below the toolbar), inset on the other sides.
    private static func controller(_ content: NSView, inset: CGFloat) -> NSViewController {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Chrome.sidePanelWidth, height: 400))
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let controller = NSViewController()
        controller.view = view
        return controller
    }

    // MARK: Toolbar

    private static let tabsEdge = NSToolbarItem.Identifier("tabsEdge")
    private static let tabsItem = NSToolbarItem.Identifier("tabs")
    private static let newTabButton = NSToolbarItem.Identifier("newTab")
    private static let splitRight = NSToolbarItem.Identifier("splitRight")
    private static let splitDown = NSToolbarItem.Identifier("splitDown")
    private static let findButton = NSToolbarItem.Identifier("find")
    private static let panelEdge = NSToolbarItem.Identifier("panelEdge")
    private static let panelButton = NSToolbarItem.Identifier("panel")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.tabsEdge, .flexibleSpace, Self.splitRight, Self.splitDown, Self.findButton, Self.panelEdge, Self.panelButton]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [Self.tabsItem, Self.newTabButton]
    }

    /// The two edges follow the dividers, so the title starts at the tab list's edge and the panel button sits over
    /// the right panel when it shows.
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.tabsEdge: return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: columns.splitView, dividerIndex: 0)
        case Self.panelEdge: return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: columns.splitView, dividerIndex: 1)
        case Self.splitRight: return button(identifier, "rectangle.split.2x1", String(localized: "Split Right (⌘D)"), #selector(splitRight(_:)))
        case Self.splitDown: return button(identifier, "rectangle.split.1x2", String(localized: "Split Down (⇧⌘D)"), #selector(splitDown(_:)))
        case Self.findButton: return button(identifier, "magnifyingglass", String(localized: "Find (⌘F)"), #selector(showFindBar(_:)))
        case Self.panelButton: return button(identifier, "sidebar.right", String(localized: "Changes Panel (⌘J)"), #selector(toggleSidePanel(_:)))
        case Self.newTabButton: return button(identifier, "plus", String(localized: "New Tab (⌘T)"), #selector(newTab(_:)))
        case Self.tabsItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = tabStrip
            item.label = String(localized: "Tabs")
            return item
        default: return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ symbol: String, _ name: String, _ action: Selector)
        -> NSToolbarItem
    {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: name)
        item.label = name
        item.toolTip = name
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    /// With the tab list hidden (Cmd-B, or its divider dragged to the edge), the tabs and the new tab button go into
    /// the toolbar beside the traffic lights, in place of the window's title, the tabs widening from nothing; shown
    /// again, they fade out and go back.
    @objc private func placeTabs(_ notification: Notification) {
        guard let toolbar = window.toolbar else { return }
        let top = columns.splitViewItems[0].isCollapsed
        let shown = toolbar.items.contains { $0.itemIdentifier == Self.tabsItem }
        if top, !shown {
            toolbar.insertItem(withItemIdentifier: Self.newTabButton, at: 1)
            toolbar.insertItem(withItemIdentifier: Self.tabsItem, at: 1)
            window.titleVisibility = .hidden
        } else if top, tabStrip.alphaValue < 1 {
            // The tab list was hidden again while the tabs faded out.
            tabStrip.animator().alphaValue = 1
        } else if !top, shown, tabStrip.alphaValue == 1 {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Chrome.animation
                self.tabStrip.animator().alphaValue = 0
            }) { [weak self] in
                guard let self, !self.columns.splitViewItems[0].isCollapsed else { return }
                for identifier in [Self.tabsItem, Self.newTabButton] {
                    if let index = toolbar.items.firstIndex(where: { $0.itemIdentifier == identifier }) { toolbar.removeItem(at: index) }
                }
                self.tabStrip.alphaValue = 1
                self.window.titleVisibility = .visible
            }
        }
        // Design A3 puts the text 18 from the window's edges with the tabs along the top; the terminal keeps 8 itself.
        let edge: CGFloat = top ? 10 : 0
        if hostEdges[0].constant != edge { hostEdges.forEach { $0.animator().constant = edge } }
    }

    // MARK: Menu actions

    /// Opens a tab to the right of the selected one, in the focused pane's directory.
    @objc func newTab(_ sender: Any?) {
        guard let terminal = makeTerminal(tabs[selected].focus.session.cwd) else { return NSSound.beep() }
        watch(terminal)
        tabs.insert(Tab(terminal), at: selected + 1)
        select(selected + 1)
    }

    /// Cmd-Shift-T. Opens the last closed tab again in its place, with a new shell in its directory; the program that
    /// ran in it and its scrollback are gone.
    @objc func reopenClosedTab(_ sender: Any?) {
        guard let last = closed.popLast(), let terminal = makeTerminal(last.cwd) else { return NSSound.beep() }
        watch(terminal)
        let index = min(last.index, tabs.count)
        tabs.insert(Tab(terminal), at: index)
        select(index)
    }

    /// Closes the focused pane, and the tab with its last pane, asking first while it runs a program.
    @objc func closePane(_ sender: Any?) {
        let pane = tabs[selected].focus
        ask(String(localized: "Close this pane?"), about: [pane]) { [weak self] in self?.close(pane) }
    }

    /// Puts a new pane to the right of the focused one.
    @objc func splitRight(_ sender: Any?) {
        split(vertical: true)
    }

    /// Puts a new pane below the focused one.
    @objc func splitDown(_ sender: Any?) {
        split(vertical: false)
    }

    @objc func showNextPane(_ sender: Any?) {
        movePane(by: 1)
    }

    @objc func showPreviousPane(_ sender: Any?) {
        movePane(by: -1)
    }

    @objc func showNextTab(_ sender: Any?) {
        select((selected + 1) % tabs.count)
    }

    @objc func showPreviousTab(_ sender: Any?) {
        select((selected + tabs.count - 1) % tabs.count)
    }

    /// Cmd-1 to Cmd-9, from the menu item's tag. Cmd-9 is the last tab.
    @objc func showTab(_ sender: NSMenuItem) {
        let index = sender.tag == 9 ? tabs.count - 1 : sender.tag - 1
        guard index < tabs.count else { return NSSound.beep() }
        select(index)
    }

    /// The toolbar's find button, and Cmd-F while no pane has the keyboard: the focused pane's find bar.
    @objc func showFindBar(_ sender: Any?) {
        tabs[selected].focus.showFindBar(sender)
    }

    /// Cmd-J. Shows or hides the right panel, as AppKit animates a split view's panel.
    @objc func toggleSidePanel(_ sender: Any?) {
        panel.animator().isCollapsed = !panel.isCollapsed
        readChanges()
    }

    // MARK: Tabs and panes

    /// Follows the pane's title, output, focus and shell. Its shell exiting closes the pane.
    private func watch(_ terminal: TerminalView) {
        terminal.session.onTitle = { [weak self] in self?.refresh() }
        terminal.onOutput = { [weak self, weak terminal] in
            guard let self, let terminal, let tab = self.tab(of: terminal), tab !== self.tabs[self.selected],
                  !tab.unseen else { return }
            tab.unseen = true
            self.refresh()
        }
        terminal.onResize = { [weak self] in self?.showSize() }
        terminal.onFocus = { [weak self, weak terminal] in
            guard let self, let terminal, let tab = self.tab(of: terminal) else { return }
            tab.focus = terminal
            self.refresh()
            self.readChanges()
        }
        terminal.session.onExit = { [weak self, weak terminal] in
            if let self, let terminal { self.close(terminal) }
        }
    }

    private func tab(of terminal: TerminalView) -> Tab? {
        tabs.first { terminal.isDescendant(of: $0.top) }
    }

    private func split(vertical: Bool) {
        let tab = tabs[selected]
        let pane = tab.focus
        guard let terminal = makeTerminal(pane.session.cwd) else { return NSSound.beep() }
        watch(terminal)
        let parent: NSSplitView
        if let split = pane.superview as? NSSplitView, split.isVertical == vertical {
            parent = split
            parent.insertArrangedSubview(terminal, at: parent.arrangedSubviews.firstIndex(of: pane)! + 1)
        } else {
            parent = NSSplitView()
            parent.isVertical = vertical
            parent.dividerStyle = .thin
            replace(pane, with: parent, in: tab)
            parent.addArrangedSubview(pane)
            parent.addArrangedSubview(terminal)
        }
        equalize(parent)
        window.makeFirstResponder(terminal)
    }

    /// Gives every pane of the split view the same size.
    private func equalize(_ split: NSSplitView) {
        window.contentView?.layoutSubtreeIfNeeded()
        let count = split.arrangedSubviews.count
        let length = (split.isVertical ? split.bounds.width : split.bounds.height) - CGFloat(count - 1) * split.dividerThickness
        for index in 0..<(count - 1) {
            split.setPosition(length * CGFloat(index + 1) / CGFloat(count) + CGFloat(index) * split.dividerThickness, ofDividerAt: index)
        }
    }

    /// Puts view where old was: in old's split view, or as the tab's top view.
    private func replace(_ old: NSView, with view: NSView, in tab: Tab) {
        if let split = old.superview as? NSSplitView {
            let index = split.arrangedSubviews.firstIndex(of: old)!
            old.removeFromSuperview()
            split.insertArrangedSubview(view, at: index)
        } else {
            let shown = old.superview != nil
            old.removeFromSuperview()
            tab.top = view
            if shown { show(tab) }
        }
    }

    private func movePane(by step: Int) {
        let tab = tabs[selected]
        let panes = tab.panes
        guard let index = panes.firstIndex(of: tab.focus), panes.count > 1 else { return }
        window.makeFirstResponder(panes[(index + step + panes.count) % panes.count])
    }

    /// Closes the pane; a tab's last pane closes the tab, and the last tab closes the window.
    /// A view and its session go away once they leave the window, which ends the shell.
    private func close(_ terminal: TerminalView) {
        guard let index = tabs.firstIndex(where: { terminal.isDescendant(of: $0.top) }) else { return }
        let tab = tabs[index]
        guard terminal !== tab.top, let split = terminal.superview as? NSSplitView else {
            return closeTab(at: index)
        }
        terminal.removeFromSuperview()
        if split.arrangedSubviews.count == 1, let only = split.arrangedSubviews.first {
            only.removeFromSuperview()
            replace(split, with: only, in: tab)
        } else {
            equalize(split)
        }
        if tab.focus === terminal { tab.focus = tab.panes[0] }
        if index == selected { window.makeFirstResponder(tab.focus) }
        refresh()
    }

    /// A tab whose shell has exited has no directory to open again in, and is not kept for Cmd-Shift-T.
    private func closeTab(at index: Int) {
        if let cwd = tabs[index].focus.session.cwd { closed.append((index, cwd)) }
        tabs[index].top.removeFromSuperview()
        tabs.remove(at: index)
        guard !tabs.isEmpty else { return window.close() }
        select(index < selected || selected == tabs.count ? selected - 1 : selected)
    }

    /// A tab dragged to another place, in the tab list or along the top.
    private func moveTab(from: Int, to: Int) {
        let current = tabs[selected]
        tabs.insert(tabs.remove(at: from), at: to)
        selected = tabs.firstIndex { $0 === current }!
        refresh()
    }

    private func select(_ index: Int) {
        let tab = tabs[index]
        if tab.top.superview == nil { show(tab) }
        selected = index
        tab.unseen = false
        window.makeFirstResponder(tab.focus)
        refresh()
        readChanges()
    }

    /// Puts the tab in the host, in place of the one shown. A pane that was in a split view keeps what the split view
    /// set on it, so the host sizes its view directly rather than through autoresizing or constraints.
    private func show(_ tab: Tab) {
        host.subviews.forEach { $0.removeFromSuperview() }
        tab.top.translatesAutoresizingMaskIntoConstraints = true
        tab.top.autoresizingMask = []
        host.addSubview(tab.top)
        host.needsLayout = true
    }

    /// Reads the git state of the focused pane's directory, for the panel, the change count and the branch.
    private func readChanges() {
        guard window.occlusionState.contains(.visible) else { return }
        changes.refresh(directory: tabs[selected].focus.session.cwd)
    }

    // MARK: Layout

    /// Brings the tab list, the panes and the window's title up to date.
    private func refresh() {
        let tab = tabs[selected]
        let titles = tabs.map(name(of:))
        window.title = titles[selected]
        window.subtitle = [place(of: tab), branch ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        tabList.show(zip(titles, tabs).map { (title: $0, detail: detail(of: $1), unseen: $1.unseen) },
                     selected: selected)
        tabStrip.show(zip(tabs, titles).map { (id: ObjectIdentifier($0), title: $1, unseen: $0.unseen) },
                      selected: selected)

        // A split or a closed pane can change which panes are along the top.
        host.needsLayout = true
        let panes = tab.panes
        for pane in panes { pane.alphaValue = panes.count == 1 || pane === tab.focus ? 1 : Chrome.inactivePaneAlpha }
        showSize()
    }

    private func showSize() {
        guard selected < tabs.count else { return }
        let size = tabs[selected].focus.gridSize
        sizeLabel.stringValue = "\(size.cols)×\(size.rows)"
    }

    /// The shell the panes start, as the footer and the tab list name it.
    private static let shell =
        ProcessInfo.processInfo.environment["SHELL"].map { ($0 as NSString).lastPathComponent } ?? "sh"

    /// The title the focused pane's program set, or else the name of the program, as in the tab list's second line.
    private func name(of tab: Tab) -> String {
        tab.focus.session.title ?? tab.focus.session.running.flatMap { $0.isEmpty ? nil : $0 } ?? "upaa"
    }

    /// The tab list's second line: the focused pane's directory and the program running in it, or its shell while
    /// the shell waits for input.
    private func detail(of tab: Tab) -> String {
        [place(of: tab), tab.focus.session.running ?? Self.shell].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The focused pane's directory, with ~ for home.
    private func place(of tab: Tab) -> String {
        let place = tab.focus.session.cwd ?? ""
        let home = NSHomeDirectory()
        return place.hasPrefix(home) ? "~" + place.dropFirst(home.count) : place
    }
}

/// Holds the selected tab's view and gives it all of its own size each time it is laid out. The host runs up under
/// the toolbar, so the panes along its top keep their text below the toolbar.
private final class Host: NSView {
    override func layout() {
        super.layout()
        // The window's layout rect is the part that no toolbar covers.
        let covered = window.map { max(0, bounds.maxY - convert($0.contentLayoutRect, from: nil).maxY) } ?? 0
        for view in subviews {
            view.frame = bounds
            view.layoutSubtreeIfNeeded()
            for pane in terminals(in: view) {
                let touchesTop = abs(pane.convert(pane.bounds, to: self).maxY - bounds.maxY) < 1
                pane.topInset = touchesTop ? covered : 0
            }
        }
    }
}

/// The terminals in a tab's view, from left to right and top to bottom.
private func terminals(in view: NSView) -> [TerminalView] {
    if let terminal = view as? TerminalView { return [terminal] }
    return (view as? NSSplitView)?.arrangedSubviews.flatMap(terminals(in:)) ?? []
}
