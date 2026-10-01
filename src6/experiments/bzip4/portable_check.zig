//! Compile-only portability probe. This exported path forces the trainer,
//! encoder, parser, and pure Zig decoder to be code-generated without a test
//! runner or operating-system services.

const std = @import("std");
const codec = @import("codec.zig");
const bwt = @import("bwt_codec.zig");

export fn bzip4PortableCheck(input_pointer: [*]const u8, input_len: usize) u32 {
    if (input_len > 4096) return 1;
    const input = input_pointer[0..input_len];
    var backing: [256 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const allocator = fixed.allocator();
    var dictionary = codec.trainDictionary(allocator, input, @min(input.len, 512)) catch return 2;
    defer dictionary.deinit();
    var encoded = codec.encodeFrame(allocator, input, dictionary.bytes, 1024, .{}) catch return 3;
    defer encoded.deinit();
    const frame = codec.Frame.open(encoded.bytes, .{}) catch return 4;
    var decoded = frame.decodeAll(allocator) catch return 5;
    defer decoded.deinit();
    return if (std.mem.eql(u8, input, decoded.bytes)) 0 else 6;
}

export fn bzip4BwtPortableCheck(input_pointer: [*]const u8, input_len: usize) u32 {
    if (input_len == 0 or input_len > 4096) return 1;
    const input = input_pointer[0..input_len];
    var backing: [512 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&backing);
    const allocator = fixed.allocator();
    const model = bwt.trainModel(allocator, input, @min(input.len, 1024)) catch return 2;
    var encoded = bwt.encodeFrame(allocator, input, model, @min(input.len, 1024), .{}) catch return 3;
    defer encoded.deinit();
    const frame = bwt.Frame.open(encoded.bytes, .{}) catch return 4;
    var decoded = frame.decodeAll(allocator) catch return 5;
    defer decoded.deinit();
    return if (std.mem.eql(u8, input, decoded.bytes)) 0 else 6;
}
