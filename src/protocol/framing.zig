const std = @import("std");
const codec = @import("codec.zig");

fn validateCodeType(comptime Code: type) void {
    if (Code != u8 and Code != u32) {
        @compileError("frame code type must be u8 or u32");
    }
}

pub fn Frame(comptime Code: type) type {
    validateCodeType(Code);

    return struct {
        code: Code,
        payload: []const u8,
    };
}

pub fn ReadResult(comptime Code: type) type {
    validateCodeType(Code);

    return union(enum) {
        incomplete,
        frame: Frame(Code),
    };
}

pub fn readFrame(
    reader: *codec.Reader,
    comptime Code: type,
) !ReadResult(Code) {
    validateCodeType(Code);

    var probe = reader.*;

    const body_len = probe.readU32() catch return .incomplete;

    if (body_len < @sizeOf(Code)) return error.InvalidLength;

    if (probe.remaining() < body_len) return .incomplete;

    const code = switch (Code) {
        u8 => probe.readU8() catch unreachable,
        u32 => probe.readU32() catch unreachable,
        else => unreachable,
    };

    const payload = probe.readSlice(@as(usize, body_len) - @sizeOf(Code)) catch unreachable;

    reader.* = probe;

    return .{
        .frame = .{
            .code = code,
            .payload = payload,
        },
    };
}

pub fn writeFrameHeader(
    writer: *codec.Writer,
    comptime Code: type,
    code: Code,
    payload_len: usize,
) error{
    NoSpace,
    LengthOverflow,
}!void {
    validateCodeType(Code);

    const body_len = std.math.add(
        usize,
        @sizeOf(Code),
        payload_len,
    ) catch return error.LengthOverflow;

    if (body_len > std.math.maxInt(u32)) return error.LengthOverflow;

    const total_header_len = @sizeOf(u32) + @sizeOf(Code);

    if (writer.remaining() < total_header_len) return error.NoSpace;

    try writer.writeU32(@intCast(body_len));

    switch (Code) {
        u8 => try writer.writeU8(code),
        u32 => try writer.writeU32(code),
        else => unreachable,
    }
}

pub fn writeFrame(
    writer: *codec.Writer,
    comptime Code: type,
    code: Code,
    payload: []const u8,
) error{ NoSpace, LengthOverflow }!void {
    validateCodeType(Code);

    const total_len = std.math.add(
        usize,
        @sizeOf(u32) + @sizeOf(Code),
        payload.len,
    ) catch return error.LengthOverflow;

    if (writer.remaining() < total_len) return error.NoSpace;

    try writeFrameHeader(
        writer,
        Code,
        code,
        payload.len,
    );
    try writer.writeSlice(payload);
}

test "frame writer and reader round-trip" {
    var storage: [32]u8 = undefined;
    var writer = codec.Writer.init(&storage);

    try writeFrame(&writer, u32, 18, "abc");

    var reader = codec.Reader.init(writer.written());

    const frame = switch (try readFrame(&reader, u32)) {
        .frame => |value| value,
        .incomplete => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(u32, 18), frame.code);
    try std.testing.expectEqualStrings("abc", frame.payload);
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());
}

test "incomplete frame is not consumed" {
    var reader = codec.Reader.init(&.{
        7,  0, 0, 0,
        18, 0,
    });

    try std.testing.expectEqual(
        ReadResult(u32).incomplete,
        try readFrame(&reader, u32),
    );

    try std.testing.expectEqual(@as(usize, 0), reader.consumed());
}
