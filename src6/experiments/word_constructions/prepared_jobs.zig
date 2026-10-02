//! C ABI for the unchanged native-v4 immutable payload Jobs.
//! A caller retains the frame bytes for the lifetime of the prepared handle.
const std = @import("std");
const bz4 = @import("bz4");
const decoder_budget = @import("decoder_budget.zig");
const allocator = std.heap.page_allocator;
const max_frame = 64 * 1024 * 1024;
const max_raw = 64 * 1024 * 1024;

// Scan the untrusted v4 envelope before its legacy decoder allocates a
// claimed delta-output buffer. These are WPG2 reader limits, not changes to
// the repository's v4 codec. The enclosing WPG2 reader separately validates
// original page geometry and source CRCs.
fn takeNumber(bytes: []const u8, pos: *usize) !u32 {
    var result: u64 = 0;
    for (0..5) |i| {
        if (pos.* >= bytes.len) return error.ShortVarint;
        const c = bytes[pos.*];
        pos.* += 1;
        result |= @as(u64, c & 127) << @intCast(i * 7);
        if (result > std.math.maxInt(u32)) return error.OverlongVarint;
        if (c < 128) return @intCast(result);
    }
    return error.OverlongVarint;
}

fn preflight(bytes: []const u8) !void {
    if (bytes.len < 6 or bytes.len > max_frame or !std.mem.startsWith(u8, bytes, "bz4\x03"))
        return error.FrameBound;
    var pos: usize = 4;
    const header_len = try takeNumber(bytes, &pos);
    if (header_len > 8 * 1024 * 1024 or header_len > bytes.len - pos) return error.HeaderBound;
    pos += header_len;
    var total_delta: usize = 0;
    var total_defs: usize = 0;
    var total_raw: usize = 0;
    var blocks: usize = 0;
    while (pos < bytes.len) {
        const kind = bytes[pos];
        pos += 1;
        if (kind == 0) {
            if (pos != bytes.len) return error.FrameTail;
            return;
        }
        if (kind > 3 or blocks >= 8192) return error.BlockBound;
        blocks += 1;
        var delta_len: usize = 0;
        var payload_len: usize = 0;
        if (kind & 1 != 0) {
            const defs = try takeNumber(bytes, &pos);
            const delta_bytes = try takeNumber(bytes, &pos);
            delta_len = try takeNumber(bytes, &pos);
            if (defs == 0 or defs > 1_000_000 - total_defs or
                delta_bytes > 16 * 1024 * 1024 or delta_bytes > max_raw - total_delta)
                return error.DeltaBound;
            total_defs += defs;
            total_delta += delta_bytes;
        }
        if (kind & 2 != 0) {
            const raw_len = try takeNumber(bytes, &pos);
            const items = try takeNumber(bytes, &pos);
            payload_len = try takeNumber(bytes, &pos);
            // Frames emitted by our encoder contain only nonempty payload
            // tokens, so token count cannot exceed decoded byte count. This
            // also bounds selected-page work by the admitted output length.
            if (raw_len == 0 or raw_len > 65536 or items == 0 or items > raw_len or
                raw_len > max_raw - total_raw)
                return error.PayloadBound;
            total_raw += raw_len;
        }
        if (delta_len > bytes.len - pos or payload_len > bytes.len - pos - delta_len)
            return error.BlockSpan;
        pos += delta_len + payload_len;
    }
    return error.MissingTerminator;
}

const Prepared = struct {
    // Stable storage: Decoder's ArenaAllocator retains a pointer to this
    // budget until wpg_close, and Jobs retain slices of that arena.
    budget: decoder_budget.Budget,
    decoder: bz4.Decoder,
    jobs: std.ArrayList(bz4.Job) = .empty,
    starts: std.ArrayList(usize) = .empty,
    total: usize = 0,

    fn deinit(self: *Prepared) void {
        const a = self.budget.allocator();
        self.starts.deinit(a);
        self.jobs.deinit(a);
        self.decoder.deinit();
        std.debug.assert(self.budget.live == 0);
        allocator.destroy(self);
    }
};

fn prepare(bytes: []const u8) !*Prepared {
    try preflight(bytes);
    const p = try allocator.create(Prepared);
    errdefer allocator.destroy(p);
    p.budget = .{ .parent = allocator };
    p.jobs = .empty;
    p.starts = .empty;
    p.total = 0;
    p.decoder = bz4.Decoder.init(p.budget.allocator(), bytes) catch |err| {
        std.debug.assert(p.budget.live == 0);
        return err;
    };
    errdefer {
        const a = p.budget.allocator();
        p.starts.deinit(a);
        p.jobs.deinit(a);
        p.decoder.deinit();
        std.debug.assert(p.budget.live == 0);
    }
    while (try p.decoder.next()) |job| {
        if (job.items == 0) continue;
        if (job.raw_len == 0 or job.raw_len > 65536 or p.total > 64 * 1024 * 1024 - job.raw_len) return error.FrameLimit;
        try p.starts.append(p.budget.allocator(), p.total);
        try p.jobs.append(p.budget.allocator(), job);
        p.total += job.raw_len;
    }
    if (p.decoder.pos != bytes.len) return error.FrameTail;
    return p;
}

export fn wpg_prepare(frame: [*]const u8, frame_len: usize, out_handle: *?*anyopaque) c_int {
    out_handle.* = null;
    if (frame_len == 0 or frame_len > max_frame) return 1;
    const p = prepare(frame[0..frame_len]) catch return 2;
    out_handle.* = @ptrCast(p);
    return 0;
}

export fn wpg_close(handle: ?*anyopaque) void {
    const ptr = handle orelse return;
    const p: *Prepared = @ptrCast(@alignCast(ptr));
    p.deinit();
}

export fn wpg_stats(handle: ?*anyopaque, out_total: *usize, out_jobs: *usize,
                    out_model_reserved: *usize, out_job_directory: *usize) c_int {
    const ptr = handle orelse return 1;
    const p: *Prepared = @ptrCast(@alignCast(ptr));
    out_total.* = p.total;
    out_jobs.* = p.jobs.items.len;
    out_model_reserved.* = p.decoder.arena.queryCapacity();
    out_job_directory.* = p.jobs.capacity * @sizeOf(bz4.Job) + p.starts.capacity * @sizeOf(usize);
    return 0;
}

export fn wpg_budget_stats(handle: ?*anyopaque, out_live: *usize,
                           out_peak: *usize, out_limit: *usize) c_int {
    const ptr = handle orelse return 1;
    const p: *Prepared = @ptrCast(@alignCast(ptr));
    out_live.* = p.budget.live;
    out_peak.* = p.budget.peak;
    out_limit.* = p.budget.limit;
    return 0;
}

export fn wpg_read(handle: ?*anyopaque, start: usize, length: usize,
                   output: [*]u8, output_capacity: usize, out_jobs: *usize) c_int {
    const ptr = handle orelse return 1;
    const p: *Prepared = @ptrCast(@alignCast(ptr));
    out_jobs.* = 0;
    if (length > output_capacity or start > p.total or length > p.total - start) return 2;
    if (length == 0) return 0;
    var lo: usize = 0;
    var hi = p.starts.items.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (p.starts.items[mid] <= start) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return 3;
    var idx = lo - 1;
    var copied: usize = 0;
    var scratch: [65536]u8 = undefined;
    while (copied < length) : (idx += 1) {
        if (idx >= p.jobs.items.len) return 3;
        const job = p.jobs.items[idx];
        const block = scratch[0..job.raw_len];
        p.decoder.run(job, block) catch return 4;
        const local = start + copied - p.starts.items[idx];
        if (local >= block.len) return 3;
        const amount = @min(length - copied, block.len - local);
        @memcpy(output[copied..][0..amount], block[local..][0..amount]);
        copied += amount;
        out_jobs.* += 1;
    }
    return 0;
}
