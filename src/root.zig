const std = @import("std");
const protobuf = @import("protobuf");
const meshtastic = @import("gen/meshtastic.pb.zig");

pub const FrameReader = @import("framing.zig").FrameReader;
pub const FromRadio = meshtastic.FromRadio;

/// Decode a single protobuf payload into a FromRadio message using an arena.
/// Returns the JSON representation. The caller must deinit the arena to free all memory.
pub fn decodeFromRadio(arena: *std.heap.ArenaAllocator, payload: []const u8) ![]const u8 {
    var reader = std.Io.Reader.fixed(payload);
    var msg = try FromRadio.decode(&reader, arena.allocator());
    return msg.jsonEncode(.{}, arena.allocator());
}

test "decode queue status" {
    // Synthetic FromRadio with queueStatus: free=5, maxlen=8
    const payload = &[_]u8{ 0x5a, 0x04, 0x10, 0x05, 0x18, 0x08 };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json = try decodeFromRadio(&arena, payload);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"queueStatus\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"free\":5") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"maxlen\":8") != null);
}

test "decode encrypted mesh packet" {
    // Synthetic FromRadio with MeshPacket: from=0xAABBCCDD, to=broadcast, hopLimit=3, encrypted payload
    const payload = &[_]u8{
        0x12, 0x1e, 0x0d, 0xdd, 0xcc, 0xbb, 0xaa, 0x15,
        0xff, 0xff, 0xff, 0xff, 0x48, 0x03, 0x2a, 0x10,
        0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
        0xde, 0xad, 0xbe, 0xef, 0xde, 0xad, 0xbe, 0xef,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json = try decodeFromRadio(&arena, payload);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"encrypted\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"from\":2864434397") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"hopLimit\":3") != null);
}

test "decode minimal mesh packet" {
    // Synthetic FromRadio with MeshPacket: just from + to, all defaults
    const payload = &[_]u8{
        0x12, 0x0a, 0x0d, 0x01, 0x02, 0x03, 0x04, 0x15,
        0xff, 0xff, 0xff, 0xff,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const json = try decodeFromRadio(&arena, payload);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"packet\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"from\":67305985") != null);
}

test "truncated packet returns error without leaking" {
    // Truncated MeshPacket — claims 0x1e bytes but only 14 provided
    const payload = &[_]u8{
        0x12, 0x1e, 0x0d, 0xdd, 0xcc, 0xbb, 0xaa, 0x15,
        0xff, 0xff, 0xff, 0xff, 0x48, 0x03, 0x2a, 0x10,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    // Should error, and arena.deinit() cleans up any partial allocations
    try std.testing.expectError(error.EndOfStream, decodeFromRadio(&arena, payload));
}
