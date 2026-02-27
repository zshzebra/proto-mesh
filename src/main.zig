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

    const use_stdin = args.len < 2 or std.mem.eql(u8, args[1], "-");

    var port: ?std.fs.File = null;
    defer if (port) |p| p.close();

    const input: std.fs.File = if (use_stdin) blk: {
        break :blk std.fs.File.stdin();
    } else blk: {
        const port_path = args[1];
        const baud_rate: u32 = if (args.len > 2)
            std.fmt.parseInt(u32, args[2], 10) catch {
                try stderr.print("Invalid baud rate: {s}\n", .{args[2]});
                try stderr.flush();
                std.process.exit(1);
            }
        else
            115200;

        port = try std.fs.cwd().openFile(port_path, .{ .mode = .read_write });

        try serial.configureSerialPort(port.?, .{
            .baud_rate = baud_rate,
            .parity = .none,
            .stop_bits = .one,
            .word_size = .eight,
            .handshake = .none,
        });

        break :blk port.?;
    };

    var frame_reader = FrameReader{};
    var read_buf: [1024]u8 = undefined;

    while (true) {
        const n = input.read(&read_buf) catch |err| {
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (n == 0) break;

        frame_reader.feed(read_buf[0..n]);

        while (frame_reader.nextPacket()) |payload| {
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            var reader = std.Io.Reader.fixed(payload);
            var msg = FromRadio.decode(&reader, arena.allocator()) catch |err| {
                try stderr.print("protobuf decode error: {}\n", .{err});
                try stderr.flush();
                continue;
            };

            const json = msg.jsonEncode(.{}, arena.allocator()) catch |err| {
                try stderr.print("json encode error: {}\n", .{err});
                try stderr.flush();
                continue;
            };

            try stdout.writeAll(json);
            try stdout.writeAll("\n");
            try stdout.flush();
        }
    }
}
