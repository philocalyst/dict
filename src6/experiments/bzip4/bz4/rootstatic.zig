//! rootstatic: static root-symbol codecs for Lane S of the bz4 lab.
//!
//! Everything here is a deterministic function of a B4SD dump's rules plus
//! the global per-symbol root counts g[] computed from it: the expansion
//! table (symbol -> byte span), a canonical length-limited Huffman code, and
//! a static range/rANS-style code with a power-of-two total. The decoder
//! rebuilds all tables from g alone; no code-length table is ever stored.
//!
//! The range coder core (RCEncoder/RCDecoder below) is a copy of rc.zig's
//! carryless 64-bit range coder, adapted with a power-of-two total (shift
//! instead of divide) for the static per-symbol model. Copied into this file
//! per PLAN.md's rule for shared files a lane needs to change.
//!
//! Pure Zig 0.16, std only. See PLAN.md and LANE_S.md.

const std = @import("std");

// ---------------------------------------------------------------------
// B4SD dump parsing (format owned by gprobe.zig; read-only contract here)
// ---------------------------------------------------------------------

pub const Rule = extern struct { a: u32, b: u32 };

pub const Dump = struct {
    rule_count: u32,
    block_count: u32,
    block_bytes: u32,
    raw_len: u32,
    rules: []Rule,
    seq: []u32, // concatenated root-symbol stream, all blocks back to back
    block_off: []u32, // start index into seq for block b
    block_len: []u32, // root count of block b

    pub fn alphabetSize(self: Dump) u32 {
        return 256 + self.rule_count;
    }

    pub fn deinit(self: *Dump, alloc: std.mem.Allocator) void {
        alloc.free(self.rules);
        alloc.free(self.seq);
        alloc.free(self.block_off);
        alloc.free(self.block_len);
    }
};

pub const DumpError = error{ Truncated, BadMagic, BadVersion };

pub fn parseDump(alloc: std.mem.Allocator, bytes: []const u8) !Dump {
    if (bytes.len < 24 or bytes.len % 4 != 0) return DumpError.Truncated;
    const words = std.mem.bytesAsSlice(u32, bytes);
    if (words[0] != 0x44533442) return DumpError.BadMagic;
    if (words[1] != 1) return DumpError.BadVersion;
    const rule_count = words[2];
    const block_count = words[3];
    const block_bytes = words[4];
    const raw_len = words[5];

    var idx: usize = 6;
    const rules = try alloc.alloc(Rule, rule_count);
    errdefer alloc.free(rules);
    for (0..rule_count) |i| {
        if (idx + 2 > words.len) return DumpError.Truncated;
        rules[i] = .{ .a = words[idx], .b = words[idx + 1] };
        idx += 2;
    }

    const block_off = try alloc.alloc(u32, block_count);
    errdefer alloc.free(block_off);
    const block_len = try alloc.alloc(u32, block_count);
    errdefer alloc.free(block_len);

    // First pass: read counts, tally total roots.
    var scan = idx;
    var total: usize = 0;
    for (0..block_count) |b| {
        if (scan >= words.len) return DumpError.Truncated;
        const cnt = words[scan];
        scan += 1;
        block_len[b] = cnt;
        total += cnt;
        scan += cnt;
    }
    if (scan > words.len) return DumpError.Truncated;

    const seq = try alloc.alloc(u32, total);
    errdefer alloc.free(seq);
    var write: usize = 0;
    for (0..block_count) |b| {
        block_off[b] = @intCast(write);
        const cnt = words[idx];
        idx += 1;
        @memcpy(seq[write .. write + cnt], words[idx .. idx + cnt]);
        idx += cnt;
        write += cnt;
    }

    return .{
        .rule_count = rule_count,
        .block_count = block_count,
        .block_bytes = block_bytes,
        .raw_len = raw_len,
        .rules = rules,
        .seq = seq,
        .block_off = block_off,
        .block_len = block_len,
    };
}

// ---------------------------------------------------------------------
// Expansion table: symbol id -> (offset, len) into one contiguous arena.
// Eager expansion, one forward pass (children always have smaller ids).
// ---------------------------------------------------------------------

pub const overscan_pad: usize = 64;

pub const Expansion = struct {
    off: []u64,
    len: []u32,
    arena: []u8, // padded with overscan_pad zero bytes past arena_used
    arena_used: usize,
    build_ns: u64,

    pub fn deinit(self: *Expansion, alloc: std.mem.Allocator) void {
        alloc.free(self.off);
        alloc.free(self.len);
        alloc.free(self.arena);
    }
};

pub fn buildExpansion(alloc: std.mem.Allocator, io: std.Io, dump: Dump) !Expansion {
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const k = dump.alphabetSize();
    const off = try alloc.alloc(u64, k);
    errdefer alloc.free(off);
    const len = try alloc.alloc(u32, k);
    errdefer alloc.free(len);

    for (0..256) |i| {
        off[i] = i;
        len[i] = 1;
    }
    var total: u64 = 256;
    for (dump.rules, 0..) |r, i| {
        const l = len[r.a] + len[r.b];
        len[256 + i] = l;
        total += l;
    }

    const arena = try alloc.alloc(u8, total + overscan_pad);
    errdefer alloc.free(arena);
    for (0..256) |i| arena[i] = @intCast(i);
    var write: u64 = 256;
    for (dump.rules, 0..) |r, i| {
        const id = 256 + i;
        off[id] = write;
        const la = len[r.a];
        const lb = len[r.b];
        @memcpy(arena[write .. write + la], arena[off[r.a] .. off[r.a] + la]);
        write += la;
        @memcpy(arena[write .. write + lb], arena[off[r.b] .. off[r.b] + lb]);
        write += lb;
    }
    @memset(arena[write .. write + overscan_pad], 0);
    std.debug.assert(write == total);

    const t1 = std.Io.Clock.awake.now(io).nanoseconds;
    return .{ .off = off, .len = len, .arena = arena, .arena_used = write, .build_ns = @intCast(t1 - t0) };
}

/// Unconditional overscan copy: safe because both arena and the output
/// buffer are padded past their real length. Branch-light: one size class
/// covers the documented 10-75 byte root expansions in a single store pair.
pub inline fn copyExpansionFast(dst: [*]u8, src: [*]const u8, l: u32) void {
    if (l <= 16) {
        @as(*[16]u8, @ptrCast(dst)).* = @as(*const [16]u8, @ptrCast(src)).*;
    } else if (l <= 32) {
        @as(*[32]u8, @ptrCast(dst)).* = @as(*const [32]u8, @ptrCast(src)).*;
    } else {
        var i: usize = 0;
        while (i + 32 <= l) : (i += 32) {
            @as(*[32]u8, @ptrCast(dst + i)).* = @as(*const [32]u8, @ptrCast(src + i)).*;
        }
        while (i < l) : (i += 1) dst[i] = src[i];
    }
}

/// Baseline copy for before/after comparison: plain @memcpy, length-dispatch
/// entirely left to the standard library.
pub inline fn copyExpansionMemcpy(dst: [*]u8, src: [*]const u8, l: u32) void {
    @memcpy(dst[0..l], src[0..l]);
}

// ---------------------------------------------------------------------
// Alphabet compaction: only symbols that actually occur as roots (g[s]>0)
// need a code. This is "the shared model" the decoder rebuilds from.
// ---------------------------------------------------------------------

pub const Alphabet = struct {
    n: u32, // number of used (root) symbols
    id: []u32, // compact index -> real symbol id, ascending by real id
    count: []u64, // compact index -> g[s]
    total: u64, // sum of count[]

    pub fn deinit(self: *Alphabet, alloc: std.mem.Allocator) void {
        alloc.free(self.id);
        alloc.free(self.count);
    }
};

pub fn buildAlphabet(alloc: std.mem.Allocator, dump: Dump) !Alphabet {
    const k = dump.alphabetSize();
    const g = try alloc.alloc(u64, k);
    defer alloc.free(g);
    @memset(g, 0);
    for (dump.seq) |s| g[s] += 1;

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

/// Exact static order-0 entropy of the root stream, in bytes (an `est`
/// figure per PLAN.md's rules of evidence -- reference only, never charged).
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
// Canonical length-limited Huffman, built deterministically from g[].
//
// Construction: (1) standard O(n) two-queue Huffman merge on sorted
// weights (Van Leeuwen's algorithm) for the unrestricted code; (2) clip any
// length > max_len down to max_len, then repeatedly lengthen the symbol at
// the longest length below max_len by one bit until the Kraft sum
// sum(2^-len) fits in 2^-0 (a bucketed variant of the classic "Kraft
// fix-up" heuristic used by, e.g., zlib/deflate's bl_count overflow fix);
// (3) canonical code assignment from the final lengths. This is a
// heuristic, not package-merge -- it is not guaranteed length-optimal, but
// it is simple, deterministic, and (per LANE_S.md) empirically very close
// to the unrestricted Huffman cost for our alphabets.
// ---------------------------------------------------------------------

pub const huf_max_len: u6 = 24;
pub const huf_primary_bits: u6 = 12;
const huf_primary_size: usize = 1 << huf_primary_bits;
const leaf_flag: u32 = 0x8000_0000;

pub const Huffman = struct {
    alphabet_size: u32,
    n: u32,
    trivial_symbol: ?u32, // set iff n <= 1: no bits are coded at all
    length: []u8, // compact index -> code length (0 if trivial)
    code: []u32, // compact index -> canonical code, MSB-justified in `length` bits

    // Decode side: real-id indexed for O(1) dispatch during copy.
    primary_len: []u8, // 0 marks "escape to subtable"
    primary_sym: []u32,
    primary_sub: []u32, // valid when primary_len[v]==0
    sub_len: []u8, // flattened [group][suffix]
    sub_sym: []u32,
    sub_groups: u32,

    // Explicit bit-trie over the SAME canonical (length,code) pairs, used
    // only for the naive before/after decode-speed comparison: real
    // pointer-chasing, one branch per bit, no table. Child value has
    // `leaf_flag` set iff it names a real symbol id (low 31 bits).
    tree_left: []u32,
    tree_right: []u32,

    build_ns: u64,

    pub fn deinit(self: *Huffman, alloc: std.mem.Allocator) void {
        alloc.free(self.length);
        alloc.free(self.code);
        alloc.free(self.primary_len);
        alloc.free(self.primary_sym);
        alloc.free(self.primary_sub);
        alloc.free(self.sub_len);
        alloc.free(self.sub_sym);
        alloc.free(self.tree_left);
        alloc.free(self.tree_right);
    }

    /// Naive bit-at-a-time decode (baseline for the before/after comparison
    /// in LANE_S.md): walk the explicit trie one bit, one pointer-chase, at
    /// a time. Decodes the exact same canonical code as decodeOneTable.
    pub inline fn decodeOneNaive(self: *const Huffman, br: *BitReader) u32 {
        if (self.trivial_symbol) |s| return s;
        var cur: u32 = 0;
        while (true) {
            const bit = br.getBit();
            const nxt = if (bit == 0) self.tree_left[cur] else self.tree_right[cur];
            if (nxt & leaf_flag != 0) return nxt & ~leaf_flag;
            cur = nxt;
        }
    }

    /// Table-driven two-level decode: O(1) primary lookup, escape to a
    /// small subtable only for the (rare) tail of long codes.
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

fn buildHuffmanTrie(alloc: std.mem.Allocator, huf: *Huffman, a: Alphabet) !void {
    const n = a.n;
    var left = try alloc.alloc(u32, @max(n, 1));
    errdefer alloc.free(left);
    var right = try alloc.alloc(u32, @max(n, 1));
    errdefer alloc.free(right);
    @memset(left, 0);
    @memset(right, 0);
    var next_free: u32 = 1; // 0 is the root
    for (0..n) |ci| {
        const len = huf.length[ci];
        const cd = huf.code[ci];
        const real = a.id[ci];
        var cur: u32 = 0;
        var bp: i32 = @as(i32, len) - 1;
        while (bp > 0) : (bp -= 1) {
            const bit = (cd >> @intCast(bp)) & 1;
            const slot: *u32 = if (bit == 0) &left[cur] else &right[cur];
            if (slot.* == 0) {
                std.debug.assert(next_free < n);
                slot.* = next_free;
                next_free += 1;
            }
            cur = slot.*;
        }
        const bit0 = cd & 1;
        const slot0: *u32 = if (bit0 == 0) &left[cur] else &right[cur];
        slot0.* = leaf_flag | real;
    }
    alloc.free(huf.tree_left);
    alloc.free(huf.tree_right);
    huf.tree_left = left;
    huf.tree_right = right;
}

pub fn buildHuffman(alloc: std.mem.Allocator, io: std.Io, a: Alphabet, alphabet_size: u32) !Huffman {
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
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
        .tree_left = try alloc.alloc(u32, 1),
        .tree_right = try alloc.alloc(u32, 1),
        .build_ns = 0,
    };
    @memset(huf.primary_len, 0);
    @memset(huf.primary_sym, 0);
    @memset(huf.primary_sub, 0);

    if (n <= 1) {
        huf.trivial_symbol = if (n == 1) a.id[0] else 0;
        const t1 = std.Io.Clock.awake.now(io).nanoseconds;
        huf.build_ns = @intCast(t1 - t0);
        return huf;
    }

    // (1) Sorted leaves (by weight, tie-broken by real id via stable sort of
    // an index permutation) feed the classic O(n) two-queue Huffman merge.
    const order = try alloc.alloc(u32, n); // compact idx sorted by (count,id) asc
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

    var li: usize = 0; // next unread leaf (0..n)
    var qj: usize = n; // next unread internal node (n..next)
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

    // length[] indexed by compact id (map back through `order`).
    var length = try alloc.alloc(u8, n);
    for (0..n) |i| length[order[i]] = depth[i];

    // (2) Clip to max_len, then Kraft fix-up via length buckets.
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
            if (l == 0) unreachable; // alphabet too large for max_len (not possible at our scale)
        }
        const ci = buckets[l].pop().?;
        length[ci] = l + 1;
        try buckets[l + 1].append(alloc, ci);
        units -= @as(u64, 1) << @intCast(huf_max_len - l - 1);
    }

    // (3) Canonical code assignment: sort by (length, compact id) so the
    // whole procedure is a pure function of g[] and max_len.
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

    // Decode tables, real-id indexed.
    buildHuffmanDecodeTables(alloc, &huf, a);
    try buildHuffmanTrie(alloc, &huf, a);

    const t1 = std.Io.Clock.awake.now(io).nanoseconds;
    huf.build_ns = @intCast(t1 - t0);
    return huf;
}

fn buildHuffmanDecodeTables(alloc: std.mem.Allocator, huf: *Huffman, a: Alphabet) void {
    const n = a.n;
    // Pass 1: fill every primary slot covered by a short (<=primary_bits)
    // code, and collect the set of distinct primary-bit prefixes that long
    // codes escape through.
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
            prefix_set.put(prefix, {}) catch unreachable;
        }
    }

    // Assign group ids 0..ngroups-1 deterministically by ascending prefix
    // value (purely a function of the codes, i.e. of g[]).
    const ngroups: u32 = prefix_set.count();
    const sub_span: u32 = @as(u32, 1) << @intCast(huf_max_len - huf_primary_bits);
    var sub_len = alloc.alloc(u8, @as(usize, ngroups) * sub_span) catch unreachable;
    var sub_sym = alloc.alloc(u32, @as(usize, ngroups) * sub_span) catch unreachable;
    @memset(sub_len, 0);
    @memset(sub_sym, 0);

    var prefixes = alloc.alloc(u32, ngroups) catch unreachable;
    defer alloc.free(prefixes);
    {
        var it = prefix_set.keyIterator();
        var i: usize = 0;
        while (it.next()) |kptr| : (i += 1) prefixes[i] = kptr.*;
    }
    std.mem.sort(u32, prefixes, {}, std.sort.asc(u32));
    var group_of_prefix = std.AutoHashMap(u32, u32).init(alloc);
    defer group_of_prefix.deinit();
    for (prefixes, 0..) |p, gi| group_of_prefix.put(p, @intCast(gi)) catch unreachable;

    // Pass 2: fill subtables for the long codes.
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

/// Real-id -> (length,code) lookup for the encoder. Builds a dense table
/// once (alphabet_size entries) so encode is O(1) per root.
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
// Bit IO for the Huffman codec. Left-justified 64-bit buffer, MSB-first,
// each block's stream byte-padded and reset independently.
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
    nbits: u7 = 0, // 0..64: u6 (max 63) cannot hold a fully-refilled 64
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

    pub inline fn getBit(self: *BitReader) u32 {
        const b = self.peek(1);
        self.consume(1);
        return b;
    }
};

// ---------------------------------------------------------------------
// Static range coder core: a copy of rc.zig's carryless 64-bit range coder,
// specialised with a power-of-two total so the total-division becomes a
// shift. The intrinsic per-symbol position division (code-low)/range is
// unavoidable in a range coder (true rANS would trade it for table-driven
// renormalisation; not implemented here -- see LANE_S.md).
// ---------------------------------------------------------------------

const rc_top: u64 = 1 << 56;
const rc_bot: u64 = 1 << 48;

pub const RCEncoder = struct {
    low: u64 = 0,
    range: u64 = std.math.maxInt(u64),
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,

    inline fn normalize(self: *RCEncoder) !void {
        while (true) {
            if ((self.low ^ (self.low +% self.range)) >= rc_top) {
                if (self.range >= rc_bot) break;
                self.range = (0 -% self.low) & (rc_bot - 1);
            }
            try self.out.append(self.alloc, @truncate(self.low >> 56));
            self.low <<= 8;
            self.range <<= 8;
        }
    }

    pub fn encodeFreqPow2(self: *RCEncoder, cum: u32, freq: u32, bits: u6) !void {
        self.range >>= @intCast(bits);
        self.low +%= @as(u64, cum) * self.range;
        self.range *= freq;
        try self.normalize();
    }

    pub fn finish(self: *RCEncoder) !void {
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            try self.out.append(self.alloc, @truncate(self.low >> 56));
            self.low <<= 8;
        }
    }
};

pub const RCDecoder = struct {
    low: u64 = 0,
    range: u64 = std.math.maxInt(u64),
    code: u64 = 0,
    in: []const u8,
    at: usize = 0,

    pub fn init(in: []const u8) RCDecoder {
        var self = RCDecoder{ .in = in };
        var i: usize = 0;
        while (i < 8) : (i += 1) self.code = (self.code << 8) | self.next();
        return self;
    }

    inline fn next(self: *RCDecoder) u64 {
        const byte: u64 = if (self.at < self.in.len) self.in[self.at] else 0;
        self.at += 1;
        return byte;
    }

    inline fn normalize(self: *RCDecoder) void {
        while (true) {
            if ((self.low ^ (self.low +% self.range)) >= rc_top) {
                if (self.range >= rc_bot) break;
                self.range = (0 -% self.low) & (rc_bot - 1);
            }
            self.code = (self.code << 8) | self.next();
            self.low <<= 8;
            self.range <<= 8;
        }
    }

    pub fn decodeFreqPow2(self: *RCDecoder, bits: u6) u32 {
        self.range >>= @intCast(bits);
        const v = (self.code -% self.low) / self.range;
        return @intCast(@min(v, (@as(u64, 1) << @intCast(bits)) - 1));
    }

    pub fn consume(self: *RCDecoder, cum: u32, freq: u32) void {
        self.low +%= @as(u64, cum) * self.range;
        self.range *= freq;
        self.normalize();
    }
};

// ---------------------------------------------------------------------
// Static range/rANS-style model: probabilities g[s]/M quantised to a
// power-of-two total. Decode finds the owning symbol via either a
// cumulative-table binary search (baseline) or an O(1) slot table
// (optimised) -- both are provided for the before/after comparison.
// ---------------------------------------------------------------------

pub const RangeModel = struct {
    n: u32,
    bits: u6, // total = 1 << bits
    id: []u32, // compact -> real symbol id (shared with Alphabet, not owned)
    qcount: []u32, // compact -> quantised frequency, sum == 1<<bits
    cum: []u32, // compact+1 -> cumulative quantised frequency, cum[0]=0
    slot: []u32, // size 1<<bits -> compact index
    build_ns: u64,

    pub fn deinit(self: *RangeModel, alloc: std.mem.Allocator) void {
        alloc.free(self.qcount);
        alloc.free(self.cum);
        alloc.free(self.slot);
    }

    pub inline fn findBinarySearch(self: *const RangeModel, v: u32) u32 {
        var lo: usize = 0;
        var hi: usize = self.n; // cum[hi] == total, invariant cum[lo] <= v
        while (hi - lo > 1) {
            const mid = (lo + hi) / 2;
            if (self.cum[mid] <= v) lo = mid else hi = mid;
        }
        return @intCast(lo);
    }

    pub inline fn findSlot(self: *const RangeModel, v: u32) u32 {
        return self.slot[v];
    }
};

fn rangeCountLess(a: Alphabet, x: u32, y: u32) bool {
    if (a.count[x] != a.count[y]) return a.count[x] > a.count[y]; // descending
    return a.id[x] < a.id[y];
}

pub fn chooseRangeBits(n: u32) u6 {
    var bits: u6 = 16;
    while ((@as(u64, 1) << bits) < @as(u64, n) * 8 and bits < 22) bits += 1;
    return bits;
}

pub fn buildRangeModel(alloc: std.mem.Allocator, io: std.Io, a: Alphabet, bits: u6) !RangeModel {
    const t0 = std.Io.Clock.awake.now(io).nanoseconds;
    const n = a.n;
    const total_target: u64 = @as(u64, 1) << bits;
    std.debug.assert(n <= total_target);

    var q = try alloc.alloc(u32, n);
    errdefer alloc.free(q);
    var qsum: u64 = 0;
    for (0..n) |i| {
        const num = a.count[i] * total_target;
        var v = (num + a.total / 2) / a.total;
        if (v == 0) v = 1;
        if (v >= total_target) v = total_target - 1;
        q[i] = @intCast(v);
        qsum += v;
    }

    // Rebalance qsum to exactly total_target, biggest movers first.
    var order = try alloc.alloc(u32, n);
    defer alloc.free(order);
    for (0..n) |i| order[i] = @intCast(i);
    std.mem.sort(u32, order, a, rangeCountLess);

    if (qsum > total_target) {
        var excess = qsum - total_target;
        while (excess > 0) {
            var progressed = false;
            for (order) |ci| {
                if (excess == 0) break;
                if (q[ci] > 1) {
                    q[ci] -= 1;
                    excess -= 1;
                    progressed = true;
                }
            }
            if (!progressed) unreachable; // can't happen: n <= total_target
        }
    } else if (qsum < total_target) {
        var deficit = total_target - qsum;
        while (deficit > 0) {
            for (order) |ci| {
                if (deficit == 0) break;
                q[ci] += 1;
                deficit -= 1;
            }
        }
    }

    var cum = try alloc.alloc(u32, n + 1);
    errdefer alloc.free(cum);
    cum[0] = 0;
    for (0..n) |i| cum[i + 1] = cum[i] + q[i];
    std.debug.assert(cum[n] == total_target);

    var slot = try alloc.alloc(u32, total_target);
    errdefer alloc.free(slot);
    for (0..n) |i| {
        var v = cum[i];
        while (v < cum[i + 1]) : (v += 1) slot[v] = @intCast(i);
    }

    const t1 = std.Io.Clock.awake.now(io).nanoseconds;
    return .{ .n = n, .bits = bits, .id = a.id, .qcount = q, .cum = cum, .slot = slot, .build_ns = @intCast(t1 - t0) };
}

// ---------------------------------------------------------------------
// Frame format: 32-byte header + 16-byte-per-block directory + payload.
// header  := magic,version,coder_tag,block_count,block_bytes,raw_len,n_sym,reserved (8 x u32)
// dirent  := payload_offset,payload_len,root_count,crc32 (4 x u32), 16 bytes
// This is bookkeeping charged exactly like the bzip3 control (PLAN.md);
// it is not itself a compact production format.
// ---------------------------------------------------------------------

pub const frame_magic: u32 = 0x53345A42; // "BZ4S"
pub const coder_huffman: u32 = 0;
pub const coder_range: u32 = 1;

pub const DirEnt = extern struct { payload_offset: u32, payload_len: u32, root_count: u32, crc32: u32 };

pub const Frame = struct {
    bytes: []u8, // owned: header ++ directory ++ payload
    header_len: usize,
    dir: []align(1) DirEnt, // view into bytes (byte-buffer backed, alignment 1)
    payload: []u8, // view into bytes

    pub fn deinit(self: *Frame, alloc: std.mem.Allocator) void {
        alloc.free(self.bytes);
    }
};

fn crc32Of(bytes: []const u8) u32 {
    return std.hash.Crc32.hash(bytes);
}

pub fn encodeHuffmanFrame(alloc: std.mem.Allocator, dump: Dump, enc: HuffmanEncodeTable) !Frame {
    const header_len = 32;
    const dir_len = @as(usize, dump.block_count) * 16;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    var dir = try alloc.alloc(DirEnt, dump.block_count);
    errdefer alloc.free(dir);

    // CRC32 is stamped in afterwards, over the ground-truth raw bytes, via
    // stampCrcs -- see the driver. The frame is complete without it.
    var bw = BitWriter{ .out = &payload, .alloc = alloc };
    for (0..dump.block_count) |b| {
        const start = payload.items.len;
        const off = dump.block_off[b];
        const cnt = dump.block_len[b];
        for (dump.seq[off .. off + cnt]) |s| {
            try bw.putBits(enc.code[s], @intCast(enc.length[s]));
        }
        try bw.flushBlock();
        dir[b] = .{ .payload_offset = @intCast(start), .payload_len = @intCast(payload.items.len - start), .root_count = cnt, .crc32 = 0 };
    }

    return assembleFrame(alloc, dump, coder_huffman, header_len, dir_len, dir, payload.items);
}

pub fn encodeRangeFrame(alloc: std.mem.Allocator, dump: Dump, a: Alphabet, model: RangeModel) !Frame {
    const header_len = 32;
    const dir_len = @as(usize, dump.block_count) * 16;
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    var dir = try alloc.alloc(DirEnt, dump.block_count);
    errdefer alloc.free(dir);

    // real id -> compact index, dense for O(1) encode lookups
    var rank = try alloc.alloc(u32, dump.alphabetSize());
    defer alloc.free(rank);
    @memset(rank, 0);
    for (0..a.n) |ci| rank[a.id[ci]] = @intCast(ci);

    for (0..dump.block_count) |b| {
        const start = payload.items.len;
        const off = dump.block_off[b];
        const cnt = dump.block_len[b];
        var enc = RCEncoder{ .out = &payload, .alloc = alloc };
        for (dump.seq[off .. off + cnt]) |s| {
            const ci = rank[s];
            try enc.encodeFreqPow2(model.cum[ci], model.qcount[ci], model.bits);
        }
        try enc.finish();
        dir[b] = .{ .payload_offset = @intCast(start), .payload_len = @intCast(payload.items.len - start), .root_count = cnt, .crc32 = 0 };
    }

    return assembleFrame(alloc, dump, coder_range, header_len, dir_len, dir, payload.items);
}

fn assembleFrame(alloc: std.mem.Allocator, dump: Dump, coder_tag: u32, header_len: usize, dir_len: usize, dir: []DirEnt, payload: []const u8) !Frame {
    const total = header_len + dir_len + payload.len;
    var bytes = try alloc.alloc(u8, total);
    var words = std.mem.bytesAsSlice(u32, bytes[0..header_len]);
    words[0] = frame_magic;
    words[1] = 1;
    words[2] = coder_tag;
    words[3] = dump.block_count;
    words[4] = dump.block_bytes;
    words[5] = dump.raw_len;
    words[6] = 0; // n_sym filled by caller if desired; not needed to decode
    words[7] = 0;
    const dir_bytes = std.mem.sliceAsBytes(dir);
    @memcpy(bytes[header_len .. header_len + dir_len], dir_bytes);
    @memcpy(bytes[header_len + dir_len ..], payload);
    alloc.free(dir);

    const dir_view = std.mem.bytesAsSlice(DirEnt, bytes[header_len .. header_len + dir_len]);
    return .{ .bytes = bytes, .header_len = header_len, .dir = dir_view, .payload = bytes[header_len + dir_len ..] };
}

/// Fill in per-block CRC32 of the decoded bytes (real evidence, computed
/// once after a verified decode). Frames are otherwise complete without it;
/// this lets single-block decode validate itself independently later.
pub fn stampCrcs(frame: *Frame, dump: Dump, decoded: []const u8) void {
    for (0..dump.block_count) |b| {
        const raw_start = b * dump.block_bytes;
        const raw_end = @min(dump.raw_len, raw_start + dump.block_bytes);
        frame.dir[b].crc32 = crc32Of(decoded[raw_start..raw_end]);
    }
}

// ---------------------------------------------------------------------
// Decode loop. comptime `checked` selects real validation (safe under any
// build mode, uses explicit error returns, not std.debug.assert which is
// UB-on-false in ReleaseFast) vs. the branch-light fast path used for
// timing. comptime `fast_copy`/`table_decode` select the optimisation
// variants for the before/after comparisons in LANE_S.md.
// ---------------------------------------------------------------------

pub const DecodeError = error{ BadMagic, BadCoder, SymbolOutOfRange, OutputOverflow, CrcMismatch, LengthMismatch };

pub fn decodeHuffman(
    comptime checked: bool,
    comptime fast_copy: bool,
    comptime table_decode: bool,
    huf: *const Huffman,
    exp: *const Expansion,
    frame: Frame,
    block_index: usize,
    out: []u8,
) !usize {
    const d = frame.dir[block_index];
    const payload = frame.payload[d.payload_offset .. d.payload_offset + d.payload_len];
    var br = BitReader.init(payload);
    var pos: usize = 0;
    var i: u32 = 0;
    while (i < d.root_count) : (i += 1) {
        const sym = if (table_decode) huf.decodeOneTable(&br) else huf.decodeOneNaive(&br);
        if (checked) {
            if (sym >= huf.alphabet_size) return DecodeError.SymbolOutOfRange;
        }
        const off = exp.off[sym];
        const l = exp.len[sym];
        if (checked) {
            if (pos + l > out.len) return DecodeError.OutputOverflow;
        }
        if (fast_copy) {
            copyExpansionFast(out.ptr + pos, exp.arena.ptr + off, l);
        } else {
            copyExpansionMemcpy(out.ptr + pos, exp.arena.ptr + off, l);
        }
        pos += l;
    }
    return pos;
}

pub fn decodeRange(
    comptime checked: bool,
    comptime fast_copy: bool,
    comptime slot_decode: bool,
    model: *const RangeModel,
    exp: *const Expansion,
    frame: Frame,
    block_index: usize,
    out: []u8,
) !usize {
    const d = frame.dir[block_index];
    const payload = frame.payload[d.payload_offset .. d.payload_offset + d.payload_len];
    var dec = RCDecoder.init(payload);
    var pos: usize = 0;
    var i: u32 = 0;
    while (i < d.root_count) : (i += 1) {
        const v = dec.decodeFreqPow2(model.bits);
        const ci = if (slot_decode) model.findSlot(v) else model.findBinarySearch(v);
        dec.consume(model.cum[ci], model.qcount[ci]);
        const sym = model.id[ci];
        if (checked) {
            if (sym >= exp.off.len) return DecodeError.SymbolOutOfRange;
        }
        const off = exp.off[sym];
        const l = exp.len[sym];
        if (checked) {
            if (pos + l > out.len) return DecodeError.OutputOverflow;
        }
        if (fast_copy) {
            copyExpansionFast(out.ptr + pos, exp.arena.ptr + off, l);
        } else {
            copyExpansionMemcpy(out.ptr + pos, exp.arena.ptr + off, l);
        }
        pos += l;
    }
    return pos;
}

/// Full-frame decode (checked, portable path) used for correctness
/// verification: rebuilds the whole raw file and checks it against `raw`.
pub fn decodeFullHuffmanChecked(alloc: std.mem.Allocator, huf: *const Huffman, exp: *const Expansion, frame: Frame, raw: []const u8) !void {
    if (std.mem.readInt(u32, frame.bytes[0..4], .little) != frame_magic) return DecodeError.BadMagic;
    if (std.mem.readInt(u32, frame.bytes[8..12], .little) != coder_huffman) return DecodeError.BadCoder;
    const raw_len = std.mem.readInt(u32, frame.bytes[20..24], .little);
    const block_bytes = std.mem.readInt(u32, frame.bytes[16..20], .little);
    const block_count = std.mem.readInt(u32, frame.bytes[12..16], .little);
    if (raw_len != raw.len) return DecodeError.LengthMismatch;
    const out = try alloc.alloc(u8, raw_len + overscan_pad);
    defer alloc.free(out);
    for (0..block_count) |b| {
        const raw_start = b * block_bytes;
        const dst = out[raw_start..];
        const n = try decodeHuffman(true, true, true, huf, exp, frame, b, dst[0 .. raw.len - raw_start + overscan_pad]);
        const raw_end = @min(raw.len, raw_start + block_bytes);
        if (raw_start + n != raw_end) return DecodeError.LengthMismatch;
        const crc = crc32Of(out[raw_start .. raw_start + n]);
        if (frame.dir[b].crc32 != 0 and frame.dir[b].crc32 != crc) return DecodeError.CrcMismatch;
    }
    if (!std.mem.eql(u8, out[0..raw_len], raw)) return DecodeError.LengthMismatch;
}

pub fn decodeFullRangeChecked(alloc: std.mem.Allocator, model: *const RangeModel, exp: *const Expansion, frame: Frame, raw: []const u8) !void {
    if (std.mem.readInt(u32, frame.bytes[0..4], .little) != frame_magic) return DecodeError.BadMagic;
    if (std.mem.readInt(u32, frame.bytes[8..12], .little) != coder_range) return DecodeError.BadCoder;
    const raw_len = std.mem.readInt(u32, frame.bytes[20..24], .little);
    const block_bytes = std.mem.readInt(u32, frame.bytes[16..20], .little);
    const block_count = std.mem.readInt(u32, frame.bytes[12..16], .little);
    if (raw_len != raw.len) return DecodeError.LengthMismatch;
    const out = try alloc.alloc(u8, raw_len + overscan_pad);
    defer alloc.free(out);
    for (0..block_count) |b| {
        const raw_start = b * block_bytes;
        const dst = out[raw_start..];
        const n = try decodeRange(true, true, true, model, exp, frame, b, dst[0 .. raw.len - raw_start + overscan_pad]);
        const raw_end = @min(raw.len, raw_start + block_bytes);
        if (raw_start + n != raw_end) return DecodeError.LengthMismatch;
        const crc = crc32Of(out[raw_start .. raw_start + n]);
        if (frame.dir[b].crc32 != 0 and frame.dir[b].crc32 != crc) return DecodeError.CrcMismatch;
    }
    if (!std.mem.eql(u8, out[0..raw_len], raw)) return DecodeError.LengthMismatch;
}
