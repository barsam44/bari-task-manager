// Aero Task Manager - Zig + SDL2 + Dear ImGui, Frutiger Aero edition.
// Usage: aero-taskman [--shot]   (--shot: render 120 frames, save PPM, exit)
const std = @import("std");
const glue = @cImport(@cInclude("glue.h"));
const ui = @import("ui.zig");
const proc = @import("proc.zig");

const SortMode = enum { cpu, mem, pid, name };

const HistCap = 120;
const SampleMs: i64 = 500;

const State = struct {
    snap: proc.Snapshot = .{},
    view: [proc.MAX_PROCS]proc.Process = undefined,
    view_n: usize = 0,
    cpu_hist: [HistCap]f32 = @splat(0),
    ram_hist: [HistCap]f32 = @splat(0),
    hist_head: usize = 0,
    hist_fill: usize = 0,
    last_sample_ms: i64 = 0,
    search_buf: [128]u8 = @splat(0),
    sort_mode: SortMode = .cpu,
    selected_pid: u32 = 0,
    kill_pid: u32 = 0,
    kill_requested: bool = false,
    // button springs
    sp_sort: [4]ui.Spring = @splat(.{}),
    sp_end: ui.Spring = .{},
};

var st: State = .{};

pub fn main() !void {
    var shot_frames: [16]u32 = @splat(0);
    var shot_n: usize = 0;
    var shot_exit = false;
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--shot")) {
            shot_frames[0] = 120;
            shot_n = 1;
            shot_exit = true;
        } else if (std.mem.startsWith(u8, a, "--shot=")) {
            var it = std.mem.splitScalar(u8, a["--shot=".len..], ',');
            while (it.next()) |tok| {
                const f = std.fmt.parseInt(u32, tok, 10) catch continue;
                if (shot_n < shot_frames.len) {
                    shot_frames[shot_n] = f;
                    shot_n += 1;
                }
            }
        }
    }

    if (glue.aero_app_init("Aero Task Manager", 1280, 800) != 0) {
        std.debug.print("failed to initialize window\n", .{});
        return;
    }
    defer glue.aero_app_shutdown();

    ui.font_body = glue.aero_load_font("assets/font/DejaVuSans.ttf", 15);
    ui.font_med = glue.aero_load_font("assets/font/DejaVuSans.ttf", 21);
    ui.font_big = glue.aero_load_font("assets/font/DejaVuSans.ttf", 30);
    if (ui.font_body != null) glue.aero_set_default_font(ui.font_body);
    glue.aero_style_setup();

    // first data pass (cpu% needs a second pass to become meaningful)
    proc.sample(&st.snap);
    st.last_sample_ms = std.time.milliTimestamp();
    rebuildView();

    var ev: glue.AeroEvents = undefined;
    var frame: u32 = 0;
    while (glue.aero_pump_events(&ev) == 1) {
        var dt = glue.aero_delta_time();
        if (!(dt > 0.0001)) dt = 0.0001;
        if (dt > 0.1) dt = 0.1;
        ui.advance(dt);

        // periodic re-sample
        const now = std.time.milliTimestamp();
        if (now - st.last_sample_ms >= SampleMs) {
            proc.sample(&st.snap);
            st.last_sample_ms = now;
            pushHist();
            rebuildView();
        }

        glue.aero_frame_begin();
        if (glue.aero_begin_main() != 0) {
            const dl = glue.aero_main_drawlist().?;
            var dw: f32 = 0;
            var dh: f32 = 0;
            glue.aero_display_size(&dw, &dh);

            ui.drawWallpaper(dl, dw, dh);
            ui.updateAndDrawBubbles(dl, dw, dh, dt);

            drawTopBar(dl, dw);
            drawLeftPanel(dl, dw, dh);
            drawMainPanel(dw, dh);
            drawFooter(dl, dw, dh);
            drawKillModal();

            glue.aero_end_main();
        }
        glue.aero_frame_end();

        if (shot_n > 0) {
            var k: usize = 0;
            while (k < shot_n) : (k += 1) {
                if (shot_frames[k] == frame) {
                    var name_buf: [64]u8 = undefined;
                    const s = std.fmt.bufPrint(&name_buf, "aero-shot-{d}.ppm", .{k + 1}) catch "aero-shot.ppm";
                    name_buf[s.len] = 0;
                    glue.aero_screenshot(s.ptr);
                }
            }
        }
        if (shot_exit and shot_n > 0 and frame >= shot_frames[shot_n - 1]) break;
        glue.aero_swap();
        frame += 1;
    }
}

// ---------------------------------------------------------------- data

fn pushHist() void {
    st.cpu_hist[st.hist_head] = st.snap.totals.cpu;
    st.ram_hist[st.hist_head] = ramPct();
    st.hist_head = (st.hist_head + 1) % HistCap;
    if (st.hist_fill < HistCap) st.hist_fill += 1;
}

fn ramPct() f32 {
    if (st.snap.totals.ram_total == 0) return 0;
    return @floatCast(@as(f64, @floatFromInt(st.snap.totals.ram_used)) /
        @as(f64, @floatFromInt(st.snap.totals.ram_total)) * 100.0);
}

fn histSlice(buf: []const f32) []const f32 {
    // rotate so index 0 = oldest
    var out: [HistCap]f32 = undefined;
    for (0..HistCap) |i| out[i] = buf[(st.hist_head + i) % HistCap];
    return sliceCopy(out);
}

var hist_tmp: [HistCap]f32 = undefined;
fn sliceCopy(src: [HistCap]f32) []const f32 {
    @memcpy(&hist_tmp, &src);
    return hist_tmp[0..HistCap];
}

fn containsInsensitive(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |nc, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(nc)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
}

fn rebuildView() void {
    const search_len = std.mem.indexOfScalar(u8, &st.search_buf, 0) orelse 0;
    const needle = st.search_buf[0..search_len];
    var n: usize = 0;
    for (st.snap.procs[0..st.snap.n]) |p| {
        if (n >= proc.MAX_PROCS) break;
        if (!containsInsensitive(p.name(), needle)) continue;
        st.view[n] = p;
        n += 1;
    }
    st.view_n = n;
    const mode = st.sort_mode;
    std.mem.sort(proc.Process, st.view[0..n], mode, struct {
        fn lessThan(m: SortMode, a: proc.Process, b: proc.Process) bool {
            return switch (m) {
                .cpu => if (a.cpu != b.cpu) a.cpu > b.cpu else a.pid < b.pid,
                .mem => if (a.mem != b.mem) a.mem > b.mem else a.pid < b.pid,
                .pid => a.pid < b.pid,
                .name => std.mem.lessThan(u8, a.name(), b.name()),
            };
        }
    }.lessThan);
}

// ---------------------------------------------------------------- formatting

var fmt_buf: [256]u8 = undefined;
var fmt_buf2: [256]u8 = undefined;
var fmt_b1: [32]u8 = undefined;
var fmt_b2: [32]u8 = undefined;

fn fmtBytes1(bytes: u64) [:0]const u8 {
    return fmtBytes(&fmt_b1, bytes);
}

fn fmtBytes2(bytes: u64) [:0]const u8 {
    return fmtBytes(&fmt_b2, bytes);
}

fn cstr(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const s = std.fmt.bufPrint(&fmt_buf, fmt, args) catch "?";
    fmt_buf[s.len] = 0;
    return fmt_buf[0..s.len :0];
}

fn cstr2(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const s = std.fmt.bufPrint(&fmt_buf2, fmt, args) catch "?";
    fmt_buf2[s.len] = 0;
    return fmt_buf2[0..s.len :0];
}

fn fmtBytes(buf: []u8, bytes: u64) [:0]const u8 {
    const kb: f64 = @floatFromInt(bytes >> 10);
    if (kb < 1024) {
        return bufPrintZ(buf, "{d:.0} KB", .{kb});
    } else if (kb < 1024 * 1024) {
        return bufPrintZ(buf, "{d:.1} MB", .{kb / 1024.0});
    } else {
        return bufPrintZ(buf, "{d:.2} GB", .{kb / (1024.0 * 1024.0)});
    }
}

fn bufPrintZ(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const s = std.fmt.bufPrint(buf, fmt, args) catch "?";
    buf[s.len] = 0;
    return buf[0..s.len :0];
}

fn fmtUptime(buf: []u8, s: u64) [:0]const u8 {
    const days = s / 86400;
    const hours = (s % 86400) / 3600;
    const mins = (s % 3600) / 60;
    if (days > 0) {
        return bufPrintZ(buf, "{d}d {d}h", .{ days, hours });
    } else if (hours > 0) {
        return bufPrintZ(buf, "{d}h {d}m", .{ hours, mins });
    }
    return bufPrintZ(buf, "{d}m {d}s", .{ mins, s % 60 });
}

// ---------------------------------------------------------------- panels

fn drawTopBar(dl: *anyopaque, dw: f32) void {
    ui.glassPanel(dl, 14, 14, dw - 28, 52);
    glue.aero_dl_text(dl, 30, 12, ui.C.text, ui.font_big, 26, "Aero Task Manager");
    glue.aero_dl_text(dl, 32, 44, ui.C.text_soft, ui.font_body, 13, "Frutiger Aero edition  ·  Zig + SDL2 + ImGui");

    const t = &st.snap.totals;
    const ram_txt = cstr2("CPU {d:.1}%   RAM {s} / {s}   {d:.0} FPS", .{
        t.cpu,
        fmtBytes1(t.ram_used),
        fmtBytes2(t.ram_total),
        @max(0.0, glue.aero_framerate()),
    });
    const ts = ui.textSize(ui.font_body, 15, ram_txt);
    glue.aero_dl_text(dl, dw - 34 - ts[0], 32, ui.C.text, ui.font_body, 15, ram_txt.ptr);
}

fn drawLeftPanel(dl: *anyopaque, dw: f32, dh: f32) void {
    _ = dw;
    const x: f32 = 14;
    const y: f32 = 78;
    const w: f32 = 300;
    const bottom = dh - 44 - 12;
    const h = bottom - y;
    ui.glassPanel(dl, x, y, w, h);

    glue.aero_child_begin("##left", x, y, w, h, 0);

    const t = &st.snap.totals;

    const pct1 = cstr("{d:.0}%", .{t.cpu});
    ui.gauge(glue.aero_cur_drawlist().?, x + w * 0.5, y + 88, 58, t.cpu / 100.0, pct1, "CPU");
    const pct2 = cstr("{d:.0}%", .{ramPct()});
    ui.gauge(glue.aero_cur_drawlist().?, x + w * 0.5, y + 236, 58, ramPct() / 100.0, pct2, "MEMORY");

    glue.aero_set_cursor(16, 306);
    glue.aero_text_col(0.09, 0.17, 0.24, 0.75, "UPTIME");
    glue.aero_same_line(128, 0);
    glue.aero_text(fmtUptime(&fmt_buf, t.uptime_s).ptr);

    glue.aero_set_cursor(16, 332);
    glue.aero_text_col(0.09, 0.17, 0.24, 0.75, "PROCESSES");
    glue.aero_same_line(128, 0);
    glue.aero_text(cstr("{d}", .{t.count}).ptr);

    glue.aero_dl_text(glue.aero_cur_drawlist().?, x + 16, y + 366, ui.C.text_soft, ui.font_body, 13, "CPU HISTORY");
    ui.sparkline(glue.aero_cur_drawlist().?, x + 16, y + 386, w - 32, 62, histSlice(&st.cpu_hist), 0, 100, ui.C.green);
    glue.aero_dl_text(glue.aero_cur_drawlist().?, x + 16, y + 462, ui.C.text_soft, ui.font_body, 13, "MEMORY HISTORY");
    ui.sparkline(glue.aero_cur_drawlist().?, x + 16, y + 482, w - 32, 62, histSlice(&st.ram_hist), 0, 100, ui.C.cyan);

    glue.aero_child_end();
}

const sort_labels = [_][:0]const u8{ "CPU", "RAM", "PID", "Name" };
const sort_modes = [_]SortMode{ .cpu, .mem, .pid, .name };

fn drawMainPanel(dw: f32, dh: f32) void {
    const x: f32 = 326;
    const y: f32 = 78;
    const w: f32 = dw - x - 14;
    const bottom = dh - 44 - 12;
    const h = bottom - y;
    ui.glassPanel(glue.aero_main_drawlist().?, x, y, w, h);

    glue.aero_child_begin("##main", x, y, w, h, 0);

    // header: title + search
    glue.aero_dl_text(glue.aero_cur_drawlist().?, x + 22, y + 16, ui.C.text, ui.font_med, 21, "Processes");
    const search_w: f32 = 230;
    glue.aero_set_cursor(w - 22 - search_w, 12);
    glue.aero_set_item_width(search_w);
    if (glue.aero_input_text("##search", "Filter processes...", &st.search_buf, 128) != 0) {
        rebuildView();
    }

    // sort buttons
    for (sort_labels, 0..) |lbl, i| {
        const active = st.sort_mode == sort_modes[i];
        const accent = if (active) ui.C.blue else ui.withAlpha(ui.C.white, 120);
        glue.aero_set_cursor(22 + @as(f32, @floatFromInt(i)) * 80.0, 54);
        if (ui.glossyButton(cstr("##sort{d}", .{i}), lbl, 0, 0, 72, 30, &st.sp_sort[i], accent, glue.aero_delta_time())) {
            st.sort_mode = sort_modes[i];
            rebuildView();
        }
    }

    // table
    const table_h = h - 96 - 56;
    glue.aero_set_cursor(10, 96);
    if (glue.aero_table_begin("##procstable", 4, -1.0, table_h) != 0) {
        glue.aero_table_col("Name", 16, 1);
        glue.aero_table_col("PID", 64, 0);
        glue.aero_table_col("CPU", 132, 0);
        glue.aero_table_col("Memory", 118, 0);
        glue.aero_table_headers();

        for (st.view[0..st.view_n]) |p| {
            glue.aero_table_row(26);
            glue.aero_table_col_i(0);
            const sel: c_int = if (p.pid == st.selected_pid) 1 else 0;
            const row_label = cstr("{s}##{d}", .{ p.name(), p.pid });
            if (glue.aero_selectable(row_label.ptr, sel, 26, 1) != 0) {
                st.selected_pid = if (st.selected_pid == p.pid) 0 else p.pid;
            }

            glue.aero_table_col_i(1);
            const pid_s = cstr("{d}", .{p.pid});
            glue.aero_text(pid_s.ptr);

            glue.aero_table_col_i(2);
            {
                var cx: f32 = 0;
                var cy: f32 = 0;
                glue.aero_cur_pos(&cx, &cy);
                const cdl = glue.aero_cur_drawlist().?;
                const bar_col: u32 = if (p.cpu > 70) ui.C.red else if (p.cpu > 40) ui.C.amber else ui.C.green;
                ui.miniBar(cdl, cx, cy + 4, 64, 15, p.cpu / 100.0, bar_col);
                const cs = cstr("{d:.1}%", .{p.cpu});
                glue.aero_dl_text(cdl, cx + 72, cy + 5, ui.C.text, ui.font_body, 14, cs.ptr);
            }

            glue.aero_table_col_i(3);
            glue.aero_text(fmtBytes1(p.mem).ptr);
        }
        glue.aero_table_end();
    }

    // footer row inside panel: info + End Task
    const info = cstr("{d} shown  ·  sorted by {s}  ·  select a row to end it", .{
        st.view_n,
        switch (st.sort_mode) {
            .cpu => "CPU",
            .mem => "memory",
            .pid => "PID",
            .name => "name",
        },
    });
    glue.aero_dl_text(glue.aero_cur_drawlist().?, x + 22, y + h - 42, ui.C.text_soft, ui.font_body, 14, info.ptr);

    const has_sel = st.selected_pid != 0;
    const btn_w: f32 = 140;
    st.sp_end.target = if (has_sel) 1.0 else 0.0;
    st.sp_end.update(glue.aero_delta_time(), 170, 14);
    if (has_sel) {
        glue.aero_set_cursor(w - 22 - btn_w, h - 50);
        if (ui.glossyButton("##endtask", "End Task", 0, 0, btn_w, 36, &st.sp_end, ui.C.red, glue.aero_delta_time())) {
            st.kill_pid = st.selected_pid;
            st.kill_requested = true;
        }
    } else {
        const cdl = glue.aero_cur_drawlist().?;
        glue.aero_dl_rect_filled(cdl, x + w - 22 - btn_w, y + h - 50, x + w - 22, y + h - 14, 9, ui.withAlpha(ui.C.white, 70));
        glue.aero_dl_text(cdl, x + w - 22 - btn_w + (btn_w - 54) * 0.5, y + h - 41, ui.withAlpha(ui.C.text, 130), ui.font_body, 15, "End Task");
    }

    glue.aero_child_end();
}

fn findName(pid: u32) []const u8 {
    for (st.snap.procs[0..st.snap.n]) |p| {
        if (p.pid == pid) return p.name();
    }
    return "?";
}

fn drawFooter(dl: *anyopaque, dw: f32, dh: f32) void {
    const x: f32 = 14;
    const y: f32 = dh - 44;
    const w: f32 = dw - 28;
    const h: f32 = 30;
    glue.aero_dl_rect_filled(dl, x, y, x + w, y + h, 10, ui.withAlpha(ui.C.white, 26));
    glue.aero_dl_rect(dl, x, y, x + w, y + h, 10, ui.withAlpha(ui.C.white, 90), 1);
    const txt = cstr("Aero Task Manager  ·  sampling every 500 ms  ·  ESC to quit", .{});
    glue.aero_dl_text(dl, x + 16, y + 8, ui.withAlpha(ui.C.text, 170), ui.font_body, 13, txt.ptr);
}

fn drawKillModal() void {
    if (st.kill_requested) {
        glue.aero_open_popup("End task?");
        st.kill_requested = false;
    }
    if (glue.aero_popup_begin("End task?") != 0) {
        const name = findName(st.kill_pid);
        const line1 = cstr("Terminate '{s}' (PID {d})?", .{ name, st.kill_pid });
        glue.aero_text(line1.ptr);
        glue.aero_text("Unsaved work in that process may be lost.");
        glue.aero_dummy(6);
        if (glue.aero_button("End it", 110, 0) != 0) {
            _ = proc.kill(st.kill_pid);
            glue.aero_close_popup();
            st.selected_pid = 0;
            proc.sample(&st.snap);
            rebuildView();
        }
        glue.aero_same_line(0, -1);
        if (glue.aero_button("Cancel", 110, 0) != 0) {
            glue.aero_close_popup();
        }
        glue.aero_popup_end();
    }
}
