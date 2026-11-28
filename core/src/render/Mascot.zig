//! The axolotl drawn faintly behind the terminal text. It only fills cells that show nothing (no glyph, which
//! includes spaces) and keep the default background, so text and colored backgrounds cover it.
//! The pictures are braille text with 24-bit colors (mascot/*.ans), made with a drawing tool kept outside this repository.
const Mascot = @This();

const std = @import("std");
const Atlas = @import("../font/Atlas.zig");
const Face = @import("../font/Face.zig");
const Cell = @import("Cell.zig").Cell;

pub const width = 39;
pub const height = 18;
/// Columns between the picture and the right edge. The bottom of the picture (the body) is cut off by the bottom edge.
const right_margin = 2;
/// How much of the picture's color shows over the background, out of 20.
const strength = 7;
const note_color = [4]u8{ 233, 111, 146, 255 };

/// When the greeting started (milliseconds on the monotonic clock).
greeted_ms: u64,
/// When something last happened in the pane (output, a key, a click). The idle loop stops rest_after_ms later.
woke_ms: u64,

/// One cell of a picture: the braille dots that are set (the low byte of U+28xx, 0 for none) and their color.
const Dot = struct { bits: u8 = 0, color: [3]u8 = .{ 0, 0, 0 } };
const Picture = [height][width]Dot;

const Pose = enum { closed, half, open, wide, settle, blink, gill_a, gill_b };
/// In the order of Pose.
const files = [_][]const u8{ "mouth-closed", "mouth-half", "mouth-open", "mouth-wide", "settle", "blink", "idle-gill-a", "idle-gill-b" };

const pictures = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: [files.len]Picture = undefined;
    for (files, &out) |name, *picture| picture.* = parse(@embedFile("mascot/" ++ name ++ ".ans"));
    break :blk out;
};

const Step = struct { pose: Pose, ms: u32 };

/// Opens the mouth wide and closes it. Played at startup and when the picture is clicked.
const greeting = [_]Step{
    .{ .pose = .closed, .ms = 600 }, .{ .pose = .half, .ms = 60 },   .{ .pose = .open, .ms = 60 },
    .{ .pose = .wide, .ms = 280 },   .{ .pose = .open, .ms = 70 },   .{ .pose = .half, .ms = 70 },
    .{ .pose = .settle, .ms = 90 },  .{ .pose = .closed, .ms = 500 },
};

/// Repeated after the greeting: the gills sway, and now and then it blinks.
const idle = [_]Step{
    .{ .pose = .gill_a, .ms = 380 }, .{ .pose = .closed, .ms = 380 }, .{ .pose = .gill_b, .ms = 380 },
    .{ .pose = .closed, .ms = 380 }, .{ .pose = .blink, .ms = 110 },  .{ .pose = .closed, .ms = 400 },
    .{ .pose = .gill_a, .ms = 380 }, .{ .pose = .closed, .ms = 380 }, .{ .pose = .gill_b, .ms = 380 },
    .{ .pose = .closed, .ms = 600 },
};

/// After this long with nothing happening, the idle loop stops at the end of a loop, and the picture rests with its
/// mouth closed until something happens, so nothing is drawn meanwhile.
const rest_after_ms = 30_000;

pub fn init(now_ms: u64) Mascot {
    return .{ .greeted_ms = now_ms, .woke_ms = now_ms };
}

/// Something happened in the pane: the idle loop goes on (again) for rest_after_ms.
pub fn wake(m: *Mascot, now_ms: u64) void {
    m.woke_ms = now_ms;
}

/// Plays the greeting again, starting with the mouth opening.
pub fn poke(m: *Mascot, now_ms: u64) void {
    m.greeted_ms = now_ms -| greeting[0].ms;
    m.woke_ms = now_ms;
}

/// Whether the cell (col, row) is inside the picture on a cols x rows screen.
pub fn covers(cols: u16, rows: u16, col: i32, row: i32) bool {
    const top = origin(cols, rows);
    return col >= top.col and col < top.col + width and row >= top.row and row < rows;
}

/// Draws the picture for now_ms into the blank cells of a whole screen (cols x rows cells, row by row).
/// Returns the milliseconds until the picture changes, or 0 if it rests or none of it is visible.
pub fn draw(m: Mascot, cells: []Cell, cols: u16, rows: u16, background: [4]u8, face: Face, atlas: *Atlas, now_ms: u64) u32 {
    const current = m.shown(now_ms);
    const top = origin(cols, rows);
    var visible = false;
    for (current.picture, 0..) |line, y| {
        const row = top.row + @as(i32, @intCast(y));
        if (row < 0) continue;
        for (line, 0..) |dot, x| {
            const col = top.col + @as(i32, @intCast(x));
            if (dot.bits == 0 or col < 0 or col >= cols) continue;
            const cell = blank(cells, cols, @intCast(col), @intCast(row), background) orelse continue;
            cell.glyph = atlas.get(face, &braille(dot.bits));
            cell.fg = faint(dot.color, background);
            visible = true;
        }
    }
    return if (visible) current.next_ms else 0;
}

/// Draws the note into the blank cells of the row above the picture, also when the mascot is off, since the note is
/// how an update is told. It ends where the picture ends. It is ASCII (UpdateCheck.swift), so one byte is one cell.
pub fn drawNote(cells: []Cell, cols: u16, rows: u16, background: [4]u8, note: []const u8, face: Face, atlas: *Atlas) void {
    const top = origin(cols, rows);
    const note_row = top.row - 1;
    if (note_row < 0) return;
    const start = top.col + width - @as(i32, @intCast(note.len));
    for (note, 0..) |ch, i| {
        const col = start + @as(i32, @intCast(i));
        if (col < 0 or col >= cols) continue;
        const cell = blank(cells, cols, @intCast(col), @intCast(note_row), background) orelse continue;
        cell.glyph = atlas.get(face, &.{ch});
        cell.fg = note_color;
    }
}

fn origin(cols: u16, rows: u16) struct { col: i32, row: i32 } {
    return .{ .col = @as(i32, cols) - width - right_margin, .row = @as(i32, rows) - height };
}

const Shown = struct { picture: *const Picture, next_ms: u32 };

fn shown(m: Mascot, now_ms: u64) Shown {
    const t = now_ms -| m.greeted_ms;
    if (t < total(&greeting)) return at(&greeting, t);
    const idle_t = t - total(&greeting);
    // Whole loops, counted from the end of the greeting, until rest_after_ms past the last wake.
    const awake_ms = (m.woke_ms + rest_after_ms) -| (m.greeted_ms + total(&greeting));
    const loops = (awake_ms + total(&idle) - 1) / total(&idle);
    if (idle_t >= loops * total(&idle)) return .{ .picture = &pictures[@intFromEnum(Pose.closed)], .next_ms = 0 };
    return at(&idle, idle_t % total(&idle));
}

fn at(steps: []const Step, t: u64) Shown {
    var left = t;
    for (steps) |step| {
        if (left < step.ms) return .{ .picture = &pictures[@intFromEnum(step.pose)], .next_ms = @intCast(step.ms - left) };
        left -= step.ms;
    }
    unreachable;
}

fn total(steps: []const Step) u64 {
    var sum: u64 = 0;
    for (steps) |step| sum += step.ms;
    return sum;
}

/// The cell at (col, row) if nothing is drawn in it: no glyph, no flags (underline, half of a wide character),
/// and the default background.
fn blank(cells: []Cell, cols: u16, col: u16, row: u16, background: [4]u8) ?*Cell {
    const cell = &cells[@as(usize, row) * cols + col];
    if (cell.glyph.width != 0 or cell.flags != 0 or !std.mem.eql(u8, &cell.bg, &background)) return null;
    return cell;
}

fn braille(bits: u8) [3]u8 {
    return .{ 0xE2, 0xA0 | (bits >> 6), 0x80 | (bits & 0x3F) };
}

fn faint(color: [3]u8, background: [4]u8) [4]u8 {
    var out = background;
    for (color, out[0..3]) |c, *o| {
        const bg: i32 = o.*;
        o.* = @intCast(bg + @divTrunc((@as(i32, c) - bg) * strength, 20));
    }
    return out;
}

/// Reads one picture: lines of braille characters and spaces, colored with \x1b[38;2;r;g;bm and reset with \x1b[0m.
fn parse(comptime ans: []const u8) Picture {
    var picture: Picture = @splat(@splat(.{}));
    var row: usize = 0;
    var col: usize = 0;
    var color: [3]u8 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (i < ans.len) {
        switch (ans[i]) {
            '\n' => {
                row += 1;
                col = 0;
                i += 1;
            },
            ' ' => {
                col += 1;
                i += 1;
            },
            0x1B => {
                const end = std.mem.indexOfScalarPos(u8, ans, i, 'm').?;
                var params = std.mem.splitScalar(u8, ans[i + 2 .. end], ';');
                if (std.mem.eql(u8, params.first(), "38")) {
                    _ = params.next();
                    for (&color) |*channel| channel.* = std.fmt.parseInt(u8, params.next().?, 10) catch unreachable;
                }
                i = end + 1;
            },
            // U+2800 to U+28FF is E2 A0..A3 80..BF in UTF-8.
            0xE2 => {
                picture[row][col] = .{ .bits = (ans[i + 1] & 0x03) << 6 | (ans[i + 2] & 0x3F), .color = color };
                col += 1;
                i += 3;
            },
            else => @compileError("unexpected byte in the mascot picture"),
        }
    }
    if (row != height) @compileError("the mascot picture must have 18 lines");
    return picture;
}

test "the pictures differ by pose" {
    for (pictures) |picture| {
        var dots: usize = 0;
        for (picture) |line| for (line) |dot| {
            if (dot.bits != 0) dots += 1;
        };
        try std.testing.expect(dots > 200);
    }
    const closed = pictures[@intFromEnum(Pose.closed)];
    for ([_]Pose{ .wide, .blink, .gill_a }) |pose| {
        try std.testing.expect(!std.meta.eql(closed, pictures[@intFromEnum(pose)]));
    }
}

test "greets, then idles, and greets again when poked" {
    var m: Mascot = .init(10_000);
    try std.testing.expectEqual(Shown{ .picture = &pictures[@intFromEnum(Pose.closed)], .next_ms = 600 }, m.shown(10_000));
    try std.testing.expectEqual(Shown{ .picture = &pictures[@intFromEnum(Pose.half)], .next_ms = 10 }, m.shown(10_650));
    const idle_start = 10_000 + total(&greeting);
    try std.testing.expectEqual(&pictures[@intFromEnum(Pose.gill_a)], m.shown(idle_start).picture);
    try std.testing.expectEqual(&pictures[@intFromEnum(Pose.gill_a)], m.shown(idle_start + total(&idle)).picture);

    m.poke(20_000);
    try std.testing.expectEqual(&pictures[@intFromEnum(Pose.half)], m.shown(20_000).picture);
}

test "rests with the mouth closed at the end of a loop when nothing happens, and idles again when woken" {
    var m: Mascot = .init(0);
    const loop = total(&idle);
    const idle_start = total(&greeting);
    // The loop that is playing when rest_after_ms passes is played to its end.
    const rest_at = idle_start + (rest_after_ms - idle_start + loop - 1) / loop * loop;
    try std.testing.expect(m.shown(rest_at - 1).next_ms > 0);
    const rest: Shown = .{ .picture = &pictures[@intFromEnum(Pose.closed)], .next_ms = 0 };
    try std.testing.expectEqual(rest, m.shown(rest_at));
    try std.testing.expectEqual(rest, m.shown(rest_at + 600_000));

    m.wake(rest_at + 600_000);
    try std.testing.expect(m.shown(rest_at + 600_000).next_ms > 0);
    try std.testing.expect(m.shown(rest_at + 600_000 + rest_after_ms - 1).next_ms > 0);
    try std.testing.expectEqual(rest, m.shown(rest_at + 600_000 + rest_after_ms + loop));
}

test "drawn only into blank cells, at the bottom right, with the note above" {
    const face = try Face.init("Menlo", 26);
    defer face.deinit();
    var atlas = try Atlas.init();
    defer atlas.deinit();

    const cols = 80;
    const rows = 24;
    const bg = [4]u8{ 0, 0, 0, 255 };
    var cells: [cols * rows]Cell = undefined;
    for (&cells, 0..) |*cell, i| cell.* = .{ .col = @intCast(i % cols), .row = @intCast(i / cols), .glyph = .{}, .fg = .{ 255, 255, 255, 255 }, .bg = bg };

    // A cell of the picture that has dots, with text already in it.
    const m: Mascot = .init(0);
    const picture = m.shown(0).picture;
    const top = origin(cols, rows);
    const y = 10;
    const x = for (picture[y], 0..) |dot, x| {
        if (dot.bits != 0) break x;
    } else unreachable;
    const text_index = @as(usize, @intCast(top.row + y)) * cols + @as(usize, @intCast(top.col)) + x;
    cells[text_index].glyph = atlas.get(face, "A");
    const text_cell = cells[text_index];

    try std.testing.expectEqual(@as(u32, 600), m.draw(&cells, cols, rows, bg, face, &atlas, 0));
    drawNote(&cells, cols, rows, bg, "v9.9.9", face, &atlas);
    try std.testing.expectEqual(text_cell, cells[text_index]);
    const beside = cells[text_index + 1];
    if (picture[y][x + 1].bits != 0) {
        try std.testing.expect(beside.glyph.width > 0);
        try std.testing.expect(beside.fg[0] < picture[y][x + 1].color[0]);
    }
    // Nothing above the note, which sits right above the picture.
    const note_y: usize = @intCast(top.row - 1);
    for (cells[0 .. note_y * cols]) |cell| try std.testing.expectEqual(@as(u16, 0), cell.glyph.width);
    const note_row = cells[note_y * cols ..][0..cols];
    try std.testing.expect(note_row[@as(usize, @intCast(top.col + width - 1))].glyph.width > 0);
    try std.testing.expectEqual(note_color, note_row[@as(usize, @intCast(top.col + width - 1))].fg);

    try std.testing.expect(covers(cols, rows, top.col, rows - 1));
    try std.testing.expect(!covers(cols, rows, top.col - 1, rows - 1));
}
