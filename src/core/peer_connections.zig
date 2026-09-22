const std = @import("std");
const server = @import("../protocol/messages/server.zig");

pub const PeerAddress = struct {
    username: []const u8,
    ip: u32,
    port: u32,
};

pub const ReverseRequest = struct {
    username: []const u8,
    token: u32,
    address: PeerAddress,
};

pub const PeerConnection = struct {
    outgoing_token: ?u32 = null,
    direct_address: ?PeerAddress = null,
    reverse_request: ?ReverseRequest = null,
};

pub const BeginRequest = struct {
    connect: server.ConnectToPeerRequest,
    address: server.GetPeerAddressRequest,
};

pub const IndirectFailure = struct {
    username: []const u8,
};

pub const PeerConnections = struct {
    connections: std.StringHashMap(PeerConnection),
    next_token: u32,

    pub fn init(
        allocator: std.mem.Allocator,
    ) PeerConnections {
        return .{
            .connections = std.StringHashMap(PeerConnection).init(allocator),
            .next_token = 1,
        };
    }

    pub fn deinit(self: *PeerConnections) void {
        self.connections.deinit();
    }

    pub fn begin(
        self: *PeerConnections,
        username: []const u8,
    ) !BeginRequest {
        if (self.connections.contains(username)) return error.ConnectionAlreadyExists;

        const token = self.next_token;

        const next_token = std.math.add(
            u32,
            token,
            1,
        ) catch return error.TokenExhausted;

        try self.connections.put(
            username,
            .{
                .outgoing_token = token,
            },
        );
        self.next_token = next_token;

        return .{ .connect = .{
            .token = token,
            .username = username,
            .connection_type = .peer,
        }, .address = .{
            .username = username,
        } };
    }

    pub fn handleGetPeerAddress(self: *PeerConnections, response: server.GetPeerAddressResponse) !PeerAddress {
        if (response.obfuscation_type != 0) return error.UnsupportedObfuscation;

        const connection = self.connections.getPtr(response.username) orelse return error.UnknownPeerConnection;

        if (connection.direct_address != null) return error.AddressAlreadyResolved;

        const address: PeerAddress = .{
            .username = response.username,
            .ip = response.ip,
            .port = response.port,
        };

        connection.direct_address = address;

        return address;
    }

    pub fn handleConnectToPeer(
        self: *PeerConnections,
        response: server.ConnectToPeerResponse,
    ) !ReverseRequest {
        if (response.connection_type != .peer) return error.UnsupportedConnectionType;
        if (response.obfuscation_type != 0) return error.UnsupportedObfuscation;

        const reverse: ReverseRequest = .{ .username = response.username, .token = response.token, .address = .{
            .username = response.username,
            .ip = response.ip,
            .port = response.port,
        } };

        const entry = try self.connections.getOrPut(response.username);

        if (!entry.found_existing) {
            entry.value_ptr.* = .{};
        } else if (entry.value_ptr.reverse_request != null) {
            return error.ReverseRequestAlreadyExists;
        }

        entry.value_ptr.reverse_request = reverse;

        return .{
            .username = response.username,
            .token = reverse.token,
            .address = reverse.address,
        };
    }

    pub fn handleCantConnectToPeer(
        self: *PeerConnections,
        response: server.CantConnectToPeerResponse,
    ) !IndirectFailure {
        var iterator = self.connections.iterator();
        while (iterator.next()) |entry| {
            const connection = entry.value_ptr;

            if (connection.outgoing_token == response.token) {
                connection.outgoing_token = null;
            }

            return .{ .username = entry.key_ptr.* };
        }
        return error.UnknownPeerConnection;
    }

    pub fn reset(self: *PeerConnections) void {
        self.connections.clearRetainingCapacity();
    }
};

test "peer connection lifecycle state is merged per user" {
    var peers = PeerConnections.init(std.testing.allocator);
    defer peers.deinit();

    const request = try peers.begin("bob");

    try std.testing.expectEqual(
        request.connect.token,
        peers.connections.get("bob").?.outgoing_token.?,
    );

    _ = try peers.handleGetPeerAddress(.{
        .username = "bob",
        .ip = 123,
        .port = 2234,
        .obfuscation_type = 0,
        .obfuscated_port = 0,
    });

    _ = try peers.handleConnectToPeer(.{
        .username = "bob",
        .connection_type = .peer,
        .ip = 123,
        .port = 2234,
        .token = 42,
        .privileged = false,
        .obfuscation_type = 0,
        .obfuscated_port = 0,
    });

    const connection = peers.connections.get("bob").?;

    try std.testing.expectEqual(
        @as(u32, 2234),
        connection.direct_address.?.port,
    );

    try std.testing.expectEqual(
        @as(u32, 42),
        connection.reverse_request.?.token,
    );

    try std.testing.expectEqual(
        request.connect.token,
        connection.outgoing_token.?,
    );

    try std.testing.expectError(
        error.ConnectionAlreadyExists,
        peers.begin("bob"),
    );
}

test "peer connection server negotiation" {
    var peers = PeerConnections.init(std.testing.allocator);
    defer peers.deinit();

    // We initiate connection to Bob.
    const begin = try peers.begin("bob");
    const outgoing_token = begin.connect.token;

    try std.testing.expectEqual(
        outgoing_token,
        peers.connections.get("bob").?.outgoing_token.?,
    );

    // Direct path resolves Bob's address.
    _ = try peers.handleGetPeerAddress(.{
        .username = "bob",
        .ip = 123,
        .port = 2234,
        .obfuscation_type = 0,
        .obfuscated_port = 0,
    });

    // Reverse path may arrive independently with its own token.
    _ = try peers.handleConnectToPeer(.{
        .username = "bob",
        .connection_type = .peer,
        .ip = 123,
        .port = 2234,
        .token = 42,
        .privileged = false,
        .obfuscation_type = 0,
        .obfuscated_port = 0,
    });

    var connection = peers.connections.get("bob").?;

    try std.testing.expectEqual(
        @as(u32, 2234),
        connection.direct_address.?.port,
    );

    try std.testing.expectEqual(
        @as(u32, 42),
        connection.reverse_request.?.token,
    );

    // Our token and the remote reverse token are separate.
    try std.testing.expectEqual(
        outgoing_token,
        connection.outgoing_token.?,
    );

    // Server reports our indirect path failed.
    _ = try peers.handleCantConnectToPeer(.{
        .token = outgoing_token,
    });

    connection = peers.connections.get("bob").?;

    try std.testing.expectEqual(
        null,
        connection.outgoing_token,
    );

    // Other information about Bob survives that failure.
    try std.testing.expect(connection.direct_address != null);
    try std.testing.expect(connection.reverse_request != null);
}
