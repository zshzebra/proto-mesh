const std = @import("std");

const START1: u8 = 0x94;
const START2: u8 = 0xC3;
const MAX_PAYLOAD: u16 = 512;
const HEADER_SIZE: usize = 4;

pub const FrameReader = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    /// Append incoming bytes to the internal buffer.
    pub fn feed(self: *FrameReader, data: []const u8) void {
        const space = self.buf.len - self.len;
        const n = @min(data.len, space);
        @memcpy(self.buf[self.len..][0..n], data[0..n]);
        self.len += n;
    }

    /// Try to extract the next complete packet payload from the buffer.
    /// Returns the protobuf payload slice, or null if no complete packet is available.
    /// On success the consumed bytes (header + payload) are removed from the buffer.
    pub fn nextPacket(self: *FrameReader) ?[]const u8 {
        while (true) {
            // Find magic header
            const start = findMagic(self.buf[0..self.len]) orelse {
                // No magic found — discard everything except the last byte
                // (which could be START1 of a split header)
                if (self.len > 0) {
                    if (self.buf[self.len - 1] == START1) {
                        self.buf[0] = START1;
                        self.len = 1;
                    } else {
                        self.len = 0;
                    }
                }
                return null;
            };

            // Discard bytes before the magic
            if (start > 0) {
                self.shift(start);
            }

            // Need at least the 4-byte header
            if (self.len < HEADER_SIZE) return null;

            const payload_len: u16 = @as(u16, self.buf[2]) << 8 | self.buf[3];

            // Corrupted length — skip this magic byte and try again
            if (payload_len > MAX_PAYLOAD or payload_len == 0) {
                self.shift(1);
                continue;
            }

            const frame_len = HEADER_SIZE + payload_len;

            // Need more data
            if (self.len < frame_len) return null;

            // Extract payload (valid until next feed/nextPacket call)
            const payload = self.buf[HEADER_SIZE..frame_len];

            // Remove consumed frame
            self.shift(frame_len);

            return payload;
        }
    }

    fn shift(self: *FrameReader, n: usize) void {
        const remaining = self.len - n;
        if (remaining > 0) {
            std.mem.copyForwards(u8, self.buf[0..remaining], self.buf[n..self.len]);
        }
        self.len = remaining;
    }

    fn findMagic(data: []const u8) ?usize {
        if (data.len < 2) return null;
        for (0..data.len - 1) |i| {
            if (data[i] == START1 and data[i + 1] == START2) {
                return i;
            }
        }
        return null;
    }
};

test "basic packet extraction" {
    var fr = FrameReader{};

    // Feed a valid frame: magic + length(3) + 3 bytes payload
    fr.feed(&[_]u8{ 0x94, 0xC3, 0x00, 0x03, 0xAA, 0xBB, 0xCC });

    const pkt = fr.nextPacket();
    try std.testing.expect(pkt != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, pkt.?);

    // No more packets
    try std.testing.expect(fr.nextPacket() == null);
}

test "skip garbage before packet" {
    var fr = FrameReader{};

    // Garbage then valid frame
    fr.feed(&[_]u8{ 0xFF, 0xFE, 0x01, 0x94, 0xC3, 0x00, 0x02, 0x11, 0x22 });

    const pkt = fr.nextPacket();
    try std.testing.expect(pkt != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22 }, pkt.?);
}

test "incomplete packet returns null" {
    var fr = FrameReader{};

    // Header says 5 bytes but only 2 provided
    fr.feed(&[_]u8{ 0x94, 0xC3, 0x00, 0x05, 0xAA, 0xBB });
    try std.testing.expect(fr.nextPacket() == null);

    // Feed remaining bytes
    fr.feed(&[_]u8{ 0xCC, 0xDD, 0xEE });
    const pkt = fr.nextPacket();
    try std.testing.expect(pkt != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE }, pkt.?);
}

test "skip invalid length" {
    var fr = FrameReader{};

    // First "packet" has length > 512 (0x02, 0x01 = 513), should be skipped
    // Second packet is valid
    fr.feed(&[_]u8{
        0x94, 0xC3, 0x02, 0x01, // bad length = 513
        0x94, 0xC3, 0x00, 0x01, 0xFF, // good packet, payload = 0xFF
    });

    const pkt = fr.nextPacket();
    try std.testing.expect(pkt != null);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xFF}, pkt.?);
}
