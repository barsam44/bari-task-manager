// Windows process backend: Toolhelp32 snapshot + GetProcessTimes +
// K32GetProcessMemoryInfo / K32GetPerformanceInfo. Compiled by Zig's
// windows-gnu cross toolchain; Win32 imports are declared manually so no
// translate-c on windows.h is needed.
const std = @import("std");
const proc = @import("proc.zig");

const TH32CS_SNAPPROCESS: u32 = 0x2;
const PROCESS_TERMINATE: u32 = 0x1;
const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;

const HANDLE = ?*anyopaque;

const FILETIME = extern struct { dwLowDateTime: u32 = 0, dwHighDateTime: u32 = 0 };

fn ftU64(ft: FILETIME) u64 {
    return (@as(u64, ft.dwHighDateTime) << 32) | @as(u64, ft.dwLowDateTime);
}

const PROCESSENTRY32W = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ProcessID: u32,
    th32DefaultHeapID: usize,
    th32ModuleID: u32,
    cntThreads: u32,
    th32ParentProcessID: u32,
    pcPriClassBase: i32,
    dwFlags: u32,
    szExeFile: [260]u16,
};

const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: u32,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};

const PERFORMANCE_INFORMATION = extern struct {
    cb: u32,
    CommitTotal: usize,
    CommitLimit: usize,
    CommitPeak: usize,
    PhysicalTotal: usize,
    PhysicalAvailable: usize,
    SystemCache: usize,
    KernelTotal: usize,
    KernelPaged: usize,
    KernelNonPaged: usize,
    PageSize: usize,
    HandleCount: u32,
    ProcessCount: u32,
    ThreadCount: u32,
};

extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: u32, th32ProcessID: u32) HANDLE;
extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) c_int;
extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) c_int;
extern "kernel32" fn CloseHandle(hObject: HANDLE) c_int;
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: c_int, dwProcessId: u32) HANDLE;
extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) c_int;
extern "kernel32" fn GetProcessTimes(hProcess: HANDLE, lpCreationTime: *FILETIME, lpExitTime: *FILETIME, lpKernelTime: *FILETIME, lpUserTime: *FILETIME) c_int;
extern "kernel32" fn GetSystemTimes(lpIdleTime: *FILETIME, lpKernelTime: *FILETIME, lpUserTime: *FILETIME) c_int;
extern "kernel32" fn K32GetProcessMemoryInfo(hProcess: HANDLE, ppsmemCounters: *PROCESS_MEMORY_COUNTERS, cb: u32) c_int;
extern "kernel32" fn K32GetPerformanceInfo(pPerfInformation: *PERFORMANCE_INFORMATION, cb: u32) c_int;
extern "kernel32" fn GetTickCount64() u64;
extern "kernel32" fn GetActiveProcessorCount(wGroup: u16) u32;
extern "kernel32" fn GetCurrentProcessId() u32;

const PrevEntry = struct { pid: u32 = 0, ticks: u64 = 0 };
var prev: [proc.MAX_PROCS]PrevEntry = undefined;
var prev_n: usize = 0;
var prev_busy: u64 = 0;
var prev_total: u64 = 0;
var prev_wall_ms: u64 = 0;
var cores: u32 = 0;
var self_pid: u32 = 0;

pub fn sample(snap: *proc.Snapshot) void {
    if (self_pid == 0) self_pid = GetCurrentProcessId();
    if (cores == 0) cores = @max(1, GetActiveProcessorCount(0xFFFF));

    const now_ms = GetTickCount64();
    const wall_s: f64 = if (prev_wall_ms == 0)
        0
    else
        @as(f64, @floatFromInt(now_ms - prev_wall_ms)) / 1000.0;

    var rec: usize = 0;

    const snap_handle = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap_handle == INVALID_HANDLE_VALUE()) return;

    var n: usize = 0;
    var entry = std.mem.zeroes(PROCESSENTRY32W);
    entry.dwSize = @sizeOf(PROCESSENTRY32W);

    if (Process32FirstW(snap_handle, &entry) != 0) {
        while (true) {
            if (n >= proc.MAX_PROCS) break;
            const pid = entry.th32ProcessID;

            var p = proc.Process{};
            p.pid = pid;
            p.name_len = w2u8(entry.szExeFile[0..], &p.name_buf);
            p.killable = pid != self_pid and pid != 0 and pid != 4;

            const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid);
            if (h != null and h != INVALID_HANDLE_VALUE()) {
                var ft_create: FILETIME = .{};
                var ft_exit: FILETIME = .{};
                var ft_kernel: FILETIME = .{};
                var ft_user: FILETIME = .{};
                if (GetProcessTimes(h, &ft_create, &ft_exit, &ft_kernel, &ft_user) != 0) {
                    const ticks = ftU64(ft_kernel) + ftU64(ft_user);
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
                            cpu_pct = @floatCast(@min(100.0, @as(f64, @floatFromInt(d)) / 10_000_000.0 / wall_s / @as(f64, @floatFromInt(cores)) * 100.0));
                        }
                    }
                    p.cpu = cpu_pct;
                    if (rec < proc.MAX_PROCS) {
                        prev[rec] = .{ .pid = pid, .ticks = ticks };
                        rec += 1;
                    }
                }
                var pmc = std.mem.zeroes(PROCESS_MEMORY_COUNTERS);
                pmc.cb = @sizeOf(PROCESS_MEMORY_COUNTERS);
                if (K32GetProcessMemoryInfo(h, &pmc, @sizeOf(PROCESS_MEMORY_COUNTERS)) != 0) {
                    p.mem = pmc.WorkingSetSize;
                }
                _ = CloseHandle(h);
            }

            if (pid != 0) { // skip "System Idle Process"
                snap.procs[n] = p;
                n += 1;
            }

            if (Process32NextW(snap_handle, &entry) == 0) break;
        }
    }
    _ = CloseHandle(snap_handle);

    snap.n = n;
    prev_n = rec;
    prev_wall_ms = now_ms;

    // ---- totals ----
    var t = proc.Totals{};
    t.count = @intCast(n);

    var ft_idle: FILETIME = .{};
    var ft_kernel: FILETIME = .{};
    var ft_user: FILETIME = .{};
    if (GetSystemTimes(&ft_idle, &ft_kernel, &ft_user) != 0) {
        const total = ftU64(ft_kernel) + ftU64(ft_user);
        const busy = total -| ftU64(ft_idle);
        if (prev_wall_ms != 0 and prev_busy > 0) {
            // store deltas: busy is cumulative; keep last cumulative busy
            // delta over interval:
            const db = busy -| prev_busy;
            const dt = total -| prev_total;
            if (dt > 0) {
                t.cpu = @floatCast(@min(100.0, @as(f64, @floatFromInt(db)) / @as(f64, @floatFromInt(dt)) * 100.0));
            }
        }
        prev_busy = busy;
        prev_total = total;
    }

    var pi = std.mem.zeroes(PERFORMANCE_INFORMATION);
    pi.cb = @sizeOf(PERFORMANCE_INFORMATION);
    if (K32GetPerformanceInfo(&pi, @sizeOf(PERFORMANCE_INFORMATION)) != 0) {
        const page: u64 = pi.PageSize;
        t.ram_total = page * @as(u64, pi.PhysicalTotal);
        t.ram_used = page * @as(u64, pi.PhysicalTotal -| pi.PhysicalAvailable);
    }

    t.uptime_s = GetTickCount64() / 1000;
    snap.totals = t;
}

pub fn kill(pid: u32) bool {
    const h = OpenProcess(PROCESS_TERMINATE, 0, pid);
    if (h == null or h == INVALID_HANDLE_VALUE()) return false;
    defer _ = CloseHandle(h);
    return TerminateProcess(h, 1) != 0;
}

fn INVALID_HANDLE_VALUE() HANDLE {
    return @ptrFromInt(~@as(usize, 0));
}

/// UTF-16LE (NUL-terminated) -> UTF-8, returns byte length written.
fn w2u8(src: []const u16, dst: []u8) u16 {
    var i: usize = 0;
    var o: usize = 0;
    while (i < src.len and src[i] != 0) {
        var cp: u21 = src[i];
        if (cp >= 0xD800 and cp <= 0xDBFF and i + 1 < src.len and
            src[i + 1] >= 0xDC00 and src[i + 1] <= 0xDFFF)
        {
            cp = 0x10000 + ((cp - 0xD800) << 10) + (src[i + 1] - 0xDC00);
            i += 1;
        }
        var enc: [4]u8 = undefined;
        const k = std.unicode.utf8Encode(cp, &enc) catch {
            i += 1;
            continue;
        };
        if (o + k > dst.len) break;
        @memcpy(dst[o .. o + k], enc[0..k]);
        o += k;
        i += 1;
    }
    return @intCast(o);
}
