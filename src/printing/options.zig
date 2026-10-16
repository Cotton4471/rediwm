//! Bounded presentation of supported IPP choices and PPD UI declarations.
//! PPD PostScript, filters, installables, JCL and commands are never evaluated.
const std = @import("std");
const ipp = @import("ipp.zig");
const tools = @import("tools.zig");
const A = std.mem.Allocator;
const eq = std.mem.eql;

pub const Choice = struct { value: []const u8 = "", label: []const u8 = "" };
pub const Option = struct {
    name: []const u8 = "",
    label: []const u8 = "",
    choices: []Choice = &.{},
    default: ?[]const u8 = null,
    range: ?ipp.Range = null,
    source: enum { ipp, ppd } = .ipp,
};
pub const Group = struct { name: []const u8 = "", label: []const u8 = "", options: []Option = &.{} };
const max_options = 256;
const max_choices = 256;
const max_groups = 32;

/// Canonical CUPS/PPD resolution choice, retaining physical units exactly.
/// Localized labels and arbitrary PPD PostScript are never interpreted.
pub fn parseResolution(value: []const u8) ?ipp.Resolution {
    if (value.len < 4 or value.len > 32) return null;
    const dpcm = value.len > 4 and std.ascii.eqlIgnoreCase(value[value.len - 4 ..], "dpcm");
    const dpi = std.ascii.eqlIgnoreCase(value[value.len - 3 ..], "dpi");
    if (!dpcm and !dpi) return null;
    const digits = value[0 .. value.len - @as(usize, if (dpcm) 4 else 3)];
    const cross = std.mem.indexOfScalar(u8, digits, 'x') orelse digits.len;
    if (cross == 0) return null;
    for (digits[0..cross]) |ch| if (!std.ascii.isDigit(ch)) return null;
    const x = std.fmt.parseInt(i32, digits[0..cross], 10) catch return null;
    var y = x;
    if (cross < digits.len) {
        if (cross + 1 == digits.len) return null;
        for (digits[cross + 1 ..]) |ch| if (!std.ascii.isDigit(ch)) return null;
        y = std.fmt.parseInt(i32, digits[cross + 1 ..], 10) catch return null;
    }
    const resolution: ipp.Resolution = .{ .x = x, .y = y, .units = if (dpcm) .dpcm else .dpi };
    _ = tools.dpiValue(resolution) orelse return null;
    return resolution;
}

pub fn resolutionOption(option: Option) bool {
    return eq(u8, option.name, "printer-resolution") or eq(u8, option.name, "Resolution") or eq(u8, option.name, "SetResolution") or eq(u8, option.name, "JCLResolution") or eq(u8, option.name, "CNRes_PGP");
}

const resolution_keys = [_][]const u8{ "Resolution", "SetResolution", "JCLResolution", "CNRes_PGP" };
const duplex_keys = [_][]const u8{ "Duplex", "JCLDuplex", "EFDuplex", "KD03Duplex" };
const color_keys = [_][]const u8{ "ColorModel", "ColorMode", "OutputMode" };
const quality_keys = [_][]const u8{ "cupsPrintQuality", "PrintQuality", "Quality" };

fn hasPpdChoice(groups: []const Group, names: []const []const u8) bool {
    for (groups) |group| for (group.options) |option| {
        if (option.source != .ppd or option.choices.len == 0) continue;
        for (names) |name| if (eq(u8, option.name, name)) return true;
    };
    return false;
}

/// An advertised IPP job capability does not establish an editable queue/PPD
/// default. In particular driverless PPDs may advertise resolution without a
/// selectable Resolution UI, for which CUPS silently ignores queue changes.
pub fn queueEditable(option: Option, groups: []const Group) bool {
    if (option.source == .ppd) return true;
    if (eq(u8, option.name, "printer-resolution")) return hasPpdChoice(groups, &resolution_keys);
    if (eq(u8, option.name, "media")) return hasPpdChoice(groups, &.{"PageSize"});
    if (eq(u8, option.name, "sides")) return hasPpdChoice(groups, &duplex_keys);
    if (eq(u8, option.name, "print-color-mode")) return hasPpdChoice(groups, &color_keys);
    if (eq(u8, option.name, "print-quality")) return hasPpdChoice(groups, &quality_keys);
    // Vendor controls have no universal IPP-to-PPD translation. Only the exact
    // selectable PPD key is safe to offer through the generic option setter.
    return hasPpdChoice(groups, &.{option.name});
}

fn ppdDefault(groups: []const Group, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (groups) |group| for (group.options) |option| {
        if (option.source != .ppd or !eq(u8, option.name, name)) continue;
        const value = option.default orelse continue;
        if (result) |previous| if (!eq(u8, previous, value)) return null;
        result = value;
    };
    return result;
}

fn typedKeywordDefault(attributes: []const ipp.Attribute, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (attributes) |attribute| {
        // A name-valued root override may precede the real typed metadata;
        // that duplicate does not establish that the PPD/filter changed.
        if (attribute.group != .printer or attribute.tag != .keyword or !eq(u8, attribute.name, name)) continue;
        const value = attribute.text() orelse continue;
        if (result) |previous| if (!eq(u8, previous, value)) return null;
        result = value;
    }
    return result;
}

fn qualityValue(value: []const u8) ?i32 {
    if (std.ascii.eqlIgnoreCase(value, "Draft") or eq(u8, value, "3")) return 3;
    if (std.ascii.eqlIgnoreCase(value, "Normal") or eq(u8, value, "4")) return 4;
    if (std.ascii.eqlIgnoreCase(value, "High") or eq(u8, value, "5")) return 5;
    return null;
}

/// Verify a queued change against fresh server/PPD evidence. null is missing
/// or contradictory evidence, false is an observed mismatch. Caller handles
/// duplicate/default consistency warnings separately, retaining all records.
pub fn settingMatches(groups: []const Group, attributes: []const ipp.Attribute, option: Option, requested: []const u8) ?bool {
    if (option.source == .ppd) return eq(u8, ppdDefault(groups, option.name) orelse return null, requested);
    if (eq(u8, option.name, "printer-resolution")) {
        const target = tools.dpiValue(parseResolution(requested) orelse return null) orelse return null;
        var actual: ?struct { x: f64, y: f64 } = null;
        for (attributes) |attribute| {
            if (attribute.group != .printer or !eq(u8, attribute.name, "printer-resolution-default")) continue;
            const value = tools.dpiValue(attribute.resolution() orelse continue) orelse continue;
            if (actual) |previous| if (@abs(previous.x - value.x) > 1 or @abs(previous.y - value.y) > 1) return null;
            actual = .{ .x = value.x, .y = value.y };
        }
        const value = actual orelse return null;
        return @abs(value.x - target.x) <= 1 and @abs(value.y - target.y) <= 1;
    }
    const keyword: ?[]const u8 = if (eq(u8, option.name, "media")) "media-default" else if (eq(u8, option.name, "sides")) "sides-default" else if (eq(u8, option.name, "print-color-mode")) "print-color-mode-default" else null;
    if (keyword) |name| return eq(u8, typedKeywordDefault(attributes, name) orelse return null, requested);
    if (eq(u8, option.name, "print-quality")) {
        const target = qualityValue(requested) orelse return null;
        if (ppdDefault(groups, "cupsPrintQuality")) |value| if (qualityValue(value)) |quality| return quality == target;
        var actual: ?i32 = null;
        for (attributes) |attribute| {
            if (attribute.group != .printer or !eq(u8, attribute.name, "print-quality-default")) continue;
            const value = attribute.integer() orelse continue;
            if (actual) |previous| if (previous != value) return null;
            actual = value;
        }
        return (actual orelse return null) == target;
    }
    if (hasPpdChoice(groups, &.{option.name})) return eq(u8, ppdDefault(groups, option.name) orelse return null, requested);
    return null;
}

pub fn resolutionChoices(a: A, groups: []const Group) ![]ipp.Resolution {
    var result: std.ArrayList(ipp.Resolution) = .empty;
    errdefer result.deinit(a);
    for (groups) |group| for (group.options) |option| {
        if (!resolutionOption(option)) continue;
        for (option.choices) |choice| {
            const candidate = parseResolution(choice.value) orelse continue;
            var duplicate = false;
            for (result.items) |old| if (std.meta.eql(old, candidate)) {
                duplicate = true;
                break;
            };
            if (duplicate) continue;
            if (result.items.len >= 256) return error.TooLarge;
            try result.append(a, candidate);
        }
    };
    return result.toOwnedSlice(a);
}

/// Results own their data and may outlive the IPP/PPD input.
pub fn deinit(a: A, groups: []Group) void {
    for (groups) |group| {
        a.free(group.name);
        a.free(group.label);
        for (group.options) |option| {
            a.free(option.name);
            a.free(option.label);
            if (option.default) |value| a.free(value);
            for (option.choices) |choice| {
                a.free(choice.value);
                a.free(choice.label);
            }
            a.free(option.choices);
        }
        a.free(group.options);
    }
    a.free(groups);
}

const Definition = struct { name: []const u8, supported: []const u8, default: []const u8, label: []const u8 };
const definitions = [_]Definition{
    .{ .name = "media", .supported = "media-supported", .default = "media-default", .label = "Paper size" },
    .{ .name = "printer-resolution", .supported = "printer-resolution-supported", .default = "printer-resolution-default", .label = "Resolution" },
    .{ .name = "sides", .supported = "sides-supported", .default = "sides-default", .label = "Two-sided printing" },
    .{ .name = "print-color-mode", .supported = "print-color-mode-supported", .default = "print-color-mode-default", .label = "Colour" },
    .{ .name = "print-quality", .supported = "print-quality-supported", .default = "print-quality-default", .label = "Quality" },
    .{ .name = "print-darkness", .supported = "print-darkness-supported", .default = "print-darkness-default", .label = "Darkness" },
    .{ .name = "print-speed", .supported = "print-speed-supported", .default = "print-speed-default", .label = "Speed" },
};

fn safeText(a: A, value: []const u8) ![]u8 {
    if (value.len > 512) return error.InvalidOptions;
    // Older PPDs commonly use ISOLatin1. Keep their UI labels usable without
    // passing malformed UTF-8 into the widget/text stack.
    if (!std.unicode.utf8ValidateSlice(value)) {
        var out: std.Io.Writer.Allocating = .init(a);
        defer out.deinit();
        for (value) |ch| {
            if (ch < 0x20 or ch == 0x7f or (ch >= 0x80 and ch < 0xa0)) {
                try out.writer.writeByte(' ');
            } else if (ch < 0x80) {
                try out.writer.writeByte(ch);
            } else {
                try out.writer.writeAll(&.{ 0xc0 | (ch >> 6), 0x80 | (ch & 0x3f) });
            }
        }
        return out.toOwnedSlice();
    }
    const copy = try a.dupe(u8, value);
    for (copy) |*ch| if (ch.* < 0x20 or ch.* == 0x7f) {
        ch.* = ' ';
    };
    return copy;
}
fn identifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    for (value) |ch| if (ch < 0x21 or ch > 0x7e or ch == ':' or ch == '/' or ch == '\\' or ch == '"' or ch == '\'') return false;
    return true;
}
fn attributeValue(a: A, attr: ipp.Attribute) !?[]const u8 {
    if (attr.resolution()) |resolution| {
        _ = tools.dpiValue(resolution) orelse return null;
        const suffix = if (resolution.units == .dpi) "dpi" else "dpcm";
        return if (resolution.x == resolution.y) try std.fmt.allocPrint(a, "{d}{s}", .{ resolution.x, suffix }) else try std.fmt.allocPrint(a, "{d}x{d}{s}", .{ resolution.x, resolution.y, suffix });
    }
    if (attr.integer()) |value| return try std.fmt.allocPrint(a, "{d}", .{value});
    const value = attr.text() orelse return null;
    if (!identifier(value)) return null;
    return value;
}
fn choiceLabel(name: []const u8, value: []const u8) []const u8 {
    if (eq(u8, name, "sides")) {
        if (eq(u8, value, "one-sided")) return "One-sided";
        if (eq(u8, value, "two-sided-long-edge")) return "Two-sided, long edge";
        if (eq(u8, value, "two-sided-short-edge")) return "Two-sided, short edge";
    } else if (eq(u8, name, "print-color-mode")) {
        if (eq(u8, value, "monochrome")) return "Black and white";
        if (eq(u8, value, "color")) return "Colour";
        if (eq(u8, value, "auto")) return "Automatic";
    } else if (eq(u8, name, "print-quality")) {
        if (eq(u8, value, "3")) return "Draft";
        if (eq(u8, value, "4")) return "Normal";
        if (eq(u8, value, "5")) return "High";
    }
    return value;
}
fn appendChoice(a: A, choices: *std.ArrayList(Choice), name: []const u8, value: []const u8, label: ?[]const u8) !void {
    for (choices.items) |choice| if (eq(u8, choice.value, value)) return;
    if (choices.items.len >= max_choices) return error.TooLarge;
    var display = label orelse choiceLabel(name, value);
    if (label == null and eq(u8, name, "media")) {
        if (tools.mediaFromKeyword(value)) |media| {
            const paper: []const u8 = if (std.mem.startsWith(u8, value, "iso_a4_")) "A4" else if (std.mem.startsWith(u8, value, "iso_a3_")) "A3" else if (std.mem.startsWith(u8, value, "iso_a5_")) "A5" else if (std.mem.startsWith(u8, value, "na_letter_")) "Letter" else if (std.mem.startsWith(u8, value, "na_legal_")) "Legal" else "Paper";
            display = try std.fmt.allocPrint(a, "{s} ({d:.1} x {d:.1} mm)", .{ paper, media.width_mm, media.height_mm });
        }
    }
    try choices.append(a, .{ .value = value, .label = try safeText(a, display) });
}

pub fn parseAttributes(a: A, attributes: []const ipp.Attribute) ![]Group {
    if (attributes.len > 16384) return error.TooLarge;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    var options: std.ArrayList(Option) = .empty;
    for (definitions) |definition| {
        var choices: std.ArrayList(Choice) = .empty;
        var default: ?[]const u8 = null;
        var saw_default = false;
        var range: ?ipp.Range = null;
        for (attributes) |attr| {
            if (attr.group != .printer) continue;
            // CUPS can place a name-valued user override before the typed PPD
            // default. Match its first-occurrence semantics without concealing
            // the duplicate records from the caller's consistency diagnostics.
            if (!saw_default and eq(u8, attr.name, definition.default)) {
                saw_default = true;
                default = try attributeValue(mem, attr);
            }
            if (!eq(u8, attr.name, definition.supported)) continue;
            if (attr.range()) |r| {
                if (r.lower < 0 or r.upper < r.lower) continue;
                range = r;
                if (@as(i64, r.upper) - r.lower < max_choices) {
                    var n: i64 = r.lower;
                    while (n <= r.upper) : (n += 1) try appendChoice(mem, &choices, definition.name, try std.fmt.allocPrint(mem, "{d}", .{n}), null);
                }
            } else if (try attributeValue(mem, attr)) |value| try appendChoice(mem, &choices, definition.name, value, null);
        }
        if (choices.items.len != 0 or range != null) try options.append(mem, .{
            .name = definition.name,
            .label = definition.label,
            .choices = choices.items,
            .default = default,
            .range = range,
        });
    }
    if (options.items.len == 0) return a.alloc(Group, 0);
    return clone(a, &.{.{ .name = "general", .label = "Printer settings", .options = options.items }});
}

fn clone(a: A, source: []const Group) ![]Group {
    const result = try a.alloc(Group, source.len);
    @memset(result, .{});
    errdefer deinit(a, result);
    for (source, result) |from, *to| {
        to.name = try a.dupe(u8, from.name);
        to.label = try safeText(a, from.label);
        to.options = try a.alloc(Option, from.options.len);
        @memset(to.options, .{});
        for (from.options, to.options) |old, *new| {
            new.name = try a.dupe(u8, old.name);
            new.label = try safeText(a, old.label);
            new.default = if (old.default) |value| try a.dupe(u8, value) else null;
            new.range = old.range;
            new.source = old.source;
            new.choices = try a.alloc(Choice, old.choices.len);
            @memset(new.choices, .{});
            for (old.choices, new.choices) |choice, *copy| {
                copy.value = try a.dupe(u8, choice.value);
                copy.label = try safeText(a, choice.label);
            }
        }
    }
    return result;
}

const BuildOption = struct { option: Option, choices: std.ArrayList(Choice) = .empty };
const BuildGroup = struct { name: []const u8, label: []const u8, options: std.ArrayList(BuildOption) = .empty };
const NameLabel = struct { name: []const u8, label: []const u8 };
fn nameLabel(value: []const u8) !NameLabel {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse value.len;
    const name = value[0..slash];
    if (!identifier(name)) return error.InvalidOptions;
    return .{ .name = name, .label = if (slash < value.len) value[slash + 1 ..] else name };
}
fn ppdLine(raw: []const u8) !?struct { key: []const u8, value: []const u8 } {
    if (raw.len > 16384) return error.TooLarge;
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0 or line[0] != '*' or std.mem.startsWith(u8, line, "*%")) return null;
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return .{ .key = line[1..colon], .value = value };
}

/// Parse only PickOne/Boolean OpenUI declarations, choices and defaults into
/// their declared groups. PickMany and executable fields are not configuration
/// choices. Remote PPD download is owned by the caller's bounded transport.
pub fn parsePpd(a: A, bytes: []const u8) ![]Group {
    if (bytes.len > 4 * 1024 * 1024) return error.TooLarge;
    if (!std.mem.startsWith(u8, bytes, "*PPD-Adobe:") or std.mem.indexOfScalar(u8, bytes, 0) != null) return error.InvalidOptions;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    var groups: std.ArrayList(BuildGroup) = .empty;
    try groups.append(mem, .{ .name = "general", .label = "General" });
    var group: usize = 0;
    var parents: [8]usize = undefined;
    var depth: usize = 0;
    var active: ?usize = null;
    var option_count: usize = 0;
    var choice_count: usize = 0;
    var defaults = std.StringHashMap([]const u8).init(mem);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = (try ppdLine(raw)) orelse continue;
        if (eq(u8, line.key, "OpenGroup") or eq(u8, line.key, "OpenSubGroup")) {
            if (depth >= parents.len or groups.items.len >= max_groups) return error.TooLarge;
            if (active != null) return error.InvalidOptions;
            const named = try nameLabel(line.value);
            parents[depth] = group;
            depth += 1;
            group = groups.items.len;
            try groups.append(mem, .{ .name = named.name, .label = named.label });
        } else if (eq(u8, line.key, "CloseGroup") or eq(u8, line.key, "CloseSubGroup")) {
            if (depth == 0 or active != null) return error.InvalidOptions;
            depth -= 1;
            group = parents[depth];
        } else if (std.mem.startsWith(u8, line.key, "OpenUI *")) {
            if (active != null or option_count >= max_options) return error.InvalidOptions;
            if (!eq(u8, line.value, "PickOne") and !eq(u8, line.value, "Boolean")) continue;
            const named = try nameLabel(line.key[8..]);
            active = groups.items[group].options.items.len;
            try groups.items[group].options.append(mem, .{ .option = .{ .name = named.name, .label = named.label, .source = .ppd } });
            option_count += 1;
        } else if (eq(u8, line.key, "CloseUI")) {
            active = null;
        } else if (std.mem.startsWith(u8, line.key, "Default")) {
            if (identifier(line.key[7..]) and identifier(line.value)) {
                if (defaults.count() >= 4096 and !defaults.contains(line.key[7..])) return error.TooLarge;
                try defaults.put(line.key[7..], line.value);
            }
        } else if (active) |index| {
            const built = &groups.items[group].options.items[index];
            const option = &built.option;
            const end = std.mem.indexOfScalar(u8, line.key, ' ') orelse continue;
            if (!eq(u8, line.key[0..end], option.name)) continue;
            const named = try nameLabel(std.mem.trimStart(u8, line.key[end + 1 ..], " \t"));
            const count = built.choices.items.len;
            try appendChoice(mem, &built.choices, option.name, named.name, named.label);
            if (built.choices.items.len != count) choice_count += 1;
            if (choice_count > 4096) return error.TooLarge;
        }
    }
    if (depth != 0 or active != null) return error.InvalidOptions;
    var output: std.ArrayList(Group) = .empty;
    for (groups.items) |built| {
        var parsed: std.ArrayList(Option) = .empty;
        for (built.options.items) |item| {
            var option = item.option;
            option.default = defaults.get(option.name);
            option.choices = item.choices.items;
            if (option.choices.len != 0) try parsed.append(mem, option);
        }
        if (parsed.items.len != 0) try output.append(mem, .{ .name = built.name, .label = built.label, .options = parsed.items });
    }
    return clone(a, output.items);
}

/// PPD PaperDimension is a pair of physical PostScript points; it is data,
/// unlike the executable PageSize choice body. Never run that PostScript.
pub fn ppdMediaDimensions(bytes: []const u8, choice: []const u8) ?tools.Media {
    const dimensions = ppdNumbers(2, bytes, "PaperDimension ", choice) orelse return null;
    const media: tools.Media = .{ .width_mm = dimensions[0] * 25.4 / 72, .height_mm = dimensions[1] * 25.4 / 72 };
    return if (media.valid()) media else null;
}

pub const Margins = struct { left_mm: f64, right_mm: f64, top_mm: f64, bottom_mm: f64 };

/// ImageableArea stores left/bottom/right/top coordinates in physical points.
/// Keep the declared paper and printable rectangle separate from executable
/// PageSize bodies; invalid, out-of-paper and conflicting declarations are unknown.
pub fn ppdMargins(bytes: []const u8, choice: []const u8) ?Margins {
    const dimensions = ppdNumbers(2, bytes, "PaperDimension ", choice) orelse return null;
    const area = ppdNumbers(4, bytes, "ImageableArea ", choice) orelse return null;
    _ = ppdMediaDimensions(bytes, choice) orelse return null;
    if (area[0] < 0 or area[1] < 0 or area[2] > dimensions[0] or area[3] > dimensions[1] or area[2] <= area[0] or area[3] <= area[1]) return null;
    return .{
        .left_mm = area[0] * 25.4 / 72,
        .bottom_mm = area[1] * 25.4 / 72,
        .right_mm = (dimensions[0] - area[2]) * 25.4 / 72,
        .top_mm = (dimensions[1] - area[3]) * 25.4 / 72,
    };
}

fn ppdNumbers(comptime count: usize, bytes: []const u8, prefix: []const u8, choice: []const u8) ?[count]f64 {
    if (bytes.len > 4 * 1024 * 1024 or !identifier(choice)) return null;
    var result: ?[count]f64 = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = (ppdLine(raw) catch return null) orelse continue;
        if (!std.mem.startsWith(u8, line.key, prefix)) continue;
        const named = nameLabel(std.mem.trimStart(u8, line.key[prefix.len..], " \t")) catch continue;
        if (!eq(u8, named.name, choice)) continue;
        var numbers = std.mem.tokenizeAny(u8, line.value, " \t");
        var parsed: [count]f64 = undefined;
        for (&parsed) |*number| {
            number.* = std.fmt.parseFloat(f64, numbers.next() orelse return null) catch return null;
            if (!std.math.isFinite(number.*)) return null;
        }
        if (numbers.next() != null) return null;
        if (result) |previous| if (!std.mem.eql(f64, &previous, &parsed)) return null;
        result = parsed;
    }
    return result;
}

test {
    _ = @import("options_tests.zig");
}
