const std = @import("std");
const wire = @import("wire.zig");
const c = @cImport({
    @cInclude("libbz3.h");
});
pub const magic = "PRSE";
pub const payload_magic = "PITM";
pub const version: u16 = 3;
pub const payload_version: u16 = 2;
pub const header_size: usize = 32;
pub const directory_record_size: usize = RecordLayout.size;
pub const payload_header_size: usize = 24;
pub const item_record_size: usize = 8;
pub const min_bzip3_state: usize = 65 * 1024;
pub const max_bzip3_state: usize = 511 * 1024 * 1024;
pub const Preset = enum { latency, balanced, compact };
pub const CodecMode = enum { auto, raw, bzip3 };
pub const Codec = enum(u8) { raw = 0, bzip3 = 1 };
const Record = struct {
    root_first: u32,
    root_last: u32,
    node_first: u32,
    node_last: u32,
    original_size: u32,
    stored_size: u32,
    stored_offset: u64,
    item_count: u32,
    root_count: u32,
    root_index: u32,
    codec: Codec,
    reserved: [3]u8 = @splat(0),
};
const RecordLayout = wire.Layout(Record);
pub const Error = error{ InvalidOptions, InvalidInput, UnsupportedVersion, Truncated, Malformed, LimitExceeded, IndexOutOfBounds, OutOfMemory, AllocationFailed, CodecFailure, Corrupt };
pub const Options = struct {
    preset: Preset = .balanced,
    codec: CodecMode = .auto,
    max_blocks: usize = 1_000_000,
    max_items_per_block: usize = 1_000_000,
    max_uncompressed_block: usize = 4 * 1024 * 1024,
    max_compressed_block: usize = 8 * 1024 * 1024,
    max_decode_bytes: usize = 8 * 1024 * 1024,
    max_codec_memory: usize = 64 * 1024 * 1024,
    pub fn targetBytes(self: Options) usize {
        return if (self.preset == .latency) 64 * 1024 else if (self.preset == .balanced) 256 * 1024 else 4 * 1024 * 1024;
    }
    pub fn stateBytes(self: Options) usize {
        return if (self.preset == .latency) min_bzip3_state else if (self.preset == .balanced) 256 * 1024 else 4 * 1024 * 1024;
    }
    fn validate(self: Options) Error!void {
        if (self.max_blocks == 0 or self.max_items_per_block == 0 or self.max_uncompressed_block < payload_header_size or
            self.max_compressed_block == 0 or self.max_decode_bytes < payload_header_size or self.max_codec_memory == 0 or
            self.stateBytes() < min_bzip3_state or self.stateBytes() > max_bzip3_state or self.max_uncompressed_block > max_bzip3_state or
            self.max_items_per_block > @as(usize, std.math.maxInt(u32)) / item_record_size or self.max_blocks > std.math.maxInt(u32))
            return Error.InvalidOptions;
    }
};
pub const ItemInput = struct { node: u64, text: []const u8 };
pub const RootInput = struct { root: u64, items: []const ItemInput };
pub const Item = struct { node: u64, text: []const u8 };
pub const BlockMeta = struct {
    root_first: u64,
    root_last: u64,
    node_first: u64,
    node_last: u64,
    root_index: usize,
    root_count: usize,
    item_count: usize,
    codec: Codec,
    original_size: usize,
    stored_offset: usize,
    stored_size: usize,
};
pub const OwnedStore = struct {
    bytes: []u8,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *OwnedStore) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};
pub const Store = struct {
    bytes: []const u8,
    directory_offset: usize,
    root_table_offset: usize,
    root_table_count: usize,
    block_count: usize,
    limits: Options,
    pub fn open(bytes: []const u8, limits: Options) Error!Store {
        try limits.validate();
        if (bytes.len < header_size) return Error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return Error.Malformed;
        if (read(u16, bytes, 4) != version) return Error.UnsupportedVersion;
        if (read(u16, bytes, 6) != header_size) return Error.Malformed;
        const count = @as(usize, read(u32, bytes, 8));
        const directory = try toUsize(read(u64, bytes, 12));
        const directory_len = try toUsize(read(u64, bytes, 20));
        if (read(u32, bytes, 28) != 0) return Error.Malformed;
        const records_len = try mul(count, directory_record_size);
        if (count > limits.max_blocks or directory != header_size or directory_len < records_len or (directory_len - records_len) % @sizeOf(u32) != 0) return Error.Malformed;
        const directory_end = try add(directory, directory_len);
        if (directory_end > bytes.len) return Error.Truncated;
        const root_table_offset = try add(directory, records_len);
        const root_table_count = (directory_len - records_len) / @sizeOf(u32);
        var previous_end = directory_end;
        var previous_root: ?u64 = null;
        var previous_node: ?u64 = null;
        var expected_root_index: usize = 0;
        for (0..count) |index| {
            const meta = try parseMeta(bytes, try add(directory, try mul(index, directory_record_size)), limits);
            const stored_end = try add(meta.stored_offset, meta.stored_size);
            if (meta.stored_offset != previous_end) return Error.Malformed;
            if (stored_end > bytes.len) return Error.Truncated;
            if (meta.root_index != expected_root_index or meta.root_index > root_table_count or meta.root_count > root_table_count - meta.root_index) return Error.Malformed;
            expected_root_index = try add(expected_root_index, meta.root_count);
            var prior_root: ?u64 = null;
            for (0..meta.root_count) |root_index| {
                const value = read(u32, bytes, root_table_offset + (meta.root_index + root_index) * 4);
                if (prior_root) |prior| if (value <= prior) return Error.Malformed;
                prior_root = value;
                if (root_index == 0 and value != meta.root_first or root_index + 1 == meta.root_count and value != meta.root_last) return Error.Malformed;
            }
            // Equal ids are continuation fragments of one oversized root.
            if (previous_root) |last| if (meta.root_first < last) return Error.Malformed;
            if (previous_node) |last| if (meta.node_first <= last) return Error.Malformed;
            previous_root = meta.root_last;
            previous_node = meta.node_last;
            previous_end = stored_end;
        }
        if (expected_root_index != root_table_count or previous_end != bytes.len) return Error.Malformed;
        return .{ .bytes = bytes, .directory_offset = directory, .root_table_offset = root_table_offset, .root_table_count = root_table_count, .block_count = count, .limits = limits };
    }
    pub fn block(self: *const Store, index: usize) Error!BlockMeta {
        if (index >= self.block_count) return Error.IndexOutOfBounds;
        return parseMeta(self.bytes, try add(self.directory_offset, try mul(index, directory_record_size)), self.limits);
    }
    pub fn blockForRoot(self: *const Store, root: u64) ?usize {
        var low: usize = 0;
        var high = self.block_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const meta = self.block(middle) catch return null;
            // Search by the inclusive upper bound so duplicate root ranges
            // (continuation blocks for one oversized entry) resolve to their
            // first block deterministically.
            if (meta.root_last < root) low = middle + 1 else high = middle;
        }
        if (low == self.block_count) return null;
        const candidate = self.block(low) catch return null;
        if (candidate.root_first > root or candidate.root_last < root) return null;
        var first = candidate.root_index;
        var last = candidate.root_index + candidate.root_count;
        while (first < last) {
            const middle = first + (last - first) / 2;
            const value = read(u32, self.bytes, self.root_table_offset + middle * 4);
            if (value < root) first = middle + 1 else last = middle;
        }
        return if (first < candidate.root_index + candidate.root_count and read(u32, self.bytes, self.root_table_offset + first * 4) == root) low else null;
    }
    /// Node bounds are deliberately outside compressed payloads: planning a
    /// batch never decodes prose merely to discover its block count.
    pub fn blockForNode(self: *const Store, node: u64) ?usize {
        var low: usize = 0;
        var high = self.block_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const meta = self.block(middle) catch return null;
            if (meta.node_last < node) low = middle + 1 else high = middle;
        }
        if (low == self.block_count) return null;
        const candidate = self.block(low) catch return null;
        return if (candidate.node_first <= node and node <= candidate.node_last) low else null;
    }
    pub fn pin(self: *const Store, allocator: std.mem.Allocator, index: usize) Error!Pin {
        var decoder = Decoder{};
        defer decoder.deinit();
        return self.pinUsing(allocator, index, &decoder);
    }

    pub fn pinUsing(self: *const Store, allocator: std.mem.Allocator, index: usize, decoder: *Decoder) Error!Pin {
        const meta = try self.block(index);
        const stored_end = try add(meta.stored_offset, meta.stored_size);
        if (stored_end > self.bytes.len) return Error.Truncated;
        const stored = self.bytes[meta.stored_offset..stored_end];
        if (meta.original_size > self.limits.max_decode_bytes or meta.stored_size > self.limits.max_compressed_block) return Error.LimitExceeded;
        const size = if (meta.codec == .raw) meta.original_size else @max(try bzipBound(meta.original_size), meta.stored_size);
        if (size > self.limits.max_decode_bytes) return Error.LimitExceeded;
        const allocation: ?[]u8 = if (meta.codec == .raw) null else allocator.alloc(u8, size) catch return Error.OutOfMemory;
        errdefer if (allocation) |buffer| allocator.free(buffer);
        switch (meta.codec) {
            .raw => {
                if (stored.len != meta.original_size) return Error.Malformed;
            },
            .bzip3 => try decoder.decode(allocation.?, stored, meta.original_size, self.limits),
        }
        const payload = if (allocation) |buffer| buffer[0..meta.original_size] else stored;
        try validatePayload(payload, meta.item_count, self.limits);
        // Routing metadata is a promise about the decoded block, not merely
        // a hint: accepting disagreement could hide or misroute valid items.
        if (read(u32, payload, payload_header_size) != meta.node_first or
            read(u32, payload, payload_header_size + (meta.item_count - 1) * item_record_size) != meta.node_last)
            return error.Malformed;
        return .{ .allocator = allocator, .allocation = allocation, .payload = payload, .meta = meta };
    }
};
pub const Pin = struct {
    allocator: std.mem.Allocator,
    allocation: ?[]u8,
    payload: []const u8,
    meta: BlockMeta,
    pub fn deinit(self: *Pin) void {
        if (self.allocation) |buffer| self.allocator.free(buffer);
        self.* = undefined;
    }
    pub fn item(self: *const Pin, index: usize) Error!Item {
        if (index >= self.meta.item_count) return Error.IndexOutOfBounds;
        const at = payload_header_size + index * item_record_size;
        const data_start = payload_header_size + self.meta.item_count * item_record_size;
        const start = try add(data_start, if (index == 0) 0 else read(u32, self.payload, at - 4));
        const end = try add(data_start, read(u32, self.payload, at + 4));
        if (end > self.payload.len) return Error.Malformed;
        return .{ .node = read(u32, self.payload, at), .text = self.payload[start..end] };
    }
    pub fn itemForNode(self: *const Pin, node: u64) Error!?Item {
        var low: usize = 0;
        var high = self.meta.item_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const candidate = try self.item(middle);
            if (candidate.node < node) low = middle + 1 else if (candidate.node > node) high = middle else return candidate;
        }
        return null;
    }
};
/// A plan is a contiguous slice of the logical input. `first_item` is only
/// non-zero when a very large root is deliberately continued in another block.
const Plan = struct {
    first_root: usize,
    root_count: usize,
    first_item: usize,
    item_count: usize,
    payload_size: usize,
    root_first: u64,
    root_last: u64,
    node_first: u64,
    node_last: u64,
};
const Encoded = struct { codec: Codec, bytes: []const u8 };
const EncodedBlock = struct { meta: BlockMeta, stored: Encoded };
pub fn build(allocator: std.mem.Allocator, roots: []const RootInput, options: Options) Error!OwnedStore {
    try options.validate();
    const count = try planBlocks(roots, options, null);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const plans = scratch.alloc(Plan, count) catch return Error.OutOfMemory;
    _ = try planBlocks(roots, options, plans);
    const blocks = scratch.alloc(EncodedBlock, count) catch return Error.OutOfMemory;
    for (plans, 0..) |plan, index| {
        const payload = try makePayload(scratch, roots, plan);
        const stored = try encodePayload(scratch, payload, options);
        blocks[index] = .{ .meta = .{ .root_first = plan.root_first, .root_last = plan.root_last, .node_first = plan.node_first, .node_last = plan.node_last, .root_index = 0, .root_count = plan.root_count, .item_count = plan.item_count, .codec = stored.codec, .original_size = payload.len, .stored_offset = 0, .stored_size = stored.bytes.len }, .stored = stored };
    }
    var root_table_count: usize = 0;
    for (plans) |plan| root_table_count = try add(root_table_count, plan.root_count);
    const records_len = try mul(count, directory_record_size);
    const directory_len = try add(records_len, try mul(root_table_count, @sizeOf(u32)));
    const payload_start = try add(header_size, directory_len);
    var total = payload_start;
    for (blocks) |block| total = try add(total, block.stored.bytes.len);
    const bytes = allocator.alloc(u8, total) catch return Error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    write(u16, bytes, 4, version);
    write(u16, bytes, 6, header_size);
    write(u32, bytes, 8, @intCast(count));
    write(u64, bytes, 12, header_size);
    write(u64, bytes, 20, directory_len);
    var root_cursor: usize = 0;
    for (plans) |plan| {
        for (roots[plan.first_root .. plan.first_root + plan.root_count]) |root| {
            write(u32, bytes, header_size + records_len + root_cursor * 4, @intCast(root.root));
            root_cursor += 1;
        }
    }
    var at = payload_start;
    var root_index: usize = 0;
    for (blocks, 0..) |block, index| {
        const dir = header_size + index * directory_record_size;
        RecordLayout.write(bytes, dir, .{
            .root_first = @intCast(block.meta.root_first),
            .root_last = @intCast(block.meta.root_last),
            .node_first = @intCast(block.meta.node_first),
            .node_last = @intCast(block.meta.node_last),
            .original_size = @intCast(block.meta.original_size),
            .stored_size = @intCast(block.stored.bytes.len),
            .stored_offset = at,
            .item_count = @intCast(block.meta.item_count),
            .root_count = @intCast(block.meta.root_count),
            .root_index = @intCast(root_index),
            .codec = block.meta.codec,
        }) catch return error.Malformed;
        root_index += block.meta.root_count;
        @memcpy(bytes[at .. at + block.stored.bytes.len], block.stored.bytes);
        at += block.stored.bytes.len;
    }
    return .{ .bytes = bytes, .allocator = allocator };
}
fn planBlocks(roots: []const RootInput, options: Options, output: ?[]Plan) Error!usize {
    var count: usize = 0;
    var previous_root: ?u64 = null;
    var previous_node: ?u64 = null;
    var current: ?Plan = null;
    for (roots, 0..) |root, root_index| {
        if (root.root > std.math.maxInt(u32)) return error.LimitExceeded;
        if (previous_root) |previous| if (root.root <= previous) return Error.InvalidInput;
        previous_root = root.root;
        for (root.items) |item| {
            if (item.text.len > std.math.maxInt(u32) or item.node > std.math.maxInt(u32) or item.node < root.root) return Error.LimitExceeded;
            if (previous_node) |node| if (item.node <= node) return Error.InvalidInput;
            previous_node = item.node;
        }
        // Empty roots need no prose-directory entry. Forest navigation still
        // represents them, while prose lookup correctly returns no block.
        if (root.items.len == 0) {
            if (current) |plan| try emitPlan(output, &count, plan);
            current = null;
            continue;
        }

        var item_at: usize = 0;
        while (item_at < root.items.len) {
            var chunk_items: usize = 0;
            var chunk_size: usize = payload_header_size;
            while (item_at + chunk_items < root.items.len and chunk_items < options.max_items_per_block) {
                const text_len = root.items[item_at + chunk_items].text.len;
                const next = try add(chunk_size, try add(item_record_size, text_len));
                if (next > options.max_uncompressed_block or next > options.max_decode_bytes or
                    (options.codec == .raw and next > options.max_compressed_block) or
                    (options.codec != .raw and next > options.stateBytes())) break;
                if (chunk_items != 0 and next > options.targetBytes()) break;
                chunk_size = next;
                chunk_items += 1;
            }
            if (chunk_items == 0) return Error.LimitExceeded;
            const is_whole_root = item_at == 0 and chunk_items == root.items.len;
            if (!is_whole_root or current == null) {
                if (current != null) {
                    if (output) |out| out[count] = current.?;
                    count += 1;
                    current = null;
                }
            }
            if (is_whole_root) {
                const hard_limit = @min(options.max_uncompressed_block, @min(options.max_decode_bytes, if (options.codec == .raw) options.max_compressed_block else options.stateBytes()));
                const joins = if (current) |plan| plan.root_count < std.math.maxInt(u32) and plan.item_count <= options.max_items_per_block -| chunk_items and try add(plan.payload_size, chunk_size - payload_header_size) <= @min(options.targetBytes(), hard_limit) else false;
                if (!joins) {
                    if (current != null) {
                        if (output) |out| out[count] = current.?;
                        count += 1;
                    }
                    current = planFor(root, root_index, 0, chunk_items, chunk_size);
                } else {
                    current.?.root_count += 1;
                    current.?.item_count = try add(current.?.item_count, chunk_items);
                    current.?.payload_size = try add(current.?.payload_size, chunk_size - payload_header_size);
                    current.?.root_last = root.root;
                    current.?.node_last = root.items[root.items.len - 1].node;
                }
            } else {
                try emitPlan(output, &count, planFor(root, root_index, item_at, chunk_items, chunk_size));
            }
            item_at += chunk_items;
        }
    }
    if (current) |plan| {
        if (output) |out| out[count] = plan;
        count += 1;
    }
    if (count > options.max_blocks) return Error.LimitExceeded;
    if (output) |out| if (out.len != count) return Error.Malformed;
    return count;
}
fn planFor(root: RootInput, root_index: usize, first_item: usize, item_count: usize, payload_size: usize) Plan {
    return .{
        .first_root = root_index,
        .root_count = 1,
        .first_item = first_item,
        .item_count = item_count,
        .payload_size = payload_size,
        .root_first = root.root,
        .root_last = root.root,
        .node_first = root.items[first_item].node,
        .node_last = root.items[first_item + item_count - 1].node,
    };
}
fn emitPlan(output: ?[]Plan, count: *usize, plan: Plan) Error!void {
    if (output) |out| {
        if (count.* >= out.len) return Error.Malformed;
        out[count.*] = plan;
    }
    count.* += 1;
}
fn makePayload(allocator: std.mem.Allocator, all_roots: []const RootInput, plan: Plan) Error![]u8 {
    var items: usize = 0;
    var data: usize = 0;
    const roots = all_roots[plan.first_root .. plan.first_root + plan.root_count];
    for (roots, 0..) |root, ri| {
        const start = if (ri == 0) plan.first_item else 0;
        const take = if (ri + 1 == roots.len) plan.item_count - items else root.items.len - start;
        items = try add(items, take);
        for (root.items[start .. start + take]) |item| data = try add(data, item.text.len);
    }
    const directory = try mul(items, item_record_size);
    const data_start = try add(payload_header_size, directory);
    const payload = allocator.alloc(u8, try add(data_start, data)) catch return Error.OutOfMemory;
    @memset(payload, 0);
    @memcpy(payload[0..4], payload_magic);
    write(u16, payload, 4, payload_version);
    write(u32, payload, 8, @intCast(items));
    write(u32, payload, 12, @intCast(directory));
    write(u64, payload, 16, data);
    var record = payload_header_size;
    var at = data_start;
    for (roots, 0..) |root, ri| {
        const start = if (ri == 0) plan.first_item else 0;
        const take = if (ri + 1 == roots.len) plan.item_count - (record - payload_header_size) / item_record_size else root.items.len - start;
        for (root.items[start .. start + take]) |item| {
            write(u32, payload, record, @intCast(item.node));
            write(u32, payload, record + 4, @intCast(at - data_start + item.text.len));
            @memcpy(payload[at .. at + item.text.len], item.text);
            record += item_record_size;
            at += item.text.len;
        }
    }
    return payload;
}
fn encodePayload(allocator: std.mem.Allocator, payload: []const u8, options: Options) Error!Encoded {
    if (options.codec == .raw) return .{ .codec = .raw, .bytes = payload };
    const capacity = try bzipBound(payload.len);
    if (capacity > options.max_compressed_block or capacity > options.max_decode_bytes) return Error.LimitExceeded;
    const buffer = allocator.alloc(u8, capacity) catch return Error.OutOfMemory;
    @memcpy(buffer[0..payload.len], payload);
    const state_size = @max(options.stateBytes(), min_bzip3_state);
    if (payload.len > state_size) return Error.LimitExceeded;
    const state = try codecState(state_size, options.max_codec_memory);
    defer c.bz3_free(state);
    const result = c.bz3_encode_block(state, buffer.ptr, @intCast(payload.len));
    if (result < 0) return mapCodecError(state);
    const size: usize = @intCast(result);
    if (size > buffer.len) return Error.CodecFailure;
    if (options.codec == .auto and size >= payload.len) return .{ .codec = .raw, .bytes = payload };
    return .{ .codec = .bzip3, .bytes = buffer[0..size] };
}
/// Request-owned codec workspace. Repeated block decodes reuse one state;
/// pins own only decoded bytes and remain valid when this workspace is reused.
/// A Decoder is single-threaded; immutable Stores may be shared freely.
pub const Decoder = struct {
    state: ?*c.struct_bz3_state = null,
    capacity: usize = 0,

    pub fn deinit(self: *Decoder) void {
        if (self.state) |state| c.bz3_free(state);
        self.* = .{};
    }

    fn decode(self: *Decoder, allocation: []u8, stored: []const u8, original: usize, limits: Options) Error!void {
        const needed = @max(limits.stateBytes(), @max(original, stored.len));
        if (self.state == null or self.capacity < needed) {
            const state = try codecState(needed, limits.max_codec_memory);
            self.deinit();
            self.state = state;
            self.capacity = needed;
        }
        if (c.bz3_min_memory_needed(@intCast(self.capacity)) > limits.max_codec_memory) return error.LimitExceeded;
        @memcpy(allocation[0..stored.len], stored);
        const state = self.state.?;
        const result = c.bz3_decode_block(state, allocation.ptr, allocation.len, @intCast(stored.len), @intCast(original));
        if (result < 0) return mapCodecError(state);
        if (@as(usize, @intCast(result)) != original) return Error.Corrupt;
    }
};
fn validatePayload(payload: []const u8, expected: usize, limits: Options) Error!void {
    if (payload.len < payload_header_size or !std.mem.eql(u8, payload[0..4], payload_magic) or read(u16, payload, 4) != payload_version or read(u16, payload, 6) != 0) return Error.Malformed;
    const items = @as(usize, read(u32, payload, 8));
    const directory = @as(usize, read(u32, payload, 12));
    const data = try toUsize(read(u64, payload, 16));
    if (items != expected or items > limits.max_items_per_block or directory != try mul(items, item_record_size)) return Error.Malformed;
    const start = try add(payload_header_size, directory);
    if (start > payload.len or try add(start, data) != payload.len) return Error.Malformed;
    var previous_node: ?u64 = null;
    var previous_end: usize = start;
    for (0..items) |index| {
        const at = payload_header_size + index * item_record_size;
        const node = read(u32, payload, at);
        if (previous_node) |previous| if (node <= previous) return Error.Malformed;
        previous_node = node;
        // Cumulative ends make gaps and overlap unrepresentable and halve
        // the item directory. Empty strings simply repeat the previous end.
        const text_end = try add(start, read(u32, payload, at + 4));
        if (text_end < previous_end or text_end > payload.len) return Error.Malformed;
        previous_end = text_end;
    }
    if (previous_end != try add(start, data)) return Error.Malformed;
}
fn parseMeta(bytes: []const u8, at: usize, limits: Options) Error!BlockMeta {
    const record = RecordLayout.read(bytes, at) catch return error.Malformed;
    if (!std.mem.eql(u8, &record.reserved, &.{ 0, 0, 0 })) return error.Malformed;
    const codec = record.codec;
    const first = record.root_first;
    const last = record.root_last;
    const node_first = record.node_first;
    const node_last = record.node_last;
    const original = record.original_size;
    const stored = record.stored_size;
    const offset = try toUsize(record.stored_offset);
    const items = record.item_count;
    const root_count = record.root_count;
    const root_index = record.root_index;
    if (first > last or node_first > node_last or root_count == 0 or items == 0 or items > limits.max_items_per_block or original > limits.max_uncompressed_block or stored > limits.max_compressed_block) return Error.LimitExceeded;
    if (original < payload_header_size or codec == .raw and stored != original) return Error.Malformed;
    return .{ .root_first = first, .root_last = last, .node_first = node_first, .node_last = node_last, .root_index = root_index, .root_count = root_count, .item_count = items, .codec = codec, .original_size = original, .stored_offset = offset, .stored_size = stored };
}
fn bzipBound(size: usize) Error!usize {
    if (size > max_bzip3_state or size > std.math.maxInt(i32)) return Error.LimitExceeded;
    const bound = c.bz3_bound(size);
    return if (bound < size) Error.CodecFailure else bound;
}
fn codecState(size: usize, memory_limit: usize) Error!*c.struct_bz3_state {
    if (size > max_bzip3_state or size > std.math.maxInt(i32)) return Error.LimitExceeded;
    const memory = c.bz3_min_memory_needed(@intCast(size));
    if (memory == 0 or memory > memory_limit) return Error.LimitExceeded;
    return c.bz3_new(@intCast(size)) orelse Error.AllocationFailed;
}
fn mapCodecError(state: *c.struct_bz3_state) Error {
    return switch (c.bz3_last_error(state)) {
        c.BZ3_ERR_CRC => Error.Corrupt,
        c.BZ3_ERR_MALFORMED_HEADER, c.BZ3_ERR_OUT_OF_BOUNDS => Error.Malformed,
        c.BZ3_ERR_TRUNCATED_DATA => Error.Truncated,
        c.BZ3_ERR_DATA_TOO_BIG, c.BZ3_ERR_DATA_SIZE_TOO_SMALL => Error.LimitExceeded,
        else => Error.CodecFailure,
    };
}
fn add(a: usize, b: usize) Error!usize {
    const x = @addWithOverflow(a, b);
    return if (x[1] != 0) Error.LimitExceeded else x[0];
}
fn mul(a: usize, b: usize) Error!usize {
    const x = @mulWithOverflow(a, b);
    return if (x[1] != 0) Error.LimitExceeded else x[0];
}
fn toUsize(value: u64) Error!usize {
    return if (value > std.math.maxInt(usize)) Error.LimitExceeded else @intCast(value);
}
fn read(comptime T: type, bytes: []const u8, at: usize) T {
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}
fn write(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}
