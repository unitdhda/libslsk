const std = @import("std");
const server = @import("../protocol/messages/server.zig");

pub const State = enum {
    disconnected,
    logging_in,
    authenticated,
};

pub const Config = struct {
    login: server.LoginRequest,
    wait_port: u32,
};

pub const LoginResult = union(enum) {
    authenticated: server.SetWaitPortRequest,
    rejected: server.LoginResponse.Failure,
};

pub const ServerConnection = struct {
    config: Config,
    state: State,

    pub fn init(config: Config) ServerConnection {
        return .{
            .config = config,
            .state = .disconnected,
        };
    }

    pub fn serverConnected(
        self: *ServerConnection,
    ) error{InvalidState}!server.LoginRequest {
        if (self.state != .disconnected)
            return error.InvalidState;

        self.state = .logging_in;

        return self.config.login;
    }

    pub fn serverDisconnected(
        self: *ServerConnection,
    ) !void {
        switch (self.state) {
            .logging_in, .authenticated => self.state = .disconnected,
            .disconnected => return error.InvalidState,
        }
    }

    pub fn handleLogin(
        self: *ServerConnection,
        response: server.LoginResponse,
    ) error{InvalidState}!LoginResult {
        if (self.state != .logging_in) return error.InvalidState;

        return switch (response) {
            .success => {
                self.state = .authenticated;

                return .{ .authenticated = .{
                    .port = self.config.wait_port,
                } };
            },
            .failure => |failure| {
                self.state = .disconnected;

                return .{
                    .rejected = failure,
                };
            },
        };
    }
};

//
// TEST
//

test "login authenticates server connection" {
    var connection = ServerConnection.init(.{
        .login = .{
            .username = "alice",
            .password = "secret",
            .major_version = 177,
            .hash = "hash",
            .minor_version = 1,
        },
        .wait_port = 2234,
    });

    const login = try connection.serverConnected();

    try std.testing.expectEqualStrings(
        "alice",
        login.username,
    );

    const result = try connection.handleLogin(.{
        .success = .{
            .greet = "hello",
            .own_ip = 0,
            .hash = "hash",
            .is_supporter = false,
        },
    });

    switch (result) {
        .authenticated => |request| {
            try std.testing.expectEqual(
                @as(u32, 2234),
                request.port,
            );
        },
        else => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(
        State.authenticated,
        connection.state,
    );
}
