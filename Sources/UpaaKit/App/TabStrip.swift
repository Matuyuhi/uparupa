import AppKit

/// The tabs along the top, in the toolbar while the tab list is hidden (design A3). A tab shows its name, a dot before
/// it while the tab has output not seen yet, and a close button while the pointer is on it; dragging a tab moves it
/// among the others, and the middle button closes it. A tab that opens widens from nothing and one that closes
/// narrows to nothing, and when they do not all fit, they all narrow, as tabs do in Safari.
final class TabStrip: NSView {
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    /// Fills a tab's menu (a right click).
    var onMenu: ((Int, NSMenu) -> Void)?
    /// The widest the strip may be, from the window's width.
    var room: CGFloat = 600 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// In order, with the closing ones still in their places until they have narrowed.
    private var tabs: [Tab] = []
    private var animation: Timer?
    /// The tab held down: where it was, where the pointer took it, and whether it has moved yet.
    private var held: (tab: Tab, from: Int, start: CGFloat, offset: CGFloat, moved: Bool)?
    /// What the owner showed while a tab was being dragged, shown once the drag ends.
    private var pending: (items: [Item], selected: Int)?

    private static let height: CGFloat = 28
    private static let gap: CGFloat = 2
    private static let widest: CGFloat = 200
    private static let narrowest: CGFloat = 44

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    typealias Item = (id: ObjectIdentifier, title: String, unseen: Bool)

    /// The tabs by their owner's identity, so that one that opens, closes or moves is told from the others. While a
    /// tab is being dragged, the tabs stay as the drag left them, and the last ones shown come once it ends.
    func show(_ items: [Item], selected: Int) {
        guard held?.moved != true else { return pending = (items, selected) }
        pending = nil
        let ids = items.map(\.id)
        for tab in tabs where !ids.contains(tab.id) { tab.target = 0 }
        var order: [Tab] = items.enumerated().map { index, item in
            let tab = tabs.first { $0.id == item.id && $0.target == 1 } ?? newTab(item.id)
            tab.title = item.title
            tab.unseen = item.unseen
            tab.isSelected = index == selected
            return tab
        }
        for (index, tab) in tabs.enumerated() where tab.target == 0 {
            let before = tabs[..<index].last { order.contains($0) }
            order.insert(tab, at: before.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
        }
        tabs = order
        animate()
    }

    /// Coming into the toolbar, the tabs widen from nothing.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        tabs.forEach { $0.shown = 0 }
        animate()
    }

    private func newTab(_ id: ObjectIdentifier) -> Tab {
        let tab = Tab(id: id)
        tab.onClose = { [weak self, weak tab] in
            if let self, let tab, let index = self.open.firstIndex(of: tab) { self.onClose?(index) }
        }
        addSubview(tab)
        return tab
    }

    /// The tabs that are not closing, which are the owner's tabs in the owner's order.
    private var open: [Tab] { tabs.filter { $0.target == 1 } }

    /// Moves each tab's width toward where it is going, over Chrome.animation; without a window, at once.
    private func animate() {
        guard window != nil else {
            tabs.forEach { $0.shown = $0.target }
            return settle()
        }
        guard animation == nil else { return }
        guard tabs.contains(where: { $0.shown != $0.target }) else { return settle() }
        var last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            let now = CACurrentMediaTime()
            let step = CGFloat((now - last) / Chrome.animation)
            last = now
            for tab in self.tabs {
                tab.shown = tab.target > tab.shown ? min(tab.target, tab.shown + step) : max(tab.target, tab.shown - step)
            }
            if self.tabs.allSatisfy({ $0.shown == $0.target }) {
                timer.invalidate()
                self.animation = nil
            }
            self.settle()
        }
        RunLoop.main.add(timer, forMode: .common)
        animation = timer
    }

    /// Lets the closed tabs go, and sizes and lays out the rest.
    private func settle() {
        tabs.removeAll { tab in
            guard tab.target == 0, tab.shown == 0 else { return false }
            tab.removeFromSuperview()
            return true
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// Each tab's width: its name's, shrunk with the others to fit the room, and eased in or out while it opens or
    /// closes.
    private func widths() -> [CGFloat] {
        let natural = tabs.map { min(Self.widest, $0.naturalWidth) * ease($0.shown) }
        let total = natural.reduce(0, +) + gaps
        let fit = total > room ? max(0, room - gaps) / max(1, natural.reduce(0, +)) : 1
        return zip(natural, tabs).map { max($0 * fit, Self.narrowest * ease($1.shown)) }
    }

    private var gaps: CGFloat { tabs.dropFirst().map { Self.gap * ease($0.shown) }.reduce(0, +) }

    private func ease(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: min(room, widths().reduce(0, +) + gaps), height: Self.height)
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (index, (tab, width)) in zip(tabs, widths()).enumerated() {
            if index > 0 { x += Self.gap * ease(tab.shown) }
            if tab !== held?.tab || held?.moved != true {
                tab.frame = NSRect(x: x, y: (bounds.height - Self.height) / 2, width: width, height: Self.height)
            }
            tab.alphaValue = ease(tab.shown)
            x += width
        }
    }

    // MARK: The pointer

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func pointer(_ event: NSEvent) -> CGFloat { convert(event.locationInWindow, from: nil).x }

    override func mouseDown(with event: NSEvent) {
        let x = pointer(event)
        guard let tab = open.first(where: { $0.frame.minX...$0.frame.maxX ~= x }) else { return }
        held = (tab, open.firstIndex(of: tab)!, x, x - tab.frame.minX, false)
    }

    /// The held tab follows the pointer, and the others make room for it where its middle is.
    override func mouseDragged(with event: NSEvent) {
        guard var hold = held else { return }
        let x = pointer(event)
        guard hold.moved || abs(x - hold.start) > 4 else { return }
        hold.moved = true
        held = hold
        let tab = hold.tab
        tab.frame.origin.x = min(max(0, x - hold.offset), bounds.width - tab.frame.width)
        let others = open.filter { $0 !== tab }
        let place = others.filter { $0.frame.midX < tab.frame.midX }.count
        guard place != open.firstIndex(of: tab) else { return }
        tabs.removeAll { $0 === tab }
        tabs.insert(tab, at: place < others.count ? tabs.firstIndex(of: others[place])! : tabs.count)
        slide()
    }

    override func mouseUp(with event: NSEvent) {
        guard let hold = held else { return }
        held = nil
        guard hold.moved else {
            onSelect?(hold.from)
            return
        }
        slide()
        if let to = open.firstIndex(of: hold.tab), to != hold.from { onMove?(hold.from, to) }
        if let pending { show(pending.items, selected: pending.selected) }
    }

    override func otherMouseUp(with event: NSEvent) {
        let x = pointer(event)
        if let index = open.firstIndex(where: { $0.frame.minX...$0.frame.maxX ~= x }) { onClose?(index) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let x = pointer(event)
        guard let index = open.firstIndex(where: { $0.frame.minX...$0.frame.maxX ~= x }) else { return nil }
        let menu = NSMenu()
        onMenu?(index, menu)
        return menu
    }

    /// Moves the tabs to their places as AppKit animates a view's frame.
    private func slide() {
        needsLayout = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Chrome.animation
            context.allowsImplicitAnimation = true
            layoutSubtreeIfNeeded()
        }
    }
}

/// One tab along the top: its name, a dot before it for output not seen yet, and a close button at its left while the
/// pointer is on it, in place of the dot. The tab draws its name
/// and its background itself, measured and drawn with the same font, so that a name that fits is never cut short.
private final class Tab: NSView {
    let id: ObjectIdentifier
    /// 1 while the tab is open, 0 once it is closing, and how far it has come toward that.
    var target: CGFloat = 1
    var shown: CGFloat = 0
    var onClose: (() -> Void)?
    var title = "" {
        didSet { needsDisplay = true }
    }
    var isSelected = false {
        didSet { needsDisplay = true }
    }
    var unseen = false {
        didSet { needsDisplay = true }
    }

    private let close = NSButton()
    private var hovering = false {
        didSet {
            close.isHidden = !hovering
            needsDisplay = true
        }
    }

    init(id: ObjectIdentifier) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        close.isBordered = false
        close.isHidden = true
        close.contentTintColor = .secondaryLabelColor
        close.toolTip = String(localized: "Close Tab (⌘W)")
        close.target = self
        close.action = #selector(closeTab)
        addSubview(close)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The name's width in the selected tab's weight, so that selecting a tab does not move the others, with room for
    /// the close button on each side, so that the name stays in the middle.
    var naturalWidth: CGFloat { ceil(name(selected: true).size().width) + 44 }

    private func name(selected: Bool) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingTail
        return NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ])
    }

    override func draw(_ dirtyRect: NSRect) {
        let back = isSelected ? Chrome.pill : hovering ? Chrome.hover : .clear
        back.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let name = name(selected: isSelected)
        let size = name.size()
        let height = ceil(size.height)
        name.draw(with: NSRect(x: 22, y: (bounds.height - height) / 2, width: max(0, bounds.width - 44), height: height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        // The dot sits 6 before the centered name, or at the edge of the name's room when the name fills it.
        if unseen, !hovering {
            let x = max(22, (bounds.width - ceil(size.width)) / 2) - 12
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.height - 6) / 2, width: 6, height: 6)).fill()
        }
    }

    /// The strip sets the tab's frame as it animates; the close button and the drawing follow it at once.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        close.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        needsDisplay = true
    }

    /// Everything but the close button goes to the strip, which tells a click from a drag.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === close ? close : hit == nil ? nil : self
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The strip's menu for the tab.
    override func menu(for event: NSEvent) -> NSMenu? { superview?.menu(for: event) }

    override func mouseEntered(with event: NSEvent) { hovering = true }

    override func mouseExited(with event: NSEvent) { hovering = false }

    @objc private func closeTab() { onClose?() }
}
