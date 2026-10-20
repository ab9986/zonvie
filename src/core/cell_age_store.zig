//! The CPU side of every surface's iCellAge texture, shared by both
//! frontends: one store per texture, keyed the way the core stamps
//! (`zonvie_cell_stamp.grid`) — 1 for the main window's screen-space cells,
//! otherwise the grid id of an external window, indexed by that grid.
//!
//! The core thread writes it from on_cell_age_stamps; each surface's draw
//! sizes its store and uploads it. `mu` is a leaf: nothing under it calls
//! out except the caller's own upload between `sync` and `endUpload`.

const std = @import("std");
const clock = @import("clock.zig");
const CellStamp = @import("grid.zig").CellStamp;

/// Stamps held for a texture whose store is not sized yet — the first
/// keystroke after a window opens arrives before that window's first shaded
/// draw. Capped per grid so a window that never draws cannot hog the queue.
pub const pending_cap_per_grid: usize = 16;
const pending_capacity: usize = 64;

/// Textures whose clean frames skip the lock. A store past this many still
/// works, through the locked path every frame.
const slot_count: usize = 16;
const no_slot: u32 = std.math.maxInt(u32);

const Store = struct {
    grid: i64,
    /// Index into `Stores.slot_versions`, or `no_slot`.
    slot: u32 = no_slot,
    cols: u32 = 0,
    rows: u32 = 0,
    values: []f32 = &.{},
    dirty: bool = false,
    last_edit: f32 = 0,
};

const Pending = struct {
    grid: i64,
    row: u16,
    col: u16,
    count: u16,
    time: f32,
};

pub const SyncResult = enum(i32) {
    /// No texture can be bound: zero size or out of memory.
    unavailable = 0,
    /// The texture already holds the mirror.
    clean = 1,
    /// `values` must be uploaded; `mu` stays held until `endUpload`.
    dirty = 2,
};

/// What one texture's owner saw at its last `sync`. Lets an unchanged frame
/// skip the lock: `version` matches its store's slot only while that store
/// is unchanged since, and 0 (a zeroed cache) never matches. `last_edit` is
/// the texture's iTimeLastEdit as of the same sync.
pub const SyncCache = extern struct {
    version: u64 = 0,
    slot: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    last_edit: f32 = 0,
};

pub const Stores = struct {
    alloc: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    /// One counter per slotted store, bumped under `mu` by every change to
    /// that store a sync could observe and read without it by the clean fast
    /// path. Per store, so a keystroke in one window leaves every other
    /// window's frame lock-free. Never reset: a freed slot's next owner
    /// starts past any version a stale cache holds. Start at 1; 0 is a
    /// zeroed cache.
    slot_versions: [slot_count]std.atomic.Value(u64) = @splat(.init(1)),
    slot_used: [slot_count]bool = @splat(false),
    /// A handful of textures (main + open external windows): a linear scan
    /// beats hashing on the per-flush apply path.
    stores: std.ArrayListUnmanaged(Store) = .empty,
    pending: [pending_capacity]Pending = undefined,
    pending_len: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Stores {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Stores) void {
        for (self.stores.items) |*st| self.freeValues(st);
        self.stores.deinit(self.alloc);
        self.* = undefined;
    }

    /// Apply one flush's stamps, in the order the ABI documents. Core thread.
    pub fn apply(self: *Stores, stamps: []const CellStamp, clear: bool, now: f32) void {
        if (!clear and stamps.len == 0) return;
        self.lock();
        defer self.unlock();
        if (clear) {
            // Every texture: a bulk repaint invalidates whatever any window
            // still shows.
            for (self.stores.items) |*st| self.zero(st);
            self.pending_len = 0;
            return;
        }
        if (now <= 0) return;
        var bumped: ?*Store = null;
        for (stamps) |s| {
            const grid: i64 = s.grid;
            if (s.count == 0) {
                // Clear marker: zero just this texture.
                if (self.find(grid)) |st| self.zero(st);
                self.dropPending(grid);
                continue;
            }
            if (self.find(grid)) |st| {
                if (st.cols > 0) {
                    // One bump per run of changing stamps on the same store.
                    if (stamp(st, s.row, s.col, s.count, now) and st != bumped) {
                        self.bump(st);
                        bumped = st;
                    }
                    continue;
                }
            }
            self.pushPending(.{ .grid = grid, .row = s.row, .col = s.col, .count = s.count, .time = now });
        }
    }

    /// Size `grid`'s store to cols x rows and report whether its texture
    /// needs an upload. `force` marks the mirror dirty first, for a texture
    /// that was just created and holds garbage. On `.dirty`, `out_values` is
    /// the mirror and `mu` is held until `endUpload`, so the upload reads a
    /// stable copy. A resize invalidates every stamp position, so the store
    /// starts clean rather than remapping ages onto cells that now hold
    /// different text. `cache` is the caller's, one per texture; it also
    /// carries the texture's iTimeLastEdit out. Drawing thread.
    pub inline fn sync(self: *Stores, grid: i64, cols: u32, rows: u32, force: bool, cache: *SyncCache, out_values: *[]const f32) SyncResult {
        if (cols == 0 or rows == 0) return .unavailable;
        // Every frame of every shaded surface lands here, nearly always with
        // nothing changed since its last look.
        if (!force and cache.slot < slot_count and
            cache.version == self.slot_versions[cache.slot].load(.acquire) and
            cache.cols == cols and cache.rows == rows) return .clean;
        return self.syncLocked(grid, cols, rows, force, cache, out_values);
    }

    noinline fn syncLocked(self: *Stores, grid: i64, cols: u32, rows: u32, force: bool, cache: *SyncCache, out_values: *[]const f32) SyncResult {
        self.lock();
        const st = self.sized(grid, cols, rows) orelse {
            cache.* = .{};
            self.unlock();
            return .unavailable;
        };
        cache.* = .{
            .version = if (st.slot != no_slot) self.slot_versions[st.slot].load(.monotonic) else 0,
            .slot = st.slot,
            .cols = cols,
            .rows = rows,
            .last_edit = st.last_edit,
        };
        if (force) st.dirty = true;
        if (!st.dirty) {
            self.unlock();
            return .clean;
        }
        st.dirty = false;
        out_values.* = st.values;
        return .dirty;
    }

    pub fn endUpload(self: *Stores) void {
        self.unlock();
    }

    /// Forget an external window's store when that window goes away, so a
    /// later window that reuses the grid id starts unedited.
    pub fn drop(self: *Stores, grid: i64) void {
        self.lock();
        defer self.unlock();
        for (self.stores.items, 0..) |*st, i| {
            if (st.grid != grid) continue;
            self.release(st);
            _ = self.stores.swapRemove(i);
            break;
        }
        self.dropPending(grid);
    }

    pub fn removeAll(self: *Stores) void {
        self.lock();
        defer self.unlock();
        for (self.stores.items) |*st| self.release(st);
        self.stores.clearRetainingCapacity();
        self.pending_len = 0;
    }

    fn find(self: *Stores, grid: i64) ?*Store {
        for (self.stores.items) |*st| {
            if (st.grid == grid) return st;
        }
        return null;
    }

    fn sized(self: *Stores, grid: i64, cols: u32, rows: u32) ?*Store {
        const st = self.find(grid) orelse blk: {
            const st = self.stores.addOne(self.alloc) catch return null;
            st.* = .{ .grid = grid };
            for (&self.slot_used, 0..) |*used, i| {
                if (used.*) continue;
                used.* = true;
                st.slot = @intCast(i);
                break;
            }
            break :blk st;
        };
        if (st.cols == cols and st.rows == rows) return st;
        const n: usize = @as(usize, cols) * @as(usize, rows);
        const buf = self.alloc.alloc(f32, n) catch return null;
        @memset(buf, 0);
        self.bump(st);
        self.freeValues(st);
        st.cols = cols;
        st.rows = rows;
        st.values = buf;
        st.dirty = true;
        var i: usize = 0;
        while (i < self.pending_len) {
            const p = self.pending[i];
            if (p.grid != grid) {
                i += 1;
                continue;
            }
            _ = stamp(st, p.row, p.col, p.count, p.time);
            self.pending_len -= 1;
            self.pending[i] = self.pending[self.pending_len];
        }
        return st;
    }

    fn pushPending(self: *Stores, p: Pending) void {
        if (self.pending_len == pending_capacity) return;
        var n: usize = 0;
        for (self.pending[0..self.pending_len]) |q| {
            if (q.grid == p.grid) n += 1;
        }
        if (n >= pending_cap_per_grid) return;
        self.pending[self.pending_len] = p;
        self.pending_len += 1;
    }

    fn dropPending(self: *Stores, grid: i64) void {
        var i: usize = 0;
        while (i < self.pending_len) {
            if (self.pending[i].grid == grid) {
                self.pending_len -= 1;
                self.pending[i] = self.pending[self.pending_len];
            } else i += 1;
        }
    }

    fn freeValues(self: *Stores, st: *Store) void {
        if (st.values.len != 0) self.alloc.free(st.values);
        st.values = &.{};
        st.cols = 0;
        st.rows = 0;
    }

    /// Under `mu`. A fast-path reader that misses the bump sees the change
    /// on its next frame, as if the change had landed after that frame.
    fn bump(self: *Stores, st: *const Store) void {
        if (st.slot != no_slot) _ = self.slot_versions[st.slot].fetchAdd(1, .release);
    }

    fn zero(self: *Stores, st: *Store) void {
        @memset(st.values, 0);
        st.dirty = true;
        self.bump(st);
    }

    /// Free a store's mirror and slot. The bump turns away any cache still
    /// naming the slot.
    fn release(self: *Stores, st: *Store) void {
        self.freeValues(st);
        if (st.slot == no_slot) return;
        self.bump(st);
        self.slot_used[st.slot] = false;
        st.slot = no_slot;
    }

    fn lock(self: *Stores) void {
        self.mu.lockUncancelable(clock.io());
    }

    fn unlock(self: *Stores) void {
        self.mu.unlock(clock.io());
    }
};

/// Returns whether any cell changed; a run wholly past the edge does not.
fn stamp(st: *Store, row: u16, col: u16, count: u16, time: f32) bool {
    if (row >= st.rows) return false;
    const col_end: u32 = @min(st.cols, @as(u32, col) + count);
    if (col >= col_end) return false;
    const base: usize = @as(usize, row) * st.cols;
    @memset(st.values[base + col .. base + col_end], time);
    st.last_edit = @max(st.last_edit, time);
    st.dirty = true;
    return true;
}

/// The cell grid a screen-space iCellAge texture needs to cover a surface,
/// indexed with the shader's own formula floor((fragCoord - iGridOrigin) /
/// iCellSize). `row_h_px` is the grid row height, 'linespace' included —
/// the height given to zonvie_core_update_layout_px — which is also what
/// iCellSize.y must carry for the lookup to track the drawn rows.
pub fn surfaceGrid(surface_w_px: f32, surface_h_px: f32, cell_w_px: f32, row_h_px: f32) struct { cols: u32, rows: u32 } {
    if (!(cell_w_px > 0) or !(row_h_px > 0)) return .{ .cols = 0, .rows = 0 };
    return .{
        .cols = @max(1, @as(u32, @intFromFloat(@ceil(@max(0, surface_w_px) / cell_w_px)))),
        .rows = @max(1, @as(u32, @intFromFloat(@ceil(@max(0, surface_h_px) / row_h_px)))),
    };
}

const testing = std.testing;

/// A fresh cache per call: always the locked path, as on a first frame.
fn syncValues(s: *Stores, grid: i64, cols: u32, rows: u32) ?[]const f32 {
    var cache: SyncCache = .{};
    var v: []const f32 = &.{};
    return switch (s.sync(grid, cols, rows, false, &cache, &v)) {
        .dirty => blk: {
            s.endUpload();
            break :blk v;
        },
        else => null,
    };
}

fn lastEdit(s: *Stores, grid: i64, cols: u32, rows: u32) f32 {
    var cache: SyncCache = .{};
    var v: []const f32 = &.{};
    if (s.sync(grid, cols, rows, false, &cache, &v) == .dirty) s.endUpload();
    return cache.last_edit;
}

test "stamps land only in the texture their grid names" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    _ = syncValues(&s, 1, 4, 2);
    _ = syncValues(&s, 7, 4, 2);
    s.apply(&.{
        .{ .row = 1, .col = 1, .count = 2, .grid = 1 },
        .{ .row = 0, .col = 3, .count = 1, .grid = 7 },
    }, false, 2.5);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0, 0, 2.5, 2.5, 0 }, syncValues(&s, 1, 4, 2).?);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 2.5, 0, 0, 0, 0 }, syncValues(&s, 7, 4, 2).?);
    try testing.expectEqual(@as(f32, 2.5), lastEdit(&s, 7, 4, 2));
    // A list naming only grid 7 must not advance grid 1's iTimeLastEdit.
    s.apply(&.{.{ .row = 0, .col = 0, .count = 1, .grid = 7 }}, false, 4);
    try testing.expectEqual(@as(f32, 2.5), lastEdit(&s, 1, 4, 2));
    var cache: SyncCache = .{};
    var v: []const f32 = &.{};
    try testing.expectEqual(SyncResult.clean, s.sync(1, 4, 2, false, &cache, &v));
}

test "stamps are clipped to the store and a run past the edge is dropped" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    _ = syncValues(&s, 1, 3, 1);
    s.apply(&.{
        .{ .row = 0, .col = 2, .count = 5, .grid = 1 },
        .{ .row = 0, .col = 3, .count = 1, .grid = 1 },
        .{ .row = 1, .col = 0, .count = 1, .grid = 1 },
    }, false, 1);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 1 }, syncValues(&s, 1, 3, 1).?);
    // A list that changes no cell leaves a cached frame on the lock-free path.
    var cache: SyncCache = .{};
    var v: []const f32 = &.{};
    try testing.expectEqual(SyncResult.clean, s.sync(1, 3, 1, false, &cache, &v));
    s.apply(&.{.{ .row = 1, .col = 0, .count = 1, .grid = 1 }}, false, 2);
    try testing.expectEqual(cache.version, s.slot_versions[cache.slot].load(.monotonic));
}

test "a clear marker zeroes its own texture; the clear flag zeroes all" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    _ = syncValues(&s, 1, 2, 1);
    _ = syncValues(&s, 7, 2, 1);
    s.apply(&.{
        .{ .row = 0, .col = 0, .count = 2, .grid = 1 },
        .{ .row = 0, .col = 0, .count = 2, .grid = 7 },
    }, false, 3);
    s.apply(&.{.{ .row = 0, .col = 0, .count = 0, .grid = 7 }}, false, 4);
    try testing.expectEqualSlices(f32, &.{ 3, 3 }, syncValues(&s, 1, 2, 1).?);
    try testing.expectEqualSlices(f32, &.{ 0, 0 }, syncValues(&s, 7, 2, 1).?);
    s.apply(&.{}, true, 5);
    try testing.expectEqualSlices(f32, &.{ 0, 0 }, syncValues(&s, 1, 2, 1).?);
}

test "a stamp for an unsized texture waits for its first sync" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    s.apply(&.{.{ .row = 0, .col = 1, .count = 1, .grid = 9 }}, false, 2);
    try testing.expectEqualSlices(f32, &.{ 0, 2 }, syncValues(&s, 9, 2, 1).?);
    // Per-grid cap: grid 11 queues at most its share, so it cannot crowd
    // out grid 10's first keystroke.
    var many: [pending_cap_per_grid + 4]CellStamp = undefined;
    for (&many, 0..) |*m, i| m.* = .{ .row = 0, .col = @intCast(i), .count = 1, .grid = 11 };
    s.apply(&many, false, 3);
    s.apply(&.{.{ .row = 0, .col = 0, .count = 1, .grid = 10 }}, false, 4);
    try testing.expectEqualSlices(f32, &.{4}, syncValues(&s, 10, 1, 1).?);
    var stamped: usize = 0;
    for (syncValues(&s, 11, many.len, 1).?) |x| stamped += @intFromBool(x != 0);
    try testing.expectEqual(pending_cap_per_grid, stamped);
    // A clear marker discards what the grid had queued.
    s.apply(&.{
        .{ .row = 0, .col = 0, .count = 1, .grid = 12 },
        .{ .row = 0, .col = 0, .count = 0, .grid = 12 },
    }, false, 5);
    try testing.expectEqualSlices(f32, &.{0}, syncValues(&s, 12, 1, 1).?);
}

test "a resize starts clean and a dropped grid is forgotten" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    _ = syncValues(&s, 7, 2, 1);
    s.apply(&.{.{ .row = 0, .col = 0, .count = 1, .grid = 7 }}, false, 1);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, syncValues(&s, 7, 3, 1).?);
    s.drop(7);
    try testing.expectEqual(@as(f32, 0), lastEdit(&s, 7, 4, 2));
}

test "a cached sync stays clean until a change, then sees it" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    var main_cache: SyncCache = .{};
    var ext_cache: SyncCache = .{};
    var v: []const f32 = &.{};
    try testing.expectEqual(SyncResult.unavailable, s.sync(1, 0, 3, false, &main_cache, &v));
    try testing.expectEqual(SyncResult.dirty, s.sync(1, 2, 1, false, &main_cache, &v));
    s.endUpload();
    try testing.expectEqual(SyncResult.dirty, s.sync(7, 2, 1, false, &ext_cache, &v));
    s.endUpload();
    // Sizing grid 7 left grid 1 untouched.
    try testing.expectEqual(SyncResult.clean, s.sync(1, 2, 1, false, &main_cache, &v));
    try testing.expectEqual(SyncResult.clean, s.sync(1, 2, 1, false, &main_cache, &v));
    // A stamp on main reaches the cached reader, with its edit time.
    s.apply(&.{.{ .row = 0, .col = 1, .count = 1, .grid = 1 }}, false, 3);
    try testing.expectEqual(SyncResult.dirty, s.sync(1, 2, 1, false, &main_cache, &v));
    try testing.expectEqualSlices(f32, &.{ 0, 3 }, v);
    s.endUpload();
    try testing.expectEqual(@as(f32, 3), main_cache.last_edit);
    // The other texture's slot never moved, so its frame stays lock-free.
    try testing.expectEqual(ext_cache.version, s.slot_versions[ext_cache.slot].load(.monotonic));
    try testing.expectEqual(SyncResult.clean, s.sync(7, 2, 1, false, &ext_cache, &v));
    try testing.expectEqual(@as(f32, 0), ext_cache.last_edit);
    // A clear reaches every cached reader; force re-uploads a clean mirror.
    s.apply(&.{}, true, 4);
    try testing.expectEqual(SyncResult.dirty, s.sync(7, 2, 1, false, &ext_cache, &v));
    s.endUpload();
    try testing.expectEqual(SyncResult.clean, s.sync(7, 2, 1, false, &ext_cache, &v));
    try testing.expectEqual(SyncResult.dirty, s.sync(7, 2, 1, true, &ext_cache, &v));
    s.endUpload();
    // A size the cache has not seen goes to the store, which starts clean.
    try testing.expectEqual(SyncResult.dirty, s.sync(1, 3, 1, false, &main_cache, &v));
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0 }, v);
    s.endUpload();
}

test "surfaceGrid covers the surface with whole rows of row height" {
    // 'linespace' 3 on a 17 px cell: rows are 20 px, so 100 px is 5 rows.
    const g = surfaceGrid(95, 100, 10, 20);
    try testing.expectEqual(@as(u32, 10), g.cols);
    try testing.expectEqual(@as(u32, 5), g.rows);
    try testing.expectEqual(@as(u32, 0), surfaceGrid(95, 100, 0, 20).cols);
    // Fractional metrics (macOS) round up the same way.
    try testing.expectEqual(@as(u32, 11), surfaceGrid(100, 10, 9.5, 20).cols);
}
