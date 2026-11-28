//! One terminal: bundles the PTY, the read thread, and the libghostty-vt terminal.
//!
//! Always take the mutex before touching the terminal. The libghostty-vt terminal is not thread-safe,
//! and it is touched from both the read thread (which writes PTY output) and the caller's thread (resize, drawing).
const Session = @This();

const std = @import("std");
const c = @import("posix");
const vt = @import("ghostty");
const Pty = @import("Pty.zig");
const keymap = @import("keymap.zig");
const Config = @import("../Config.zig");

const alloc = std.heap.c_allocator;

pty: Pty,
terminal: vt.GhosttyTerminal,
key_encoder: vt.GhosttyKeyEncoder,
key_event: vt.GhosttyKeyEvent,
/// Interprets mouse presses and drags as text selection (clicks, double and triple clicks, autoscroll).
gesture: vt.GhosttySelectionGesture,
/// Encodes mouse events for programs that ask for them (vim with mouse=a, htop, ...).
mouse_encoder: vt.GhosttyMouseEncoder,
mouse_event: vt.GhosttyMouseEvent,
mutex: std.c.pthread_mutex_t = .{},
thread: std.Thread,
/// Pipe to stop the read thread. Writing to it wakes poll.
stop_pipe: [2]c_int,
/// Calls on_wakeup only when the screen change has not been reported yet. takeDirty resets it.
dirty: std.atomic.Value(bool) = .init(false),
callbacks: Callbacks,
/// The find bar's search through the screen and the scrollback. null while the find bar is closed.
search: vt.GhosttySearch = null,
/// The top of the screen at the last call of newText, followed as it scrolls up into the scrollback.
link_mark: vt.GhosttyTrackedGridRef = null,

pub const Callbacks = extern struct {
    userdata: ?*anyopaque = null,
    /// The screen changed. Called from the read thread.
    on_wakeup: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
    /// The child process exited. Called from the read thread.
    on_exit: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
    /// The program set the title (OSC 0 or 2). Called from the read thread with the lock held; read it with title().
    on_title: ?*const fn (userdata: ?*anyopaque) callconv(.c) void = null,
};

/// One key press (release). Same layout as UpaaKeyEvent in Sources/CUpaaCore.
pub const KeyEvent = extern struct {
    /// macOS virtual key code.
    key_code: u16,
    action: Action,
    /// The sum of the Mods values.
    mods: u8 = 0,
    /// Character for the same key pressed without modifiers. 0 if unknown.
    unshifted_codepoint: u32 = 0,
    /// Text this key produces (UTF-8). null if none.
    text: ?[*]const u8 = null,
    text_len: usize = 0,

    pub const Action = enum(u8) { release = 0, press = 1, repeat = 2 };

    pub const Mods = struct {
        pub const shift = 1 << 0;
        pub const ctrl = 1 << 1;
        pub const alt = 1 << 2;
        pub const super = 1 << 3;
    };
};

/// A mouse event, for selecting text or for reporting to the program. Same layout as UpaaPointer in Sources/CUpaaCore.
pub const Pointer = extern struct {
    kind: Kind,
    /// GhosttyMouseButton (1 left, 2 right, 3 middle, 4 wheel up, 5 wheel down). Only used for reporting.
    button: u8 = 0,
    /// KeyEvent.Mods values added together. Only used for reporting.
    mods: u8 = 0,
    /// Option held: select a rectangle instead of running text.
    rectangle: bool = false,
    /// Position in drawable pixels from the top-left of the view.
    x: f64,
    y: f64,
    /// Monotonic event time, and the longest gap and distance between clicks that still count as a double or triple click.
    time_ns: u64 = 0,
    repeat_interval_ns: u64 = 0,
    repeat_distance: f64 = 0,
    cols: u32,
    rows: u32,
    cell_width: u32,
    cell_height: u32,
    padding_left: u32 = 0,
    padding_top: u32 = 0,
    padding_right: u32 = 0,
    padding_bottom: u32 = 0,
    /// Size of the whole view in pixels. Dragging past the top or bottom asks for autoscroll.
    screen_width: u32 = 0,
    screen_height: u32,

    pub const Kind = enum(u8) { press = 0, drag = 1, release = 2, autoscroll = 3 };
};

pub const Options = struct {
    size: Pty.Size,
    /// null means the login shell.
    command: ?[*:0]const u8 = null,
    /// Directory to start in. null means the home directory for the login shell, the current one for a command.
    cwd: ?[*:0]const u8 = null,
    /// upaa's zsh startup files, as for Pty.spawn.
    zsh_dir: ?[*:0]const u8 = null,
    callbacks: Callbacks = .{},
};

pub fn create(opts: Options) !*Session {
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);

    var terminal: vt.GhosttyTerminal = null;
    if (vt.ghostty_terminal_new(null, &terminal, opts.size.cols, opts.size.rows) != vt.GHOSTTY_SUCCESS)
        return error.TerminalFailed;
    errdefer vt.ghostty_terminal_free(terminal);
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self);
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&onWritePty));
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @ptrCast(&onTitleChanged));
    // The library default (10,000 bytes) keeps only a few hundred lines of scrollback.
    var scrollback: usize = 10 * 1024 * 1024;
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback);

    var key_encoder: vt.GhosttyKeyEncoder = null;
    if (vt.ghostty_key_encoder_new(null, &key_encoder) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_key_encoder_free(key_encoder);
    var key_event: vt.GhosttyKeyEvent = null;
    if (vt.ghostty_key_event_new(null, &key_event) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_key_event_free(key_event);

    var gesture: vt.GhosttySelectionGesture = null;
    if (vt.ghostty_selection_gesture_new(null, &gesture) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_selection_gesture_free(gesture, terminal);

    var mouse_encoder: vt.GhosttyMouseEncoder = null;
    if (vt.ghostty_mouse_encoder_new(null, &mouse_encoder) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_mouse_encoder_free(mouse_encoder);
    // Report motion only when the pointer moves to another cell, as xterm does.
    var track_last_cell = true;
    _ = vt.ghostty_mouse_encoder_set(mouse_encoder, vt.GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &track_last_cell);
    var mouse_event: vt.GhosttyMouseEvent = null;
    if (vt.ghostty_mouse_event_new(null, &mouse_event) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_mouse_event_free(mouse_event);

    var stop_pipe: [2]c_int = undefined;
    if (c.pipe(&stop_pipe) != 0) return error.PipeFailed;
    errdefer for (stop_pipe) |fd| {
        _ = c.close(fd);
    };

    const pty = try Pty.spawn(opts.command, opts.cwd, opts.size, opts.zsh_dir);
    errdefer pty.deinit();

    self.* = .{
        .pty = pty,
        .terminal = terminal,
        .key_encoder = key_encoder,
        .key_event = key_event,
        .gesture = gesture,
        .mouse_encoder = mouse_encoder,
        .mouse_event = mouse_event,
        .thread = undefined,
        .stop_pipe = stop_pipe,
        .callbacks = opts.callbacks,
    };
    self.thread = try std.Thread.spawn(.{}, readLoop, .{self});
    return self;
}

pub fn destroy(self: *Session) void {
    _ = c.write(self.stop_pipe[1], "x", 1);
    self.thread.join();
    self.pty.deinit();
    for (self.stop_pipe) |fd| _ = c.close(fd);
    vt.ghostty_search_free(self.search);
    vt.ghostty_tracked_grid_ref_free(self.link_mark);
    vt.ghostty_mouse_event_free(self.mouse_event);
    vt.ghostty_mouse_encoder_free(self.mouse_encoder);
    vt.ghostty_selection_gesture_free(self.gesture, self.terminal);
    vt.ghostty_key_event_free(self.key_event);
    vt.ghostty_key_encoder_free(self.key_encoder);
    vt.ghostty_terminal_free(self.terminal);
    alloc.destroy(self);
}

/// Input to the child process (e.g. bytes encoding a key press).
pub fn write(self: *Session, bytes: []const u8) void {
    // Typing brings the view back to the live screen if it was scrolled into the scrollback.
    self.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } });
    _ = self.pty.writeAll(bytes);
}

/// Moves the view through the scrollback. Up is a negative delta.
pub fn scroll(self: *Session, behavior: vt.GhosttyTerminalScrollViewport) void {
    self.lock();
    defer self.unlock();
    _ = vt.ghostty_terminal_scroll_viewport(self.terminal, behavior);
}

/// Turns a key press into bytes matching the terminal's current mode (e.g. cursor key mode), and sends them to the child process.
pub fn key(self: *Session, event: KeyEvent) void {
    var buf: [128]u8 = undefined;
    var len: usize = 0;
    {
        self.lock();
        defer self.unlock();

        const text_len = if (event.text == null) 0 else event.text_len;
        // For keys that produce a character, Shift and Option are already used to make that character.
        const consumed: u8 = if (text_len > 0) event.mods & (KeyEvent.Mods.shift | KeyEvent.Mods.alt) else 0;

        const ev = self.key_event;
        _ = vt.ghostty_key_event_set_action(ev, @intFromEnum(event.action));
        _ = vt.ghostty_key_event_set_key(ev, keymap.fromMacKeyCode(event.key_code));
        _ = vt.ghostty_key_event_set_mods(ev, event.mods);
        _ = vt.ghostty_key_event_set_consumed_mods(ev, consumed);
        _ = vt.ghostty_key_event_set_unshifted_codepoint(ev, event.unshifted_codepoint);
        _ = vt.ghostty_key_event_set_composing(ev, false);
        _ = vt.ghostty_key_event_set_utf8(ev, .{ .ptr = event.text, .len = text_len });

        _ = vt.ghostty_key_encoder_set_from_terminal(self.key_encoder, self.terminal);
        if (vt.ghostty_key_encoder_encode(self.key_encoder, ev, &buf, buf.len, &len) != vt.GHOSTTY_SUCCESS) return;
    }
    if (len > 0) self.write(buf[0..len]);
}

pub fn resize(self: *Session, size: Pty.Size, cell_width_px: u32, cell_height_px: u32) void {
    self.lock();
    defer self.unlock();
    _ = vt.ghostty_terminal_resize(self.terminal, size.cols, size.rows, cell_width_px, cell_height_px);
    self.pty.resize(size);
}

/// Sets the default colors for light or dark mode (Config.applyColors).
pub fn setColors(self: *Session, config: *const Config, dark: bool) void {
    self.lock();
    defer self.unlock();
    config.applyColors(self.terminal, dark);
}

/// True if the screen changed since the previous call. Resets so that the next on_wakeup is received.
pub fn takeDirty(self: *Session) bool {
    return self.dirty.swap(false, .acq_rel);
}

/// A match of the find bar's search in view, from its first cell to its last, in viewport cells.
/// A match that runs over the top or bottom of the view is cut at the edge.
pub const Match = struct {
    start: vt.GhosttyPointCoordinate,
    end: vt.GhosttyPointCoordinate,
    /// The match that findNext moved to, which the find bar counts.
    selected: bool = false,
};

/// What updateRenderState found besides the screen.
pub const Update = struct {
    /// Matches written.
    matches: usize = 0,
    /// The search has more of the scrollback to go through, so the screen should be drawn again soon.
    searching: bool = false,
};

/// Syncs the render state with the current screen, and writes the find bar's matches in view to matches (as many as
/// fit). Holds the lock only while touching the terminal. null on failure.
pub fn updateRenderState(self: *Session, state: vt.GhosttyRenderState, matches: []Match) ?Update {
    var update: Update = .{};
    {
        self.lock();
        defer self.unlock();
        if (vt.ghostty_render_state_begin_update(state, self.terminal) != vt.GHOSTTY_SUCCESS) return null;
        if (self.search != null) update.matches = self.matchesInView(matches);
    }
    if (vt.ghostty_render_state_end_update(state) != vt.GHOSTTY_SUCCESS) return null;
    if (self.search != null) update.searching = self.searchScrollback();
    return update;
}

/// Starts the find bar's search for needle through the screen and the scrollback, and selects the newest match.
/// ASCII letters match either case. A needle that matches the same way as the last one keeps its results. An empty
/// needle ends the search.
pub fn find(self: *Session, needle: []const u8) void {
    self.lock();
    defer self.unlock();
    if (needle.len == 0) {
        vt.ghostty_search_free(self.search);
        self.search = null;
        return;
    }
    if (self.search == null and vt.ghostty_search_new(null, &self.search, self.terminal) != vt.GHOSTTY_SUCCESS) return;
    const value: vt.GhosttyString = .{ .ptr = needle.ptr, .len = needle.len };
    _ = vt.ghostty_search_set(self.search, vt.GHOSTTY_SEARCH_OPT_NEEDLE, &value);
    // The search sees the screen only once fed, and only then has a match to select.
    _ = vt.ghostty_search_feed(self.search);
    var index: usize = 0;
    if (vt.ghostty_search_get(self.search, vt.GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) != vt.GHOSTTY_SUCCESS)
        _ = vt.ghostty_search_select_next(self.search);
}

/// Selects the next older match (the next newer one with back), wrapping around, and scrolls to it if it is out of view.
pub fn findNext(self: *Session, back: bool) void {
    self.lock();
    defer self.unlock();
    if (self.search == null) return;
    _ = if (back) vt.ghostty_search_select_prev(self.search) else vt.ghostty_search_select_next(self.search);
}

/// How many matches the search has found so far. selected is set to the selected one's place, counted from the
/// newest (1), or 0 if none is selected.
pub fn findCount(self: *Session, selected: *usize) usize {
    selected.* = 0;
    if (self.search == null) return 0;
    var total: usize = 0;
    var index: usize = 0;
    _ = vt.ghostty_search_get(self.search, vt.GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total);
    if (vt.ghostty_search_get(self.search, vt.GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == vt.GHOSTTY_SUCCESS) selected.* = index + 1;
    return total;
}

/// Brings the search up to date with the terminal and writes its matches in view to out. The caller holds the lock.
fn matchesInView(self: *Session, out: []Match) usize {
    _ = vt.ghostty_search_feed(self.search);
    var current = std.mem.zeroes(vt.GhosttySelection);
    const has_current = vt.ghostty_search_get(self.search, vt.GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &current) == vt.GHOSTTY_SUCCESS;

    // Asked once for the count, then for the matches.
    var found: vt.GhosttySelectionBuffer = .{ .ptr = null, .cap = 0, .len = 0 };
    if (vt.ghostty_search_get(self.search, vt.GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &found) != vt.GHOSTTY_OUT_OF_SPACE) return 0;
    const all = alloc.alloc(vt.GhosttySelection, found.len) catch return 0;
    defer alloc.free(all);
    found = .{ .ptr = all.ptr, .cap = all.len, .len = 0 };
    if (vt.ghostty_search_get(self.search, vt.GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &found) != vt.GHOSTTY_SUCCESS) return 0;

    var cols: u16 = 0;
    var rows: u16 = 0;
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_COLS, &cols);
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    if (cols == 0 or rows == 0) return 0;
    var n: usize = 0;
    // The list can hold matches just outside the view, on the same page of the scrollback.
    for (all[0..found.len]) |match| {
        if (n == out.len) break;
        const start = self.inView(&match.start, rows);
        const end = self.inView(&match.end, rows);
        if (start == null and end == null) continue;
        out[n] = .{
            .start = start orelse .{ .x = 0, .y = 0 },
            .end = end orelse .{ .x = cols - 1, .y = rows - 1 },
            .selected = has_current and std.meta.eql(match.start, current.start) and std.meta.eql(match.end, current.end),
        };
        n += 1;
    }
    return n;
}

/// The cell in viewport coordinates, or null when it is out of view. The caller holds the lock.
fn inView(self: *Session, ref: *const vt.GhosttyGridRef, rows: u16) ?vt.GhosttyPointCoordinate {
    var point: vt.GhosttyPointCoordinate = undefined;
    if (vt.ghostty_terminal_point_from_grid_ref(self.terminal, ref, vt.GHOSTTY_POINT_TAG_VIEWPORT, &point) != vt.GHOSTTY_SUCCESS) return null;
    return if (point.y < rows) point else null;
}

/// Goes through the part of the scrollback that the last feed handed the search. It works on its own copy, so the lock
/// is not needed. Returns whether more of the scrollback is left for the next feed.
fn searchScrollback(self: *Session) bool {
    var status: vt.GhosttySearchStatus = vt.GHOSTTY_SEARCH_STATUS_RUNNING;
    while (status == vt.GHOSTTY_SEARCH_STATUS_RUNNING) {
        if (vt.ghostty_search_tick(self.search, &status) != vt.GHOSTTY_SUCCESS) return false;
    }
    return status == vt.GHOSTTY_SEARCH_STATUS_FEED_REQUIRED;
}

/// Whether the program asked for mouse events (vim with mouse=a, htop, ...). If so, clicks and the wheel go to
/// reportMouse instead of selection and scrolling, unless Shift is held.
pub fn wantsMouse(self: *Session) bool {
    self.lock();
    defer self.unlock();
    var tracking: vt.GhosttyMouseTrackingMode = vt.GHOSTTY_MOUSE_TRACKING_NONE;
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking);
    return tracking != vt.GHOSTTY_MOUSE_TRACKING_NONE;
}

/// The shell's current directory, copied into out. Returns its length; 0 if unknown or longer than out.
pub fn cwd(self: *Session, out: []u8) usize {
    return (self.pty.cwd(out) orelse return 0).len;
}

/// The program running in the foreground other than the shell, as Pty.running. Returns its name's length, -1 if none.
pub fn running(self: *Session, out: []u8) isize {
    return @intCast((self.pty.running(out) orelse return -1).len);
}

/// The title the program set (UTF-8), copied into out. Returns the full length; 0 if none was set.
pub fn title(self: *Session, out: []u8) usize {
    self.lock();
    defer self.unlock();
    var text: vt.GhosttyString = .{ .ptr = null, .len = 0 };
    if (vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_TITLE, &text) != vt.GHOSTTY_SUCCESS) return 0;
    const n = @min(text.len, out.len);
    if (n > 0) @memcpy(out[0..n], text.ptr[0..n]);
    return text.len;
}

/// Sends a mouse event to the program in the format and mode it asked for. A wheel step is a press of button 4 or 5.
pub fn reportMouse(self: *Session, p: Pointer) void {
    var buf: [64]u8 = undefined;
    var len: usize = 0;
    {
        self.lock();
        defer self.unlock();

        const ev = self.mouse_event;
        _ = vt.ghostty_mouse_event_set_action(ev, switch (p.kind) {
            .press => vt.GHOSTTY_MOUSE_ACTION_PRESS,
            .release => vt.GHOSTTY_MOUSE_ACTION_RELEASE,
            .drag, .autoscroll => vt.GHOSTTY_MOUSE_ACTION_MOTION,
        });
        if (p.button == 0) _ = vt.ghostty_mouse_event_clear_button(ev) else _ = vt.ghostty_mouse_event_set_button(ev, p.button);
        _ = vt.ghostty_mouse_event_set_mods(ev, p.mods);
        _ = vt.ghostty_mouse_event_set_position(ev, .{ .x = @floatCast(p.x), .y = @floatCast(p.y) });

        var size = std.mem.zeroes(vt.GhosttyMouseEncoderSize);
        size.size = @sizeOf(vt.GhosttyMouseEncoderSize);
        size.screen_width = p.screen_width;
        size.screen_height = p.screen_height;
        size.cell_width = p.cell_width;
        size.cell_height = p.cell_height;
        size.padding_top = p.padding_top;
        size.padding_bottom = p.padding_bottom;
        size.padding_left = p.padding_left;
        size.padding_right = p.padding_right;
        var pressed = p.kind == .press or p.kind == .drag;
        _ = vt.ghostty_mouse_encoder_set_from_terminal(self.mouse_encoder, self.terminal);
        _ = vt.ghostty_mouse_encoder_set(self.mouse_encoder, vt.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        _ = vt.ghostty_mouse_encoder_set(self.mouse_encoder, vt.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
        if (vt.ghostty_mouse_encoder_encode(self.mouse_encoder, ev, &buf, buf.len, &len) != vt.GHOSTTY_SUCCESS) return;
    }
    if (len > 0) _ = self.pty.writeAll(buf[0..len]);
}

pub const PasteResult = enum(u8) { pasted = 0, rejected = 1, failed = 2 };

/// Pastes text into the shell, framed for the terminal's current mode (bracketed paste when the program asks for it).
/// Text that could run a command by itself (a line break outside bracketed paste, or the end-of-paste sequence) is
/// rejected unless allow_unsafe is set: ask the user, then call again with allow_unsafe.
pub fn paste(self: *Session, text: []const u8, allow_unsafe: bool) PasteResult {
    self.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } });
    self.lock();
    defer self.unlock();

    var source = text;
    const mime: vt.GhosttyString = .{ .ptr = "text/plain", .len = "text/plain".len };
    const request: vt.GhosttyPaste = .{
        .size = @sizeOf(vt.GhosttyPaste),
        .location = vt.GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
        .source = vt.GHOSTTY_PASTE_SOURCE_CLIPBOARD,
        .mimes = &mime,
        .mimes_len = 1,
        .reader = .{ .read = readPasteText, .userdata = @ptrCast(&source) },
        .allow_unsafe = allow_unsafe,
    };
    // The encoded bytes come back through onWritePty, which writes them to the PTY.
    return switch (vt.ghostty_terminal_paste(self.terminal, &request, null)) {
        vt.GHOSTTY_SUCCESS => .pasted,
        vt.GHOSTTY_REJECTED => .rejected,
        else => .failed,
    };
}

fn readPasteText(userdata: ?*anyopaque, _: vt.GhosttyString, writer: vt.GhosttyWriter) callconv(.c) bool {
    const text: *const []const u8 = @ptrCast(@alignCast(userdata orelse return false));
    const writeFn = writer.write orelse return false;
    return writeFn(writer.userdata, text.*.ptr, text.*.len);
}

/// The live screen (without the scrollback) as plain text, written to out. Returns the full length.
pub fn plainText(self: *Session, out: []u8) ?usize {
    self.lock();
    defer self.unlock();

    var cols: u16 = 0;
    var rows: u16 = 0;
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_COLS, &cols);
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    var screen = std.mem.zeroes(vt.GhosttySelection);
    if (vt.ghostty_terminal_grid_ref(self.terminal, activePoint(0, 0), &screen.start) != vt.GHOSTTY_SUCCESS) return null;
    if (vt.ghostty_terminal_grid_ref(self.terminal, activePoint(cols - 1, rows - 1), &screen.end) != vt.GHOSTTY_SUCCESS) return null;
    return self.format(&screen, out, .plain);
}

/// The text printed since the last call, for the links panel: as VT sequences, so that hyperlinks (OSC 8) come with
/// it, with wrapped lines joined. The first call gives the scrollback and the screen; each later one gives what
/// scrolled up into the scrollback since the call before, and the screen again. On the alternate screen (full-screen
/// programs) it is that screen alone. Writes as much of the end of the text as fits in out; returns how much it wrote.
pub fn newText(self: *Session, out: []u8) usize {
    self.lock();
    defer self.unlock();

    var cols: u16 = 0;
    var rows: u16 = 0;
    var screen: vt.GhosttyTerminalScreen = vt.GHOSTTY_TERMINAL_SCREEN_PRIMARY;
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_COLS, &cols);
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_ROWS, &rows);
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen);
    const primary = screen == vt.GHOSTTY_TERMINAL_SCREEN_PRIMARY;

    var range = std.mem.zeroes(vt.GhosttySelection);
    // The mark has no value once its row is dropped from the scrollback (or cleared), and then it all comes again.
    const marked = primary and self.link_mark != null and vt.ghostty_tracked_grid_ref_snapshot(self.link_mark, &range.start) == vt.GHOSTTY_SUCCESS;
    const top: vt.GhosttyPoint = if (primary) .{ .tag = vt.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = 0, .y = 0 } } } else activePoint(0, 0);
    if (!marked and vt.ghostty_terminal_grid_ref(self.terminal, top, &range.start) != vt.GHOSTTY_SUCCESS) return 0;
    if (vt.ghostty_terminal_grid_ref(self.terminal, activePoint(cols - 1, rows - 1), &range.end) != vt.GHOSTTY_SUCCESS) return 0;
    const n = self.format(&range, out, .vt) orelse 0;

    if (primary) {
        if (self.link_mark == null) {
            _ = vt.ghostty_terminal_grid_ref_track(self.terminal, activePoint(0, 0), &self.link_mark);
        } else {
            _ = vt.ghostty_tracked_grid_ref_set(self.link_mark, self.terminal, activePoint(0, 0));
        }
    }
    return @min(n, out.len);
}

/// The selected text, written to out. Returns the full length; 0 if nothing is selected.
pub fn selectionText(self: *Session, out: []u8) ?usize {
    self.lock();
    defer self.unlock();
    var selection: vt.GhosttySelection = undefined;
    if (vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SELECTION, &selection) != vt.GHOSTTY_SUCCESS) return 0;
    return self.format(&selection, out, .plain);
}

pub fn selectAll(self: *Session) void {
    self.lock();
    defer self.unlock();
    var selection: vt.GhosttySelection = undefined;
    if (vt.ghostty_terminal_select_all(self.terminal, &selection) == vt.GHOSTTY_SUCCESS)
        _ = vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, &selection);
}

/// Feeds a mouse event to the selection gesture and makes its result the terminal's selection.
/// Returns the autoscroll direction a drag asks for (GhosttySelectionGestureAutoscroll: 0 none, 1 up, 2 down).
/// The caller sends autoscroll events from a timer while it is not 0.
pub fn select(self: *Session, p: Pointer) u8 {
    self.lock();
    defer self.unlock();

    const kind: vt.GhosttySelectionGestureEventType = switch (p.kind) {
        .press => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS,
        .drag => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG,
        .release => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE,
        .autoscroll => vt.GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK,
    };
    var event: vt.GhosttySelectionGestureEvent = null;
    if (vt.ghostty_selection_gesture_event_new(null, &event, kind) != vt.GHOSTTY_SUCCESS) return 0;
    defer vt.ghostty_selection_gesture_event_free(event);

    // The cell under the pointer, clamped to the grid.
    var cell: vt.GhosttyPointCoordinate = .{ .x = @intCast(cellIndex(p.x, p.padding_left, p.cell_width, p.cols)), .y = cellIndex(p.y, p.padding_top, p.cell_height, p.rows) };
    var ref: vt.GhosttyGridRef = undefined;
    const point: vt.GhosttyPoint = .{ .tag = vt.GHOSTTY_POINT_TAG_VIEWPORT, .value = .{ .coordinate = cell } };
    const has_ref = vt.ghostty_terminal_grid_ref(self.terminal, point, &ref) == vt.GHOSTTY_SUCCESS;
    var position: vt.GhosttySurfacePosition = .{ .x = p.x, .y = p.y };
    var geometry: vt.GhosttySelectionGestureGeometry = .{ .columns = p.cols, .cell_width = p.cell_width, .padding_left = p.padding_left, .screen_height = p.screen_height };
    var time_ns = p.time_ns;
    var repeat_interval_ns = p.repeat_interval_ns;
    var repeat_distance = p.repeat_distance;
    var rectangle = p.rectangle;

    if (has_ref and p.kind != .autoscroll) _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
    if (p.kind != .release) _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position);
    if (p.kind == .press) {
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &time_ns);
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &repeat_interval_ns);
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &repeat_distance);
    }
    if (p.kind == .drag or p.kind == .autoscroll) {
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry);
        _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &rectangle);
    }
    if (p.kind == .autoscroll) _ = vt.ghostty_selection_gesture_event_set(event, vt.GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &cell);

    var selection: vt.GhosttySelection = undefined;
    switch (vt.ghostty_selection_gesture_event(self.gesture, self.terminal, event, &selection)) {
        vt.GHOSTTY_SUCCESS => _ = vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, &selection),
        // A plain click selects nothing and clears the old selection.
        vt.GHOSTTY_NO_VALUE => if (p.kind == .press) {
            _ = vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, null);
        },
        else => {},
    }

    var autoscroll: vt.GhosttySelectionGestureAutoscroll = vt.GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE;
    _ = vt.ghostty_selection_gesture_get(self.gesture, self.terminal, vt.GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &autoscroll);
    return @intCast(autoscroll);
}

fn cellIndex(px: f64, padding: u32, cell: u32, count: u32) u32 {
    const offset = px - @as(f64, @floatFromInt(padding));
    if (offset <= 0 or cell == 0 or count == 0) return 0;
    return @min(@as(u32, @intFromFloat(offset / @as(f64, @floatFromInt(cell)))), count - 1);
}

/// Writes the text inside selection to out, and returns its full length. The caller holds the lock.
/// plain: each row its own line, and what does not fit in out cut off at the end.
/// vt: with its styles and hyperlinks, wrapped lines joined, and what does not fit cut off at the start.
fn format(self: *Session, selection: *const vt.GhosttySelection, out: []u8, comptime as: enum { plain, vt }) ?usize {
    var formatter: vt.GhosttyFormatter = null;
    if (vt.ghostty_formatter_terminal_new(null, &formatter, self.terminal) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_formatter_free(formatter);
    _ = vt.ghostty_formatter_set(formatter, vt.GHOSTTY_FORMATTER_OPT_SELECTION, selection);
    if (as == .vt) {
        var emit: vt.GhosttyFormatterFormat = vt.GHOSTTY_FORMATTER_FORMAT_VT;
        var unwrap = true;
        _ = vt.ghostty_formatter_set(formatter, vt.GHOSTTY_FORMATTER_OPT_EMIT, &emit);
        _ = vt.ghostty_formatter_set(formatter, vt.GHOSTTY_FORMATTER_OPT_UNWRAP, &unwrap);
    }

    var buf: [*c]u8 = null;
    var n: usize = 0;
    if (vt.ghostty_formatter_format_alloc(formatter, null, &buf, &n) != vt.GHOSTTY_SUCCESS) return null;
    defer vt.ghostty_free(null, buf, n);

    const m = @min(n, out.len);
    const from = if (as == .vt) n - m else 0;
    if (m > 0) @memcpy(out[0..m], buf[from..][0..m]);
    return n;
}

fn activePoint(x: u16, y: u16) vt.GhosttyPoint {
    return .{ .tag = vt.GHOSTTY_POINT_TAG_ACTIVE, .value = .{ .coordinate = .{ .x = x, .y = y } } };
}

fn lock(self: *Session) void {
    _ = std.c.pthread_mutex_lock(&self.mutex);
}

fn unlock(self: *Session) void {
    _ = std.c.pthread_mutex_unlock(&self.mutex);
}

/// Writes directly to the terminal and signals that the screen changed.
fn feed(self: *Session, bytes: []const u8) void {
    self.lock();
    vt.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    self.unlock();

    if (!self.dirty.swap(true, .acq_rel)) {
        if (self.callbacks.on_wakeup) |f| f(self.callbacks.userdata);
    }
}

fn readLoop(self: *Session) void {
    var buf: [64 * 1024]u8 = undefined;
    var fds = [_]c.struct_pollfd{
        .{ .fd = self.pty.master, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.stop_pipe[0], .events = c.POLLIN, .revents = 0 },
    };
    while (true) {
        if (c.poll(&fds, fds.len, -1) < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            break;
        }
        if (fds[1].revents != 0) return;

        const n = c.read(self.pty.master, &buf, buf.len);
        if (n < 0 and std.c._errno().* == c.EINTR) continue;
        // When the child exits, read returns 0 or EIO.
        if (n <= 0) break;

        self.feed(buf[0..@intCast(n)]);
    }
    if (self.callbacks.on_exit) |f| f(self.callbacks.userdata);
}

/// Bytes the terminal wants to send back to the program (e.g. replies to cursor position queries).
/// Called from inside ghostty_terminal_vt_write, so the mutex is already held.
fn onWritePty(_: vt.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(userdata orelse return));
    _ = self.pty.writeAll(data[0..len]);
}

fn onTitleChanged(_: vt.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Session = @ptrCast(@alignCast(userdata orelse return));
    if (self.callbacks.on_title) |f| f(self.callbacks.userdata);
}

fn waitForText(self: *Session, needle: []const u8, out: []u8) !void {
    var tries: usize = 0;
    while (tries < 500) : (tries += 1) {
        const n = self.plainText(out) orelse return error.FormatFailed;
        if (std.mem.indexOf(u8, out[0..@min(n, out.len)], needle) != null) return;
        _ = c.usleep(10 * 1000);
    }
    return error.Timeout;
}

test "shell output reaches the terminal" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();

    // Wait for the shell to compute the result so it can be told apart from input echo.
    self.write("echo upaa-$((40+2))\n");
    var out: [4096]u8 = undefined;
    try self.waitForText("upaa-42", &out);
    try std.testing.expect(self.takeDirty());
}

test "a title set by the program can be read back" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "printf '\\033]2;upaa-title\\007title-sent'; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("title-sent", &out);
    var buf: [64]u8 = undefined;
    const n = self.title(&buf);
    try std.testing.expectEqualStrings("upaa-title", buf[0..n]);
}

test "the shell starts in the given directory, and its current directory can be read back" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "pwd; cd /bin && echo moved; read _", .cwd = "/usr" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("moved", &out);
    const n = self.plainText(&out) orelse return error.FormatFailed;
    try std.testing.expect(std.mem.indexOf(u8, out[0..@min(n, out.len)], "/usr") != null);
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("/bin", buf[0..self.cwd(&buf)]);
}

test "resize is visible to the child" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();

    self.resize(.{ .cols = 100, .rows = 30 }, 8, 16);
    self.write("stty size\n");
    var out: [4096]u8 = undefined;
    try self.waitForText("30 100", &out);
}

test "a zsh prompt that fills the width is drawn once after the width changes, as upaa's startup files mark it (#59)" {
    // Without the marks the terminal rewraps the old prompt and zsh redraws below what is left of it. Checking that
    // shows the test reproduces the bug.
    try std.testing.expect(try promptsLeftByResizes("ZDOTDIR=\"$PWD/tests/zsh\" exec zsh -i") > 0);
    try std.testing.expectEqual(@as(usize, 0), try promptsLeftByResizes(
        "UPAA_ZDOTDIR=\"$PWD/tests/zsh\" ZDOTDIR=\"$PWD/Resources/shell-integration/zsh\" exec zsh -i",
    ));
}

/// Starts zsh with the test prompt (tests/zsh/.zshrc), runs a command, changes the width a few times, and returns how
/// many more prompts are on screen than before the changes.
fn promptsLeftByResizes(command: [*:0]const u8) !usize {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = command });
    defer self.destroy();
    var out: [8192]u8 = undefined;
    try self.waitForPrompt(80, &out);

    // From the second prompt on, the marks come from PS1, which is how they are drawn again on each redraw. The first
    // prompt stays above, as an earlier prompt does, and is rewrapped like any other line. (A clear would leave it in
    // the scrollback, where a resize can bring it back.) The output is computed, so the typed command is not taken for
    // it.
    self.write("echo done-$((40+2))\n");
    try self.waitForText("done-42", &out);
    var tries: usize = 0;
    while (try self.countPrompts(&out) < 2) : (tries += 1) {
        if (tries == 500) return error.Timeout;
        _ = c.usleep(10 * 1000);
    }

    // The last width is not 80, where the first prompt alone would match waitForPrompt.
    for ([_]u16{ 50, 70, 40, 60 }) |cols| {
        self.resize(.{ .cols = cols, .rows = 24 }, 8, 16);
        try self.waitForPrompt(cols, &out);
    }
    _ = c.usleep(200 * 1000);
    return try self.countPrompts(&out) -| 2;
}

fn countPrompts(self: *Session, out: []u8) !usize {
    const n = self.plainText(out) orelse return error.FormatFailed;
    return std.mem.count(u8, out[0..@min(n, out.len)], "left");
}

/// Waits until zsh has drawn the test prompt's first line for this width: "left", dashes, "right", one column short.
fn waitForPrompt(self: *Session, cols: u16, out: []u8) !void {
    var line: [256]u8 = undefined;
    const dashes = cols - 10;
    @memcpy(line[0..4], "left");
    @memset(line[4..][0..dashes], '-');
    @memcpy(line[4 + dashes ..][0..5], "right");
    try self.waitForText(line[0 .. dashes + 9], out);
}

test "a program the shell runs in the foreground is told from the shell" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();
    self.write("sleep 5\n");
    var name: [64]u8 = undefined;
    var n: isize = -1;
    var tries: usize = 0;
    while (tries < 50) : (tries += 1) {
        n = self.running(&name);
        if (n > 0 and std.mem.eql(u8, name[0..@intCast(n)], "sleep")) break;
        _ = c.usleep(100 * 1000);
    }
    try std.testing.expectEqualStrings("sleep", name[0..@intCast(@max(n, 0))]);
}

fn typeText(self: *Session, text: []const u8) void {
    for (text) |ch| self.key(.{ .key_code = 0xFFFF, .action = .press, .text = @ptrCast(&ch), .text_len = 1 });
}

test "keys are encoded for the child" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "/bin/sh" });
    defer self.destroy();
    var out: [4096]u8 = undefined;

    // Ctrl+C (keycode 8 is C) stops sleep, and the next command runs.
    self.typeText("sleep 100");
    self.key(.{ .key_code = 36, .action = .press });
    _ = c.usleep(200 * 1000);
    self.key(.{ .key_code = 8, .action = .press, .mods = KeyEvent.Mods.ctrl, .unshifted_codepoint = 'c' });
    self.typeText("echo key-$((1+1))");
    self.key(.{ .key_code = 36, .action = .press });
    try self.waitForText("key-2", &out);
}

test "scrollback keeps history, and input returns to the live screen" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "seq 1 2000; echo seq-done; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("seq-done", &out);

    var bar: vt.GhosttyTerminalScrollbar = undefined;
    self.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP, .value = .{ .delta = 0 } });
    self.lock();
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    self.unlock();
    // All 2000 lines are kept, and the view is at the top.
    try std.testing.expect(bar.total >= 2000);
    try std.testing.expectEqual(@as(u64, 0), bar.offset);

    self.write("x");
    self.lock();
    _ = vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);
    self.unlock();
    try std.testing.expectEqual(bar.total - bar.len, bar.offset);
}

fn pointerAt(kind: Pointer.Kind, col: u32, row: u32, time_ms: u64) Pointer {
    // A 10 x 20 pixel cell on an 80 x 24 grid, pointing at the middle of the cell.
    return .{
        .kind = kind,
        .x = @floatFromInt(col * 10 + 5),
        .y = @floatFromInt(row * 20 + 10),
        .time_ns = time_ms * std.time.ns_per_ms,
        .repeat_interval_ns = 500 * std.time.ns_per_ms,
        .repeat_distance = 10,
        .cols = 80,
        .rows = 24,
        .cell_width = 10,
        .cell_height = 20,
        .screen_width = 800,
        .screen_height = 480,
    };
}

test "mouse gestures select words, ranges and everything" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "printf 'hello world\\nsecond line\\n'; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("second line", &out);

    try std.testing.expectEqual(@as(?usize, 0), self.selectionText(&out));

    // A double click selects the word under the pointer.
    _ = self.select(pointerAt(.press, 7, 0, 1000));
    _ = self.select(pointerAt(.release, 7, 0, 1000));
    _ = self.select(pointerAt(.press, 7, 0, 1100));
    _ = self.select(pointerAt(.release, 7, 0, 1100));
    try std.testing.expectEqualStrings("world", out[0..self.selectionText(&out).?]);

    // Dragging selects from the press to the pointer, across lines. libghostty-vt includes the cell under the
    // pointer only once the pointer is past its middle, so ending in the middle of cell 6 selects "second".
    _ = self.select(pointerAt(.press, 0, 0, 5000));
    _ = self.select(pointerAt(.drag, 6, 1, 5000));
    _ = self.select(pointerAt(.release, 6, 1, 5000));
    try std.testing.expectEqualStrings("hello world\nsecond", out[0..self.selectionText(&out).?]);

    // A plain click clears the selection.
    _ = self.select(pointerAt(.press, 3, 3, 9000));
    _ = self.select(pointerAt(.release, 3, 3, 9000));
    try std.testing.expectEqual(@as(?usize, 0), self.selectionText(&out));

    self.selectAll();
    const all = out[0..self.selectionText(&out).?];
    try std.testing.expect(std.mem.indexOf(u8, all, "hello world\nsecond line") != null);
}

test "paste sends safe text, and holds back text that could run a command" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "read a; read b; echo \"got:$a/$b\"; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;

    try std.testing.expectEqual(PasteResult.pasted, self.paste("one", false));
    // A line break would press Enter, so it is rejected until the user agrees.
    try std.testing.expectEqual(PasteResult.rejected, self.paste("\ntwo\n", false));
    try std.testing.expectEqual(PasteResult.pasted, self.paste("\ntwo\n", true));
    try self.waitForText("got:one/two", &out);
}

test "the find bar's search finds the matches in view and moves between them" {
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "echo one-upaa two-upaa; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("two-upaa", &out);

    var state: vt.GhosttyRenderState = null;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_render_state_new(null, &state));
    defer vt.ghostty_render_state_free(state);
    var matches: [8]Match = undefined;
    var selected: usize = 0;

    // ASCII letters match either case. The newest match is selected first.
    self.find("UPAA");
    var update = self.updateRenderState(state, &matches) orelse return error.UpdateFailed;
    try std.testing.expectEqual(@as(usize, 2), update.matches);
    try std.testing.expectEqual(@as(usize, 2), self.findCount(&selected));
    try std.testing.expectEqual(@as(usize, 1), selected);
    try std.testing.expect(matches[0].selected != matches[1].selected);
    const first = if (matches[0].selected) matches[0] else matches[1];
    try std.testing.expectEqual(@as(u16, 4), first.end.x - first.start.x + 1);

    // Next goes to the other one; the count stays.
    self.findNext(false);
    update = self.updateRenderState(state, &matches) orelse return error.UpdateFailed;
    try std.testing.expectEqual(@as(usize, 2), self.findCount(&selected));
    try std.testing.expectEqual(@as(usize, 2), selected);
    const second = if (matches[0].selected) matches[0] else matches[1];
    try std.testing.expect(!std.meta.eql(first.start, second.start));

    self.find("");
    update = self.updateRenderState(state, &matches) orelse return error.UpdateFailed;
    try std.testing.expectEqual(@as(usize, 0), update.matches);
    try std.testing.expectEqual(@as(usize, 0), self.findCount(&selected));
}

test "newText joins a wrapped address, keeps a hyperlink's target, and next time leaves out what scrolled up before" {
    // 20 columns, so the address wraps, and 3 rows, so the first lines go up into the scrollback.
    const self = try Session.create(.{ .size = .{ .cols = 20, .rows = 3 }, .command = "printf 'see https://example.com/a/long/path\\n\\033]8;;https://example.com/b\\033\\\\label\\033]8;;\\033\\\\\\n'; echo upaa-first; read _; echo upaa-second; read _" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("upaa-first", &out);

    var text: [8192]u8 = undefined;
    var n = self.newText(&text);
    try std.testing.expect(std.mem.indexOf(u8, text[0..n], "https://example.com/a/long/path") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[0..n], "\x1b]8;;https://example.com/b") != null);

    self.write("\n");
    try self.waitForText("upaa-second", &out);
    n = self.newText(&text);
    try std.testing.expect(std.mem.indexOf(u8, text[0..n], "upaa-second") != null);
    try std.testing.expect(std.mem.indexOf(u8, text[0..n], "long/path") == null);
}

test "mouse events go to programs that ask for them" {
    // Turn on button tracking with SGR encoding, then echo whatever arrives.
    const self = try Session.create(.{ .size = .{ .cols = 80, .rows = 24 }, .command = "printf '\\033[?1000h\\033[?1006h'; echo ready; cat" });
    defer self.destroy();
    var out: [4096]u8 = undefined;
    try self.waitForText("ready", &out);
    try std.testing.expect(self.wantsMouse());

    var press = pointerAt(.press, 2, 3, 0);
    press.button = 1;
    self.reportMouse(press);
    // Left button pressed on column 3, row 4 (1-based). The terminal echoes the escape as ^[.
    try self.waitForText("[<0;3;4M", &out);
}
