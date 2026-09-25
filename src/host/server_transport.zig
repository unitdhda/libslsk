const std = @import("std");

const codec = @import("../protocol/codec.zig");
const server = @import("../protocol/messages/server.zig");
const Client = @import("../core/client.zig").Client;

pub const ServerTransport = struct {
    io: std.Io,
    stream: std.Io.net.Stream,

    pub fn connect(
        io: std.Io,
        host: []const u8,
        port: u16,
    ) !ServerTransport {
        const hostname = try std.Io.net.HostName.init(host);

        const stream =
            try hostname.connect(
                io,
                port,
                .{ .mode = .stream },
            );

        return .{
            .io = io,
            .stream = stream,
        };
    }

    pub fn close(self: *ServerTransport) void {
        self.stream.close(self.io);
    }

    pub fn send(self: *ServerTransport, message: server.OutgoingMessage) !void {
        var encoded: [4096]u8 = undefined;
        var protocol_writer = codec.Writer.init(&encoded);

        try server.encodeFrame(&protocol_writer, message);

        var network_buffer: [4096]u8 = undefined;
        var network_writer = self.stream.writer(self.io, &network_buffer);

        try network_writer.interface.writeAll(
            protocol_writer.written(),
        );
    }
};

//
// TEST
//
