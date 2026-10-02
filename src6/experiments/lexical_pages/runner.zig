//! Exact native-model storage screen and explicitly gated access benchmark.
//! All variants use the same independently addressed root groups. The LPB1
//! envelope pays its checksum/header, 24-byte page directory and every stored
//! inner frame. It provides ordinal access only: lexical/identity indexes are
//! equally excluded, so these are page-representation, not full archive costs.
const std = @import("std");
const lex = @import("lex6");
const dag = @import("dag.zig");
const shape = @import("shape.zig");
const shape_view = @import("shape_view.zig");
const workloads = @import("workloads.zig");
const Entry = lex.model.Entry;
const Page = dag.Page(Entry);
const Prepared = dag.PreparedPage(Entry);
const normal_page_bytes = 64 * 1024;
const exceptional_page_bytes = 1024 * 1024;
const bundle_header_bytes = 64;
const directory_entry_bytes = 24;
const compression_limits = lex.compression.Limits{ .max_block_bytes = exceptional_page_bytes };
const Variant = enum { flat, shared, shape, raw_adaptive, compressed_minimum };

const Timer = struct {
    io: std.Io,
    start: i96,
    fn init(io: std.Io) Timer {
        return .{ .io = io, .start = std.Io.Clock.awake.now(io).nanoseconds };
    }
    fn elapsed(self: Timer) u64 {
        return @intCast(@max(@as(i96, 0), std.Io.Clock.awake.now(self.io).nanoseconds - self.start));
    }
};

// Successful Zig allocator hooks and requested growth, not malloc/RSS. Native
// bzip3 state and process/OS storage are explicitly outside these counters.
const Meter = struct {
    child: std.mem.Allocator,
    alloc_calls: usize = 0,
    resize_calls: usize = 0,
    remap_calls: usize = 0,
    growth_bytes: usize = 0,
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    start_live: usize = 0,
    fn allocator(self: *Meter) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn reset(self: *Meter) void {
        self.alloc_calls = 0;
        self.resize_calls = 0;
        self.remap_calls = 0;
        self.growth_bytes = 0;
        self.peak_bytes = self.live_bytes;
        self.start_live = self.live_bytes;
    }
    fn account(self: *Meter, before: usize, after: usize) void {
        if (after > before) {
            self.live_bytes += after - before;
            self.growth_bytes += after - before;
        } else self.live_bytes -= before - after;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(length, alignment, address) orelse return null;
        self.alloc_calls += 1;
        self.account(0, length);
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
        const self: *Meter = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, length, address)) return false;
        self.resize_calls += 1;
        self.account(memory.len, length);
        return true;
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
        const self: *Meter = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(memory, alignment, length, address) orelse return null;
        self.remap_calls += 1;
        self.account(memory.len, length);
        return result;
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *Meter = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, address);
        self.account(memory.len, 0);
    }
};

const Group = struct {
    start: usize,
    count: usize,
    limits: dag.Limits,
    flat: []u8,
    shared: []u8,
    shaped: []u8,
    flat_page: ?Page = null,
    shared_page: ?Page = null,
    flat_prepared: ?Prepared = null,
    shared_prepared: ?Prepared = null,
    shape_page: ?shape.Page(Entry) = null,
};

const Layout = struct {
    allocator: std.mem.Allocator,
    groups: []Group,
    canonical_packet_bytes: usize,
    max_root_packet_bytes: usize,
    exceptional_pages: usize,
    shared_encoding_trials: usize,
    shape_encoding_trials: usize,
    flat_encoding_ns: u64,
    shared_encoding_ns: u64,
    shape_encoding_ns: u64,
    fn deinit(self: *Layout) void {
        for (self.groups) |group| {
            self.allocator.free(group.flat);
            self.allocator.free(group.shared);
            self.allocator.free(group.shaped);
        }
        self.allocator.free(self.groups);
        self.* = undefined;
    }
};

fn layout(allocator: std.mem.Allocator, io: std.Io, entries: []const Entry, quiet: bool) !Layout {
    const lengths = try allocator.alloc(usize, entries.len);
    defer allocator.free(lengths);
    var canonical_bytes: usize = 0;
    var max_root: usize = 0;
    for (entries, lengths) |entry, *length| {
        const bytes = try lex.packet.encode(allocator, entry, .{});
        defer allocator.free(bytes);
        length.* = bytes.len;
        canonical_bytes += bytes.len;
        max_root = @max(max_root, bytes.len);
        if (dag.header_size + 8 + bytes.len > exceptional_page_bytes) return error.RootExceedsOneMiBPage;
    }
    var groups: std.ArrayList(Group) = .empty;
    errdefer {
        for (groups.items) |group| {
            allocator.free(group.flat);
            allocator.free(group.shared);
            allocator.free(group.shaped);
        }
        groups.deinit(allocator);
    }
    var start: usize = 0;
    var exceptions: usize = 0;
    var trials: usize = 0;
    var shape_trials: usize = 0;
    var flat_ns: u64 = 0;
    var shared_ns: u64 = 0;
    var shape_ns: u64 = 0;
    while (start < entries.len) {
        var count: usize = 0;
        var size: usize = dag.header_size + 4;
        while (start + count < entries.len and count < 4096) {
            const next = 4 + lengths[start + count];
            if (count != 0 and size + next > normal_page_bytes) break;
            size += next;
            count += 1;
            if (size > normal_page_bytes) break;
        }
        var limits = dag.Limits{ .max_page_bytes = if (count == 1) exceptional_page_bytes else normal_page_bytes };
        var shared: []u8 = undefined;
        var shaped: []u8 = undefined;
        while (true) {
            const timer = if (quiet) Timer.init(io) else null;
            trials += 1;
            const attempt = dag.encodePage(Entry, allocator, entries[start .. start + count], limits, .shared);
            if (timer) |clock| shared_ns += clock.elapsed();
            shared = attempt catch |err| {
                if (err != error.PageTooLarge or count == 1) return err;
                count = @max(@as(usize, 1), count / 2);
                limits.max_page_bytes = if (count == 1) exceptional_page_bytes else normal_page_bytes;
                continue;
            };
            const shape_timer = if (quiet) Timer.init(io) else null;
            shape_trials += 1;
            const shape_attempt = shape.encodePage(Entry, allocator, entries[start .. start + count], .{ .max_page_bytes = limits.max_page_bytes });
            if (shape_timer) |clock| shape_ns += clock.elapsed();
            shaped = shape_attempt catch |err| {
                allocator.free(shared);
                if (err != error.PageTooLarge or count == 1) return err;
                count = @max(@as(usize, 1), count / 2);
                limits.max_page_bytes = if (count == 1) exceptional_page_bytes else normal_page_bytes;
                continue;
            };
            break;
        }
        errdefer allocator.free(shared);
        errdefer allocator.free(shaped);
        const timer = if (quiet) Timer.init(io) else null;
        const flat = try dag.encodePage(Entry, allocator, entries[start .. start + count], limits, .flat);
        if (timer) |clock| flat_ns += clock.elapsed();
        errdefer allocator.free(flat);
        if (flat.len > normal_page_bytes or shared.len > normal_page_bytes or shaped.len > normal_page_bytes) exceptions += 1;
        try groups.append(allocator, .{ .start = start, .count = count, .limits = limits, .flat = flat, .shared = shared, .shaped = shaped });
        start += count;
    }
    return .{
        .allocator = allocator,
        .groups = try groups.toOwnedSlice(allocator),
        .canonical_packet_bytes = canonical_bytes,
        .max_root_packet_bytes = max_root,
        .exceptional_pages = exceptions,
        .shared_encoding_trials = trials,
        .shape_encoding_trials = shape_trials,
        .flat_encoding_ns = flat_ns,
        .shared_encoding_ns = shared_ns,
        .shape_encoding_ns = shape_ns,
    };
}

const AccessObservation = struct {
    checksum: u64 = 0,
    consumed_bytes: u64 = 0,
    fn add(self: *AccessObservation, other: AccessObservation) void {
        self.checksum +%= other.checksum;
        self.consumed_bytes += other.consumed_bytes;
    }
};

fn observeFields(headword: []const u8, text: []const u8) AccessObservation {
    var hash = std.hash.Wyhash.init(0x6c65787061676571);
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, headword.len, .little);
    hash.update(&length);
    hash.update(headword);
    std.mem.writeInt(u64, &length, text.len, .little);
    hash.update(&length);
    hash.update(text);
    return .{ .checksum = hash.final(), .consumed_bytes = headword.len + text.len };
}

fn consumeNative(entry: *const Entry, natural: bool) !AccessObservation {
    if (natural) {
        if (entry.content.len != 1 or entry.content[0] != .definition) return error.InvalidNaturalShape;
        const text = entry.content[0].definition;
        if (text.content.len != 1 or text.content[0] != .text) return error.InvalidNaturalShape;
        return observeFields(entry.headword, text.content[0].text);
    }
    var senses = lex.query.entry(entry).select(.sense, .children);
    const sense = (try senses.next()) orelse return error.MissingSense;
    return observeFields(entry.headword, sense.value.label orelse return error.MissingLabel);
}

fn consumeView(view: anytype, natural: bool) !AccessObservation {
    const headword = try (try view.field(.headword)).text();
    var items = try (try view.field(.content)).values();
    while (try items.next()) |item| {
        const kind = try item.tag();
        if (natural and kind == .definition) {
            var inlines = try (try (try item.payload(.definition)).field(.content)).values();
            const inline_ = (try inlines.next()) orelse return error.InvalidNaturalShape;
            return observeFields(headword, try (try inline_.payload(.text)).text());
        }
        if (!natural and kind == .sense) {
            const label = (try (try (try item.payload(.sense)).field(.label)).optional()) orelse return error.MissingLabel;
            return observeFields(headword, try label.text());
        }
    }
    return error.MissingQueryField;
}

fn phase(writer: *std.Io.Writer, name: []const u8, variant: []const u8, elapsed: u64, meter: *const Meter, observation: AccessObservation, operations: usize) !void {
    try std.json.Stringify.value(.{
        .phase = name,
        .variant = variant,
        .ns = elapsed,
        .alloc_calls = meter.alloc_calls,
        .resize_calls = meter.resize_calls,
        .remap_calls = meter.remap_calls,
        .growth_bytes = meter.growth_bytes,
        .peak_requested_delta_bytes = meter.peak_bytes - meter.start_live,
        .checksum = observation.checksum,
        .consumed_bytes = observation.consumed_bytes,
        .operations = operations,
    }, .{}, writer);
    try writer.writeByte('\n');
}

fn gates(io: std.Io, writer: *std.Io.Writer, meter: *Meter, source: []const Entry, groups: []Group, natural: bool, quiet: bool) !void {
    inline for (.{ dag.Mode.flat, dag.Mode.shared }) |mode| {
        meter.reset();
        const open_timer = if (quiet) Timer.init(io) else null;
        for (groups) |*group| {
            const page = try dag.open(Entry, meter.allocator(), if (mode == .flat) group.flat else group.shared, group.limits);
            if (mode == .flat) group.flat_page = page else group.shared_page = page;
        }
        if (open_timer) |clock| try phase(writer, "structural_open_all_pages", @tagName(mode), clock.elapsed(), meter, .{}, groups.len);
        meter.reset();
        const prepare_timer = if (quiet) Timer.init(io) else null;
        for (groups) |*group| {
            const page = if (mode == .flat) group.flat_page.? else group.shared_page.?;
            const prepared = try page.prepare(meter.allocator(), .{});
            if (mode == .flat) group.flat_prepared = prepared else group.shared_prepared = prepared;
        }
        if (prepare_timer) |clock| try phase(writer, "full_semantic_prepare_all_pages", @tagName(mode), clock.elapsed(), meter, .{}, source.len);
        // Every native field is checked outside access timers. The hash oracle
        // walks original native values; no candidate wire answer table exists.
        for (groups) |group| {
            const page = if (mode == .flat) group.flat_page.? else group.shared_page.?;
            const prepared = if (mode == .flat) group.flat_prepared.? else group.shared_prepared.?;
            for (0..group.count) |index| {
                const expected = &source[group.start + index];
                var decoded = try page.decode(meter.allocator(), index);
                defer decoded.deinit();
                if (!workloads.nativeEqual(Entry, expected.*, decoded.value)) return error.IncorrectNativeValue;
                if (!std.meta.eql(try workloads.observe(expected), try workloads.observe(&decoded.value))) return error.IncorrectFullObservation;
                const expected_query = try consumeNative(expected, natural);
                if (!std.meta.eql(expected_query, try consumeView(try prepared.view(index), natural))) return error.IncorrectQueryObservation;
            }
        }
    }
    meter.reset();
    const open_timer = if (quiet) Timer.init(io) else null;
    for (groups) |*group| group.shape_page = try shape.open(Entry, meter.allocator(), group.shaped, .{ .max_page_bytes = group.limits.max_page_bytes });
    if (open_timer) |clock| try phase(writer, "structural_open_all_pages", "shape", clock.elapsed(), meter, .{}, groups.len);
    meter.reset();
    const prepare_timer = if (quiet) Timer.init(io) else null;
    for (groups) |group| try group.shape_page.?.prepare(meter.allocator(), .{});
    if (prepare_timer) |clock| try phase(writer, "full_semantic_prepare_all_pages", "shape", clock.elapsed(), meter, .{}, source.len);
    for (groups) |group| {
        for (0..group.count) |index| {
            const expected = &source[group.start + index];
            var decoded = try group.shape_page.?.decode(meter.allocator(), index);
            defer decoded.deinit();
            if (!workloads.nativeEqual(Entry, expected.*, decoded.value)) return error.IncorrectNativeValue;
            if (!std.meta.eql(try workloads.observe(expected), try workloads.observe(&decoded.value))) return error.IncorrectFullObservation;
            if (!std.meta.eql(try consumeNative(expected, natural), try consumeNative(&decoded.value, natural))) return error.IncorrectQueryObservation;
            if (!std.meta.eql(try consumeNative(expected, natural), try consumeView(try shape_view.fromAdmittedPage(Entry, group.shape_page.?, index), natural))) return error.IncorrectQueryObservation;
        }
    }
}

fn put32(bytes: []u8, at: usize, number: usize) void {
    std.mem.writeInt(u32, bytes[at..][0..4], @intCast(number), .little);
}

fn get32(bytes: []const u8, at: usize) usize {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

const Bundle = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    chosen_frames: []const []const u8,
    shared_pages: usize,
    shape_pages: usize,
    graph_nodes: usize,
    shape_nodes: usize,
    shape_bytes: usize,
    literal_bytes: usize,
    max_frame_bytes: usize,
    encoding_trials: usize,
    fn deinit(self: *Bundle) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.chosen_frames);
        self.* = undefined;
    }
};

fn bundle(allocator: std.mem.Allocator, groups: []const Group, variant: Variant, backend: lex.compression.Mode) !Bundle {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const blocks = try a.alloc(lex.compression.Block, groups.len);
    var initialized: usize = 0;
    defer for (blocks[0..initialized]) |*block| block.deinit();
    const chosen = try allocator.alloc([]const u8, groups.len);
    errdefer allocator.free(chosen);
    var size: usize = bundle_header_bytes + groups.len * directory_entry_bytes;
    var raw_size: usize = 0;
    var shared_pages: usize = 0;
    var shape_pages: usize = 0;
    var graph_nodes: usize = 0;
    var shape_nodes: usize = 0;
    var shape_bytes: usize = 0;
    var literal_bytes: usize = 0;
    var max_frame: usize = 0;
    var roots: usize = 0;
    var trials: usize = 0;
    for (groups, 0..) |group, index| {
        if (variant == .compressed_minimum) {
            var flat = try lex.compression.encode(allocator, group.flat, backend, compression_limits);
            errdefer flat.deinit();
            var shared = try lex.compression.encode(allocator, group.shared, backend, compression_limits);
            errdefer shared.deinit();
            var shaped = try lex.compression.encode(allocator, group.shaped, backend, compression_limits);
            trials += 3;
            if (shaped.bytes.len < flat.bytes.len and shaped.bytes.len < shared.bytes.len) {
                flat.deinit();
                shared.deinit();
                blocks[index] = shaped;
                chosen[index] = group.shaped;
            } else if (shared.bytes.len < flat.bytes.len) {
                shaped.deinit();
                flat.deinit();
                blocks[index] = shared;
                chosen[index] = group.shared;
            } else {
                shaped.deinit();
                shared.deinit();
                blocks[index] = flat;
                chosen[index] = group.flat;
            }
        } else {
            chosen[index] = switch (variant) {
                .flat => group.flat,
                .shared => group.shared,
                .shape => group.shaped,
                .raw_adaptive => if (group.shaped.len < group.flat.len and group.shaped.len < group.shared.len) group.shaped else if (group.shared.len < group.flat.len) group.shared else group.flat,
                .compressed_minimum => unreachable,
            };
            blocks[index] = try lex.compression.encode(allocator, chosen[index], backend, compression_limits);
            trials += 1;
        }
        initialized += 1;
        size += blocks[index].bytes.len;
        raw_size += chosen[index].len;
        roots += group.count;
        max_frame = @max(max_frame, chosen[index].len);
        if (std.mem.eql(u8, chosen[index][0..4], "LPS1")) {
            shape_pages += 1;
            shape_nodes += get32(chosen[index], 12);
            shape_bytes += get32(chosen[index], 16);
            literal_bytes += get32(chosen[index], 20);
        } else if (chosen[index][5] == @intFromEnum(dag.Mode.shared)) {
            shared_pages += 1;
            graph_nodes += get32(chosen[index], 12);
        }
    }
    if (size > std.math.maxInt(u32)) return error.BundleTooLarge;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "LPB1");
    bytes[4] = 2;
    bytes[5] = @intFromEnum(variant);
    put32(bytes, 8, groups.len);
    put32(bytes, 12, roots);
    put32(bytes, 16, directory_entry_bytes);
    std.mem.writeInt(u64, bytes[24..32], raw_size, .little);
    var offset: usize = bundle_header_bytes + groups.len * directory_entry_bytes;
    for (groups, blocks, 0..) |group, block, index| {
        const at = bundle_header_bytes + index * directory_entry_bytes;
        put32(bytes, at, group.start);
        put32(bytes, at + 4, group.count);
        put32(bytes, at + 8, block.raw_len);
        put32(bytes, at + 12, block.bytes.len);
        put32(bytes, at + 16, offset);
        bytes[at + 20] = @intFromEnum(block.codec);
        @memcpy(bytes[offset..][0..block.bytes.len], block.bytes);
        offset += block.bytes.len;
    }
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(bytes[32..64]);
    return .{ .allocator = allocator, .bytes = bytes, .chosen_frames = chosen, .shared_pages = shared_pages, .shape_pages = shape_pages, .graph_nodes = graph_nodes, .shape_nodes = shape_nodes, .shape_bytes = shape_bytes, .literal_bytes = literal_bytes, .max_frame_bytes = max_frame, .encoding_trials = trials };
}

fn verifyBundle(allocator: std.mem.Allocator, value: *const Bundle, groups: []const Group) !void {
    const bytes = value.bytes;
    if (bytes.len < bundle_header_bytes or !std.mem.eql(u8, bytes[0..4], "LPB1") or bytes[4] != 2 or get32(bytes, 8) != groups.len) return error.InvalidBundle;
    var digest: [32]u8 = undefined;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(bytes[0..32]);
    hash.update(bytes[64..]);
    hash.final(&digest);
    if (!std.crypto.timing_safe.eql([32]u8, digest, bytes[32..64].*)) return error.InvalidBundle;
    var offset = bundle_header_bytes + groups.len * directory_entry_bytes;
    for (groups, value.chosen_frames, 0..) |group, frame, index| {
        const at = bundle_header_bytes + index * directory_entry_bytes;
        if (get32(bytes, at) != group.start or get32(bytes, at + 4) != group.count or get32(bytes, at + 8) != frame.len or get32(bytes, at + 16) != offset) return error.InvalidBundle;
        const stored_len = get32(bytes, at + 12);
        if (stored_len > bytes.len - offset) return error.InvalidBundle;
        const codec = std.enums.fromInt(lex.compression.Codec, bytes[at + 20]) orelse return error.InvalidBundle;
        var decoded = try lex.compression.decode(allocator, codec, bytes[offset..][0..stored_len], frame.len, compression_limits);
        defer decoded.deinit();
        if (!std.mem.eql(u8, frame, decoded.bytes)) return error.IncorrectCompressedPage;
        offset += stored_len;
    }
    if (offset != bytes.len) return error.InvalidBundle;
}

fn selectedOrdinal(total: usize, operations: usize, index: usize, mixed: bool) usize {
    return if (!mixed or operations == 1) 0 else index * (total - 1) / (operations - 1);
}

fn groupFor(groups: []const Group, ordinal: usize) usize {
    var low: usize = 0;
    var high = groups.len;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (groups[middle].start <= ordinal) low = middle else high = middle;
    }
    return low;
}

fn access(io: std.Io, writer: *std.Io.Writer, meter: *Meter, source: []const Entry, groups: []const Group, operations: usize, natural: bool) !void {
    inline for (.{ false, true }) |mixed| {
        var expected = AccessObservation{};
        for (0..operations) |index| expected.add(try consumeNative(&source[selectedOrdinal(source.len, operations, index, mixed)], natural));
        inline for (.{ dag.Mode.flat, dag.Mode.shared }) |mode| {
            meter.reset();
            const native_timer = Timer.init(io);
            var native = AccessObservation{};
            for (0..operations) |index| {
                const ordinal = selectedOrdinal(source.len, operations, index, mixed);
                const group = groups[groupFor(groups, ordinal)];
                const page = if (mode == .flat) group.flat_page.? else group.shared_page.?;
                var value = try page.decode(meter.allocator(), ordinal - group.start);
                defer value.deinit();
                native.add(try consumeNative(&value.value, natural));
            }
            const native_ns = native_timer.elapsed();
            if (!std.meta.eql(expected, native)) return error.IncorrectQueryObservation;
            try phase(writer, if (mixed) "prepared_native_decode_mixed" else "prepared_native_decode_same_root", @tagName(mode), native_ns, meter, native, operations);
            meter.reset();
            const view_timer = Timer.init(io);
            var wire = AccessObservation{};
            for (0..operations) |index| {
                const ordinal = selectedOrdinal(source.len, operations, index, mixed);
                const group = groups[groupFor(groups, ordinal)];
                const prepared = if (mode == .flat) group.flat_prepared.? else group.shared_prepared.?;
                wire.add(try consumeView(try prepared.view(ordinal - group.start), natural));
            }
            const view_ns = view_timer.elapsed();
            if (!std.meta.eql(expected, wire)) return error.IncorrectQueryObservation;
            try phase(writer, if (mixed) "prepared_direct_projection_mixed" else "prepared_direct_projection_same_root", @tagName(mode), view_ns, meter, wire, operations);
        }
        meter.reset();
        const native_timer = Timer.init(io);
        var native = AccessObservation{};
        for (0..operations) |index| {
            const ordinal = selectedOrdinal(source.len, operations, index, mixed);
            const group = groups[groupFor(groups, ordinal)];
            var value = try group.shape_page.?.decode(meter.allocator(), ordinal - group.start);
            defer value.deinit();
            native.add(try consumeNative(&value.value, natural));
        }
        const native_ns = native_timer.elapsed();
        if (!std.meta.eql(expected, native)) return error.IncorrectQueryObservation;
        try phase(writer, if (mixed) "prepared_native_decode_mixed" else "prepared_native_decode_same_root", "shape", native_ns, meter, native, operations);
        meter.reset();
        const view_timer = Timer.init(io);
        var wire = AccessObservation{};
        for (0..operations) |index| {
            const ordinal = selectedOrdinal(source.len, operations, index, mixed);
            const group = groups[groupFor(groups, ordinal)];
            wire.add(try consumeView(try shape_view.fromAdmittedPage(Entry, group.shape_page.?, ordinal - group.start), natural));
        }
        const view_ns = view_timer.elapsed();
        if (!std.meta.eql(expected, wire)) return error.IncorrectQueryObservation;
        try phase(writer, if (mixed) "prepared_direct_projection_mixed" else "prepared_direct_projection_same_root", "shape", view_ns, meter, wire, operations);
    }
}

pub fn main(init: std.process.Init) !void {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const kind = args.next() orelse "rich";
    const natural = std.mem.eql(u8, kind, "natural");
    if (!natural and !std.mem.eql(u8, kind, "rich")) return error.InvalidWorkload;
    const source_arg = args.next() orelse if (natural) return error.MissingProjection else "4096";
    var count: usize = if (natural) 4096 else try std.fmt.parseUnsigned(usize, source_arg, 10);
    var operations: usize = 1024;
    var quiet = false;
    var retain: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet-gate")) {
            const token = args.next() orelse return error.MissingQuietGate;
            if (!std.mem.eql(u8, token, "ROOT-EXPLICIT-QUIET-GATE")) return error.InvalidQuietGate;
            quiet = true;
        } else if (std.mem.eql(u8, arg, "--entries")) {
            count = try std.fmt.parseUnsigned(usize, args.next() orelse return error.MissingCount, 10);
        } else if (std.mem.eql(u8, arg, "--operations")) {
            operations = try std.fmt.parseUnsigned(usize, args.next() orelse return error.MissingOperations, 10);
        } else if (std.mem.eql(u8, arg, "--retain-prefix")) {
            retain = args.next() orelse return error.MissingRetainPrefix;
        } else return error.UnknownArgument;
    }
    if (operations == 0 or operations > 1_000_000) return error.InvalidOperations;
    const allocator = std.heap.c_allocator;
    var source = if (natural) try workloads.natural(allocator, init.io, source_arg, count) else try workloads.rich(allocator, count);
    defer source.deinit();
    if (source.entries.len == 0) return error.EmptyWorkload;
    var output: [16 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &output);
    const writer = &stdout.interface;
    var full_hash: u64 = 0;
    var native_string_bytes: usize = 0;
    var source_identities: std.StringHashMapUnmanaged(void) = .empty;
    defer source_identities.deinit(allocator);
    for (source.entries) |*entry| {
        const identity = try source_identities.getOrPut(allocator, entry.id);
        if (identity.found_existing) return error.DuplicateSourceIdentity;
        try lex.validate.check(allocator, entry, .{});
        const observed = try workloads.observe(entry);
        full_hash +%= observed.hash;
        native_string_bytes += observed.string_bytes;
    }
    try std.json.Stringify.value(.{
        .protocol = "LEXICAL-PAGES/2",
        .workload = kind,
        .source = source_arg,
        .entries = source.entries.len,
        .native_full_observation_checksum = full_hash,
        .native_observed_string_bytes = native_string_bytes,
        .source_identity_gate = "all native input entry IDs globally unique",
        .quiet_gate = quiet,
        .ordering = "original native entry order",
        .packing = "common flat-bounded groups; shared/shape-cap bisection; ordinary complete frames <=64KiB; exceptional single roots <=1MiB",
        .storage_scope = "LPB1 ordinal page envelope;64-byte header/checksum+24-byte/page directory+all inner frames; no lexical/identity index",
        .query = if (natural) "headword and complete preserved single-definition text" else "headword and first direct sense label",
        .access_scope = "all immutable uncompressed frames resident and structurally/semantically prepared; application metadata for every page retained",
        .allocation_scope = "successful Zig allocator hooks and requested growth/peak; native C state, RSS and OS caches excluded",
    }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
    var meter = Meter{ .child = allocator };
    meter.reset();
    const pack_timer = if (quiet) Timer.init(init.io) else null;
    var page_layout = try layout(meter.allocator(), init.io, source.entries, quiet);
    defer page_layout.deinit();
    if (pack_timer) |clock| try phase(writer, "common_pack_and_encode_flat_shared_shape", "all_three", clock.elapsed(), &meter, .{}, source.entries.len);
    try std.json.Stringify.value(.{
        .layout = "common_groups",
        .pages = page_layout.groups.len,
        .roots = source.entries.len,
        .canonical_entry_packet_bytes = page_layout.canonical_packet_bytes,
        .max_root_packet_bytes = page_layout.max_root_packet_bytes,
        .exceptional_single_root_pages = page_layout.exceptional_pages,
        .shared_frame_encoding_trials = page_layout.shared_encoding_trials,
        .shape_frame_encoding_trials = page_layout.shape_encoding_trials,
    }, .{}, writer);
    try writer.writeByte('\n');
    try gates(init.io, writer, &meter, source.entries, page_layout.groups, natural, quiet);
    try writer.writeAll("{\"gate\":\"all_flat_shared_shape_roots_admitted_native_equal_and_complete_native_observation_equal; all_three_direct_projection_equal\"}\n");
    inline for (.{ Variant.flat, Variant.shared, Variant.shape, Variant.raw_adaptive, Variant.compressed_minimum }) |variant| {
        inline for (.{ lex.compression.Mode.raw, lex.compression.Mode.bzip3, lex.compression.Mode.adaptive }) |backend| {
            meter.reset();
            const encode_timer = if (quiet) Timer.init(init.io) else null;
            var encoded = try bundle(meter.allocator(), page_layout.groups, variant, backend);
            defer encoded.deinit();
            if (encode_timer) |clock| try phase(writer, "backend_encode_and_complete_bundle", @tagName(variant) ++ "/" ++ @tagName(backend), clock.elapsed(), &meter, .{}, page_layout.groups.len);
            meter.reset();
            const decode_timer = if (quiet) Timer.init(init.io) else null;
            try verifyBundle(meter.allocator(), &encoded, page_layout.groups);
            if (decode_timer) |clock| try phase(writer, "backend_decode_all_pages_and_exact_frame_gate", @tagName(variant) ++ "/" ++ @tagName(backend), clock.elapsed(), &meter, .{}, page_layout.groups.len);
            const sha = std.fmt.bytesToHex(encoded.bytes[32..64].*, .lower);
            try std.json.Stringify.value(.{
                .storage = "complete_ordinal_page_bundle",
                .variant = @tagName(variant),
                .backend = @tagName(backend),
                .complete_bytes = encoded.bytes.len,
                .outer_framing_bytes = bundle_header_bytes + page_layout.groups.len * directory_entry_bytes,
                .inner_uncompressed_frame_bytes = std.mem.readInt(u64, encoded.bytes[24..32], .little),
                .stored_payload_bytes = encoded.bytes.len - bundle_header_bytes - page_layout.groups.len * directory_entry_bytes,
                .pages = page_layout.groups.len,
                .roots = source.entries.len,
                .shared_pages = encoded.shared_pages,
                .shape_pages = encoded.shape_pages,
                .flat_pages = page_layout.groups.len - encoded.shared_pages - encoded.shape_pages,
                .graph_nodes = encoded.graph_nodes,
                .shape_nodes = encoded.shape_nodes,
                .encoded_shape_bytes = encoded.shape_bytes,
                .encoded_literal_lane_bytes = encoded.literal_bytes,
                .max_uncompressed_frame_bytes = encoded.max_frame_bytes,
                .backend_encoding_trials = encoded.encoding_trials,
                .selection = if (variant == .compressed_minimum) "minimum actual complete compressed page among flat/shared/shape; all three full trials paid" else if (variant == .raw_adaptive) "minimum actual complete raw flat/shared/shape frame before backend" else "fixed representation",
                .bundle_digest = @as([]const u8, &sha),
                .gate = "all stored pages decode exactly to fully admitted native-equal frame",
            }, .{}, writer);
            try writer.writeByte('\n');
            if (retain) |prefix| {
                const path = try std.fmt.allocPrint(allocator, "{s}.{s}.{s}.lpb", .{ prefix, @tagName(variant), @tagName(backend) });
                defer allocator.free(path);
                try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = encoded.bytes });
            }
            try writer.flush();
        }
    }
    if (quiet) try access(init.io, writer, &meter, source.entries, page_layout.groups, operations, natural);
    try writer.flush();
}
