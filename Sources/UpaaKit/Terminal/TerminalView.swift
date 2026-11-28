import AppKit
import CUpaaCore
import MetalKit

/// A view that displays one terminal and receives key input. Redraws only when the screen changes.
final class TerminalView: MTKView, MTKViewDelegate {
    let session: TerminalSession
    let renderer: Renderer
    private let commandQueue: MTLCommandQueue
    private(set) var gridSize: (cols: Int, rows: Int) = (0, 0)
    /// The cursor cell from the last frame. The IME candidate window is placed below it.
    private var cursor: (col: Int, row: Int)?
    /// Scroll amount (in rows) not applied yet, since trackpads scroll by less than a row at a time.
    private var pendingScroll: CGFloat = 0
    /// Runs while a selection drag is past the top or bottom edge, scrolling one row per tick.
    private var autoscrollTimer: Timer?
    private var lastDrag: NSEvent?
    /// Fires when the mascot's picture changes, or the search has more scrollback to go through, since neither waits
    /// on the screen changing.
    private var redrawTimer: Timer?
    /// A redraw is waiting to run after the current event.
    private var redrawQueued = false
    /// A grid resize is waiting to follow the drawable's size.
    private var resizeQueued = false
    /// The find bar (Cmd-F), floating over the bottom of the pane. Made the first time it opens.
    private var findBar: FindBar?
    private var finding = false
    /// This view took the keyboard (a click on it, or the window choosing it).
    var onFocus: (() -> Void)?
    /// The grid changed size.
    var onResize: (() -> Void)?
    /// The screen changed (the program wrote something), whether or not the view is in the window.
    var onOutput: (() -> Void)?

    /// Drawable pixels per view point (2 on Retina).
    private var scale: CGFloat { drawableSize.width / max(bounds.width, 1) }

    /// Text being composed with IME. Passed to Zig when drawing and overlaid with an underline at the cursor position.
    private var markedText = NSMutableAttributedString()
    /// Collects characters committed from IME during keyDown processing. nil outside keyDown.
    private var insertedText: String?

    init(session: TerminalSession, renderer: Renderer) {
        self.session = session
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()!
        super.init(frame: .zero, device: renderer.device)
        colorPixelFormat = Renderer.pixelFormat
        // Draw only when something changes, and right away (redraw) rather than at the next display update.
        isPaused = true
        enableSetNeedsDisplay = false
        delegate = self
        session.onWakeup = { [weak self] in
            self?.redraw()
            self?.onOutput?()
        }
        session.setColors(dark: effectiveAppearance.isDark)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: Drawing

    /// Points kept free above the text, for chrome that floats over the terminal. The background still fills them.
    var topInset: CGFloat = 0 {
        didSet {
            guard topInset != oldValue else { return }
            renderer.extraTop = Int((topInset * (window?.backingScaleFactor ?? 2)).rounded())
            if drawableSize.width > 0 { mtkView(self, drawableSizeWillChange: drawableSize) }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The drawable needs a frame at its new size even when the grid stays the same.
        redraw()
        // Dragging the sidebar or the window changes the size every frame. Each grid change tells the shell (SIGWINCH),
        // and a shell still drawing its prompt for the last width would leave it rewrapped at the new one (#59). So the
        // grid follows at most every 25 ms, with the size of that moment, as in Ghostty.
        // (A main-queue block rather than a Timer, since it also runs while the drag tracks the mouse.)
        guard !resizeQueued else { return }
        resizeQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.resizeGrid() }
    }

    private func resizeGrid() {
        resizeQueued = false
        let (cols, rows) = renderer.gridSize(for: (Int(drawableSize.width), Int(drawableSize.height)))
        guard (cols, rows) != gridSize else { return }
        gridSize = (cols, rows)
        session.resize(
            cols: UInt16(clamping: cols), rows: UInt16(clamping: rows),
            cellWidth: renderer.cellSize.width, cellHeight: renderer.cellSize.height)
        onResize?()
    }

    /// Changes the font (as for Renderer.setFont) and fits the grid to the new cells. Returns false if it cannot be found.
    func setFont(name: String, size: Double) -> Bool {
        guard renderer.setFont(name: name, size: size) else { return false }
        // The cells' pixel size changed even if the grid did not.
        gridSize = (0, 0)
        if drawableSize.width > 0 { mtkView(self, drawableSizeWillChange: drawableSize) }
        return true
    }

    /// Draws once the current event has been handled. Requests made while handling one event share a frame.
    private func redraw() {
        guard !redrawQueued else { return }
        redrawQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.redrawQueued = false
            self.draw()
        }
    }

    /// A tab that comes back into the window needs a frame, since it was not drawn while it was hidden.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = renderer.backgroundOpacity >= 1
        if window != nil { redraw() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        session.setColors(dark: effectiveAppearance.isDark)
        redraw()
    }

    func draw(in view: MTKView) {
        // Register to receive the next change notification before drawing.
        _ = session.takeDirty()
        guard window != nil,
              let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }
        cursor = renderer.draw(
            session: session, preedit: markedText.string, commandBuffer: commandBuffer, pass: pass,
            viewport: (Int(drawableSize.width), Int(drawableSize.height)))
        commandBuffer.present(drawable)
        commandBuffer.commit()
        if finding { findBar?.show(count: session.findCount) }

        redrawTimer?.invalidate()
        redrawTimer = renderer.redrawDelay.map { delay in
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.redraw() }
        }
    }

    /// Shows a notice above the mascot (e.g. an update is available).
    func showNote(_ text: String) {
        renderer.setNote(text)
        redraw()
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        // Trackpads report points; mouse wheels report rows. Positive is toward older output.
        let rows = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / (CGFloat(renderer.cellSize.height) / scale)
            : event.scrollingDeltaY
        pendingScroll += rows
        let whole = pendingScroll.rounded(.towardZero)
        guard whole != 0 else { return }
        pendingScroll -= whole
        if reportsMouse(event) {
            for _ in 0..<Int(abs(whole)) {
                session.reportMouse(pointer(UPAA_POINTER_PRESS, event, button: whole > 0 ? 4 : 5))
            }
            return
        }
        session.scroll(rows: -Int(whole))
        redraw()
    }

    // MARK: Selection

    /// Programs that ask for the mouse get clicks and the wheel, unless Shift is held to select text instead.
    private func reportsMouse(_ event: NSEvent) -> Bool {
        !event.modifierFlags.contains(.shift) && session.wantsMouse
    }

    override func mouseDown(with event: NSEvent) {
        if reportsMouse(event) { return session.reportMouse(pointer(UPAA_POINTER_PRESS, event, button: 1)) }
        let press = pointer(UPAA_POINTER_PRESS, event)
        renderer.pokeMascot(x: press.x, y: press.y)
        _ = session.select(press)
        redraw()
    }

    override func mouseDragged(with event: NSEvent) {
        if reportsMouse(event) { return session.reportMouse(pointer(UPAA_POINTER_DRAG, event, button: 1)) }
        lastDrag = event
        let wantsAutoscroll = session.select(pointer(UPAA_POINTER_DRAG, event))
        redraw()
        if wantsAutoscroll, autoscrollTimer == nil {
            autoscrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self, let drag = self.lastDrag else { return }
                if !self.session.select(self.pointer(UPAA_POINTER_AUTOSCROLL, drag)) { self.stopAutoscroll() }
                self.redraw()
            }
        } else if !wantsAutoscroll {
            stopAutoscroll()
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        if reportsMouse(event) { return session.reportMouse(pointer(UPAA_POINTER_RELEASE, event, button: 1)) }
        _ = session.select(pointer(UPAA_POINTER_RELEASE, event))
        redraw()
    }

    override func rightMouseDown(with event: NSEvent) {
        if reportsMouse(event) { session.reportMouse(pointer(UPAA_POINTER_PRESS, event, button: 2)) }
    }

    override func rightMouseUp(with event: NSEvent) {
        if reportsMouse(event) { session.reportMouse(pointer(UPAA_POINTER_RELEASE, event, button: 2)) }
    }

    override func otherMouseDown(with event: NSEvent) {
        if reportsMouse(event) { session.reportMouse(pointer(UPAA_POINTER_PRESS, event, button: 3)) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if reportsMouse(event) { session.reportMouse(pointer(UPAA_POINTER_RELEASE, event, button: 3)) }
    }

    private func stopAutoscroll() {
        autoscrollTimer?.invalidate()
        autoscrollTimer = nil
    }

    /// The event as a pointer in drawable pixels from the top-left. button is only used when reporting to the program.
    private func pointer(_ kind: Int, _ event: NSEvent, button: UInt8 = 0) -> UpaaPointer {
        let location = convert(event.locationInWindow, from: nil)
        let cell = renderer.cellSize
        return UpaaPointer(
            kind: UInt8(kind),
            button: button,
            mods: Self.mods(event.modifierFlags),
            rectangle: event.modifierFlags.contains(.option),
            x: location.x * scale,
            y: (bounds.height - location.y) * scale,
            time_ns: UInt64(event.timestamp * 1e9),
            repeat_interval_ns: UInt64(NSEvent.doubleClickInterval * 1e9),
            repeat_distance: Double(cell.width),
            cols: UInt32(gridSize.cols), rows: UInt32(gridSize.rows),
            cell_width: UInt32(cell.width), cell_height: UInt32(cell.height),
            padding_left: UInt32(renderer.padding.horizontal), padding_top: UInt32(renderer.padding.top),
            padding_right: UInt32(renderer.padding.horizontal), padding_bottom: UInt32(renderer.padding.bottom),
            screen_width: UInt32(drawableSize.width), screen_height: UInt32(drawableSize.height))
    }

    @objc func copy(_ sender: Any?) {
        guard let text = session.selectionText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else { return }
        if session.paste(text, allowUnsafe: false) == .rejected, confirmUnsafePaste(text) {
            _ = session.paste(text, allowUnsafe: true)
        }
    }

    /// Asks before pasting text that could run a command as soon as it is pasted.
    private func confirmUnsafePaste(_ text: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Paste text that may run commands?")
        alert.informativeText = String(localized: "The text contains a line break or a control sequence, so the shell may run it as soon as it is pasted.")
        alert.addButton(withTitle: String(localized: "Paste"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    override func selectAll(_ sender: Any?) {
        session.selectAll()
        redraw()
    }

    // MARK: Find

    /// Cmd-F. Opens the find bar with the text it had, or takes the keyboard back to it, the text selected so that
    /// typing replaces it.
    @objc func showFindBar(_ sender: Any?) {
        let bar = findBar ?? makeFindBar()
        if !finding {
            finding = true
            session.find(bar.field.stringValue)
            bar.isHidden = false
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Chrome.animation
                bar.animator().alphaValue = 1
            }
            redraw()
        }
        window?.makeFirstResponder(bar.field)
        bar.field.selectText(nil)
    }

    /// Cmd-G, and Return in the find bar: the next older match. Opens the find bar while it is closed.
    @objc func findNextMatch(_ sender: Any?) {
        moveMatch(back: false)
    }

    /// Shift-Cmd-G, and Shift-Return in the find bar: the next newer match.
    @objc func findPreviousMatch(_ sender: Any?) {
        moveMatch(back: true)
    }

    private func moveMatch(back: Bool) {
        guard finding else { return showFindBar(nil) }
        session.findNext(back: back)
        redraw()
    }

    /// Escape or the close button. The matches are no longer marked, and the keyboard goes back to the terminal.
    private func closeFindBar() {
        guard finding, let bar = findBar else { return }
        finding = false
        session.find("")
        window?.makeFirstResponder(self)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Chrome.animation
            bar.animator().alphaValue = 0
        }) { [weak self] in
            if self?.finding == false { bar.isHidden = true }
        }
        redraw()
    }

    private func makeFindBar() -> FindBar {
        let bar = FindBar()
        bar.onChange = { [weak self] text in
            self?.session.find(text)
            self?.redraw()
        }
        bar.onMove = { [weak self] back in self?.moveMatch(back: back) }
        bar.onClose = { [weak self] in self?.closeFindBar() }
        bar.alphaValue = 0
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        findBar = bar
        return bar
    }

    // MARK: Key input

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocus?()
        return true
    }

    override func keyDown(with event: NSEvent) {
        // Keys that include ⌘ are left to menu shortcuts.
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }

        let wasComposing = hasMarkedText()
        insertedText = ""
        // Go through IME. Committed characters arrive in insertText; text being composed arrives in setMarkedText.
        interpretKeyEvents([event])
        let text = insertedText ?? ""
        insertedText = nil

        if wasComposing || hasMarkedText() {
            // Keys during composition belong to IME. Only the committed characters are sent to the shell.
            if !text.isEmpty { session.write(text) }
            return
        }

        session.key(
            code: event.keyCode,
            isRepeat: event.isARepeat,
            mods: Self.mods(event.modifierFlags),
            unshifted: event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0,
            text: Self.printable(text))
    }

    /// Arrow keys, Return, and similar keys arrive here instead of insertText. They are sent as keys, so nothing is done here.
    override func doCommand(by selector: Selector) {}

    private static func mods(_ flags: NSEvent.ModifierFlags) -> UInt8 {
        var mods = 0
        if flags.contains(.shift) { mods |= UPAA_MOD_SHIFT }
        if flags.contains(.control) { mods |= UPAA_MOD_CTRL }
        if flags.contains(.option) { mods |= UPAA_MOD_ALT }
        if flags.contains(.command) { mods |= UPAA_MOD_SUPER }
        return UInt8(mods)
    }

    /// Control characters (such as 0x03 for Ctrl+C) and private-use characters assigned to arrow keys are
    /// not sent as text. The encoder builds them from the key and modifier keys.
    private static func printable(_ text: String) -> String? {
        guard let first = text.unicodeScalars.first else { return nil }
        if first.value < 0x20 || first.value == 0x7F { return nil }
        if (0xF700...0xF8FF).contains(first.value) { return nil }
        return text
    }
}

// MARK: IME

extension TerminalView: NSTextInputClient {
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        // Plain typing also arrives here, so this draws only when a composition ends. An extra frame before the
        // shell echoes the character would push the echo to a later display refresh.
        unmarkText()
        if insertedText != nil {
            insertedText! += text
        } else {
            // Input that does not go through keyDown (such as the character viewer).
            session.write(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let attributed = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: attributed)
        } else {
            markedText = NSMutableAttributedString(string: string as? String ?? "")
        }
        redraw()
    }

    func unmarkText() {
        guard hasMarkedText() else { return }
        markedText = NSMutableAttributedString()
        redraw()
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        nil
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    /// Screen rect of the cursor cell (where composition starts). The input method shows its candidate window below it.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window, let cursor else { return .zero }
        // Renderer works in drawable pixels from the top-left; the view is in points from the bottom-left.
        let cell = renderer.cellSize
        let x = CGFloat(renderer.padding.horizontal + cursor.col * cell.width) / scale
        let top = CGFloat(renderer.padding.top + cursor.row * cell.height) / scale
        let height = CGFloat(cell.height) / scale
        let rect = NSRect(x: x, y: bounds.height - top - height, width: CGFloat(cell.width) / scale, height: height)
        return window.convertToScreen(convert(rect, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        NSNotFound
    }
}
