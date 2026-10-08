//! Automatic counterpart to the manual `save_layout`/`restore_layout`
//! actions (config/actions.zig, which this module reuses unchanged): a
//! periodic autosave of window positions/sizes/zoom to a fixed path in
//! `$XDG_STATE_HOME/rediwm/`, and a best-effort restore attempt a few times
//! after startup.
//!
//! This has nothing to do with detecting whether the previous shutdown was
//! clean or a crash — matching is by app_id against whatever toplevels
//! happen to exist (see `applySavedWindow`), so reapplying a saved position
//! to a window that's already there, or finding nothing to match at all, is
//! harmless. That's true on every normal startup, not just after a crash;
//! this is what makes `data/rediwm-session`'s crash-restart loop useful
//! instead of just reopening every app in the top-left corner.
//!
//! Restoring is retried on a few delays rather than once, because a slow
//! launching app (a browser, say) may not have mapped its first window yet
//! at the first attempt — restore_layout has the same "only affects windows
//! open right now" limitation when a human presses it, so this doesn't
//! introduce a new one.
const std = @import("std");
const wl = @import("wayland").server.wl;

const Server = @import("../Server.zig");
const actions = @import("../config_runtime/actions.zig");
const window_sizes = @import("../window_sizes.zig");

const log = std.log.scoped(.layout_autosave);
const gpa = @import("../main.zig").gpa;

const autosave_interval_ms: c_int = 10_000;
const restore_delays_ms = [_]c_int{ 2000, 5000, 10000, 20000 };

pub const Autosave = struct {
    server: *Server,
    save_timer: ?*wl.EventSource = null,
    restore_timer: ?*wl.EventSource = null,
    restore_attempt: usize = 0,
    /// Hash of the layout this process last wrote; unchanged ticks skip I/O.
    last_saved_hash: ?u64 = null,
    workspace_hash: ?u64 = null,
    workspace_restore: ?@import("../workspace_persistence.zig").Restore = null,

    pub fn create(server: *Server) !*Autosave {
        const self = try gpa.create(Autosave);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server };

        const loop = server.wl_server.getEventLoop();
        self.save_timer = try loop.addTimer(*Autosave, onSaveTimer, self);
        errdefer self.save_timer.?.remove();
        try self.save_timer.?.timerUpdate(autosave_interval_ms);

        self.restore_timer = try loop.addTimer(*Autosave, onRestoreTimer, self);
        try self.restore_timer.?.timerUpdate(restore_delays_ms[0]);

        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        if (workspacePath(arena.allocator(), server)) |path| {
            self.workspace_restore = @import("../workspace_persistence.zig").Restore.load(server, path) catch |err| blk: {
                if (err != error.FileNotFound) log.warn("workspace restore: {s}", .{@errorName(err)});
                break :blk null;
            };
        }
        return self;
    }

    pub fn deinit(self: *Autosave) void {
        if (self.save_timer) |t| t.remove();
        if (self.restore_timer) |t| t.remove();
        if (self.workspace_restore) |*restore| restore.deinit();
        gpa.destroy(self);
    }

    /// Also called once from `Server.deinit` on a clean shutdown, so the
    /// saved layout reflects the last few seconds of movement rather than
    /// whatever it was at the last periodic tick.
    pub fn saveNow(self: *Autosave) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (self.server.world.workspaces.active) {
            if (workspacePath(arena.allocator(), self.server)) |path|
                @import("../workspace_persistence.zig").save(self.server, path, &self.workspace_hash) catch |err| {
                    log.warn("workspace autosave: {s}", .{@errorName(err)});
                };
            return;
        }
        if (autosavePath(arena.allocator(), self.server)) |path| {
            actions.saveLayoutToPathIfChanged(self.server, path, &self.last_saved_hash) catch |err| {
                log.warn("autosave: {}", .{err});
            };
        }
    }

    pub fn mapped(self: *Autosave, top: *@import("../Toplevel.zig")) void {
        if (self.restore_attempt >= restore_delays_ms.len) return;
        if (self.workspace_restore) |*restore| restore.apply(self.server, top);
    }
    pub fn finishMapped(self: *Autosave, top: *@import("../Toplevel.zig")) void {
        if (self.restore_attempt >= restore_delays_ms.len or !self.server.world.workspaces.active) return;
        if (self.workspace_restore) |*restore| restore.finish(self.server, top);
    }
    pub fn cancelWorkspaceRestore(self: *Autosave) void {
        if (self.workspace_restore) |*restore| restore.deinit();
        self.workspace_restore = null;
    }
    pub fn navigation(self: *Autosave) void {
        if (self.workspace_restore) |*restore| if (!restore.initialized) {
            restore.restore_output_selection = false;
        };
    }
    pub fn touch(self: *Autosave, ids: []const u8) void {
        if (self.workspace_restore) |*restore| for (ids) |id| {
            if (id > 0 and id <= 32) restore.touched[id - 1] = true;
        };
    }

    fn onSaveTimer(self: *Autosave) c_int {
        // Keep the original snapshot on disk while slow startup clients can
        // still claim it. Explicit saves and shutdown retain saveNow semantics.
        const pending = self.server.world.workspaces.active and
            (if (self.workspace_restore) |*restore| restore.pending() else false);
        if (!pending) self.saveNow();
        self.save_timer.?.timerUpdate(autosave_interval_ms) catch {};
        return 0;
    }

    fn onRestoreTimer(self: *Autosave) c_int {
        if (self.workspace_restore) |*restore| restore.prepare(self.server);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (autosavePath(arena.allocator(), self.server)) |path| {
            if (!self.server.world.workspaces.active) actions.restoreLayoutFromPath(self.server, path) catch |err| {
                if (err != error.FileNotFound) log.warn("autosave restore: {}", .{err});
            };
        }
        self.restore_attempt += 1;
        if (self.restore_attempt < restore_delays_ms.len) {
            self.restore_timer.?.timerUpdate(restore_delays_ms[self.restore_attempt]) catch {};
        } else self.cancelWorkspaceRestore();
        return 0;
    }
};

fn autosavePath(allocator: std.mem.Allocator, server: *Server) ?[]const u8 {
    const dir = (window_sizes.resolveStateDir(allocator, server.environ) catch return null) orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/autosave-layout.toml", .{dir}) catch null;
}

fn workspacePath(a: std.mem.Allocator, server: *Server) ?[]const u8 {
    const dir = (window_sizes.resolveStateDir(a, server.environ) catch return null) orelse return null;
    return std.fmt.allocPrint(a, "{s}/workspace-layout.json", .{dir}) catch null;
}
