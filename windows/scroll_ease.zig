//! Pixel-smooth scrolling of one grid: the eased offset a scroll leaves
//! behind, and which scrolled-off rows stay drawable to fill the band it
//! opens. Std-only, so the tests run on every host.
//!
//! Every grid_scroll a layer commits seeds its ease, whatever produced it
//! (wheel, keys, scrollbar, a command), so there is one animation path. The
//! offset is how far the content is still drawn from where the committed rows
//! put it: positive draws it lower. A critically damped spring brings it back
//! to zero, keeping its velocity across arrivals so a steady stream of
//! scrolls moves at a steady speed instead of stepping at every arrival.

const std = @import("std");

/// Settles in about 200 ms.
pub const spring_omega: f64 = 30.0;
/// Below this offset, and below this many px/s per omega, the ease is done.
pub const epsilon_px: f64 = 1.0;
/// Scrolled-off rows kept on each side of a scroll region. Also the most rows
/// one ease may cover, since past it the band has nothing left to show.
pub const retention_depth_rows: i32 = 8;

pub const LargeJumpBehavior = enum { partial, snap };

/// Rows an arrival may animate: 'mousescroll' ver, the rows one wheel event
/// is worth, bounded by what retention can fill. ver 0 animates nothing.
pub fn animatedCapRows(live_ver: i32) i32 {
    return std.math.clamp(live_ver, 0, retention_depth_rows);
}

/// Whether a scroll of `rows_delta` seeds an ease at all. `snap` refuses a
/// batch larger than one wheel event's worth, so jumps (page keys, searches)
/// land at once; `partial` animates the capped part of any batch.
pub fn admitsSeed(rows_delta: i32, live_ver: i32, mode: LargeJumpBehavior) bool {
    if (rows_delta == 0 or animatedCapRows(live_ver) == 0) return false;
    return switch (mode) {
        .partial => true,
        .snap => @abs(rows_delta) <= @as(u32, @intCast(@max(live_ver, 0))),
    };
}

pub const Ease = struct {
    offset_px: f64 = 0,
    velocity_px_s: f64 = 0,
    /// The previous tick, or 0 at rest so the first tick after a seed
    /// integrates nothing: a seed must not be decayed over the idle time
    /// before it arrived.
    last_tick_ns: i128 = 0,
    /// The row height the offset was built with; another one voids it.
    row_h_px: i32 = 0,
    /// The scroll region of the latest seed, half-open, in grid rows. Rows
    /// outside it (a winbar) do not move.
    region_start: u32 = 0,
    region_end: u32 = 0,

    pub fn moving(self: *const Ease) bool {
        return self.offset_px != 0 or self.velocity_px_s != 0;
    }

    pub fn reset(self: *Ease) void {
        self.* = .{};
    }

    /// Advance to `now_ns`. Runs before this frame's seed.
    pub fn tick(self: *Ease, now_ns: i128) void {
        if (!self.moving()) {
            self.last_tick_ns = 0;
            return;
        }
        const dt_s: f64 = if (self.last_tick_ns == 0)
            0
        else
            @as(f64, @floatFromInt(@max(now_ns - self.last_tick_ns, 0))) / std.time.ns_per_s;
        self.last_tick_ns = now_ns;
        const x = self.offset_px;
        const v = self.velocity_px_s;
        const a = v + spring_omega * x;
        const f = @exp(-spring_omega * dt_s);
        const next_x = (x + a * dt_s) * f;
        const next_v = (v - a * spring_omega * dt_s) * f;
        if (@abs(next_x) < epsilon_px and @abs(next_v) < spring_omega * epsilon_px) {
            self.offset_px = 0;
            self.velocity_px_s = 0;
            self.last_tick_ns = 0;
            return;
        }
        self.offset_px = next_x;
        self.velocity_px_s = next_v;
    }

    /// Give back a committed scroll of `rows_delta` rows (positive = content
    /// moved up) as offset, so the picture starts where it was. The sum is
    /// clamped to the cap; velocity is kept, unless the offset changes sign,
    /// where momentum toward the old side would overshoot. Returns whether
    /// the ease took it.
    pub fn seed(
        self: *Ease,
        now_ns: i128,
        rows_delta: i32,
        row_h_px: i32,
        region_start: u32,
        region_end: u32,
        live_ver: i32,
        mode: LargeJumpBehavior,
    ) bool {
        if (row_h_px <= 0 or region_end <= region_start) return false;
        // A refused batch leaves an ease in flight alone: clearing it would
        // collapse the offset in one frame whenever a scrollbar drag mixes
        // batches on both sides of the threshold.
        if (!admitsSeed(rows_delta, live_ver, mode)) return false;
        if (self.row_h_px != row_h_px or self.region_start != region_start or self.region_end != region_end) {
            self.reset();
            self.row_h_px = row_h_px;
            self.region_start = region_start;
            self.region_end = region_end;
        }
        const h: f64 = @floatFromInt(row_h_px);
        const limit = @as(f64, @floatFromInt(animatedCapRows(live_ver))) * h;
        const prev = self.offset_px;
        const next = std.math.clamp(prev + @as(f64, @floatFromInt(rows_delta)) * h, -limit, limit);
        if (prev != 0 and next != 0 and (prev < 0) != (next < 0)) self.velocity_px_s = 0;
        self.offset_px = next;
        if (self.last_tick_ns == 0) self.last_tick_ns = now_ns;
        return true;
    }
};

/// Where an old row of the region sits once the region scrolled by
/// `rows_delta`: its grid row less the distance travelled. Rows that left the
/// region land outside it.
pub fn shiftedRow(row: i32, rows_delta: i32) i32 {
    return row - rows_delta;
}

/// Whether a scrolled-off row at `row` is worth keeping: outside the region,
/// within retention depth of its edge. One inside the region is a live row
/// again and the committed set draws it.
pub fn keepsRetained(row: i32, region_start: u32, region_end: u32) bool {
    const s: i32 = @intCast(region_start);
    const e: i32 = @intCast(region_end);
    return (row < s and row >= s - retention_depth_rows) or
        (row >= e and row < e + retention_depth_rows);
}

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expect(@abs(actual - expected) <= tolerance);
}

test "an ease settles to rest and then stays there" {
    var e: Ease = .{};
    try std.testing.expect(e.seed(1, 4, 20, 0, 30, 8, .partial));
    try expectNear(e.offset_px, 80, 0);
    var now: i128 = 1;
    var frames: usize = 0;
    while (e.moving()) : (frames += 1) {
        now += std.time.ns_per_s / 60;
        e.tick(now);
        try std.testing.expect(frames < 60);
    }
    // About 200 ms at 60 Hz.
    try std.testing.expect(frames >= 8 and frames <= 20);
    try std.testing.expectEqual(@as(i128, 0), e.last_tick_ns);
    e.tick(now + std.time.ns_per_s);
    try std.testing.expect(!e.moving());
}

test "the first tick after a seed integrates nothing" {
    var e: Ease = .{};
    _ = e.seed(5 * std.time.ns_per_s, 1, 20, 0, 30, 3, .partial);
    e.tick(5 * std.time.ns_per_s);
    try expectNear(e.offset_px, 20, 0);
}

test "the spring does not depend on the frame rate" {
    var a: Ease = .{ .offset_px = 64, .velocity_px_s = -11, .last_tick_ns = 1 };
    var b = a;
    a.tick(1 + 10 * std.time.ns_per_ms);
    a.tick(1 + 20 * std.time.ns_per_ms);
    b.tick(1 + 20 * std.time.ns_per_ms);
    try expectNear(a.offset_px, b.offset_px, 1e-9);
    try expectNear(a.velocity_px_s, b.velocity_px_s, 1e-9);
}

test "arrivals add offset and keep velocity" {
    var e: Ease = .{ .offset_px = 4, .velocity_px_s = 17, .last_tick_ns = 1, .row_h_px = 20, .region_end = 30 };
    try std.testing.expect(e.seed(2, 2, 20, 0, 30, 8, .partial));
    try expectNear(e.offset_px, 44, 0);
    try expectNear(e.velocity_px_s, 17, 0);
}

test "an arrival that flips the sign drops the velocity" {
    var e: Ease = .{ .offset_px = -60, .velocity_px_s = 17, .last_tick_ns = 1, .row_h_px = 20, .region_end = 30 };
    try std.testing.expect(e.seed(2, 20, 20, 0, 30, 3, .partial));
    try expectNear(e.offset_px, 60, 0);
    try expectNear(e.velocity_px_s, 0, 0);
}

test "the offset is capped by mousescroll ver and by retention depth" {
    var e: Ease = .{};
    _ = e.seed(1, 9, 20, 0, 30, 3, .partial);
    try expectNear(e.offset_px, 60, 0);
    e.reset();
    _ = e.seed(1, -20, 20, 0, 30, 32, .partial);
    try expectNear(e.offset_px, -160, 0);
}

test "ver 0 animates nothing" {
    var e: Ease = .{};
    try std.testing.expect(!e.seed(1, 1, 20, 0, 30, 0, .partial));
    try std.testing.expect(!e.moving());
}

test "snap refuses a batch past one wheel event and keeps an ease in flight" {
    var e: Ease = .{ .offset_px = 20, .velocity_px_s = -30, .last_tick_ns = 1, .row_h_px = 20, .region_end = 30 };
    try std.testing.expect(!e.seed(2, 4, 20, 0, 30, 3, .snap));
    try expectNear(e.offset_px, 20, 0);
    try expectNear(e.velocity_px_s, -30, 0);
    try std.testing.expect(e.seed(2, -3, 20, 0, 30, 3, .snap));
}

test "a new row height or region voids the old offset" {
    var e: Ease = .{ .offset_px = 40, .velocity_px_s = 5, .last_tick_ns = 1, .row_h_px = 20, .region_end = 30 };
    _ = e.seed(2, 1, 22, 0, 30, 3, .partial);
    try expectNear(e.offset_px, 22, 0);
    try expectNear(e.velocity_px_s, 0, 0);
}

test "a steady stream of arrivals never jumps a row in one frame" {
    var e: Ease = .{};
    var now: i128 = 1;
    var previous: f64 = 0;
    for (0..180) |frame| {
        now += std.time.ns_per_s / 60;
        e.tick(now);
        if (frame % 6 == 0 and frame / 6 < 30) _ = e.seed(now, 1, 20, 0, 30, 8, .partial);
        if (frame > 12) try std.testing.expect(@abs(e.offset_px - previous) <= 20);
        previous = e.offset_px;
    }
}

test "retained rows outside the region within depth are kept" {
    // Region [2, 30): rows 1 and -6 sit above it, 30 and 37 below.
    try std.testing.expect(keepsRetained(1, 2, 30));
    try std.testing.expect(keepsRetained(-6, 2, 30));
    try std.testing.expect(!keepsRetained(-7, 2, 30));
    try std.testing.expect(!keepsRetained(2, 2, 30));
    try std.testing.expect(!keepsRetained(29, 2, 30));
    try std.testing.expect(keepsRetained(30, 2, 30));
    try std.testing.expect(keepsRetained(37, 2, 30));
    try std.testing.expect(!keepsRetained(38, 2, 30));
    // Scrolling up by 3 sends rows 2..4 to -1..1, all above the region.
    try std.testing.expectEqual(@as(i32, -1), shiftedRow(2, 3));
    try std.testing.expectEqual(@as(i32, 30), shiftedRow(27, -3));
}
