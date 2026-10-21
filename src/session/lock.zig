//! Built-in session lock. The opaque per-output guard exists before locking;
//! optional wallpaper/UI allocation never determines desktop confidentiality.
//!
//! Greeter mode (`rediwm --greeter`) is the same lock that never unlocks: it
//! picks an account and session and signs in through rediwm-dm, then exits.
const i18n = @import("i18n");
const std = @import("std");
const Child = @import("child.zig");
const wl = @import("wayland").server.wl;
const wlr = @import("wlroots");
const sn = @import("../node.zig");
const col = @import("../color.zig");
const xkb = @import("xkbcommon");
const Server = @import("../Server.zig");
const Output = @import("../Output.zig");
const gpa = @import("../main.zig").gpa;
const Buffer = @import("../panel_buffer.zig").PanelBuffer;
const ui = @import("ui");
const text = @import("ui").text;
const png = @import("../png.zig");
const anim = @import("ui").anim;
const greeter_mod = @import("greeter.zig");
const ClientLock = @import("client_lock.zig").ClientLock;
const lock_controls = @import("lock_controls.zig");
const power_cmd = @import("power.zig");
const Controls = lock_controls.Controls;
const CaretOverlay = @import("../caret_overlay.zig").CaretOverlay;
const Greeter = greeter_mod.Greeter;
const login_appearance = @import("login_appearance.zig");
const ImageBuffer = @import("../ImageBuffer.zig");
pub const c = @cImport({
    @cInclude("time.h");
    @cInclude("unistd.h");
    @cInclude("sys/mman.h");
    @cInclude("sys/prctl.h");
});
const text_field = ui.widgets.field;
const SecretInput = ui.widgets.secret_input.Input;
const Auth = opaque {};
extern fn rediwm_account([*]u8, usize, [*]u8, usize, [*]u8, usize) c_int;
extern fn rediwm_secret_clear([*]u8, usize) void;
extern fn rediwm_auth_start([*:0]const u8) ?*Auth;
pub extern fn rediwm_auth_poll(*Auth) c_int;
extern fn rediwm_auth_fd(*Auth) c_int;
extern fn rediwm_auth_destroy(*Auth) void;

pub fn clearKeyScratch(bytes: []u8) void {
    rediwm_secret_clear(bytes.ptr, bytes.len);
}

pub const Lock = struct {
    server: *Server,
    /// Handles the clock and transient controls deadlines.
    timer: *wl.EventSource,
    user: [256]u8 = @splat(0),
    name: [256]u8 = @splat(0),
    password: [512:0]u8 = @splat(0),
    /// Edits `password`; reach it through `field()`.
    input: SecretInput = .{ .storage = &.{} },
    reveal: bool = false,
    caps: bool = false,
    focus: u8 = 0, // password, reveal, unlock, power, restart, account, session
    auth: ?*Auth = null,
    /// Readable when `auth` has a result; only set while `auth` is.
    auth_source: ?*wl.EventSource = null,
    /// Set in greeter mode: rediwm-dm, not PAM, decides, and success exits.
    greeter: ?*Greeter = null,
    greeter_appearance_root: []const u8 = login_appearance.root,
    greeter_default_theme: ui.theme.Theme = .{},
    greeter_appearance: ?login_appearance.Saved = null,
    greeter_wallpaper: ?*ImageBuffer = null,
    /// Who started the lock. Only a client lock whose client died may be
    /// taken over by a new ext-session-lock client.
    origin: enum { builtin, client } = .builtin,
    /// The ext-session-lock client drawing over this lock, if any.
    client: ?*ClientLock = null,
    status: []const u8 = unlock_hint,
    /// Last key into the lock: restarts the field caret's blink phase.
    caret_edit_ms: i64 = 0,
    retry_at: i64 = 0,
    revision: u64 = 1,
    minute: i64 = -1,
    controls_visible: bool = false,
    controls_hide_at: i64 = 0,
    confirm: ?bool = null, // false = power off, true = reboot
    power_child: ?*Child = null,
    avatar: ?png.Image = null,
    /// Volume and brightness sliders; none in the greeter.
    controls: Controls = .{},

    pub fn start(server: *Server) void {
        if (server.locker != null) return;
        _ = create(server, .builtin) catch |err| std.log.err("Cannot lock: {}", .{err});
    }

    /// Locks now. A client lock still needs its PAM account: the built-in
    /// screen is the fallback if the client dies.
    pub fn create(server: *Server, origin: @FieldType(Lock, "origin")) !*Lock {
        std.debug.assert(server.locker == null);
        const self = try gpa.create(Lock);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .timer = undefined, .origin = origin, .status = i18n.tr("Press Enter to unlock") };
        var home: [4096]u8 = @splat(0);
        if (rediwm_account(&self.user, self.user.len, &self.name, self.name.len, &home, home.len) != 0) return error.NoAccount;
        self.timer = try server.wl_server.getEventLoop().addTimer(*Lock, tick, self);
        self.engage();
        self.loadAvatar(std.mem.sliceTo(&home, 0));
        return self;
    }

    /// Covers every output with the greeter until rediwm-dm starts a session.
    pub fn startGreeter(server: *Server) !void {
        std.debug.assert(server.locker == null);
        const greeter = try Greeter.create(server.io, server.wl_server.getEventLoop(), server.environ);
        errdefer greeter.destroy();
        const self = try gpa.create(Lock);
        errdefer gpa.destroy(self);
        self.* = .{ .server = server, .timer = undefined, .greeter = greeter, .greeter_default_theme = server.config.theme };
        self.timer = try server.wl_server.getEventLoop().addTimer(*Lock, tick, self);
        greeter.owner = self;
        greeter.notify = greeterEvent;
        self.engage();
        self.showAccount();
        self.status = self.idleStatus();
        std.log.info("greeter: {d} account(s), {d} session(s), login service {s}", .{
            greeter.users.len,
            greeter.sessions.len,
            if (greeter.client != null) "connected" else "not running (REDIWM_GREETER_FD unset)",
        });
    }

    pub fn engage(self: *Lock) void {
        const server = self.server;
        // First, so a crash anywhere below still restarts the session locked.
        announce(server, true);
        _ = c.mlock(&self.password, self.password.len);
        _ = c.prctl(c.PR_SET_DUMPABLE, @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0));
        server.switcher.cancel();
        server.screenshot_selector.cancel();
        server.locker = self;
        if (server.bluetooth) |bluetooth| bluetooth.closed();
        if (server.input.open_control_center) |cc| cc.bluetooth.clearPin();
        @import("../extra_protocols.zig").rediwm_protocols_revoke(server.extra_protocols);
        server.world.mini_map.hide();
        if (server.ipc) |ipc| ipc.wait_mgr.failAll("SessionLocked");
        if (server.polkit) |agent| agent.pauseForLock();
        // Clear undo state on lock: restoring spatial state across a screen
        // lock session would be confusing (different user context).
        if (server.input.tiling_grab != null) server.input.finishTilingGrab(false);
        server.undo.clear();
        var keyboards = server.input.keyboards.iterator(.forward);
        while (keyboards.next()) |keyboard| keyboard.cancelHardware();
        server.input.cancelResize();
        server.input.cursor_mode = .passthrough;
        server.input.grabbed_toplevel = null;
        server.input.pan_session = null;
        server.input.active_buttons = 0;
        server.input.seat.keyboardEndGrab();
        server.input.seat.pointerEndGrab();
        server.input.window_menu.close();
        server.input.seat.keyboardClearFocus();
        server.input.seat.pointerClearFocus();
        server.input.setDefaultCursor();
        ui.input.reset();
        var it = server.outputs.iterator(.forward);
        while (it.next()) |out| {
            out.closeStartMenu();
            out.closePowerMenu();
            out.closeBattery();
            out.closeWifi();
            out.lock_view.cover(out);
            out.lock_commit_pending = out.isAvailable();
        }
        // The greeter runs no audio and no external tools.
        if (self.greeter == null) {
            server.brightness.query(server);
            _ = self.controls.refresh(server);
        }
        self.changed();
        self.minute = @divTrunc(c.time(null), 60);
        self.scheduleClock();
    }

    /// Wakes for the next clock minute or transient controls timeout.
    pub fn scheduleClock(self: *Lock) void {
        var delay: i64 = (60 - @mod(c.time(null), 60)) * 1000 + 25;
        if (self.controls_visible and self.controls_hide_at > 0) {
            delay = @min(delay, @max(1, self.controls_hide_at - anim.nowMs()));
        }
        self.timer.timerUpdate(@intCast(delay)) catch {};
    }

    /// Everyone outside the compositor who tracks the lock: rediwm-session,
    /// so a crash restarts locked, and logind's LockedHint.
    pub fn announce(server: *Server, locked: bool) void {
        @import("activation.zig").reportLocked(server.environ, locked);
        if (server.power) |power| power.lockChanged(locked);
    }

    /// Whether every available output has committed a frame with the lock
    /// covering it (`Output.lock_commit_pending`).
    pub fn covered(self: *const Lock) bool {
        var it = self.server.outputs.iterator(.forward);
        while (it.next()) |out| {
            if (out.lock_commit_pending and out.isAvailable()) return false;
        }
        return true;
    }

    /// An output committed a covered frame, went dark or went away.
    pub fn outputCovered(self: *Lock) void {
        if (self.client) |client| client.checkLocked();
        if (self.covered()) if (self.server.power) |power| power.lockCovered();
    }

    /// Greeter: shows the selected account's name and picture.
    pub fn showAccount(self: *Lock) void {
        const greeter = self.greeter orelse return;
        self.applyAccountAppearance(if (greeter.selectedUser()) |user| user.uid else null);
        if (self.avatar) |avatar| avatar.deinit(gpa);
        self.avatar = null;
        @memset(&self.user, 0);
        @memset(&self.name, 0);
        const user = greeter.selectedUser() orelse return;
        const n = @min(user.name.len, self.user.len - 1);
        @memcpy(self.user[0..n], user.name[0..n]);
        const m = @min(user.real.len, self.name.len - 1);
        @memcpy(self.name[0..m], user.real[0..m]);
        // Home directories are usually private to their owner; AccountsService
        // pictures are the ones a greeter can normally read.
        self.loadAvatar(user.home);
    }

    pub fn applyAccountAppearance(self: *Lock, uid: ?u32) void {
        // Reset first: an account without a snapshot must not inherit the
        // preceding account's palette, fonts or wallpaper.
        self.clearAccountAppearance();
        if (uid) |id| if (self.greeter_appearance_root.len > 0) {
            self.greeter_appearance = login_appearance.load(gpa, self.greeter_appearance_root, id) catch null;
        };
        if (self.greeter_appearance) |*saved| {
            ui.theme.global = saved.tokens;
            if (saved.wallpaper) |image| {
                self.greeter_wallpaper = ImageBuffer.createFromDecoded(image) catch null;
                if (self.greeter_wallpaper != null) saved.wallpaper = null; // buffer owns pixels
            }
        }
        text.setPreferredFamilies(ui.theme.global.font, ui.theme.global.mono_font);
        self.themeChanged();
    }

    pub fn clearAccountAppearance(self: *Lock) void {
        ui.theme.global = self.greeter_default_theme;
        text.setPreferredFamilies(ui.theme.global.font, ui.theme.global.mono_font);
        if (self.greeter_wallpaper) |image| image.base.drop();
        self.greeter_wallpaper = null;
        if (self.greeter_appearance) |*saved| saved.deinit(gpa);
        self.greeter_appearance = null;
    }

    pub fn idleStatus(self: *const Lock) []const u8 {
        const greeter = self.greeter orelse return i18n.tr("Press Enter to unlock");
        if (greeter.users.len == 0) return i18n.tr("No user accounts found");
        if (greeter.sessions.len == 0) return i18n.tr("No sessions installed");
        return i18n.tr("Press Enter to log in");
    }

    pub fn busy(self: *const Lock) bool {
        if (self.greeter) |greeter| return greeter.busy();
        return self.auth != null;
    }

    pub fn prompting(self: *const Lock) bool {
        const greeter = self.greeter orelse return false;
        return greeter.phase == .prompting;
    }

    pub fn greeterEvent(owner: ?*anyopaque, event: greeter_mod.Event) void {
        const self: *Lock = @ptrCast(@alignCast(owner.?));
        switch (event) {
            .status => |message| self.status = message,
            .prompt => |p| {
                self.clear();
                self.status = p.text;
                self.reveal = p.visible;
                self.focus = 0;
            },
            .rejected => {
                self.status = i18n.tr("Incorrect password. Try again.");
                self.retry_at = anim.nowMs() + 1500;
            },
            .failed => |message| {
                self.status = message;
                self.retry_at = anim.nowMs() + 1500;
            },
            .started => {
                self.status = i18n.tr("Starting session…");
                std.log.info("greeter: rediwm-dm accepted the session; exiting", .{});
                // Out to black, as the session comes in from it.
                self.server.reveal.cover(self.server, Server.terminate);
            },
            .disconnected => {
                self.status = i18n.tr("Lost contact with login service. Try again.");
                std.log.info("greeter: lost the rediwm-dm connection; exiting so it starts a new greeter", .{});
                self.server.terminate();
            },
        }
        self.changed();
    }

    pub fn loadAvatar(self: *Lock, home: []const u8) void {
        var path: [4352]u8 = undefined;
        if (home.len > 0) for ([_][]const u8{ ".face", ".face.png" }) |file| {
            const p = std.fmt.bufPrint(&path, "{s}/{s}", .{ home, file }) catch continue;
            if (self.readAvatar(p)) return;
        };
        const p = std.fmt.bufPrint(&path, "/var/lib/AccountsService/icons/{s}", .{std.mem.sliceTo(&self.user, 0)}) catch return;
        _ = self.readAvatar(p);
    }

    pub fn readAvatar(self: *Lock, path: []const u8) bool {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.server.io, path, gpa, .limited(4 * 1024 * 1024)) catch return false;
        defer gpa.free(bytes);
        // Bound decoded allocation as well as file size before using the PNG decoder.
        if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return false;
        if (std.mem.readInt(u32, bytes[16..20], .big) > 2048 or std.mem.readInt(u32, bytes[20..24], .big) > 2048) return false;
        self.avatar = png.decode(gpa, bytes) catch return false;
        return true;
    }

    /// The password editor, bound to `password` on every access so a moved
    /// `Lock` (tests build them on the stack) never leaves it dangling. The
    /// last byte stays zero: PAM reads `password` as a C string.
    pub fn field(self: *Lock) *SecretInput {
        self.input.storage = self.password[0 .. self.password.len - 1];
        return &self.input;
    }

    pub fn clear(self: *Lock) void {
        rediwm_secret_clear(&self.password, self.password.len);
        self.input.len = 0;
        self.input.cursor = 0;
        self.reveal = false;
    }

    pub fn destroy(self: *Lock) void {
        if (self.client) |client| client.end();
        self.timer.remove();
        if (self.power_child) |child| child.detach();
        if (self.auth_source) |source| source.remove();
        if (self.auth) |auth| rediwm_auth_destroy(auth);
        if (self.greeter) |greeter| {
            self.clearAccountAppearance();
            greeter.destroy();
        }
        self.clear();
        _ = c.munlock(&self.password, self.password.len);
        if (self.avatar) |avatar| avatar.deinit(gpa);
        gpa.destroy(self);
    }

    /// Ends the lock after PAM success or the lock client's own unlock.
    pub fn release(self: *Lock) void {
        // Greeter mode never starts PAM; only rediwm-dm can end it.
        std.debug.assert(self.greeter == null);
        const server = self.server;
        server.input.seat.keyboardEndGrab();
        server.input.seat.pointerEndGrab();
        server.input.seat.keyboardClearFocus();
        server.input.seat.pointerClearFocus();
        server.locker = null;
        // Clear undo across the lock boundary.
        server.undo.clear();
        var it = server.outputs.iterator(.forward);
        while (it.next()) |out| {
            out.lock_view.hide();
            out.lock_commit_pending = false;
        }
        self.destroy();
        if (server.polkit) |agent| agent.resumeAfterLock();
        if (server.world.toplevels.first()) |top| server.world.focus(top);
        server.scheduleFrames();
        announce(server, false);
    }

    /// The lock client died without unlocking: the built-in screen takes over.
    pub fn clientGone(self: *Lock) void {
        self.focus = 0;
        self.status = i18n.tr("Press Enter to unlock");
        self.changed();
    }

    pub fn changed(self: *Lock) void {
        self.revision +%= 1;
        self.server.scheduleFrames();
    }

    /// A reskin invalidates both the screen and its small controls raster.
    pub fn themeChanged(self: *Lock) void {
        var outputs = self.server.outputs.iterator(.forward);
        while (outputs.next()) |out| out.lock_view.controls_key = null;
        self.changed();
    }

    /// Volume, mute or brightness changed; redraw only the controls block.
    pub fn controlsChanged(self: *Lock) void {
        if (self.greeter != null) return;
        const previous_volume = self.controls.volume;
        const previous_muted = self.controls.muted;
        const previous_brightness = self.controls.brightness;
        if (self.controls.refresh(self.server)) {
            self.server.scheduleFrames();
            const active_changed = if (self.controls.active) |kind| switch (kind) {
                .volume => self.controls.volume != previous_volume or self.controls.muted != previous_muted,
                .brightness => self.controls.brightness != previous_brightness,
            } else false;
            if (self.controls_visible and active_changed) self.showControls(self.controls.active.?);
        }
    }

    /// Hardware feedback selects the same row as pointer use, including when
    /// a key leaves the value unchanged at its limit.
    pub fn showControl(self: *Lock, kind: lock_controls.Kind) void {
        if (self.greeter != null) return;
        if (self.controls.refresh(self.server)) self.server.scheduleFrames();
        self.showControls(kind);
    }

    pub fn showControls(self: *Lock, requested: lock_controls.Kind) void {
        if (self.greeter != null or self.controls.height() == 0) return;
        const kind = if (self.controls.drag) |drag| drag.kind else requested;
        const selected = self.controls.select(kind);
        if (self.controls.active != kind) return;
        const newly_visible = !self.controls_visible;
        self.controls_visible = true;
        self.controls_hide_at = anim.nowMs() + 2500;
        self.scheduleClock();
        if (newly_visible or selected) self.server.scheduleFrames();
    }

    /// The control under a layout point, with its track's left edge and
    /// width in layout pixels. An ext-session-lock client's surface hides
    /// the built-in controls along with the rest of the screen.
    pub fn controlsAt(self: *Lock, x: f64, y: f64) ?ControlsAt {
        if (self.greeter != null) return null;
        const out = Output.atLayout(self.server, x, y) orelse return null;
        if (self.client) |client| if (client.covers(out)) return null;
        const b = out.cached_box;
        const found = controlsPick(&self.controls, @floatFromInt(b.width), @floatFromInt(b.height), @floatCast(x - @as(f64, @floatFromInt(b.x))), @floatCast(y - @as(f64, @floatFromInt(b.y)))) orelse return null;
        return .{ .hit = found.hit, .left = found.left + @as(f32, @floatFromInt(b.x)), .span = found.span };
    }

    /// The pointer moved: continues a drag, else follows the hover.
    pub fn pointerMoved(self: *Lock, x: f64, y: f64) void {
        if (self.controls.drag != null) {
            const before = self.controls.revision;
            self.controls.dragTo(self.server, @floatCast(x));
            self.controls_hide_at = anim.nowMs() + 2500;
            self.scheduleClock();
            if (self.controls.revision != before) self.server.scheduleFrames();
            return;
        }
        const at = self.controlsAt(x, y);
        if (at) |found| self.showControls(found.hit.kind);
        const hit: ?lock_controls.Hit = if (at) |found| found.hit else null;
        if (self.controls.setHover(hit)) self.server.scheduleFrames();
    }

    /// The primary button went up, wherever the pointer is.
    pub fn pointerReleased(self: *Lock) void {
        if (self.controls.endDrag()) {
            self.controls_hide_at = anim.nowMs() + 2500;
            self.scheduleClock();
            self.server.scheduleFrames();
        }
    }

    pub fn powerExited(owner: ?*anyopaque, _: *Child, status: ?u32) void {
        const self: *Lock = @ptrCast(@alignCast(owner.?));
        self.power_child = null;
        self.status = if (status != null and status.? == 0) i18n.tr("Power request accepted") else i18n.tr("Power request denied or unavailable");
        self.changed();
    }

    pub fn tick(self: *Lock) c_int {
        const minute = @divTrunc(c.time(null), 60);
        if (minute != self.minute) {
            self.minute = minute;
            self.changed();
        }
        if (self.controls_visible and self.controls.drag == null and anim.nowMs() >= self.controls_hide_at) {
            self.controls_visible = false;
            self.controls_hide_at = 0;
            _ = self.controls.setHover(null);
            self.server.scheduleFrames();
        }
        self.scheduleClock();
        return 0;
    }

    /// The PAM worker finished: its eventfd became readable.
    pub fn authReady(_: c_int, _: wl.EventMask, self: *Lock) c_int {
        const auth = self.auth orelse return 0;
        const result = rediwm_auth_poll(auth);
        if (result == 0) return 0;
        // Removing a source inside its own callback is safe: libwayland defers the free.
        if (self.auth_source) |source| source.remove();
        self.auth_source = null;
        rediwm_auth_destroy(auth);
        self.auth = null;
        self.clear();
        if (result == 1) {
            self.release();
            return 0;
        }
        self.status = i18n.tr("Unable to unlock. Try again.");
        self.retry_at = anim.nowMs() + 1500;
        self.changed();
        return 0;
    }

    pub fn submit(self: *Lock) void {
        if (self.greeter) |greeter| return self.submitGreeter(greeter);
        if (self.auth != null or self.input.len == 0 or anim.nowMs() < self.retry_at) return;
        self.auth = rediwm_auth_start(&self.password);
        self.clear();
        if (self.auth) |auth| {
            self.auth_source = self.server.wl_server.getEventLoop().addFd(*Lock, rediwm_auth_fd(auth), .{ .readable = true }, authReady, self) catch null;
            if (self.auth_source == null) {
                // Nothing would ever report the result. Joining waits for PAM
                // to finish, which is acceptable on this resource-exhaustion path.
                rediwm_auth_destroy(auth);
                self.auth = null;
            }
        }
        self.status = if (self.auth != null) i18n.tr("Checking password…") else i18n.tr("Authentication unavailable. Try again.");
        self.changed();
    }

    pub fn submitGreeter(self: *Lock, greeter: *Greeter) void {
        if (anim.nowMs() < self.retry_at) return;
        defer self.changed();
        if (greeter.phase == .prompting) {
            greeter.answer(self.field().value()) catch {
                self.status = i18n.tr("Lost contact with login service. Try again.");
            };
            if (greeter.phase == .authenticating) self.status = i18n.tr("Checking…");
            self.clear();
            return;
        }
        if (greeter.busy() or self.input.len == 0) return;
        self.status = greeter.begin(self.field().value()) catch |err| switch (err) {
            error.NoService => i18n.tr("No login service"),
            error.NoAccount => i18n.tr("No user accounts found"),
            error.NoSession => i18n.tr("No sessions installed"),
            else => i18n.tr("Cannot reach login service. Try again."),
        };
        self.clear();
    }

    /// Greeter: account or session choice changed.
    pub fn choose(self: *Lock, target: u8, delta: isize) void {
        const greeter = self.greeter orelse return;
        if (greeter.phase != .idle) return;
        if (target == focus_account) {
            if (greeter.users.len < 2) return;
            greeter.cycleUser(delta);
            self.clear();
            self.showAccount();
        } else if (target == focus_session) {
            greeter.cycleSession(delta);
        }
        self.status = self.idleStatus();
    }

    /// Tab order; greeter mode adds the account and session choosers.
    pub fn focusOrder(self: *const Lock, buf: *[7]u8) []const u8 {
        const greeter = self.greeter orelse {
            buf[0..5].* = .{ 0, 1, 2, 3, 4 };
            return buf[0..5];
        };
        var n: usize = 0;
        if (greeter.users.len > 1) {
            buf[n] = focus_account;
            n += 1;
        }
        for ([_]u8{ 0, 1, 2 }) |f| {
            buf[n] = f;
            n += 1;
        }
        if (greeter.sessions.len > 1) {
            buf[n] = focus_session;
            n += 1;
        }
        buf[n..][0..2].* = .{ 3, 4 };
        return buf[0 .. n + 2];
    }

    pub fn moveFocus(self: *Lock, backward: bool) void {
        var buf: [7]u8 = undefined;
        const order = self.focusOrder(&buf);
        const at = std.mem.indexOfScalar(u8, order, self.focus) orelse 0;
        self.focus = order[(at + if (backward) order.len - 1 else 1) % order.len];
    }

    pub fn modifiers(self: *Lock, mods: wlr.Keyboard.ModifierMask) void {
        if (self.caps == mods.caps) return;
        self.caps = mods.caps;
        self.changed();
    }

    /// Which held keys `Keyboard` repeats: typing and caret keys in the
    /// field, and stepping through the greeter's account and session
    /// choices. Buttons, Return and Escape fire once.
    pub fn keyRepeats(self: *const Lock, sym: xkb.Keysym, utf8: []const u8) bool {
        if (self.busy()) return false;
        if (self.focus == 0) return @import("../input/repeat_keys.zig").editing(sym, utf8);
        if (self.focus == focus_account or self.focus == focus_session) {
            const value = @intFromEnum(sym);
            return value == xkb.Keysym.Left or value == xkb.Keysym.Right;
        }
        return false;
    }

    pub fn key(self: *Lock, sym: xkb.Keysym, utf8: []const u8, mods: wlr.Keyboard.ModifierMask) void {
        self.caps = mods.caps;
        self.caret_edit_ms = anim.nowMs();
        defer self.changed();
        const value = @intFromEnum(sym);
        if (value == xkb.Keysym.Escape) {
            self.clear();
            self.confirm = null;
            self.focus = 0;
            if (self.prompting()) {
                self.greeter.?.cancel();
                self.status = i18n.tr("Sign-in cancelled");
            } else if (!self.busy()) self.status = self.idleStatus();
            return;
        }
        if (self.busy()) return;
        switch (value) {
            xkb.Keysym.Tab, xkb.Keysym.ISO_Left_Tab => self.moveFocus(mods.shift or value == xkb.Keysym.ISO_Left_Tab),
            xkb.Keysym.Up, xkb.Keysym.Down => if (!self.prompting()) self.choose(focus_account, if (value == xkb.Keysym.Up) -1 else 1),
            xkb.Keysym.Left, xkb.Keysym.Right => if (self.focus == focus_account or self.focus == focus_session)
                self.choose(self.focus, if (value == xkb.Keysym.Left) -1 else 1)
            else if (self.focus == 0) {
                if (value == xkb.Keysym.Left) self.field().left() else self.field().right();
            },
            xkb.Keysym.Home => if (self.focus == 0) {
                self.input.cursor = 0;
            },
            xkb.Keysym.End => if (self.focus == 0) {
                self.input.cursor = self.input.len;
            },
            xkb.Keysym.Return, xkb.Keysym.KP_Enter => self.activate(self.focus),
            xkb.Keysym.space => {
                if (self.focus != 0) self.activate(self.focus) else _ = self.field().insert(" ");
            },
            xkb.Keysym.BackSpace => self.field().backspace(),
            xkb.Keysym.Delete => if (self.focus == 0) self.field().delete(),
            else => {
                if (mods.ctrl or mods.alt or mods.logo) return;
                if (utf8.len == 0 or utf8[0] < 32 or utf8[0] == 127) return;
                if (!self.field().insert(utf8)) return;
                self.focus = 0;
                self.confirm = null;
                if (!self.prompting()) self.status = self.idleStatus();
            },
        }
    }

    pub fn activate(self: *Lock, focus: u8) void {
        switch (focus) {
            0, 2 => self.submit(),
            1 => self.reveal = !self.reveal,
            3, 4 => {
                if (self.power_child != null) return;
                const reboot = focus == 4;
                if (self.confirm == null or self.confirm.? != reboot) {
                    self.clear();
                    self.confirm = reboot;
                    self.status = if (reboot) i18n.tr("Restart? Activate Restart again to confirm.") else i18n.tr("Power off? Activate Power again to confirm.");
                    return;
                }
                self.confirm = null;
                // systemctl/loginctl delegate to logind/polkit; no privileged
                // syscall or shell interpolation. Never request an interactive
                // auth agent behind the locked screen.
                var argv: [4][]const u8 = undefined;
                var child = std.process.spawn(self.server.io, .{ .argv = power_cmd.commandArgv(&argv, if (reboot) .reboot else .poweroff, false, true) }) catch {
                    self.status = i18n.tr("Power service unavailable");
                    return;
                };
                self.power_child = Child.watch(gpa, self.server.wl_server.getEventLoop(), child.id.?, self, powerExited) catch {
                    child.kill(self.server.io);
                    self.status = i18n.tr("Power service unavailable");
                    return;
                };
                self.status = i18n.tr("Requesting power action…");
            },
            focus_account, focus_session => self.choose(focus, 1),
            else => {},
        }
    }

    pub fn click(self: *Lock, x: f64, y: f64) void {
        if (self.controlsAt(x, y)) |at| {
            self.showControls(at.hit.kind);
            switch (at.hit.part) {
                .icon => if (at.hit.kind == .volume) lock_controls.toggleMute(self.server),
                .track => self.controls.beginDrag(self.server, at.hit.kind, at.left, at.span, @floatCast(x)),
            }
            self.server.scheduleFrames();
            return;
        }
        const out = Output.atLayout(self.server, x, y) orelse return;
        const b = out.cached_box;
        const geo = Geometry.init(@floatFromInt(b.width), @floatFromInt(b.height));
        const px: f32 = @floatCast(x - @as(f64, @floatFromInt(b.x)));
        const py: f32 = @floatCast(y - @as(f64, @floatFromInt(b.y)));
        // Design units, as the field is laid out.
        const dx = px / geo.s;
        const dy = py / geo.s;
        const box = geo.field();
        const eye = text_field.arrange(box, field_options, ui.theme.shellPalette()).trailing.?;
        if (dx >= box.x and dx <= box.x + box.w and dy >= box.y and dy <= box.y + box.h) {
            self.focus = if (dx >= eye.x) 1 else 0;
            if (self.focus == 1) self.activate(1);
        } else {
            const submit_box = geo.submit();
            if (dx >= submit_box.x and dx <= submit_box.x + submit_box.w and dy >= submit_box.y and dy <= submit_box.y + submit_box.h) {
                self.focus = 2;
                self.activate(2);
            }
        }
        if (self.greeter) |greeter| if (!self.busy()) {
            const ay = geo.top + 214 * geo.s;
            const cx = geo.w / 2;
            if (greeter.users.len > 1 and py >= ay and py <= ay + 120 * geo.s) {
                if (px >= cx - 150 * geo.s and px <= cx - 70 * geo.s) {
                    self.focus = focus_account;
                    self.choose(focus_account, -1);
                } else if (px >= cx + 70 * geo.s and px <= cx + 150 * geo.s) {
                    self.focus = focus_account;
                    self.choose(focus_account, 1);
                }
            }
            if (greeter.sessions.len > 1 and py >= geo.h - 100 * geo.s and py <= geo.h - 20 * geo.s and px <= 320 * geo.s) {
                self.focus = focus_session;
                self.choose(focus_session, 1);
            }
        };
        if (py >= geo.h - 100 * geo.s and py <= geo.h - 20 * geo.s) {
            if (px >= geo.w - 220 * geo.s and px < geo.w - 120 * geo.s) {
                self.focus = 3;
                self.activate(3);
            } else if (px >= geo.w - 120 * geo.s and px < geo.w - 20 * geo.s) {
                self.focus = 4;
                self.activate(4);
            }
        }
        self.changed();
    }
};

pub const ControlsAt = struct { hit: lock_controls.Hit, left: f32, span: f32 };

/// What the volume/brightness block of a `w` x `h` output has at an
/// output-local point: the control, and its track's left edge and width in
/// the same pixels.
pub fn controlsPick(controls: *const Controls, w: f32, h: f32, px: f32, py: f32) ?ControlsAt {
    if (controls.rows() == 0) return null;
    const geo = Geometry.init(w, h);
    const box = geo.controlsBox(controls.height());
    const origin_x: f32 = @floatFromInt(box.x);
    const origin_y: f32 = @floatFromInt(box.y);
    const hit = controls.pick((px - origin_x) / geo.s, (py - origin_y) / geo.s) orelse return null;
    return .{ .hit = hit, .left = origin_x + lock_controls.track_x * geo.s, .span = lock_controls.track_w * geo.s };
}

pub const unlock_hint = "Press Enter to unlock";
pub const login_hint = "Press Enter to log in";
pub const focus_account: u8 = 5;
pub const focus_session: u8 = 6;

pub const Geometry = struct {
    s: f32,
    w: f32,
    h: f32,
    left: f32,
    top: f32,
    pub fn init(w: f32, h: f32) Geometry {
        // ui_scale trims the whole panel (fonts, field, button) down from the
        // 600x900 design canvas's 1:1 cap — full size read as oversized on
        // typical outputs.
        const ui_scale: f32 = 0.85;
        const s = @min(1, @min(w / 600, h / 900)) * ui_scale;
        return .{ .w = w, .h = h, .s = s, .left = (w - 390 * s) / 2, .top = (h - 670 * s) / 2 - 20 * s };
    }

    /// The password field in design units: draw through `Renderer.zoomed(s)`.
    pub fn field(geo: Geometry) text_field.Rect {
        return .{ .x = geo.left / geo.s, .y = geo.top / geo.s + 430, .w = 390, .h = 56 };
    }

    /// Power (0) and Restart (1), bottom right, in the same units.
    pub fn powerAction(geo: Geometry, i: usize) text_field.Rect {
        const center = geo.w / geo.s - 170 + @as(f32, @floatFromInt(i)) * 100;
        return .{ .x = center - 45, .y = geo.h / geo.s - 96, .w = 90, .h = 76 };
    }

    /// The volume/brightness block of `block_h` design units, centred on the
    /// power buttons' band and horizontally on the screen, in whole layout
    /// pixels output-local. It never reaches the power buttons: the canvas is
    /// at least 705 design units wide, they start 215 from its right edge.
    pub fn controlsBox(geo: Geometry, block_h: f32) struct { x: i32, y: i32, w: i32, h: i32 } {
        const x = (geo.w / geo.s - lock_controls.width) / 2;
        const y = geo.h / geo.s - 58 - block_h / 2;
        return .{
            .x = @intFromFloat(@round(x * geo.s)),
            .y = @intFromFloat(@round(y * geo.s)),
            .w = @intFromFloat(@ceil(lock_controls.width * geo.s)),
            .h = @intFromFloat(@ceil(block_h * geo.s)),
        };
    }

    /// The Unlock / Log In button, in the same units.
    pub fn submit(geo: Geometry) text_field.Rect {
        return .{ .x = geo.left / geo.s, .y = geo.top / geo.s + 508, .w = 390, .h = 52 };
    }
};

pub const field_options: text_field.Options = .{ .size = .lg, .secret_dots = .{ .diameter = 0.46, .pitch = 1.05 }, .trailing = .reveal };

pub const View = struct {
    tree: *sn.Tree,
    guard: *sn.Rect,
    wallpaper: *sn.Buffer,
    ui_node: *sn.Buffer,
    /// The password field's caret, above `ui_node`: it blinks and glides
    /// without re-rastering the whole screen.
    caret: CaretOverlay,
    /// The volume/brightness block: its own small raster (`Lock.controls`),
    /// so dragging a slider never re-rasters the screen under it.
    controls_node: *sn.Buffer,
    controls_key: ?ControlsKey = null,
    revision: u64 = 0,
    width: i32 = 0,
    height: i32 = 0,
    scale: f32 = 0,

    pub fn create(parent: *sn.Tree) !View {
        const tree = try parent.createSceneTree();
        errdefer tree.node.destroy();
        const guard = try col.createRect(tree, 0, 0, col.Straight.fromRgba(lockBackground()).premultiply());
        const wallpaper = try tree.createSceneBuffer(null);
        wallpaper.setOpacity(ui.theme.global.lock_wallpaper_opacity);
        wallpaper.setFilterMode(.bilinear);
        const node = try tree.createSceneBuffer(null);
        node.setFilterMode(.bilinear);
        const caret = try CaretOverlay.create(tree);
        const controls_node = try tree.createSceneBuffer(null);
        controls_node.setFilterMode(.bilinear);
        controls_node.node.setEnabled(false);
        tree.node.setEnabled(false);
        return .{ .tree = tree, .guard = guard, .wallpaper = wallpaper, .ui_node = node, .caret = caret, .controls_node = controls_node };
    }

    pub fn cover(self: *View, out: *Output) void {
        var box: wlr.Box = undefined;
        out.server.output_layout.getBox(out.wlr_output, &box);
        self.tree.node.setPosition(box.x, box.y);
        self.guard.setSize(box.width, box.height);
        col.setRect(self.guard, col.Straight.fromRgba(lockBackground()).premultiply());
        self.wallpaper.setOpacity(ui.theme.global.lock_wallpaper_opacity);
        self.tree.node.setEnabled(true);
        out.server.lock_tree.node.raiseToTop();
    }

    pub fn hide(self: *View) void {
        self.tree.node.setEnabled(false);
        self.ui_node.setBuffer(null);
        self.wallpaper.setBuffer(null);
        self.caret.hide();
        self.hideControls();
        self.revision = 0;
        Buffer.drainPool();
    }

    pub fn hideControls(self: *View) void {
        self.controls_node.node.setEnabled(false);
        self.controls_node.setBuffer(null);
        self.controls_key = null;
    }

    /// Rasters the volume/brightness block when it, or the output it sits
    /// on, changed. The greeter and an output without either backend show none.
    pub fn syncControls(self: *View, lock: *Lock, b: wlr.Box, scale: f32) void {
        const block_h = lock.controls.height();
        if (lock.greeter != null or !lock.controls_visible or block_h == 0 or b.width <= 0 or b.height <= 0) return self.hideControls();
        const key = ControlsKey{ .revision = lock.controls.revision, .width = b.width, .height = b.height, .scale = scale };
        if (self.controls_key) |have| if (std.meta.eql(have, key)) return;
        const geo = Geometry.init(@floatFromInt(b.width), @floatFromInt(b.height));
        const box = geo.controlsBox(block_h);
        const buf = Buffer.createUnpooled(box.w, box.h, scale) catch return;
        defer buf.base.drop();
        var renderer = ui.paint.Renderer.init(buf.pixels, buf.width, buf.height, scale);
        var zoomed = renderer.zoomed(geo.s);
        zoomed.palette = ui.theme.shellPalette();
        lock.controls.paint(&zoomed);
        buf.publish(self.controls_node, scale, null);
        self.controls_node.setDestSize(box.w, box.h);
        self.controls_node.node.setPosition(box.x, box.y);
        self.controls_node.node.setEnabled(true);
        self.controls_key = key;
    }

    /// Returns whether the field's caret still wants frames.
    pub fn sync(self: *View, out: *Output) bool {
        const lock = out.server.locker orelse return false;
        self.cover(out);
        // A lock client's surface replaces the built-in screen, which stays
        // ready underneath in case the client dies.
        const covered = if (lock.client) |client| blk: {
            client.syncOutput(out);
            break :blk client.covers(out);
        } else false;
        self.ui_node.node.setEnabled(!covered);
        self.wallpaper.node.setEnabled(!covered);
        if (covered) {
            self.caret.hide();
            self.hideControls();
            return false;
        }
        const b = out.cached_box;
        const scale = out.wlr_output.scale;
        const now = anim.nowMs();
        self.syncControls(lock, b, scale);
        if (self.revision == lock.revision and self.width == b.width and self.height == b.height and self.scale == scale) return self.caret.frame(now);
        if (b.width <= 0 or b.height <= 0) return false;
        // Drop stale pixels before a failed resize allocation.
        self.ui_node.setBuffer(null);
        if (lock.greeter_wallpaper orelse out.server.wallpaper) |image| {
            self.wallpaper.setBuffer(&image.base);
            self.wallpaper.setDestSize(b.width, b.height);
        } else self.wallpaper.setBuffer(null);
        const buf = Buffer.create(b.width, b.height, scale) catch return false;
        defer buf.base.drop();
        buf.sensitive = true;
        var renderer = ui.paint.Renderer{ .pixels = buf.pixels, .width = buf.width, .height = buf.height, .scale = scale };
        const painted = paint(&renderer, lock, @floatFromInt(b.width), @floatFromInt(b.height), lock.server.config.region.clock_24h);
        self.caret.update(now, if (painted.caret) |place| .{
            .caret = place,
            .origin_x = 0,
            .origin_y = 0,
            .factor = painted.factor,
            .scale = scale,
            .color = ui.theme.shellPalette().caretColor(),
        } else null, lock.caret_edit_ms);
        self.ui_node.setBuffer(&buf.base);
        self.ui_node.setDestSize(b.width, b.height);
        self.revision = lock.revision;
        self.width = b.width;
        self.height = b.height;
        self.scale = scale;
        return self.caret.frame(now);
    }
};

pub const ControlsKey = struct { revision: u64, width: i32, height: i32, scale: f32 };

pub fn lockBackground() [4]f32 {
    var bg = ui.theme.global.lock_bg;
    bg[3] = 1;
    return bg;
}
pub fn label(r: *ui.paint.Renderer, cx: f32, y: f32, width: f32, height: f32, value: []const u8, size: f32, color: [4]f32) void {
    const measured = text.measureWidthF(value, .manrope, size, r.scale) catch width;
    const w = @min(width, measured + 1);
    r.drawText(cx - w / 2, y, w, height, .{ .content = value, .font_size = size, .color = color });
}

/// Where the field's caret went, in design units `factor` layout pixels
/// wide; the caret itself is the view's overlay.
pub const Painted = struct { caret: ?ui.widgets.secret_input.Input.CaretPlace, factor: f32 };

pub fn paint(r: *ui.paint.Renderer, lock: *Lock, w: f32, h: f32, clock_24h: bool) Painted {
    const fg = ui.theme.global.lock_fg;
    const muted = ui.theme.global.lock_dim;
    const geo = Geometry.init(w, h);
    const s = geo.s;
    const y = geo.top;
    const cx = w / 2;
    var raw = c.time(null);
    var tm: c.struct_tm = undefined;
    var time_buf: [32]u8 = @splat(0);
    var date_buf: [96]u8 = @splat(0);
    var period: [16]u8 = @splat(0);
    var pattern: [256]u8 = undefined;
    const date_pattern = std.fmt.bufPrintZ(&pattern, "{s}", .{i18n.trc("date", "%A, %B %-d")}) catch "%A, %B %-d";
    if (c.localtime_r(&raw, &tm) != null) {
        _ = c.strftime(&time_buf, time_buf.len, if (clock_24h) "%H:%M" else "%l:%M", &tm);
        if (!clock_24h) _ = c.strftime(&period, period.len, "%p", &tm);
        _ = c.strftime(&date_buf, date_buf.len, date_pattern, &tm);
    }
    const time_str = std.mem.trim(u8, std.mem.sliceTo(&time_buf, 0), " ");
    const period_str = std.mem.sliceTo(&period, 0);
    const tw = text.measureWidthF(time_str, .manrope, 100 * s, r.scale) catch 220 * s;
    const pw = text.measureWidthF(period_str, .manrope, 64 * s, r.scale) catch 100 * s;
    const period_gap: f32 = if (period_str.len == 0) 0 else 20 * s;
    const start = cx - (tw + pw + period_gap) / 2;
    r.drawText(start, y, tw + 2, 110 * s, .{ .content = time_str, .font_size = 100 * s, .color = fg });
    r.drawText(start + tw + period_gap, y + 24 * s, pw + 2, 86 * s, .{ .content = period_str, .font_size = 64 * s, .color = muted });
    label(r, cx, y + 110 * s, w, 45 * s, std.mem.sliceTo(&date_buf, 0), 30 * s, muted);
    r.fillRect(cx - 35 * s, y + 174 * s, 70 * s, 2 * s, .{ .color = muted });
    // Shared components draw in the 600x900 design units the layout uses.
    var zoomed = r.zoomed(s);
    zoomed.palette = ui.theme.shellPalette();
    const avatar_image: ?ui.paint.Image = if (lock.avatar) |image| .{ .pixels = image.pixels, .width = image.width, .height = image.height } else null;
    ui.widgets.avatar.paint(&zoomed, cx / s - 60, y / s + 214, 120, .{ .image = avatar_image, .ring = true });
    const name = std.mem.sliceTo(&lock.name, 0);
    label(r, cx, y + 343 * s, 500 * s, 36 * s, if (name.len > 0) name else std.mem.sliceTo(&lock.user, 0), 25 * s, fg);
    label(r, cx, y + 380 * s, 500 * s, 30 * s, std.mem.sliceTo(&lock.user, 0), 18 * s, muted);
    if (lock.greeter) |greeter| paintChoices(r, lock, greeter, geo, h);
    const field = text_field.paintSecret(&zoomed, geo.field(), field_options, .{
        .focused = lock.focus == 0,
        .disabled = lock.busy(),
        .revealed = lock.reveal,
        .trailing_focused = lock.focus == 1,
        .external_caret = true,
    }, lock.field(), if (lock.prompting()) i18n.tr("Response") else i18n.tr("Password"));
    const action = if (lock.greeter != null)
        (if (lock.busy()) i18n.tr("Signing in…") else if (lock.prompting()) i18n.tr("Continue") else i18n.tr("Log In"))
    else if (lock.busy()) i18n.tr("Checking…") else i18n.tr("Unlock");
    ui.widgets.button.paint(&zoomed, geo.submit(), .{
        .variant = .primary,
        .size = .lg,
        .label = action,
        .trailing_icon = .chevron_right,
    }, .{ .pointer = if (lock.busy()) .disabled else .idle, .focused = lock.focus == 2 });
    label(r, cx, y + 590 * s, w - 20, 32 * s, if (lock.caps and std.mem.eql(u8, lock.status, lock.idleStatus())) i18n.tr("Caps Lock is on") else lock.status, 16 * s, muted);
    for (0..2) |i| ui.widgets.button.paint(&zoomed, geo.powerAction(i), .{
        .variant = .ghost,
        .size = .sm,
        .stacked = true,
        .leading_icon = if (i == 0) .power else .reboot,
        .label = if (i == 0) i18n.tr("Power") else i18n.tr("Restart"),
    }, .{ .focused = lock.focus == 3 + i });
    r.fillRect(w - 120 * s, h - 90 * s, s, 34 * s, .{ .color = ui.theme.global.lock_divider });
    return .{ .caret = field.caret, .factor = s };
}

/// Greeter: account arrows beside the picture, session chooser bottom-left.
pub fn paintChoices(r: *ui.paint.Renderer, lock: *const Lock, greeter: *const Greeter, geo: Geometry, h: f32) void {
    const fg = ui.theme.global.lock_fg;
    const muted = ui.theme.global.lock_dim;
    const s = geo.s;
    const cx = geo.w / 2;
    const ay = geo.top + 214 * s;
    const idle = greeter.phase == .idle;
    if (greeter.users.len > 1) {
        if (lock.focus == focus_account) r.fillRect(cx - 150 * s, ay - 6 * s, 300 * s, 205 * s, .{ .color = .{ 0, 0, 0, 0 }, .radius = 14 * s, .border_width = s, .border_color = fg });
        if (idle) {
            var zoomed = r.zoomed(s);
            zoomed.palette = ui.theme.shellPalette();
            for ([_]f32{ -1, 1 }) |side| ui.widgets.button.paint(&zoomed, .{ .x = cx / s + side * 110 - 22, .y = ay / s + 30, .w = 44, .h = 60 }, .{
                .variant = .ghost,
                .icon = if (side < 0) .chevron_left else .chevron_right,
                .icon_scale = 0.7,
                .label = if (side < 0) i18n.tr("Previous account") else i18n.tr("Next account"),
            }, .{});
        }
    }
    const session = greeter.selectedSession() orelse return;
    const color = if (lock.focus == focus_session) fg else muted;
    const x = 30 * s;
    const name_w = @min(280 * s, (text.measureWidthF(session.name, .manrope, 16 * s, r.scale) catch 280 * s) + 1);
    r.drawText(x, h - 90 * s, name_w, 30 * s, .{ .content = session.name, .font_size = 16 * s, .color = if (lock.focus == focus_session) fg else ui.theme.global.lock_session_fg });
    const caption = if (greeter.sessions.len > 1) i18n.tr("Session  ›") else i18n.tr("Session");
    const caption_w = (text.measureWidthF(caption, .manrope, 13 * s, r.scale) catch 90 * s) + 1;
    r.drawText(x, h - 54 * s, caption_w, 24 * s, .{ .content = caption, .font_size = 13 * s, .color = color });
    if (lock.focus == focus_session) r.fillRect(x - 12 * s, h - 96 * s, @max(name_w, caption_w) + 24 * s, 76 * s, .{ .color = .{ 0, 0, 0, 0 }, .radius = 10 * s, .border_width = s, .border_color = fg });
}

test {
    _ = @import("lock_tests.zig");
}
