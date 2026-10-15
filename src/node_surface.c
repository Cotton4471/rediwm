// Client surfaces in the own scene: see node_surface.h. The logic is wlroots' own
// (types/scene/surface.c, subsurface_tree.c, xdg_shell.c, drag_icon.c, wlroots 0.20, MIT
// licensed), moved onto own nodes. wlroots 0.20 ABI, pinned by build.zig.zon (as in
// projection.c).
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "node_surface.h"
#include <assert.h>
#include <math.h>
#include <stdlib.h>
#include <wlr/types/wlr_alpha_modifier_v1.h>
#include <wlr/types/wlr_color_management_v1.h>
#include <wlr/types/wlr_color_representation_v1.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_linux_drm_syncobj_v1.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/util/transform.h>

// ---- The surface -----------------------------------------------------------------

static double get_surface_preferred_buffer_scale(struct wlr_surface *surface) {
  double scale = 1;
  struct wlr_surface_output *surface_output;
  wl_list_for_each(surface_output, &surface->current_outputs, link) {
    if (surface_output->output->scale > scale) scale = surface_output->output->scale;
  }
  return scale;
}

// Output used for frame pacing (surface frame callbacks, presentation time feedback,
// etc), may be NULL.
static struct wlr_output *get_surface_frame_pacing_output(struct wlr_surface *surface) {
  struct wlr_output *frame_pacing_output = NULL;
  struct wlr_surface_output *surface_output;
  wl_list_for_each(surface_output, &surface->current_outputs, link) {
    if (!surface_output->private.suspended &&
        (frame_pacing_output == NULL || surface_output->output->refresh > frame_pacing_output->refresh))
      frame_pacing_output = surface_output->output;
  }
  return frame_pacing_output;
}

static int get_tf_preference(enum wlr_color_transfer_function tf) {
  switch (tf) {
  case WLR_COLOR_TRANSFER_FUNCTION_GAMMA22:
    return 0;
  case WLR_COLOR_TRANSFER_FUNCTION_ST2084_PQ:
    return 1;
  case WLR_COLOR_TRANSFER_FUNCTION_BT1886:
  case WLR_COLOR_TRANSFER_FUNCTION_SRGB:
  case WLR_COLOR_TRANSFER_FUNCTION_EXT_LINEAR:
    return -1;
  }
  abort(); // unreachable
}

static int get_primaries_preference(enum wlr_color_named_primaries primaries) {
  switch (primaries) {
  case WLR_COLOR_NAMED_PRIMARIES_SRGB:
    return 0;
  case WLR_COLOR_NAMED_PRIMARIES_BT2020:
    return 1;
  }
  abort(); // unreachable
}

static void get_surface_preferred_image_description(struct wlr_surface *surface,
                                                    struct wlr_image_description_v1_data *out) {
  struct wlr_output_image_description preferred = {
      .transfer_function = WLR_COLOR_TRANSFER_FUNCTION_GAMMA22,
      .primaries = WLR_COLOR_NAMED_PRIMARIES_SRGB,
  };

  struct wlr_surface_output *surface_output;
  wl_list_for_each(surface_output, &surface->current_outputs, link) {
    const struct wlr_output_image_description *img_desc = surface_output->output->image_description;
    if (img_desc == NULL) continue;
    if (get_tf_preference(preferred.transfer_function) < get_tf_preference(img_desc->transfer_function))
      preferred.transfer_function = img_desc->transfer_function;
    if (get_primaries_preference(preferred.primaries) < get_primaries_preference(img_desc->primaries))
      preferred.primaries = img_desc->primaries;
  }

  *out = (struct wlr_image_description_v1_data){
      .tf_named = wlr_color_manager_v1_transfer_function_from_wlr(preferred.transfer_function),
      .primaries_named = wlr_color_manager_v1_primaries_from_wlr(preferred.primaries),
  };
}

// The wlr_scene whose host holds the node's carrier: it knows the outputs and the colour
// manager (stage 7c replaces both with plain pointers).
static struct wlr_scene *carrier_scene(struct wlr_scene_buffer *carrier) {
  struct wlr_scene_tree *tree = carrier->node.parent;
  while (tree->node.parent) tree = tree->node.parent;
  return wl_container_of(tree, (struct wlr_scene *)NULL, tree);
}

static void handle_scene_buffer_outputs_update(struct wl_listener *listener, void *data) {
  struct rediwm_surface *surface = wl_container_of(listener, surface, outputs_update);
  struct wlr_scene_outputs_update_event *event = data;
  struct wlr_scene *scene = carrier_scene(surface->buffer->carrier);

  // If the surface is no longer visible on any output in the scene, keep the last sent
  // preferred configuration to avoid unnecessary redraws.
  bool suspend = event->size == 0;

  // To avoid sending redundant leave/enter events when a surface is hidden and then
  // shown without moving to a different output the following policy is implemented:
  //
  // 1. When a surface transitions from being visible on >0 outputs to being visible on 0
  //    outputs don't send any leave events.
  //
  // 2. When a surface transitions from being visible on 0 outputs to being visible on >0
  //    outputs send leave events for all entered outputs on which the surface is no
  //    longer visible as well as enter events for any outputs not already entered.
  struct wlr_surface_output *entered_output, *tmp;
  wl_list_for_each_safe(entered_output, tmp, &surface->surface->current_outputs, link) {
    bool active = false;
    for (size_t i = 0; i < event->size; i++) {
      if (entered_output->output == event->active[i]->output) {
        active = true;
        break;
      }
    }

    struct wlr_scene_output *scene_output;
    wl_list_for_each(scene_output, &scene->outputs, link) {
      if (scene_output->output == entered_output->output) {
        entered_output->private.suspended = suspend;
        if (!suspend && !active) wlr_surface_send_leave(surface->surface, entered_output->output);
        break;
      }
    }
  }

  // No reason to update the preferred configuration if we aren't sending leave/enter
  // events.
  if (suspend) return;

  for (size_t i = 0; i < event->size; i++) {
    // This function internally checks if an enter event was already sent for the output
    // to avoid sending redundant events.
    wlr_surface_send_enter(surface->surface, event->active[i]->output);
  }

  double scale = get_surface_preferred_buffer_scale(surface->surface);
  wlr_fractional_scale_v1_notify_scale(surface->surface, scale);
  wlr_surface_set_preferred_buffer_scale(surface->surface, ceil(scale));

  if (scene->color_manager_v1 != NULL) {
    struct wlr_image_description_v1_data img_desc = {0};
    get_surface_preferred_image_description(surface->surface, &img_desc);
    wlr_color_manager_v1_set_surface_preferred_image_description(scene->color_manager_v1,
                                                                 surface->surface, &img_desc);
  }
}

static void handle_scene_buffer_output_sample(struct wl_listener *listener, void *data) {
  struct rediwm_surface *surface = wl_container_of(listener, surface, output_sample);
  const struct wlr_scene_output_sample_event *event = data;
  struct wlr_output *output = event->output->output;
  if (get_surface_frame_pacing_output(surface->surface) != output) return;

  if (event->direct_scanout)
    wlr_presentation_surface_scanned_out_on_output(surface->surface, output);
  else
    wlr_presentation_surface_textured_on_output(surface->surface, output);

  struct wlr_linux_drm_syncobj_surface_v1_state *syncobj_surface_state =
      wlr_linux_drm_syncobj_v1_get_surface_state(surface->surface);
  if (syncobj_surface_state != NULL && event->release_timeline != NULL) {
    wlr_linux_drm_syncobj_v1_state_add_release_point(syncobj_surface_state, event->release_timeline,
                                                     event->release_point, output->event_loop);
  }
}

static void handle_scene_buffer_frame_done(struct wl_listener *listener, void *data) {
  struct rediwm_surface *surface = wl_container_of(listener, surface, frame_done);
  struct wlr_scene_frame_done_event *event = data;
  if (get_surface_frame_pacing_output(surface->surface) != event->output->output) return;

  wlr_surface_send_frame_done(surface->surface, &event->when);
}

static void scene_surface_handle_surface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_surface *surface = wl_container_of(listener, surface, surface_destroy);
  rediwm_node_destroy(&surface->buffer->node);
}

// This is used for wlr_scene where it unconditionally locks buffers preventing reuse of
// the existing texture for shm clients. With the usage pattern of surface handling, we
// can mark its locked buffer as safe for mutation.
static void client_buffer_mark_next_can_damage(struct wlr_client_buffer *buffer) {
  buffer->private.n_ignore_locks++;
}

static void carrier_unmark_client_buffer(struct wlr_scene_buffer *scene_buffer) {
  if (!scene_buffer->buffer) return;

  struct wlr_client_buffer *buffer = wlr_client_buffer_get(scene_buffer->buffer);
  if (!buffer) return;

  // If the buffer was a single-pixel buffer where we cached its color then it won't have
  // been marked as damage-allowed.
  if (buffer->private.n_ignore_locks > 0) buffer->private.n_ignore_locks--;
}

static int min(int a, int b) { return a < b ? a : b; }

static void surface_reconfigure(struct rediwm_surface *scene_surface) {
  struct rediwm_buffer *scene_buffer = scene_surface->buffer;
  struct wlr_scene_buffer *carrier = scene_buffer->carrier;
  struct wlr_surface *surface = scene_surface->surface;
  struct wlr_surface_state *state = &surface->current;

  struct wlr_fbox src_box;
  wlr_surface_get_buffer_source_box(surface, &src_box);

  pixman_region32_t opaque;
  pixman_region32_init(&opaque);
  pixman_region32_copy(&opaque, &surface->opaque_region);

  int width = state->width;
  int height = state->height;

  if (!wlr_box_empty(&scene_surface->clip)) {
    struct wlr_box *clip = &scene_surface->clip;

    int buffer_width = state->buffer_width;
    int buffer_height = state->buffer_height;
    width = min(clip->width, width - clip->x);
    height = min(clip->height, height - clip->y);

    wlr_fbox_transform(&src_box, &src_box, state->transform, buffer_width, buffer_height);
    wlr_output_transform_coords(state->transform, &buffer_width, &buffer_height);

    src_box.x += (double)(clip->x * src_box.width) / state->width;
    src_box.y += (double)(clip->y * src_box.height) / state->height;
    src_box.width *= (double)width / state->width;
    src_box.height *= (double)height / state->height;

    wlr_fbox_transform(&src_box, &src_box, wlr_output_transform_invert(state->transform),
                       buffer_width, buffer_height);

    pixman_region32_translate(&opaque, -clip->x, -clip->y);
    pixman_region32_intersect_rect(&opaque, &opaque, 0, 0, width, height);
  }

  if (width <= 0 || height <= 0) {
    rediwm_buffer_set_buffer(scene_buffer, NULL);
    pixman_region32_fini(&opaque);
    return;
  }

  float opacity = 1.0;
  const struct wlr_alpha_modifier_surface_v1_state *alpha_modifier_state =
      wlr_alpha_modifier_v1_get_surface_state(surface);
  if (alpha_modifier_state != NULL) opacity = (float)alpha_modifier_state->multiplier;

  enum wlr_color_transfer_function tf = WLR_COLOR_TRANSFER_FUNCTION_GAMMA22;
  enum wlr_color_named_primaries primaries = WLR_COLOR_NAMED_PRIMARIES_SRGB;
  const struct wlr_image_description_v1_data *img_desc =
      wlr_surface_get_image_description_v1_data(surface);
  if (img_desc != NULL) {
    tf = wlr_color_manager_v1_transfer_function_to_wlr(img_desc->tf_named);
    primaries = wlr_color_manager_v1_primaries_to_wlr(img_desc->primaries_named);
  }

  enum wlr_color_encoding color_encoding = WLR_COLOR_ENCODING_NONE;
  enum wlr_color_range color_range = WLR_COLOR_RANGE_NONE;
  const struct wlr_color_representation_v1_surface_state *color_repr =
      wlr_color_representation_v1_get_surface_state(surface);
  if (color_repr != NULL) {
    if (color_repr->coefficients != 0)
      color_encoding = wlr_color_representation_v1_color_encoding_to_wlr(color_repr->coefficients);
    if (color_repr->range != 0)
      color_range = wlr_color_representation_v1_color_range_to_wlr(color_repr->range);
  }

  rediwm_buffer_set_opaque_region(scene_buffer, &opaque);
  rediwm_buffer_set_source_box(scene_buffer, &src_box);
  rediwm_buffer_set_dest_size(scene_buffer, width, height);
  rediwm_buffer_set_transform(scene_buffer, state->transform);
  rediwm_buffer_set_opacity(scene_buffer, opacity);
  // The colour description is the carrier's alone: the buffer set below reports it.
  wlr_scene_buffer_set_transfer_function(carrier, tf);
  wlr_scene_buffer_set_primaries(carrier, primaries);
  wlr_scene_buffer_set_color_encoding(carrier, color_encoding);
  wlr_scene_buffer_set_color_range(carrier, color_range);

  carrier_unmark_client_buffer(carrier);

  if (surface->buffer) {
    // If we've cached the buffer's single-pixel buffer color then any in-place updates
    // to the texture wouldn't be reflected in rendering. So only allow in-place texture
    // updates if it's not a single pixel buffer. Note that we can't use the cached
    // scene_buffer->is_single_pixel_buffer because that's only set later on.
    bool is_single_pixel_buffer = false;
    if (surface->buffer->source != NULL) {
      struct wlr_single_pixel_buffer_v1 *spb =
          wlr_single_pixel_buffer_v1_try_from_buffer(surface->buffer->source);
      is_single_pixel_buffer = spb != NULL;
    }
    if (!is_single_pixel_buffer) client_buffer_mark_next_can_damage(surface->buffer);

    struct wlr_linux_drm_syncobj_surface_v1_state *syncobj_surface_state =
        wlr_linux_drm_syncobj_v1_get_surface_state(surface);

    struct wlr_scene_buffer_set_buffer_options options = {
        .damage = &surface->buffer_damage,
    };
    if (syncobj_surface_state != NULL) {
      options.wait_timeline = syncobj_surface_state->acquire_timeline;
      options.wait_point = syncobj_surface_state->acquire_point;
    }
    rediwm_buffer_set_buffer_with_options(scene_buffer, &surface->buffer->base, &options);
  } else {
    rediwm_buffer_set_buffer(scene_buffer, NULL);
  }

  pixman_region32_fini(&opaque);
}

static void handle_scene_surface_surface_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_surface *surface = wl_container_of(listener, surface, surface_commit);

  surface_reconfigure(surface);

  // If the surface has requested a frame done event, honour that. The frame_callback_list
  // will be populated in this case. We should only schedule the frame however if the node
  // is enabled and there is an output intersecting, otherwise the frame done events would
  // never reach the surface anyway.
  bool enabled = rediwm_node_coords(&surface->buffer->node, NULL, NULL);
  struct wlr_output *output = get_surface_frame_pacing_output(surface->surface);
  if (!wl_list_empty(&surface->surface->current.frame_callback_list) && output && enabled)
    wlr_output_schedule_frame(output);
}

static bool scene_buffer_point_accepts_input(struct rediwm_buffer *buffer, double *sx, double *sy) {
  struct rediwm_surface *scene_surface = buffer->surface;

  *sx += scene_surface->clip.x;
  *sy += scene_surface->clip.y;

  return wlr_surface_point_accepts_input(scene_surface->surface, *sx, *sy);
}

static void surface_node_destroyed(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_surface *surface = wl_container_of(listener, surface, node_destroy);

  carrier_unmark_client_buffer(surface->buffer->carrier);
  surface->buffer->surface = NULL;
  surface->buffer->point_accepts_input = NULL;

  wl_list_remove(&surface->node_destroy.link);
  wl_list_remove(&surface->outputs_update.link);
  wl_list_remove(&surface->output_sample.link);
  wl_list_remove(&surface->frame_done.link);
  wl_list_remove(&surface->surface_destroy.link);
  wl_list_remove(&surface->surface_commit.link);

  free(surface);
}

struct rediwm_surface *rediwm_surface_create(struct rediwm_tree *parent, struct wlr_surface *wlr_surface) {
  struct rediwm_surface *surface = calloc(1, sizeof(*surface));
  if (surface == NULL) return NULL;

  struct rediwm_buffer *scene_buffer = rediwm_buffer_create(parent, NULL);
  if (!scene_buffer) {
    free(surface);
    return NULL;
  }

  surface->buffer = scene_buffer;
  surface->surface = wlr_surface;
  scene_buffer->surface = surface;
  scene_buffer->point_accepts_input = scene_buffer_point_accepts_input;
  struct wlr_scene_buffer *carrier = scene_buffer->carrier;

  surface->node_destroy.notify = surface_node_destroyed;
  wl_signal_add(&scene_buffer->node.events.destroy, &surface->node_destroy);

  surface->outputs_update.notify = handle_scene_buffer_outputs_update;
  wl_signal_add(&carrier->events.outputs_update, &surface->outputs_update);

  surface->output_sample.notify = handle_scene_buffer_output_sample;
  wl_signal_add(&carrier->events.output_sample, &surface->output_sample);

  surface->frame_done.notify = handle_scene_buffer_frame_done;
  wl_signal_add(&carrier->events.frame_done, &surface->frame_done);

  surface->surface_destroy.notify = scene_surface_handle_surface_destroy;
  wl_signal_add(&wlr_surface->events.destroy, &surface->surface_destroy);

  surface->surface_commit.notify = handle_scene_surface_surface_commit;
  wl_signal_add(&wlr_surface->events.commit, &surface->surface_commit);

  surface_reconfigure(surface);

  return surface;
}

static void scene_surface_set_clip(struct rediwm_surface *surface, const struct wlr_box *clip) {
  if (clip ? wlr_box_equal(clip, &surface->clip) : wlr_box_empty(&surface->clip)) return;

  if (clip)
    surface->clip = *clip;
  else
    surface->clip = (struct wlr_box){0};

  surface_reconfigure(surface);
}

// ---- The surface and its subsurfaces -----------------------------------------------

// A tree for a surface and all of its child sub-surfaces. `tree` contains `scene_surface`
// and one node per sub-surface.
struct rediwm_subsurface_tree {
  struct rediwm_tree *tree;
  struct wlr_surface *surface;
  struct rediwm_surface *scene_surface;

  struct wl_listener surface_destroy;
  struct wl_listener surface_commit;
  struct wl_listener surface_map;
  struct wl_listener surface_unmap;
  struct wl_listener surface_new_subsurface;

  struct rediwm_subsurface_tree *parent; // NULL for the top-level surface

  struct wlr_addon scene_addon;

  struct wlr_box clip;

  // Only valid if the surface is a sub-surface

  struct wlr_addon surface_addon;

  struct wl_listener subsurface_destroy;
};

static void subsurface_tree_addon_destroy(struct wlr_addon *addon) {
  struct rediwm_subsurface_tree *subsurface_tree = wl_container_of(addon, subsurface_tree, scene_addon);
  // tree and scene_surface are cleaned up with the node
  if (subsurface_tree->parent) {
    wlr_addon_finish(&subsurface_tree->surface_addon);
    wl_list_remove(&subsurface_tree->subsurface_destroy.link);
  }
  wlr_addon_finish(&subsurface_tree->scene_addon);
  wl_list_remove(&subsurface_tree->surface_destroy.link);
  wl_list_remove(&subsurface_tree->surface_commit.link);
  wl_list_remove(&subsurface_tree->surface_map.link);
  wl_list_remove(&subsurface_tree->surface_unmap.link);
  wl_list_remove(&subsurface_tree->surface_new_subsurface.link);
  free(subsurface_tree);
}

static const struct wlr_addon_interface subsurface_tree_surface_addon_impl;

static struct rediwm_subsurface_tree *subsurface_tree_from_subsurface(
    struct rediwm_subsurface_tree *parent, struct wlr_subsurface *subsurface) {
  struct wlr_addon *addon =
      wlr_addon_find(&subsurface->surface->addons, parent, &subsurface_tree_surface_addon_impl);
  assert(addon != NULL);
  struct rediwm_subsurface_tree *subsurface_tree = wl_container_of(addon, subsurface_tree, surface_addon);
  return subsurface_tree;
}

static bool subsurface_tree_reconfigure_clip(struct rediwm_subsurface_tree *subsurface_tree) {
  struct rediwm_node *surface_node = &subsurface_tree->scene_surface->buffer->node;
  if (subsurface_tree->parent) {
    subsurface_tree->clip = (struct wlr_box){
        .x = subsurface_tree->parent->clip.x - subsurface_tree->tree->node.x,
        .y = subsurface_tree->parent->clip.y - subsurface_tree->tree->node.y,
        .width = subsurface_tree->parent->clip.width,
        .height = subsurface_tree->parent->clip.height,
    };
  }

  if (wlr_box_empty(&subsurface_tree->clip)) {
    scene_surface_set_clip(subsurface_tree->scene_surface, NULL);
    rediwm_node_set_enabled(surface_node, true);
    rediwm_node_set_position(surface_node, 0, 0);

    return false;
  } else {
    struct wlr_box clip = subsurface_tree->clip;
    struct wlr_box surface_box = {
        .width = subsurface_tree->surface->current.width,
        .height = subsurface_tree->surface->current.height,
    };

    bool intersects = wlr_box_intersection(&clip, &clip, &surface_box);
    rediwm_node_set_enabled(surface_node, intersects);

    if (intersects) {
      rediwm_node_set_position(surface_node, clip.x, clip.y);
      scene_surface_set_clip(subsurface_tree->scene_surface, &clip);
    }

    return true;
  }
}

static void subsurface_tree_reconfigure(struct rediwm_subsurface_tree *subsurface_tree) {
  bool has_clip = subsurface_tree_reconfigure_clip(subsurface_tree);

  struct wlr_surface *surface = subsurface_tree->surface;

  struct rediwm_node *prev = NULL;
  struct wlr_subsurface *subsurface;
  wl_list_for_each(subsurface, &surface->current.subsurfaces_below, current.link) {
    struct rediwm_subsurface_tree *child = subsurface_tree_from_subsurface(subsurface_tree, subsurface);
    if (prev != NULL) rediwm_node_place_above(&child->tree->node, prev);
    prev = &child->tree->node;

    rediwm_node_set_position(&child->tree->node, subsurface->current.x, subsurface->current.y);

    if (has_clip) subsurface_tree_reconfigure_clip(child);
  }

  if (prev != NULL) rediwm_node_place_above(&subsurface_tree->scene_surface->buffer->node, prev);
  prev = &subsurface_tree->scene_surface->buffer->node;

  wl_list_for_each(subsurface, &surface->current.subsurfaces_above, current.link) {
    struct rediwm_subsurface_tree *child = subsurface_tree_from_subsurface(subsurface_tree, subsurface);
    rediwm_node_place_above(&child->tree->node, prev);
    prev = &child->tree->node;

    rediwm_node_set_position(&child->tree->node, subsurface->current.x, subsurface->current.y);

    if (has_clip) subsurface_tree_reconfigure_clip(child);
  }
}

static void subsurface_tree_handle_surface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_destroy);
  rediwm_node_destroy(&subsurface_tree->tree->node);
}

static void subsurface_tree_handle_surface_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_commit);

  // TODO: only do this on subsurface order or position change
  subsurface_tree_reconfigure(subsurface_tree);
}

static void subsurface_tree_handle_subsurface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, subsurface_destroy);
  rediwm_node_destroy(&subsurface_tree->tree->node);
}

static void subsurface_tree_handle_surface_map(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_map);

  rediwm_node_set_enabled(&subsurface_tree->tree->node, true);
}

static void subsurface_tree_handle_surface_unmap(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_unmap);

  rediwm_node_set_enabled(&subsurface_tree->tree->node, false);
}

static void subsurface_tree_surface_addon_destroy(struct wlr_addon *addon) {
  struct rediwm_subsurface_tree *subsurface_tree = wl_container_of(addon, subsurface_tree, surface_addon);
  rediwm_node_destroy(&subsurface_tree->tree->node);
}

static const struct wlr_addon_interface subsurface_tree_surface_addon_impl = {
    .name = "rediwm_subsurface_tree",
    .destroy = subsurface_tree_surface_addon_destroy,
};

static struct rediwm_subsurface_tree *scene_surface_tree_create(struct rediwm_tree *parent,
                                                                 struct wlr_surface *surface);

static bool subsurface_tree_create_subsurface(struct rediwm_subsurface_tree *parent,
                                              struct wlr_subsurface *subsurface) {
  struct rediwm_subsurface_tree *child = scene_surface_tree_create(parent->tree, subsurface->surface);
  if (child == NULL) return false;

  child->parent = parent;

  wlr_addon_init(&child->surface_addon, &subsurface->surface->addons, parent,
                 &subsurface_tree_surface_addon_impl);

  child->subsurface_destroy.notify = subsurface_tree_handle_subsurface_destroy;
  wl_signal_add(&subsurface->events.destroy, &child->subsurface_destroy);

  return true;
}

static void subsurface_tree_handle_surface_new_subsurface(struct wl_listener *listener, void *data) {
  struct rediwm_subsurface_tree *subsurface_tree =
      wl_container_of(listener, subsurface_tree, surface_new_subsurface);
  struct wlr_subsurface *subsurface = data;
  if (!subsurface_tree_create_subsurface(subsurface_tree, subsurface))
    wl_resource_post_no_memory(subsurface->resource);
}

static const struct wlr_addon_interface subsurface_tree_addon_impl = {
    .name = "rediwm_subsurface_tree",
    .destroy = subsurface_tree_addon_destroy,
};

static struct rediwm_subsurface_tree *scene_surface_tree_create(struct rediwm_tree *parent,
                                                                 struct wlr_surface *surface) {
  struct rediwm_subsurface_tree *subsurface_tree = calloc(1, sizeof(*subsurface_tree));
  if (subsurface_tree == NULL) return NULL;

  subsurface_tree->tree = rediwm_tree_create(parent);
  if (subsurface_tree->tree == NULL) goto error_surface_tree;

  subsurface_tree->scene_surface = rediwm_surface_create(subsurface_tree->tree, surface);
  if (subsurface_tree->scene_surface == NULL) goto error_scene_surface;

  subsurface_tree->surface = surface;

  struct wlr_subsurface *subsurface;
  wl_list_for_each(subsurface, &surface->current.subsurfaces_below, current.link) {
    if (!subsurface_tree_create_subsurface(subsurface_tree, subsurface)) goto error_scene_surface;
  }
  wl_list_for_each(subsurface, &surface->current.subsurfaces_above, current.link) {
    if (!subsurface_tree_create_subsurface(subsurface_tree, subsurface)) goto error_scene_surface;
  }

  subsurface_tree_reconfigure(subsurface_tree);

  wlr_addon_init(&subsurface_tree->scene_addon, &subsurface_tree->tree->node.addons, NULL,
                 &subsurface_tree_addon_impl);

  subsurface_tree->surface_destroy.notify = subsurface_tree_handle_surface_destroy;
  wl_signal_add(&surface->events.destroy, &subsurface_tree->surface_destroy);

  subsurface_tree->surface_commit.notify = subsurface_tree_handle_surface_commit;
  wl_signal_add(&surface->events.commit, &subsurface_tree->surface_commit);

  subsurface_tree->surface_map.notify = subsurface_tree_handle_surface_map;
  wl_signal_add(&surface->events.map, &subsurface_tree->surface_map);

  subsurface_tree->surface_unmap.notify = subsurface_tree_handle_surface_unmap;
  wl_signal_add(&surface->events.unmap, &subsurface_tree->surface_unmap);

  subsurface_tree->surface_new_subsurface.notify = subsurface_tree_handle_surface_new_subsurface;
  wl_signal_add(&surface->events.new_subsurface, &subsurface_tree->surface_new_subsurface);

  rediwm_node_set_enabled(&subsurface_tree->tree->node, surface->mapped);

  return subsurface_tree;

error_scene_surface:
  rediwm_node_destroy(&subsurface_tree->tree->node);
error_surface_tree:
  free(subsurface_tree);
  return NULL;
}

struct rediwm_tree *rediwm_subsurface_tree_create(struct rediwm_tree *parent, struct wlr_surface *surface) {
  struct rediwm_subsurface_tree *subsurface_tree = scene_surface_tree_create(parent, surface);
  if (subsurface_tree == NULL) return NULL;
  return subsurface_tree->tree;
}

static struct rediwm_subsurface_tree *get_subsurface_tree_from_node(struct rediwm_node *node) {
  struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &subsurface_tree_addon_impl);
  if (!addon) return NULL;

  struct rediwm_subsurface_tree *tree = wl_container_of(addon, tree, scene_addon);
  return tree;
}

static bool subsurface_tree_set_clip(struct rediwm_node *node, const struct wlr_box *clip) {
  if (node->type != REDIWM_NODE_TREE) return false;

  bool discovered_subsurface_tree = false;
  struct rediwm_subsurface_tree *tree = get_subsurface_tree_from_node(node);
  if (tree) {
    if (tree->parent == NULL) {
      if (clip ? wlr_box_equal(&tree->clip, clip) : wlr_box_empty(&tree->clip)) return true;

      if (clip)
        tree->clip = *clip;
      else
        tree->clip = (struct wlr_box){0};
    }

    discovered_subsurface_tree = true;
    subsurface_tree_reconfigure_clip(tree);
  }

  struct rediwm_tree *scene_tree = (struct rediwm_tree *)node;
  struct rediwm_node *child;
  wl_list_for_each(child, &scene_tree->children, link) {
    discovered_subsurface_tree |= subsurface_tree_set_clip(child, clip);
  }

  return discovered_subsurface_tree;
}

bool rediwm_subsurface_tree_set_clip(struct rediwm_node *node, const struct wlr_box *clip) {
  return subsurface_tree_set_clip(node, clip);
}

// ---- xdg surfaces and drag icons -----------------------------------------

struct rediwm_xdg_surface {
  struct rediwm_tree *tree;
  struct wlr_xdg_surface *xdg_surface;
  struct rediwm_tree *surface_tree;

  struct wl_listener tree_destroy;
  struct wl_listener xdg_surface_destroy;
  struct wl_listener xdg_surface_commit;
};

static void scene_xdg_surface_handle_tree_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_xdg_surface *scene_xdg_surface = wl_container_of(listener, scene_xdg_surface, tree_destroy);
  // tree and surface_node are cleaned up with the node
  wl_list_remove(&scene_xdg_surface->tree_destroy.link);
  wl_list_remove(&scene_xdg_surface->xdg_surface_destroy.link);
  wl_list_remove(&scene_xdg_surface->xdg_surface_commit.link);
  free(scene_xdg_surface);
}

static void scene_xdg_surface_handle_xdg_surface_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_xdg_surface *scene_xdg_surface =
      wl_container_of(listener, scene_xdg_surface, xdg_surface_destroy);
  rediwm_node_destroy(&scene_xdg_surface->tree->node);
}

static void scene_xdg_surface_update_position(struct rediwm_xdg_surface *scene_xdg_surface) {
  struct wlr_xdg_surface *xdg_surface = scene_xdg_surface->xdg_surface;

  rediwm_node_set_position(&scene_xdg_surface->surface_tree->node, -xdg_surface->geometry.x,
                           -xdg_surface->geometry.y);

  if (xdg_surface->role == WLR_XDG_SURFACE_ROLE_POPUP) {
    struct wlr_xdg_popup *popup = xdg_surface->popup;
    if (popup != NULL)
      rediwm_node_set_position(&scene_xdg_surface->tree->node, popup->current.geometry.x,
                               popup->current.geometry.y);
  }
}

static void scene_xdg_surface_handle_xdg_surface_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_xdg_surface *scene_xdg_surface =
      wl_container_of(listener, scene_xdg_surface, xdg_surface_commit);
  scene_xdg_surface_update_position(scene_xdg_surface);
}

struct rediwm_tree *rediwm_xdg_surface_create(struct rediwm_tree *parent, struct wlr_xdg_surface *xdg_surface) {
  struct rediwm_xdg_surface *scene_xdg_surface = calloc(1, sizeof(*scene_xdg_surface));
  if (scene_xdg_surface == NULL) return NULL;

  scene_xdg_surface->xdg_surface = xdg_surface;

  scene_xdg_surface->tree = rediwm_tree_create(parent);
  if (scene_xdg_surface->tree == NULL) {
    free(scene_xdg_surface);
    return NULL;
  }

  scene_xdg_surface->surface_tree = rediwm_subsurface_tree_create(scene_xdg_surface->tree, xdg_surface->surface);
  if (scene_xdg_surface->surface_tree == NULL) {
    rediwm_node_destroy(&scene_xdg_surface->tree->node);
    free(scene_xdg_surface);
    return NULL;
  }

  scene_xdg_surface->tree_destroy.notify = scene_xdg_surface_handle_tree_destroy;
  wl_signal_add(&scene_xdg_surface->tree->node.events.destroy, &scene_xdg_surface->tree_destroy);

  scene_xdg_surface->xdg_surface_destroy.notify = scene_xdg_surface_handle_xdg_surface_destroy;
  wl_signal_add(&xdg_surface->events.destroy, &scene_xdg_surface->xdg_surface_destroy);

  scene_xdg_surface->xdg_surface_commit.notify = scene_xdg_surface_handle_xdg_surface_commit;
  wl_signal_add(&xdg_surface->surface->events.commit, &scene_xdg_surface->xdg_surface_commit);

  scene_xdg_surface_update_position(scene_xdg_surface);

  return scene_xdg_surface->tree;
}

struct rediwm_drag_icon {
  struct rediwm_tree *tree;
  struct rediwm_tree *surface_tree;
  struct wlr_drag_icon *drag_icon;

  struct wl_listener tree_destroy;
  struct wl_listener drag_icon_surface_commit;
  struct wl_listener drag_icon_destroy;
};

static void drag_icon_handle_surface_commit(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_drag_icon *icon = wl_container_of(listener, icon, drag_icon_surface_commit);
  struct wlr_surface *surface = icon->drag_icon->surface;
  struct rediwm_node *node = &icon->surface_tree->node;
  rediwm_node_set_position(node, node->x + surface->current.dx, node->y + surface->current.dy);
}

static void drag_icon_handle_tree_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_drag_icon *icon = wl_container_of(listener, icon, tree_destroy);
  wl_list_remove(&icon->tree_destroy.link);
  wl_list_remove(&icon->drag_icon_surface_commit.link);
  wl_list_remove(&icon->drag_icon_destroy.link);
  free(icon);
}

static void drag_icon_handle_destroy(struct wl_listener *listener, void *data) {
  (void)data;
  struct rediwm_drag_icon *icon = wl_container_of(listener, icon, drag_icon_destroy);
  rediwm_node_destroy(&icon->tree->node);
}

struct rediwm_tree *rediwm_drag_icon_create(struct rediwm_tree *parent, struct wlr_drag_icon *drag_icon) {
  struct rediwm_drag_icon *icon = calloc(1, sizeof(*icon));
  if (!icon) return NULL;

  icon->drag_icon = drag_icon;

  icon->tree = rediwm_tree_create(parent);
  if (!icon->tree) {
    free(icon);
    return NULL;
  }

  icon->surface_tree = rediwm_subsurface_tree_create(icon->tree, drag_icon->surface);
  if (!icon->surface_tree) {
    rediwm_node_destroy(&icon->tree->node);
    free(icon);
    return NULL;
  }

  icon->tree_destroy.notify = drag_icon_handle_tree_destroy;
  wl_signal_add(&icon->tree->node.events.destroy, &icon->tree_destroy);
  icon->drag_icon_surface_commit.notify = drag_icon_handle_surface_commit;
  wl_signal_add(&drag_icon->surface->events.commit, &icon->drag_icon_surface_commit);
  icon->drag_icon_destroy.notify = drag_icon_handle_destroy;
  wl_signal_add(&drag_icon->events.destroy, &icon->drag_icon_destroy);

  return icon->tree;
}
