//! Per-user CUPS destination and bounded private diagnostic observations.
//! All filesystem roots and environment values are passed by the caller.
const std = @import("std");
const tools = @import("tools.zig");
const ipp = @import("ipp.zig");
const A = std.mem.Allocator;
const Io = std.Io;
const max_bytes = 256 * 1024;

pub fn validQueue(queue: []const u8) bool {
    if (queue.len == 0 or queue.len > 127 or !std.unicode.utf8ValidateSlice(queue)) return false;
    for (queue) |ch| if (ch <= 0x20 or ch == 0x7f or ch == '/' or ch == '#' or ch == '?' or ch == '\\' or ch == '\"' or ch == '\'') return false;
    return true;
}

fn path(a: A, env: std.process.Environ, suffix: []const u8) ![]u8 {
    const home = env.getPosix("HOME") orelse return error.NoHomeDirectory;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidHomeDirectory;
    return std.fs.path.join(a, &.{ home, suffix });
}

fn read(a: A, io: Io, file_path: []const u8, limit: usize) ![]u8 {
    return Io.Dir.cwd().readFileAlloc(io, file_path, a, .limited(limit)) catch |err| switch (err) {
        error.FileNotFound => a.dupe(u8, ""),
        else => return err,
    };
}

const Line = struct { keyword: []const u8, name: []const u8, keyword_start: usize, keyword_end: usize };
fn destination(line: []const u8) ?Line {
    var tokens = std.mem.tokenizeAny(u8, line, " \t\r\n");
    const keyword = tokens.next() orelse return null;
    if (!std.ascii.eqlIgnoreCase(keyword, "Default") and !std.ascii.eqlIgnoreCase(keyword, "Dest")) return null;
    const name = tokens.next() orelse return null;
    const start: usize = @intFromPtr(keyword.ptr) - @intFromPtr(line.ptr);
    return .{ .keyword = keyword, .name = name, .keyword_start = start, .keyword_end = start + keyword.len };
}

/// Preserve options (including quoted and escaped values), instances, comments,
/// unrelated directives, whitespace and newline style. Demote old Default lines
/// to Dest; promote an existing exact queue line so its options remain attached.
pub fn patchDefault(a: A, original: []const u8, queue: []const u8) ![]u8 {
    if (!validQueue(queue)) return error.InvalidQueueName;
    if (original.len > max_bytes or std.mem.indexOfScalar(u8, original, 0) != null) return error.InvalidPreferences;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var offset: usize = 0;
    var found = false;
    while (offset < original.len) {
        const end = if (std.mem.indexOfScalarPos(u8, original, offset, '\n')) |n| n + 1 else original.len;
        const line = original[offset..end];
        if (destination(line)) |dest| {
            const selected = std.mem.eql(u8, std.mem.trimEnd(u8, dest.name, "\n"), queue);
            if (selected and found) return error.AmbiguousPreferences;
            if (selected) found = true;
            if (selected or std.ascii.eqlIgnoreCase(dest.keyword, "Default")) {
                try out.writer.writeAll(line[0..dest.keyword_start]);
                try out.writer.writeAll(if (selected) "Default" else "Dest");
                try out.writer.writeAll(line[dest.keyword_end..]);
            } else try out.writer.writeAll(line);
        } else try out.writer.writeAll(line);
        offset = end;
    }
    if (!found) {
        if (original.len != 0 and original[original.len - 1] != '\n') try out.writer.writeByte('\n');
        try out.writer.print("Default {s}\n", .{queue});
    }
    return out.toOwnedSlice();
}

/// A queue's instances use the same base identity (Queue/photo). Only the
/// destination token changes; options, comments and formatting remain bytes.
pub fn patchRename(a: A, original: []const u8, old: []const u8, new: []const u8) ![]u8 {
    if (!validQueue(old) or !validQueue(new)) return error.InvalidQueueName;
    if (original.len > max_bytes or std.mem.indexOfScalar(u8, original, 0) != null) return error.InvalidPreferences;
    if (std.mem.eql(u8, old, new)) return a.dupe(u8, original);
    if (std.ascii.eqlIgnoreCase(old, new)) return error.InvalidQueueName;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var offset: usize = 0;
    while (offset < original.len) {
        const end = if (std.mem.indexOfScalarPos(u8, original, offset, '\n')) |n| n + 1 else original.len;
        const line = original[offset..end];
        if (destination(line)) |dest| {
            const slash = std.mem.indexOfScalar(u8, dest.name, '/') orelse dest.name.len;
            const base = dest.name[0..slash];
            if (std.ascii.eqlIgnoreCase(base, new)) return error.QueuePreferencesExist;
            if (std.ascii.eqlIgnoreCase(base, old)) {
                const start: usize = @intFromPtr(dest.name.ptr) - @intFromPtr(line.ptr);
                out.writer.writeAll(line[0..start]) catch return error.OutOfMemory;
                out.writer.writeAll(new) catch return error.OutOfMemory;
                out.writer.writeAll(line[start + base.len ..]) catch return error.OutOfMemory;
            } else out.writer.writeAll(line) catch return error.OutOfMemory;
        } else out.writer.writeAll(line) catch return error.OutOfMemory;
        if (out.written().len > max_bytes) return error.TooLarge;
        offset = end;
    }
    return out.toOwnedSlice();
}

pub fn defaultPrinter(a: A, io: Io, env: std.process.Environ) !?[]u8 {
    if (env.getPosix("LPDEST")) |value| if (value.len != 0) return try a.dupe(u8, value);
    if (env.getPosix("PRINTER")) |value| if (value.len != 0 and !std.mem.eql(u8, value, "lp")) return try a.dupe(u8, value);
    const file_path = try path(a, env, ".cups/lpoptions");
    defer a.free(file_path);
    const bytes = try read(a, io, file_path, max_bytes);
    defer a.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var result: ?[]const u8 = null;
    while (lines.next()) |line| {
        const dest = destination(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(dest.keyword, "Default")) result = dest.name;
    }
    return if (result) |name| try a.dupe(u8, name) else null;
}

pub fn overrideMessage(env: std.process.Environ) ?[]const u8 {
    if (env.getPosix("LPDEST")) |value| if (value.len != 0) return "LPDEST currently overrides the saved default printer.";
    if (env.getPosix("PRINTER")) |value| if (value.len != 0 and !std.mem.eql(u8, value, "lp")) return "PRINTER currently overrides the saved default printer.";
    return null;
}

fn atomicSave(a: A, io: Io, file_path: []const u8, original: []const u8, bytes: []const u8) !void {
    const parent = std.fs.path.dirname(file_path) orelse return error.InvalidPath;
    _ = try Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    var file = try Io.Dir.cwd().createFileAtomic(io, file_path, .{ .permissions = .fromMode(0o600), .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    // Another application can also write lpoptions; refuse a detected change
    // rather than replacing its options from an obsolete read.
    const check = try read(a, io, file_path, max_bytes);
    defer a.free(check);
    if (!std.mem.eql(u8, original, check)) return error.PreferencesChanged;
    try file.replace(io);
}

fn atomicCreate(io: Io, file_path: []const u8, bytes: []const u8) !Io.File.Stat {
    const parent = std.fs.path.dirname(file_path) orelse return error.InvalidPath;
    _ = try Io.Dir.cwd().createDirPathStatus(io, parent, .fromMode(0o700));
    var file = try Io.Dir.cwd().createFileAtomic(io, file_path, .{ .permissions = .fromMode(0o600) });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.file.sync(io);
    const stat = try file.file.stat(io);
    file.link(io) catch |err| switch (err) {
        error.PathAlreadyExists => return error.QueuePreferencesExist,
        else => return err,
    };
    return stat;
}

fn fileStat(io: Io, file_path: []const u8) !?Io.File.Stat {
    return Io.Dir.cwd().statFile(io, file_path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn discardCreated(a: A, io: Io, file_path: []const u8, created: Io.File.Stat, bytes: []const u8) void {
    const stat = (fileStat(io, file_path) catch return) orelse return;
    if (stat.kind != .file or stat.inode != created.inode or stat.size != created.size or !std.meta.eql(stat.mtime, created.mtime)) return;
    const current = read(a, io, file_path, 4096) catch return;
    defer a.free(current);
    if (std.mem.eql(u8, current, bytes)) Io.Dir.cwd().deleteFile(io, file_path) catch {};
}

/// Invoke only after a fresh scheduler inventory confirms old absent/new
/// present. Files are committed separately: create private new-state first,
/// update lpoptions second. Neither an existing destination nor existing new
/// state is merged/replaced. Keep old-state as a harmless recovery copy.
pub fn renameQueue(a: A, io: Io, env: std.process.Environ, old: []const u8, new: []const u8) !void {
    if (!validQueue(old) or !validQueue(new)) return error.InvalidQueueName;
    if (std.mem.eql(u8, old, new)) return;
    const options_path = try path(a, env, ".cups/lpoptions");
    defer a.free(options_path);
    const original = try read(a, io, options_path, max_bytes);
    defer a.free(original);
    const patched = try patchRename(a, original, old, new);
    defer a.free(patched);
    const old_state = try statePath(a, env, old);
    defer a.free(old_state);
    const new_state = try statePath(a, env, new);
    defer a.free(new_state);
    if (try fileStat(io, new_state) != null) return error.QueuePreferencesExist;
    const old_stat = try fileStat(io, old_state);
    if (old_stat) |stat| if (stat.kind != .file) return error.InvalidPreferences;
    const state_bytes = if (old_stat != null) try read(a, io, old_state, 4096) else try a.dupe(u8, "");
    defer a.free(state_bytes);
    if (old_stat != null) _ = try parseState(state_bytes);
    var created: ?Io.File.Stat = null;
    var committed = false;
    defer if (!committed) if (created) |stat| discardCreated(a, io, new_state, stat, state_bytes);
    if (old_stat != null) created = try atomicCreate(io, new_state, state_bytes);
    if (!std.mem.eql(u8, original, patched)) try atomicSave(a, io, options_path, original, patched);
    committed = true;
}

pub fn setDefault(a: A, io: Io, env: std.process.Environ, queue: []const u8) !void {
    const file_path = try path(a, env, ".cups/lpoptions");
    defer a.free(file_path);
    const original = try read(a, io, file_path, max_bytes);
    defer a.free(original);
    const bytes = try patchDefault(a, original, queue);
    defer a.free(bytes);
    try atomicSave(a, io, file_path, original, bytes);
}

pub const Outcome = enum { unknown, printed, no_output };
pub const UserState = struct {
    label: bool = false,
    language: ?tools.Language = null,
    expected_media: ?tools.Media = null,
    driver: Outcome = .unknown,
    raw: Outcome = .unknown,
    ruler: Outcome = .unknown,
    /// The queue resolution that produced the measured physical rectangle.
    /// Calibration must not reinterpret an old ruler at a later queue DPI.
    ruler_resolution: ?ipp.Resolution = null,
};

fn statePath(a: A, env: std.process.Environ, queue: []const u8) ![]u8 {
    if (!validQueue(queue)) return error.InvalidQueueName;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(queue, &hash, .{});
    const filename = try std.fmt.allocPrint(a, "{s}.state", .{std.fmt.bytesToHex(hash, .lower)});
    defer a.free(filename);
    if (env.getPosix("XDG_STATE_HOME")) |root| {
        if (!std.fs.path.isAbsolute(root)) return error.InvalidStateDirectory;
        return std.fs.path.join(a, &.{ root, "rediwm/printers", filename });
    }
    const root = try path(a, env, ".local/state/rediwm/printers");
    defer a.free(root);
    return std.fs.path.join(a, &.{ root, filename });
}

pub fn parseState(bytes: []const u8) !UserState {
    if (bytes.len == 0) return .{};
    if (bytes.len > 4096) return error.InvalidPreferences;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    if (!std.mem.eql(u8, lines.next() orelse "", "rediwm-printer-state 1")) return error.InvalidPreferences;
    var state: UserState = .{};
    var width: ?f64 = null;
    var height: ?f64 = null;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, line, ' ') orelse return error.InvalidPreferences;
        const key = line[0..sep];
        const value = line[sep + 1 ..];
        if (std.mem.eql(u8, key, "label")) {
            state.label = if (std.mem.eql(u8, value, "1")) true else if (std.mem.eql(u8, value, "0")) false else return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "language")) {
            state.language = std.meta.stringToEnum(tools.Language, value) orelse return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "width-mm")) {
            width = std.fmt.parseFloat(f64, value) catch return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "height-mm")) {
            height = std.fmt.parseFloat(f64, value) catch return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "driver")) {
            state.driver = std.meta.stringToEnum(Outcome, value) orelse return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "raw")) {
            state.raw = std.meta.stringToEnum(Outcome, value) orelse return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "ruler")) {
            state.ruler = std.meta.stringToEnum(Outcome, value) orelse return error.InvalidPreferences;
        } else if (std.mem.eql(u8, key, "ruler-resolution")) {
            var tokens = std.mem.tokenizeScalar(u8, value, ' ');
            const x = std.fmt.parseInt(i32, tokens.next() orelse return error.InvalidPreferences, 10) catch return error.InvalidPreferences;
            const y = std.fmt.parseInt(i32, tokens.next() orelse return error.InvalidPreferences, 10) catch return error.InvalidPreferences;
            const units = tokens.next() orelse return error.InvalidPreferences;
            if (tokens.next() != null) return error.InvalidPreferences;
            const resolution: ipp.Resolution = .{ .x = x, .y = y, .units = if (std.mem.eql(u8, units, "dpi")) .dpi else if (std.mem.eql(u8, units, "dpcm")) .dpcm else return error.InvalidPreferences };
            _ = tools.dpiValue(resolution) orelse return error.InvalidPreferences;
            state.ruler_resolution = resolution;
        }
    }
    if (width != null or height != null) {
        const media: tools.Media = .{ .width_mm = width orelse return error.InvalidPreferences, .height_mm = height orelse return error.InvalidPreferences };
        if (!media.valid()) return error.InvalidPreferences;
        state.expected_media = media;
    }
    return state;
}

pub fn loadState(a: A, io: Io, env: std.process.Environ, queue: []const u8) !UserState {
    const file_path = try statePath(a, env, queue);
    defer a.free(file_path);
    const bytes = try read(a, io, file_path, 4096);
    defer a.free(bytes);
    return parseState(bytes);
}

pub fn saveState(a: A, io: Io, env: std.process.Environ, queue: []const u8, state: UserState) !void {
    const file_path = try statePath(a, env, queue);
    defer a.free(file_path);
    const original = try read(a, io, file_path, 4096);
    defer a.free(original);
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.print("rediwm-printer-state 1\nlabel {d}\ndriver {s}\nraw {s}\nruler {s}\n", .{ @intFromBool(state.label), @tagName(state.driver), @tagName(state.raw), @tagName(state.ruler) });
    if (state.language) |language| try out.writer.print("language {s}\n", .{@tagName(language)});
    if (state.expected_media) |media| {
        if (!media.valid()) return error.InvalidMedia;
        try out.writer.print("width-mm {d:.4}\nheight-mm {d:.4}\n", .{ media.width_mm, media.height_mm });
    }
    if (state.ruler_resolution) |resolution| {
        _ = tools.dpiValue(resolution) orelse return error.InvalidPreferences;
        try out.writer.print("ruler-resolution {d} {d} {s}\n", .{ resolution.x, resolution.y, @tagName(resolution.units) });
    }
    try atomicSave(a, io, file_path, original, out.written());
}

test {
    _ = @import("preferences_tests.zig");
}
