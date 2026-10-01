//! bz4_root.zig — Lane V's copy of Lane S's static root codec
//! (rootstatic.zig): the expansion arena + canonical length-limited Huffman
//! code, derived deterministically from g[] alone (no code-length table is
//! ever transmitted). Adapted from rootstatic.zig per PLAN.md's
//! copy-and-modify rule for another lane's owned file:
//!
//!  - No B4SD dump parsing (bz4 never touches that format); the expansion
//!    table is built directly from a rule list + g[].
//!  - The old range/rANS coder and old bespoke frame format are dropped;
//!    Lane S's own writeup recommends Huffman outright (within 0.5% of H0
//!    on every dump, no framing-per-block flush tax, no intrinsic division
//!    in the decode hot path), and bz4.zig defines its own frame (see
//!    PLAN's brief FORMAT section), not rootstatic's.
//!  - `buildExpansion` is changed to lay the FINAL arena out in descending-g
//!    order (hot symbols first, adjacent) instead of ascending-id
//!    (construction) order, per this lane's STARTUP SPEED brief: "Lane S
//!    found full-file decode is bound by arena cache misses ... lay the
//!    expansion arena out in descending-g order so hot expansions share
//!    cache lines." This also only retains symbols that are actually
//!    root-bearing (alphabet members); purely-structural (g=0) rules that
//!    exist only to build up other expansions are dropped from the final
//!    arena entirely once construction is done, shrinking it too.
//!
//! Pure Zig 0.16, std only. See LANE_S.md for the design rationale this
//! lane is reusing, and LANE_V.md for the before/after startup numbers.

const std = @import("std");

pub const Rule = struct { a: u32, b: u32 };

// ---------------------------------------------------------------------
// Alphabet: only symbols that actually occur as roots (g[s]>0) need a code.
// ---------------------------------------------------------------------

pub const Alphabet = struct {
    n: u32,
    id: []u32, // compact index -> real symbol id, ascending by real id
    count: []u64, // compact index -> g[s]
    total: u64,

    pub fn deinit(self: *Alphabet, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.count);
    }
};

pub fn buildAlphabet(alloc: std.mem.Allocator, g: []const u64) !Alphabet {
    var n: u32 = 0;
    for (g) |c| if (c != 0) {
        n += 1;
    };
    const id = try alloc.alloc(u32, n);
    errdefer alloc.free(id);
    const count = try alloc.alloc(u64, n);
    errdefer alloc.free(count);
    var w: u32 = 0;
    var total: u64 = 0;
    for (g, 0..) |c, s| if (c != 0) {
        id[w] = @intCast(s);
        count[w] = c;
        total += c;
        w += 1;
    };
    return .{ .n = n, .id = id, .count = count, .total = total };
}

pub fn h0Bytes(a: Alphabet) f64 {
    const m: f64 = @floatFromInt(a.total);
    var bits: f64 = 0;
    for (a.count) |c| {
        const f: f64 = @floatFromInt(c);
        bits -= f * @log2(f / m);
    }
    return bits / 8.0;
}

// ---------------------------------------------------------------------
// Expansion table: symbol id -> (offset, len) into one contiguous arena,
// laid out in descending-g order for decode-time cache locality (see
// module doc comment).
// ---------------------------------------------------------------------

pub const Expansion = struct {
    off: []u64, // real-id indexed, size = alphabet_size; valid only where g[s]>0
    len: []u32, // real-id indexed, size = alphabet_size; valid only where g[s]>0
    arena: []u8,
    arena_used: usize,

    pub fn deinit(self: *Expansion, alloc: std.mem.Allocator) void {
        alloc.free(self.off);
        alloc.free(self.len);
        alloc.free(self.arena);
    }
};

fn alphabetGDesc(a: Alphabet, x: u32, y: u32) bool {
    if (a.count[x] != a.count[y]) return a.count[x] > a.count[y];
    return a.id[x] < a.id[y];
}

/// No `io`/timing parameter: callers time the whole `Frame.open` (which
/// calls this) from the outside, per bz4.zig's API (see PLAN's brief:
/// "startup_ms (Frame.open)").
pub fn buildExpansion(alloc: std.mem.Allocator, rules: []const Rule, alphabet: Alphabet, alphabet_size: u32) !Expansion {
    const k = alphabet_size;

    // Pass 1 (construction order, children always < parent): a temporary
    // arena holding EVERY symbol's expansion, including purely-structural
    // (g=0) rules needed to build others. Freed once the final,
    // alphabet-only, descending-g arena is populated below.
    const tmp_off = try alloc.alloc(u64, k);
    defer alloc.free(tmp_off);
    const tmp_len = try alloc.alloc(u32, k);
    defer alloc.free(tmp_len);
    for (0..256) |i| {
        tmp_off[i] = i;
        tmp_len[i] = 1;
    }
    var total: u64 = 256;
    for (rules, 0..) |r, i| {
        const l = tmp_len[r.a] + tmp_len[r.b];
        tmp_len[256 + i] = l;
        total += l;
    }

    const tmp_arena = try alloc.alloc(u8, total);
    defer alloc.free(tmp_arena);
    for (0..256) |i| tmp_arena[i] = @intCast(i);
    var write: u64 = 256;
    for (rules, 0..) |r, i| {
        const id = 256 + i;
        tmp_off[id] = write;
        const la = tmp_len[r.a];
        const lb = tmp_len[r.b];
        @memcpy(tmp_arena[write .. write + la], tmp_arena[tmp_off[r.a] .. tmp_off[r.a] + la]);
        write += la;
        @memcpy(tmp_arena[write .. write + lb], tmp_arena[tmp_off[r.b] .. tmp_off[r.b] + lb]);
        write += lb;
    }
    std.debug.assert(write == total);

    // Pass 2: final arena, alphabet members only (g[s]>0), placed in
    // descending-g order so the hottest symbols end up adjacent.
    const off = try alloc.alloc(u64, k);
    errdefer alloc.free(off);
    @memset(off, 0);
    const len = try alloc.alloc(u32, k);
    errdefer alloc.free(len);
    @memset(len, 0);

    var order = try alloc.alloc(u32, alphabet.n);
    defer alloc.free(order);
    for (0..alphabet.n) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, alphabet, alphabetGDesc);

    var final_total: u64 = 0;
    for (order) |ci| final_total += tmp_len[alphabet.id[ci]];
    const arena = try alloc.alloc(u8, final_total + overscan_pad);
    errdefer alloc.free(arena);

    var fw: u64 = 0;
    for (order) |ci| {
        const real = alphabet.id[ci];
        const l = tmp_len[real];
        @memcpy(arena[fw .. fw + l], tmp_arena[tmp_off[real] .. tmp_off[real] + l]);
        off[real] = fw;
        len[real] = l;
        fw += l;
    }
    @memset(arena[fw .. fw + overscan_pad], 0);

    return .{ .off = off, .len = len, .arena = arena, .arena_used = fw };
}

pub const overscan_pad: usize = 64;

// ---------------------------------------------------------------------
// Canonical length-limited Huffman (identical construction to
// rootstatic.zig's -- see LANE_S.md for the design rationale).
// ---------------------------------------------------------------------

pub const huf_max_len: u6 = 24;
pub const huf_primary_bits: u6 = 12;
const huf_primary_size: usize = 1 << huf_primary_bits;
const leaf_flag: u32 = 0x8000_0000;

pub const Huffman = struct {
    alphabet_size: u32,
    n: u32,
    trivial_symbol: ?u32,
    length: []u8,
    code: []u32,

    primary_len: []u8,
    primary_sym: []u32,
    primary_sub: []u32,
    sub_len: []u8,
    sub_sym: []u32,
    sub_groups: u32,

    pub fn deinit(self: *Huffman, alloc: std.mem.Allocator) void {
        alloc.free(self.length);
        alloc.free(self.code);
        alloc.free(self.primary_len);
        alloc.free(self.primary_sym);
        alloc.free(self.primary_sub);
        alloc.free(self.sub_len);
        alloc.free(self.sub_sym);
    }

    pub inline fn decodeOneTable(self: *const Huffman, br: *BitReader) u32 {
        if (self.trivial_symbol) |s| return s;
        const peek = br.peek(huf_primary_bits);
        const plen = self.primary_len[peek];
        if (plen != 0) {
            br.consume(@intCast(plen));
            return self.primary_sym[peek];
        }
        const full = br.peek(huf_max_len);
        const suffix = full & ((@as(u32, 1) << @as(u5, @intCast(huf_max_len - huf_primary_bits))) - 1);
        const group = self.primary_sub[peek];
        const gi = group * (@as(u32, 1) << @as(u5, @intCast(huf_max_len - huf_primary_bits))) + suffix;
        const slen = self.sub_len[gi];
        br.consume(@intCast(slen));
        return self.sub_sym[gi];
    }
};

pub fn buildHuffman(alloc: std.mem.Allocator, a: Alphabet, alphabet_size: u32) !Huffman {
    const n = a.n;

    var huf = Huffman{
        .alphabet_size = alphabet_size,
        .n = n,
        .trivial_symbol = null,
        .length = try alloc.alloc(u8, @max(n, 1)),
        .code = try alloc.alloc(u32, @max(n, 1)),
        .primary_len = try alloc.alloc(u8, huf_primary_size),
        .primary_sym = try alloc.alloc(u32, huf_primary_size),
        .primary_sub = try alloc.alloc(u32, huf_primary_size),
        .sub_len = try alloc.alloc(u8, 1),
        .sub_sym = try alloc.alloc(u32, 1),
        .sub_groups = 0,
    };
    @memset(huf.primary_len, 0);
    @memset(huf.primary_sym, 0);
    @memset(huf.primary_sub, 0);

    if (n <= 1) {
        huf.trivial_symbol = if (n == 1) a.id[0] else 0;
        return huf;
    }

    const order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    for (0..n) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, a, struct {
        fn less(al: Alphabet, x: u32, y: u32) bool {
            if (al.count[x] != al.count[y]) return al.count[x] < al.count[y];
            return al.id[x] < al.id[y];
        }
    }.less);

    const total_nodes = 2 * @as(usize, n) - 1;
    const w = try alloc.alloc(u64, total_nodes);
    defer alloc.free(w);
    const parent = try alloc.alloc(u32, total_nodes);
    defer alloc.free(parent);
    for (0..n) |i| w[i] = a.count[order[i]];

    var li: usize = 0;
    var qj: usize = n;
    var next: usize = n;
    while (next < total_nodes) : (next += 1) {
        var picks: [2]usize = undefined;
        var pn: usize = 0;
        while (pn < 2) : (pn += 1) {
            const use_leaf = li < n and (qj >= next or w[li] <= w[qj]);
            if (use_leaf) {
                picks[pn] = li;
                li += 1;
            } else {
                picks[pn] = qj;
                qj += 1;
            }
        }
        w[next] = w[picks[0]] + w[picks[1]];
        parent[picks[0]] = @intCast(next);
        parent[picks[1]] = @intCast(next);
    }

    const depth = try alloc.alloc(u8, total_nodes);
    defer alloc.free(depth);
    depth[total_nodes - 1] = 0;
    var kk: usize = total_nodes - 1;
    while (kk > 0) {
        kk -= 1;
        const d = @as(u32, depth[parent[kk]]) + 1;
        depth[kk] = @intCast(@min(d, 255));
    }

    var length = try alloc.alloc(u8, n);
    for (0..n) |i| length[order[i]] = depth[i];

    var buckets = try alloc.alloc(std.ArrayList(u32), huf_max_len + 1);
    defer alloc.free(buckets);
    for (buckets) |*bk| bk.* = .empty;
    defer for (buckets) |*bk| bk.deinit(alloc);

    for (0..n) |ci| {
        if (length[ci] > huf_max_len) length[ci] = huf_max_len;
        try buckets[length[ci]].append(alloc, @intCast(ci));
    }

    var units: u64 = 0;
    for (0..n) |ci| units += @as(u64, 1) << @intCast(huf_max_len - length[ci]);
    const target: u64 = @as(u64, 1) << huf_max_len;
    while (units > target) {
        var l: u6 = huf_max_len - 1;
        while (buckets[l].items.len == 0) : (l -= 1) {
            if (l == 0) unreachable;
        }
        const ci = buckets[l].pop().?;
        length[ci] = l + 1;
        try buckets[l + 1].append(alloc, ci);
        units -= @as(u64, 1) << @intCast(huf_max_len - l - 1);
    }

    var bl_count = [_]u32{0} ** (huf_max_len + 2);
    for (0..n) |ci| bl_count[length[ci]] += 1;
    var first_code = [_]u32{0} ** (huf_max_len + 2);
    var code_acc: u32 = 0;
    for (1..huf_max_len + 1) |l| {
        code_acc = (code_acc + bl_count[l - 1]) << 1;
        first_code[l] = code_acc;
    }
    var code = try alloc.alloc(u32, n);
    for (1..huf_max_len + 1) |l| {
        std.mem.sort(u32, buckets[l].items, {}, std.sort.asc(u32));
        var c = first_code[l];
        for (buckets[l].items) |ci| {
            code[ci] = c;
            c += 1;
        }
    }

    alloc.free(huf.length);
    alloc.free(huf.code);
    huf.length = length;
    huf.code = code;

    try buildHuffmanDecodeTables(alloc, &huf, a);

    return huf;
}

fn buildHuffmanDecodeTables(alloc: std.mem.Allocator, huf: *Huffman, a: Alphabet) !void {
    const n = a.n;
    var prefix_set = std.AutoHashMap(u32, void).init(alloc);
    defer prefix_set.deinit();

    for (0..n) |ci| {
        const len = huf.length[ci];
        const c = huf.code[ci];
        const real = a.id[ci];
        if (len <= huf_primary_bits) {
            const base = c << @intCast(huf_primary_bits - len);
            const count = @as(u32, 1) << @intCast(huf_primary_bits - len);
            var v: u32 = 0;
            while (v < count) : (v += 1) {
                huf.primary_len[base + v] = len;
                huf.primary_sym[base + v] = real;
            }
        } else {
            const prefix = c >> @intCast(len - huf_primary_bits);
            try prefix_set.put(prefix, {});
        }
    }

    const ngroups: u32 = prefix_set.count();
    const sub_span: u32 = @as(u32, 1) << @intCast(huf_max_len - huf_primary_bits);
    var sub_len = try alloc.alloc(u8, @as(usize, ngroups) * sub_span);
    var sub_sym = try alloc.alloc(u32, @as(usize, ngroups) * sub_span);
    @memset(sub_len, 0);
    @memset(sub_sym, 0);

    var prefixes = try alloc.alloc(u32, ngroups);
    defer alloc.free(prefixes);
    {
        var it = prefix_set.keyIterator();
        var i: usize = 0;
        while (it.next()) |kptr| : (i += 1) prefixes[i] = kptr.*;
    }
    std.mem.sort(u32, prefixes, {}, std.sort.asc(u32));
    var group_of_prefix = std.AutoHashMap(u32, u32).init(alloc);
    defer group_of_prefix.deinit();
    for (prefixes, 0..) |p, gi| try group_of_prefix.put(p, @intCast(gi));

    for (0..n) |ci| {
        const len = huf.length[ci];
        if (len <= huf_primary_bits) continue;
        const c = huf.code[ci];
        const real = a.id[ci];
        const prefix = c >> @intCast(len - huf_primary_bits);
        const gi = group_of_prefix.get(prefix).?;
        huf.primary_len[prefix] = 0;
        huf.primary_sub[prefix] = gi;
        const extra_len: u6 = @intCast(len - huf_primary_bits);
        const suffix = c & ((@as(u32, 1) << @as(u5, @intCast(extra_len))) - 1);
        const base = suffix << @intCast(huf_max_len - huf_primary_bits - extra_len);
        const count = @as(u32, 1) << @intCast(huf_max_len - huf_primary_bits - extra_len);
        var v: u32 = 0;
        while (v < count) : (v += 1) {
            sub_len[@as(usize, gi) * sub_span + base + v] = len;
            sub_sym[@as(usize, gi) * sub_span + base + v] = real;
        }
    }

    alloc.free(huf.sub_len);
    alloc.free(huf.sub_sym);
    huf.sub_len = sub_len;
    huf.sub_sym = sub_sym;
    huf.sub_groups = ngroups;
}

pub const HuffmanEncodeTable = struct {
    length: []u8,
    code: []u32,

    pub fn deinit(self: *HuffmanEncodeTable, alloc: std.mem.Allocator) void {
        alloc.free(self.length);
        alloc.free(self.code);
    }
};

pub fn buildHuffmanEncodeTable(alloc: std.mem.Allocator, huf: Huffman, a: Alphabet) !HuffmanEncodeTable {
    var length = try alloc.alloc(u8, huf.alphabet_size);
    var code = try alloc.alloc(u32, huf.alphabet_size);
    @memset(length, 0);
    @memset(code, 0);
    if (huf.trivial_symbol) |s| {
        length[s] = 0;
        return .{ .length = length, .code = code };
    }
    for (0..a.n) |ci| {
        length[a.id[ci]] = huf.length[ci];
        code[a.id[ci]] = huf.code[ci];
    }
    return .{ .length = length, .code = code };
}

// ---------------------------------------------------------------------
// Bit IO (identical to rootstatic.zig's).
// ---------------------------------------------------------------------

pub const BitWriter = struct {
    acc: u64 = 0,
    nbits: u6 = 0,
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn putBits(self: *BitWriter, value: u32, len: u6) !void {
        if (len == 0) return;
        self.acc = (self.acc << @intCast(len)) | @as(u64, value);
        self.nbits += len;
        while (self.nbits >= 8) {
            self.nbits -= 8;
            try self.out.append(self.alloc, @truncate(self.acc >> self.nbits));
        }
    }

    pub fn flushBlock(self: *BitWriter) !void {
        if (self.nbits > 0) {
            const pad: u6 = 8 - self.nbits;
            try self.out.append(self.alloc, @truncate((self.acc << pad) & 0xFF));
        }
        self.acc = 0;
        self.nbits = 0;
    }
};

pub const BitReader = struct {
    buf: u64 = 0,
    nbits: u7 = 0,
    data: []const u8,
    pos: usize = 0,

    pub fn init(data: []const u8) BitReader {
        var self = BitReader{ .data = data };
        self.refill();
        return self;
    }

    inline fn nextByte(self: *BitReader) u64 {
        const b: u64 = if (self.pos < self.data.len) self.data[self.pos] else 0;
        self.pos += 1;
        return b;
    }

    pub inline fn refill(self: *BitReader) void {
        while (self.nbits <= 56) {
            self.buf |= self.nextByte() << @intCast(56 - self.nbits);
            self.nbits += 8;
        }
    }

    pub inline fn peek(self: *BitReader, n: u6) u32 {
        const shift: u6 = @intCast(@as(u7, 64) - @as(u7, n));
        return @intCast(self.buf >> shift);
    }

    pub inline fn consume(self: *BitReader, n: u6) void {
        self.buf <<= n;
        self.nbits -= n;
        self.refill();
    }
};

test "expansion arena is descending-g ordered and byte-exact" {
    const alloc = std.testing.allocator;
    // rules: 256="ab" 257=256+'c'="abc" 258='a'+'a'="aa" (never a root)
    const rules = [_]Rule{
        .{ .a = 'a', .b = 'b' }, // 256 "ab"
        .{ .a = 256, .b = 'c' }, // 257 "abc"
        .{ .a = 'a', .b = 'a' }, // 258 "aa" -- purely structural, g=0
    };
    const k = 256 + rules.len;
    var g = [_]u64{0} ** k;
    g['a'] = 3;
    g[257] = 5; // "abc" is hot
    // 258 ("aa") never appears as a root.

    var alphabet = try buildAlphabet(alloc, &g);
    defer alphabet.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), alphabet.n); // 'a' and 257 only

    var exp = try buildExpansion(alloc, &rules, alphabet, @intCast(k));
    defer exp.deinit(alloc);

    // 257 ("abc") has higher g than 'a', so it must be placed first.
    try std.testing.expect(exp.off[257] < exp.off['a']);
    try std.testing.expectEqualSlices(u8, "abc", exp.arena[exp.off[257]..][0..3]);
    try std.testing.expectEqualSlices(u8, "a", exp.arena[exp.off['a']..][0..1]);
}
