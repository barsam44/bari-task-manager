// Linux process backend: parses /proc for per-process CPU/RAM and totals.
const std = @import("std");
const proc = @import("proc.zig");

const CLK_TCK = 100; // USER_HZ on every Linux target we care about

const PrevEntry = struct { pid: u32 = 0, ticks: u64 = 0 };
var prev: [proc.MAX_PROCS]PrevEntry = undefined;
var prev_n: usize = 0;
var prev_busy: u64 = 0;
var prev_total: u64 = 0;
var prev_wall_ms: i64 = 0;
var cores: usize = 1;
var self_pid: u32 = 0;

pub fn sample(snap: *proc.Snapshot) void {
    const now_ms = std.time.milliTimestamp();
    if (self_pid == 0) {
        self_pid = @intCast(std.c.getpid());
    }
    if (cores == 1) {
        cores = std.Thread.getCpuCount() catch 1;
    }
    const wall_s: f64 = if (prev_wall_ms == 0)
        0
    else
        @as(f64, @floatFromInt(now_ms - prev_wall_ms)) / 1000.0;

    var n_proc_ticks: usize = 0;

    // ---- per-process pass ----
    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        return;
    };
    defer dir.close();

    var n: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (n >= proc.MAX_PROCS) break;
        const pid = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        var stat_buf: [4096]u8 = undefined;
        const stat_len = readFile(dir, entry.name, "stat", &stat_buf) orelse continue;
        var ticks: u64 = 0;
        var comm_len: usize = 0;
        var comm_buf: [264]u8 = undefined;
        parseStat(stat_buf[0..stat_len], &ticks, &comm_buf, &comm_len);
        if (comm_len == 0) continue;

        var mem: u64 = 0;
        var statm_buf: [512]u8 = undefined;
        if (readFile(dir, entry.name, "statm", &statm_buf)) |slen| {
            var toks = std.mem.tokenizeAny(u8, statm_buf[0..slen], " \t\n");
            _ = toks.next(); // size
            if (toks.next()) |res| {
                const pages = std.fmt.parseInt(u64, res, 10) catch 0;
                mem = pages * 4096;
            }
        }

        // cpu delta vs previous sample
        var cpu_pct: f32 = 0;
        if (wall_s > 0.05) {
            var p_ticks: ?u64 = null;
            var j: usize = 0;
            while (j < prev_n) : (j += 1) {
                if (prev[j].pid == pid) {
                    p_ticks = prev[j].ticks;
                    break;
                }
            }
            if (p_ticks) |pt| {
                const d = ticks -| pt;
                cpu_pct = @floatCast(@min(100.0, @as(f64, @floatFromInt(d)) / (wall_s * CLK_TCK * @as(f64, @floatFromInt(cores))) * 100.0));
            }
        }

        const p = &snap.procs[n];
        p.* = .{};
        p.pid = pid;
        p.cpu = cpu_pct;
        p.mem = mem;
        p.killable = pid != self_pid;
        p.setName(comm_buf[0..comm_len]);
        n += 1;

        // record for next pass
        if (n_proc_ticks < proc.MAX_PROCS) {
            prev[n_proc_ticks] = .{ .pid = pid, .ticks = ticks };
            n_proc_ticks += 1;
        }
    }
    snap.n = n;
    prev_n = n_proc_ticks;
    prev_wall_ms = now_ms;

    // ---- totals ----
    var t = proc.Totals{};
    t.count = @intCast(n);

    var stat_buf: [4096]u8 = undefined;
    if (readTopLevel("stat", &stat_buf)) |len| {
        if (parseCpuLine(stat_buf[0..len])) |ct| {
            if (prev_wall_ms != 0 and prev_total > 0) {
                const dtot = ct.total -| prev_total;
                const dbusy = ct.busy -| prev_busy;
                if (dtot > 0) {
                    t.cpu = @floatCast(@min(100.0, @as(f64, @floatFromInt(dbusy)) / @as(f64, @floatFromInt(dtot)) * 100.0));
                }
            }
            prev_total = ct.total;
            prev_busy = ct.busy;
        }
    }

    var meminfo_buf: [4096]u8 = undefined;
    if (readTopLevel("meminfo", &meminfo_buf)) |len| {
        var mem_total: u64 = 0;
        var mem_avail: u64 = 0;
        var lines = std.mem.splitScalar(u8, meminfo_buf[0..len], '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "MemTotal:")) {
                mem_total = kbSuffix(line) * 1024;
            } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
                mem_avail = kbSuffix(line) * 1024;
            }
        }
        if (mem_total > 0) {
            t.ram_total = mem_total;
            t.ram_used = mem_total -| mem_avail;
        }
    }

    var uptime_buf: [256]u8 = undefined;
    if (readTopLevel("uptime", &uptime_buf)) |len| {
        var toks = std.mem.tokenizeScalar(u8, uptime_buf[0..len], ' ');
        if (toks.next()) |up| {
            var intpart = up;
            if (std.mem.indexOfScalar(u8, up, '.')) |dot| intpart = up[0..dot];
            t.uptime_s = std.fmt.parseInt(u64, intpart, 10) catch 0;
        }
    }

    snap.totals = t;
}

pub fn kill(pid: u32) bool {
    std.posix.kill(@intCast(pid), std.posix.SIG.TERM) catch return false;
    return true;
}

// ---------------------------------------------------------------- helpers

fn readFile(dir: std.fs.Dir, pid_name: []const u8, file_name: []const u8, buf: []u8) ?usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ pid_name, file_name }) catch return null;
    const f = dir.openFile(path, .{}) catch return null;
    defer f.close();
    return f.readAll(buf) catch null;
}

fn readTopLevel(file_name: []const u8, buf: []u8) ?usize {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{s}", .{file_name}) catch return null;
    const f = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer f.close();
    return f.readAll(buf) catch null;
}

/// /proc/[pid]/stat: "pid (comm) state ... utime stime" - comm may contain
/// spaces and parentheses, so locate the last ')' before parsing numbers.
fn parseStat(data: []const u8, ticks: *u64, comm: *[264]u8, comm_len: *usize) void {
    const close = std.mem.lastIndexOfScalar(u8, data, ')') orelse return;
    const open = std.mem.indexOfScalar(u8, data, '(') orelse return;
    if (close <= open) return;
    const cname = data[open + 1 .. close];
    const cn = @min(cname.len, comm.len);
    @memcpy(comm[0..cn], cname[0..cn]);
    comm_len.* = cn;

    var toks = std.mem.tokenizeAny(u8, data[close + 1 ..], " \t\n");
    // after ')': state(0) ppid(1) pgrp(2) session(3) tty(4) tpgid(5) flags(6)
    //            minflt(7) cminflt(8) majflt(9) cmajflt(10) utime(11) stime(12)
    var idx: usize = 0;
    var utime: u64 = 0;
    var stime: u64 = 0;
    while (toks.next()) |tok| {
        if (idx == 11) utime = std.fmt.parseInt(u64, tok, 10) catch 0;
        if (idx == 12) {
            stime = std.fmt.parseInt(u64, tok, 10) catch 0;
            break;
        }
        idx += 1;
    }
    ticks.* = utime + stime;
}

fn parseCpuLine(data: []const u8) ?struct { total: u64, busy: u64 } {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const first = lines.next() orelse return null;
    if (!std.mem.startsWith(u8, first, "cpu ")) return null;
    var toks = std.mem.tokenizeAny(u8, first[3..], " \t");
    var total: u64 = 0;
    var idle: u64 = 0;
    var iowait: u64 = 0;
    var i: usize = 0;
    while (toks.next()) |tok| {
        const v = std.fmt.parseInt(u64, tok, 10) catch 0;
        if (i == 3) idle = v;
        if (i == 4) iowait = v;
        if (i < 8) total += v;
        i += 1;
    }
    return .{ .total = total, .busy = total -| (idle + iowait) };
}

fn kbSuffix(line: []const u8) u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 0;
    var toks = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const tok = toks.next() orelse return 0;
    return std.fmt.parseInt(u64, tok, 10) catch 0;
}
