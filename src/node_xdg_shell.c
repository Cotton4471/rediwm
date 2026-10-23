// xdg surfaces and drag icons in the own scene: see node_surface.h. wlroots'
// types/scene/xdg_shell.c and drag_icon.c (wlroots 0.20, MIT licensed) on own nodes.
#define WLR_USE_UNSTABLE
#define WLR_PRIVATE private
#include "node_surface.h"
#include <stdlib.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_xdg_shell.h>

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
