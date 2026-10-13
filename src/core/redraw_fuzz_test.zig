//! Seeded random redraw sequences against the header-only consumer model.
//! After every committed flush the model must show exactly what a fresh Core
//! sends for the cells the Neovim UI spec says the grids hold
//! (api-ui-events.txt grid_line / grid_scroll), and no callback may break a
//! header rule. Refusals, forced resends and partial-width scrolls are mixed
//! in, since rows owed across them are where an early dirty clear hides.
//! Reproduce a failure with `zig build test --seed <printed seed>`.

const std = @import("std");
const c_api = @import("c_api.zig");
const consumer_model = @import("consumer_model.zig");
const Core = @import("nvim_core.zig").Core;
const FlushCtx = @import("flush.zig").FlushCtx;
const Model = consumer_model.Model;

const ROWS = 6;
const COLS = 4;
const HL_COUNT = 16;
/// Grid 2 is an external window, grid 3 a split covering the main window.
const GRIDS = [_]i64{ 2, 3 };

/// The cells as the spec defines them; only the highlight reaches vertices in
/// the test Core (it has no glyph callbacks).
const Cells = [GRIDS.len][ROWS][COLS]u32;

fn setupCore(core: *Core) !void {
    var id: u32 = 1;
    while (id <= HL_COUNT) : (id += 1) {
        try core.hl.define(id, null, 0x100000 * id + 0x40, null, false, 0, .{}, false);
    }
    try core.grid.resizeGrid(1, ROWS, COLS);
    try core.grid.resizeGrid(2, ROWS, COLS);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = ROWS,
        .cols = COLS,
    });
    try core.grid.resizeGrid(3, ROWS, COLS);
    try core.grid.setWinPos(3, 43, 0, 0);
    core.drawable_w_px = COLS;
    core.drawable_h_px = ROWS;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;
}

fn put(core: *Core, cells: *Cells, gi: usize, row: u32, col: u32, hl: u32) void {
    cells[gi][row][col] = hl;
    core.grid.putCellGrid(GRIDS[gi], row, col, 'a' + hl, hl);
}

/// grid_scroll as the spec states it: rows in [top, bot) x [left, right) move
/// up by `delta` (down when negative). The area scrolled in is not cleared by
/// the UI; Neovim fills it with grid_line right after, as done here.
fn scroll(core: *Core, cells: *Cells, rng: std.Random, gi: usize, top: u32, bot: u32, left: u32, right: u32, delta: i32) void {
    core.grid.scrollGrid(GRIDS[gi], top, bot, left, right, delta, 0);
    const g = &cells[gi];
    const n: u32 = @abs(delta);
    if (delta > 0) {
        var r = top;
        while (r + n < bot) : (r += 1) {
            for (left..right) |c| g[r][c] = g[r + n][c];
        }
    } else {
        var r = bot;
        while (r > top + n) {
            r -= 1;
            for (left..right) |c| g[r][c] = g[r - n][c];
        }
    }
    const fill_top = if (delta > 0) bot - n else top;
    for (fill_top..fill_top + n) |r| {
        for (left..right) |c| put(core, cells, gi, @intCast(r), @intCast(c), rng.intRangeAtMost(u32, 1, HL_COUNT));
    }
}

/// What a consumer holds after a fresh Core draws `cells` from scratch.
fn reference(cells: *const Cells) !struct { core: Core, model: Model } {
    var core = Core.initForTest(std.testing.allocator);
    errdefer core.deinitForTest();
    try setupCore(&core);
    for (cells, 0..) |g, gi| {
        for (g, 0..) |row, r| {
            for (row, 0..) |hl, c| core.grid.putCellGrid(GRIDS[gi], @intCast(r), @intCast(c), 'a' + hl, hl);
        }
    }
    var model = Model.init(std.testing.allocator);
    errdefer model.deinit();
    model.install(&core.cb, &core.ctx);
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(ROWS, COLS);
    try std.testing.expect(model.violation == null);
    return .{ .core = core, .model = model };
}

fn expectMatchesReference(m: *const Model, cells: *const Cells, seed: u64, step: usize) !void {
    var ref = try reference(cells);
    defer {
        ref.model.deinit();
        ref.core.deinitForTest();
    }
    var it = ref.model.committed.iterator();
    while (it.next()) |e| {
        const held = m.grid(e.key_ptr.*) orelse {
            std.debug.print("seed {x} step {d}: grid {d} never committed\n", .{ seed, step, e.key_ptr.* });
            return error.ModelDiffersFromSpec;
        };
        if (consumer_model.diff(held, e.value_ptr)) |why| {
            std.debug.print("seed {x} step {d}: grid {d}: {s}\n", .{ seed, step, e.key_ptr.*, why });
            return error.ModelDiffersFromSpec;
        }
    }
}

/// Paths a sequence took, so the test can fail when the generator stops
/// reaching the ones it exists for.
const Reached = struct { shifts: u32 = 0, refusals: u32 = 0, checks: u32 = 0 };

fn runSequence(seed: u64, steps: usize, reached: *Reached) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setupCore(&core);
    var cells: Cells = undefined;
    for (&cells, 0..) |*g, gi| {
        for (g, 0..) |*row, r| {
            for (row, 0..) |_, c| put(&core, &cells, gi, @intCast(r), @intCast(c), rng.intRangeAtMost(u32, 1, HL_COUNT));
        }
    }

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.install(&core.cb, &core.ctx);
    m.abort_flag = &core.flush_aborted;
    var flush_ctx = FlushCtx{ .core = &core };

    for (0..steps) |step| {
        const gi = rng.uintLessThan(usize, GRIDS.len);
        switch (rng.uintLessThan(u32, 10)) {
            0...2 => put(&core, &cells, gi, rng.uintLessThan(u32, ROWS), rng.uintLessThan(u32, COLS), rng.intRangeAtMost(u32, 1, HL_COUNT)),
            3...4 => {
                // Full width: the shape the row shift carries.
                const top = rng.uintLessThan(u32, ROWS - 1);
                const bot = rng.intRangeAtMost(u32, top + 2, ROWS);
                const n = rng.intRangeAtMost(i32, 1, @intCast(bot - top - 1));
                scroll(&core, &cells, rng, gi, top, bot, 0, COLS, if (rng.boolean()) n else -n);
            },
            5 => {
                const top = rng.uintLessThan(u32, ROWS - 1);
                const bot = rng.intRangeAtMost(u32, top + 2, ROWS);
                const left = rng.uintLessThan(u32, COLS - 1);
                const right = rng.intRangeAtMost(u32, left + 1, COLS);
                const n = rng.intRangeAtMost(i32, 1, @intCast(bot - top - 1));
                scroll(&core, &cells, rng, gi, top, bot, left, right, if (rng.boolean()) n else -n);
            },
            6 => m.refuse_next = true,
            7 => c_api.forceResendAll(&core),
            else => {
                const refusals = m.refusals;
                try flush_ctx.onFlush(ROWS, COLS);
                if (m.violation) |why| {
                    std.debug.print("seed {x} step {d}: header violation: {s}\n", .{ seed, step, why });
                    return error.HeaderViolation;
                }
                // A refused bracket leaves the old frame on screen by design.
                if (m.refusals == refusals) {
                    try expectMatchesReference(&m, &cells, seed, step);
                    reached.checks += 1;
                }
            },
        }
    }
    // Drain: nothing refused, so the last flush must land on the spec state.
    m.refuse_next = false;
    try flush_ctx.onFlush(ROWS, COLS);
    try std.testing.expect(m.violation == null);
    try expectMatchesReference(&m, &cells, seed, steps);
    reached.shifts += m.shifts;
    reached.refusals += m.refusals;
}

test "random redraw sequences keep the consumer on the spec's cells" {
    var reached: Reached = .{};
    for (0..4) |i| {
        const seed = std.testing.random_seed +% i;
        runSequence(seed, 200, &reached) catch |err| {
            std.debug.print("failing sequence seed {x}\n", .{seed});
            return err;
        };
    }
    try std.testing.expect(reached.shifts > 0 and reached.refusals > 0 and reached.checks > 0);
}
