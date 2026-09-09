//! Compact, directly addressable heuristic Re-Pair prose grammar.
//!
//! This module is the canonical compact grammar implementation.  Its wire
//! format has no fixed-width u32 symbol array and no fixed-width item records:
//! rules, symbols, item ends, and sparse alias targets are all bit-packed at
//! the minimum width required by the snapshot.  A mapped View borrows those
//! bytes and extraction never allocates.  Pair selection uses a deterministic,
//! bounded prefix sample per round: it preserves predictable compiler memory,
//! but is intentionally not exact global Re-Pair.

const std = @import("std");
const wire = @import("wire.zig");

pub const magic = "L4GC";
pub const version: u16 = 2;
pub const header_size: usize = 96;
pub const terminal_count: u32 = 256;
pub const no_alias: u64 = std.math.maxInt(u64);
pub const alias_checkpoint_stride: usize = 64;

pub const Error = error{
    InvalidOptions,
    InvalidInput,
    InvalidSymbol,
    InvalidRuleReference,
    CycleDetected,
    ExpansionOverflow,
    InvalidItemRange,
    InvalidAlias,
    OutputLimitExceeded,
    DecompressionBomb,
    StackLimitExceeded,
    OutputTooSmall,
    IndexOutOfBounds,
    Truncated,
    Malformed,
    UnsupportedVersion,
    SizeOverflow,
    OutOfMemory,
};

pub const Options = struct {
    max_items: usize = 1_000_000,
    // Pair replacement is an offline O(rounds × corpus) pass.  The round and
    // pair-sample budgets keep builds predictable; callers compiling archive
    // snapshots may raise either explicitly after measuring the corpus.
    max_rules: usize = 256,
    max_symbols: usize = 64 * 1024 * 1024,
    max_pair_occurrences: usize = 1_000_000,
    max_output_bytes: usize = 16 * 1024 * 1024,
    max_item_output_bytes: usize = 16 * 1024 * 1024,
    max_total_output_bytes: u64 = 512 * 1024 * 1024,
    max_rule_expansion_bytes: u64 = 64 * 1024 * 1024,
    max_expansion_steps: u64 = 128 * 1024 * 1024,

    fn validate(self: Options) Error!void {
        if (self.max_items == 0 or self.max_symbols == 0 or
            self.max_pair_occurrences == 0 or
            self.max_output_bytes == 0 or self.max_item_output_bytes == 0 or
            self.max_total_output_bytes == 0 or self.max_rule_expansion_bytes == 0 or
            self.max_expansion_steps == 0) return error.InvalidOptions;
        if (self.max_items > std.math.maxInt(u32) or self.max_rules > std.math.maxInt(u32) - terminal_count)
            return error.InvalidOptions;
    }

    fn itemLimit(self: Options) u64 {
        return @intCast(@min(self.max_output_bytes, self.max_item_output_bytes));
    }
};

pub const Limits = struct {
    max_items: usize = 1_000_000,
    max_rules: usize = 1_000_000,
    max_symbols: usize = 64 * 1024 * 1024,
    max_output_bytes: usize = 16 * 1024 * 1024,
    max_item_output_bytes: usize = 16 * 1024 * 1024,
    max_total_output_bytes: u64 = 512 * 1024 * 1024,
    max_rule_expansion_bytes: u64 = 64 * 1024 * 1024,
    max_expansion_steps: u64 = 128 * 1024 * 1024,

    fn validate(self: Limits) Error!void {
        if (self.max_items == 0 or self.max_symbols == 0 or
            self.max_output_bytes == 0 or self.max_item_output_bytes == 0 or
            self.max_total_output_bytes == 0 or self.max_rule_expansion_bytes == 0 or
            self.max_expansion_steps == 0) return error.InvalidOptions;
        if (self.max_items > std.math.maxInt(u32) or self.max_rules > std.math.maxInt(u32) - terminal_count)
            return error.InvalidOptions;
    }

    fn itemLimit(self: Limits) u64 {
        return @intCast(@min(self.max_output_bytes, self.max_item_output_bytes));
    }
};

pub const ItemInput = struct { text: []const u8 };

pub const Item = struct {
    sequence_start: u64,
    symbol_count: u64,
    output_len: u64,
    alias: ?usize,
};

pub const Rule = struct {
    left: u32,
    right: u32,
    expansion_len: u64,
};

/// Caller-owned pending-symbol storage. A sequence cursor stays in registers;
/// the stack contains only right siblings while we descend left through rules.
/// Slots are scratch, require no initialization, and carry no public state.
pub const Frame = enum(u32) { _ };

pub const AccessTrace = struct {
    item_records: usize = 0,
    rule_records: usize = 0,
    sequence_symbols: usize = 0,
    block_decodes: usize = 0,
    literal_pair_runs: usize = 0,
};

/// Optional named adapter for APIs that want a source object. `ViewFor` also
/// specializes directly for `[]const u8`, so standalone readers need no
/// wrapper. Authenticated hosts provide `len()` and `bytes(offset, length)`;
/// every packed read is then routed through that source.
pub const SliceSource = struct {
    data: []const u8,

    pub fn init(data: []const u8) SliceSource {
        return .{ .data = data };
    }
    pub fn len(self: *const SliceSource) usize {
        return self.data.len;
    }
    pub fn bytes(self: *const SliceSource, offset: usize, length: usize) Error![]const u8 {
        if (offset > self.data.len or length > self.data.len - offset) return error.Truncated;
        return self.data[offset..][0..length];
    }
};

pub const ReadRange = struct { offset: usize, length: usize };
pub const RangeKind = enum { rules, sequence, item_ends, alias_bits, alias_ranks, alias_targets };

fn packedRange(offset: usize, bit: usize, width: u8) Error!ReadRange {
    const first = try checkedAddSize(offset, bit / 8);
    const edge_bits = try checkedAddSize(try checkedAddSize(bit % 8, width), 7);
    return .{ .offset = first, .length = edge_bits / 8 };
}

pub const Owned = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    item_count: usize,
    rule_count: usize,

    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }
};

const WorkItem = struct {
    symbols: std.ArrayList(u32) = .empty,
    output_len: u64 = 0,
    alias: ?usize = null,
};

const ItemMeta = struct {
    end: u64,
    alias: ?usize,
};

const PairChoice = struct { left: u32, right: u32, count: usize };
const TextSlot = struct { hash: u64 = 0, index: usize = std.math.maxInt(usize) };
const PairSlot = struct { key: u64 = 0, count: usize = 0 };

fn hashBytes(bytes: []const u8) u64 {
    var hash: u64 = 14_695_981_039_346_656_037;
    for (bytes) |byte| {
        hash ^= byte;
        hash *%= 1_099_511_628_211;
    }
    return if (hash == 0) 1 else hash;
}

fn hashPair(value: u64) usize {
    var x = value;
    x ^= x >> 33;
    x *%= 0xff51_afd7_ed55_8ccd;
    x ^= x >> 33;
    x *%= 0xc4ce_b9fe_1a85_ec53;
    x ^= x >> 33;
    return @intCast(x);
}

fn checkedU64(value: usize) Error!u64 {
    return std.math.cast(u64, value) orelse error.SizeOverflow;
}
fn checkedAddU64(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.ExpansionOverflow;
}
fn checkedMulSize(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.SizeOverflow;
}
fn checkedAddSize(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.SizeOverflow;
}
fn toUsize(value: u64) Error!usize {
    return std.math.cast(usize, value) orelse error.SizeOverflow;
}

fn bitsFor(max_value: u64) u8 {
    if (max_value == 0) return 1;
    return @intCast(64 - @clz(max_value));
}

fn bytesForBits(bit_count: usize) Error!usize {
    if (bit_count == 0) return 0;
    const rounded = std.math.add(usize, bit_count, 7) catch return error.SizeOverflow;
    return rounded / 8;
}

fn maskFor(width: u8) u64 {
    if (width == 0) return 0;
    if (width == 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @as(u6, @intCast(width))) - 1;
}

fn readBits(bytes: []const u8, bit_offset: usize, width: u8) Error!u64 {
    return wire.readPacked(bytes, bit_offset, width) catch |err| switch (err) {
        error.Overflow => error.SizeOverflow,
        error.Truncated => error.Truncated,
        else => error.Malformed,
    };
}

/// A rule is one packed record, not three independent packed lookups. Most
/// dictionaries fit the complete record in a word: load its exact borrowed
/// byte window once, then derive both children and the length independently.
/// Wide records retain the same wire and checked reader; no padding overread
/// or extra authenticated range is needed for the fast path.
fn decodeRule(bytes: []const u8, bit: usize, symbol_bits: u8, length_bits: u8) Error!Rule {
    const children_bits = @as(usize, symbol_bits) * 2;
    const record_bits = children_bits + length_bits;
    if (record_bits <= 64) {
        const record = try readBits(bytes, bit, @intCast(record_bits));
        return .{
            .left = @intCast(record & maskFor(symbol_bits)),
            .right = @intCast((record >> @as(u6, @intCast(symbol_bits))) & maskFor(symbol_bits)),
            .expansion_len = record >> @as(u6, @intCast(children_bits)),
        };
    }
    return .{
        .left = @intCast(try readBits(bytes, bit, symbol_bits)),
        .right = @intCast(try readBits(bytes, try checkedAddSize(bit, symbol_bits), symbol_bits)),
        .expansion_len = try readBits(bytes, try checkedAddSize(bit, children_bits), length_bits),
    };
}

test "rule record decoding agrees across all bit alignments and wide records" {
    for ([_]u8{ 8, 9, 16, 31, 32 }) |symbols| {
        for ([_]u8{ 1, 7, 16, 32, 64 }) |lengths| {
            for (0..8) |offset| {
                var bytes = [_]u8{0} ** 17;
                const expected = Rule{
                    .left = @intCast(maskFor(symbols)),
                    .right = @intCast(maskFor(symbols) / 3),
                    .expansion_len = maskFor(lengths),
                };
                const length_bit = offset + @as(usize, symbols) * 2;
                writeBits(&bytes, offset, symbols, expected.left);
                writeBits(&bytes, offset + symbols, symbols, expected.right);
                writeBits(&bytes, length_bit, lengths, expected.expansion_len);
                const n = try bytesForBits(length_bit + lengths);
                try std.testing.expectEqualDeep(expected, try decodeRule(bytes[0..n], offset, symbols, lengths));
                try std.testing.expectError(error.Truncated, decodeRule(bytes[0 .. n - 1], offset, symbols, lengths));
            }
        }
    }
}

fn writeBits(bytes: []u8, bit_offset: usize, width: u8, value: u64) void {
    var i: usize = 0;
    while (i < width) : (i += 1) {
        if ((value & (@as(u64, 1) << @as(u6, @intCast(i)))) != 0)
            bytes[(bit_offset + i) / 8] |= @as(u8, 1) << @as(u3, @intCast((bit_offset + i) % 8));
    }
}

fn readLE(comptime T: type, bytes: []const u8, at: usize) Error!T {
    if (at > bytes.len or bytes.len - at < @sizeOf(T)) return error.Truncated;
    return std.mem.readInt(T, bytes[at..][0..@sizeOf(T)], .little);
}

fn writeLE(comptime T: type, bytes: []u8, at: usize, value: T) void {
    std.mem.writeInt(T, bytes[at..][0..@sizeOf(T)], value, .little);
}

const PairTable = struct {
    allocator: std.mem.Allocator,
    slots: []PairSlot,

    fn init(allocator: std.mem.Allocator, pair_count: usize) Error!PairTable {
        var needed = std.math.mul(usize, pair_count, 2) catch return error.SizeOverflow;
        needed = std.math.add(usize, needed, 1) catch return error.SizeOverflow;
        var capacity: usize = 1;
        while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch return error.SizeOverflow;
        const slots = allocator.alloc(PairSlot, capacity) catch return error.OutOfMemory;
        @memset(slots, .{});
        return .{ .allocator = allocator, .slots = slots };
    }

    fn deinit(self: *PairTable) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    fn add(self: *PairTable, left: u32, right: u32) void {
        const key = (@as(u64, left) << 32) | @as(u64, right);
        var at = hashPair(key) & (self.slots.len - 1);
        while (true) {
            const slot = &self.slots[at];
            if (slot.count == 0) {
                slot.* = .{ .key = key, .count = 1 };
                return;
            }
            if (slot.key == key) {
                slot.count += 1;
                return;
            }
            at = (at + 1) & (self.slots.len - 1);
        }
    }

    fn best(self: *const PairTable) ?PairChoice {
        var result: ?PairChoice = null;
        for (self.slots) |slot| {
            if (slot.count == 0) continue;
            const candidate = PairChoice{ .left = @truncate(slot.key >> 32), .right = @truncate(slot.key), .count = slot.count };
            if (result == null or candidate.count > result.?.count or
                (candidate.count == result.?.count and (candidate.left < result.?.left or
                    (candidate.left == result.?.left and candidate.right < result.?.right)))) result = candidate;
        }
        return result;
    }
};

fn symbolLength(symbol: u32, rules: []const Rule) Error!u64 {
    if (symbol < terminal_count) return 1;
    const index = symbol - terminal_count;
    if (index >= rules.len) return error.InvalidRuleReference;
    return rules[index].expansion_len;
}

fn findBestPair(allocator: std.mem.Allocator, work: []const WorkItem, max_symbols: usize, max_pair_occurrences: usize) Error!?PairChoice {
    var pair_count: usize = 0;
    for (work) |item| {
        if (item.alias != null or item.symbols.items.len < 2) continue;
        pair_count = std.math.add(usize, pair_count, item.symbols.items.len - 1) catch return error.SizeOverflow;
        if (pair_count > max_symbols) return error.OutputLimitExceeded;
    }
    if (pair_count == 0) return null;
    // A bounded occurrence sample keeps peak build memory proportional to the
    // grammar work budget on prose-heavy corpora.  This is deliberately a
    // deterministic heuristic Re-Pair round, not an exact global pair count:
    // a pair outside the sampled prefix can be the true best pair.  The cap
    // keeps a hostile unique corpus from demanding hundreds of megabytes just
    // to count one offline round.
    const sampled_pairs = @min(pair_count, max_pair_occurrences);
    var table = try PairTable.init(allocator, sampled_pairs);
    defer table.deinit();
    var seen_pairs: usize = 0;
    for (work) |item| {
        if (item.alias != null) continue;
        var i: usize = 1;
        while (i < item.symbols.items.len) : (i += 1) {
            if (seen_pairs == sampled_pairs) return table.best();
            table.add(item.symbols.items[i - 1], item.symbols.items[i]);
            seen_pairs += 1;
        }
    }
    return table.best();
}

fn replacePair(allocator: std.mem.Allocator, work: []WorkItem, choice: PairChoice, replacement: u32) Error!void {
    for (work) |*item| {
        if (item.alias != null or item.symbols.items.len < 2) continue;
        var next: std.ArrayList(u32) = .empty;
        errdefer next.deinit(allocator);
        try next.ensureTotalCapacity(allocator, item.symbols.items.len);
        var at: usize = 0;
        while (at < item.symbols.items.len) {
            if (at + 1 < item.symbols.items.len and item.symbols.items[at] == choice.left and item.symbols.items[at + 1] == choice.right) {
                try next.append(allocator, replacement);
                at += 2;
            } else {
                try next.append(allocator, item.symbols.items[at]);
                at += 1;
            }
        }
        var old = item.symbols;
        item.symbols = next;
        old.deinit(allocator);
    }
}

fn symbolWire(rule_index: usize) Error!u32 {
    const value = std.math.add(usize, rule_index, terminal_count) catch return error.SizeOverflow;
    return std.math.cast(u32, value) orelse error.SizeOverflow;
}

/// Build a compact wire snapshot with deterministic, bounded-sample Re-Pair.
///
/// Pair frequencies are counted over at most `max_pair_occurrences` adjacent
/// symbols per round. This is a reproducible compression heuristic, not exact
/// global Re-Pair; increasing the cap can improve ratio at compiler-time cost.
pub fn build(allocator: std.mem.Allocator, inputs: []const ItemInput, options: Options) Error!Owned {
    try options.validate();
    if (inputs.len > options.max_items) return error.OutputLimitExceeded;

    var work = allocator.alloc(WorkItem, inputs.len) catch return error.OutOfMemory;
    defer {
        for (work) |*item| item.symbols.deinit(allocator);
        allocator.free(work);
    }
    for (work) |*item| item.* = .{};

    var slots_capacity: usize = 1;
    const slot_target = std.math.mul(usize, @max(@as(usize, 1), inputs.len), 2) catch return error.SizeOverflow;
    while (slots_capacity < slot_target) slots_capacity = std.math.mul(usize, slots_capacity, 2) catch return error.SizeOverflow;
    const text_slots = allocator.alloc(TextSlot, slots_capacity) catch return error.OutOfMemory;
    defer allocator.free(text_slots);
    for (text_slots) |*slot| slot.* = .{};

    var total_output: u64 = 0;
    const item_limit = options.itemLimit();
    for (inputs, 0..) |input, index| {
        const length = checkedU64(input.text.len) catch return error.SizeOverflow;
        if (length > item_limit or length > options.max_rule_expansion_bytes) return error.OutputLimitExceeded;
        total_output = checkedAddU64(total_output, length) catch return error.OutputLimitExceeded;
        if (total_output > options.max_total_output_bytes) return error.OutputLimitExceeded;
        const hash = hashBytes(input.text);
        var at = hash & (text_slots.len - 1);
        while (true) {
            const slot = &text_slots[at];
            if (slot.index == std.math.maxInt(usize)) {
                slot.* = .{ .hash = hash, .index = index };
                break;
            }
            if (slot.hash == hash and std.mem.eql(u8, inputs[slot.index].text, input.text)) {
                work[index].alias = slot.index;
                break;
            }
            at = (at + 1) & (text_slots.len - 1);
        }
        work[index].output_len = length;
        if (work[index].alias == null) {
            try work[index].symbols.ensureTotalCapacity(allocator, input.text.len);
            for (input.text) |byte| try work[index].symbols.append(allocator, byte);
        }
    }

    var rules: std.ArrayList(Rule) = .empty;
    defer rules.deinit(allocator);
    while (rules.items.len < options.max_rules) {
        const choice = (try findBestPair(allocator, work, options.max_symbols, options.max_pair_occurrences)) orelse break;
        if (choice.count < 2) break;
        const left_len = try symbolLength(choice.left, rules.items);
        const right_len = try symbolLength(choice.right, rules.items);
        const expansion_len = try checkedAddU64(left_len, right_len);
        if (expansion_len > options.max_rule_expansion_bytes) break;
        const replacement = try symbolWire(rules.items.len);
        try rules.append(allocator, .{ .left = choice.left, .right = choice.right, .expansion_len = expansion_len });
        try replacePair(allocator, work, choice, replacement);
    }

    var sequence: std.ArrayList(u32) = .empty;
    defer sequence.deinit(allocator);
    var metas = allocator.alloc(ItemMeta, inputs.len) catch return error.OutOfMemory;
    defer allocator.free(metas);
    for (work, 0..) |*item, index| {
        if (item.alias) |target| {
            metas[index] = .{ .end = checkedU64(sequence.items.len) catch return error.SizeOverflow, .alias = target };
        } else {
            try sequence.appendSlice(allocator, item.symbols.items);
            metas[index] = .{ .end = checkedU64(sequence.items.len) catch return error.SizeOverflow, .alias = null };
        }
    }
    if (sequence.items.len > options.max_symbols) return error.OutputLimitExceeded;

    const sequence_count = checkedU64(sequence.items.len) catch return error.SizeOverflow;
    const rule_count_u64 = checkedU64(rules.items.len) catch return error.SizeOverflow;
    const alphabet_size = std.math.add(u64, terminal_count, rule_count_u64) catch return error.SizeOverflow;
    const symbol_bits = bitsFor(alphabet_size - 1);
    const seq_bits = bitsFor(sequence_count);
    const item_bits = bitsFor(if (inputs.len == 0) 0 else checkedU64(inputs.len - 1) catch return error.SizeOverflow);
    var max_rule_len: u64 = 0;
    for (rules.items) |rule| max_rule_len = @max(max_rule_len, rule.expansion_len);
    const length_bits = bitsFor(max_rule_len);
    const rule_bits = std.math.add(usize, std.math.add(usize, symbol_bits, symbol_bits) catch return error.SizeOverflow, length_bits) catch return error.SizeOverflow;
    const rules_bytes = try bytesForBits(checkedMulSize(rule_bits, rules.items.len) catch return error.SizeOverflow);
    const sequence_bytes = try bytesForBits(checkedMulSize(symbol_bits, sequence.items.len) catch return error.SizeOverflow);
    const ends_bytes = try bytesForBits(checkedMulSize(seq_bits, inputs.len) catch return error.SizeOverflow);
    var alias_count: usize = 0;
    for (metas) |meta| {
        if (meta.alias != null) alias_count += 1;
    }
    const alias_bits_bytes = if (alias_count == 0) 0 else try bytesForBits(inputs.len);
    const checkpoint_count = if (alias_count == 0) 0 else inputs.len / alias_checkpoint_stride + 1 + @intFromBool(inputs.len % alias_checkpoint_stride != 0);
    const alias_rank_bytes = try checkedMulSize(checkpoint_count, @sizeOf(u32));
    const alias_targets_bytes = try bytesForBits(checkedMulSize(item_bits, alias_count) catch return error.SizeOverflow);

    const rules_offset = header_size;
    const sequence_offset = try checkedAddSize(rules_offset, rules_bytes);
    const ends_offset = try checkedAddSize(sequence_offset, sequence_bytes);
    const alias_bits_offset = try checkedAddSize(ends_offset, ends_bytes);
    const alias_rank_offset = try checkedAddSize(alias_bits_offset, alias_bits_bytes);
    const alias_targets_offset = try checkedAddSize(alias_rank_offset, alias_rank_bytes);
    const total_size = try checkedAddSize(alias_targets_offset, alias_targets_bytes);

    var bytes = allocator.alloc(u8, total_size) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], magic);
    writeLE(u16, bytes, 4, version);
    writeLE(u16, bytes, 6, 0);
    writeLE(u32, bytes, 8, header_size);
    writeLE(u32, bytes, 12, @intCast(inputs.len));
    writeLE(u32, bytes, 16, @intCast(rules.items.len));
    writeLE(u64, bytes, 20, sequence_count);
    writeLE(u64, bytes, 28, checkedU64(alias_count) catch return error.SizeOverflow);
    bytes[36] = symbol_bits;
    bytes[37] = seq_bits;
    bytes[38] = item_bits;
    bytes[39] = length_bits;
    writeLE(u64, bytes, 40, @intCast(rules_offset));
    writeLE(u64, bytes, 48, @intCast(sequence_offset));
    writeLE(u64, bytes, 56, @intCast(ends_offset));
    writeLE(u64, bytes, 64, @intCast(alias_bits_offset));
    writeLE(u64, bytes, 72, @intCast(alias_rank_offset));
    writeLE(u64, bytes, 80, @intCast(alias_targets_offset));
    writeLE(u64, bytes, 88, @intCast(total_size));

    for (rules.items, 0..) |rule, i| {
        const bit = checkedMulSize(i, rule_bits) catch return error.SizeOverflow;
        writeBits(bytes[rules_offset .. rules_offset + rules_bytes], bit, symbol_bits, rule.left);
        writeBits(bytes[rules_offset .. rules_offset + rules_bytes], bit + symbol_bits, symbol_bits, rule.right);
        writeBits(bytes[rules_offset .. rules_offset + rules_bytes], bit + symbol_bits * 2, length_bits, rule.expansion_len);
    }
    for (sequence.items, 0..) |symbol, i| {
        const bit = checkedMulSize(i, symbol_bits) catch return error.SizeOverflow;
        writeBits(bytes[sequence_offset .. sequence_offset + sequence_bytes], bit, symbol_bits, symbol);
    }
    for (metas, 0..) |meta, i| {
        const bit = checkedMulSize(i, seq_bits) catch return error.SizeOverflow;
        writeBits(bytes[ends_offset .. ends_offset + ends_bytes], bit, seq_bits, meta.end);
    }
    var rank: usize = 0;
    if (alias_count != 0) {
        var i: usize = 0;
        while (i < inputs.len) : (i += 1) {
            if (i % alias_checkpoint_stride == 0) writeLE(u32, bytes, alias_rank_offset + (i / alias_checkpoint_stride) * 4, @intCast(rank));
            if (metas[i].alias != null) {
                bytes[alias_bits_offset + i / 8] |= @as(u8, 1) << @as(u3, @intCast(i % 8));
                rank += 1;
            }
        }
        writeLE(u32, bytes, alias_rank_offset + (checkpoint_count - 1) * 4, @intCast(rank));
    }
    rank = 0;
    for (metas, 0..) |meta, item_index| {
        if (meta.alias) |target| {
            _ = item_index;
            const bit = checkedMulSize(rank, item_bits) catch return error.SizeOverflow;
            writeBits(bytes[alias_targets_offset .. alias_targets_offset + alias_targets_bytes], bit, item_bits, target);
            rank += 1;
        }
    }
    return .{ .allocator = allocator, .bytes = bytes, .item_count = inputs.len, .rule_count = rules.items.len };
}

const ItemRaw = struct { start: u64, count: u64, alias: ?usize };

/// Execution depends on two scalar operations, not on where bytes live.
/// Zig specializes these bodies for the raw view, an authenticated ViewFor,
/// or the explicit *From adapter. Source errors propagate unchanged; neither
/// engine knows about self.bytes and so neither can bypass authentication.
fn measureSymbols(reader: anytype, limits: Limits, sequence_count: usize, start: u64, count: u64) !u64 {
    const begin = toUsize(start) catch return error.InvalidItemRange;
    const n = toUsize(count) catch return error.InvalidItemRange;
    if (begin > sequence_count or n > sequence_count - begin) return error.InvalidItemRange;
    var total: u64 = 0;
    for (0..n) |i| {
        const symbol = try reader.readSequence(begin + i, null);
        const length = if (symbol < terminal_count) 1 else (try reader.readRuleTraced(@intCast(symbol - terminal_count), null)).expansion_len;
        total = checkedAddU64(total, length) catch return error.ExpansionOverflow;
        if (total > limits.itemLimit()) return error.OutputLimitExceeded;
    }
    return total;
}

fn expandSymbols(reader: anytype, limits: Limits, rule_count: usize, raw: ItemRaw, out: []u8, wanted: usize, stack: []Frame, trace: ?*AccessTrace) !usize {
    if (wanted == 0) return 0;
    if (stack.len == 0) return error.StackLimitExceeded;
    var sequence = raw.start;
    var remaining = raw.count;
    var depth: usize = 0;
    var written: usize = 0;
    var steps: u64 = 0;
    render_loop: while (written < wanted) {
        var symbol: u32 = undefined;
        if (depth != 0) {
            depth -= 1;
            symbol = @intFromEnum(stack[depth]);
        } else {
            if (remaining == 0) break;
            try expansionStep(&steps, limits);
            symbol = try reader.readSequence(toUsize(sequence) catch return error.InvalidItemRange, trace);
            remaining -= 1;
            if (remaining != 0) sequence = checkedAddU64(sequence, 1) catch return error.InvalidItemRange;
        }
        // The left child is the next instruction, not a frame to push and
        // immediately pop. Both children come from the same packed rule load.
        while (true) {
            try expansionStep(&steps, limits);
            if (symbol < terminal_count) break;
            const rule_index = symbol - terminal_count;
            if (rule_index >= rule_count) return error.InvalidRuleReference;
            const rule = try reader.readRuleTraced(rule_index, trace);
            // A terminal pair is already completely authenticated by the
            // rule read. The one-byte snippet path retains the ordinary push.
            if (rule.left < terminal_count and rule.right < terminal_count and wanted - written >= 2) {
                try expansionStep(&steps, limits);
                try expansionStep(&steps, limits);
                if (written + 2 > out.len) return error.OutputLimitExceeded;
                out[written] = @intCast(rule.left);
                out[written + 1] = @intCast(rule.right);
                written += 2;
                if (trace) |t| t.literal_pair_runs += 1;
                continue :render_loop;
            }
            if (depth == stack.len) return error.StackLimitExceeded;
            stack[depth] = @enumFromInt(rule.right);
            depth += 1;
            symbol = rule.left;
        }
        if (written >= out.len) return error.OutputLimitExceeded;
        out[written] = @intCast(symbol);
        written += 1;
    }
    return written;
}

fn expansionStep(steps: *u64, limits: Limits) Error!void {
    steps.* = checkedAddU64(steps.*, 1) catch return error.DecompressionBomb;
    if (steps.* > limits.max_expansion_steps) return error.DecompressionBomb;
}

/// Rules are a topologically ordered straight-line program. Validate the
/// same recurrence that extraction uses, once, for every source contract.
fn validateRuleRecords(reader: anytype, limits: Limits, count: usize, length_bits: u8) !void {
    var max_length: u64 = 0;
    for (0..count) |index| {
        const value = try reader.readRuleTraced(index, null);
        for ([_]u32{ value.left, value.right }) |symbol| {
            if (symbol < terminal_count) continue;
            const ref = @as(usize, symbol - terminal_count);
            if (ref >= count) return error.InvalidRuleReference;
            if (ref >= index) return error.CycleDetected;
        }
        const left = if (value.left < terminal_count) 1 else (try reader.readRuleTraced(value.left - terminal_count, null)).expansion_len;
        const right = if (value.right < terminal_count) 1 else (try reader.readRuleTraced(value.right - terminal_count, null)).expansion_len;
        if (value.expansion_len != (checkedAddU64(left, right) catch return error.ExpansionOverflow)) return error.Malformed;
        if (value.expansion_len > limits.max_rule_expansion_bytes) return error.DecompressionBomb;
        max_length = @max(max_length, value.expansion_len);
    }
    if (length_bits != bitsFor(max_length)) return error.Malformed;
}

/// Alias checkpoints are exact prefix measures, not merely monotone hints.
/// Checking each checkpoint against the running measure prevents a valid-looking
/// backward alias from being redirected by a forged intermediate checkpoint.
fn validateItemRecords(reader: anytype, count: usize, sequence_count: usize, alias_count: usize) !void {
    var aliases: usize = 0;
    var previous: u64 = 0;
    for (0..count) |index| {
        if (index % alias_checkpoint_stride == 0 and try reader.aliasRankSlot(index / alias_checkpoint_stride) != aliases)
            return error.Malformed;
        const end = try reader.itemEnd(index);
        if (end < previous or end > sequence_count) return error.InvalidItemRange;
        if (try reader.aliasBit(index)) {
            if (end != previous) return error.InvalidItemRange;
            if (try reader.aliasTarget(index) >= index) return error.InvalidAlias;
            aliases += 1;
        }
        previous = end;
    }
    if (previous != sequence_count) return error.InvalidItemRange;
    if (aliases != alias_count) return error.Malformed;
    const final_slot = count / alias_checkpoint_stride + @intFromBool(count % alias_checkpoint_stride != 0);
    if (try reader.aliasRankSlot(final_slot) != aliases) return error.Malformed;
}

/// A source-backed reader for authenticated snapshot sections. `Source` is
/// either a byte slice or provides `len() usize` and
/// `bytes(offset, length) ![]const u8`. The source type is comptime, so every
/// read is statically dispatched; no callback or virtual interface is present
/// in extraction. `open` reads the 96-byte envelope only. Use `verify` for a
/// complete integrity walk, or render directly and authenticate only the
/// packed records touched by that operation.
pub fn ViewFor(comptime Source: type) type {
    return struct {
        source: Source,
        limits: Limits,
        item_count: usize,
        rule_count: usize,
        sequence_count: usize,
        alias_count: usize,
        symbol_bits: u8,
        seq_bits: u8,
        item_bits: u8,
        length_bits: u8,
        rules_offset: usize,
        rules_bytes: usize,
        sequence_offset: usize,
        sequence_bytes: usize,
        ends_offset: usize,
        ends_bytes: usize,
        alias_bits_offset: usize,
        alias_rank_offset: usize,
        alias_targets_offset: usize,
        alias_targets_bytes: usize,

        const Self = @This();
        const Raw = ItemRaw;

        fn sourceLen(source: Source) usize {
            if (comptime Source == []const u8 or Source == []u8) return source.len;
            return source.len();
        }

        fn sourceBytes(source: Source, offset: usize, length: usize) anyerror![]const u8 {
            if (comptime Source == []const u8 or Source == []u8) {
                if (offset > source.len or length > source.len - offset) return error.Truncated;
                return source[offset..][0..length];
            }
            return source.bytes(offset, length);
        }

        pub fn open(source: Source, limits: Limits) anyerror!Self {
            try limits.validate();
            if (sourceLen(source) < header_size) return error.Truncated;
            const header = try sourceBytes(source, 0, header_size);
            if (!std.mem.eql(u8, header[0..4], magic)) return error.Malformed;
            if (try readLE(u16, header, 4) != version) return error.UnsupportedVersion;
            if (try readLE(u16, header, 6) != 0 or try readLE(u32, header, 8) != header_size) return error.Malformed;
            const item_count = @as(usize, try readLE(u32, header, 12));
            const rule_count = @as(usize, try readLE(u32, header, 16));
            const sequence_count = try toUsize(try readLE(u64, header, 20));
            const alias_count = try toUsize(try readLE(u64, header, 28));
            const symbol_bits = header[36];
            const seq_bits = header[37];
            const item_bits = header[38];
            const length_bits = header[39];
            if (symbol_bits < 8 or symbol_bits > 32 or seq_bits == 0 or seq_bits > 64 or item_bits == 0 or item_bits > 64 or length_bits == 0 or length_bits > 64)
                return error.Malformed;
            if (alias_count > item_count or item_count > limits.max_items or rule_count > limits.max_rules or sequence_count > limits.max_symbols)
                return error.OutputLimitExceeded;
            const alphabet_size = std.math.add(u64, terminal_count, checkedU64(rule_count) catch return error.SizeOverflow) catch return error.SizeOverflow;
            if (symbol_bits != bitsFor(alphabet_size - 1) or seq_bits != bitsFor(try checkedU64(sequence_count)) or
                item_bits != bitsFor(if (item_count == 0) 0 else checkedU64(item_count - 1) catch return error.SizeOverflow)) return error.Malformed;
            const rule_bits = std.math.add(usize, std.math.add(usize, symbol_bits, symbol_bits) catch return error.SizeOverflow, length_bits) catch return error.SizeOverflow;
            const rules_bytes = try bytesForBits(checkedMulSize(rule_bits, rule_count) catch return error.SizeOverflow);
            const sequence_bytes = try bytesForBits(checkedMulSize(symbol_bits, sequence_count) catch return error.SizeOverflow);
            const ends_bytes = try bytesForBits(checkedMulSize(seq_bits, item_count) catch return error.SizeOverflow);
            const alias_bits_bytes = if (alias_count == 0) 0 else try bytesForBits(item_count);
            const checkpoint_count = if (alias_count == 0) 0 else item_count / alias_checkpoint_stride + 1 + @intFromBool(item_count % alias_checkpoint_stride != 0);
            const alias_rank_bytes = try checkedMulSize(checkpoint_count, 4);
            const alias_targets_bytes = try bytesForBits(checkedMulSize(item_bits, alias_count) catch return error.SizeOverflow);
            const rules_offset = try toUsize(try readLE(u64, header, 40));
            const sequence_offset = try toUsize(try readLE(u64, header, 48));
            const ends_offset = try toUsize(try readLE(u64, header, 56));
            const alias_bits_offset = try toUsize(try readLE(u64, header, 64));
            const alias_rank_offset = try toUsize(try readLE(u64, header, 72));
            const alias_targets_offset = try toUsize(try readLE(u64, header, 80));
            const total_size = try toUsize(try readLE(u64, header, 88));
            if (rules_offset != header_size or sequence_offset != try checkedAddSize(rules_offset, rules_bytes) or
                ends_offset != try checkedAddSize(sequence_offset, sequence_bytes) or alias_bits_offset != try checkedAddSize(ends_offset, ends_bytes) or
                alias_rank_offset != try checkedAddSize(alias_bits_offset, alias_bits_bytes) or alias_targets_offset != try checkedAddSize(alias_rank_offset, alias_rank_bytes) or
                total_size != try checkedAddSize(alias_targets_offset, alias_targets_bytes)) return error.Malformed;
            const source_len = sourceLen(source);
            if (total_size != source_len) return if (total_size > source_len) error.Truncated else error.Malformed;
            return .{ .source = source, .limits = limits, .item_count = item_count, .rule_count = rule_count, .sequence_count = sequence_count, .alias_count = alias_count, .symbol_bits = symbol_bits, .seq_bits = seq_bits, .item_bits = item_bits, .length_bits = length_bits, .rules_offset = rules_offset, .rules_bytes = rules_bytes, .sequence_offset = sequence_offset, .sequence_bytes = sequence_bytes, .ends_offset = ends_offset, .ends_bytes = ends_bytes, .alias_bits_offset = alias_bits_offset, .alias_rank_offset = alias_rank_offset, .alias_targets_offset = alias_targets_offset, .alias_targets_bytes = alias_targets_bytes };
        }

        pub const openEnvelope = open;

        fn ruleBitsValue(self: *const Self) usize {
            return @as(usize, self.symbol_bits) * 2 + self.length_bits;
        }

        fn readRule(self: *const Self, index: usize) anyerror!Rule {
            if (index >= self.rule_count) return error.IndexOutOfBounds;
            const bit = checkedMulSize(index, self.ruleBitsValue()) catch return error.SizeOverflow;
            const range = try packedRange(self.rules_offset, bit, @intCast(self.ruleBitsValue()));
            const bytes = try sourceBytes(self.source, range.offset, range.length);
            return decodeRule(bytes, bit % 8, self.symbol_bits, self.length_bits);
        }

        fn readSequence(self: *const Self, index: usize, trace: ?*AccessTrace) anyerror!u32 {
            if (index >= self.sequence_count) return error.InvalidItemRange;
            if (trace) |t| t.sequence_symbols += 1;
            const bit = checkedMulSize(index, self.symbol_bits) catch return error.SizeOverflow;
            const range = try packedRange(self.sequence_offset, bit, self.symbol_bits);
            const bytes = try sourceBytes(self.source, range.offset, range.length);
            return @intCast(try readBits(bytes, bit % 8, self.symbol_bits));
        }

        fn aliasBit(self: *const Self, index: usize) anyerror!bool {
            if (index >= self.item_count) return error.IndexOutOfBounds;
            if (self.alias_count == 0) return false;
            const offset = checkedAddSize(self.alias_bits_offset, index / 8) catch return error.SizeOverflow;
            const bytes = try sourceBytes(self.source, offset, 1);
            if (bytes.len < 1) return error.Truncated;
            return (bytes[0] & (@as(u8, 1) << @as(u3, @intCast(index % 8)))) != 0;
        }

        fn aliasRankBefore(self: *const Self, index: usize) anyerror!usize {
            if (index > self.item_count) return error.IndexOutOfBounds;
            if (self.alias_count == 0) return 0;
            const block = index / alias_checkpoint_stride;
            const checkpoint_offset = checkedAddSize(self.alias_rank_offset, checkedMulSize(block, 4) catch return error.SizeOverflow) catch return error.SizeOverflow;
            const checkpoint = try sourceBytes(self.source, checkpoint_offset, 4);
            var count: usize = std.mem.readInt(u32, checkpoint[0..4], .little);
            var i = checkedMulSize(block, alias_checkpoint_stride) catch return error.SizeOverflow;
            while (i < index) : (i += 1) {
                if (try self.aliasBit(i)) count += 1;
            }
            return count;
        }

        fn aliasTarget(self: *const Self, index: usize) anyerror!usize {
            if (!(try self.aliasBit(index))) return error.InvalidAlias;
            const ordinal = try self.aliasRankBefore(index);
            const bit = checkedMulSize(ordinal, self.item_bits) catch return error.SizeOverflow;
            const range = try packedRange(self.alias_targets_offset, bit, self.item_bits);
            const bytes = try sourceBytes(self.source, range.offset, range.length);
            return toUsize(try readBits(bytes, bit % 8, self.item_bits));
        }

        fn itemRaw(self: *const Self, index: usize, trace: ?*AccessTrace) anyerror!Raw {
            if (index >= self.item_count) return error.IndexOutOfBounds;
            if (trace) |t| t.item_records += 1;
            const end = try self.itemEnd(index);
            const previous = if (index == 0) 0 else try self.itemEnd(index - 1);
            if (end < previous or end > self.sequence_count) return error.InvalidItemRange;
            if (try self.aliasBit(index)) return .{ .start = 0, .count = 0, .alias = try self.aliasTarget(index) };
            return .{ .start = previous, .count = end - previous, .alias = null };
        }

        fn itemEnd(self: *const Self, index: usize) anyerror!u64 {
            if (index >= self.item_count) return error.IndexOutOfBounds;
            const bit = checkedMulSize(index, self.seq_bits) catch return error.SizeOverflow;
            const range = try packedRange(self.ends_offset, bit, self.seq_bits);
            const bytes = try sourceBytes(self.source, range.offset, range.length);
            return readBits(bytes, bit % 8, self.seq_bits);
        }

        fn aliasRankSlot(self: *const Self, slot: usize) anyerror!usize {
            if (self.alias_count == 0) return 0;
            const offset = try checkedAddSize(self.alias_rank_offset, try checkedMulSize(slot, 4));
            const bytes = try sourceBytes(self.source, offset, 4);
            return try readLE(u32, bytes, 0);
        }

        fn validateRules(self: *const Self) anyerror!void {
            return validateRuleRecords(self, self.limits, self.rule_count, self.length_bits);
        }

        fn validateMetadata(self: *const Self) anyerror!void {
            return validateItemRecords(self, self.item_count, self.sequence_count, self.alias_count);
        }

        fn measureRange(self: *const Self, start: u64, count: u64) anyerror!u64 {
            return measureSymbols(self, self.limits, self.sequence_count, start, count);
        }

        pub fn verify(self: *const Self) anyerror!void {
            try self.validateRules();
            try self.validateMetadata();
            for (0..self.sequence_count) |index| {
                const symbol = try self.readSequence(index, null);
                if (symbol >= terminal_count and @as(usize, symbol - terminal_count) >= self.rule_count) return error.InvalidRuleReference;
            }
            var total: u64 = 0;
            for (0..self.item_count) |index| {
                const raw = try self.primary(index, null);
                const length = try self.measureRange(raw.start, raw.count);
                total = checkedAddU64(total, length) catch return error.OutputLimitExceeded;
                if (total > self.limits.max_total_output_bytes) return error.OutputLimitExceeded;
            }
        }

        fn primary(self: *const Self, index: usize, trace: ?*AccessTrace) anyerror!Raw {
            var current = index;
            var raw = try self.itemRaw(current, trace);
            while (raw.alias) |target| {
                if (target >= current) return error.InvalidAlias;
                current = target;
                raw = try self.itemRaw(current, trace);
            }
            return raw;
        }

        fn readRuleTraced(self: *const Self, index: usize, trace: ?*AccessTrace) anyerror!Rule {
            if (trace) |t| t.rule_records += 1;
            return self.readRule(index);
        }

        fn expand(self: *const Self, raw: Raw, out: []u8, wanted: usize, stack: []Frame, trace: ?*AccessTrace) anyerror!usize {
            return expandSymbols(self, self.limits, self.rule_count, raw, out, wanted, stack, trace);
        }

        pub fn item(self: *const Self, index: usize) anyerror!Item {
            const raw = try self.itemRaw(index, null);
            const primary_raw = try self.primary(index, null);
            return .{ .sequence_start = raw.start, .symbol_count = raw.count, .output_len = try self.measureRange(primary_raw.start, primary_raw.count), .alias = raw.alias };
        }

        pub fn rule(self: *const Self, index: usize) anyerror!Rule {
            return self.readRule(index);
        }

        pub fn extract(self: *const Self, index: usize, out: []u8) anyerror!usize {
            var stack: [256]Frame = undefined;
            return self.extractWithStack(index, out, stack[0..]);
        }

        pub fn extractWithStack(self: *const Self, index: usize, out: []u8, stack: []Frame) anyerror!usize {
            const item_info = try self.item(index);
            const length = try toUsize(item_info.output_len);
            if (out.len < length) return error.OutputTooSmall;
            return self.expand(try self.primary(index, null), out, length, stack, null);
        }

        pub fn snippet(self: *const Self, index: usize, limit: usize, out: []u8) anyerror!usize {
            var stack: [256]Frame = undefined;
            return self.snippetWithStack(index, limit, out, stack[0..]);
        }

        pub fn snippetWithStack(self: *const Self, index: usize, limit: usize, out: []u8, stack: []Frame) anyerror!usize {
            const raw = try self.primary(index, null);
            const wanted = @min(limit, out.len);
            if (wanted == 0) return 0;
            return self.expand(raw, out, wanted, stack, null);
        }

        pub fn extractWithTrace(self: *const Self, index: usize, out: []u8, trace: *AccessTrace) anyerror!usize {
            var stack: [256]Frame = undefined;
            const raw = try self.primary(index, trace);
            const length = try self.measureRange(raw.start, raw.count);
            if (out.len < try toUsize(length)) return error.OutputTooSmall;
            return self.expand(raw, out, try toUsize(length), stack[0..], trace);
        }

        pub fn snippetWithTrace(self: *const Self, index: usize, limit: usize, out: []u8, trace: *AccessTrace) anyerror!usize {
            var stack: [256]Frame = undefined;
            const raw = try self.primary(index, trace);
            const wanted = @min(limit, out.len);
            if (wanted == 0) return 0;
            return self.expand(raw, out, wanted, stack[0..], trace);
        }

        pub fn directBlockDecodeCount(_: *const Self) usize {
            return 0;
        }
    };
}

pub const ReferenceOracle = struct {
    items: []const ItemInput,

    pub fn init(items: []const ItemInput) ReferenceOracle {
        return .{ .items = items };
    }
    pub fn item(self: *const ReferenceOracle, index: usize) Error![]const u8 {
        if (index >= self.items.len) return error.IndexOutOfBounds;
        return self.items[index].text;
    }
    pub fn extract(self: *const ReferenceOracle, index: usize, out: []u8) Error!usize {
        const text = try self.item(index);
        if (out.len < text.len) return error.OutputTooSmall;
        @memcpy(out[0..text.len], text);
        return text.len;
    }
    pub fn snippet(self: *const ReferenceOracle, index: usize, limit: usize, out: []u8) Error!usize {
        const text = try self.item(index);
        const n = @min(@min(limit, out.len), text.len);
        if (n != 0) @memcpy(out[0..n], text[0..n]);
        return n;
    }
};
