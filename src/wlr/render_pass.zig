//! Drawing options are caller-owned values: check every field and the full
//! layout against wlroots before passing them to the output/capture passes.
const wl = @import("wayland").server.wl;
const pixman = @import("pixman");
const wlr = @import("wlr.zig");
const c = @import("c.zig").c;
const assertSameLayout = @import("signal.zig").assertSameLayout;
const assertFieldOffset = @import("signal.zig").assertFieldOffset;

pub const RenderPass = opaque {
    pub const BlendMode = enum(c_int) {
        premultiplied = c.WLR_RENDER_BLEND_MODE_PREMULTIPLIED,
        none = c.WLR_RENDER_BLEND_MODE_NONE,
    };

    pub const ScaleFilterMode = enum(c_int) {
        bilinear = c.WLR_SCALE_FILTER_BILINEAR,
        nearest = c.WLR_SCALE_FILTER_NEAREST,
    };

    pub const Color = c.wlr_render_color;

    pub const TextureOptions = extern struct {
        texture: *wlr.Texture,
        src_box: wlr.FBox,
        dst_box: wlr.Box,
        alpha: ?*const f32,
        clip: ?*const pixman.Region32,
        transform: wl.Output.Transform,
        filter_mode: ScaleFilterMode,
        blend_mode: BlendMode,
        transfer_function: wlr.color.TransferFunction,
        primaries: *const wlr.color.Primaries,
        color_encoding: wlr.color.Encoding,
        color_range: wlr.color.Range,
        luminance_multiplier: ?*const f32,
        wait_timeline: ?*wlr.DrmSyncobjTimeline = null,
        wait_point: u64,

        comptime {
            const Real = c.wlr_render_texture_options;
            assertSameLayout(TextureOptions, Real);
            for (@typeInfo(TextureOptions).@"struct".field_names) |field_name| {
                assertFieldOffset(TextureOptions, Real, field_name);
                assertSameLayout(@FieldType(TextureOptions, field_name), @FieldType(Real, field_name));
            }
        }
    };

    pub const RectOptions = extern struct {
        box: wlr.Box,
        color: Color,
        clip: ?*const pixman.Region32,
        blend_mode: BlendMode,

        comptime {
            const Real = c.wlr_render_rect_options;
            assertSameLayout(RectOptions, Real);
            for (@typeInfo(RectOptions).@"struct".field_names) |field_name| {
                assertFieldOffset(RectOptions, Real, field_name);
                assertSameLayout(@FieldType(RectOptions, field_name), @FieldType(Real, field_name));
            }
        }
    };

    pub fn submit(pass: *RenderPass) bool {
        return c.wlr_render_pass_submit(@ptrCast(pass));
    }

    pub fn addTexture(pass: *RenderPass, options: *const TextureOptions) void {
        c.wlr_render_pass_add_texture(@ptrCast(pass), @ptrCast(options));
    }

    pub fn addRect(pass: *RenderPass, options: *const RectOptions) void {
        c.wlr_render_pass_add_rect(@ptrCast(pass), @ptrCast(options));
    }
};
