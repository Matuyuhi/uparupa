//! PTY and the child process (shell) running on it.
const Pty = @This();

const std = @import("std");
const c = @import("posix");

/// Parent-side fd. Reads get the child's output; writes become input to the child.
master: c_int,
child: c.pid_t,

pub const Size = struct {
    cols: u16,
    rows: u16,
    width_px: u16 = 0,
    height_px: u16 = 0,

    fn winsize(size: Size) c.struct_winsize {
        return .{ .ws_col = size.cols, .ws_row = size.rows, .ws_xpixel = size.width_px, .ws_ypixel = size.height_px };
    }
};

pub const SpawnError = error{ ForkFailed, NoShell, OutOfMemory };

/// If command is null, starts the user's login shell as a login shell, in start_dir or else the home directory.
/// If not null, runs /bin/sh -c command in start_dir or else the current directory (for tests and screen dumps).
/// zsh_dir is the directory with upaa's zsh startup files (Resources/shell-integration/zsh). A login shell that is zsh
/// starts with ZDOTDIR set to it, and the user's ZDOTDIR in UPAA_ZDOTDIR, which those files put back.
pub fn spawn(command: ?[*:0]const u8, start_dir: ?[*:0]const u8, size: Size, zsh_dir: ?[*:0]const u8) SpawnError!Pty {
    // malloc is not allowed between fork and exec, so build the needed strings before fork.
    const path: [*:0]const u8 = if (command == null) loginShell() orelse return error.NoShell else "/bin/sh";
    var argv0_buf: [256]u8 = undefined;
    var argv: [4:null]?[*:0]const u8 = if (command) |cmd|
        .{ "sh", "-c", cmd, null }
    else
        .{ loginArgv0(path, &argv0_buf), null, null, null };
    const dir: ?[*:0]const u8 = start_dir orelse if (command == null) c.getenv("HOME") else null;
    const zdotdir = if (command == null and std.mem.eql(u8, std.mem.span(argv[0].?), "-zsh")) zsh_dir else null;
    var arena: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    defer arena.deinit();
    const env = try childEnv(arena.allocator(), zdotdir);

    var ws = size.winsize();
    var master: c_int = -1;
    const pid = c.forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child process. From here to exec, call only async-signal-safe functions.
        if (dir) |d| _ = c.chdir(d);
        _ = c.execve(path, @ptrCast(&argv), @ptrCast(env.ptr));
        c._exit(127);
    }
    return .{ .master = master, .child = pid };
}

/// The child's environment: this process's, with TERM set, and with ZDOTDIR set to zdotdir if it is not null, the old
/// value moved to UPAA_ZDOTDIR. Built before fork, because setenv may allocate.
fn childEnv(arena: std.mem.Allocator, zdotdir: ?[*:0]const u8) error{OutOfMemory}![:null]?[*:0]const u8 {
    const environ: [*:null]?[*:0]const u8 = @ptrCast(c._NSGetEnviron().*);
    const count = std.mem.len(environ);
    // Room for every entry, TERM, ZDOTDIR and the null at the end.
    const env = try arena.allocSentinel(?[*:0]const u8, count + 3, null);
    var n: usize = 0;
    for (environ[0..count]) |entry| {
        const s = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, s, "TERM=")) continue;
        if (zdotdir != null and std.mem.startsWith(u8, s, "UPAA_ZDOTDIR=")) continue;
        env[n] = if (zdotdir != null and std.mem.startsWith(u8, s, "ZDOTDIR="))
            (try std.fmt.allocPrintSentinel(arena, "UPAA_{s}", .{s}, 0)).ptr
        else
            entry;
        n += 1;
    }
    env[n] = "TERM=xterm-256color";
    n += 1;
    if (zdotdir) |z| {
        env[n] = (try std.fmt.allocPrintSentinel(arena, "ZDOTDIR={s}", .{z}, 0)).ptr;
        n += 1;
    }
    env[n] = null;
    return env[0..n :null];
}

pub fn resize(pty: Pty, size: Size) void {
    var ws = size.winsize();
    _ = c.ioctl(pty.master, c.TIOCSWINSZ, &ws);
}

/// Repeats until everything is written. Returns false if writing fails, e.g. because the child has exited.
pub fn writeAll(pty: Pty, bytes: []const u8) bool {
    var rest = bytes;
    while (rest.len > 0) {
        const n = c.write(pty.master, rest.ptr, rest.len);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return false;
        }
        rest = rest[@intCast(n)..];
    }
    return true;
}

/// The child's current directory, read from the kernel, so the shell needs no setup to report it. null if unknown.
pub fn cwd(pty: Pty, out: []u8) ?[]const u8 {
    var info: c.struct_proc_vnodepathinfo = undefined;
    const size: c_int = @sizeOf(c.struct_proc_vnodepathinfo);
    if (c.proc_pidinfo(pty.child, c.PROC_PIDVNODEPATHINFO, 0, &info, size) != size) return null;
    const path = std.mem.sliceTo(&info.pvi_cdir.vip_path, 0);
    if (path.len == 0 or path.len > out.len) return null;
    @memcpy(out[0..path.len], path);
    return out[0..path.len];
}

/// The name of the program in the terminal's foreground when it is not the shell (a command the shell started), copied
/// into out; "" when its name cannot be read. null while the shell itself has the terminal.
pub fn running(pty: Pty, out: []u8) ?[]const u8 {
    const group = c.tcgetpgrp(pty.master);
    if (group <= 0 or group == pty.child) return null;
    const n = c.proc_name(group, out.ptr, @intCast(out.len));
    if (n > 0) return out[0..@intCast(n)];
    // proc_name reads only the user's own processes, and a setuid program (top, sudo) runs as root. The kernel's
    // process table, which ps reads, gives any process's name, cut to 16 bytes.
    var mib = [_]c_int{ c.CTL_KERN, c.KERN_PROC, c.KERN_PROC_PID, group };
    var info: c.struct_kinfo_proc = undefined;
    var size: usize = @sizeOf(c.struct_kinfo_proc);
    if (c.sysctl(&mib, mib.len, &info, &size, null, 0) != 0 or size == 0) return out[0..0];
    const name = std.mem.sliceTo(&info.kp_proc.p_comm, 0);
    const len = @min(name.len, out.len);
    @memcpy(out[0..len], name[0..len]);
    return out[0..len];
}

/// Terminates the child process, reaps it, and closes the fd.
pub fn deinit(pty: Pty) void {
    _ = c.kill(pty.child, c.SIGHUP);
    _ = c.close(pty.master);
    var status: c_int = 0;
    _ = c.waitpid(pty.child, &status, 0);
}

fn loginShell() ?[*:0]const u8 {
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.*.pw_shell) |shell| {
            if (shell[0] != 0) return shell;
        }
    }
    return c.getenv("SHELL");
}

/// Sets argv[0] to the "-zsh" form, following the convention for starting a login shell.
fn loginArgv0(path: [*:0]const u8, buf: []u8) [*:0]const u8 {
    const full = std.mem.span(path);
    const base = if (std.mem.lastIndexOfScalar(u8, full, '/')) |i| full[i + 1 ..] else full;
    if (base.len + 2 > buf.len) return path;
    buf[0] = '-';
    @memcpy(buf[1..][0..base.len], base);
    buf[1 + base.len] = 0;
    return @ptrCast(buf.ptr);
}

test "login argv0" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("-zsh", std.mem.span(loginArgv0("/bin/zsh", &buf)));
}

test "the child's environment sets TERM and ZDOTDIR once each" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var terms: usize = 0;
    var zdotdirs: usize = 0;
    for (try childEnv(arena.allocator(), "/upaa/zsh")) |entry| {
        const s = std.mem.span(entry.?);
        if (std.mem.startsWith(u8, s, "TERM=")) {
            try std.testing.expectEqualStrings("TERM=xterm-256color", s);
            terms += 1;
        }
        if (std.mem.startsWith(u8, s, "ZDOTDIR=")) {
            try std.testing.expectEqualStrings("ZDOTDIR=/upaa/zsh", s);
            zdotdirs += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), terms);
    try std.testing.expectEqual(@as(usize, 1), zdotdirs);
}
