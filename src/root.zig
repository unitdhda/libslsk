pub const protocol = @import("protocol/root.zig");
pub const core = @import("core/root.zig");
pub const host = @import("host/root.zig");

test "root imports package layers" {
    _ = protocol;
    _ = core;
    _ = host;
}
