import AppKit

/// The window's sidebar: a source list of the tabs, each with its name, a dot while it has output not seen yet, and
/// the directory and program of its focused pane under them (design M5), under a heading with the button for a new
/// tab. The list's look, selection and hover are AppKit's own. A row shows a close button while the pointer is on it,
/// the middle button closes it too, and a row can be dragged to another place, as the tabs along the top can. AppKit's
/// sidebar glass shows what is behind the window, not upaa's gradient, so the sidebar lays the window's ground (the
/// gradient and the card, lined up with the window's) under a pane of the design's glass color.
final class TabList: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    /// A row was picked by the user.
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    /// Fills a row's menu (a right click).
    var onMenu: ((Int, NSMenu) -> Void)?
    private var items: [Item] = []
    /// What the owner showed while a row was being dragged, shown once the drag ends.
    private var pending: (items: [Item], selected: Int)?
    private let table = Table()
    /// Set while the rows are being replaced, so that the new selection is not taken as the user's.
    private var reloading = false
    private let ground = Backdrop(frame: .zero)
    private var groundPinned = false

    /// background is the card's color, as in the rest of the window.
    init(background: NSColor) {
        super.init(nibName: nil, bundle: nil)
        let card = Fill(background)
        ground.addSubview(card)
        card.pin(to: ground)
        let glass = Fill(NSColor(name: nil) {
            $0.isDark ? NSColor(red: 60 / 255, green: 60 / 255, blue: 67 / 255, alpha: 0.45) : NSColor(white: 1, alpha: 0.5)
        })
        ground.addSubview(glass)
        glass.pin(to: ground)
        let column = NSTableColumn(identifier: .init("tab"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.style = .sourceList
        table.headerView = nil
        table.rowHeight = 40
        table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        // The keyboard stays with the terminal.
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        // The selection follows the moved row, which is not the user picking another tab.
        table.onMove = { [weak self] from, to in
            guard let self else { return }
            self.items.insert(self.items.remove(at: from), at: to)
            self.reloading = true
            self.table.moveRow(at: from, to: to)
            self.reloading = false
        }
        table.onMoved = { [weak self] from, to in
            guard let self else { return }
            if from != to { self.onMove?(from, to) }
            if let pending = self.pending { self.show(pending.items, selected: pending.selected) }
        }
        table.menu = NSMenu()
        table.menu?.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func loadView() {
        // The plus button's action goes up the responder chain to the window's TabbedWindow.
        let plus = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: String(localized: "New Tab"))!,
                            target: nil, action: #selector(TabbedWindow.newTab(_:)))
        plus.isBordered = false
        plus.contentTintColor = .secondaryLabelColor
        plus.toolTip = String(localized: "New Tab (⌘T)")
        let heading = NSStackView(views: [
            Chrome.label(String(localized: "Tabs"), size: 11, weight: .semibold, color: .secondaryLabelColor), NSView(), plus,
        ])
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Chrome.tabPanelWidth, height: 400))
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        for subview in [ground, heading, scroll] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        // The safe area keeps the heading below the traffic lights and the toolbar.
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            heading.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            heading.heightAnchor.constraint(equalToConstant: 24),
            scroll.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }

    /// The ground covers the window's content, so that its gradient lines up with the one beside the sidebar.
    override func viewWillAppear() {
        super.viewWillAppear()
        guard !groundPinned, let content = view.window?.contentView else { return }
        groundPinned = true
        NSLayoutConstraint.activate([
            ground.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            ground.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            ground.topAnchor.constraint(equalTo: content.topAnchor),
            ground.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    typealias Item = (title: String, detail: String, unseen: Bool)

    /// While a row is being dragged, the rows stay as the drag left them, and the last ones shown come once it ends.
    func show(_ items: [Item], selected: Int) {
        guard !table.dragging else { return pending = (items, selected) }
        pending = nil
        reloading = true
        // Rows rebuilt under the pointer would lose its hover, so only a change in a row rebuilds them.
        if !items.elementsEqual(self.items, by: { $0 == $1 }) {
            self.items = items
            table.reloadData()
        }
        table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        reloading = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let title = Chrome.label(item.title, size: 13)
        let line = NSStackView(views: [title])
        line.spacing = 6
        if item.unseen {
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill",
                                                 accessibilityDescription: String(localized: "New output"))!)
            dot.symbolConfiguration = .init(pointSize: 6, weight: .regular)
            dot.contentTintColor = .controlAccentColor
            line.addArrangedSubview(dot)
        }
        let stack = NSStackView(views: [line, Chrome.label(item.detail, size: 11, mono: true, color: .secondaryLabelColor)])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        let cell = Row()
        cell.textField = title
        cell.onClose = { [weak self, weak cell] in
            guard let self, let cell else { return }
            let row = self.table.row(for: cell)
            if row >= 0 { self.onClose?(row) }
        }
        cell.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.close.leadingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The menu is made each time for the row clicked.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if table.clickedRow >= 0 { onMenu?(table.clickedRow, menu) }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, table.selectedRow >= 0 else { return }
        onSelect?(table.selectedRow)
    }
}

/// The tab list's table, which moves a row held down and dragged among the others as the pointer goes: the held row
/// takes the place under the pointer, and the table animates the others out of its way. A click selects the row at
/// once, as the table's own does. AppKit's own row dragging is not used: its picture of the row jumped away from the
/// pointer as the drag started.
private final class Table: NSTableView {
    /// The held row has moved one place; the table and its rows are to follow.
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    /// The pointer let go of a row that was dragged, to the same place or another.
    var onMoved: ((_ from: Int, _ to: Int) -> Void)?
    private var held: (from: Int, row: Int, start: CGFloat, moved: Bool)?
    var dragging: Bool { held?.moved == true }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point)
        guard row >= 0 else { return super.mouseDown(with: event) }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        held = (row, row, point.y, false)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var hold = held else { return }
        let y = convert(event.locationInWindow, from: nil).y
        guard hold.moved || abs(y - hold.start) > 4 else { return }
        hold.moved = true
        // Above the first row or below the last, the row goes to that end; between two rows, it stays.
        let last = numberOfRows - 1
        let under = y < 0 ? 0 : y >= rect(ofRow: last).maxY ? last : row(at: NSPoint(x: bounds.midX, y: y))
        // The table's own row animation is longer, and lagged behind the pointer; this is the one the tabs along the
        // top slide with.
        if under >= 0, under != hold.row {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Chrome.animation
                onMove?(hold.row, under)
            }
            hold.row = under
        }
        held = hold
    }

    override func mouseUp(with event: NSEvent) {
        guard let hold = held else { return super.mouseUp(with: event) }
        held = nil
        if hold.moved { onMoved?(hold.from, hold.row) }
    }
}

/// A tab's row, with a close button at its right while the pointer is on it.
private final class Row: NSTableCellView {
    let close = NSButton()
    var onClose: (() -> Void)?

    init() {
        super.init(frame: .zero)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
        close.isBordered = false
        close.isHidden = true
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = String(localized: "Close Tab")
        close.target = self
        close.action = #selector(closeTab)
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 16),
            close.heightAnchor.constraint(equalToConstant: 16),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func mouseEntered(with event: NSEvent) { close.isHidden = false }

    override func mouseExited(with event: NSEvent) { close.isHidden = true }

    override func otherMouseUp(with event: NSEvent) { onClose?() }

    @objc private func closeTab() { onClose?() }
}
