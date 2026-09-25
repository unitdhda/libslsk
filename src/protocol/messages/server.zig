const std = @import("std");
const codec = @import("../codec.zig");
const common = @import("../common.zig");
const types = @import("../types.zig");
const framing = @import("../framing.zig");

pub const OutgoingMessage = union(enum) {
    login: LoginRequest,
    set_wait_port: SetWaitPortRequest,
    get_peer_address: GetPeerAddressRequest,
    connect_to_peer: ConnectToPeerRequest,
    cant_connect_to_peer: CantConnectToPeerRequest,
};

fn encodeTypedFrame(
    writer: *codec.Writer,
    message: anytype,
) !void {
    const T = @TypeOf(message);

    const payload_size = try message.encodedSize();

    const total_size = @sizeOf(u32) + @sizeOf(u32) + payload_size;

    if (writer.remaining() < total_size) return error.NoSpace;

    try framing.writeFrameHeader(
        writer,
        u32,
        T.code,
        payload_size,
    );

    try message.encode(writer);
}

pub fn encodeFrame(
    writer: *codec.Writer,
    message: OutgoingMessage,
) !void {
    switch (message) {
        inline else => |value| {
            try encodeTypedFrame(writer, value);
        },
    }
}

pub const IncomingMessage = union(enum) {
    login: LoginResponse,
    get_peer_address: GetPeerAddressResponse,
    connect_to_peer: ConnectToPeerResponse,
    cant_connect_to_peer: CantConnectToPeerResponse,
};

pub fn decodeFrame(frame: framing.Frame(u32)) !IncomingMessage {
    var reader = codec.Reader.init(frame.payload);

    const result: IncomingMessage =
        switch (frame.code) {
            LoginResponse.code => .{
                .login = try LoginResponse.decode(&reader),
            },

            GetPeerAddressResponse.code => .{
                .get_peer_address = try GetPeerAddressResponse.decode(&reader),
            },

            ConnectToPeerResponse.code => .{
                .connect_to_peer = try ConnectToPeerResponse.decode(&reader),
            },
            CantConnectToPeerResponse => .{
                .cant_connect_to_peer = try CantConnectToPeerResponse.decode(&reader),
            },
            else => return error.UnknownMessageCode,
        };

    if (reader.remaining() != 0) return error.TrailingPayload;

    return result;
}

//
// Messages
//

pub const LoginRequest = struct {
    username: []const u8,
    password: []const u8,
    major_version: u32,
    hash: []const u8,
    minor_version: u32,

    pub const code: u32 = 1;

    pub fn encodedSize(self: LoginRequest) error{LengthOverflow}!usize {
        return common.encodedSizeWithStrings(8, &.{ self.username, self.password, self.hash });
    }

    pub fn encode(
        self: LoginRequest,
        writer: *codec.Writer,
    ) !void {
        const size = try self.encodedSize();
        if (writer.remaining() < size) return error.NoSpace;

        try writer.writeString(self.username);
        try writer.writeString(self.password);
        try writer.writeU32(self.major_version);
        try writer.writeString(self.hash);
        try writer.writeU32(self.minor_version);
    }
};

pub const LoginRejectReason = union(enum) {
    invalid_username,
    empty_password,
    invalid_password,
    invalid_version,
    server_full,
    server_private,

    unknown: []const u8,

    pub fn fromWire(
        value: []const u8,
    ) LoginRejectReason {
        if (std.mem.eql(u8, value, "INVALIDUSERNAME"))
            return .invalid_username;
        if (std.mem.eql(u8, value, "EMPTYPASSWORD"))
            return .empty_password;
        if (std.mem.eql(u8, value, "INVALIDPASS"))
            return .invalid_password;
        if (std.mem.eql(u8, value, "INVALIDVERSION"))
            return .invalid_version;
        if (std.mem.eql(u8, value, "SVRFULL"))
            return .server_full;
        if (std.mem.eql(u8, value, "SVRPRIVATE"))
            return .server_private;

        return .{ .unknown = value };
    }
};

pub const LoginResponse = union(enum) {
    success: Success,
    failure: Failure,

    pub const code = LoginRequest.code;

    pub const Success = struct {
        greet: []const u8,
        own_ip: u32,
        hash: []const u8,
        is_supporter: bool,
    };

    pub const Failure = struct {
        reason: LoginRejectReason,
        detail: ?[]const u8,
    };

    pub fn decode(
        reader: *codec.Reader,
    ) !LoginResponse {
        var probe = reader.*;

        const success = try probe.readBool();

        const result: LoginResponse =
            if (success)
                .{ .success = .{
                    .greet = try probe.readString(),
                    .own_ip = try probe.readU32(),
                    .hash = try probe.readString(),
                    .is_supporter = try probe.readBool(),
                } }
            else fail: {
                const reason = LoginRejectReason.fromWire(try probe.readString());

                const detail = switch (reason) {
                    .invalid_username => try probe.readString(),
                    else => null,
                };

                break :fail .{ .failure = .{
                    .reason = reason,
                    .detail = detail,
                } };
            };

        reader.* = probe;
        return result;
    }
};

pub const set_wait_port_code: u32 = 2;

pub const SetWaitPortRequest = struct {
    port: u32,

    pub const code = 2;

    pub fn encodedSize(_: SetWaitPortRequest) !usize {
        return @sizeOf(u32);
    }

    pub fn encode(
        self: SetWaitPortRequest,
        writer: *codec.Writer,
    ) !void {
        try writer.writeU32(self.port);
    }
};

pub const GetPeerAddressRequest = struct {
    username: []const u8,

    pub const code: u32 = 3;

    pub fn encodedSize(
        self: GetPeerAddressRequest,
    ) error{LengthOverflow}!usize {
        return common.encodedStringSize(self.username);
    }

    pub fn encode(
        self: GetPeerAddressRequest,
        writer: *codec.Writer,
    ) !void {
        const size = try self.encodedSize();

        if (writer.remaining() < size) return error.NoSpace;

        try writer.writeString(
            self.username,
        );
    }
};

pub const GetPeerAddressResponse = struct {
    username: []const u8,
    ip: u32,
    port: u32,
    obfuscation_type: u32,
    obfuscated_port: u16,

    pub const code: u32 = GetPeerAddressRequest.code;

    pub fn decode(reader: *codec.Reader) !GetPeerAddressResponse {
        var probe = reader.*;

        const result: GetPeerAddressResponse = .{
            .username = try probe.readString(),
            .ip = try probe.readU32(),
            .port = try probe.readU32(),
            .obfuscation_type = try probe.readU32(),
            .obfuscated_port = try probe.readU16(),
        };

        reader.* = probe;
        return result;
    }
};

pub const ConnectToPeerRequest = struct {
    token: u32,
    username: []const u8,
    connection_type: types.ConnectionType,

    pub const code: u32 = 18;

    pub fn encodedSize(
        self: ConnectToPeerRequest,
    ) error{LengthOverflow}!usize {
        return common.encodedSizeWithStrings(
            @sizeOf(u32),
            &.{ self.username, self.connection_type.wire() },
        );
    }

    pub fn encode(
        self: ConnectToPeerRequest,
        writer: *codec.Writer,
    ) !void {
        const size = try self.encodedSize();

        if (writer.remaining() < size) return error.NoSpace;

        try writer.writeU32(self.token);
        try writer.writeString(self.username);
        try writer.writeString(self.connection_type.wire());
    }
};

pub const ConnectToPeerResponse = struct {
    username: []const u8,
    connection_type: types.ConnectionType,
    ip: u32,
    port: u32,
    token: u32,
    privileged: bool,
    obfuscation_type: u32,
    obfuscated_port: u32,

    pub const code: u32 = ConnectToPeerRequest.code;

    pub fn decode(reader: *codec.Reader) !ConnectToPeerResponse {
        var probe = reader.*;

        const result: ConnectToPeerResponse = .{
            .username = try probe.readString(),
            .connection_type = try types.ConnectionType.fromWire(try probe.readString()),
            .ip = try probe.readU32(),
            .port = try probe.readU32(),
            .token = try probe.readU32(),
            .privileged = try probe.readBool(),
            .obfuscation_type = try probe.readU32(),
            .obfuscated_port = try probe.readU32(),
        };

        reader.* = probe;
        return result;
    }
};

pub const CantConnectToPeerRequest = struct {
    token: u32,
    username: []const u8,

    pub const code: u32 = 1001;

    pub fn encodedSize(self: CantConnectToPeerRequest) error{LengthOverflow}!usize {
        return common.encodedSizeWithStrings(@sizeOf(u32), &.{self.username});
    }

    pub fn encode(self: *CantConnectToPeerRequest, writer: *codec.Writer) !void {
        const size = try self.encodedSize();

        if (writer.remaining() < size) {
            return error.NoSpace;
        }

        try writer.writeU32(self.token);
        try writer.writeString(self.username);
    }
};

pub const CantConnectToPeerResponse = struct {
    token: u32,

    pub const code: u32 = CantConnectToPeerRequest.code;

    pub fn decode(reader: *codec.Reader) !CantConnectToPeerResponse {
        var probe = reader.*;

        const result: CantConnectToPeerResponse = .{
            .token = try probe.readU32(),
        };

        reader.* = probe;
        return result;
    }
};

//
// TEST
//

test "Login request and response" {
    var storage: [128]u8 = undefined;
    var writer = codec.Writer.init(&storage);

    try (LoginRequest{
        .username = "alice",
        .password = "secret",
        .major_version = 177,
        .hash = "hash",
        .minor_version = 1,
    }).encode(&writer);

    var request = codec.Reader.init(writer.written());

    try std.testing.expectEqualStrings("alice", try request.readString());
    try std.testing.expectEqualStrings("secret", try request.readString());
    try std.testing.expectEqual(@as(u32, 177), try request.readU32());
    try std.testing.expectEqualStrings("hash", try request.readString());
    try std.testing.expectEqual(@as(u32, 1), try request.readU32());

    writer = codec.Writer.init(&storage);

    try writer.writeBool(true);
    try writer.writeString("hello");
    try writer.writeU32(42);
    try writer.writeString("hash");
    try writer.writeBool(false);

    var response_reader = codec.Reader.init(writer.written());
    const response = try LoginResponse.decode(&response_reader);

    switch (response) {
        .success => |value| {
            try std.testing.expectEqualStrings("hello", value.greet);
            try std.testing.expectEqual(@as(u32, 42), value.own_ip);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GetPeerAddress request and response" {
    var storage: [64]u8 = undefined;
    var writer = codec.Writer.init(&storage);

    try (GetPeerAddressRequest{
        .username = "bob",
    }).encode(&writer);

    var request = codec.Reader.init(writer.written());
    try std.testing.expectEqualStrings("bob", try request.readString());

    writer = codec.Writer.init(&storage);

    try writer.writeString("bob");
    try writer.writeU32(42);
    try writer.writeU32(2234);
    try writer.writeU32(0);
    try writer.writeU16(0);

    var reader = codec.Reader.init(writer.written());
    const response = try GetPeerAddressResponse.decode(&reader);

    try std.testing.expectEqualStrings("bob", response.username);
    try std.testing.expectEqual(@as(u32, 2234), response.port);
}

test "ConnectToPeer request and response" {
    var storage: [128]u8 = undefined;
    var writer = codec.Writer.init(&storage);

    try (ConnectToPeerRequest{
        .token = 42,
        .username = "bob",
        .connection_type = .peer,
    }).encode(&writer);

    var request = codec.Reader.init(writer.written());

    try std.testing.expectEqual(@as(u32, 42), try request.readU32());
    try std.testing.expectEqualStrings("bob", try request.readString());
    try std.testing.expectEqualStrings("P", try request.readString());

    writer = codec.Writer.init(&storage);

    try writer.writeString("bob");
    try writer.writeString("P");
    try writer.writeU32(123);
    try writer.writeU32(2234);
    try writer.writeU32(42);
    try writer.writeBool(false);
    try writer.writeU32(0);
    try writer.writeU32(0);

    var reader = codec.Reader.init(writer.written());
    const response = try ConnectToPeerResponse.decode(&reader);

    try std.testing.expectEqual(@as(u32, 42), response.token);
    try std.testing.expectEqual(types.ConnectionType.peer, response.connection_type);
}
