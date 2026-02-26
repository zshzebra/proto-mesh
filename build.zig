const std = @import("std");
const protobuf = @import("protobuf");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protobuf_dep = b.dependency("protobuf", .{
        .target = target,
        .optimize = optimize,
    });

    const serial_dep = b.dependency("serial", .{
        .target = target,
        .optimize = optimize,
    });

    // Proto codegen step: zig build gen-proto
    const gen_proto = b.step("gen-proto", "Generate Zig files from Meshtastic protobuf definitions");

    const protoc_step = protobuf.RunProtocStep.create(protobuf_dep.builder, target, .{
        .destination_directory = b.path("src/gen"),
        .source_files = &.{"proto/meshtastic/mesh.proto"},
        .include_directories = &.{"proto/"},
    });

    gen_proto.dependOn(&protoc_step.step);

    // Main executable — depends on proto codegen
    const exe = b.addExecutable(.{
        .name = "proto-mesh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protobuf", .module = protobuf_dep.module("protobuf") },
                .{ .name = "serial", .module = serial_dep.module("serial") },
            },
        }),
    });

    exe.step.dependOn(&protoc_step.step);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run proto-mesh");
    run_step.dependOn(&run_cmd.step);
}
