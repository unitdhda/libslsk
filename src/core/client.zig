const std = @import("std");

const server = @import("../protocol/messages/server.zig");
const server_connection = @import("server_connection.zig");
const peer_connections = @import("peer_connections.zig");

const ServerConnection = server_connection.ServerConnection;
const PeerConnections = peer_connections.PeerConnections;

pub const ServerResult = union(enum) {
    authenticated: server.SetWaitPortRequest,
    login_rejected: server.LoginResponse.Failure,
    peer_address: peer_connections.Address,
    reverse_request: peer_connections.ReverseRequest,
    indirect_failure: peer_connections.IndirectFailure,
};

pub const Client = struct {
    server: ServerConnection,
    peers: PeerConnections,

    pub fn init(allocator: std.mem.Allocator, config: server_connection.Config) Client {
        return .{
            .server = ServerConnection.init(config),
            .peers = PeerConnections.init(allocator),
        };
    }

    pub fn deinit(self: *Client) void {
        self.peers.deinit();
    }

    fn handleLogin(
        self: *Client,
        response: server.LoginResponse,
    ) !ServerResult {
        return switch (try self.server.handleLogin(response)) {
            .authenticated => |request| .{
                .authenticated = request,
            },

            .rejected => |failure| .{
                .login_rejected = failure,
            },
        };
    }

    pub fn handleServerMessage(
        self: *Client,
        message: server.IncomingMessage,
    ) !ServerResult {
        return switch (self.server.state) {
            .disconnected => error.InvalidState,
            .logging_in => switch (message) {
                .login => |response| self.handleLogin(response),
                else => error.UnexpectedMessage,
            },
            .authenticated => switch (message) {
                .login => return error.UnexpectedMessage,
                .get_peer_address => |response| .{ .peer_address = try self.peers.handleGetPeerAddress(response) },
                .connect_to_peer => |response| .{ .reverse_request = try self.peers.handleConnectToPeer(response) },
                .cant_connect_to_peer => |response| .{ .indirect_failure = try self.peers.handleCantConnectToPeer(response) },
            },
        };
    }

    pub fn connectToPeer(self: *Client, username: []const u8) !peer_connections.BeginRequest {
        if (self.server.state != .authenticated) return error.NotAuthenticated;

        return self.peers.begin(username);
    }

    pub fn serverConnected(
        self: *Client,
    ) !server.OutgoingMessage {
        const login = try self.server.serverConnected();

        return .{
            .login = login,
        };
    }

    pub fn serverDisconnected(
        self: *Client,
    ) !void {
        try self.server.serverDisconnected();
        self.peers.reset();
    }
};

//
// TEST
//

test "client coordinates server and peer state" {
    var client = Client.init(
        std.testing.allocator,
        .{
            .login = .{
                .username = "alice",
                .password = "secret",
                .major_version = 177,
                .hash = "hash",
                .minor_version = 1,
            },
            .wait_port = 2234,
        },
    );
    defer client.deinit();

    const outgoing = try client.serverConnected();

    switch (outgoing) {
        .login => {},
        else => return error.TestUnexpectedResult,
    }

    const login = try client.handleServerMessage(.{
        .login = .{
            .success = .{
                .greet = "",
                .own_ip = 0,
                .hash = "",
                .is_supporter = false,
            },
        },
    });

    switch (login) {
        .authenticated => {},
        else => return error.TestUnexpectedResult,
    }

    _ = try client.connectToPeer("bob");

    try std.testing.expect(
        client.peers.connections.contains("bob"),
    );

    try client.serverDisconnected();

    try std.testing.expectEqual(
        server_connection.State.disconnected,
        client.server.state,
    );

    try std.testing.expectEqual(
        @as(usize, 0),
        client.peers.connections.count(),
    );
}
