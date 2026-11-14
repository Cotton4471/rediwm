//! Toplevel tab strip.

const std = @import("std");
const Toplevel = @import("../Toplevel.zig");
const geometry = @import("../geometry.zig");
const nowMs = Toplevel.nowMs;

/// `storage` may be null for a window outside any tab group, which has no tabs.
pub fn tabStrip(toplevel: *Toplevel, storage: ?*[@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab) @import("../chrome_tabs.zig").Strip {
    var strip: @import("../chrome_tabs.zig").Strip = .{ .first = toplevel.tab_first, .hover = toplevel.tab_hover, .notice = toplevel.tab_notice };
    const selected = if (storage) |tabs| fillTabs(toplevel, tabs, &strip) else 0;
    const geom = @import("../chrome_tabs.zig").geometry(toplevel.chrome_width, toplevel.chromeDensity(), strip);
    if (selected < strip.first) strip.first = selected;
    if (selected >= strip.first + geom.count) strip.first = selected + 1 -| geom.count;
    toplevel.tab_first = strip.first;
    return strip;
}

/// The group's tabs into `storage`; returns the index of `toplevel`'s own tab.
fn fillTabs(toplevel: *Toplevel, storage: *[@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab, strip: *@import("../chrome_tabs.zig").Strip) usize {
    var members_storage: [@import("../window_tabs.zig").max_tabs]*Toplevel = undefined;
    const members = @import("../window_tabs.zig").members(toplevel, &members_storage);
    var selected: usize = 0;
    for (members, 0..) |member, i| {
        storage[i] = .{ .id = member.id, .title = member.title(), .active = member == toplevel, .attention = member.needs_attention };
        if (member == toplevel) selected = i;
    }
    strip.tabs = storage[0..members.len];
    return selected;
}

pub fn tabAt(toplevel: *Toplevel, x: f64, y: f64) @import("../chrome_tabs.zig").Hit {
    if (!toplevel.hasServerDecorations() or toplevel.tab_group == 0) return .none;
    var storage: [@import("../window_tabs.zig").max_tabs]@import("../chrome_tabs.zig").Tab = undefined;
    return @import("../chrome_tabs.zig").hit(toplevel.chrome_width - toplevel.controlInsets().right, toplevel.chromeDensity(), toplevel.tabStrip(&storage), x, y);
}

pub fn hoverTab(toplevel: *Toplevel, x: f64, y: f64) void {
    const next = @import("../chrome_tabs.zig").key(toplevel.tabAt(x, y));
    if (next == toplevel.tab_hover) return;
    toplevel.tab_hover = next;
    toplevel.syncChrome(false, nowMs()) catch {};
}

pub fn stepTab(toplevel: *Toplevel, forward: bool) void {
    var storage: [@import("../window_tabs.zig").max_tabs]*Toplevel = undefined;
    const members = @import("../window_tabs.zig").members(toplevel, &storage);
    if (members.len < 2) return;
    for (members, 0..) |member, i| {
        if (member != toplevel) continue;
        const next = if (forward) (i + 1) % members.len else (i + members.len - 1) % members.len;
        toplevel.server.world.focus(members[next]);
        return;
    }
}
