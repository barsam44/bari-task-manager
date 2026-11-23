// Aero UI kit: theme, animated wallpaper, bubbles, springs, glossy widgets.
const std = @import("std");
const glue = @cImport(@cInclude("glue.h"));

pub var g_time: f32 = 0.0;

pub fn advance(dt: f32) void {
    g_time += dt;
}

// ---------------------------------------------------------------- colors
// ImGui packs colors as R | G<<8 | B<<16 | A<<24 (IM_COL32 default).
pub inline fn imcol(r: u32, g: u32, b: u32, a: u32) u32 {
    return (r & 0xFF) | ((g & 0xFF) << 8) | ((b & 0xFF) << 16) | ((a & 0xFF) << 24);
}

pub inline fn withAlpha(c: u32, a: u32) u32 {
    return (c & 0x00FFFFFF) | ((a & 0xFF) << 24);
}

pub inline fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub inline fn clamp(v: f32, lo: f32, hi: f32) f32 {
    return if (v < lo) lo else if (v > hi) hi else v;
}

pub inline fn lerpCol(a: u32, b: u32, t: f32) u32 {
    const ar: f32 = @floatFromInt(a & 0xFF);
    const ag: f32 = @floatFromInt((a >> 8) & 0xFF);
    const ab: f32 = @floatFromInt((a >> 16) & 0xFF);
    const aa: f32 = @floatFromInt((a >> 24) & 0xFF);
    const br: f32 = @floatFromInt(b & 0xFF);
    const bg: f32 = @floatFromInt((b >> 8) & 0xFF);
    const bb: f32 = @floatFromInt((b >> 16) & 0xFF);
    const ba: f32 = @floatFromInt((b >> 24) & 0xFF);
    return imcol(
        @intFromFloat(lerp(ar, br, t)),
        @intFromFloat(lerp(ag, bg, t)),
        @intFromFloat(lerp(ab, bb, t)),
        @intFromFloat(lerp(aa, ba, t)),
    );
}

pub const C = struct {
    pub const text = imcol(24, 44, 62, 255);
    pub const text_soft = imcol(24, 44, 62, 175);
    pub const text_faint = imcol(24, 44, 62, 120);
    pub const white = imcol(255, 255, 255, 255);
    pub const glass_fill = imcol(255, 255, 255, 34);
    pub const glass_border = imcol(255, 255, 255, 135);
    pub const glass_gloss = imcol(255, 255, 255, 44);
    pub const shadow = imcol(18, 46, 84, 80);
    pub const green = imcol(108, 198, 92, 255);
    pub const cyan = imcol(72, 178, 224, 255);
    pub const amber = imcol(244, 178, 54, 255);
    pub const red = imcol(232, 86, 74, 255);
    pub const blue = imcol(78, 140, 220, 255);
};

// ---------------------------------------------------------------- springs
pub const Spring = struct {
    value: f32 = 0,
    vel: f32 = 0,
    target: f32 = 0,

    pub fn update(self: *Spring, dt: f32, stiffness: f32, damping: f32) void {
        const steps = 2; // sub-step for stability
        const h = dt / steps;
        var i: u32 = 0;
        while (i < steps) : (i += 1) {
            const a = (self.target - self.value) * stiffness - self.vel * damping;
            self.vel += a * h;
            self.value += self.vel * h;
        }
    }
};

// ---------------------------------------------------------------- fonts
pub var font_body: ?*anyopaque = null; // 15px
pub var font_med: ?*anyopaque = null; // 20px
pub var font_big: ?*anyopaque = null; // 30px

pub fn textSize(font: ?*anyopaque, size: f32, text: [:0]const u8) [2]f32 {
    var w: f32 = 0;
    var h: f32 = 0;
    glue.aero_calc_text_size(font, size, text.ptr, &w, &h);
    return .{ w, h };
}

// ---------------------------------------------------------------- wallpaper
const pal_a = .{ imcol(56, 118, 200, 255), imcol(120, 192, 232, 255), imcol(112, 198, 96, 255) };
const pal_b = .{ imcol(66, 146, 216, 255), imcol(134, 206, 240, 255), imcol(96, 190, 122, 255) };

pub fn drawWallpaper(dl: *anyopaque, w: f32, h: f32) void {
    const mix = (std.math.sin(g_time * 0.13) + 1.0) * 0.5;
    const top = lerpCol(pal_a[0], pal_b[0], mix);
    const mid = lerpCol(pal_a[1], pal_b[1], mix);
    const bot = lerpCol(pal_a[2], pal_b[2], mix);

    const split = h * 0.52;
    glue.aero_dl_gradient_v(dl, 0, 0, w, split, top, mid);
    glue.aero_dl_gradient_v(dl, 0, split, w, h, mid, bot);

    // drifting aurora blobs
    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        const ft: f32 = @floatFromInt(i);
        const cx = w * (0.25 + 0.22 * std.math.sin(g_time * 0.10 + ft * 2.1));
        const cy = h * (0.42 + 0.22 * std.math.cos(g_time * 0.08 + ft * 1.7));
        const r = h * (0.38 + 0.08 * std.math.sin(g_time * 0.15 + ft));
        const col: u32 = switch (i) {
            0 => imcol(210, 240, 255, 12),
            1 => imcol(190, 255, 210, 10),
            else => imcol(255, 255, 255, 9),
        };
        glue.aero_dl_circle_filled(dl, cx, cy, r, col);
    }

    // top-left sky glow
    glue.aero_dl_circle_glow(dl, w * 0.12, h * 0.05, h * 0.22, imcol(255, 255, 255, 26));
}

// ---------------------------------------------------------------- bubbles
pub const Bubble = struct {
    x: f32 = 0,
    y: f32 = 0,
    r: f32 = 0,
    vy: f32 = 0,
    phase: f32 = 0,
    wob: f32 = 1,
    alpha: u32 = 26,
};

pub var bubbles: [32]Bubble = @splat(.{});
var seeded = false;

fn respawn(b: *Bubble, w: f32, h: f32, rng: std.Random, start_bottom: bool) void {
    b.r = lerp(6, 30, rng.float(f32));
    b.x = lerp(b.r + 4, w - b.r - 4, rng.float(f32));
    b.y = if (start_bottom) h + b.r + lerp(0, h * 0.8, rng.float(f32)) else h + b.r;
    b.vy = lerp(14, 52, rng.float(f32)) * (b.r / 20.0);
    b.phase = lerp(0, 6.283, rng.float(f32));
    b.wob = lerp(0.4, 1.6, rng.float(f32));
    b.alpha = @intFromFloat(lerp(26, 62, rng.float(f32)));
}

pub fn updateAndDrawBubbles(dl: *anyopaque, w: f32, h: f32, dt: f32) void {
    var rng_src = std.Random.DefaultPrng.init(0xA3A0CAFE);
    const rng = rng_src.random();
    for (&bubbles) |*b| {
        if (!seeded) {
            respawn(b, w, h, rng, true);
            // spread the initial population across the whole screen
            b.y = lerp(b.r, h * 0.92, rng.float(f32));
        }
        b.y -= b.vy * dt;
        b.x += std.math.sin(g_time * b.wob + b.phase) * 9.0 * dt;
        if (b.y < -b.r - 30) respawn(b, w, h, rng, false);

        const a = b.alpha;
        glue.aero_dl_circle_filled(dl, b.x, b.y, b.r, withAlpha(C.white, a));
        glue.aero_dl_circle(dl, b.x, b.y, b.r, withAlpha(C.white, a + a / 2), 1.4);
        const sx = b.x - b.r * 0.34;
        const sy = b.y - b.r * 0.34;
        glue.aero_dl_circle_filled(dl, sx, sy, b.r * 0.20, withAlpha(C.white, a + a * 2));
    }
    seeded = true;
}

// ---------------------------------------------------------------- glass panel
pub fn glassPanel(dl: *anyopaque, x: f32, y: f32, w: f32, h: f32) void {
    glue.aero_dl_glow(dl, x, y, x + w, y + h, 14, C.shadow);
    glue.aero_dl_rect_filled(dl, x, y, x + w, y + h, 14, C.glass_fill);
    // gloss strip (top ~45%)
    glue.aero_dl_push_clip(dl, x, y, x + w, y + h);
    glue.aero_dl_rect_filled(dl, x, y, x + w, y + h * 0.45, 14, C.glass_gloss);
    glue.aero_dl_pop_clip(dl);
    glue.aero_dl_rect(dl, x, y, x + w, y + h, 14, C.glass_border, 1.25);
}

// ---------------------------------------------------------------- glossy button
pub fn glossyButton(
    id: [:0]const u8,
    label: [:0]const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    spring: *Spring,
    accent: u32,
    dt: f32,
) bool {
    _ = x;
    _ = y;
    const pressed = glue.aero_invisible_button(id.ptr, w, h) != 0;
    var rx0: f32 = 0;
    var ry0: f32 = 0;
    var rx1: f32 = 0;
    var ry1: f32 = 0;
    glue.aero_item_rect(&rx0, &ry0, &rx1, &ry1);
    const hover = glue.aero_item_hovered() != 0;

    spring.target = if (hover) 1.0 else 0.0;
    spring.update(dt, 170, 14);
    const t = clamp(spring.value, -0.3, 1.4);

    const dl = glue.aero_cur_drawlist();
    const fill_hi = lerpCol(withAlpha(accent, 200), withAlpha(accent, 255), t);
    const fill_lo = lerpCol(withAlpha(accent, 130), withAlpha(accent, 200), t);
    glue.aero_dl_glow(dl, rx0, ry0, rx1, ry1, 9, withAlpha(accent, @intFromFloat(40 + 70 * clamp(t, 0, 1))));
    glue.aero_dl_push_clip(dl, rx0, ry0, rx1, ry1);
    glue.aero_dl_gradient_v(dl, rx0, ry0, rx1, ry1, fill_hi, fill_lo);
    glue.aero_dl_rect_filled(dl, rx0, ry0, rx1, ry0 + (ry1 - ry0) * 0.45, 9, withAlpha(C.white, @intFromFloat(30 + 40 * t)));
    glue.aero_dl_pop_clip(dl);
    glue.aero_dl_rect(dl, rx0, ry0, rx1, ry1, 9, withAlpha(C.white, @intFromFloat(120 + 80 * t)), 1.2);

    const ts = textSize(font_body, 15, label);
    const grow = 1.0 + 0.05 * clamp(t, 0, 1);
    glue.aero_dl_text(
        dl,
        (rx0 + rx1) * 0.5 - ts[0] * 0.5 * grow,
        (ry0 + ry1) * 0.5 - ts[1] * 0.5 * grow,
        withAlpha(C.white, 255),
        font_body,
        15 * grow,
        label.ptr,
    );
    return pressed;
}

// ---------------------------------------------------------------- gauge
pub fn gauge(
    dl: *anyopaque,
    cx: f32,
    cy: f32,
    r: f32,
    frac: f32,
    value_text: [:0]const u8,
    label: [:0]const u8,
) void {
    const f = clamp(frac, 0, 1);
    const ring = 11.0;
    // background ring
    glue.aero_dl_arc(dl, cx, cy, r, 0, 6.28318, withAlpha(C.white, 60), ring, 56);
    // inner glass disc
    glue.aero_dl_circle_filled(dl, cx, cy, r - ring * 0.5 - 3, withAlpha(C.white, 26));
    glue.aero_dl_circle(dl, cx, cy, r - ring * 0.5 - 3, withAlpha(C.white, 70), 1.2);
    // gloss arc
    glue.aero_dl_arc(dl, cx, cy, r - ring * 0.55, 3.49, 5.06, withAlpha(C.white, 140), 3.4, 20);

    // value arc: 36 segments, green -> amber -> red
    const segs = 36;
    const start: f32 = -std.math.pi / 2.0;
    const sweep = 6.28318 * 0.9999;
    const filled: i32 = @intFromFloat(f * segs);
    var i: i32 = 0;
    while (i < segs) : (i += 1) {
        const ft: f32 = @floatFromInt(i);
        const fs: f32 = @floatFromInt(segs);
        const a0 = start + sweep * ft / fs;
        const a1 = start + sweep * (ft + 1.0) / fs;
        const lit: f32 = @floatFromInt(i + 1);
        const on = lit <= @as(f32, @floatFromInt(filled));
        const hue_t = ft / fs;
        const col = blk: {
            if (!on) break :blk withAlpha(C.white, 34);
            break :blk blk2: {
                var c: u32 = undefined;
                if (hue_t < 0.55) {
                    c = lerpCol(C.green, C.amber, hue_t / 0.55);
                } else {
                    c = lerpCol(C.amber, C.red, (hue_t - 0.55) / 0.45);
                }
                break :blk2 c;
            };
        };
        glue.aero_dl_arc(dl, cx, cy, r, a0, a1 + 0.004, col, ring, 8);
    }

    // center text
    const vt = textSize(font_big, 30, value_text);
    glue.aero_dl_text(dl, cx - vt[0] * 0.5, cy - vt[1] * 0.5 - 4, C.text, font_big, 30, value_text.ptr);
    const lt = textSize(font_body, 14, label);
    glue.aero_dl_text(dl, cx - lt[0] * 0.5, cy + r * 0.42, C.text_soft, font_body, 14, label.ptr);
}

// ---------------------------------------------------------------- sparkline
pub fn sparkline(
    dl: *anyopaque,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    samples: []const f32,
    head: usize,
    vmax: f32,
    col: u32,
) void {
    if (samples.len < 2) return;
    // grid
    var g: u32 = 1;
    while (g < 3) : (g += 1) {
        const gy = y + h * @as(f32, @floatFromInt(g)) / 3.0;
        glue.aero_dl_line(dl, x, gy, x + w, gy, withAlpha(C.white, 30), 1);
    }
    const n = samples.len;
    const step = w / @as(f32, @floatFromInt(n - 1));
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const v = samples[(head + i) % n];
        const vi = clamp(v / vmax, 0, 1);
        const ytop = y + h - vi * h;
        glue.aero_dl_gradient_v(dl, x + step * @as(f32, @floatFromInt(i)), ytop, x + step * @as(f32, @floatFromInt(i)) + step + 1, y + h, withAlpha(col, 110), withAlpha(col, 8));
    }
    // line
    i = 1;
    while (i < n) : (i += 1) {
        const v0 = samples[(head + i - 1) % n];
        const v1 = samples[(head + i) % n];
        const x0 = x + step * @as(f32, @floatFromInt(i - 1));
        const x1 = x + step * @as(f32, @floatFromInt(i));
        const y0 = y + h - clamp(v0 / vmax, 0, 1) * h;
        const y1 = y + h - clamp(v1 / vmax, 0, 1) * h;
        glue.aero_dl_line(dl, x0, y0, x1, y1, withAlpha(C.white, 210), 2);
    }
    // head dot
    const vhead = samples[head % n];
    const hx = x + step * @as(f32, @floatFromInt(n - 1));
    const hy = y + h - clamp(vhead / vmax, 0, 1) * h;
    glue.aero_dl_circle_glow(dl, hx, hy, 3.5, withAlpha(col, 200));
    glue.aero_dl_circle_filled(dl, hx, hy, 3.5, C.white);
}

// ---------------------------------------------------------------- mini bar (table cell)
pub fn miniBar(dl: *anyopaque, x: f32, y: f32, w: f32, h: f32, frac: f32, col: u32) void {
    glue.aero_dl_rect_filled(dl, x, y, x + w, y + h, 4, withAlpha(C.white, 70));
    const fw = clamp(frac, 0, 1) * w;
    if (fw > 2) {
        glue.aero_dl_push_clip(dl, x, y, x + w, y + h);
        glue.aero_dl_gradient_v(dl, x, y, x + fw, y + h, withAlpha(col, 235), withAlpha(col, 150));
        glue.aero_dl_rect_filled(dl, x, y, x + fw, y + h * 0.5, 4, withAlpha(C.white, 60));
        glue.aero_dl_pop_clip(dl);
    }
}
