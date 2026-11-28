import CUpaaCore
import Foundation

/// Wraps the Zig-side terminal session (PTY, shell, libghostty-vt terminal).
final class TerminalSession {
    let handle: OpaquePointer
    private let events: Events
    /// Gives setColors the colors it names.
    var config: Config?
    /// The web addresses the session has printed, oldest first (readLinks).
    private(set) var links: [Link] = []

    /// The screen changed. Called on the main thread.
    var onWakeup: (() -> Void)? {
        get { events.onWakeup }
        set { events.onWakeup = newValue }
    }

    /// The shell exited. Called on the main thread.
    var onExit: (() -> Void)? {
        get { events.onExit }
        set { events.onExit = newValue }
    }

    /// The program set the title (read it with title). Called on the main thread.
    var onTitle: (() -> Void)? {
        get { events.onTitle }
        set { events.onTitle = newValue }
    }

    /// If command is nil, starts the login shell; otherwise starts /bin/sh -c command. cwd nil starts in the home directory
    /// (or the current one for a command). The colors are libghostty-vt's until setColors; config gives the ones it names.
    init?(cols: UInt16, rows: UInt16, command: String? = nil, cwd: String? = nil, config: Config? = nil) {
        let events = Events()
        var callbacks = UpaaSessionCallbacks(
            userdata: Unmanaged.passUnretained(events).toOpaque(),
            on_wakeup: { userdata in
                let events = Unmanaged<Events>.fromOpaque(userdata!).takeUnretainedValue()
                DispatchQueue.main.async { events.onWakeup?() }
            },
            on_exit: { userdata in
                let events = Unmanaged<Events>.fromOpaque(userdata!).takeUnretainedValue()
                DispatchQueue.main.async { events.onExit?() }
            },
            on_title: { userdata in
                let events = Unmanaged<Events>.fromOpaque(userdata!).takeUnretainedValue()
                DispatchQueue.main.async { events.onTitle?() }
            }
        )
        // A zsh login shell reads upaa's startup files first, which mark the prompt so a resize can clear it (#59).
        // nil outside the .app, where the files are not, so zsh starts as usual.
        let zshDir = Bundle.main.path(forResource: "zsh", ofType: nil, inDirectory: "shell-integration")
        guard let handle = upaa_session_new(cols, rows, command, cwd, zshDir, &callbacks) else { return nil }
        self.handle = handle
        self.events = events
        self.config = config
    }

    /// Sets the default colors for light or dark mode: the config's, and design A3's where it names none.
    func setColors(dark: Bool) {
        upaa_session_set_colors(handle, config?.handle, dark)
    }

    deinit {
        // Waits for the read thread to exit, so no callbacks arrive after this point.
        upaa_session_free(handle)
    }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        upaa_session_write(handle, bytes, bytes.count)
    }

    /// A key was pressed once. text is the character this key inputs (nil if none).
    func key(code: UInt16, isRepeat: Bool, mods: UInt8, unshifted: UInt32, text: String?) {
        let bytes = text.map { Array($0.utf8) } ?? []
        bytes.withUnsafeBufferPointer { buffer in
            var event = UpaaKeyEvent(
                key_code: code,
                action: UInt8(isRepeat ? UPAA_KEY_REPEAT : UPAA_KEY_PRESS),
                mods: mods,
                unshifted_codepoint: unshifted,
                text: buffer.isEmpty ? nil : buffer.baseAddress,
                text_len: buffer.count)
            upaa_session_key(handle, &event)
        }
    }

    /// Whether the program asked for mouse events (vim with mouse=a, htop, ...).
    var wantsMouse: Bool { upaa_session_wants_mouse(handle) }

    /// Sends a mouse event to the program. A wheel step is a press of button 4 (up) or 5 (down).
    func reportMouse(_ pointer: UpaaPointer) {
        var pointer = pointer
        upaa_session_report_mouse(handle, &pointer)
    }

    /// Feeds a mouse event to text selection. Returns true while a drag past the top or bottom edge wants autoscroll ticks.
    func select(_ pointer: UpaaPointer) -> Bool {
        var pointer = pointer
        return upaa_session_select(handle, &pointer) != 0
    }

    func selectAll() {
        upaa_session_select_all(handle)
    }

    /// Starts the find bar's search through the screen and the scrollback, and selects the newest match. "" ends it.
    func find(_ text: String) {
        let bytes = Array(text.utf8)
        upaa_session_find(handle, bytes, bytes.count)
    }

    /// Selects the next older match, or the next newer one with back, scrolling to it.
    func findNext(back: Bool) {
        upaa_session_find_next(handle, back)
    }

    /// How many matches the search has found so far, and the selected one's place from the newest (1), 0 if none.
    var findCount: (selected: Int, total: Int) {
        var selected = 0
        let total = upaa_session_find_count(handle, &selected)
        return (selected, total)
    }

    enum PasteResult { case pasted, rejected, failed }

    /// Pastes text into the shell. .rejected means the text could run a command by itself; ask, then retry with allowUnsafe.
    func paste(_ text: String, allowUnsafe: Bool) -> PasteResult {
        let bytes = Array(text.utf8)
        switch Int(upaa_session_paste(handle, bytes, bytes.count, allowUnsafe)) {
        case UPAA_PASTE_PASTED: return .pasted
        case UPAA_PASTE_REJECTED: return .rejected
        default: return .failed
        }
    }

    /// The selected text, or nil if nothing is selected.
    func selectionText() -> String? {
        let n = upaa_session_selection_text(handle, nil, 0)
        guard n > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: n)
        _ = upaa_session_selection_text(handle, &out, out.count)
        return String(decoding: out, as: UTF8.self)
    }

    /// Moves the view through the scrollback by rows (up is negative).
    func scroll(rows: Int) {
        upaa_session_scroll(handle, rows)
    }

    func resize(cols: UInt16, rows: UInt16, cellWidth: Int, cellHeight: Int) {
        upaa_session_resize(handle, cols, rows, UInt32(cellWidth), UInt32(cellHeight))
    }

    /// The shell's current directory, or nil if unknown. Programs it started (such as Claude Code) may be elsewhere.
    var cwd: String? {
        var out = [UInt8](repeating: 0, count: 1024)
        let n = upaa_session_cwd(handle, &out, out.count)
        return n > 0 ? String(decoding: out.prefix(n), as: UTF8.self) : nil
    }

    /// The program the shell is running in the foreground (such as vim or claude), "" if its name cannot be read, or nil
    /// while the shell itself waits for input.
    var running: String? {
        var out = [UInt8](repeating: 0, count: 256)
        let n = upaa_session_running(handle, &out, out.count)
        return n < 0 ? nil : String(decoding: out.prefix(n), as: UTF8.self)
    }

    /// The title the program set (OSC 0 or 2), or nil if it set none.
    var title: String? {
        var out = [UInt8](repeating: 0, count: 1024)
        let n = upaa_session_title(handle, &out, out.count)
        return n > 0 ? String(decoding: out.prefix(n), as: UTF8.self) : nil
    }

    /// Plain text of the screen.
    func plainText() -> String {
        var out = [UInt8](repeating: 0, count: 64 * 1024)
        let n = upaa_session_plain_text(handle, &out, out.count)
        return n >= 0 ? String(decoding: out.prefix(min(n, out.count)), as: UTF8.self) : ""
    }

    /// Adds the web addresses printed since the previous call to links.
    func readLinks() {
        // The text since the previous call, as VT sequences so that hyperlinks come with it. Of more than fits, the
        // newest part.
        var out = [UInt8](repeating: 0, count: 1 << 20)
        let n = upaa_session_new_text(handle, &out, out.count)
        Links.add(Links.find(in: String(decoding: out.prefix(n), as: UTF8.self)), to: &links, now: Date())
    }

    /// true if the screen has changed since the previous call.
    func takeDirty() -> Bool {
        upaa_session_take_dirty(handle)
    }

    /// Receiver for notifications passed from the Zig thread. It must live longer than the session, so it is a separate object
    /// (a notification queued on the main thread may run after the session has been freed).
    private final class Events {
        var onWakeup: (() -> Void)?
        var onExit: (() -> Void)?
        var onTitle: (() -> Void)?
    }
}
