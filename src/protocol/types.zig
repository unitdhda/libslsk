const std = @import("std");

pub const ConnectionType = enum {
    peer,
    file,
    distributed,

    pub fn wire(
        self: ConnectionType,
    ) []const u8 {
        return switch (self) {
            .peer => "P",
            .file => "F",
            .distributed => "D",
        };
    }

    pub fn fromWire(
        value: []const u8,
    ) error{InvalidConnectionType}!ConnectionType {
        if (value.len != 1) return error.InvalidConnectionType;

        return switch (value[0]) {
            'P' => .peer,
            'F' => .file,
            'D' => .distributed,
            else => error.InvalidConnectionType,
        };
    }
};
