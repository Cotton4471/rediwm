//! The compositor owns its scene tree; the remaining carrier pointers
//! need the C layout only, with no Zig methods or copied fields.
const c = @import("c.zig").c;
pub const Scene = c.wlr_scene;
pub const SceneNode = c.wlr_scene_node;
