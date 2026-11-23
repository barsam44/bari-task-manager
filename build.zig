// Aero Task Manager - build script (Zig 0.15.x)
//
// Linux build (system SDL2 recommended):
//   sudo apt install libsdl2-dev libgl1-mesa-dev
//   zig build -Doptimize=ReleaseFast
//
// Windows cross-build (vendored SDL2, no extra deps):
//   zig build -Doptimize=ReleaseFast -Dtarget=x86_64-windows-gnu
//
// If pkg-config cannot find SDL2 on Linux, set AERO_SDL2_CFLAGS / AERO_SDL2_LIBS
// or let the build fall back to ../tools/sysroot.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const os = target.result.os.tag;

    const exe = b.addExecutable(.{
        .name = "aero-taskman",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibC();
    exe.linkLibCpp();

    // ---- include paths (C glue, ImGui, and Zig @cImport) ----
    exe.addIncludePath(b.path("src/glue"));
    exe.addIncludePath(b.path("vendor"));
    exe.addIncludePath(b.path("vendor/backends"));

    // ---- Dear ImGui C++ sources + glue (all C++) ----
    const imgui_srcs = [_][]const u8{
        "vendor/imgui.cpp",
        "vendor/imgui_draw.cpp",
        "vendor/imgui_tables.cpp",
        "vendor/imgui_widgets.cpp",
        "vendor/backends/imgui_impl_sdl2.cpp",
        "vendor/backends/imgui_impl_opengl3.cpp",
        "src/glue/glue.cpp",
    };

    // ---- C++ compile flags ----
    var cpp_flags: std.ArrayList([]const u8) = .empty;
    const cpp_base = [_][]const u8{ "-std=c++17", "-fno-exceptions", "-fno-rtti", "-O2", "-DSDL_MAIN_HANDLED" };
    cpp_flags.appendSlice(b.allocator, &cpp_base) catch @panic("oom");

    // ---- per-OS SDL2 discovery ----
    var sdl_lib_dir: ?[]const u8 = null;

    if (os == .windows) {
        const inc = b.path("vendor/sdl2-win/include/SDL2").getPath(b);
        const flag = b.fmt("-I{s}", .{inc});
        cpp_flags.append(b.allocator, flag) catch @panic("oom");
        sdl_lib_dir = b.path("vendor/sdl2-win/lib").getPath(b);
    } else {
        // 1. env override  2. pkg-config  3. local sysroot
        var sdl_inc_dir: ?[]const u8 = null;
        var env_incs: usize = 0;
        if (std.process.getEnvVarOwned(b.allocator, "AERO_SDL2_CFLAGS")) |v| {
            // append every -I flag the variable carries
            env_incs = appendAllFlags(b, &cpp_flags, v, "-I");
            if (env_incs > 0) sdl_inc_dir = "env";
        } else |_| {}
        if (sdl_inc_dir == null) {
            if (std.process.Child.run(.{ .allocator = b.allocator, .argv = &.{ "pkg-config", "--cflags", "sdl2" } })) |res| {
                switch (res.term) {
                    .Exited => |code| if (code == 0) {
                        sdl_inc_dir = extractFlag(res.stdout, "-I");
                    },
                    else => {},
                }
            } else |_| {}
        }
        if (std.process.getEnvVarOwned(b.allocator, "AERO_SDL2_LIBS")) |v| {
            sdl_lib_dir = extractFlag(v, "-L");
        } else |_| {}
        if (sdl_inc_dir == null or sdl_lib_dir == null) {
            const root: []const u8 = b.build_root.path orelse ".";
            const sysroot = std.fs.path.join(b.allocator, &.{ root, "..", "tools", "sysroot" }) catch null;
            if (sysroot) |sr| {
                if (sdl_inc_dir == null) {
                    const inc = std.fs.path.join(b.allocator, &.{ sr, "usr", "include", "SDL2" }) catch null;
                    if (inc) |ip| {
                        if (std.fs.accessAbsolute(ip, .{})) |_| {
                            sdl_inc_dir = ip;
                            // Debian: SDL_config.h wrapper needs the parent dir plus
                            // the arch-specific dir holding _real_SDL_config.h
                            const extras = [_][]const u8{ "usr/include", "usr/include/x86_64-linux-gnu" };
                            for (extras) |rel| {
                                if (std.fs.path.join(b.allocator, &.{ sr, rel }) catch null) |dir| {
                                    const flag = b.fmt("-I{s}", .{dir});
                                    cpp_flags.append(b.allocator, flag) catch @panic("oom");
                                }
                            }
                        } else |_| {}
                    }
                }
                if (sdl_lib_dir == null) {
                    const lp = std.fs.path.join(b.allocator, &.{ sr, "usr", "lib", "x86_64-linux-gnu" }) catch null;
                    if (lp) |lp_abs| {
                        if (std.fs.accessAbsolute(lp_abs, .{})) |_| {
                            sdl_lib_dir = lp_abs;
                        } else |_| {}
                    }
                }
            }
        }
        if (sdl_inc_dir) |inc| {
            if (env_incs == 0) {
                const flag = b.fmt("-I{s}", .{inc});
                cpp_flags.append(b.allocator, flag) catch @panic("oom");
            }
        } else {
            std.debug.print("warning: SDL2 headers not found; install libsdl2-dev or set AERO_SDL2_CFLAGS\n", .{});
        }
    }

    exe.addCSourceFiles(.{ .files = &imgui_srcs, .flags = cpp_flags.toOwnedSlice(b.allocator) catch @panic("oom") });
    // ---- link ----
    if (os == .windows) {
        exe.subsystem = .Windows;
        // link the DLL import library explicitly (dynamic SDL2; SDL2.dll is
        // installed next to the exe), so SDL's own system deps live inside the dll
        exe.addObjectFile(b.path("vendor/sdl2-win/lib/libSDL2.dll.a"));
        exe.linkSystemLibrary("opengl32");
    } else {
        if (sdl_lib_dir) |lp| exe.addLibraryPath(.{ .cwd_relative = lp });
        exe.linkSystemLibrary("SDL2");
        exe.linkSystemLibrary("GL");
    }

    b.installArtifact(exe);

    // ---- install assets next to the binary ----
    const font_install = b.addInstallFileWithDir(
        b.path("assets/font/DejaVuSans.ttf"),
        .prefix,
        "assets/font/DejaVuSans.ttf",
    );
    b.getInstallStep().dependOn(&font_install.step);

    if (os == .windows) {
        const dll_install = b.addInstallFileWithDir(
            b.path("vendor/sdl2-win/bin/SDL2.dll"),
            .bin,
            "SDL2.dll",
        );
        b.getInstallStep().dependOn(&dll_install.step);
    }
}

fn extractFlag(text: []const u8, prefix: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, prefix)) |at| {
        var start = at + prefix.len;
        if (start < text.len and text[start] == ' ') start += 1;
        var end = start;
        while (end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
        if (end > start) return text[start..end];
        i = at + prefix.len;
    }
    return null;
}

/// Append every `-I<dir>` occurrence found in `text` to `flags`.
fn appendAllFlags(b: *std.Build, flags: *std.ArrayList([]const u8), text: []const u8, prefix: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, prefix)) |at| {
        var start = at + prefix.len;
        if (start < text.len and text[start] == ' ') start += 1;
        var end = start;
        while (end < text.len and text[end] != ' ' and text[end] != '\n') end += 1;
        if (end > start) {
            const dir = text[start..end];
            if (std.fs.accessAbsolute(dir, .{})) |_| {
                flags.append(b.allocator, b.fmt("-I{s}", .{dir})) catch @panic("oom");
                count += 1;
            } else |_| {}
            i = end;
        } else {
            i = at + prefix.len;
        }
    }
    return count;
}
