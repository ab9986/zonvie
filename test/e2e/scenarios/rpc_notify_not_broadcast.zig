// rpc_notify_not_broadcast — the reporters zonvie injects into Neovim must
// address zonvie's own RPC channel, not channel 0.
//
// Channel 0 means "every RPC channel" (rpc_send_event -> broadcast_event in
// Neovim's msgpack_rpc/channel.c), so with coc.nvim attached each report also
// lands in coc's node process, which has no handler for it and logs
//   Error on notification "zonvie_agent_status": Action "zonvie_agent_status"
//   does not exist
// (GitHub issue #39).
//
// A bystander plays coc: a plain socket client that the test connects to a
// server Neovim starts, and that records every byte Neovim sends it. After the
// reporters have fired (the frontend saw the agent state and the
// 'mousescroll' value), a deliberate channel-0 probe is sent. The probe MUST
// reach the bystander -- that proves broadcasts do reach it and the reads
// work -- and because notifications on one channel arrive in order, once the
// probe is in the recording everything broadcast before it is too. The
// reporter method names must then be absent.

const std = @import("std");
const builtin = @import("builtin");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;
const AgentEvent = @import("../harness.zig").AgentEvent;

const AGENT_METHOD = "zonvie_agent_status";
const SCROLL_METHOD = "zonvie_mousescroll";
const PROBE_METHOD = "zonvie_e2e_bystander_probe";

fn isWorking(e: AgentEvent) bool {
    return e.state == 3;
}

/// Everything Neovim has written to the bystander's socket so far.
const Bystander = struct {
    stream: std.Io.net.Stream,
    mu: std.Io.Mutex = .init,
    got: std.ArrayListUnmanaged(u8) = .empty,
    alloc: std.mem.Allocator,

    fn pump(b: *Bystander) void {
        const io = zc.clock.io();
        var chunk: [4096]u8 = undefined;
        while (true) {
            var vec = [_][]u8{chunk[0..]};
            const n = io.vtable.netRead(io.userdata, b.stream.socket.handle, &vec) catch return;
            if (n == 0) return;
            b.mu.lockUncancelable(io);
            defer b.mu.unlock(io);
            b.got.appendSlice(b.alloc, chunk[0..n]) catch return;
        }
    }

    fn contains(b: *Bystander, needle: []const u8) bool {
        b.mu.lockUncancelable(zc.clock.io());
        defer b.mu.unlock(zc.clock.io());
        return std.mem.indexOf(u8, b.got.items, needle) != null;
    }
};

pub fn run(alloc: std.mem.Allocator) !void {
    // Unix-domain sockets only; the Windows e2e build has no bystander.
    if (comptime builtin.os.tag == .windows) return;

    try testNoBroadcast(alloc);
    try testDeadChannelSilent(alloc);
}

/// A server zonvie attached to with --connect-nvim outlives the GUI, and so do
/// the reporters' autocmds and vim.g.zonvie_channel. Sending to that closed
/// channel raises "Invalid channel: N", which would surface as an error on
/// every terminal title change or 'mousescroll' change. The reporters must
/// stay silent instead. An id that was never allocated takes the same path in
/// Neovim (find_rpc_channel returns NULL for missing and closed channels).
fn testDeadChannelSilent(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const io = zc.clock.io();

    try std.Io.Dir.cwd().createDirPath(io, "tmp");
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    var out_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const out_path = try std.fmt.bufPrint(&out_buf, "{s}/tmp/e2e-dead-chan-{d}.txt", .{
        std.mem.sliceTo(cwd_ptr, 0),
        std.Thread.getCurrentId(),
    });
    std.Io.Dir.cwd().deleteFile(io, out_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, out_path) catch {};

    // The 'mousescroll' error propagates through pcall(vim.cmd). The
    // agent-status report fires from a TermRequest autocmd while vim.wait
    // runs the loop; when that report raises, this chunk never reaches
    // writefile, so a missing result file is the failure for that reporter.
    var lua_buf: [1024]u8 = undefined;
    try h.core.requestExecLua(try std.fmt.bufPrint(&lua_buf,
        \\local real = vim.g.zonvie_channel
        \\vim.g.zonvie_channel = 999999
        \\vim.v.errmsg = ''
        \\local out = {{}}
        \\local ok, err = pcall(vim.cmd, 'set mousescroll=ver:7,hor:6')
        \\out[#out+1] = 'mousescroll ' .. tostring(ok) .. ' ' .. tostring(err)
        \\vim.cmd('enew')
        \\vim.fn.termopen("printf '\\033]0;⠋ working\\007'; sleep 2")
        \\vim.wait(1500, function()
        \\  local t = vim.b.term_title or ''
        \\  return vim.v.errmsg ~= '' or t:find('working') ~= nil
        \\end)
        \\vim.wait(200, function() return vim.v.errmsg ~= '' end)
        \\out[#out+1] = 'errmsg ' .. vim.v.errmsg
        \\out[#out+1] = 'title ' .. (vim.b.term_title or '')
        \\vim.g.zonvie_channel = real
        \\vim.fn.writefile(out, '{s}')
    , .{out_path}));

    const t0 = zc.clock.nowNs();
    while (true) {
        if (std.Io.Dir.cwd().access(io, out_path, .{})) |_| break else |_| {}
        if (h.exited.load(.seq_cst)) return error.NvimExited;
        if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms > h.opts.timeout_ms) {
            std.debug.print("[e2e] rpc_notify_not_broadcast: the dead-channel probe never wrote its result (a reporter raised inside vim.wait, or the chunk died earlier)\n", .{});
            return error.DeadChannelProbeNoResult;
        }
        std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    }
    const out = try std.Io.Dir.cwd().readFileAlloc(io, out_path, alloc, .limited(4096));
    defer alloc.free(out);

    // The terminal title must have changed, or the agent reporter never ran
    // and an empty errmsg would prove nothing.
    if (std.mem.indexOf(u8, out, "title ⠋ working") == null) {
        std.debug.print("[e2e] rpc_notify_not_broadcast: terminal title never changed:\n{s}\n", .{out});
        return error.AgentReporterDidNotRun;
    }
    // The report must have gone to the dead id, not to us. A reporter that
    // cached the live channel at install time would never raise and would
    // pass the checks below vacuously; the harness having received the
    // "working" state is what gives that away.
    if (h.hasAgentStatus(isWorking)) {
        std.debug.print("[e2e] rpc_notify_not_broadcast: the agent report reached the harness; the reporter is not reading vim.g.zonvie_channel at send time\n", .{});
        return error.ReporterIgnoredChannelVariable;
    }
    // pcall(vim.cmd) yields true and vim.cmd's empty-string result.
    if (std.mem.indexOf(u8, out, "mousescroll true \n") == null or
        std.mem.indexOf(u8, out, "errmsg \n") == null)
    {
        std.debug.print("[e2e] rpc_notify_not_broadcast: a reporter raised on a dead channel:\n{s}\n", .{out});
        return error.ReporterRaisedOnDeadChannel;
    }
    std.debug.print("[e2e] rpc_notify_not_broadcast: reporters stay silent on a dead channel\n", .{});
}

fn testNoBroadcast(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const io = zc.clock.io();

    // Absolute path: the spawned nvim's cwd is not the test's.
    var cwd_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_ptr = std.c.getcwd(&cwd_buf, cwd_buf.len) orelse return error.NoCwd;
    const cwd = std.mem.sliceTo(cwd_ptr, 0);
    try std.Io.Dir.cwd().createDirPath(io, "tmp");
    var path_buf: [std.Io.net.UnixAddress.max_len]u8 = undefined;
    const sock_path = try std.fmt.bufPrint(&path_buf, "{s}/tmp/e2e-bystander-{d}.sock", .{
        cwd,
        std.Thread.getCurrentId(),
    });
    std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, sock_path) catch {};

    // serverstart runs asynchronously to us. Connecting before it listens
    // is refused (and Debug Io dumps a trace for the refusal), so nvim drops
    // a marker file once the server is up and we connect only after that.
    var ready_buf: [std.Io.net.UnixAddress.max_len + 8]u8 = undefined;
    const ready_path = try std.fmt.bufPrint(&ready_buf, "{s}.ready", .{sock_path});
    std.Io.Dir.cwd().deleteFile(io, ready_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, ready_path) catch {};
    var lua_buf: [512]u8 = undefined;
    try h.core.requestExecLua(try std.fmt.bufPrint(
        &lua_buf,
        "vim.fn.serverstart('{s}'); vim.fn.writefile({{}}, '{s}')",
        .{ sock_path, ready_path },
    ));
    const t0 = zc.clock.nowNs();
    while (true) {
        if (std.Io.Dir.cwd().access(io, ready_path, .{})) |_| break else |_| {}
        if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms > h.opts.timeout_ms) return error.BystanderServerTimeout;
        std.Io.sleep(io, .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    }
    const addr = try std.Io.net.UnixAddress.init(sock_path);
    const stream = try addr.connect(io);
    var by = Bystander{ .stream = stream, .alloc = alloc };
    defer by.got.deinit(alloc);
    const pump = std.Thread.spawn(.{}, Bystander.pump, .{&by}) catch |e| {
        stream.close(io);
        return e;
    };
    defer {
        stream.shutdown(io, .both) catch {};
        pump.join();
        stream.close(io);
    }

    // Fire the agent reporter once the bystander's channel is accepted, so a
    // report cannot predate the channel it would have been broadcast to.
    // assert: a timed-out wait must stop the chunk before termopen. The
    // harness ignores exec_lua errors, so the failure shows up as the
    // waitAgentStatus timeout below rather than as a vacuous pass.
    try h.core.requestExecLua(
        \\assert(vim.wait(3000, function()
        \\  for _, c in ipairs(vim.api.nvim_list_chans()) do
        \\    if c.stream == 'socket' then return true end
        \\  end
        \\  return false
        \\end), 'bystander channel was never accepted')
        \\vim.cmd('enew')
        \\vim.fn.termopen("printf '\\033]0;⠋ working\\007'; sleep 1")
    );
    try h.waitAgentStatus(isWorking, 3000);

    try h.command("set mousescroll=ver:5,hor:6");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return hh.mousescrollVer() == 5;
        }
    }.check, h.opts.timeout_ms);

    try h.core.requestExecLua("vim.rpcnotify(0, '" ++ PROBE_METHOD ++ "')");
    try h.waitUntil(&by, struct {
        fn check(b: *Bystander, _: *Harness) bool {
            return b.contains(PROBE_METHOD);
        }
    }.check, h.opts.timeout_ms);

    var failed = false;
    for ([_][]const u8{ AGENT_METHOD, SCROLL_METHOD }) |method| {
        if (by.contains(method)) {
            std.debug.print("[e2e] rpc_notify_not_broadcast: '{s}' reached a bystander RPC channel (sent to channel 0)\n", .{method});
            failed = true;
        }
    }
    if (failed) return error.ReporterBroadcast;
    std.debug.print("[e2e] rpc_notify_not_broadcast: reporters stay on zonvie's channel\n", .{});
}
