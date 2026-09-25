const std = @import("std");
const server = @import("../protocol/messages/server.zig");

pub const Address = struct { ip: u32, port: u32 };

pub const PeerAddress = struct {
    username: []const u8,
    address: Address,
};

pub const ReverseRequest = struct {
    username: []const u8,
    token: u32,
    address: Address,
};

pub const PeerConnection = struct {
    outgoing_token: ?u32 = null,
    direct_address: ?Address = null,
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
    allocator: std.mem.Allocator,
    connections: std.StringHashMap(PeerConnection),
    next_token: u32,

    pub fn init(
        allocator: std.mem.Allocator,
    ) PeerConnections {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(PeerConnection).init(allocator),
            .next_token = 1,
        };
    }

    pub fn deinit(self: *PeerConnections) void {
        self.reset();
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

        const owned_username = try self.allocator.dupe(u8, username);

        errdefer self.allocator.free(owned_username);

        try self.connections.put(
            owned_username,
            .{
                .outgoing_token = token,
            },
        );
        self.next_token = next_token;

        return .{ .connect = .{
            .token = token,
            .username = owned_username,
            .connection_type = .peer,
        }, .address = .{
            .username = owned_username,
        } };
    }

    pub fn handleGetPeerAddress(self: *PeerConnections, response: server.GetPeerAddressResponse) !Address {
        if (response.obfuscation_type != 0) return error.UnsupportedObfuscation;

        const entry = self.connections.getEntry(response.username) orelse return error.UnknownPeerConnection;

        if (entry.value_ptr.direct_address != null) return error.AddressAlreadyResolved;

        const address: Address = .{
            .ip = response.ip,
            .port = response.port,
        };

        entry.value_ptr.direct_address = address;

        return address;
    }

    pub fn handleConnectToPeer(
        self: *PeerConnections,
        response: server.ConnectToPeerResponse,
    ) !ReverseRequest {
        if (response.connection_type != .peer) return error.UnsupportedConnectionType;
        if (response.obfuscation_type != 0) return error.UnsupportedObfuscation;

        const username: []const u8, const connection: *PeerConnection =
            if (self.connections.getEntry(response.username)) |entry|
                .{ entry.key_ptr.*, entry.value_ptr }
            else create: {
                const owned = try self.allocator.dupe(u8, response.username);

                errdefer self.allocator.free(owned);

                try self.connections.put(owned, .{});

                break :create .{
                    owned,
                    self.connections.getPtr(owned).?,
                };
            };

        if (connection.reverse_request != null) return error.ReverseRequestAlreadyExists;

        const reverse: ReverseRequest = .{ .username = username, .token = response.token, .address = .{
            .ip = response.ip,
            .port = response.port,
        } };

        connection.reverse_request = reverse;

        return .{
            .username = username,
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
                return .{ .username = entry.key_ptr.* };
            }
        }
        return error.UnknownPeerToken;
    }

    pub fn reset(self: *PeerConnections) void {
        var iterator = self.connections.iterator();

        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.connections.clearRetainingCapacity();
    }
};

//
// TEST
//

test "peer negotiation state is merged per user" {
    var peers = PeerConnections.init(std.testing.allocator);
    defer peers.deinit();

    const begin = try peers.begin("bob");
    const token = begin.connect.token;

    const direct = try peers.handleGetPeerAddress(.{
        .username = "bob",
        .ip = 123,
        .port = 2234,
        .obfuscation_type = 0,
        .obfuscated_port = 0,
    });

    try std.testing.expectEqual(@as(u32, 2234), direct.port);

    const reverse = try peers.handleConnectToPeer(.{
        .username = "bob",
        .connection_type = .peer,
        .ip = 123,
        .port = 2234,
        .token = 42,
        .privileged = false,
        .obfuscation_type = 0,
        .obfuscated_port = 0,
    });

    try std.testing.expectEqual(@as(u32, 42), reverse.token);

    _ = try peers.handleCantConnectToPeer(.{
        .token = token,
    });

    const connection = peers.connections.get("bob").?;

    try std.testing.expectEqual(null, connection.outgoing_token);
    try std.testing.expectEqual(
        @as(u32, 2234),
        connection.direct_address.?.port,
    );
    try std.testing.expectEqual(
        @as(u32, 42),
        connection.reverse_request.?.token,
    );
}
