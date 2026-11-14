//! wlr.Box / wlr.FBox, backed by translate-c against wlr/util/box.h instead
//! of a hand-mirrored extern struct. The four fields are redeclared here
//! only so Zig's method-call sugar works on them (an alias to the
//! translate-c type directly can't carry extra pub fns); the comptime
//! asserts below keep that redeclaration honest against the real header.
const c = @import("c.zig").c;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;
const assertSameLayout = @import("signal.zig").assertSameLayout;

pub const Box = extern struct {
    x: c_int,
    y: c_int,
    width: c_int,
    height: c_int,

    pub fn closestPoint(box: *const Box, x: f64, y: f64, dest_x: *f64, dest_y: *f64) void {
        c.wlr_box_closest_point(@ptrCast(box), x, y, dest_x, dest_y);
    }

    pub fn intersection(dest: *Box, box_a: ?*const Box, box_b: ?*const Box) bool {
        return c.wlr_box_intersection(@ptrCast(dest), @ptrCast(box_a), @ptrCast(box_b));
    }

    pub fn containsPoint(box: ?*const Box, x: f64, y: f64) bool {
        return c.wlr_box_contains_point(@ptrCast(box), x, y);
    }

    pub fn containsBox(bigger: *const Box, smaller: *const Box) bool {
        return c.wlr_box_contains_box(@ptrCast(bigger), @ptrCast(smaller));
    }

    pub fn empty(box: ?*const Box) bool {
        return c.wlr_box_empty(@ptrCast(box));
    }

    pub fn transform(dest: *Box, box: ?*const Box, transform_: c.wl_output_transform, width: c_int, height: c_int) void {
        c.wlr_box_transform(@ptrCast(dest), @ptrCast(box), transform_, width, height);
    }

    pub fn equal(a: ?*const Box, b: ?*const Box) bool {
        return c.wlr_box_equal(@ptrCast(a), @ptrCast(b));
    }

    comptime {
        assertSameLayout(Box, c.wlr_box);
        assertFieldOffset(Box, c.wlr_box, "x");
        assertFieldOffset(Box, c.wlr_box, "y");
        assertFieldOffset(Box, c.wlr_box, "width");
        assertFieldOffset(Box, c.wlr_box, "height");
    }
};

pub const FBox = extern struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,

    pub fn empty(box: ?*const FBox) bool {
        return c.wlr_fbox_empty(@ptrCast(box));
    }

    pub fn transform(dest: *FBox, box: ?*const FBox, transform_: c.wl_output_transform, width: f64, height: f64) void {
        c.wlr_fbox_transform(@ptrCast(dest), @ptrCast(box), transform_, width, height);
    }

    pub fn equal(a: ?*const FBox, b: ?*const FBox) bool {
        return c.wlr_fbox_equal(@ptrCast(a), @ptrCast(b));
    }

    comptime {
        assertSameLayout(FBox, c.wlr_fbox);
        assertFieldOffset(FBox, c.wlr_fbox, "x");
        assertFieldOffset(FBox, c.wlr_fbox, "y");
        assertFieldOffset(FBox, c.wlr_fbox, "width");
        assertFieldOffset(FBox, c.wlr_fbox, "height");
    }
};
