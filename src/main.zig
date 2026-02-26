const std = @import("std");
const protobuf = @import("protobuf");
const serial = @import("serial");
const FrameReader = @import("framing.zig").FrameReader;
const meshtastic = @import("gen/meshtastic.pb.zig");
const FromRadio = meshtastic.FromRadio;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buf: [8192]u8 = undefined;
    var stdout_fw = std.fs.File.stdout().writer(&stdout_buf);
    var stdout = &stdout_fw.interface;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_fw = std.fs.File.stderr().writer(&stderr_buf);
    var stderr = &stderr_fw.interface;

    if (args.len < 2) {
        try stderr.print("Usage: proto-mesh <serial-port> [baud-rate]\n", .{});
        try stderr.print("  e.g. proto-mesh /dev/ttyUSB0\n", .{});
        try stderr.flush();
        std.process.exit(1);
    }

    const port_path = args[1];
    const baud_rate: u32 = if (args.len > 2)
        std.fmt.parseInt(u32, args[2], 10) catch {
            try stderr.print("Invalid baud rate: {s}\n", .{args[2]});
            try stderr.flush();
            std.process.exit(1);
        }
    else
        115200;

    var port = try std.fs.cwd().openFile(port_path, .{ .mode = .read_write });
    defer port.close();

    try serial.configureSerialPort(port, .{
        .baud_rate = baud_rate,
        .parity = .none,
        .stop_bits = .one,
        .word_size = .eight,
        .handshake = .none,
    });

    var frame_reader = FrameReader{};
    var read_buf: [1024]u8 = undefined;

    while (true) {
        const n = port.read(&read_buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (n == 0) continue;

        frame_reader.feed(read_buf[0..n]);

        while (frame_reader.nextPacket()) |payload| {
            var reader = std.Io.Reader.fixed(payload);
            var msg = FromRadio.decode(&reader, allocator) catch |err| {
                try stderr.print("protobuf decode error: {}\n", .{err});
                try stderr.flush();
                continue;
            };
            defer msg.deinit(allocator);

            const json = msg.jsonEncode(.{}, allocator) catch |err| {
                try stderr.print("json encode error: {}\n", .{err});
                try stderr.flush();
                continue;
            };
            defer allocator.free(json);

            try stdout.writeAll(json);
            try stdout.writeAll("\n");
            try stdout.flush();
        }
    }
}
