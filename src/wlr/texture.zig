//! Textures remain owned by wlroots. Readback options use the facade's Box
//! and retain their complete C layout because callers allocate them in Zig.
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const Texture = extern struct {
    pub const ReadPixelsOptions = extern struct {
        data: *anyopaque,
        format: u32,
        stride: u32,
        dst_x: u32,
        dst_y: u32,
        src_box: wlr.Box,

        comptime {
            const Real = c.wlr_texture_read_pixels_options;
            assertSameLayout(ReadPixelsOptions, Real);
            for (@typeInfo(ReadPixelsOptions).@"struct".field_names) |field_name| {
                assertFieldOffset(ReadPixelsOptions, Real, field_name);
                assertSameLayout(@FieldType(ReadPixelsOptions, field_name), @FieldType(Real, field_name));
            }
        }
    };

    impl: *const c.wlr_texture_impl,
    width: u32,
    height: u32,
    renderer: *wlr.Renderer,

    pub fn fromBuffer(renderer: *wlr.Renderer, buffer: *wlr.Buffer) ?*Texture {
        return @ptrCast(c.wlr_texture_from_buffer(@ptrCast(renderer), @ptrCast(buffer)));
    }

    pub fn destroy(texture: *Texture) void {
        c.wlr_texture_destroy(@ptrCast(texture));
    }

    pub fn readPixels(texture: *Texture, options: *const ReadPixelsOptions) bool {
        return c.wlr_texture_read_pixels(@ptrCast(texture), @ptrCast(options));
    }

    pub fn preferredReadFormat(texture: *Texture) u32 {
        return c.wlr_texture_preferred_read_format(@ptrCast(texture));
    }

    comptime {
        const Real = c.wlr_texture;
        assertSameLayout(Texture, Real);
        for (@typeInfo(Texture).@"struct".field_names) |field_name| {
            assertFieldOffset(Texture, Real, field_name);
            assertSameLayout(@FieldType(Texture, field_name), @FieldType(Real, field_name));
        }
    }
};
