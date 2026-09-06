//! BCP 47 language-tag syntax and text-profile views.
//!
//! This module deliberately validates the RFC 5646 *well-formed* grammar,
//! not the IANA registry.  A tag may therefore be syntactically well-formed
//! while containing an unregistered language, script, region, or variant.
//! All returned slices borrow the caller's bytes.  No locale, allocator, or
//! Unicode case-folding data is consulted.

const std = @import("std");

pub const max_input_bytes: usize = 4096;

pub const Error = error{
    Empty,
    TooLong,
    NonAscii,
    InvalidTag,
    InvalidSubtag,
    MissingExtensionSubtag,
    DuplicateVariant,
    DuplicateExtension,
    InvalidBasicRange,
    InvalidExtendedRange,
    BufferTooSmall,
};

pub const Kind = enum {
    language_tag,
    private_use,
    grandfathered,
};

pub const Direction = enum {
    unspecified,
    ltr,
    rtl,
};

/// A four-letter BCP 47 script-shaped value.  The bytes are borrowed and
/// retain their supplied case; no ISO 15924 registry lookup is performed.
pub const Script = struct {
    original: []const u8,

    pub fn parse(bytes: []const u8) Error!Script {
        if (bytes.len != 4) return Error.InvalidSubtag;
        for (bytes) |byte| if (!isAlpha(byte)) return Error.InvalidSubtag;
        return .{ .original = bytes };
    }

    pub fn eql(self: Script, other: Script) bool {
        return asciiEql(self.original, other.original);
    }

    /// A stable ASCII-only comparison form.  The source remains available in
    /// `original`, so canonical comparison never destroys provenance.
    pub fn writeComparisonKey(self: Script, out: []u8) Error![]const u8 {
        if (out.len < self.original.len) return Error.BufferTooSmall;
        for (self.original, 0..) |byte, index| out[index] = asciiLower(byte);
        return out[0..self.original.len];
    }
};

/// A notation identifier is intentionally opaque.  IPA, romanization,
/// orthography, and project-defined notation names can coexist without being
/// conflated; this type does not claim that any notation has been interpreted.
pub const Notation = struct {
    original: []const u8,

    pub fn init(bytes: []const u8) Error!Notation {
        if (bytes.len == 0 or !std.unicode.utf8ValidateSlice(bytes)) return Error.InvalidSubtag;
        return .{ .original = bytes };
    }

    pub fn eql(self: Notation, other: Notation) bool {
        return std.mem.eql(u8, self.original, other.original);
    }
};

/// Identity of an optional analysis artifact.  `digest` is an application
/// supplied identity value (normally a cryptographic truncation); zero means
/// "not supplied", not "the analysis has no effect".  This metadata does not
/// implement normalization, collation, transliteration, or morphology.
pub const AnalysisKind = enum {
    none,
    tokenizer,
    normalization,
    transliteration,
    collation,
    morphology,
    custom,
};

pub const AnalysisIdentity = struct {
    kind: AnalysisKind = .none,
    name: []const u8 = "",
    version: u32 = 0,
    digest: u64 = 0,

    pub fn eql(self: AnalysisIdentity, other: AnalysisIdentity) bool {
        return self.kind == other.kind and
            self.version == other.version and
            self.digest == other.digest and
            std.mem.eql(u8, self.name, other.name);
    }
};

pub const TextProfile = struct {
    /// Parsed language identity.  Its `original` bytes are exactly the bytes
    /// supplied by the source Text value.
    language: ?LanguageTag = null,
    /// Script is separate from direction and notation.  It may be supplied
    /// independently when source metadata places it outside xml:lang.
    script: ?Script = null,
    direction: Direction = .unspecified,
    notation: ?Notation = null,
    analysis: AnalysisIdentity = .{},

    pub fn init(
        language_bytes: ?[]const u8,
        script_bytes: ?[]const u8,
        direction: Direction,
        notation_bytes: ?[]const u8,
        analysis: AnalysisIdentity,
    ) Error!TextProfile {
        return .{
            .language = if (language_bytes) |bytes| try LanguageTag.parse(bytes) else null,
            .script = if (script_bytes) |bytes| try Script.parse(bytes) else null,
            .direction = direction,
            .notation = if (notation_bytes) |bytes| try Notation.init(bytes) else null,
            .analysis = analysis,
        };
    }

    /// Bridge for the existing semantic.Text shape.  The input is read only
    /// and remains the authority for exact source bytes; an invalid language,
    /// script, or notation returns an error without rewriting or normalizing
    /// the Text value.  `anytype` keeps this module independent of the semantic
    /// model while accepting its current field layout.
    pub fn fromText(text: anytype, direction: Direction, analysis: AnalysisIdentity) Error!TextProfile {
        return init(text.language, text.script, direction, text.notation, analysis);
    }

    pub fn eql(self: TextProfile, other: TextProfile) bool {
        const languages_equal = optionalLanguageEqual(self.language, other.language);
        const scripts_equal = optionalScriptEqual(self.script, other.script);
        const notation_equal = optionalNotationEqual(self.notation, other.notation);
        return languages_equal and scripts_equal and notation_equal and
            self.direction == other.direction and self.analysis.eql(other.analysis);
    }
};

/// A validated tag borrowed from the source buffer.  This is deliberately a
/// view rather than an owned normalized string: `original` is exact source
/// provenance and all derived keys are generated into caller-owned storage.
pub const LanguageTag = struct {
    original: []const u8,
    kind: Kind,
    language_start: ?usize = null,
    language_end: ?usize = null,
    script_start: ?usize = null,
    script_end: ?usize = null,
    region_start: ?usize = null,
    region_end: ?usize = null,

    pub fn parse(input: []const u8) Error!LanguageTag {
        if (input.len == 0) return Error.Empty;
        if (input.len > max_input_bytes) return Error.TooLong;
        if (input[0] == '-' or input[input.len - 1] == '-') return Error.InvalidTag;
        for (input) |byte| {
            if (byte > 0x7f) return Error.NonAscii;
            if (byte != '-' and !isAlpha(byte) and !isDigit(byte)) return Error.InvalidSubtag;
        }

        if (isGrandfathered(input)) return .{ .original = input, .kind = .grandfathered };

        var cursor: usize = 0;
        const first = (try nextPart(input, &cursor)) orelse return Error.InvalidTag;

        if (asciiEql(first.bytes(input), "x")) {
            try consumePrivateTail(input, &cursor);
            return .{ .original = input, .kind = .private_use };
        }

        if (!validLanguage(first.bytes(input))) return Error.InvalidTag;
        var result = LanguageTag{
            .original = input,
            .kind = .language_tag,
            .language_start = first.start,
            .language_end = first.end,
        };

        // A two- or three-letter language may carry up to three extlang
        // subtags.  We consume only the structurally unambiguous 3-alpha
        // forms; registry membership belongs to a separate validator.
        if (first.len() == 2 or first.len() == 3) {
            var extlang_count: usize = 0;
            while (extlang_count < 3) : (extlang_count += 1) {
                const saved = cursor;
                const candidate = try nextPart(input, &cursor) orelse break;
                if (!(candidate.len() == 3 and allAlpha(candidate.bytes(input)))) {
                    cursor = saved;
                    break;
                }
            }
        }

        // Optional script and region are position-sensitive, as required by
        // RFC 5646; a four-letter subtag after a singleton is just extension
        // data and is never mistaken for script here.
        {
            const saved = cursor;
            if (try nextPart(input, &cursor)) |candidate| {
                if (candidate.len() == 4 and allAlpha(candidate.bytes(input))) {
                    result.script_start = candidate.start;
                    result.script_end = candidate.end;
                } else cursor = saved;
            }
        }
        {
            const saved = cursor;
            if (try nextPart(input, &cursor)) |candidate| {
                if ((candidate.len() == 2 and allAlpha(candidate.bytes(input))) or
                    (candidate.len() == 3 and allDigit(candidate.bytes(input))))
                {
                    result.region_start = candidate.start;
                    result.region_end = candidate.end;
                } else cursor = saved;
            }
        }

        // Variants occupy the only phase where arbitrary duplicate detection
        // is needed.  The source is bounded by max_input_bytes, and the scan
        // is allocation-free and cannot recurse or grow a stack.
        const variants_start = cursor;
        while (true) {
            const saved = cursor;
            const candidate = try nextPart(input, &cursor) orelse break;
            if (!validVariant(candidate.bytes(input))) {
                cursor = saved;
                break;
            }
            if (variantSeen(input, variants_start, saved, candidate.bytes(input))) return Error.DuplicateVariant;
        }

        // Extensions are sequences introduced by a unique singleton, each
        // with at least one 2..8-character subtag.  x is reserved for the
        // final private-use sequence and is therefore handled separately.
        var singleton_bits: u64 = 0;
        while (true) {
            const saved = cursor;
            const candidate = try nextPart(input, &cursor) orelse break;
            const singleton = candidate.bytes(input);
            if (singleton.len == 1 and asciiLower(singleton[0]) == 'x') {
                try consumePrivateTail(input, &cursor);
                return result;
            }
            if (singleton.len != 1 or !isAlphaNumeric(singleton[0])) {
                cursor = saved;
                break;
            }
            const bit = singletonBit(singleton[0]) orelse return Error.InvalidTag;
            if ((singleton_bits & bit) != 0) return Error.DuplicateExtension;
            singleton_bits |= bit;

            const extension_first = try nextPart(input, &cursor) orelse return Error.MissingExtensionSubtag;
            if (!validExtensionPart(extension_first.bytes(input))) return Error.InvalidSubtag;
            while (true) {
                const extension_saved = cursor;
                const extension_next = try nextPart(input, &cursor) orelse break;
                if (!validExtensionPart(extension_next.bytes(input))) {
                    cursor = extension_saved;
                    break;
                }
            }
        }

        if (cursor != input.len) return Error.InvalidTag;
        return result;
    }

    /// RFC 5646 syntax (well-formedness) validation only.  This does not
    /// consult the IANA Language Subtag Registry and does not canonicalize
    /// deprecated tags or preferred values.
    pub fn validateSyntax(input: []const u8) Error!void {
        _ = try parse(input);
    }

    pub const validate = validateSyntax;

    pub fn source(self: LanguageTag) []const u8 {
        return self.original;
    }

    pub fn language(self: LanguageTag) ?[]const u8 {
        return range(self.original, self.language_start, self.language_end);
    }

    pub fn script(self: LanguageTag) ?Script {
        const bytes = range(self.original, self.script_start, self.script_end) orelse return null;
        return .{ .original = bytes };
    }

    pub fn region(self: LanguageTag) ?[]const u8 {
        return range(self.original, self.region_start, self.region_end);
    }

    pub fn subtags(self: LanguageTag) SubtagIterator {
        return .{ .input = self.original };
    }

    pub fn comparisonKey(self: LanguageTag) ComparisonKey {
        return .{ .source = self.original };
    }

    /// Writes the registry-independent canonical comparison spelling.  It is
    /// ASCII lower case, preserving subtag order and all source distinctions
    /// not declared case-significant by BCP 47.  Preferred-value replacement,
    /// variant-prefix checks, and registry canonicalization are intentionally
    /// outside this API.
    pub fn writeComparisonKey(self: LanguageTag, out: []u8) Error![]const u8 {
        return self.comparisonKey().write(out);
    }

    /// RFC 4647 basic filtering.  `range` is validated as a basic language
    /// range and is matched case-insensitively without allocating.
    pub fn matchesBasic(self: LanguageTag, range_bytes: []const u8) Error!bool {
        try validateBasicRange(range_bytes);
        if (std.mem.eql(u8, range_bytes, "*")) return true;
        if (range_bytes.len > self.original.len) return false;
        for (range_bytes, 0..) |byte, index| {
            if (!asciiEqual(byte, self.original[index])) return false;
        }
        return range_bytes.len == self.original.len or self.original[range_bytes.len] == '-';
    }

    /// RFC 4647 extended filtering.  The range is a borrowed ASCII pattern;
    /// `*` consumes no tag subtag, and a singleton in the tag stops a mismatch
    /// exactly as specified by Section 3.3.2.
    pub fn matchesExtended(self: LanguageTag, range_bytes: []const u8) Error!bool {
        try validateExtendedRange(range_bytes);
        if (std.mem.eql(u8, range_bytes, "*")) return true;

        var range_cursor: usize = 0;
        var tag_cursor: usize = 0;
        var range_part = try nextRangePart(range_bytes, &range_cursor);
        var tag_part = try nextPart(self.original, &tag_cursor);
        while (range_part) |r| {
            const rb = r.bytes(range_bytes);
            if (std.mem.eql(u8, rb, "*")) {
                range_part = try nextRangePart(range_bytes, &range_cursor);
                continue;
            }
            const t = tag_part orelse return false;
            const tb = t.bytes(self.original);
            if (asciiEql(rb, tb)) {
                tag_part = try nextPart(self.original, &tag_cursor);
                range_part = try nextRangePart(range_bytes, &range_cursor);
            } else if (t.len() == 1) {
                return false;
            } else {
                tag_part = try nextPart(self.original, &tag_cursor);
            }
        }
        return true;
    }
};

pub const ComparisonKey = struct {
    source: []const u8,

    pub fn eql(self: ComparisonKey, other: ComparisonKey) bool {
        return asciiEql(self.source, other.source);
    }

    pub fn hash(self: ComparisonKey) u64 {
        // FNV-1a over the ASCII-folded bytes.  This is an index hint, not an
        // authenticity digest; callers must still use eql after hash matches.
        var value: u64 = 0xcbf29ce484222325;
        for (self.source) |byte| {
            value ^= asciiLower(byte);
            value *%= 0x100000001b3;
        }
        return value;
    }

    pub fn write(self: ComparisonKey, out: []u8) Error![]const u8 {
        if (out.len < self.source.len) return Error.BufferTooSmall;
        for (self.source, 0..) |byte, index| out[index] = asciiLower(byte);
        return out[0..self.source.len];
    }
};

pub const SubtagIterator = struct {
    input: []const u8,
    cursor: usize = 0,

    pub fn next(self: *SubtagIterator) ?[]const u8 {
        if (self.cursor >= self.input.len) return null;
        const start = self.cursor;
        while (self.cursor < self.input.len and self.input[self.cursor] != '-') : (self.cursor += 1) {}
        const end = self.cursor;
        if (self.cursor < self.input.len) self.cursor += 1;
        return self.input[start..end];
    }
};

pub fn validateBasicRange(range_bytes: []const u8) Error!void {
    if (range_bytes.len == 0 or range_bytes.len > max_input_bytes) return Error.InvalidBasicRange;
    if (range_bytes[0] == '-' or range_bytes[range_bytes.len - 1] == '-') return Error.InvalidBasicRange;
    if (std.mem.eql(u8, range_bytes, "*")) return;
    var cursor: usize = 0;
    while (nextRangePart(range_bytes, &cursor) catch return Error.InvalidBasicRange) |part| {
        const bytes = part.bytes(range_bytes);
        if (bytes.len == 0 or bytes.len > 8 or !allAlphaNumeric(bytes) or std.mem.indexOfScalar(u8, bytes, '*') != null) return Error.InvalidBasicRange;
    }
}

pub fn validateExtendedRange(range_bytes: []const u8) Error!void {
    if (range_bytes.len == 0 or range_bytes.len > max_input_bytes) return Error.InvalidExtendedRange;
    if (range_bytes[0] == '-' or range_bytes[range_bytes.len - 1] == '-') return Error.InvalidExtendedRange;
    var cursor: usize = 0;
    while (nextRangePart(range_bytes, &cursor) catch return Error.InvalidExtendedRange) |part| {
        const bytes = part.bytes(range_bytes);
        if (std.mem.eql(u8, bytes, "*")) continue;
        if (bytes.len == 0 or bytes.len > 8 or !allAlphaNumeric(bytes)) return Error.InvalidExtendedRange;
    }
}

pub fn filterBasic(range_bytes: []const u8, tags: []const LanguageTag, output: []usize) Error!usize {
    try validateBasicRange(range_bytes);
    var count: usize = 0;
    for (tags, 0..) |tag, index| {
        if (try tag.matchesBasic(range_bytes)) {
            if (count == output.len) return Error.BufferTooSmall;
            output[count] = index;
            count += 1;
        }
    }
    return count;
}

pub fn filterExtended(range_bytes: []const u8, tags: []const LanguageTag, output: []usize) Error!usize {
    try validateExtendedRange(range_bytes);
    var count: usize = 0;
    for (tags, 0..) |tag, index| {
        if (try tag.matchesExtended(range_bytes)) {
            if (count == output.len) return Error.BufferTooSmall;
            output[count] = index;
            count += 1;
        }
    }
    return count;
}

const Part = struct {
    start: usize,
    end: usize,

    fn bytes(self: Part, input: []const u8) []const u8 {
        return input[self.start..self.end];
    }

    fn len(self: Part) usize {
        return self.end - self.start;
    }
};

fn nextPart(input: []const u8, cursor: *usize) Error!?Part {
    if (cursor.* >= input.len) return null;
    const start = cursor.*;
    while (cursor.* < input.len and input[cursor.*] != '-') : (cursor.* += 1) {}
    const end = cursor.*;
    if (end == start) return Error.InvalidSubtag;
    if (cursor.* < input.len) cursor.* += 1;
    return .{ .start = start, .end = end };
}

fn nextRangePart(input: []const u8, cursor: *usize) Error!?Part {
    if (cursor.* >= input.len) return null;
    const start = cursor.*;
    while (cursor.* < input.len and input[cursor.*] != '-') : (cursor.* += 1) {}
    const end = cursor.*;
    if (end == start) return Error.InvalidSubtag;
    if (cursor.* < input.len) cursor.* += 1;
    return .{ .start = start, .end = end };
}

fn consumePrivateTail(input: []const u8, cursor: *usize) Error!void {
    var count: usize = 0;
    while (try nextPart(input, cursor)) |part| {
        const bytes = part.bytes(input);
        if (bytes.len == 0 or bytes.len > 8 or !allAlphaNumeric(bytes)) return Error.InvalidSubtag;
        count += 1;
    }
    if (count == 0) return Error.InvalidTag;
}

fn variantSeen(input: []const u8, start: usize, end: usize, candidate: []const u8) bool {
    var cursor = start;
    while (cursor < end) {
        const part_start = cursor;
        while (cursor < end and input[cursor] != '-') : (cursor += 1) {}
        if (asciiEql(input[part_start..cursor], candidate)) return true;
        if (cursor < end) cursor += 1;
    }
    return false;
}

fn range(input: []const u8, start: ?usize, end: ?usize) ?[]const u8 {
    if (start) |s| return input[s..end.?];
    return null;
}

fn optionalLanguageEqual(left: ?LanguageTag, right: ?LanguageTag) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.comparisonKey().eql(right.?.comparisonKey());
}

fn optionalScriptEqual(left: ?Script, right: ?Script) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

fn optionalNotationEqual(left: ?Notation, right: ?Notation) bool {
    if (left == null or right == null) return left == null and right == null;
    return left.?.eql(right.?);
}

fn validLanguage(bytes: []const u8) bool {
    return (bytes.len >= 2 and bytes.len <= 3 and allAlpha(bytes)) or
        (bytes.len >= 4 and bytes.len <= 8 and allAlpha(bytes));
}

fn validVariant(bytes: []const u8) bool {
    if (!allAlphaNumeric(bytes)) return false;
    if (bytes.len >= 5 and bytes.len <= 8) return true;
    return bytes.len == 4 and isDigit(bytes[0]);
}

fn validExtensionPart(bytes: []const u8) bool {
    return bytes.len >= 2 and bytes.len <= 8 and allAlphaNumeric(bytes);
}

fn singletonBit(byte: u8) ?u64 {
    const folded = asciiLower(byte);
    if (folded >= '0' and folded <= '9') return @as(u64, 1) << @intCast(folded - '0');
    if (folded >= 'a' and folded <= 'z' and folded != 'x') return @as(u64, 1) << @intCast(10 + folded - 'a');
    return null;
}

fn isGrandfathered(input: []const u8) bool {
    // RFC 5646 Section 2.1's fixed grandfathered list.  Registry entries and
    // preferred values are intentionally not consulted here.
    const tags = [_][]const u8{
        "en-gb-oed",   "i-ami",    "i-bnn",     "i-default", "i-enochian", "i-hak",
        "i-klingon",   "i-lux",    "i-mingo",   "i-navajo",  "i-pwn",      "i-tao",
        "i-tay",       "i-tsu",    "sgn-be-fr", "sgn-be-nl", "sgn-ch-de",  "art-lojban",
        "cel-gaulish", "no-bok",   "no-nyn",    "zh-guoyu",  "zh-hakka",   "zh-min",
        "zh-min-nan",  "zh-xiang",
    };
    for (tags) |tag| if (asciiEql(input, tag)) return true;
    return false;
}

fn asciiEql(left: []const u8, right: []const u8) bool {
    if (left.len != right.len) return false;
    for (left, 0..) |byte, index| if (!asciiEqual(byte, right[index])) return false;
    return true;
}

fn asciiEqual(left: u8, right: u8) bool {
    return asciiLower(left) == asciiLower(right);
}

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn isAlpha(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn isDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isAlphaNumeric(byte: u8) bool {
    return isAlpha(byte) or isDigit(byte);
}

fn allAlpha(bytes: []const u8) bool {
    for (bytes) |byte| if (!isAlpha(byte)) return false;
    return true;
}

fn allDigit(bytes: []const u8) bool {
    for (bytes) |byte| if (!isDigit(byte)) return false;
    return true;
}

fn allAlphaNumeric(bytes: []const u8) bool {
    for (bytes) |byte| if (!isAlphaNumeric(byte)) return false;
    return true;
}

test "RFC 5646 well-formed examples preserve source and expose typed parts" {
    const zh = try LanguageTag.parse("zh-Hant-TW");
    try std.testing.expectEqualStrings("zh-Hant-TW", zh.source());
    try std.testing.expectEqualStrings("zh", zh.language().?);
    try std.testing.expectEqualStrings("Hant", zh.script().?.original);
    try std.testing.expectEqualStrings("TW", zh.region().?);

    const sr = try LanguageTag.parse("sr-Latn");
    try std.testing.expectEqualStrings("Latn", sr.script().?.original);
    try std.testing.expect((try sr.matchesBasic("SR")));
    try std.testing.expect((try sr.matchesExtended("sr-*-*")));
    try std.testing.expect(!(try sr.matchesBasic("sr-Cyrl")));
}

test "case is comparison-only and never provenance" {
    const upper = try LanguageTag.parse("MN-cYRL-mn");
    const lower = try LanguageTag.parse("mn-Cyrl-MN");
    try std.testing.expectEqualStrings("MN-cYRL-mn", upper.source());
    try std.testing.expect(upper.comparisonKey().eql(lower.comparisonKey()));
    try std.testing.expectEqual(upper.comparisonKey().hash(), lower.comparisonKey().hash());
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("mn-cyrl-mn", try upper.writeComparisonKey(&buffer));
}

test "private use, grandfathered, extensions, and hostile duplicates" {
    _ = try LanguageTag.parse("x-private-USE");
    _ = try LanguageTag.parse("EN-a-foo-x-private");
    _ = try LanguageTag.parse("i-kLiNgOn");
    _ = try LanguageTag.parse("art-lojban");
    try std.testing.expectError(Error.InvalidTag, LanguageTag.parse("x"));
    try std.testing.expectError(Error.DuplicateVariant, LanguageTag.parse("de-DE-1901-1901"));
    try std.testing.expectError(Error.DuplicateExtension, LanguageTag.parse("en-a-foo-A-bar"));
    try std.testing.expectError(Error.MissingExtensionSubtag, LanguageTag.parse("en-a"));
    try std.testing.expectError(Error.InvalidSubtag, LanguageTag.parse("en-a-b-foo"));
    try std.testing.expectError(Error.InvalidTag, LanguageTag.parse("en-x-a-"));
    try std.testing.expectError(Error.NonAscii, LanguageTag.parse("en-é"));
}

test "registry membership and Unicode normalization are intentionally outside syntax" {
    _ = try LanguageTag.parse("zzzz-QAAA-QQ-zzzzz");
    const composed = try LanguageTag.parse("en");
    const decomposed = try LanguageTag.parse("EN");
    try std.testing.expect(composed.comparisonKey().eql(decomposed.comparisonKey()));
}

test "RFC 4647 filtering and caller-owned result storage" {
    const tags = [_]LanguageTag{
        try LanguageTag.parse("de"),
        try LanguageTag.parse("de-CH-1996"),
        try LanguageTag.parse("de-Latn-DE"),
        try LanguageTag.parse("en"),
    };
    var result: [4]usize = undefined;
    const count = try filterBasic("de-CH", &tags, &result);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(usize, 1), result[0]);
    const extended_count = try filterExtended("de-*-DE", &tags, &result);
    try std.testing.expectEqual(@as(usize, 1), extended_count);
    try std.testing.expectEqual(@as(usize, 2), result[0]);
    try std.testing.expectError(Error.InvalidBasicRange, validateBasicRange("de-*-DE"));
    try std.testing.expectError(Error.InvalidExtendedRange, validateExtendedRange("de--DE"));
    try std.testing.expectError(Error.InvalidBasicRange, validateBasicRange("de-"));
    try std.testing.expectError(Error.InvalidExtendedRange, validateExtendedRange("-de"));
}

test "hostile length is rejected before duplicate scans" {
    var bytes: [max_input_bytes + 1]u8 = undefined;
    @memset(&bytes, 'a');
    try std.testing.expectError(Error.TooLong, LanguageTag.parse(&bytes));
}

test "text profile keeps language, script, direction, notation, and analysis distinct" {
    const profile = try TextProfile.init("ar", "Arab", .rtl, "ipa", .{
        .kind = .morphology,
        .name = "example-morph",
        .version = 3,
        .digest = 0x1234,
    });
    try std.testing.expectEqualStrings("ar", profile.language.?.source());
    try std.testing.expectEqualStrings("Arab", profile.script.?.original);
    try std.testing.expectEqual(Direction.rtl, profile.direction);
    try std.testing.expectEqualStrings("ipa", profile.notation.?.original);
    try std.testing.expectEqual(@as(u32, 3), profile.analysis.version);

    const source_text = .{
        .bytes = "العربية",
        .language = @as(?[]const u8, "ar"),
        .script = @as(?[]const u8, "Arab"),
        .notation = @as(?[]const u8, "orthographic"),
    };
    const bridged = try TextProfile.fromText(source_text, .rtl, .{});
    try std.testing.expect(bridged.eql(try TextProfile.init("ar", "Arab", .rtl, "orthographic", .{})));
}
