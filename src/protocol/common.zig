const std = @import("std");

pub fn encodedStringSize(
    value: []const u8,
) error{LengthOverflow}!usize {
    if (value.len > std.math.maxInt(u32))
        return error.LengthOverflow;

    return std.math.add(
        usize,
        @sizeOf(u32),
        value.len,
    ) catch error.LengthOverflow;
}

pub fn encodedSizeWithStrings(
    base_size: usize,
    values: []const []const u8,
) error{LengthOverflow}!usize {
    var total = base_size;

    for (values) |value| {
        const string_size = try encodedStringSize(value);

        total = std.math.add(
            usize,
            total,
            string_size,
        ) catch return error.LengthOverflow;
    }
    return total;
}

test "encoded string sizes" {
    try std.testing.expectEqual(
        @as(usize, 7),
        try encodedStringSize("abc"),
    );

    try std.testing.expectEqual(
        @as(usize, 18),
        try encodedSizeWithStrings(
            4,
            &.{ "abc", "xyz" },
        ),
    );
}
