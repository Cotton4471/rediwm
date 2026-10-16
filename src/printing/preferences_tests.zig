const std = @import("std");
const prefs = @import("preferences.zig");
const a = std.testing.allocator;

test "setting default preserves queue options, other destinations, instances and comments" {
    const original = "# retain this\nDefault Old media=A4\n  Dest New   media=Custom\\ Size note=\"keep quoted\"\r\nDest New/photo quality=5\nUnknown verbatim\n";
    const patched = try prefs.patchDefault(a, original, "New");
    defer a.free(patched);
    try std.testing.expectEqualStrings("# retain this\nDest Old media=A4\n  Default New   media=Custom\\ Size note=\"keep quoted\"\r\nDest New/photo quality=5\nUnknown verbatim\n", patched);
    const twice = try prefs.patchDefault(a, patched, "New");
    defer a.free(twice);
    try std.testing.expectEqualStrings(patched, twice);
    const appended = try prefs.patchDefault(a, "# no newline", "Printer");
    defer a.free(appended);
    try std.testing.expectEqualStrings("# no newline\nDefault Printer\n", appended);
    try std.testing.expectError(error.InvalidQueueName, prefs.patchDefault(a, original, "New\nDefault Injected"));
    try std.testing.expectError(error.AmbiguousPreferences, prefs.patchDefault(a, "Dest A x=1\nDest A y=2\n", "A"));
}

test "private queue state has bounded typed values and rejects malformed media" {
    const state = try prefs.parseState("rediwm-printer-state 1\nlabel 1\nlanguage tspl\nwidth-mm 101.6\nheight-mm 152.4\ndriver no_output\nraw printed\n");
    try std.testing.expect(state.label);
    try std.testing.expectEqual(.tspl, state.language.?);
    try std.testing.expectEqual(.no_output, state.driver);
    try std.testing.expectEqual(.printed, state.raw);
    try std.testing.expectEqual(.unknown, state.ruler);
    try std.testing.expectEqual(@as(?@import("ipp.zig").Resolution, null), state.ruler_resolution);
    try std.testing.expectError(error.InvalidPreferences, prefs.parseState("rediwm-printer-state 1\nwidth-mm nan\nheight-mm 152.4\n"));
    try std.testing.expectError(error.InvalidPreferences, prefs.parseState("rediwm-printer-state 1\nwidth-mm 100\n"));
    try std.testing.expectError(error.InvalidPreferences, prefs.parseState("rediwm-printer-state 1\nlanguage arbitrary\n"));
    const ruler = try prefs.parseState("rediwm-printer-state 1\nruler printed\nruler-resolution 80 118 dpcm\n");
    try std.testing.expectEqual(@import("ipp.zig").Resolution{ .x = 80, .y = 118, .units = .dpcm }, ruler.ruler_resolution.?);
    for ([_][]const u8{ "0 300 dpi", "300 -1 dpi", "300 300 unknown", "300 300 dpi extra", "300 dpi", "2147483647 300 dpi", "300 nan dpi" }) |invalid| {
        const bytes = try std.fmt.allocPrint(a, "rediwm-printer-state 1\nruler-resolution {s}\n", .{invalid});
        defer a.free(bytes);
        try std.testing.expectError(error.InvalidPreferences, prefs.parseState(bytes));
    }
}

test "preference persistence uses only explicit temporary HOME and survives a reload" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const home_entry = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0);
    defer a.free(home_entry);
    const block: [:null]const ?[*:0]const u8 = &.{home_entry};
    const env: std.process.Environ = .{ .block = .{ .slice = block } };
    try tmp.dir.createDirPath(io, ".cups");
    try tmp.dir.writeFile(io, .{ .sub_path = ".cups/lpoptions", .data = "Default Old x=1\nDest New y=2\n" });
    try prefs.setDefault(a, io, env, "New");
    const selected = (try prefs.defaultPrinter(a, io, env)).?;
    defer a.free(selected);
    try std.testing.expectEqualStrings("New", selected);
    const written = try tmp.dir.readFileAlloc(io, ".cups/lpoptions", a, .limited(4096));
    defer a.free(written);
    try std.testing.expectEqualStrings("Dest Old x=1\nDefault New y=2\n", written);
    const state: prefs.UserState = .{ .label = true, .language = .tspl, .expected_media = .{ .width_mm = 101.6, .height_mm = 152.4 }, .raw = .printed, .ruler_resolution = .{ .x = 203, .y = 300, .units = .dpi } };
    try prefs.saveState(a, io, env, "New", state);
    const loaded = try prefs.loadState(a, io, env, "New");
    try std.testing.expectEqualDeep(state, loaded);
    const dpcm_state: prefs.UserState = .{ .ruler = .printed, .ruler_resolution = .{ .x = 80, .y = 118, .units = .dpcm } };
    try prefs.saveState(a, io, env, "New", dpcm_state);
    try std.testing.expectEqualDeep(dpcm_state, try prefs.loadState(a, io, env, "New"));
    const absent = try prefs.loadState(a, io, env, "Other");
    try std.testing.expectEqualDeep(prefs.UserState{}, absent);
}

test "environment default overrides are honoured and explained" {
    const block: [:null]const ?[*:0]const u8 = &.{ "LPDEST=EnvChoice", "PRINTER=Other" };
    const env: std.process.Environ = .{ .block = .{ .slice = block } };
    const selected = (try prefs.defaultPrinter(a, std.testing.io, env)).?;
    defer a.free(selected);
    try std.testing.expectEqualStrings("EnvChoice", selected);
    try std.testing.expect(prefs.overrideMessage(env) != null);
}

test "queue rename preserves destination instances options comments and exact formatting" {
    const original = "# Old is retained in comments\r\nDefault Old media=A4\r\n  dEsT oLd/photo  note=\"Old stays in options\" paper=Custom\\ Size\nDest OldExtra media=A5\nUnknown Old\nDest Other quality=5";
    const renamed = try prefs.patchRename(a, original, "Old", "New");
    defer a.free(renamed);
    try std.testing.expectEqualStrings("# Old is retained in comments\r\nDefault New media=A4\r\n  dEsT New/photo  note=\"Old stays in options\" paper=Custom\\ Size\nDest OldExtra media=A5\nUnknown Old\nDest Other quality=5", renamed);
    try std.testing.expectError(error.QueuePreferencesExist, prefs.patchRename(a, "Dest Old x=1\nDest nEw/photo x=2\n", "Old", "New"));
    try std.testing.expectError(error.QueuePreferencesExist, prefs.patchRename(a, "Default New\n", "Old", "New"));
    try std.testing.expectError(error.InvalidQueueName, prefs.patchRename(a, original, "Old", "Invalid\nInjected"));
    const untouched = try prefs.patchRename(a, "# absent\nDest Other/photo media=A4\n", "Old", "New");
    defer a.free(untouched);
    try std.testing.expectEqualStrings("# absent\nDest Other/photo media=A4\n", untouched);
}

test "renaming a queue migrates private observations and the per-user default under temporary HOME" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const home_entry = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0);
    defer a.free(home_entry);
    const env: std.process.Environ = .{ .block = .{ .slice = &.{home_entry} } };
    const state: prefs.UserState = .{ .label = true, .language = .tspl, .expected_media = .{ .width_mm = 101.6, .height_mm = 152.4 }, .driver = .no_output, .raw = .printed };
    try prefs.saveState(a, io, env, "Old", state);
    try tmp.dir.createDirPath(io, ".cups");
    try tmp.dir.writeFile(io, .{ .sub_path = ".cups/lpoptions", .data = "# retain\nDefault Old custom=\"preserve value\"\nDest Old/photo quality=5\nDest Other media=A4\n" });
    try prefs.renameQueue(a, io, env, "Old", "New");
    try std.testing.expectEqualDeep(state, try prefs.loadState(a, io, env, "New"));
    // Keeping the old observation file is deliberate recovery protection.
    try std.testing.expectEqualDeep(state, try prefs.loadState(a, io, env, "Old"));
    const selected = (try prefs.defaultPrinter(a, io, env)).?;
    defer a.free(selected);
    try std.testing.expectEqualStrings("New", selected);
    const written = try tmp.dir.readFileAlloc(io, ".cups/lpoptions", a, .limited(4096));
    defer a.free(written);
    try std.testing.expectEqualStrings("# retain\nDefault New custom=\"preserve value\"\nDest New/photo quality=5\nDest Other media=A4\n", written);
}

test "rename collision preflight preserves both sets of preferences and never merges them" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const home_entry = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0);
    defer a.free(home_entry);
    const env: std.process.Environ = .{ .block = .{ .slice = &.{home_entry} } };
    const old: prefs.UserState = .{ .label = true, .language = .tspl };
    const new: prefs.UserState = .{ .raw = .printed, .language = .zpl };
    try prefs.saveState(a, io, env, "Old", old);
    try prefs.saveState(a, io, env, "New", new);
    try tmp.dir.createDirPath(io, ".cups");
    const original = "Default Old copies=2\n";
    try tmp.dir.writeFile(io, .{ .sub_path = ".cups/lpoptions", .data = original });
    try std.testing.expectError(error.QueuePreferencesExist, prefs.renameQueue(a, io, env, "Old", "New"));
    try std.testing.expectEqualDeep(new, try prefs.loadState(a, io, env, "New"));
    try std.testing.expectEqualDeep(old, try prefs.loadState(a, io, env, "Old"));
    const written = try tmp.dir.readFileAlloc(io, ".cups/lpoptions", a, .limited(4096));
    defer a.free(written);
    try std.testing.expectEqualStrings(original, written);
    try tmp.dir.writeFile(io, .{ .sub_path = ".cups/lpoptions", .data = "Default Old copies=2\nDest Third/photo quality=5\n" });
    try std.testing.expectError(error.QueuePreferencesExist, prefs.renameQueue(a, io, env, "Old", "Third"));
    try std.testing.expectEqualDeep(prefs.UserState{}, try prefs.loadState(a, io, env, "Third"));
}

test "queue rename without observations neither invents state nor changes unrelated defaults" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const home_entry = try std.fmt.allocPrintSentinel(a, "HOME={s}", .{root}, 0);
    defer a.free(home_entry);
    const env: std.process.Environ = .{ .block = .{ .slice = &.{home_entry} } };
    try prefs.renameQueue(a, io, env, "Old", "New");
    try std.testing.expectEqualDeep(prefs.UserState{}, try prefs.loadState(a, io, env, "New"));
    try std.testing.expectEqual(@as(?[]u8, null), try prefs.defaultPrinter(a, io, env));
}

fn renameAllocationFailure(mem: std.mem.Allocator) !void {
    const result = try prefs.patchRename(mem, "Default Old media=A4\nDest Old/photo note=\"preserve\"\n", "Old", "New");
    defer mem.free(result);
}
test "rename patch releases partial output on allocation failure" {
    try std.testing.checkAllAllocationFailures(a, renameAllocationFailure, .{});
}
