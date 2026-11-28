//! Settings from the config file. The Swift side reads the file and passes its text here.
//!
//! One setting per line, `key = value`. Empty lines and lines starting with `#` are ignored.
//! The keys and the color syntax are Ghostty's, so lines can be copied from a Ghostty config.
//! A line that cannot be read keeps the default, and is reported.
const Config = @This();

const std = @import("std");
const vt = @import("ghostty");

/// The font, then its fallbacks, one per line, as in Ghostty: each font-family line after the first adds a fallback,
/// and an empty one starts the list again. NUL-terminated. The last byte is never written.
font_family: [513]u8 = fixed("Menlo"),
/// Whether a font-family line has been read, so that the next one adds a fallback instead of replacing the default.
font_family_named: bool = false,
/// Points.
font_size: f64 = 13,
/// How much of the default background color covers what is behind the window (0 to 1). Cells with a color of their
/// own stay opaque. Below 1 by default, for the glass look of design A3.
background_opacity: f64 = 0.8,
/// Cells.
window_width: u16 = 80,
window_height: u16 = 24,
/// null takes design A3's color for light or dark mode (Theme).
foreground: ?vt.GhosttyColorRgb = null,
background: ?vt.GhosttyColorRgb = null,
palette: [256]?vt.GhosttyColorRgb = @splat(null),
/// The lines that could not be read, as many as fit. The Swift side words them, in the user's language.
problems: [32]Problem = undefined,
problem_count: u8 = 0,

/// A line that could not be read. Same layout as UpaaConfigProblem in Sources/CUpaaCore.
pub const Problem = extern struct {
    line: u32,
    /// Where the line's key is in the text passed to parse, in bytes. Empty for not_key_value.
    key_start: u32,
    key_len: u32,
    kind: Kind,

    pub const Kind = enum(u8) { not_key_value = 0, unknown_key = 1, invalid_value = 2 };
};

/// What the Swift side reads. Same layout as UpaaConfigValues in Sources/CUpaaCore. The pointers live as long as the Config.
pub const Values = extern struct {
    font_family: [*:0]const u8,
    font_size: f64,
    background_opacity: f64,
    window_width: u16,
    window_height: u16,
    /// The lines that could not be read.
    problems: [*]const Problem,
    problem_count: usize,
};

pub fn parse(text: []const u8) Config {
    var config: Config = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |raw| {
        number += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            config.fail(number, .not_key_value, 0, 0);
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        config.set(key, value) catch |err| config.fail(number, switch (err) {
            error.UnknownKey => .unknown_key,
            error.InvalidValue => .invalid_value,
        }, @intFromPtr(key.ptr) - @intFromPtr(text.ptr), key.len);
    }
    return config;
}

pub fn values(config: *const Config) Values {
    return .{
        .font_family = config.font_family[0 .. config.font_family.len - 1 :0].ptr,
        .font_size = config.font_size,
        .background_opacity = config.background_opacity,
        .window_width = config.window_width,
        .window_height = config.window_height,
        .problems = &config.problems,
        .problem_count = config.problem_count,
    };
}

/// Design A3's colors for light and dark mode, for what the file does not name.
const Theme = struct {
    foreground: vt.GhosttyColorRgb,
    background: vt.GhosttyColorRgb,
    /// Palette 2 to 5: green, yellow, blue, magenta. The others keep libghostty-vt's defaults.
    palette: [4]vt.GhosttyColorRgb,

    const light: Theme = .{
        .foreground = hex(0x1d1d1f),
        .background = hex(0xffffff),
        .palette = .{ hex(0x1a7f1a), hex(0x8a6a00), hex(0x0a49c9), hex(0x9b2393) },
    };
    const dark: Theme = .{
        .foreground = hex(0xf2f2f7),
        .background = hex(0x18181c),
        .palette = .{ hex(0x7ccf7c), hex(0xe5c07b), hex(0x6aa8ff), hex(0xd79be0) },
    };

    fn hex(value: u24) vt.GhosttyColorRgb {
        return .{ .r = @truncate(value >> 16), .g = @truncate(value >> 8), .b = @truncate(value) };
    }
};

/// The terminal's default background in light or dark mode.
pub fn defaultBackground(config: *const Config, dark: bool) vt.GhosttyColorRgb {
    return config.background orelse (if (dark) Theme.dark else Theme.light).background;
}

/// Sets the terminal's colors for light or dark mode: the file's, and the theme's where the file names none.
pub fn applyColors(config: *const Config, terminal: vt.GhosttyTerminal, dark: bool) void {
    const theme = if (dark) Theme.dark else Theme.light;
    const foreground = config.foreground orelse theme.foreground;
    const background = config.defaultBackground(dark);
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground);
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background);

    var palette: [256]vt.GhosttyColorRgb = undefined;
    if (vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT, &palette) != vt.GHOSTTY_SUCCESS) return;
    @memcpy(palette[2..6], &theme.palette);
    for (config.palette, &palette) |entry, *slot| if (entry) |rgb| {
        slot.* = rgb;
    };
    _ = vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette);
}

fn set(config: *Config, key: []const u8, value: []const u8) error{ UnknownKey, InvalidValue }!void {
    if (std.mem.eql(u8, key, "font-family")) {
        if (value.len == 0) {
            config.font_family = fixed("Menlo");
            config.font_family_named = false;
            return;
        }
        const start = if (config.font_family_named) std.mem.indexOfScalar(u8, &config.font_family, 0).? + 1 else 0;
        if (start + value.len >= config.font_family.len) return error.InvalidValue;
        if (start == 0) @memset(&config.font_family, 0) else config.font_family[start - 1] = '\n';
        @memcpy(config.font_family[start..][0..value.len], value);
        config.font_family_named = true;
    } else if (std.mem.eql(u8, key, "font-size")) {
        const size = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
        if (!(size >= 4 and size <= 200)) return error.InvalidValue;
        config.font_size = size;
    } else if (std.mem.eql(u8, key, "background-opacity")) {
        const opacity = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
        if (!(opacity >= 0 and opacity <= 1)) return error.InvalidValue;
        config.background_opacity = opacity;
    } else if (std.mem.eql(u8, key, "window-width")) {
        config.window_width = try cells(value, 10);
    } else if (std.mem.eql(u8, key, "window-height")) {
        config.window_height = try cells(value, 4);
    } else if (std.mem.eql(u8, key, "foreground")) {
        config.foreground = try color(value);
    } else if (std.mem.eql(u8, key, "background")) {
        config.background = try color(value);
    } else if (std.mem.eql(u8, key, "palette")) {
        var index: u8 = 0;
        var rgb: vt.GhosttyColorRgb = undefined;
        if (vt.ghostty_color_parse_palette_entry(value.ptr, value.len, &index, &rgb) != vt.GHOSTTY_SUCCESS) return error.InvalidValue;
        config.palette[index] = rgb;
    } else return error.UnknownKey;
}

fn cells(value: []const u8, min: u16) error{InvalidValue}!u16 {
    const n = std.fmt.parseInt(u16, value, 10) catch return error.InvalidValue;
    return if (n >= min and n <= 1000) n else error.InvalidValue;
}

fn color(value: []const u8) error{InvalidValue}!vt.GhosttyColorRgb {
    var rgb: vt.GhosttyColorRgb = undefined;
    if (vt.ghostty_color_parse(value.ptr, value.len, &rgb) != vt.GHOSTTY_SUCCESS) return error.InvalidValue;
    return rgb;
}

fn unquote(value: []const u8) []const u8 {
    return if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value[1 .. value.len - 1] else value;
}

fn fail(config: *Config, line: usize, kind: Problem.Kind, key_start: usize, key_len: usize) void {
    if (config.problem_count == config.problems.len) return;
    config.problems[config.problem_count] = .{
        .line = std.math.lossyCast(u32, line),
        .key_start = std.math.lossyCast(u32, key_start),
        .key_len = std.math.lossyCast(u32, key_len),
        .kind = kind,
    };
    config.problem_count += 1;
}

fn fixed(comptime text: []const u8) [513]u8 {
    var out: [513]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

test "defaults" {
    const config = parse("");
    const v = config.values();
    try std.testing.expectEqualStrings("Menlo", std.mem.span(v.font_family));
    try std.testing.expectEqual(@as(f64, 13), v.font_size);
    try std.testing.expectEqual(@as(f64, 0.8), v.background_opacity);
    try std.testing.expectEqual(@as(u16, 80), v.window_width);
    try std.testing.expectEqual(@as(u16, 24), v.window_height);
    try std.testing.expectEqual(@as(usize, 0), v.problem_count);
}

test "settings, and the lines that cannot be read" {
    const text =
        \\# comment
        \\font-family = "JetBrains Mono"
        \\font-size = 14.5
        \\background-opacity = 1
        \\window-width = 100
        \\window-height=30
        \\
        \\background = #1e1e2e
        \\palette = 1 = #ff0000
        \\bogus = 1
        \\font-size = huge
    ;
    const config = parse(text);
    const v = config.values();
    try std.testing.expectEqualStrings("JetBrains Mono", std.mem.span(v.font_family));
    try std.testing.expectEqual(@as(f64, 14.5), v.font_size);
    try std.testing.expectEqual(@as(f64, 1), v.background_opacity);
    try std.testing.expectEqual(@as(u16, 100), v.window_width);
    try std.testing.expectEqual(@as(u16, 30), v.window_height);
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, config.background.?);
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0xff, .g = 0, .b = 0 }, config.palette[1].?);
    try std.testing.expect(config.palette[2] == null);
    try std.testing.expectEqualSlices(Problem, &.{
        .{ .line = 10, .key_start = @intCast(std.mem.indexOf(u8, text, "bogus").?), .key_len = 5, .kind = .unknown_key },
        .{ .line = 11, .key_start = @intCast(std.mem.lastIndexOf(u8, text, "font-size").?), .key_len = 9, .kind = .invalid_value },
    }, v.problems[0..v.problem_count]);

    const bad = parse("window-width = 3\nwindow-width = 120\nno equals sign");
    try std.testing.expectEqual(@as(u16, 120), bad.window_width);
    const b = bad.values();
    try std.testing.expectEqualSlices(Problem, &.{
        .{ .line = 1, .key_start = 0, .key_len = 12, .kind = .invalid_value },
        .{ .line = 3, .key_start = 0, .key_len = 0, .kind = .not_key_value },
    }, b.problems[0..b.problem_count]);

    // Lines past what fits are left out.
    var lines: [200]u8 = undefined;
    for (&lines, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'x' else '\n';
    const many = parse(&lines);
    try std.testing.expectEqual(@as(usize, 32), many.values().problem_count);
    try std.testing.expectEqual(Problem{ .line = 32, .key_start = 0, .key_len = 0, .kind = .not_key_value }, many.problems[31]);
}

test "each font-family line after the first adds a fallback, and an empty one starts again" {
    const two = parse(
        \\font-family = "JetBrains Mono"
        \\font-family = Symbols Nerd Font
    );
    try std.testing.expectEqualStrings("JetBrains Mono\nSymbols Nerd Font", std.mem.span(two.values().font_family));
    const again = parse("font-family = Menlo\nfont-family =\nfont-family = Monaco");
    try std.testing.expectEqualStrings("Monaco", std.mem.span(again.values().font_family));
    const cleared = parse("font-family = Monaco\nfont-family = \"\"");
    try std.testing.expectEqualStrings("Menlo", std.mem.span(cleared.values().font_family));
}

test "colors reach the terminal" {
    var terminal: vt.GhosttyTerminal = null;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_new(null, &terminal, 10, 3));
    defer vt.ghostty_terminal_free(terminal);
    const config = parse("foreground = #102030\nbackground = black\npalette = 4=#abcdef");
    config.applyColors(terminal, true);

    var rgb: vt.GhosttyColorRgb = undefined;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND, &rgb));
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0x10, .g = 0x20, .b = 0x30 }, rgb);
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &rgb));
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0, .g = 0, .b = 0 }, rgb);
    var palette: [256]vt.GhosttyColorRgb = undefined;
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &palette));
    try std.testing.expectEqual(vt.GhosttyColorRgb{ .r = 0xab, .g = 0xcd, .b = 0xef }, palette[4]);
    try std.testing.expectEqual(Theme.dark.palette[1], palette[3]);

    // What the file does not name follows light or dark mode.
    parse("").applyColors(terminal, false);
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND, &rgb));
    try std.testing.expectEqual(Theme.light.background, rgb);
    try std.testing.expectEqual(vt.GHOSTTY_SUCCESS, vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &palette));
    try std.testing.expectEqual(Theme.light.palette[2], palette[4]);
}
