//! Functions exported to C (corresponds to Sources/CUpaaCore/include/upaa_core.h).
//! Only export fn lives here; the implementation is in each module.
const std = @import("std");
const vt = @import("ghostty");
const Session = @import("term/Session.zig");
const version = @import("version.zig");
const Config = @import("Config.zig");
const Renderer = @import("render/Renderer.zig");
const Cell = @import("render/Cell.zig").Cell;
const Frame = @import("render/Frame.zig");
const Face = @import("font/Face.zig");
const Atlas = @import("font/Atlas.zig");

comptime {
    _ = @import("term/Pty.zig");
    _ = @import("term/keymap.zig");
    _ = @import("font/Face.zig");
    _ = @import("font/Atlas.zig");
    _ = @import("render/Frame.zig");
    _ = @import("render/Mascot.zig");
    _ = @import("Config.zig");
}

/// upaa's own version (.version in build.zig.zon).
export fn upaa_version() [*:0]const u8 {
    return version.current.ptr;
}

/// True if candidate (in the form "v0.2.0") is newer than the current version.
export fn upaa_version_is_newer(candidate: [*:0]const u8) bool {
    return version.isNewer(std.mem.span(candidate));
}

// Config file

/// Reads the text of the config file (UTF-8). Settings it does not name keep their defaults. null only when out of memory.
export fn upaa_config_new(text: ?[*]const u8, len: usize) ?*Config {
    const config = std.heap.c_allocator.create(Config) catch return null;
    config.* = Config.parse(if (text) |t| t[0..len] else "");
    return config;
}

export fn upaa_config_free(config: *Config) void {
    std.heap.c_allocator.destroy(config);
}

/// The terminal's default background in light or dark mode, as 0xRRGGBB.
export fn upaa_config_background(config: *const Config, dark: bool) u32 {
    const rgb = config.defaultBackground(dark);
    return @as(u32, rgb.r) << 16 | @as(u32, rgb.g) << 8 | rgb.b;
}

export fn upaa_config_values(config: *const Config) Config.Values {
    return config.values();
}

// Terminal session

/// If command is null, starts the login shell; otherwise starts /bin/sh -c command. cwd null starts in the default directory.
/// zsh_dir is the directory with upaa's zsh startup files, used when the login shell is zsh.
/// The colors are libghostty-vt's until upaa_session_set_colors.
export fn upaa_session_new(cols: u16, rows: u16, command: ?[*:0]const u8, cwd: ?[*:0]const u8, zsh_dir: ?[*:0]const u8, callbacks: ?*const Session.Callbacks) ?*Session {
    return Session.create(.{
        .size = .{ .cols = cols, .rows = rows },
        .command = command,
        .cwd = cwd,
        .zsh_dir = zsh_dir,
        .callbacks = if (callbacks) |cb| cb.* else .{},
    }) catch null;
}

/// Sets the default colors for light or dark mode: config's, and design A3's where it names none (config null: all A3's).
export fn upaa_session_set_colors(session: *Session, config: ?*const Config, dark: bool) void {
    session.setColors(config orelse &Config{}, dark);
}

export fn upaa_session_free(session: *Session) void {
    session.destroy();
}

export fn upaa_session_write(session: *Session, data: [*]const u8, len: usize) void {
    session.write(data[0..len]);
}

/// Moves the view through the scrollback by rows (up is negative).
export fn upaa_session_scroll(session: *Session, rows: isize) void {
    session.scroll(.{ .tag = vt.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = rows } });
}

/// Feeds a mouse event to text selection. Returns the autoscroll direction (0 none, 1 up, 2 down).
export fn upaa_session_select(session: *Session, pointer: *const Session.Pointer) u8 {
    return session.select(pointer.*);
}

export fn upaa_session_select_all(session: *Session) void {
    session.selectAll();
}

/// Starts the find bar's search for needle (UTF-8) and selects the newest match. An empty needle ends the search.
export fn upaa_session_find(session: *Session, needle: [*]const u8, len: usize) void {
    session.find(needle[0..len]);
}

/// Selects the next older match (the next newer one with back), scrolling to it.
export fn upaa_session_find_next(session: *Session, back: bool) void {
    session.findNext(back);
}

/// How many matches the search has found so far. selected gets the selected one's place from the newest (1), 0 if none.
export fn upaa_session_find_count(session: *Session, selected: *usize) usize {
    return session.findCount(selected);
}

/// Whether the program asked for mouse events. If so, send clicks and the wheel to upaa_session_report_mouse unless Shift is held.
export fn upaa_session_wants_mouse(session: *Session) bool {
    return session.wantsMouse();
}

/// Sends a mouse event to the program in the format it asked for.
export fn upaa_session_report_mouse(session: *Session, pointer: *const Session.Pointer) void {
    session.reportMouse(pointer.*);
}

/// Pastes text into the shell. Returns 0 pasted, 1 rejected (could run a command; ask, then call with allow_unsafe), 2 failed.
export fn upaa_session_paste(session: *Session, text: [*]const u8, len: usize, allow_unsafe: bool) u8 {
    return @intFromEnum(session.paste(text[0..len], allow_unsafe));
}

/// The selected text. Returns the full length (0 if nothing is selected); anything beyond cap is truncated. -1 on failure.
export fn upaa_session_selection_text(session: *Session, out: [*]u8, cap: usize) isize {
    return @intCast(session.selectionText(out[0..cap]) orelse return -1);
}

export fn upaa_session_key(session: *Session, event: *const Session.KeyEvent) void {
    session.key(event.*);
}

export fn upaa_session_resize(session: *Session, cols: u16, rows: u16, cell_width_px: u32, cell_height_px: u32) void {
    session.resize(.{
        .cols = cols,
        .rows = rows,
        .width_px = std.math.lossyCast(u16, @as(u64, cols) * cell_width_px),
        .height_px = std.math.lossyCast(u16, @as(u64, rows) * cell_height_px),
    }, cell_width_px, cell_height_px);
}

export fn upaa_session_take_dirty(session: *Session) bool {
    return session.takeDirty();
}

/// The shell's current directory. Returns its length; 0 if unknown or longer than cap.
export fn upaa_session_cwd(session: *Session, out: [*]u8, cap: usize) usize {
    return session.cwd(out[0..cap]);
}

/// The program in the terminal's foreground when it is not the shell. Returns its name's length (0 if the name cannot
/// be read), -1 while the shell has the terminal.
export fn upaa_session_running(session: *Session, out: [*]u8, cap: usize) isize {
    return session.running(out[0..cap]);
}

/// The title the program set (UTF-8). Returns the full length (0 if none); anything beyond cap is truncated.
export fn upaa_session_title(session: *Session, out: [*]u8, cap: usize) usize {
    return session.title(out[0..cap]);
}

/// Returns the full length; anything beyond cap is truncated. Returns -1 on failure.
export fn upaa_session_plain_text(session: *Session, out: [*]u8, cap: usize) isize {
    return @intCast(session.plainText(out[0..cap]) orelse return -1);
}

/// The text printed since the last call, as VT sequences, for the links panel (Session.newText). Returns how many bytes
/// it wrote; if more than cap, the start is left out.
export fn upaa_session_new_text(session: *Session, out: [*]u8, cap: usize) usize {
    return session.newText(out[0..cap]);
}

// Rendering

/// If mascot is true, the axolotl is drawn behind the text.
export fn upaa_renderer_new(font_name: [*:0]const u8, font_size_px: f64, mascot: bool) ?*Renderer {
    return Renderer.create(font_name, font_size_px, mascot) catch null;
}

/// Changes the font. Returns false, keeping the old font, if the new one cannot be found.
export fn upaa_renderer_set_font(renderer: *Renderer, font_name: [*:0]const u8, font_size_px: f64) bool {
    renderer.setFont(font_name, font_size_px) catch return false;
    return true;
}

export fn upaa_renderer_free(renderer: *Renderer) void {
    renderer.destroy();
}

/// Notice drawn above the mascot (e.g. an update is available).
export fn upaa_renderer_set_note(renderer: *Renderer, text: [*:0]const u8) void {
    renderer.setNote(std.mem.span(text));
}

/// Plays the mascot's greeting again if the cell (col, row) is on it. Returns whether it was.
export fn upaa_renderer_poke_mascot(renderer: *Renderer, col: i32, row: i32) bool {
    return renderer.pokeMascot(col, row);
}

export fn upaa_renderer_metrics(renderer: *Renderer) Face.Metrics {
    return renderer.face.metrics;
}

/// Atlas image (1 byte per pixel, side upaa_renderer_atlas_size pixels).
export fn upaa_renderer_atlas_pixels(renderer: *Renderer) [*]const u8 {
    return renderer.atlas.pixels.ptr;
}

export fn upaa_renderer_atlas_size() u32 {
    return Atlas.size;
}

/// Writes the session's current screen to cells. cells may point directly into the Metal buffer's contents.
/// preedit is the IME composing string (UTF-8). null if none.
export fn upaa_renderer_frame(renderer: *Renderer, session: *Session, preedit: ?[*]const u8, preedit_len: usize, cells: [*]Cell, cap: usize) Frame.Info {
    const text: []const u8 = if (preedit) |p| p[0..preedit_len] else "";
    return renderer.buildFrame(session, text, cells[0..cap]);
}

