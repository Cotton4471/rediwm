const wlr = @import("wlroots");
const Projection = @import("projection.zig").Projection;

pub const Renderer = opaque {
    extern fn rediwm_output_renderer_create(renderer: *wlr.Renderer) ?*Renderer;
    pub const create = rediwm_output_renderer_create;
    extern fn rediwm_output_renderer_destroy(renderer: ?*Renderer) void;
    pub const destroy = rediwm_output_renderer_destroy;
    extern fn rediwm_scene_output_build_state(renderer: *Renderer, projection: *Projection, output: *wlr.SceneOutput, state: *wlr.Output.State) bool;
    pub const buildState = rediwm_scene_output_build_state;
    extern fn rediwm_output_begin_pass(renderer: *Renderer, buffer: *wlr.Buffer, options: ?*const wlr.Renderer.BufferPassOptions) ?*wlr.RenderPass;
    pub const beginPass = rediwm_output_begin_pass;
};
extern fn rediwm_scene_output_damage_whole(output: *wlr.SceneOutput) void;
pub const damageWhole = rediwm_scene_output_damage_whole;
