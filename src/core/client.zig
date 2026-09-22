const std = @import("std");

const server = @import("../protocol/messages/server.zig");
const server_connection = @import("server_connection.zig");
const peer_connections = @import("peer_connections.zig");

const ServerConnection = server_connection.ServerConnection;
const PeerConnections = peer_connections.PeerConnections;

pub const ServerResult = union(enum) {
    authenticated: server.SetWaitPortRequest,
    login_rejected: server.LoginResponse.Failure,
    peer_address: peer_connections.PeerAddress,
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
        return switch (message) {
            .login => |response| self.handleLogin(response),
            .get_peer_address => |response| .{ .peer_address = try self.peers.handleGetPeerAddress(response) },
            .connect_to_peer => |response| .{ .reverse_request = try self.peers.handleConnectToPeer(response) },
            .cant_connect_to_peer => |response| .{ .indirect_failure = try self.peers.handleCantConnectToPeer(response) },
        };
    }
};
