// ext_windows_resize_first_window — under ext_windows, resizing the first
// window makes nvim send win_resize (window.c win_setheight_win) for a grid no
// win_split named. That grid must stay composited in the main window.
// A split window is open during the resize so the composited-fallback
// promotion cannot pull a wrongly externalized first window back.
// Skipped unless the nvim under test advertises the ext_windows ui option;
// ZONVIE_REQUIRE_EXT_WINDOWS turns that skip into a failure.

const std = @import("std");
const zc = @import("zonvie_core");
const harness = @import("../harness.zig");
const Harness = harness.Harness;

fn nvimHasExtWindows(alloc: std.mem.Allocator) !bool {
    const path = try harness.resolveNvim(alloc);
    defer alloc.free(path);
    const result = try std.process.run(alloc, zc.clock.io(), .{ .argv = &.{ path, "--api-info" } });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return std.mem.indexOf(u8, result.stdout, "ext_windows") != null;
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!try nvimHasExtWindows(alloc)) {
        if (std.process.Environ.getAlloc(std.testing.environ, alloc, "ZONVIE_REQUIRE_EXT_WINDOWS")) |required| {
            alloc.free(required);
            std.debug.print("[e2e] nvim lacks ext_windows but ZONVIE_REQUIRE_EXT_WINDOWS is set\n", .{});
            return error.ExtWindowsUnavailable;
        } else |_| {}
        std.debug.print("[e2e] skipped: nvim lacks the ext_windows ui option\n", .{});
        return error.SkipZigTest;
    }
    var h = try Harness.init(alloc, .{ .ext_windows = true });
    defer h.deinit();

    const first = h.winGrid();
    try std.testing.expect(!h.isExternalGrid(first));

    try h.command("lua _G.e2e_first = vim.api.nvim_get_current_win()");
    try h.command("split");

    // The split's grid is announced by win_split and becomes external.
    try h.waitUntil(first, struct {
        fn check(first_grid: i64, hh: *Harness) bool {
            const cur = hh.winGrid();
            return cur != first_grid and hh.isExternalGrid(cur);
        }
    }.check, h.opts.timeout_ms);
    const split_grid = h.winGrid();

    // Resize the first window without entering it: win_vert_neighbor under
    // ext_windows is a blocking win_move_cursor request this harness never answers.
    try h.command("lua vim.api.nvim_win_set_height(_G.e2e_first, 5)");

    // The win_resize round trip (nvim_ui_try_resize_grid -> grid_resize)
    // proves the event was handled before the surfaces are checked.
    try h.waitUntil(first, struct {
        fn check(grid_id: i64, hh: *Harness) bool {
            const sz = hh.subGridSize(grid_id) orelse return false;
            return sz.rows == 5;
        }
    }.check, h.opts.timeout_ms);

    try std.testing.expect(!h.isExternalGrid(first));
    try std.testing.expect(h.isExternalGrid(split_grid));
    const ext = try h.externalGridsAlloc(alloc);
    defer alloc.free(ext);
    try std.testing.expectEqual(@as(usize, 1), ext.len);
}
