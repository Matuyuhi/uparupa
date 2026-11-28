//! Holds the font, atlas, and render state together, and builds one frame of cells from the terminal session.
const Renderer = @This();

const std = @import("std");
const vt = @import("ghostty");
const Atlas = @import("../font/Atlas.zig");
const Face = @import("../font/Face.zig");
const Session = @import("../term/Session.zig");
const Cell = @import("Cell.zig").Cell;
const Frame = @import("Frame.zig");
const Mascot = @import("Mascot.zig");

const alloc = std.heap.c_allocator;

face: Face,
atlas: Atlas,
state: vt.GhosttyRenderState,
frame: Frame,
/// null when the mascot is not drawn (turned off in the config, and in snapshots).
mascot: ?Mascot,
/// Notice drawn above the mascot (e.g. an update is available).
note: [160]u8 = undefined,
note_len: usize = 0,
/// Grid size of the last frame, to tell whether a click hit the mascot.
cols: u16 = 0,
rows: u16 = 0,

pub fn create(font_name: [*:0]const u8, font_size_px: f64, mascot: bool) !*Renderer {
    const self = try alloc.create(Renderer);
    errdefer alloc.destroy(self);

    const face = try Face.init(font_name, font_size_px);
    errdefer face.deinit();
    var atlas = try Atlas.init();
    errdefer atlas.deinit();
    var state: vt.GhosttyRenderState = null;
    if (vt.ghostty_render_state_new(null, &state) != vt.GHOSTTY_SUCCESS) return error.OutOfMemory;
    errdefer vt.ghostty_render_state_free(state);
    const frame = try Frame.init();

    self.* = .{
        .face = face,
        .atlas = atlas,
        .state = state,
        .frame = frame,
        .mascot = if (mascot) .init(nowMs()) else null,
    };
    return self;
}

pub fn destroy(self: *Renderer) void {
    self.frame.deinit();
    vt.ghostty_render_state_free(self.state);
    self.atlas.deinit();
    self.face.deinit();
    alloc.destroy(self);
}

/// Writes the session's current screen to out. preedit is the IME composing string (empty if none).
pub fn buildFrame(self: *Renderer, session: *Session, preedit: []const u8, out: []Cell) Frame.Info {
    // Matches past this many in view are not marked.
    var matches: [512]Session.Match = undefined;
    const update = session.updateRenderState(self.state, &matches) orelse return .{};
    var info = self.frame.build(self.state, self.face, &self.atlas, preedit, matches[0..update.matches], out);
    info.searching = update.searching;
    _ = vt.ghostty_render_state_clean(self.state);
    self.cols = info.cols;
    self.rows = info.rows;
    if (self.mascot) |mascot| if (info.cell_count == @as(u32, info.cols) * info.rows) {
        const note = self.note[0..self.note_len];
        info.mascot_next_ms = mascot.draw(out[0..info.cell_count], info.cols, info.rows, info.background, note, self.face, &self.atlas, nowMs());
        info.atlas_generation = self.atlas.generation;
    };
    return info;
}

/// Changes the font (Face.init's names). Keeps the old one if the new one cannot be found.
pub fn setFont(self: *Renderer, font_name: [*:0]const u8, font_size_px: f64) error{FontNotFound}!void {
    const face = try Face.init(font_name, font_size_px);
    self.face.deinit();
    self.face = face;
    self.atlas.clear();
}

pub fn setNote(self: *Renderer, text: []const u8) void {
    self.note_len = @min(text.len, self.note.len);
    @memcpy(self.note[0..self.note_len], text[0..self.note_len]);
}

/// Turns the mascot on (with its greeting) or off.
pub fn setMascot(self: *Renderer, on: bool) void {
    if (on == (self.mascot != null)) return;
    self.mascot = if (on) .init(nowMs()) else null;
}

/// Something happened in the pane, so the mascot's idle loop goes on for a while longer.
pub fn wakeMascot(self: *Renderer) void {
    if (self.mascot) |*mascot| mascot.wake(nowMs());
}

/// Plays the mascot's greeting again if the cell (col, row) is on it. Returns whether it was.
pub fn pokeMascot(self: *Renderer, col: i32, row: i32) bool {
    if (self.mascot) |*mascot| if (Mascot.covers(self.cols, self.rows, col, row)) {
        mascot.poke(nowMs());
        return true;
    };
    return false;
}

fn nowMs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}
