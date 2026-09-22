const std = @import("std");

pub const Reader = struct {
    data: []const u8,
    pos: usize,

    pub fn init(data: []const u8) Reader {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    fn ensureAvailable(
        self: Reader,
        n: usize,
    ) error{UnexpectedEnd}!void {
        if (self.pos > self.data.len) return error.UnexpectedEnd;
        if (n > self.data.len - self.pos) return error.UnexpectedEnd;
    }

    fn readInt(self: *Reader, comptime T: type) error{UnexpectedEnd}!T {
        try self.ensureAvailable(@sizeOf(T));

        const value = std.mem.readInt(T, self.data[self.pos..][0..@sizeOf(T)], .little);
        self.pos += @sizeOf(T);

        return value;
    }

    pub fn readU8(self: *Reader) !u8 {
        return self.readInt(u8);
    }
    pub fn readU16(self: *Reader) !u16 {
        return self.readInt(u16);
    }
    pub fn readU32(self: *Reader) !u32 {
        return self.readInt(u32);
    }
    pub fn readU64(self: *Reader) !u64 {
        return self.readInt(u64);
    }
    pub fn readBool(
        self: *Reader,
    ) error{
        UnexpectedEnd,
        InvalidBool,
    }!bool {
        const value = try self.readU8();
        return switch (value) {
            0 => false,
            1 => true,
            else => return error.InvalidBool,
        };
    }

    pub fn readSlice(
        self: *Reader,
        len: usize,
    ) error{UnexpectedEnd}![]const u8 {
        try self.ensureAvailable(len);

        const start = self.pos;
        const end = start + len;

        self.pos = end;

        return self.data[start..end];
    }

    pub fn readBytes(self: *Reader) error{UnexpectedEnd}![]const u8 {
        var probe = self.*;

        const len = try probe.readU32();

        const bytes = try probe.readSlice(
            @intCast(len),
        );
        self.* = probe;

        return bytes;
    }

    pub fn readString(
        self: *Reader,
    ) error{UnexpectedEnd}![]const u8 {
        return self.readBytes();
    }

    pub fn remaining(self: Reader) usize {
        std.debug.assert(self.pos <= self.data.len);
        return (self.data.len - self.pos);
    }

    pub fn consumed(self: Reader) usize {
        return self.pos;
    }
};

pub const Writer = struct {
    data: []u8,
    pos: usize,

    pub fn init(data: []u8) Writer {
        return .{
            .data = data,
            .pos = 0,
        };
    }

    fn ensureAvailable(
        self: Writer,
        n: usize,
    ) error{NoSpace}!void {
        if (self.pos > self.data.len) return error.NoSpace;
        if (n > self.data.len - self.pos) return error.NoSpace;
    }

    fn writeInt(self: *Writer, comptime T: type, value: T) error{NoSpace}!void {
        try self.ensureAvailable(@sizeOf(T));

        std.mem.writeInt(T, self.data[self.pos..][0..@sizeOf(T)], value, .little);

        self.pos += @sizeOf(T);
    }

    pub fn writeU8(self: *Writer, value: u8) !void {
        try self.writeInt(u8, value);
    }
    pub fn writeU16(self: *Writer, value: u16) !void {
        try self.writeInt(u16, value);
    }
    pub fn writeU32(self: *Writer, value: u32) !void {
        try self.writeInt(u32, value);
    }
    pub fn writeU64(self: *Writer, value: u64) !void {
        try self.writeInt(u64, value);
    }

    pub fn remaining(
        self: Writer,
    ) usize {
        std.debug.assert(self.pos <= self.data.len);

        return self.data.len - self.pos;
    }

    pub fn written(
        self: Writer,
    ) []const u8 {
        return self.data[0..self.pos];
    }

    pub fn writeBool(
        self: *Writer,
        value: bool,
    ) error{NoSpace}!void {
        try self.writeU8(
            if (value) 1 else 0,
        );
    }

    pub fn writeSlice(
        self: *Writer,
        value: []const u8,
    ) error{NoSpace}!void {
        try self.ensureAvailable(value.len);

        const end = self.pos + value.len;

        @memcpy(
            self.data[self.pos..end],
            value,
        );

        self.pos = end;
    }

    pub fn writeBytes(self: *Writer, value: []const u8) error{ NoSpace, LengthOverflow }!void {
        if (value.len > std.math.maxInt(u32)) {
            return error.LengthOverflow;
        }

        const total_len = std.math.add(
            usize,
            @sizeOf(u32),
            value.len,
        ) catch return error.LengthOverflow;

        try self.ensureAvailable(total_len);

        try self.writeU32(@intCast(value.len));

        try self.writeSlice(value);
    }

    pub fn writeString(
        self: *Writer,
        value: []const u8,
    ) error{
        NoSpace,
        LengthOverflow,
    }!void {
        try self.writeBytes(value);
    }
};

test "Reader and Writer round-trip" {
    var storage: [32]u8 = undefined;
    var writer = Writer.init(&storage);

    try writer.writeU16(0x1234);
    try writer.writeBool(true);
    try writer.writeString("bob");

    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x34, 0x12, 1, 3, 0, 0, 0, 'b', 'o', 'b' },
        writer.written(),
    );

    var reader = Reader.init(writer.written());

    try std.testing.expectEqual(@as(u16, 0x1234), try reader.readU16());
    try std.testing.expect(try reader.readBool());
    try std.testing.expectEqualStrings("bob", try reader.readString());
    try std.testing.expectEqual(@as(usize, 0), reader.remaining());
}
