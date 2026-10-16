//! A frontend written from include/zonvie_core.h alone: the on_vertices_row
//! row and cursor layers (:192-206), the on_grid_row_scroll shift (:208-222)
//! and the flush bracket (:886-902, abort :1882-1897). Tests attach it to a
//! Core and compare what it holds -- against a full resend of the same grids,
//! or between surfaces -- instead of re-deriving what the core should send.
//!
//! It must never call or mirror core internals: if a rule is not in the
//! header it is not in this file. Test-only.

const std = @import("std");
const c_api = @import("c_api.zig");

const Vertex = c_api.Vertex;

/// One grid as a consumer holds it.
pub const GridState = struct {
    total_rows: u32 = 0,
    total_cols: u32 = 0,
    /// Row contents by row index. null: no MAIN send has filled the row since
    /// it appeared or since a shift vacated it (header :210: the core sends the
    /// vacated rows, so one still null after a flush was never sent).
    rows: std.ArrayListUnmanaged(?[]Vertex) = .empty,
    /// The grid's complete cursor layer (header :196).
    cursor: []Vertex = &.{},

    fn deinit(self: *GridState, alloc: std.mem.Allocator) void {
        for (self.rows.items) |r| if (r) |v| alloc.free(v);
        self.rows.deinit(alloc);
        alloc.free(self.cursor);
        self.* = .{};
    }

    fn clone(self: *const GridState, alloc: std.mem.Allocator) !GridState {
        var out = GridState{ .total_rows = self.total_rows, .total_cols = self.total_cols };
        errdefer out.deinit(alloc);
        try out.rows.ensureTotalCapacity(alloc, self.rows.items.len);
        for (self.rows.items) |r| {
            out.rows.appendAssumeCapacity(if (r) |v| try alloc.dupe(Vertex, v) else null);
        }
        out.cursor = try alloc.dupe(Vertex, self.cursor);
        return out;
    }

    /// Grow or shrink the row list to `total_rows`; new rows are unfilled.
    fn setShape(self: *GridState, alloc: std.mem.Allocator, total_rows: u32, total_cols: u32) !void {
        while (self.rows.items.len > total_rows) {
            if (self.rows.pop().?) |v| alloc.free(v);
        }
        while (self.rows.items.len < total_rows) try self.rows.append(alloc, null);
        self.total_rows = total_rows;
        self.total_cols = total_cols;
    }

    fn setRow(self: *GridState, alloc: std.mem.Allocator, row: u32, verts: []const Vertex) !void {
        const slot = &self.rows.items[row];
        if (slot.*) |old| alloc.free(old);
        slot.* = try alloc.dupe(Vertex, verts);
    }
};

const Grids = std.AutoHashMapUnmanaged(i64, GridState);

fn deinitGrids(alloc: std.mem.Allocator, grids: *Grids) void {
    var it = grids.valueIterator();
    while (it.next()) |g| g.deinit(alloc);
    grids.deinit(alloc);
}

fn cloneGrids(alloc: std.mem.Allocator, src: *const Grids) !Grids {
    var out: Grids = .empty;
    errdefer deinitGrids(alloc, &out);
    var it = src.iterator();
    while (it.next()) |e| {
        var g = try e.value_ptr.clone(alloc);
        errdefer g.deinit(alloc);
        try out.put(alloc, e.key_ptr.*, g);
    }
    return out;
}

pub const Model = struct {
    alloc: std.mem.Allocator,
    /// What the screen shows: the last committed bracket.
    committed: Grids = .empty,
    /// The write set of the open bracket; null outside one.
    pending: ?Grids = null,
    /// Refuse the next bracket at on_flush_end (header :1883: "when the
    /// frontend cannot accept this flush"). Set by the test, consumed once.
    refuse_next: bool = false,
    /// Where a refusal is reported: the Core's abort flag, as
    /// zonvie_core_abort_flush sets it.
    abort_flag: ?*bool = null,
    /// A callback the header says never happens arrived (both or neither of
    /// MAIN/CURSOR, row_count > 1, a send outside a bracket, a row out of
    /// range). Tests assert this stays empty.
    violation: ?[]const u8 = null,
    commits: u32 = 0,
    refusals: u32 = 0,
    /// Row shifts received, committed or not.
    shifts: u32 = 0,
    /// MAIN row sends received, committed or not.
    main_sends: u32 = 0,

    pub fn init(alloc: std.mem.Allocator) Model {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Model) void {
        deinitGrids(self.alloc, &self.committed);
        if (self.pending) |*p| deinitGrids(self.alloc, p);
        self.* = undefined;
    }

    /// Point `cbs` (the C ABI struct or the Core's own) at this model. The core
    /// passes `ctx` back to every callback.
    pub fn install(self: *Model, cbs: anytype, ctx: *?*anyopaque) void {
        ctx.* = self;
        cbs.on_flush_begin = onFlushBegin;
        cbs.on_flush_end = onFlushEnd;
        cbs.on_vertices_row = onVerticesRow;
        cbs.on_grid_row_scroll = onGridRowScroll;
    }

    pub fn grid(self: *const Model, grid_id: i64) ?*const GridState {
        return self.committed.getPtr(grid_id);
    }

    /// Neovim shows one cursor, so with it visible on `owner` exactly that
    /// grid holds a non-empty cursor layer; every other grid was cleared
    /// (header :205: vert_count=0 clears). null: no grid shows one.
    pub fn cursorOwnerMismatch(self: *const Model, owner: ?i64) ?[]const u8 {
        var it = self.committed.iterator();
        while (it.next()) |e| {
            const holds = e.value_ptr.cursor.len != 0;
            const should = owner != null and owner.? == e.key_ptr.*;
            if (holds and !should) return "a grid the cursor is not on holds a cursor layer";
            if (!holds and should) return "the cursor's grid holds no cursor layer";
        }
        if (owner) |g| if (!self.committed.contains(g)) return "the cursor's grid was never sent";
        return null;
    }

    fn fail(self: *Model, why: []const u8) void {
        if (self.violation == null) self.violation = why;
    }

    fn from(ctx: ?*anyopaque) *Model {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn pendingGrid(self: *Model, grid_id: i64) !*GridState {
        const gop = try self.pending.?.getOrPut(self.alloc, grid_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        return gop.value_ptr;
    }

    fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
        const self = from(ctx);
        if (self.pending != null) return self.fail("on_flush_begin inside an open bracket");
        self.pending = cloneGrids(self.alloc, &self.committed) catch return self.fail("model OOM");
    }

    fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
        const self = from(ctx);
        var p = self.pending orelse return self.fail("on_flush_end without on_flush_begin");
        self.pending = null;
        const refuse = self.refuse_next or (self.abort_flag != null and self.abort_flag.?.*);
        if (self.refuse_next) {
            self.refuse_next = false;
            if (self.abort_flag) |f| f.* = true;
        }
        if (refuse) {
            // Header :1891: keep the last committed frame.
            deinitGrids(self.alloc, &p);
            self.refusals += 1;
            return;
        }
        deinitGrids(self.alloc, &self.committed);
        self.committed = p;
        self.commits += 1;
    }

    fn onVerticesRow(
        ctx: ?*anyopaque,
        grid_id: i64,
        row_start: u32,
        row_count: u32,
        verts: ?[*]const Vertex,
        vert_count: usize,
        flags: u32,
        total_rows: u32,
        total_cols: u32,
    ) callconv(.c) void {
        const self = from(ctx);
        if (self.pending == null) return self.fail("on_vertices_row outside a bracket");
        const main = flags & c_api.VERT_UPDATE_MAIN != 0;
        const cursor = flags & c_api.VERT_UPDATE_CURSOR != 0;
        if (main == cursor) return self.fail("on_vertices_row with both or neither of MAIN/CURSOR");
        if (row_count > 1) return self.fail("on_vertices_row with row_count > 1");
        const g = self.pendingGrid(grid_id) catch return self.fail("model OOM");
        const payload: []const Vertex = if (verts) |v| v[0..vert_count] else &.{};

        if (cursor) {
            // Header :173: a vertex carries the grid it belongs to.
            for (payload) |v| if (v.grid_id != grid_id) return self.fail("CURSOR vertex grid_id differs from the callback's");
            // Header :205-206: the complete cursor layer; rows untouched.
            self.alloc.free(g.cursor);
            g.cursor = self.alloc.dupe(Vertex, payload) catch return self.fail("model OOM");
            return;
        }

        if (total_rows != g.total_rows or total_cols != g.total_cols) {
            g.setShape(self.alloc, total_rows, total_cols) catch return self.fail("model OOM");
        }
        if (row_count == 0) {
            // Header :203-206: layout-only zero-cell transition.
            if (verts != null or vert_count != 0) return self.fail("zero-row MAIN carried vertices");
            if (total_rows != 0 and total_cols != 0) return self.fail("zero-row MAIN with a non-zero shape");
            return;
        }
        if (row_start >= total_rows) return self.fail("MAIN row outside total_rows");
        self.main_sends += 1;
        // Header :201-202: the last send wins.
        g.setRow(self.alloc, row_start, payload) catch return self.fail("model OOM");
    }

    fn onGridRowScroll(
        ctx: ?*anyopaque,
        grid_id: i64,
        row_start: u32,
        row_end: u32,
        col_start: u32,
        col_end: u32,
        rows_delta: i32,
        total_rows: u32,
        total_cols: u32,
    ) callconv(.c) void {
        _ = total_cols;
        const self = from(ctx);
        if (self.pending == null) return self.fail("on_grid_row_scroll outside a bracket");
        self.shifts += 1;
        // Header :228: grid 1 never gets a shift.
        if (grid_id == 1) return self.fail("row shift for grid 1");
        const g = self.pendingGrid(grid_id) catch return self.fail("model OOM");
        // Header :216: always full width.
        if (col_start != 0 or col_end != g.total_cols) return self.fail("row shift not full width");
        if (row_end > g.rows.items.len or row_start >= row_end) return self.fail("row shift region out of range");
        if (total_rows != g.total_rows) return self.fail("row shift on a resized grid");
        const height: u32 = row_end - row_start;
        const mag: u32 = @abs(rows_delta);
        // Header :212: at most half the region.
        if (mag == 0 or mag * 2 > height) return self.fail("row shift delta out of range");

        // Neovim grid_scroll: rows_delta > 0 moves content up (row r takes
        // r + delta); the rows it leaves are vacated and the core sends them.
        const rows = g.rows.items[row_start..row_end];
        if (rows_delta > 0) {
            for (rows[0..mag]) |r| if (r) |v| self.alloc.free(v);
            std.mem.copyForwards(?[]Vertex, rows[0 .. height - mag], rows[mag..]);
            @memset(rows[height - mag ..], null);
        } else {
            for (rows[height - mag ..]) |r| if (r) |v| self.alloc.free(v);
            std.mem.copyBackwards(?[]Vertex, rows[mag..], rows[0 .. height - mag]);
            @memset(rows[0..mag], null);
        }
        // Row vertices are grid-local; a shifted row keeps the y of the row it
        // was generated for, so its geometry moves by the shift. The model
        // translates them so a shifted row equals what a resend would carry.
        const cell_h = rowHeight(rows);
        if (cell_h) |h| {
            const dy = -@as(f32, @floatFromInt(rows_delta)) * h;
            for (rows) |r| if (r) |v| for (v) |*vert| {
                vert.position[1] += dy;
            };
        }
    }

    /// The grid-local height of one row, from any row whose vertices span it;
    /// null when nothing filled tells.
    fn rowHeight(rows: []const ?[]Vertex) ?f32 {
        for (rows) |r| {
            const v = r orelse continue;
            if (v.len == 0) continue;
            var lo = v[0].position[1];
            var hi = v[0].position[1];
            for (v[1..]) |x| {
                lo = @min(lo, x.position[1]);
                hi = @max(hi, x.position[1]);
            }
            if (hi > lo) return hi - lo;
        }
        return null;
    }
};

/// Whether two held grids show the same thing: same shape, every row filled
/// in both and equal vertex for vertex, same cursor layer. Returns the first
/// difference for the failure message.
pub fn diff(a: *const GridState, b: *const GridState) ?[]const u8 {
    if (a.total_rows != b.total_rows or a.total_cols != b.total_cols) return "shape differs";
    for (a.rows.items, b.rows.items) |ra, rb| {
        const va = ra orelse return "a row was never sent (left)";
        const vb = rb orelse return "a row was never sent (right)";
        if (!std.mem.eql(u8, std.mem.sliceAsBytes(va), std.mem.sliceAsBytes(vb))) return "row contents differ";
    }
    if (!std.mem.eql(u8, std.mem.sliceAsBytes(a.cursor), std.mem.sliceAsBytes(b.cursor))) return "cursor layer differs";
    return null;
}

// ---------------------------------------------------------------------------
// The model against the header, with no core involved.

fn vertAt(y: f32, tag: f32) Vertex {
    var v = std.mem.zeroes(Vertex);
    v.position = .{ tag, y };
    return v;
}

/// A row of two vertices spanning grid-local [row, row+1) at cell height 1.
fn rowVerts(row: u32, tag: f32) [2]Vertex {
    const y: f32 = @floatFromInt(row);
    return .{ vertAt(y, tag), vertAt(y + 1, tag) };
}

fn sendMain(m: *Model, grid_id: i64, row: u32, verts: []const Vertex, rows: u32) void {
    Model.onVerticesRow(m, grid_id, row, 1, verts.ptr, verts.len, c_api.VERT_UPDATE_MAIN, rows, 4);
}

test "MAIN replaces one row and leaves the others; CURSOR never touches rows" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    Model.onFlushBegin(&m);
    for (0..3) |r| {
        const v = rowVerts(@intCast(r), 1);
        sendMain(&m, 2, @intCast(r), &v, 3);
    }
    Model.onFlushEnd(&m);

    Model.onFlushBegin(&m);
    const v1 = rowVerts(1, 9);
    sendMain(&m, 2, 1, &v1, 3);
    var cur = [_]Vertex{vertAt(0, 7)};
    cur[0].grid_id = 2;
    Model.onVerticesRow(&m, 2, 0, 1, &cur, 1, c_api.VERT_UPDATE_CURSOR, 3, 4);
    Model.onFlushEnd(&m);

    try std.testing.expect(m.violation == null);
    const g = m.grid(2).?;
    try std.testing.expectEqual(@as(f32, 1), g.rows.items[0].?[0].position[0]);
    try std.testing.expectEqual(@as(f32, 9), g.rows.items[1].?[0].position[0]);
    try std.testing.expectEqual(@as(f32, 1), g.rows.items[2].?[0].position[0]);
    try std.testing.expectEqual(@as(usize, 1), g.cursor.len);

    // A zero-vertex CURSOR clears the layer and still leaves rows alone.
    Model.onFlushBegin(&m);
    Model.onVerticesRow(&m, 2, 0, 0, null, 0, c_api.VERT_UPDATE_CURSOR, 3, 4);
    Model.onFlushEnd(&m);
    try std.testing.expectEqual(@as(usize, 0), m.grid(2).?.cursor.len);
    try std.testing.expectEqual(@as(f32, 9), m.grid(2).?.rows.items[1].?[0].position[0]);
}

test "a refused bracket leaves the committed frame as it was" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    var aborted = false;
    m.abort_flag = &aborted;
    Model.onFlushBegin(&m);
    const v = rowVerts(0, 1);
    sendMain(&m, 2, 0, &v, 1);
    Model.onFlushEnd(&m);

    m.refuse_next = true;
    Model.onFlushBegin(&m);
    const w = rowVerts(0, 5);
    sendMain(&m, 2, 0, &w, 1);
    Model.onFlushEnd(&m);

    try std.testing.expect(aborted);
    try std.testing.expectEqual(@as(u32, 1), m.refusals);
    try std.testing.expectEqual(@as(f32, 1), m.grid(2).?.rows.items[0].?[0].position[0]);
}

test "within one bracket the last send of a row wins" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    Model.onFlushBegin(&m);
    const a = rowVerts(0, 1);
    const b = rowVerts(0, 2);
    sendMain(&m, 2, 0, &a, 1);
    sendMain(&m, 2, 0, &b, 1);
    Model.onFlushEnd(&m);
    try std.testing.expectEqual(@as(f32, 2), m.grid(2).?.rows.items[0].?[0].position[0]);
}

test "a row shift moves rows by the delta and leaves the vacated rows unfilled" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    Model.onFlushBegin(&m);
    for (0..4) |r| {
        const v = rowVerts(@intCast(r), @floatFromInt(r));
        sendMain(&m, 2, @intCast(r), &v, 4);
    }
    Model.onFlushEnd(&m);

    // Content moves up one row: row 0 now holds what row 1 held, placed at
    // row 0's y, and row 3 waits for the core.
    Model.onFlushBegin(&m);
    Model.onGridRowScroll(&m, 2, 0, 4, 0, 4, 1, 4, 4);
    Model.onFlushEnd(&m);
    const g = m.grid(2).?;
    try std.testing.expect(m.violation == null);
    try std.testing.expectEqual(@as(f32, 1), g.rows.items[0].?[0].position[0]);
    try std.testing.expectEqual(@as(f32, 0), g.rows.items[0].?[0].position[1]);
    try std.testing.expectEqual(@as(f32, 3), g.rows.items[2].?[0].position[0]);
    try std.testing.expect(g.rows.items[3] == null);
}

test "callbacks the header rules out are reported, not absorbed" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    const v = rowVerts(0, 1);
    // Outside a bracket.
    sendMain(&m, 2, 0, &v, 1);
    try std.testing.expect(m.violation != null);

    var m2 = Model.init(std.testing.allocator);
    defer m2.deinit();
    Model.onFlushBegin(&m2);
    Model.onVerticesRow(&m2, 2, 0, 1, &v, v.len, c_api.VERT_UPDATE_MAIN | c_api.VERT_UPDATE_CURSOR, 1, 4);
    Model.onFlushEnd(&m2);
    try std.testing.expect(m2.violation != null);

    var m3 = Model.init(std.testing.allocator);
    defer m3.deinit();
    Model.onFlushBegin(&m3);
    sendMain(&m3, 2, 0, &v, 2);
    // A shift past half the region.
    Model.onGridRowScroll(&m3, 2, 0, 2, 0, 4, 2, 2, 4);
    Model.onFlushEnd(&m3);
    try std.testing.expect(m3.violation != null);
}

// ---------------------------------------------------------------------------
// The core against the model. These drive a real Core; the model above stays
// the only judge of what a consumer ends up showing.

const Core = @import("nvim_core.zig").Core;
const FlushCtx = @import("flush.zig").FlushCtx;

/// Highlight ids 1..16 with distinct background colours. The test Core has no
/// glyph callbacks, so a cell's text never reaches its vertices; its
/// background colour does, which is what makes a row's contents comparable.
fn defineRowColors(core: *Core) !void {
    var id: u32 = 1;
    while (id <= 16) : (id += 1) {
        try core.hl.define(id, null, 0x100000 * id + 0x40, null, false, 0, .{}, false);
    }
}

/// An external grid of `rows` x 2; row r's first cell uses highlight r + 1.
fn externalGridCore(core: *Core, rows: u32) !void {
    try defineRowColors(core);
    try core.grid.resizeGrid(1, rows, 2);
    try core.grid.resizeGrid(2, rows, 2);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = rows,
        .cols = 2,
    });
    for (0..rows) |row| core.grid.putCellGrid(2, @intCast(row), 0, @intCast('A' + row), @intCast(row + 1));
    core.drawable_w_px = 2;
    core.drawable_h_px = rows;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;
}

/// What a consumer holds after the core resends everything into a fresh one.
fn fullResend(core: *Core, rows: u32) !Model {
    var full = Model.init(std.testing.allocator);
    errdefer full.deinit();
    full.install(&core.cb, &core.ctx);
    full.abort_flag = &core.flush_aborted;
    core.grid.markEverySurfaceDirty();
    core.grid.cursor_rev +%= 1;
    var flush_ctx = FlushCtx{ .core = core };
    try flush_ctx.onFlush(rows, 2);
    try std.testing.expect(full.violation == null);
    return full;
}

test "after a shifted external scroll the consumer holds what a full resend would" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try externalGridCore(&core, 4);

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.install(&core.cb, &core.ctx);
    m.abort_flag = &core.flush_aborted;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 2);

    // Neovim scrolls the grid up one row and draws the row it exposed.
    core.grid.scrollGrid(2, 0, 4, 0, 2, 1, 0);
    core.grid.putCellGrid(2, 3, 0, 'Z', 9);
    const sends_before = m.main_sends;
    try flush_ctx.onFlush(4, 2);
    try std.testing.expect(m.violation == null);
    try std.testing.expectEqual(@as(u32, 2), m.commits);
    // The shift path was taken and only the exposed row was resent, not a
    // regeneration that would make the comparison below trivially true.
    try std.testing.expectEqual(@as(u32, 1), m.shifts);
    try std.testing.expectEqual(@as(u32, 1), m.main_sends - sends_before);

    var full = try fullResend(&core, 4);
    defer full.deinit();
    if (diff(m.grid(2).?, full.grid(2).?)) |why| {
        std.debug.print("incremental != full: {s}\n", .{why});
        return error.IncrementalDiffersFromFull;
    }
}

test "a refused bracket is resent by the next flush and ends where a full resend does" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try externalGridCore(&core, 4);

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.install(&core.cb, &core.ctx);
    m.abort_flag = &core.flush_aborted;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 2);

    // An edit the consumer refuses at on_flush_end: the screen keeps the old
    // row, and the core must owe it again (header :1893-1894).
    core.grid.putCellGrid(2, 1, 0, 'Q', 10);
    m.refuse_next = true;
    try flush_ctx.onFlush(4, 2);
    try std.testing.expectEqual(@as(u32, 1), m.refusals);

    // Nothing else changes; the next flush alone must deliver the edit.
    try flush_ctx.onFlush(4, 2);
    try std.testing.expect(m.violation == null);

    var full = try fullResend(&core, 4);
    defer full.deinit();
    if (diff(m.grid(2).?, full.grid(2).?)) |why| {
        std.debug.print("after refusal, incremental != full: {s}\n", .{why});
        return error.IncrementalDiffersFromFull;
    }
}

/// Grid 2 as a split of the main window at (0, 0), holding the same cells
/// `externalGridCore` gives the external window.
fn splitGridCore(core: *Core, rows: u32) !void {
    try defineRowColors(core);
    try core.grid.resizeGrid(1, rows, 2);
    try core.grid.resizeGrid(2, rows, 2);
    try core.grid.setWinPos(2, 42, 0, 0);
    for (0..rows) |row| core.grid.putCellGrid(2, @intCast(row), 0, @intCast('A' + row), @intCast(row + 1));
    core.drawable_w_px = 2;
    core.drawable_h_px = rows;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;
}

test "a scrolled split and a scrolled external window end with the same rows" {
    var cores: [2]Core = .{ Core.initForTest(std.testing.allocator), Core.initForTest(std.testing.allocator) };
    defer for (&cores) |*c| c.deinitForTest();
    try splitGridCore(&cores[0], 4);
    try externalGridCore(&cores[1], 4);
    var models: [2]Model = .{ Model.init(std.testing.allocator), Model.init(std.testing.allocator) };
    defer for (&models) |*m| m.deinit();

    for (&cores, &models) |*core, *m| {
        m.install(&core.cb, &core.ctx);
        m.abort_flag = &core.flush_aborted;
        var flush_ctx = FlushCtx{ .core = core };
        try flush_ctx.onFlush(4, 2);
        // Neovim scrolls the window up one row and draws the row it exposed.
        core.grid.scrollGrid(2, 0, 4, 0, 2, 1, 0);
        core.grid.putCellGrid(2, 3, 0, 'Z', 9);
        const sends_before = m.main_sends;
        try flush_ctx.onFlush(4, 2);
        try std.testing.expect(m.violation == null);
        // Both shift and resend only the exposed row; a regenerated region
        // would make the comparison below trivially true.
        try std.testing.expectEqual(@as(u32, 1), m.shifts);
        try std.testing.expectEqual(@as(u32, 1), m.main_sends - sends_before);
    }

    if (diff(models[0].grid(2).?, models[1].grid(2).?)) |why| {
        std.debug.print("split != external: {s}\n", .{why});
        return error.SplitDiffersFromExternal;
    }
    var full = try fullResend(&cores[0], 4);
    defer full.deinit();
    if (diff(models[0].grid(2).?, full.grid(2).?)) |why| {
        std.debug.print("split incremental != full: {s}\n", .{why});
        return error.IncrementalDiffersFromFull;
    }
}

test "diff reports a row the core never sent" {
    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    Model.onFlushBegin(&m);
    const v = rowVerts(0, 1);
    sendMain(&m, 2, 0, &v, 2); // row 1 of 2 never sent
    Model.onFlushEnd(&m);
    var full = Model.init(std.testing.allocator);
    defer full.deinit();
    Model.onFlushBegin(&full);
    sendMain(&full, 2, 0, &v, 2);
    const w = rowVerts(1, 1);
    sendMain(&full, 2, 1, &w, 2);
    Model.onFlushEnd(&full);
    try std.testing.expect(diff(m.grid(2).?, full.grid(2).?) != null);
}

test "a scroll on grid 1 is resent, never shifted" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try defineRowColors(&core);
    try core.grid.resizeGrid(1, 4, 2);
    for (0..4) |row| core.grid.putCellGrid(1, @intCast(row), 0, @intCast('A' + row), @intCast(row + 1));
    core.drawable_w_px = 2;
    core.drawable_h_px = 4;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;

    var m = Model.init(std.testing.allocator);
    defer m.deinit();
    m.install(&core.cb, &core.ctx);
    m.abort_flag = &core.flush_aborted;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 2);
    core.grid.scrollGrid(1, 0, 4, 0, 2, 1, 0);
    core.grid.putCellGrid(1, 3, 0, 'Z', 9);
    try flush_ctx.onFlush(4, 2);
    if (m.violation) |why| {
        std.debug.print("grid 1 scroll: {s}\n", .{why});
        return error.HeaderViolation;
    }
    var full = try fullResend(&core, 4);
    defer full.deinit();
    if (diff(m.grid(1).?, full.grid(1).?)) |why| {
        std.debug.print("grid 1 incremental != full: {s}\n", .{why});
        return error.IncrementalDiffersFromFull;
    }
}
