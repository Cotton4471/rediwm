//! Native session state and VT switching. Backend.autocreate owns session
//! creation and teardown; the compositor only observes active changes and
//! requests VT switches. Never allocate this prefix: wlroots owns its private
//! event-loop listener after the public fields.
const wl = @import("wayland").server.wl;
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

// The session's intrusive list needs the link's real offset even though
// compositor code does not currently enumerate devices.
const Device = extern struct {
    fd: c_int,
    device_id: c_int,
    dev: c.dev_t,
    link: wl.list.Link,
    events: extern struct {
        change: wl.Signal(*c.wlr_device_change_event),
        remove: wl.Signal(void),
    },

    comptime {
        const Real = c.wlr_device;
        assertSameLayout(Device, Real);
        for (.{ "fd", "device_id", "dev", "link", "events" }) |field| {
            assertFieldOffset(Device, Real, field);
            assertSameLayout(@FieldType(Device, field), @FieldType(Real, field));
        }
        const Events = @FieldType(Device, "events");
        const RealEvents = @FieldType(Real, "events");
        for (.{ "change", "remove" }) |field| {
            assertSameLayout(@FieldType(Events, field), c.wl_signal);
            assertFieldOffset(Events, RealEvents, field);
        }
    }
};

pub const Session = extern struct {
    pub const event = struct {
        pub const Add = extern struct {
            path: [*:0]const u8,

            comptime {
                assertSameLayout(Add, c.wlr_session_add_event);
                assertFieldOffset(Add, c.wlr_session_add_event, "path");
            }
        };
    };

    active: bool,
    seat: [256]u8,
    udev: ?*c.udev,
    mon: ?*c.udev_monitor,
    udev_event: ?*wl.EventSource,
    seat_handle: ?*c.libseat,
    libseat_event: ?*wl.EventSource,
    devices: wl.list.Head(Device, .link),
    event_loop: *wl.EventLoop,
    events: extern struct {
        // Server.handleSessionActive reads Session.active and does not
        // consume a payload from this signal.
        active: wl.Signal(void),
        add_drm_card: wl.Signal(*event.Add),
        destroy: wl.Signal(*Session),
    },

    pub fn changeVt(session: *Session, vt: c_uint) !void {
        if (!c.wlr_session_change_vt(@ptrCast(session), vt)) return error.ChangeVtFailed;
    }

    comptime {
        const Real = c.wlr_session;
        for (.{ "active", "seat", "udev", "mon", "udev_event", "seat_handle", "libseat_event", "devices", "event_loop", "events" }) |field| {
            assertFieldOffset(Session, Real, field);
            assertSameLayout(@FieldType(Session, field), @FieldType(Real, field));
        }
        const Events = @FieldType(Session, "events");
        const RealEvents = @FieldType(Real, "events");
        for (.{ "active", "add_drm_card", "destroy" }) |field| {
            assertSameLayout(@FieldType(Events, field), c.wl_signal);
            assertFieldOffset(Events, RealEvents, field);
        }
    }
};
