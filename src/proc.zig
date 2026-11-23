// Process snapshot abstraction. Platform backends live in proc_linux.zig /
// proc_windows.zig and are selected at compile time.
const std = @import("std");
const builtin = @import("builtin");

pub const MAX_PROCS = 2048;

pub const Process = struct {
    pid: u32 = 0,
    cpu: f32 = 0, // % of total machine capacity (0..100*? can exceed 100 on many cores? no: normalized to all cores, 0..100)
    mem: u64 = 0, // resident bytes
    killable: bool = false,
    name_len: u16 = 0,
    name_buf: [264]u8 = undefined,

    pub fn name(self: *const Process) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn setName(self: *Process, src: []const u8) void {
        const n = @min(src.len, self.name_buf.len);
        @memcpy(self.name_buf[0..n], src[0..n]);
        self.name_len = @intCast(n);
    }
};

pub const Totals = struct {
    cpu: f32 = 0, // 0..100
    ram_used: u64 = 0,
    ram_total: u64 = 0,
    count: u32 = 0,
    uptime_s: u64 = 0,
};

pub const Snapshot = struct {
    procs: [MAX_PROCS]Process = undefined,
    n: usize = 0,
    totals: Totals = .{},
};

const impl = if (builtin.os.tag == .windows)
    @import("proc_windows.zig")
else
    @import("proc_linux.zig");

pub fn sample(snap: *Snapshot) void {
    impl.sample(snap);
}

pub fn kill(pid: u32) bool {
    return impl.kill(pid);
}
