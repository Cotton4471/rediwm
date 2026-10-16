//! Bounded IPP binary codec (RFC 8010). Decoded slices borrow the input;
//! callers still sanitize display strings and validate URIs for their use.
const std = @import("std");

pub const Tag = enum(u8) {
    operation = 0x01,
    job = 0x02,
    end = 0x03,
    printer = 0x04,
    unsupported = 0x05,
    subscription = 0x06,
    event_notification = 0x07,
    resource = 0x08,
    document = 0x09,
    system = 0x0a,
    unsupported_value = 0x10,
    default_value = 0x11,
    unknown = 0x12,
    no_value = 0x13,
    not_settable = 0x15,
    delete_attribute = 0x16,
    admin_defined = 0x17,
    integer = 0x21,
    boolean = 0x22,
    enum_value = 0x23,
    octet_string = 0x30,
    date_time = 0x31,
    resolution = 0x32,
    range = 0x33,
    begin_collection = 0x34,
    text_with_language = 0x35,
    name_with_language = 0x36,
    end_collection = 0x37,
    text = 0x41,
    name = 0x42,
    keyword = 0x44,
    uri = 0x45,
    uri_scheme = 0x46,
    charset = 0x47,
    natural_language = 0x48,
    mime_type = 0x49,
    member_name = 0x4a,
    extension = 0x7f,
    _,
};

pub const Error = error{ Truncated, InvalidMessage, UnsupportedVersion, TooLarge };
pub const Limits = struct {
    max_bytes: usize = 4 * 1024 * 1024,
    // Includes collection members and additional values, not only names.
    max_attributes: usize = 16384,
    max_groups: usize = 1024,
    max_name: usize = 255,
    max_value: usize = 32767,
    max_collection_depth: usize = 8,
    /// Compatibility for CUPS replies that repeat defaults with different
    /// value tags. Preserve every record; callers must reject ambiguous
    /// identity attributes. Collection member names remain strict.
    allow_duplicate_names: bool = false,
};

pub const Resolution = struct {
    x: i32,
    y: i32,
    units: enum(u8) { dpi = 3, dpcm = 4 },
};
pub const Range = struct { lower: i32, upper: i32 };

pub const Attribute = struct {
    group: Tag,
    // Every group delimiter advances this, including consecutive same-tag groups.
    group_index: usize,
    name: []const u8,
    tag: Tag,
    // Collections contain the encoded members, including their end marker.
    value: []const u8,

    pub fn integer(self: Attribute) ?i32 {
        if (self.tag != .integer and self.tag != .enum_value) return null;
        if (self.value.len != 4) return null;
        return std.mem.readInt(i32, self.value[0..4], .big);
    }
    pub fn boolean(self: Attribute) ?bool {
        if (self.tag != .boolean or self.value.len != 1 or self.value[0] > 1) return null;
        return self.value[0] == 1;
    }
    pub fn text(self: Attribute) ?[]const u8 {
        return switch (self.tag) {
            .text, .name, .keyword, .uri, .uri_scheme, .charset, .natural_language, .mime_type => self.value,
            .text_with_language, .name_with_language => languageText(self.value) catch null,
            else => null,
        };
    }
    pub fn resolution(self: Attribute) ?Resolution {
        if (self.tag != .resolution or self.value.len != 9) return null;
        if (self.value[8] != 3 and self.value[8] != 4) return null;
        return .{
            .x = std.mem.readInt(i32, self.value[0..4], .big),
            .y = std.mem.readInt(i32, self.value[4..8], .big),
            .units = @enumFromInt(self.value[8]),
        };
    }
    pub fn range(self: Attribute) ?Range {
        if (self.tag != .range or self.value.len != 8) return null;
        return .{
            .lower = std.mem.readInt(i32, self.value[0..4], .big),
            .upper = std.mem.readInt(i32, self.value[4..8], .big),
        };
    }
};

pub const Message = struct {
    version: [2]u8,
    code: u16,
    request_id: i32,
    attributes: []Attribute,
    group_count: usize,
    data: []const u8,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.attributes);
        self.* = undefined;
    }
};

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8, limits: Limits) !Message {
    if (bytes.len > limits.max_bytes) return error.TooLarge;
    var reader: Reader = .{ .bytes = bytes, .limits = limits };
    const header = try reader.take(8);
    try checkVersion(header[0..2].*);
    const request_id = std.mem.readInt(i32, header[4..8], .big);
    if (request_id <= 0) return error.InvalidMessage;
    var attributes: std.ArrayList(Attribute) = .empty;
    errdefer attributes.deinit(allocator);
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    var group: ?Tag = null;
    var groups: usize = 0;
    var previous_name: []const u8 = "";
    while (true) {
        const tag: Tag = @enumFromInt(try reader.byte());
        if (tag == .end) {
            if (group == null) return error.InvalidMessage;
            return .{
                .version = header[0..2].*,
                .code = std.mem.readInt(u16, header[2..4], .big),
                .request_id = request_id,
                .attributes = try attributes.toOwnedSlice(allocator),
                .group_count = groups,
                .data = bytes[reader.offset..],
            };
        }
        if (@intFromEnum(tag) < 0x10) {
            if (!isGroup(tag) or (groups == 0 and tag != .operation) or
                (groups != 0 and tag == .operation)) return error.InvalidMessage;
            if (groups >= limits.max_groups) return error.TooLarge;
            groups += 1;
            group = tag;
            previous_name = "";
            names.clearRetainingCapacity();
            continue;
        }
        if (group == null or tag == .member_name or tag == .end_collection) return error.InvalidMessage;
        const record = try reader.record(tag);
        var name = record.name;
        if (name.len == 0) {
            if (previous_name.len == 0) return error.InvalidMessage;
            name = previous_name;
        } else {
            if (!validName(name)) return error.InvalidMessage;
            const result = try names.getOrPut(name);
            if (result.found_existing and !limits.allow_duplicate_names) return error.InvalidMessage;
            previous_name = name;
        }
        try validateValue(tag, record.value);
        var value = record.value;
        if (tag == .begin_collection) {
            const start = reader.offset;
            try reader.collection(allocator, 1);
            value = bytes[start..reader.offset];
        }
        try attributes.append(allocator, .{
            .group = group.?,
            .group_index = groups - 1,
            .name = name,
            .tag = tag,
            .value = value,
        });
    }
}

const Reader = struct {
    bytes: []const u8,
    limits: Limits,
    offset: usize = 0,
    records: usize = 0,

    fn take(self: *Reader, count: usize) Error![]const u8 {
        if (count > self.bytes.len - self.offset) return error.Truncated;
        defer self.offset += count;
        return self.bytes[self.offset..][0..count];
    }
    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }
    fn field(self: *Reader, limit: usize) Error![]const u8 {
        const length = std.mem.readInt(u16, (try self.take(2))[0..2], .big);
        if (length > 32767 or length > limit) return error.TooLarge;
        return self.take(length);
    }
    const Record = struct { name: []const u8, value: []const u8 };
    fn record(self: *Reader, tag: Tag) Error!Record {
        if (@intFromEnum(tag) < 0x10) return error.InvalidMessage;
        if (self.records >= self.limits.max_attributes) return error.TooLarge;
        self.records += 1;
        return .{
            .name = try self.field(@min(255, self.limits.max_name)),
            .value = try self.field(self.limits.max_value),
        };
    }
    fn collection(self: *Reader, allocator: std.mem.Allocator, depth: usize) (Error || std.mem.Allocator.Error)!void {
        // Keep a hard stack bound even if a caller accidentally raises its limit.
        if (depth > @min(16, self.limits.max_collection_depth)) return error.TooLarge;
        var names = std.StringHashMap(void).init(allocator);
        defer names.deinit();
        var member_started = false;
        var member_has_value = false;
        while (true) {
            const tag: Tag = @enumFromInt(try self.byte());
            const record_value = try self.record(tag);
            if (record_value.name.len != 0) return error.InvalidMessage;
            if (tag == .end_collection) {
                if (record_value.value.len != 0 or (member_started and !member_has_value)) return error.InvalidMessage;
                return;
            }
            if (tag == .member_name) {
                if (record_value.value.len > self.limits.max_name or record_value.value.len > 255) return error.TooLarge;
                if (!validName(record_value.value) or (member_started and !member_has_value)) return error.InvalidMessage;
                const result = try names.getOrPut(record_value.value);
                if (result.found_existing) return error.InvalidMessage;
                member_started = true;
                member_has_value = false;
                continue;
            }
            if (!member_started) return error.InvalidMessage;
            try validateValue(tag, record_value.value);
            if (tag == .begin_collection) try self.collection(allocator, depth + 1);
            member_has_value = true;
        }
    }
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    groups: usize = 0,
    attributes: usize = 0,
    has_name: bool = false,
    finished: bool = false,

    pub fn init(allocator: std.mem.Allocator, operation: u16, request_id: i32) !Encoder {
        return initVersion(allocator, .{ 1, 1 }, operation, request_id);
    }
    pub fn initVersion(allocator: std.mem.Allocator, version: [2]u8, operation: u16, request_id: i32) !Encoder {
        try checkVersion(version);
        if (request_id <= 0) return error.InvalidMessage;
        var self: Encoder = .{ .allocator = allocator };
        errdefer self.deinit();
        var header: [8]u8 = undefined;
        header[0..2].* = version;
        std.mem.writeInt(u16, header[2..4], operation, .big);
        std.mem.writeInt(i32, header[4..8], request_id, .big);
        try self.bytes.appendSlice(allocator, &header);
        return self;
    }
    pub fn deinit(self: *Encoder) void {
        self.bytes.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn group(self: *Encoder, tag: Tag) !void {
        if (self.finished or !isGroup(tag) or (self.groups == 0 and tag != .operation) or
            (self.groups != 0 and tag == .operation)) return error.InvalidMessage;
        if (self.groups >= (Limits{}).max_groups) return error.TooLarge;
        try self.append(&.{@intFromEnum(tag)});
        self.groups += 1;
        self.has_name = false;
    }
    pub fn string(self: *Encoder, tag: Tag, name: []const u8, data: []const u8) !void {
        switch (tag) {
            .text, .name, .keyword, .uri, .uri_scheme, .charset, .natural_language, .mime_type, .octet_string => {},
            else => return error.InvalidMessage,
        }
        try self.value(tag, name, data);
    }
    pub fn integer(self: *Encoder, tag: Tag, name: []const u8, number: i32) !void {
        if (tag != .integer and tag != .enum_value) return error.InvalidMessage;
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, number, .big);
        try self.value(tag, name, &bytes);
    }
    pub fn boolean(self: *Encoder, name: []const u8, enabled: bool) !void {
        try self.value(.boolean, name, &.{@intFromBool(enabled)});
    }
    /// One non-collection value. An empty name adds a value to the prior name.
    pub fn value(self: *Encoder, tag: Tag, name: []const u8, data: []const u8) !void {
        if (self.finished or self.groups == 0 or tag == .begin_collection or
            tag == .end_collection or tag == .member_name or @intFromEnum(tag) < 0x10) return error.InvalidMessage;
        if (name.len > 255 or data.len > 32767 or self.attributes >= (Limits{}).max_attributes) return error.TooLarge;
        if ((name.len == 0 and !self.has_name) or (name.len != 0 and !validName(name))) return error.InvalidMessage;
        try validateValue(tag, data);
        const size = 5 + name.len + data.len;
        if (size > (Limits{}).max_bytes - self.bytes.items.len) return error.TooLarge;
        try self.bytes.ensureUnusedCapacity(self.allocator, size);
        self.bytes.appendAssumeCapacity(@intFromEnum(tag));
        var length: [2]u8 = undefined;
        std.mem.writeInt(u16, &length, @intCast(name.len), .big);
        self.bytes.appendSliceAssumeCapacity(&length);
        self.bytes.appendSliceAssumeCapacity(name);
        std.mem.writeInt(u16, &length, @intCast(data.len), .big);
        self.bytes.appendSliceAssumeCapacity(&length);
        self.bytes.appendSliceAssumeCapacity(data);
        self.has_name = true;
        self.attributes += 1;
    }
    /// The result remains owned by this encoder until deinit.
    pub fn finish(self: *Encoder) ![]const u8 {
        if (self.groups == 0) return error.InvalidMessage;
        if (!self.finished) {
            try self.append(&.{@intFromEnum(Tag.end)});
            self.finished = true;
        }
        return self.bytes.items;
    }
    fn append(self: *Encoder, bytes: []const u8) !void {
        if (bytes.len > (Limits{}).max_bytes - self.bytes.items.len) return error.TooLarge;
        try self.bytes.appendSlice(self.allocator, bytes);
    }
};

fn isGroup(tag: Tag) bool {
    return @intFromEnum(tag) >= 1 and @intFromEnum(tag) < 0x10 and tag != .end;
}
fn checkVersion(version: [2]u8) Error!void {
    if ((version[0] == 1 and version[1] <= 1) or (version[0] == 2 and version[1] <= 2)) return;
    return error.UnsupportedVersion;
}
fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] < 'a' or name[0] > 'z') return false;
    for (name[1..]) |ch| {
        if (!(ch >= 'a' and ch <= 'z') and !std.ascii.isDigit(ch) and ch != '-' and ch != '_' and ch != '.') return false;
    }
    return true;
}
fn validText(value: []const u8) bool {
    return std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn languageText(value: []const u8) Error![]const u8 {
    if (value.len < 4) return error.InvalidMessage;
    const language_len = std.mem.readInt(u16, value[0..2], .big);
    if (language_len == 0 or language_len > 63 or language_len > value.len - 4) return error.InvalidMessage;
    for (value[2..][0..language_len]) |ch| if (ch <= 0x20 or ch >= 0x7f) return error.InvalidMessage;
    const tail = value[2 + language_len ..];
    const text_len = std.mem.readInt(u16, tail[0..2], .big);
    if (text_len != tail.len - 2 or !validText(tail[2..])) return error.InvalidMessage;
    return tail[2..];
}
fn validateValue(tag: Tag, value: []const u8) Error!void {
    switch (tag) {
        .integer, .enum_value => if (value.len != 4) return error.InvalidMessage,
        .boolean => if (value.len != 1 or value[0] > 1) return error.InvalidMessage,
        .date_time => if (value.len != 11) return error.InvalidMessage,
        .resolution => {
            if (value.len != 9 or (value[8] != 3 and value[8] != 4)) return error.InvalidMessage;
            if (std.mem.readInt(i32, value[0..4], .big) <= 0 or std.mem.readInt(i32, value[4..8], .big) <= 0) return error.InvalidMessage;
        },
        .range => {
            if (value.len != 8) return error.InvalidMessage;
            if (std.mem.readInt(i32, value[0..4], .big) > std.mem.readInt(i32, value[4..8], .big)) return error.InvalidMessage;
        },
        .begin_collection => if (value.len != 0) return error.InvalidMessage,
        .text, .name => if (!validText(value)) return error.InvalidMessage,
        .text_with_language, .name_with_language => _ = try languageText(value),
        .keyword, .uri, .uri_scheme, .charset, .natural_language, .mime_type => {
            for (value) |ch| if (ch < 0x20 or ch >= 0x7f) return error.InvalidMessage;
        },
        .extension => if (value.len < 4) return error.InvalidMessage,
        else => if (@intFromEnum(tag) >= 0x10 and @intFromEnum(tag) < 0x20 and value.len != 0) return error.InvalidMessage,
    }
}

test {
    _ = @import("ipp_tests.zig");
}
