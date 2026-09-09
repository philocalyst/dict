//! Checkpointed, random-access coding for dense u32 sequences.
//!
//! The format in this file is intentionally self-contained.  It is useful as
//! a leaf section in a snapshot: an open view borrows the mapped bytes and a
//! build owns exactly one final byte string.  The builder measures complete
//! candidate strings (directory, alignment, tables, and checkpoints included)
//! before selecting a representation.

const std = @import("std");

pub const magic = "ENS4";
pub const version: u16 = 1;
pub const header_size: usize = 64;
pub const rans_scale_bits: u8 = 12;
pub const rans_total: u32 = 1 << rans_scale_bits;
pub const rans_l: u32 = 1 << 23;
pub const default_checkpoint_stride: usize = 64;
pub const max_entropy_alphabet: usize = 4096;

pub const Error = error{
    BadMagic,
    UnsupportedVersion,
    InvalidOptions,
    InvalidInput,
    InvalidEncoding,
    Truncated,
    OutOfBounds,
    Overflow,
    ValueOverflow,
    LimitExceeded,
    NotApplicable,
    UnsupportedStrategy,
    Corrupt,
    RansFailure,
    OutOfMemory,
};

/// `reference` is deliberately a transparent, little-endian u32 stream.  It
/// is both the lossless fallback and the independent oracle used by tests.
/// The other four variants are selected by the measured-size cascade.
pub const Strategy = enum(u8) {
    reference,
    constant,
    runs,
    @"packed",
    entropy,
};

// Compatibility names for callers that describe a sequence as a codec or a
// view; the wire and selection semantics remain those of Strategy/View.
pub const Options = struct {
    checkpoint_stride: usize = default_checkpoint_stride,
    max_values: usize = std.math.maxInt(u32),
    max_entropy_alphabet: usize = max_entropy_alphabet,

    pub fn validate(self: Options) Error!void {
        if (self.checkpoint_stride == 0 or self.checkpoint_stride > std.math.maxInt(u32) or
            self.max_values > std.math.maxInt(u64) or self.max_entropy_alphabet == 0 or
            self.max_entropy_alphabet > max_entropy_alphabet)
            return error.InvalidOptions;
    }
};

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    chosen: Strategy,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn strategy(self: *const Owned) Strategy {
        return self.chosen;
    }
};

pub const Checkpoint = struct {
    /// Strategy-specific random-access coordinate: a packed bit offset, a
    /// packed run/within pair, or an entropy payload byte offset.
    offset: u64,
    /// The rANS state at the start of an entropy block.  It is zero for the
    /// other strategies, whose checkpoint is an index into their records.
    state: u32 = 0,
};

fn readLE(comptime T: type, bytes: []const u8, at: usize) Error!T {
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return error.Truncated;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn writeLE(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

fn add(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.Overflow;
}

fn mul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.Overflow;
}

fn indexedOffset(base: usize, index: usize, item_size: usize) Error!usize {
    return add(base, try mul(index, item_size));
}

// Zig's error-union methods are intentionally not used here: this helper is
// also called while checking hostile offsets, where the failure must remain a
// normal codec error.
fn align8Checked(value: usize) Error!usize {
    const rounded = add(value, 7) catch return error.Overflow;
    return rounded & ~@as(usize, 7);
}

fn ceilDiv(value: usize, divisor: usize) Error!usize {
    if (divisor == 0) return error.InvalidOptions;
    if (value == 0) return 0;
    const rounded = add(value, divisor - 1) catch return error.Overflow;
    return rounded / divisor;
}

fn asUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.Overflow;
}

fn asU64(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse error.Overflow;
}

fn bitsFor(width: u8, count: usize) Error!usize {
    if (width > 32) return error.InvalidEncoding;
    const bits = mul(@as(usize, width), count) catch return error.Overflow;
    return ceilDiv(bits, 8);
}

fn widthFor(max_delta: u64) u8 {
    if (max_delta == 0) return 0;
    return @intCast(64 - @clz(max_delta));
}

fn valueAsU32(value: anytype) Error!u32 {
    return switch (@typeInfo(@TypeOf(value))) {
        .int, .comptime_int => std.math.cast(u32, value) orelse error.ValueOverflow,
        .@"enum" => std.math.cast(u32, @intFromEnum(value)) orelse error.ValueOverflow,
        else => error.InvalidInput,
    };
}

fn makeU32(allocator: std.mem.Allocator, values: anytype) Error![]u32 {
    const count = values.len;
    const out = allocator.alloc(u32, count) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    for (values, 0..) |value, i| out[i] = try valueAsU32(value);
    return out;
}

/// Build the adaptive sequence.  `values` may be a u32 slice/array or any
/// integer/enum slice whose values fit in u32.
pub fn build(allocator: std.mem.Allocator, values: anytype, options: Options) Error!Owned {
    try options.validate();
    if (values.len > options.max_values) return error.LimitExceeded;
    const normalized = try makeU32(allocator, values);
    defer allocator.free(normalized);
    return buildU32(allocator, normalized, options);
}

pub fn encode(allocator: std.mem.Allocator, values: anytype, options: Options) Error!Owned {
    return build(allocator, values, options);
}

pub fn buildU32(allocator: std.mem.Allocator, values: []const u32, options: Options) Error!Owned {
    try options.validate();
    if (values.len > options.max_values) return error.LimitExceeded;

    const order = [_]Strategy{ .constant, .runs, .@"packed", .entropy, .reference };
    const Candidate = struct { strategy: Strategy, bytes: []u8 };
    var candidates: [order.len]Candidate = undefined;
    var candidate_count: usize = 0;
    errdefer for (candidates[0..candidate_count]) |candidate| allocator.free(candidate.bytes);

    for (order) |kind| {
        const encoded = encodeCandidate(allocator, values, options, kind) catch |err| switch (err) {
            error.NotApplicable => continue,
            else => return err,
        };
        candidates[candidate_count] = .{ .strategy = kind, .bytes = encoded };
        candidate_count += 1;
    }
    if (candidate_count == 0) return error.NotApplicable;

    // Strictly smaller is important: rANS never wins merely because it ties
    // the transparent reference, and ties remain deterministic by cascade
    // order.
    var winner: usize = 0;
    for (1..candidate_count) |i| {
        if (candidates[i].bytes.len < candidates[winner].bytes.len) winner = i;
    }
    const selected = candidates[winner];
    for (candidates[0..candidate_count], 0..) |candidate, i| if (i != winner) allocator.free(candidate.bytes);
    return .{ .allocator = allocator, .bytes = selected.bytes, .chosen = selected.strategy };
}

pub fn buildReference(allocator: std.mem.Allocator, values: anytype) Error!Owned {
    const normalized = try makeU32(allocator, values);
    defer allocator.free(normalized);
    return buildForced(allocator, normalized, .{}, .reference);
}

pub fn encodeReference(allocator: std.mem.Allocator, values: anytype) Error!Owned {
    return buildReference(allocator, values);
}

pub fn buildForced(allocator: std.mem.Allocator, values: []const u32, options: Options, strategy: Strategy) Error!Owned {
    try options.validate();
    if (values.len > options.max_values) return error.LimitExceeded;
    if (strategy == .entropy and values.len == 0) return error.NotApplicable;
    const bytes = try encodeCandidate(allocator, values, options, strategy);
    return .{ .allocator = allocator, .bytes = bytes, .chosen = strategy };
}

fn encodeCandidate(allocator: std.mem.Allocator, values: []const u32, options: Options, strategy: Strategy) Error![]u8 {
    return switch (strategy) {
        .reference => encodeReferenceCandidate(allocator, values),
        .constant => encodeConstantCandidate(allocator, values),
        .runs => encodeRunsCandidate(allocator, values, options),
        .@"packed" => encodePackedCandidate(allocator, values, options),
        .entropy => encodeEntropyCandidate(allocator, values, options),
    };
}

fn candidateEnvelope(
    allocator: std.mem.Allocator,
    strategy: Strategy,
    count: usize,
    stride: usize,
    width: u8,
    checkpoints: []const u64,
    payload: []const u8,
) Error![]u8 {
    const index_len = try mul(checkpoints.len, @sizeOf(u64));
    const payload_at = try align8Checked(try add(header_size, index_len));
    const total = try add(payload_at, payload.len);
    const out = allocator.alloc(u8, total) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    @memset(out, 0);

    @memcpy(out[0..4], magic);
    writeLE(u16, out, 4, version);
    writeLE(u16, out, 6, header_size);
    out[8] = @intFromEnum(strategy);
    out[9] = 0;
    out[10] = width;
    out[11] = 0;
    writeLE(u64, out, 12, try asU64(count));
    writeLE(u32, out, 20, std.math.cast(u32, stride) orelse return error.Overflow);
    writeLE(u32, out, 24, std.math.cast(u32, checkpoints.len) orelse return error.Overflow);
    writeLE(u64, out, 28, header_size);
    writeLE(u64, out, 36, index_len);
    writeLE(u64, out, 44, try asU64(payload_at));
    writeLE(u64, out, 52, try asU64(payload.len));
    writeLE(u32, out, 60, 0);

    for (checkpoints, 0..) |offset, i| writeLE(u64, out, try indexedOffset(header_size, i, 8), offset);
    @memcpy(out[payload_at..][0..payload.len], payload);
    return out;
}

fn encodeReferenceCandidate(allocator: std.mem.Allocator, values: []const u32) Error![]u8 {
    const payload_len = try mul(values.len, 4);
    const payload = allocator.alloc(u8, payload_len) catch return error.OutOfMemory;
    defer allocator.free(payload);
    for (values, 0..) |value, i| writeLE(u32, payload, i * 4, value);
    return candidateEnvelope(allocator, .reference, values.len, 0, 32, &.{}, payload);
}

fn encodeConstantCandidate(allocator: std.mem.Allocator, values: []const u32) Error![]u8 {
    var payload: [4]u8 = undefined;
    if (values.len != 0) {
        for (values[1..]) |value| if (value != values[0]) return error.NotApplicable;
        writeLE(u32, &payload, 0, values[0]);
    } else {
        @memset(&payload, 0);
    }
    const used = if (values.len == 0) @as([]const u8, &.{}) else payload[0..];
    return candidateEnvelope(allocator, .constant, values.len, 0, 0, &.{}, used);
}

const Run = struct { value: u32, length: u64 };

fn runCount(values: []const u32) Error!usize {
    if (values.len == 0) return 0;
    var count: usize = 1;
    for (values[1..], 1..) |value, i| {
        if (value != values[i - 1]) count = try add(count, 1);
    }
    return count;
}

fn encodeRunsCandidate(allocator: std.mem.Allocator, values: []const u32, options: Options) Error![]u8 {
    const count = try runCount(values);
    if (values.len == 0 or count >= values.len) return error.NotApplicable;

    const runs = allocator.alloc(Run, count) catch return error.OutOfMemory;
    defer allocator.free(runs);
    var run_index: usize = 0;
    for (values) |value| {
        if (run_index == 0 or value != runs[run_index - 1].value) {
            runs[run_index] = .{ .value = value, .length = 1 };
            run_index += 1;
        } else runs[run_index - 1].length += 1;
    }

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendLE(u64, &payload, allocator, count);
    for (runs) |run| {
        try appendLE(u32, &payload, allocator, run.value);
        try appendLE(u32, &payload, allocator, 0);
        try appendLE(u64, &payload, allocator, run.length);
    }

    const checkpoint_count = try ceilDiv(values.len, options.checkpoint_stride);
    const checkpoints = allocator.alloc(u64, checkpoint_count) catch return error.OutOfMemory;
    defer allocator.free(checkpoints);
    var r: usize = 0;
    var position: usize = 0;
    for (0..checkpoint_count) |checkpoint| {
        const target = try mul(checkpoint, options.checkpoint_stride);
        while (r < runs.len and try add(position, @as(usize, @intCast(runs[r].length))) <= target) {
            position = try add(position, @as(usize, @intCast(runs[r].length)));
            r += 1;
        }
        const within = target - position;
        if (r > std.math.maxInt(u32) or within > std.math.maxInt(u32)) return error.Overflow;
        checkpoints[checkpoint] = (@as(u64, @intCast(r)) << 32) | @as(u64, @intCast(within));
    }
    return candidateEnvelope(allocator, .runs, values.len, options.checkpoint_stride, 0, checkpoints, payload.items);
}

fn encodePackedCandidate(allocator: std.mem.Allocator, values: []const u32, options: Options) Error![]u8 {
    if (values.len == 0) return error.NotApplicable;
    var base: u32 = values[0];
    var high: u64 = 0;
    for (values) |value| {
        base = @min(base, value);
    }
    for (values) |value| high = @max(high, @as(u64, value - base));
    const width = widthFor(high);
    const packed_len = try bitsFor(width, values.len);
    const payload_len = try add(4, packed_len);
    const payload = allocator.alloc(u8, payload_len) catch return error.OutOfMemory;
    defer allocator.free(payload);
    @memset(payload, 0);
    writeLE(u32, payload, 0, base);
    for (values, 0..) |value, i| try writeBits(payload[4..], i * width, width, value - base);

    const checkpoint_count = try ceilDiv(values.len, options.checkpoint_stride);
    const checkpoints = allocator.alloc(u64, checkpoint_count) catch return error.OutOfMemory;
    defer allocator.free(checkpoints);
    for (checkpoints, 0..) |*offset, checkpoint| {
        offset.* = try asU64(try mul(checkpoint, try mul(options.checkpoint_stride, width)));
    }
    return candidateEnvelope(allocator, .@"packed", values.len, options.checkpoint_stride, width, checkpoints, payload);
}

fn writeBits(bytes: []u8, bit_offset: usize, width: u8, value: u32) Error!void {
    if (width > 32) return error.InvalidEncoding;
    if (width == 0) {
        if (value != 0) return error.ValueOverflow;
        return;
    }
    const mask: u64 = if (width == 32) std.math.maxInt(u32) else (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
    if (@as(u64, value) & ~mask != 0) return error.ValueOverflow;
    const end = add(bit_offset, width) catch return error.Overflow;
    const capacity = mul(bytes.len, 8) catch return error.Overflow;
    if (end > capacity) return error.OutOfBounds;
    for (0..width) |bit| {
        const at = bit_offset + bit;
        const mask_bit: u8 = @as(u8, 1) << @as(u3, @intCast(at % 8));
        if ((value & (@as(u32, 1) << @as(u5, @intCast(bit)))) != 0) bytes[at / 8] |= mask_bit else bytes[at / 8] &= ~mask_bit;
    }
}

fn readBits(bytes: []const u8, bit_offset: usize, width: u8) Error!u32 {
    if (width > 32) return error.InvalidEncoding;
    const end = add(bit_offset, width) catch return error.Overflow;
    if (end > try mul(bytes.len, 8)) return error.OutOfBounds;
    var value: u32 = 0;
    for (0..width) |bit| {
        if ((bytes[(bit_offset + bit) / 8] & (@as(u8, 1) << @as(u3, @intCast((bit_offset + bit) % 8)))) != 0)
            value |= @as(u32, 1) << @as(u5, @intCast(bit));
    }
    return value;
}

fn appendLE(comptime T: type, list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: T) Error!void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    writeLE(T, &bytes, 0, value);
    list.appendSlice(allocator, &bytes) catch return error.OutOfMemory;
}

fn appendAlign8(list: *std.ArrayList(u8), allocator: std.mem.Allocator) Error!void {
    const aligned = try align8Checked(list.items.len);
    const padding = aligned - list.items.len;
    if (padding != 0) {
        const zeros = [_]u8{0} ** 8;
        list.appendSlice(allocator, zeros[0..padding]) catch return error.OutOfMemory;
    }
}

const Symbol = struct {
    value: u32,
    count: u64,
    frequency: u16 = 0,
    remainder: u64 = 0,
    cumulative: u32 = 0,
};

fn lessU32(_: void, a: u32, b: u32) bool {
    return a < b;
}

fn buildSymbols(allocator: std.mem.Allocator, values: []const u32, limit: usize) Error!struct { values: []u32, symbols: []Symbol } {
    const sorted = allocator.alloc(u32, values.len) catch return error.OutOfMemory;
    errdefer allocator.free(sorted);
    @memcpy(sorted, values);
    std.mem.sort(u32, sorted, {}, lessU32);

    var count: usize = 0;
    for (sorted, 0..) |value, i| {
        if (i == 0 or value != sorted[i - 1]) count = try add(count, 1);
    }
    if (count == 0 or count > limit or count > max_entropy_alphabet or count > rans_total) return error.NotApplicable;
    const symbols = allocator.alloc(Symbol, count) catch return error.OutOfMemory;
    errdefer allocator.free(symbols);
    var at: usize = 0;
    var i: usize = 0;
    while (i < sorted.len) {
        const value = sorted[i];
        var end = i + 1;
        while (end < sorted.len and sorted[end] == value) : (end += 1) {}
        symbols[at] = .{ .value = value, .count = try asU64(end - i) };
        at += 1;
        i = end;
    }
    return .{ .values = sorted, .symbols = symbols };
}

fn normalizeFrequencies(symbols: []Symbol, total_count: usize) Error!void {
    if (symbols.len == 0 or symbols.len > rans_total) return error.NotApplicable;
    const n = try asU64(total_count);
    const remaining = rans_total - @as(u32, @intCast(symbols.len));
    var assigned: u32 = 0;
    for (symbols) |*symbol| {
        const product: u128 = @as(u128, symbol.count) * @as(u128, remaining);
        const quotient: u64 = @intCast(product / n);
        symbol.frequency = @intCast(1 + quotient);
        symbol.remainder = @intCast(product % n);
        assigned += symbol.frequency;
    }
    var left = rans_total - assigned;
    while (left != 0) : (left -= 1) {
        var best: usize = 0;
        for (symbols[1..], 1..) |symbol, i| {
            if (symbol.remainder > symbols[best].remainder) best = i;
        }
        symbols[best].frequency += 1;
        // A selected remainder is set below the other candidates.  The
        // strictly deterministic tie-break is the lower value's table index.
        symbols[best].remainder = 0;
    }
    var cumulative: u32 = 0;
    for (symbols) |*symbol| {
        symbol.cumulative = cumulative;
        cumulative += symbol.frequency;
    }
    if (cumulative != rans_total) return error.RansFailure;
}

fn symbolIndex(symbols: []const Symbol, value: u32) Error!usize {
    var low: usize = 0;
    var high: usize = symbols.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (symbols[middle].value < value) low = middle + 1 else high = middle;
    }
    if (low == symbols.len or symbols[low].value != value) return error.RansFailure;
    return low;
}

fn encodeRansBlock(symbols: []const Symbol, values: []const u32, stream: *std.ArrayList(u8), allocator: std.mem.Allocator) Error!u32 {
    stream.clearRetainingCapacity();
    var emitted: std.ArrayList(u8) = .empty;
    defer emitted.deinit(allocator);
    var state: u32 = rans_l;
    var i = values.len;
    while (i != 0) {
        i -= 1;
        const index = try symbolIndex(symbols, values[i]);
        const symbol = symbols[index];
        const x_max: u64 = (@as(u64, rans_l >> rans_scale_bits) << 8) * symbol.frequency;
        while (@as(u64, state) >= x_max) {
            emitted.append(allocator, @truncate(state)) catch return error.OutOfMemory;
            state >>= 8;
        }
        const next: u64 = (@as(u64, state) / symbol.frequency) * rans_total + (@as(u64, state) % symbol.frequency) + symbol.cumulative;
        if (next > std.math.maxInt(u32)) return error.RansFailure;
        state = @intCast(next);
    }
    try appendLE(u32, stream, allocator, state);
    var e = emitted.items.len;
    while (e != 0) {
        e -= 1;
        stream.append(allocator, emitted.items[e]) catch return error.OutOfMemory;
    }
    return state;
}

fn encodeEntropyCandidate(allocator: std.mem.Allocator, values: []const u32, options: Options) Error![]u8 {
    if (values.len == 0) return error.NotApplicable;
    const built = try buildSymbols(allocator, values, options.max_entropy_alphabet);
    defer allocator.free(built.values);
    defer allocator.free(built.symbols);
    try normalizeFrequencies(built.symbols, values.len);

    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(allocator);
    try appendLE(u32, &payload, allocator, @intCast(built.symbols.len));
    try appendLE(u32, &payload, allocator, rans_total);
    const block_count = try ceilDiv(values.len, options.checkpoint_stride);
    try appendLE(u32, &payload, allocator, std.math.cast(u32, block_count) orelse return error.Overflow);
    try appendLE(u32, &payload, allocator, 0);
    for (built.symbols) |symbol| {
        try appendLE(u32, &payload, allocator, symbol.value);
        try appendLE(u16, &payload, allocator, symbol.frequency);
        try appendLE(u16, &payload, allocator, @intCast(symbol.cumulative));
    }
    try appendAlign8(&payload, allocator);

    const checkpoints = allocator.alloc(u64, block_count) catch return error.OutOfMemory;
    defer allocator.free(checkpoints);
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(allocator);
    for (0..block_count) |block| {
        try appendAlign8(&payload, allocator);
        checkpoints[block] = try asU64(payload.items.len);
        const start = try mul(block, options.checkpoint_stride);
        const end = @min(values.len, try add(start, options.checkpoint_stride));
        const state = try encodeRansBlock(built.symbols, values[start..end], &stream, allocator);
        try appendLE(u32, &payload, allocator, state);
        try appendLE(u32, &payload, allocator, std.math.cast(u32, stream.items.len - 4) orelse return error.Overflow);
        try payload.appendSlice(allocator, stream.items[4..]);
    }
    try appendAlign8(&payload, allocator);
    return candidateEnvelope(allocator, .entropy, values.len, options.checkpoint_stride, rans_scale_bits, checkpoints, payload.items);
}

pub const View = struct {
    bytes: []const u8,
    chosen: Strategy,
    count_: usize,
    stride_: usize,
    checkpoint_count_: usize,
    index_at: usize,
    payload_at: usize,
    payload_len: usize,
    width_: u8,
    entropy_table_at: usize = 0,
    entropy_alphabet: usize = 0,

    pub fn open(bytes: []const u8) Error!View {
        return openWithLimits(bytes, .{});
    }

    pub fn openWithLimits(bytes: []const u8, limits: Options) Error!View {
        var view = try openEnvelopeWithLimits(bytes, limits);
        try view.verify();
        return view;
    }

    /// Parse only the bounded envelope and representation-specific offsets.
    /// This does not walk packed values, run totals, or rANS symbols.  The
    /// returned view remains safe to probe: malformed payload bytes are
    /// reported by the read operation rather than being used as unchecked
    /// offsets. Call `verify` when a complete linear integrity pass is needed.
    pub fn openEnvelope(bytes: []const u8) Error!View {
        return openEnvelopeWithLimits(bytes, .{});
    }

    pub fn openEnvelopeWithLimits(bytes: []const u8, limits: Options) Error!View {
        try limits.validate();
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.BadMagic;
        if (try readLE(u16, bytes, 4) != version) return error.UnsupportedVersion;
        if (try readLE(u16, bytes, 6) != header_size) return error.InvalidEncoding;
        if (bytes[9] != 0 or bytes[11] != 0 or try readLE(u32, bytes, 60) != 0) return error.InvalidEncoding;

        const raw_strategy = bytes[8];
        if (raw_strategy > @intFromEnum(Strategy.entropy)) return error.UnsupportedStrategy;
        const chosen: Strategy = @enumFromInt(raw_strategy);
        const width = bytes[10];
        if (width > 32) return error.InvalidEncoding;
        const count_value = try asUsize(try readLE(u64, bytes, 12));
        if (count_value > limits.max_values) return error.LimitExceeded;
        const stride_u32 = try readLE(u32, bytes, 20);
        const stride = @as(usize, stride_u32);
        const checkpoint_count = try asUsize(try readLE(u32, bytes, 24));
        const index_offset = try asUsize(try readLE(u64, bytes, 28));
        const index_len = try asUsize(try readLE(u64, bytes, 36));
        const payload_at = try asUsize(try readLE(u64, bytes, 44));
        const payload_len = try asUsize(try readLE(u64, bytes, 52));
        const expected_index_len = try mul(checkpoint_count, 8);
        if (index_offset != header_size or index_len != expected_index_len) return error.InvalidEncoding;
        const index_end = try add(index_offset, index_len);
        if (payload_at != try align8Checked(index_end)) return error.InvalidEncoding;
        if (payload_at > bytes.len or payload_len > bytes.len - payload_at) return error.Truncated;
        if (payload_len != bytes.len - payload_at)
            return error.InvalidEncoding;
        for (bytes[index_end..payload_at]) |padding| if (padding != 0) return error.InvalidEncoding;
        if (stride_u32 == 0 and checkpoint_count != 0) return error.InvalidEncoding;
        if (stride_u32 != 0 and checkpoint_count != try ceilDiv(count_value, stride)) return error.InvalidEncoding;
        if (stride_u32 == 0 and count_value != 0 and chosen != .reference and chosen != .constant) return error.InvalidEncoding;
        if (chosen == .reference or chosen == .constant) {
            if (checkpoint_count != 0 or stride != 0) return error.InvalidEncoding;
        }

        var view = View{
            .bytes = bytes,
            .chosen = chosen,
            .count_ = count_value,
            .stride_ = stride,
            .checkpoint_count_ = checkpoint_count,
            .index_at = index_offset,
            .payload_at = payload_at,
            .payload_len = payload_len,
            .width_ = width,
        };
        switch (chosen) {
            .reference => try view.validateReference(),
            .constant => try view.validateConstant(),
            .@"packed" => try view.validatePackedEnvelope(),
            .runs => try view.validateRunsEnvelope(),
            .entropy => try view.validateEntropyEnvelope(limits.max_entropy_alphabet),
        }
        return view;
    }

    /// Complete linear integrity validation.  `open` calls this for the
    /// compatibility/safe default, while callers that need a cheap mapped
    /// open can use `openEnvelope` and defer this pass.
    pub fn verify(self: *const View) Error!void {
        switch (self.chosen) {
            .reference => try self.validateReference(),
            .constant => try self.validateConstant(),
            .@"packed" => try self.validatePacked(),
            .runs => try self.validateRuns(),
            .entropy => try self.validateEntropy(max_entropy_alphabet),
        }
    }

    pub fn count(self: *const View) usize {
        return self.count_;
    }

    pub fn strategy(self: *const View) Strategy {
        return self.chosen;
    }

    pub fn checkpointStride(self: *const View) usize {
        return self.stride_;
    }

    pub fn checkpointCount(self: *const View) usize {
        return self.checkpoint_count_;
    }

    pub fn checkpoint(self: *const View, index: usize) Error!Checkpoint {
        if (index >= self.checkpoint_count_) return error.OutOfBounds;
        const offset = try readLE(u64, self.bytes, try indexedOffset(self.index_at, index, 8));
        if (self.chosen == .entropy) {
            const at = try self.payloadOffset(offset);
            return .{ .offset = offset, .state = try readLE(u32, self.bytes, at) };
        }
        return .{ .offset = offset };
    }

    pub fn get(self: *const View, index: usize) Error!u32 {
        if (index >= self.count_) return error.OutOfBounds;
        return switch (self.chosen) {
            .reference => readLE(u32, self.bytes, try indexedOffset(self.payload_at, index, 4)),
            .constant => readLE(u32, self.bytes, self.payload_at),
            .@"packed" => self.getPacked(index),
            .runs => self.getRun(index),
            .entropy => self.getEntropy(index),
        };
    }

    /// Decode into caller-owned storage.  No allocations occur, including
    /// for rANS blocks; a too-small destination is reported before touching it.
    pub fn decode(self: *const View, out: []u32) Error!void {
        if (out.len < self.count_) return error.OutOfBounds;
        if (self.chosen == .entropy) {
            var written: usize = 0;
            for (0..self.checkpoint_count_) |block| {
                var cursor = try EntropyCursor.init(self, block);
                while (try cursor.next()) |value| {
                    out[written] = value;
                    written += 1;
                }
            }
            if (written != self.count_) return error.Corrupt;
            return;
        }
        for (0..self.count_) |i| out[i] = try self.get(i);
    }

    fn payload(self: *const View) []const u8 {
        return self.bytes[self.payload_at .. self.payload_at + self.payload_len];
    }

    fn payloadOffset(self: *const View, offset: u64) Error!usize {
        const relative = try asUsize(offset);
        if (relative > self.payload_len) return error.InvalidEncoding;
        return add(self.payload_at, relative);
    }

    fn indexValue(self: *const View, index: usize) Error!u64 {
        return readLE(u64, self.bytes, try indexedOffset(self.index_at, index, 8));
    }

    fn validateReference(self: *const View) Error!void {
        if (self.width_ != 32 or self.payload_len != try mul(self.count_, 4)) return error.InvalidEncoding;
    }

    fn validateConstant(self: *const View) Error!void {
        if (self.width_ != 0 or (self.count_ == 0 and self.payload_len != 0) or (self.count_ != 0 and self.payload_len != 4)) return error.InvalidEncoding;
    }

    fn validatePackedEnvelope(self: *const View) Error!void {
        if (self.count_ == 0 or self.payload_len < 4) return error.InvalidEncoding;
        const data_len = try bitsFor(self.width_, self.count_);
        if (self.payload_len != try add(4, data_len)) return error.InvalidEncoding;
    }

    fn validatePacked(self: *const View) Error!void {
        try self.validatePackedEnvelope();
        const data_len = self.payload_len - 4;
        const data = self.payload()[4..];
        const base = try readLE(u32, self.payload(), 0);
        for (0..self.checkpoint_count_) |cp_index| {
            const expected = try asU64(try mul(cp_index, try mul(self.stride_, self.width_)));
            if (try self.indexValue(cp_index) != expected) return error.InvalidEncoding;
        }
        const used = try mul(self.count_, self.width_);
        if (used % 8 != 0 and data_len != 0 and data[data_len - 1] >> @as(u3, @intCast(used % 8)) != 0) return error.InvalidEncoding;
        for (0..self.count_) |i| {
            const delta = try readBits(data, try mul(i, self.width_), self.width_);
            const reconstructed = std.math.add(u64, base, delta) catch return error.InvalidEncoding;
            if (reconstructed > std.math.maxInt(u32)) return error.InvalidEncoding;
        }
    }

    fn validateRunsEnvelope(self: *const View) Error!void {
        if (self.count_ == 0 or self.payload_len < 8) return error.InvalidEncoding;
        const run_count = try asUsize(try readLE(u64, self.payload(), 0));
        if (run_count == 0 or run_count > self.count_) return error.InvalidEncoding;
        const records_len = try mul(run_count, 16);
        if (self.payload_len != try add(8, records_len)) return error.InvalidEncoding;
    }

    fn validateRuns(self: *const View) Error!void {
        try self.validateRunsEnvelope();
        const run_count = try asUsize(try readLE(u64, self.payload(), 0));
        var total: usize = 0;
        var previous: ?u32 = null;
        for (0..run_count) |i| {
            const at = try indexedOffset(8, i, 16);
            const value = try readLE(u32, self.payload(), at);
            if (try readLE(u32, self.payload(), try add(at, 4)) != 0) return error.InvalidEncoding;
            const length = try asUsize(try readLE(u64, self.payload(), try add(at, 8)));
            if (length == 0 or (previous != null and previous.? == value)) return error.InvalidEncoding;
            previous = value;
            total = add(total, length) catch return error.InvalidEncoding;
            if (total > self.count_) return error.InvalidEncoding;
        }
        if (total != self.count_) return error.InvalidEncoding;
        var run: usize = 0;
        var position: usize = 0;
        for (0..self.checkpoint_count_) |cp_index| {
            const target = try mul(cp_index, self.stride_);
            while (run < run_count) {
                const record_at = try indexedOffset(8, run, 16);
                const length = try asUsize(try readLE(u64, self.payload(), try add(record_at, 8)));
                if (try add(position, length) > target) break;
                position = try add(position, length);
                run += 1;
            }
            const within = target - position;
            if (run > std.math.maxInt(u32) or within > std.math.maxInt(u32)) return error.InvalidEncoding;
            const expected = (@as(u64, try asU64(run)) << 32) | @as(u64, try asU64(within));
            if (try self.indexValue(cp_index) != expected) return error.InvalidEncoding;
        }
    }

    fn entropySymbol(self: *const View, slot: u32) Error!usize {
        var low: usize = 0;
        var high: usize = self.entropy_alphabet;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const at = try indexedOffset(self.entropy_table_at, middle, 8);
            const cumulative = try readLE(u16, self.bytes, try add(at, 6));
            if (slot < cumulative) high = middle else low = middle + 1;
        }
        if (low == 0 or low > self.entropy_alphabet) return error.InvalidEncoding;
        const index = low - 1;
        const at = try indexedOffset(self.entropy_table_at, index, 8);
        const cumulative = try readLE(u16, self.bytes, try add(at, 6));
        const frequency = try readLE(u16, self.bytes, try add(at, 4));
        if (slot < cumulative or slot >= @as(u32, cumulative) + frequency) return error.InvalidEncoding;
        return index;
    }

    fn entropySymbolData(self: *const View, index: usize) Error!Symbol {
        const at = try indexedOffset(self.entropy_table_at, index, 8);
        return .{
            .value = try readLE(u32, self.bytes, at),
            .count = 0,
            .frequency = try readLE(u16, self.bytes, try add(at, 4)),
            .cumulative = try readLE(u16, self.bytes, try add(at, 6)),
        };
    }

    /// Check the rANS table and block envelopes without decoding any symbols.
    /// Every public read remains bounds-safe after this pass, but semantic
    /// table and stream integrity belongs to `validateEntropy`/`verify`.
    fn validateEntropyEnvelope(self: *View, alphabet_limit: usize) Error!void {
        const payload_bytes = self.payload();
        if (self.width_ != rans_scale_bits or payload_bytes.len < 16) return error.InvalidEncoding;
        const alphabet = @as(usize, try readLE(u32, payload_bytes, 0));
        const total_frequency = try readLE(u32, payload_bytes, 4);
        const block_count = @as(usize, try readLE(u32, payload_bytes, 8));
        if (alphabet == 0 or alphabet > alphabet_limit or alphabet > max_entropy_alphabet or alphabet > rans_total or
            total_frequency != rans_total or block_count != self.checkpoint_count_ or self.count_ == 0) return error.InvalidEncoding;
        if (try readLE(u32, payload_bytes, 12) != 0) return error.InvalidEncoding;
        const table_end = try add(16, try mul(alphabet, 8));
        const first_block = try align8Checked(table_end);
        if (first_block > payload_bytes.len) return error.InvalidEncoding;
        for (payload_bytes[table_end..first_block]) |padding| if (padding != 0) return error.InvalidEncoding;

        self.entropy_table_at = try add(self.payload_at, 16);
        self.entropy_alphabet = alphabet;

        var expected = first_block;
        for (0..block_count) |block| {
            const offset = try asUsize(try self.indexValue(block));
            if (offset != expected or offset % 8 != 0) return error.InvalidEncoding;
            if (offset > payload_bytes.len or payload_bytes.len - offset < 8) return error.InvalidEncoding;
            const stream_len = try asUsize(try readLE(u32, payload_bytes, try add(offset, 4)));
            const stream_end = try add(offset, try add(8, stream_len));
            if (stream_end > payload_bytes.len) return error.InvalidEncoding;
            const next = try align8Checked(stream_end);
            if (block + 1 == block_count) {
                if (next != payload_bytes.len) return error.InvalidEncoding;
            } else if (next > payload_bytes.len) return error.InvalidEncoding;
            for (payload_bytes[stream_end..next]) |padding| if (padding != 0) return error.InvalidEncoding;
            expected = next;
        }
    }

    fn validateEntropy(self: *const View, alphabet_limit: usize) Error!void {
        const payload_bytes = self.payload();
        if (self.width_ != rans_scale_bits or payload_bytes.len < 16) return error.InvalidEncoding;
        const alphabet = @as(usize, try readLE(u32, payload_bytes, 0));
        const total_frequency = try readLE(u32, payload_bytes, 4);
        const block_count = @as(usize, try readLE(u32, payload_bytes, 8));
        if (alphabet == 0 or alphabet > alphabet_limit or alphabet > max_entropy_alphabet or alphabet > rans_total or
            total_frequency != rans_total or block_count != self.checkpoint_count_ or self.count_ == 0) return error.InvalidEncoding;
        if (try readLE(u32, payload_bytes, 12) != 0) return error.InvalidEncoding;
        const table_end = try add(16, try mul(alphabet, 8));
        const first_block = try align8Checked(table_end);
        if (first_block > payload_bytes.len) return error.InvalidEncoding;
        for (payload_bytes[table_end..first_block]) |padding| if (padding != 0) return error.InvalidEncoding;
        var cumulative: u32 = 0;
        var previous: ?u32 = null;
        for (0..alphabet) |i| {
            const at = try indexedOffset(16, i, 8);
            const value = try readLE(u32, payload_bytes, at);
            const frequency = try readLE(u16, payload_bytes, at + 4);
            if (cumulative > std.math.maxInt(u16) or
                try readLE(u16, payload_bytes, at + 6) != @as(u16, @intCast(cumulative)) or
                frequency == 0 or (previous != null and previous.? >= value)) return error.InvalidEncoding;
            previous = value;
            cumulative += frequency;
        }
        if (cumulative != rans_total) return error.InvalidEncoding;
        var expected = first_block;
        for (0..block_count) |block| {
            const offset = try asUsize(try self.indexValue(block));
            if (offset != expected or offset % 8 != 0) return error.InvalidEncoding;
            if (offset > payload_bytes.len or payload_bytes.len - offset < 8) return error.InvalidEncoding;
            const stream_len = try asUsize(try readLE(u32, payload_bytes, try add(offset, 4)));
            const stream_end = try add(offset, try add(8, stream_len));
            if (stream_end > payload_bytes.len) return error.InvalidEncoding;
            const next = try align8Checked(stream_end);
            if (block + 1 == block_count) {
                if (next != payload_bytes.len) return error.InvalidEncoding;
            } else if (next > payload_bytes.len) return error.InvalidEncoding;
            for (payload_bytes[stream_end..next]) |padding| if (padding != 0) return error.InvalidEncoding;
            const symbol_start = try mul(block, self.stride_);
            const take = @min(self.stride_, self.count_ - symbol_start);
            try self.validateRansBlock(block, take);
            expected = next;
        }
    }

    fn validateRansBlock(self: *const View, block: usize, symbol_count: usize) Error!void {
        var cursor = try EntropyCursor.init(self, block);
        var decoded: usize = 0;
        while (try cursor.next()) |_| decoded += 1;
        if (decoded != symbol_count) return error.InvalidEncoding;
    }

    fn getPacked(self: *const View, index: usize) Error!u32 {
        const base = try readLE(u32, self.payload(), 0);
        const data = self.payload()[4..];
        const delta = try readBits(data, try mul(index, self.width_), self.width_);
        return std.math.add(u32, base, delta) catch error.Corrupt;
    }

    fn getRun(self: *const View, index: usize) Error!u32 {
        const run_count = try asUsize(try readLE(u64, self.payload(), 0));
        const cp_index = index / self.stride_;
        const checkpoint_value = try self.indexValue(cp_index);
        const run = try asUsize(checkpoint_value >> 32);
        const target = try mul(cp_index, self.stride_);
        const within = try asUsize(checkpoint_value & std.math.maxInt(u32));
        if (within > target) return error.Corrupt;
        var position = target - within;
        var current_run = run;
        while (current_run < run_count) : (current_run += 1) {
            const at = try indexedOffset(8, current_run, 16);
            const length = try asUsize(try readLE(u64, self.payload(), try add(at, 8)));
            if (index < try add(position, length)) return try readLE(u32, self.payload(), at);
            position = try add(position, length);
        }
        return error.Corrupt;
    }

    fn getEntropy(self: *const View, index: usize) Error!u32 {
        const block = index / self.stride_;
        var cursor = try EntropyCursor.init(self, block);
        const local = index % self.stride_;
        for (0..local + 1) |i| {
            const value = (try cursor.next()) orelse return error.Corrupt;
            if (i == local) return value;
        }
        unreachable;
    }

    const EntropyCursor = struct {
        view: *const View,
        state: u32,
        cursor: usize,
        end: usize,
        remaining: usize,

        fn init(view: *const View, block: usize) Error!EntropyCursor {
            if (block >= view.checkpoint_count_) return error.OutOfBounds;
            const offset = try asUsize(try view.indexValue(block));
            const stream_len = try asUsize(try readLE(u32, view.payload(), try add(offset, 4)));
            const start = try add(offset, 8);
            const end = try add(start, stream_len);
            if (end > view.payload_len) return error.InvalidEncoding;
            const first = try mul(block, view.stride_);
            return .{
                .view = view,
                .state = try readLE(u32, view.payload(), offset),
                .cursor = start,
                .end = end,
                .remaining = @min(view.stride_, view.count_ - first),
            };
        }

        fn next(self: *EntropyCursor) Error!?u32 {
            if (self.remaining == 0) {
                if (self.cursor != self.end or self.state != rans_l) return error.InvalidEncoding;
                return null;
            }
            if (self.state < rans_l) return error.InvalidEncoding;
            const slot = self.state & (rans_total - 1);
            const symbol_index = try self.view.entropySymbol(slot);
            const symbol = try self.view.entropySymbolData(symbol_index);
            self.state = try ransDecodeState(self.state, slot, symbol.frequency, symbol.cumulative);
            while (self.state < rans_l) {
                if (self.cursor >= self.end) return error.InvalidEncoding;
                self.state = (self.state << 8) | self.view.payload()[self.cursor];
                self.cursor += 1;
            }
            self.remaining -= 1;
            return symbol.value;
        }
    };
};

fn ransDecodeState(state: u32, slot: u32, frequency: u16, cumulative: u32) Error!u32 {
    const next: u64 = @as(u64, frequency) * (@as(u64, state) >> rans_scale_bits) + (slot - cumulative);
    if (next > std.math.maxInt(u32)) return error.InvalidEncoding;
    return @intCast(next);
}

test "entropy module compiles its public contract" {
    try std.testing.expectEqual(@as(usize, 64), header_size);
    try std.testing.expectEqual(@as(u32, 4096), rans_total);
}
