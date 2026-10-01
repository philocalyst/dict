//! Second bounded `bzip4` experiment: block BWT -> MTF -> zero runs -> rANS.
//!
//! These are established compression components. The experiment asks whether
//! a small, charged, training-derived entropy model plus a straightforward
//! pure Zig inverse pipeline produces a better archive Pareto point than the
//! first shared-LZ candidate. It is not a novel codec or production format.

const std = @import("std");
const shared = @import("codec.zig");

pub const Owned = shared.Owned;
pub const magic = "B4BW";
pub const version: u8 = 1;
pub const header_size: usize = 40;
pub const directory_record_size: usize = 16;
pub const model_bytes: usize = 256 * @sizeOf(u16);
pub const probability_bits: u5 = 12;
pub const probability_total: u32 = 1 << probability_bits;
pub const rans_lower_bound: u32 = 1 << 23;
pub const max_block_bytes: usize = 64 * 1024;
pub const max_training_bytes: usize = 512 * 1024 * 1024;
pub const rans_decode_table_bytes: usize = probability_total;
/// Conservative sum of all fixed decode tables. Some have disjoint
/// lifetimes, but charging all keeps the published bound simple.
pub const decode_fixed_table_bytes: usize = @sizeOf(PreparedRansDecoder) +
    3 * 256 * @sizeOf(usize) + 256;

const BlockMode = enum(u8) { raw = 0, bwt = 1 };

pub const Limits = struct {
    max_frame_bytes: usize = 512 * 1024 * 1024,
    max_raw_bytes: usize = 512 * 1024 * 1024,
    max_block_bytes: usize = max_block_bytes,
    max_blocks: usize = 1_000_000,
    max_decode_accounted_bytes: usize = 512 * 1024 * 1024,
};

pub const Error = error{
    OutOfMemory,
    InvalidArgument,
    InputTooLarge,
    ResourceLimit,
    InvalidMagic,
    UnsupportedVersion,
    InvalidHeader,
    InvalidModel,
    InvalidDirectory,
    InvalidMode,
    InvalidPrimaryIndex,
    InvalidRansState,
    InvalidToken,
    NonCanonicalVarint,
    Truncated,
    TrailingBytes,
    ChecksumMismatch,
    OutputSizeMismatch,
    BlockOutOfRange,
};

pub const Model = struct {
    frequencies: [256]u16,

    pub fn validate(self: Model) Error!void {
        var total: u32 = 0;
        for (self.frequencies) |frequency| {
            if (frequency == 0) return error.InvalidModel;
            total += frequency;
        }
        if (total != probability_total) return error.InvalidModel;
    }

    pub fn write(self: Model, output: []u8) void {
        std.debug.assert(output.len == model_bytes);
        for (self.frequencies, 0..) |frequency, index| {
            std.mem.writeInt(u16, output[index * 2 ..][0..2], frequency, .little);
        }
    }

    pub fn read(input: []const u8) Error!Model {
        if (input.len != model_bytes) return error.InvalidModel;
        var result: Model = undefined;
        for (&result.frequencies, 0..) |*frequency, index| {
            frequency.* = std.mem.readInt(u16, input[index * 2 ..][0..2], .little);
        }
        try result.validate();
        return result;
    }
};

const Bwt = struct {
    allocator: std.mem.Allocator,
    last: []u8,
    primary: u32,

    fn deinit(self: *Bwt) void {
        self.allocator.free(self.last);
        self.* = undefined;
    }
};

fn checkedAdd(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch error.ResourceLimit;
}

fn checkedMul(a: usize, b: usize) Error!usize {
    return std.math.mul(usize, a, b) catch error.ResourceLimit;
}

fn checksum(bytes: []const u8) u32 {
    return std.hash.crc.Crc32.hash(bytes);
}

fn metadataChecksum(header: []const u8, model: []const u8, directory: []const u8) u32 {
    var crc = std.hash.crc.Crc32.init();
    crc.update(header);
    crc.update(model);
    crc.update(directory);
    return crc.final();
}

fn bwtTransform(allocator: std.mem.Allocator, input: []const u8) Error!Bwt {
    if (input.len == 0 or input.len > max_block_bytes) return error.InvalidArgument;
    const n = input.len;
    const positions_allocation = allocator.alloc(u32, n * 4) catch return error.OutOfMemory;
    defer allocator.free(positions_allocation);
    var positions = positions_allocation[0..n];
    var next_positions = positions_allocation[n .. n * 2];
    var classes = positions_allocation[n * 2 .. n * 3];
    var next_classes = positions_allocation[n * 3 .. n * 4];
    const counts = allocator.alloc(usize, @max(n, 256)) catch return error.OutOfMemory;
    defer allocator.free(counts);

    @memset(counts[0..256], 0);
    for (input) |byte| counts[byte] += 1;
    for (1..256) |index| counts[index] += counts[index - 1];
    var input_index = n;
    while (input_index != 0) {
        input_index -= 1;
        const byte = input[input_index];
        counts[byte] -= 1;
        positions[counts[byte]] = @intCast(input_index);
    }

    var class_count: usize = 1;
    classes[positions[0]] = 0;
    for (1..n) |index| {
        if (input[positions[index]] != input[positions[index - 1]]) class_count += 1;
        classes[positions[index]] = @intCast(class_count - 1);
    }

    var shift: usize = 1;
    while (shift < n) : (shift *= 2) {
        for (positions, 0..) |position_u32, index| {
            const position: usize = position_u32;
            next_positions[index] = @intCast(if (position >= shift) position - shift else position + n - shift);
        }
        @memset(counts[0..class_count], 0);
        for (next_positions) |position| counts[classes[position]] += 1;
        for (1..class_count) |index| counts[index] += counts[index - 1];
        var index = n;
        while (index != 0) {
            index -= 1;
            const position = next_positions[index];
            const class = classes[position];
            counts[class] -= 1;
            positions[counts[class]] = position;
        }

        var next_class_count: usize = 1;
        next_classes[positions[0]] = 0;
        for (1..n) |sorted_index| {
            const current: usize = positions[sorted_index];
            const previous: usize = positions[sorted_index - 1];
            const current_pair = .{ classes[current], classes[(current + shift) % n] };
            const previous_pair = .{ classes[previous], classes[(previous + shift) % n] };
            if (current_pair[0] != previous_pair[0] or current_pair[1] != previous_pair[1]) next_class_count += 1;
            next_classes[current] = @intCast(next_class_count - 1);
        }
        const old_classes = classes;
        classes = next_classes;
        next_classes = old_classes;
        class_count = next_class_count;
    }

    const last = allocator.alloc(u8, n) catch return error.OutOfMemory;
    errdefer allocator.free(last);
    var primary: ?u32 = null;
    for (positions, 0..) |position_u32, row| {
        const position: usize = position_u32;
        last[row] = input[if (position == 0) n - 1 else position - 1];
        if (position == 0) primary = @intCast(row);
    }
    return .{ .allocator = allocator, .last = last, .primary = primary orelse unreachable };
}

fn inverseBwt(allocator: std.mem.Allocator, last: []const u8, primary: usize, output: []u8) Error!void {
    if (last.len != output.len) return error.OutputSizeMismatch;
    if (primary >= last.len) return error.InvalidPrimaryIndex;
    var counts = [_]usize{0} ** 256;
    for (last) |byte| counts[byte] += 1;
    var starts: [256]usize = undefined;
    var sum: usize = 0;
    for (counts, 0..) |count, symbol| {
        starts[symbol] = sum;
        sum += count;
    }
    var seen = [_]usize{0} ** 256;
    const lf = allocator.alloc(u32, last.len) catch return error.OutOfMemory;
    defer allocator.free(lf);
    for (last, 0..) |byte, row| {
        lf[row] = @intCast(starts[byte] + seen[byte]);
        seen[byte] += 1;
    }
    var row = primary;
    var at = output.len;
    while (at != 0) {
        at -= 1;
        output[at] = last[row];
        row = lf[row];
    }
}

fn mtfEncode(input: []const u8, output: []u8) void {
    std.debug.assert(input.len == output.len);
    var symbols: [256]u8 = undefined;
    for (&symbols, 0..) |*symbol, index| symbol.* = @intCast(index);
    for (input, output) |byte, *rank| {
        var position: usize = 0;
        while (symbols[position] != byte) : (position += 1) {}
        rank.* = @intCast(position);
        while (position != 0) : (position -= 1) symbols[position] = symbols[position - 1];
        symbols[0] = byte;
    }
}

fn mtfDecode(input: []const u8, output: []u8) void {
    std.debug.assert(input.len == output.len);
    var symbols: [256]u8 = undefined;
    for (&symbols, 0..) |*symbol, index| symbol.* = @intCast(index);
    for (input, output) |rank, *byte| {
        const value = symbols[rank];
        byte.* = value;
        var position: usize = rank;
        while (position != 0) : (position -= 1) symbols[position] = symbols[position - 1];
        symbols[0] = value;
    }
}

fn appendByte(out: *std.ArrayList(u8), allocator: std.mem.Allocator, byte: u8) Error!void {
    out.append(allocator, byte) catch return error.OutOfMemory;
}

fn appendUleb(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: usize) Error!void {
    var remaining = value;
    while (remaining >= 0x80) {
        try appendByte(out, allocator, @as(u8, @truncate(remaining)) | 0x80);
        remaining >>= 7;
    }
    try appendByte(out, allocator, @intCast(remaining));
}

fn tokenizeZeros(allocator: std.mem.Allocator, mtf: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var at: usize = 0;
    while (at < mtf.len) {
        if (mtf[at] != 0) {
            try appendByte(&out, allocator, mtf[at]);
            at += 1;
            continue;
        }
        const start = at;
        while (at < mtf.len and mtf[at] == 0) : (at += 1) {}
        try appendByte(&out, allocator, 0);
        try appendUleb(&out, allocator, at - start);
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn readUleb(input: []const u8, at: *usize) Error!usize {
    var value: usize = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    const max_bytes = (@bitSizeOf(usize) + 6) / 7;
    while (count < max_bytes) : (count += 1) {
        if (at.* >= input.len) return error.Truncated;
        const byte = input[at.*];
        at.* += 1;
        const payload: usize = byte & 0x7f;
        if (shift >= @bitSizeOf(usize)) {
            if (payload != 0) return error.InvalidToken;
        } else {
            const shift_amount: std.math.Log2Int(usize) = @intCast(shift);
            if (payload > @as(usize, std.math.maxInt(usize)) >> shift_amount) return error.InvalidToken;
            value |= payload << shift_amount;
        }
        if ((byte & 0x80) == 0) {
            if (count != 0 and byte == 0) return error.NonCanonicalVarint;
            if (value == 0) return error.InvalidToken;
            return value;
        }
        shift +|= 7;
    }
    return error.InvalidToken;
}

fn expandZeros(tokens: []const u8, output: []u8) Error!void {
    var input_at: usize = 0;
    var output_at: usize = 0;
    while (input_at < tokens.len) {
        const token = tokens[input_at];
        input_at += 1;
        if (token != 0) {
            if (output_at >= output.len) return error.InvalidToken;
            output[output_at] = token;
            output_at += 1;
        } else {
            const run = try readUleb(tokens, &input_at);
            if (run > output.len - output_at) return error.InvalidToken;
            @memset(output[output_at..][0..run], 0);
            output_at += run;
        }
    }
    if (output_at != output.len) return error.OutputSizeMismatch;
}

fn modelCdf(model: Model, cdf: *[257]u16) void {
    cdf[0] = 0;
    for (model.frequencies, 0..) |frequency, symbol| cdf[symbol + 1] = cdf[symbol] + frequency;
}

fn ransEncode(allocator: std.mem.Allocator, input: []const u8, model: Model) Error![]u8 {
    try model.validate();
    var cdf: [257]u16 = undefined;
    modelCdf(model, &cdf);
    var state: u32 = rans_lower_bound;
    var emitted: std.ArrayList(u8) = .empty;
    defer emitted.deinit(allocator);
    var at = input.len;
    while (at != 0) {
        at -= 1;
        const symbol = input[at];
        const frequency: u32 = model.frequencies[symbol];
        const start: u32 = cdf[symbol];
        const max_state = ((rans_lower_bound >> probability_bits) << 8) * frequency;
        while (state >= max_state) {
            try appendByte(&emitted, allocator, @truncate(state));
            state >>= 8;
        }
        const next = (@as(u64, state / frequency) << probability_bits) + state % frequency + start;
        if (next > std.math.maxInt(u32)) return error.ResourceLimit;
        state = @intCast(next);
    }
    const output = allocator.alloc(u8, 4 + emitted.items.len) catch return error.OutOfMemory;
    std.mem.writeInt(u32, output[0..4], state, .little);
    for (0..emitted.items.len) |index| output[4 + index] = emitted.items[emitted.items.len - 1 - index];
    return output;
}

const PreparedRansDecoder = struct {
    model: Model,
    cdf: [257]u16,
    table: [probability_total]u8,

    fn init(model: Model) Error!PreparedRansDecoder {
        try model.validate();
        var result: PreparedRansDecoder = .{ .model = model, .cdf = undefined, .table = undefined };
        modelCdf(model, &result.cdf);
        for (model.frequencies, 0..) |frequency, symbol| {
            @memset(result.table[result.cdf[symbol] .. result.cdf[symbol] + frequency], @intCast(symbol));
        }
        return result;
    }

    fn decode(self: *const PreparedRansDecoder, encoded: []const u8, output: []u8) Error!void {
        if (encoded.len < 4) return error.Truncated;
        var state = std.mem.readInt(u32, encoded[0..4], .little);
        if (state < rans_lower_bound) return error.InvalidRansState;
        var input_at: usize = 4;
        for (output) |*byte| {
            const slot: u16 = @intCast(state & (probability_total - 1));
            const symbol = self.table[slot];
            byte.* = symbol;
            const frequency: u32 = self.model.frequencies[symbol];
            state = frequency * (state >> probability_bits) + slot - self.cdf[symbol];
            while (state < rans_lower_bound) {
                if (input_at >= encoded.len) return error.Truncated;
                state = (state << 8) | encoded[input_at];
                input_at += 1;
            }
        }
        if (input_at != encoded.len) return error.TrailingBytes;
        if (state != rans_lower_bound) return error.InvalidRansState;
    }
};

fn ransDecode(encoded: []const u8, model: Model, output: []u8) Error!void {
    const prepared = try PreparedRansDecoder.init(model);
    try prepared.decode(encoded, output);
}

fn countTrainingTokens(allocator: std.mem.Allocator, training: []const u8, block_bytes: usize, counts: *[256]u64) Error!void {
    var start: usize = 0;
    while (start < training.len) {
        const raw = training[start..][0..@min(block_bytes, training.len - start)];
        var transformed = try bwtTransform(allocator, raw);
        defer transformed.deinit();
        const mtf = allocator.alloc(u8, raw.len) catch return error.OutOfMemory;
        defer allocator.free(mtf);
        mtfEncode(transformed.last, mtf);
        const tokens = try tokenizeZeros(allocator, mtf);
        defer allocator.free(tokens);
        for (tokens) |token| counts[token] = std.math.add(u64, counts[token], 1) catch return error.ResourceLimit;
        start += raw.len;
    }
}

pub fn trainModel(allocator: std.mem.Allocator, training: []const u8, block_bytes: usize) Error!Model {
    if (training.len == 0 or block_bytes == 0 or block_bytes > max_block_bytes) return error.InvalidArgument;
    if (training.len > max_training_bytes) return error.InputTooLarge;
    var counts = [_]u64{0} ** 256;
    try countTrainingTokens(allocator, training, block_bytes, &counts);
    var count_total: u64 = 0;
    for (counts) |count| count_total = std.math.add(u64, count_total, count) catch return error.ResourceLimit;
    if (count_total == 0) return error.InvalidModel;
    const distributable: u64 = probability_total - 256;
    var model = Model{ .frequencies = [_]u16{1} ** 256 };
    var remainders: [256]u64 = undefined;
    var assigned: u32 = 256;
    for (counts, 0..) |count, symbol| {
        const product = std.math.mul(u64, count, distributable) catch return error.ResourceLimit;
        const extra: u16 = @intCast(product / count_total);
        model.frequencies[symbol] += extra;
        assigned += extra;
        remainders[symbol] = product % count_total;
    }
    while (assigned < probability_total) : (assigned += 1) {
        var best: usize = 0;
        for (1..256) |symbol| {
            if (remainders[symbol] > remainders[best]) best = symbol;
        }
        model.frequencies[best] += 1;
        remainders[best] = 0;
    }
    try model.validate();
    return model;
}

fn encodeBlock(allocator: std.mem.Allocator, raw: []const u8, model: Model) Error![]u8 {
    var transformed = try bwtTransform(allocator, raw);
    defer transformed.deinit();
    const mtf = allocator.alloc(u8, raw.len) catch return error.OutOfMemory;
    defer allocator.free(mtf);
    mtfEncode(transformed.last, mtf);
    const tokens = try tokenizeZeros(allocator, mtf);
    defer allocator.free(tokens);
    const entropy = try ransEncode(allocator, tokens, model);
    defer allocator.free(entropy);
    const output = allocator.alloc(u8, 9 + entropy.len) catch return error.OutOfMemory;
    output[0] = @intFromEnum(BlockMode.bwt);
    std.mem.writeInt(u32, output[1..5], transformed.primary, .little);
    std.mem.writeInt(u32, output[5..9], @intCast(tokens.len), .little);
    @memcpy(output[9..], entropy);
    return output;
}

pub fn encodeFrame(
    allocator: std.mem.Allocator,
    input: []const u8,
    model: Model,
    block_bytes: usize,
    limits: Limits,
) Error!Owned {
    try model.validate();
    if (block_bytes == 0 or block_bytes > limits.max_block_bytes or block_bytes > max_block_bytes) return error.InvalidArgument;
    if (input.len > limits.max_raw_bytes) return error.InputTooLarge;
    const block_count = if (input.len == 0) 0 else (input.len - 1) / block_bytes + 1;
    if (block_count > limits.max_blocks or block_count > std.math.maxInt(u32)) return error.ResourceLimit;
    const directory_len = try checkedMul(block_count, directory_record_size);
    const prefix_len = try checkedAdd(try checkedAdd(header_size, model_bytes), directory_len);
    if (prefix_len > limits.max_frame_bytes) return error.ResourceLimit;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    out.appendNTimes(allocator, 0, prefix_len) catch return error.OutOfMemory;
    model.write(out.items[header_size..][0..model_bytes]);
    const payload_base = prefix_len;
    for (0..block_count) |block_index| {
        const raw_start = block_index * block_bytes;
        const raw = input[raw_start..][0..@min(block_bytes, input.len - raw_start)];
        const compressed = try encodeBlock(allocator, raw, model);
        defer allocator.free(compressed);
        const relative_offset = out.items.len - payload_base;
        if (relative_offset > std.math.maxInt(u32)) return error.ResourceLimit;
        if (compressed.len < raw.len + 1) {
            out.appendSlice(allocator, compressed) catch return error.OutOfMemory;
        } else {
            try appendByte(&out, allocator, @intFromEnum(BlockMode.raw));
            out.appendSlice(allocator, raw) catch return error.OutOfMemory;
        }
        if (out.items.len > limits.max_frame_bytes) return error.ResourceLimit;
        const encoded_len = out.items.len - payload_base - relative_offset;
        if (relative_offset > std.math.maxInt(u32) or encoded_len > std.math.maxInt(u32) or raw.len > std.math.maxInt(u32))
            return error.ResourceLimit;
        const record = header_size + model_bytes + block_index * directory_record_size;
        writeU32(out.items, record, @intCast(relative_offset));
        writeU32(out.items, record + 4, @intCast(encoded_len));
        writeU32(out.items, record + 8, @intCast(raw.len));
        writeU32(out.items, record + 12, checksum(raw));
    }
    @memcpy(out.items[0..4], magic);
    out.items[4] = version;
    out.items[5] = 0;
    writeU16(out.items, 6, header_size);
    writeU32(out.items, 8, @intCast(block_bytes));
    writeU32(out.items, 12, @intCast(block_count));
    writeU64(out.items, 16, @intCast(input.len));
    writeU32(out.items, 24, model_bytes);
    writeU32(out.items, 28, probability_total);
    writeU32(out.items, 32, 0);
    writeU32(out.items, 36, metadataChecksum(
        out.items[0..36],
        out.items[header_size..][0..model_bytes],
        out.items[header_size + model_bytes .. prefix_len],
    ));
    return .{ .allocator = allocator, .bytes = out.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

pub const Frame = struct {
    bytes: []const u8,
    model: Model,
    model_wire: []const u8,
    directory: []const u8,
    payload: []const u8,
    block_bytes: usize,
    block_count: usize,
    raw_len: usize,
    limits: Limits,

    pub fn open(bytes: []const u8, limits: Limits) Error!Frame {
        if (bytes.len > limits.max_frame_bytes) return error.ResourceLimit;
        if (bytes.len < header_size) return error.Truncated;
        if (!std.mem.eql(u8, bytes[0..4], magic)) return error.InvalidMagic;
        if (bytes[4] != version) return error.UnsupportedVersion;
        if (bytes[5] != 0 or readU16(bytes, 6) != header_size or readU32(bytes, 24) != model_bytes or
            readU32(bytes, 28) != probability_total or readU32(bytes, 32) != 0) return error.InvalidHeader;
        const block_bytes: usize = readU32(bytes, 8);
        const block_count: usize = readU32(bytes, 12);
        const raw_len_u64 = readU64(bytes, 16);
        if (raw_len_u64 > std.math.maxInt(usize)) return error.ResourceLimit;
        const raw_len: usize = @intCast(raw_len_u64);
        if (block_bytes == 0 or block_bytes > limits.max_block_bytes or block_bytes > max_block_bytes) return error.InvalidHeader;
        if (block_count > limits.max_blocks or raw_len > limits.max_raw_bytes) return error.ResourceLimit;
        const expected_blocks = if (raw_len == 0) 0 else (raw_len - 1) / block_bytes + 1;
        if (block_count != expected_blocks) return error.InvalidHeader;
        const directory_len = try checkedMul(block_count, directory_record_size);
        const payload_at = try checkedAdd(try checkedAdd(header_size, model_bytes), directory_len);
        if (payload_at > bytes.len) return error.Truncated;
        const model_wire = bytes[header_size..][0..model_bytes];
        const model = try Model.read(model_wire);
        const directory = bytes[header_size + model_bytes .. payload_at];
        if (readU32(bytes, 36) != metadataChecksum(bytes[0..36], model_wire, directory)) return error.ChecksumMismatch;
        const payload = bytes[payload_at..];
        var offset_expected: usize = 0;
        var raw_total: usize = 0;
        for (0..block_count) |block_index| {
            const record = block_index * directory_record_size;
            const offset: usize = readU32(directory, record);
            const encoded_len: usize = readU32(directory, record + 4);
            const block_raw: usize = readU32(directory, record + 8);
            if (offset != offset_expected or encoded_len == 0 or block_raw == 0 or block_raw > block_bytes) return error.InvalidDirectory;
            if (block_index + 1 < block_count and block_raw != block_bytes) return error.InvalidDirectory;
            offset_expected = try checkedAdd(offset_expected, encoded_len);
            raw_total = try checkedAdd(raw_total, block_raw);
            if (offset_expected > payload.len) return error.Truncated;
        }
        if (offset_expected != payload.len) return error.TrailingBytes;
        if (raw_total != raw_len) return error.InvalidDirectory;
        return .{
            .bytes = bytes,
            .model = model,
            .model_wire = model_wire,
            .directory = directory,
            .payload = payload,
            .block_bytes = block_bytes,
            .block_count = block_count,
            .raw_len = raw_len,
            .limits = limits,
        };
    }

    pub fn blockEncodedLength(self: Frame, block_index: usize) Error!usize {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        return readU32(self.directory, block_index * directory_record_size + 4);
    }

    pub fn blockRawLength(self: Frame, block_index: usize) Error!usize {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        return readU32(self.directory, block_index * directory_record_size + 8);
    }

    fn decodeInto(
        self: Frame,
        allocator: std.mem.Allocator,
        prepared: *const PreparedRansDecoder,
        block_index: usize,
        output: []u8,
        live_output: usize,
    ) Error!void {
        if (block_index >= self.block_count) return error.BlockOutOfRange;
        const record = block_index * directory_record_size;
        const offset: usize = readU32(self.directory, record);
        const encoded_len: usize = readU32(self.directory, record + 4);
        const raw_len: usize = readU32(self.directory, record + 8);
        if (output.len != raw_len) return error.OutputSizeMismatch;
        const encoded = self.payload[offset..][0..encoded_len];
        const mode = std.enums.fromInt(BlockMode, encoded[0]) orelse return error.InvalidMode;
        switch (mode) {
            .raw => {
                if (encoded.len != raw_len + 1) return error.OutputSizeMismatch;
                @memcpy(output, encoded[1..]);
            },
            .bwt => {
                if (encoded.len < 13) return error.Truncated;
                const primary: usize = std.mem.readInt(u32, encoded[1..5], .little);
                if (primary >= raw_len) return error.InvalidPrimaryIndex;
                const token_len: usize = std.mem.readInt(u32, encoded[5..9], .little);
                const token_bound = try checkedAdd(try checkedMul(raw_len, 2), 4);
                if (token_len == 0 or token_len > token_bound) return error.ResourceLimit;
                const accounted = try checkedAdd(
                    try checkedAdd(live_output, token_len),
                    try checkedAdd(raw_len, try checkedAdd(try checkedMul(raw_len, 4), decode_fixed_table_bytes)),
                );
                if (accounted > self.limits.max_decode_accounted_bytes) return error.ResourceLimit;
                const tokens = allocator.alloc(u8, token_len) catch return error.OutOfMemory;
                defer allocator.free(tokens);
                try prepared.decode(encoded[9..], tokens);
                const last = allocator.alloc(u8, raw_len) catch return error.OutOfMemory;
                defer allocator.free(last);
                try expandZeros(tokens, last);
                // Safe in place: each rank is consumed before the same byte is
                // overwritten, while all future ranks remain untouched.
                mtfDecode(last, last);
                try inverseBwt(allocator, last, primary, output);
            },
        }
        if (checksum(output) != readU32(self.directory, record + 12)) return error.ChecksumMismatch;
    }

    pub fn decodeBlock(self: Frame, allocator: std.mem.Allocator, block_index: usize) Error!Owned {
        const raw_len = try self.blockRawLength(block_index);
        const base_accounted = try checkedAdd(raw_len, @sizeOf(PreparedRansDecoder));
        if (base_accounted > self.limits.max_decode_accounted_bytes) return error.ResourceLimit;
        const prepared = try PreparedRansDecoder.init(self.model);
        const output = allocator.alloc(u8, raw_len) catch return error.OutOfMemory;
        errdefer allocator.free(output);
        try self.decodeInto(allocator, &prepared, block_index, output, raw_len);
        return .{ .allocator = allocator, .bytes = output };
    }

    pub fn decodeAll(self: Frame, allocator: std.mem.Allocator) Error!Owned {
        const base_accounted = try checkedAdd(self.raw_len, @sizeOf(PreparedRansDecoder));
        if (base_accounted > self.limits.max_decode_accounted_bytes) return error.ResourceLimit;
        const prepared = try PreparedRansDecoder.init(self.model);
        const output = allocator.alloc(u8, self.raw_len) catch return error.OutOfMemory;
        errdefer allocator.free(output);
        var written: usize = 0;
        for (0..self.block_count) |block_index| {
            const block_len = try self.blockRawLength(block_index);
            try self.decodeInto(allocator, &prepared, block_index, output[written..][0..block_len], self.raw_len);
            written += block_len;
        }
        return .{ .allocator = allocator, .bytes = output };
    }
};

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}
fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
fn readU64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}
fn writeU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}
fn writeU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}
fn writeU64(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}

/// Deliberately simple test oracle: it finds each symbol by scanning the CDF,
/// rather than using the production decoder's inverse table.
fn referenceRansDecode(encoded: []const u8, model: Model, output: []u8) Error!void {
    try model.validate();
    if (encoded.len < 4) return error.Truncated;
    var cdf: [257]u16 = undefined;
    modelCdf(model, &cdf);
    var state = std.mem.readInt(u32, encoded[0..4], .little);
    if (state < rans_lower_bound) return error.InvalidRansState;
    var input_at: usize = 4;
    for (output) |*byte| {
        const slot: u16 = @intCast(state & (probability_total - 1));
        var symbol: usize = 0;
        while (symbol < 256 and slot >= cdf[symbol + 1]) : (symbol += 1) {}
        if (symbol == 256 or slot < cdf[symbol]) return error.InvalidRansState;
        byte.* = @intCast(symbol);
        const frequency: u32 = model.frequencies[symbol];
        state = frequency * (state >> probability_bits) + slot - cdf[symbol];
        while (state < rans_lower_bound) {
            if (input_at >= encoded.len) return error.Truncated;
            state = (state << 8) | encoded[input_at];
            input_at += 1;
        }
    }
    if (input_at != encoded.len) return error.TrailingBytes;
    if (state != rans_lower_bound) return error.InvalidRansState;
}

test "BWT MTF zero-run rANS components roundtrip" {
    const allocator = std.testing.allocator;
    const samples = [_][]const u8{ "banana", "aaaaaaaa", "日本語banana", "\x00\xff\x00binary" };
    for (samples) |sample| {
        var transformed = try bwtTransform(allocator, sample);
        defer transformed.deinit();
        const decoded_bwt = try allocator.alloc(u8, sample.len);
        defer allocator.free(decoded_bwt);
        try inverseBwt(allocator, transformed.last, transformed.primary, decoded_bwt);
        try std.testing.expectEqualSlices(u8, sample, decoded_bwt);

        const mtf = try allocator.alloc(u8, sample.len);
        defer allocator.free(mtf);
        mtfEncode(transformed.last, mtf);
        const tokens = try tokenizeZeros(allocator, mtf);
        defer allocator.free(tokens);
        const expanded = try allocator.alloc(u8, sample.len);
        defer allocator.free(expanded);
        try expandZeros(tokens, expanded);
        try std.testing.expectEqualSlices(u8, mtf, expanded);
        const model = try trainModel(allocator, sample, sample.len);
        const entropy = try ransEncode(allocator, tokens, model);
        defer allocator.free(entropy);
        const decoded_tokens = try allocator.alloc(u8, tokens.len);
        defer allocator.free(decoded_tokens);
        try ransDecode(entropy, model, decoded_tokens);
        try std.testing.expectEqualSlices(u8, tokens, decoded_tokens);
    }
}

test "frame exact roundtrip and independent block" {
    const allocator = std.testing.allocator;
    const training = "dictionary definition lexical context banana banana日本語 repeated repeated";
    const input = "banana banana definition\x00日本語--banana banana definition tail";
    const model = try trainModel(allocator, training, 16);
    var encoded = try encodeFrame(allocator, input, model, 16, .{});
    defer encoded.deinit();
    const frame = try Frame.open(encoded.bytes, .{});
    var decoded = try frame.decodeAll(allocator);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, input, decoded.bytes);
    var block = try frame.decodeBlock(allocator, 1);
    defer block.deinit();
    try std.testing.expectEqualSlices(u8, input[16..32], block.bytes);
}

test "rANS differential oracle covers nonuniform random sequences and exact termination" {
    const allocator = std.testing.allocator;
    const model = try trainModel(allocator, "eeeeeeeeeeeeeeeeeeeeeeetttttttttaaaaaaoinshrdlu0123456789", 32);
    try model.validate();
    var input: [4096]u8 = undefined;
    var state: u32 = 0x12345678;
    for (&input) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 16);
    }
    const encoded = try ransEncode(allocator, &input, model);
    defer allocator.free(encoded);
    var output: [input.len]u8 = undefined;
    try ransDecode(encoded, model, &output);
    try std.testing.expectEqualSlices(u8, &input, &output);
    var oracle_output: [input.len]u8 = undefined;
    try referenceRansDecode(encoded, model, &oracle_output);
    try std.testing.expectEqualSlices(u8, &input, &oracle_output);

    const tailed = try allocator.alloc(u8, encoded.len + 1);
    defer allocator.free(tailed);
    @memcpy(tailed[0..encoded.len], encoded);
    tailed[tailed.len - 1] = 0;
    try std.testing.expectError(error.TrailingBytes, ransDecode(tailed, model, &output));
    try std.testing.expectError(error.Truncated, ransDecode(encoded[0 .. encoded.len - 1], model, &output));
}

test "ULEB rejects noncanonical and overflowing aliases" {
    var at: usize = 0;
    try std.testing.expectError(error.NonCanonicalVarint, readUleb(&.{ 0x81, 0x00 }, &at));

    at = 0;
    if (@bitSizeOf(usize) == 64) {
        try std.testing.expectError(error.InvalidToken, readUleb(&.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x03 }, &at));
    } else {
        try std.testing.expectError(error.InvalidToken, readUleb(&.{ 0x80, 0x80, 0x80, 0x80, 0x11 }, &at));
    }

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try appendUleb(&encoded, std.testing.allocator, std.math.maxInt(usize));
    at = 0;
    try std.testing.expectEqual(std.math.maxInt(usize), try readUleb(encoded.items, &at));
    try std.testing.expectEqual(encoded.items.len, at);
}

test "frame is deterministic and rejects hostile metadata payload and budgets" {
    const allocator = std.testing.allocator;
    const training = "aaaaabbbbbaaaaabbbbb lexical lexical eeeeeeeeeeeeeeeeeeee";
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ** 3;
    const model = try trainModel(allocator, training, 32);
    var first = try encodeFrame(allocator, input, model, 64, .{});
    defer first.deinit();
    var second = try encodeFrame(allocator, input, model, 64, .{});
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    const frame = try Frame.open(first.bytes, .{});
    const payload_at = header_size + model_bytes + frame.block_count * directory_record_size;
    try std.testing.expectEqual(@intFromEnum(BlockMode.bwt), first.bytes[payload_at]);

    const damaged = try allocator.dupe(u8, first.bytes);
    defer allocator.free(damaged);
    writeU16(damaged, header_size, 0);
    try std.testing.expectError(error.InvalidModel, Frame.open(damaged, .{}));
    @memcpy(damaged, first.bytes);
    damaged[header_size + model_bytes] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, Frame.open(damaged, .{}));

    @memcpy(damaged, first.bytes);
    writeU32(damaged, payload_at + 1, std.math.maxInt(u32));
    const invalid_primary = try Frame.open(damaged, .{});
    try std.testing.expectError(error.InvalidPrimaryIndex, invalid_primary.decodeBlock(allocator, 0));

    @memcpy(damaged, first.bytes);
    damaged[payload_at + 9] ^= 0x40;
    const mutated_payload = try Frame.open(damaged, .{});
    if (mutated_payload.decodeAll(allocator)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |_| {}

    const tiny_budget = try Frame.open(first.bytes, .{ .max_decode_accounted_bytes = 1 });
    try std.testing.expectError(error.ResourceLimit, tiny_budget.decodeAll(allocator));

    const tailed = try allocator.alloc(u8, first.bytes.len + 1);
    defer allocator.free(tailed);
    @memcpy(tailed[0..first.bytes.len], first.bytes);
    tailed[tailed.len - 1] = 0;
    try std.testing.expectError(error.TrailingBytes, Frame.open(tailed, .{}));
}

test "raw fallback is framed and exact" {
    const allocator = std.testing.allocator;
    var randomish: [257]u8 = undefined;
    var state: u32 = 0x9e3779b9;
    for (&randomish) |*byte| {
        state = state *% 1103515245 +% 12345;
        byte.* = @truncate(state >> 16);
    }
    const model = try trainModel(allocator, "small training text", 16);
    var encoded = try encodeFrame(allocator, &randomish, model, 64, .{});
    defer encoded.deinit();
    const frame = try Frame.open(encoded.bytes, .{});
    const payload_at = header_size + model_bytes + frame.block_count * directory_record_size;
    try std.testing.expectEqual(@intFromEnum(BlockMode.raw), encoded.bytes[payload_at]);
    var decoded = try frame.decodeAll(allocator);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, &randomish, decoded.bytes);

    const output_only_budget = try Frame.open(encoded.bytes, .{ .max_decode_accounted_bytes = randomish.len });
    try std.testing.expectError(error.ResourceLimit, output_only_budget.decodeAll(allocator));

    var empty_encoded = try encodeFrame(allocator, "", model, 64, .{});
    defer empty_encoded.deinit();
    const empty = try Frame.open(empty_encoded.bytes, .{});
    var empty_decoded = try empty.decodeAll(allocator);
    defer empty_decoded.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_decoded.bytes.len);
    const empty_under_budget = try Frame.open(empty_encoded.bytes, .{ .max_decode_accounted_bytes = @sizeOf(PreparedRansDecoder) - 1 });
    try std.testing.expectError(error.ResourceLimit, empty_under_budget.decodeAll(allocator));
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    const training = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa repeated repeated repeated repeated";
    const input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ** 3;
    const model = try trainModel(allocator, training, 32);
    var encoded = try encodeFrame(allocator, input, model, 32, .{});
    defer encoded.deinit();
    const frame = try Frame.open(encoded.bytes, .{});
    try std.testing.expectEqual(@intFromEnum(BlockMode.bwt), frame.payload[0]);
    var decoded = try frame.decodeAll(allocator);
    defer decoded.deinit();
    try std.testing.expectEqualSlices(u8, input, decoded.bytes);
}

test "all allocation failures propagate" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationExercise, .{});
}
