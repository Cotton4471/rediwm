// Shared representative data for serializer compatibility tests. The baseline
// JSON was captured before replacing the manual encoders. Exercise both null
// and populated optional fields, nested arrays, and escaped strings.
const std = @import("std");
pub fn sample(comptime T: type, comptime populated: bool) T {
    return comptime switch (@typeInfo(T)) {
        .void => {},
        .bool => populated,
        .int => if (populated) 7 else 0,
        .float => if (populated) 1.23456 else 0,
        .optional => |o| if (populated) sample(o.child, populated) else null,
        .@"enum" => std.meta.tags(T)[0],
        .array => |a| @as([a.len]a.child, @splat(sample(a.child, populated))),
        .pointer => |p| if (p.size == .slice)
            (if (p.child == u8) "text \"quoted\"\n\\" else &[_]p.child{sample(p.child, populated)})
        else
            @compileError("add pointer fixture for " ++ @typeName(T)),
        .@"struct" => blk: {
            var value: T = undefined;
            for (@typeInfo(T).@"struct".field_names) |name| {
                if (std.mem.eql(u8, name, "placeholder") or std.mem.eql(u8, name, "tab_group") or (@hasField(T, "tab_group") and (std.mem.eql(u8, name, "tag") or std.mem.eql(u8, name, "description") or std.mem.eql(u8, name, "content_type")))) {
                    @field(value, name) = null;
                } else {
                    @field(value, name) = sample(@FieldType(T, name), populated);
                }
            }
            break :blk value;
        },
        else => @compileError("add serializer fixture for " ++ @typeName(T)),
    };
}
