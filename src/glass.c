// Glass: the CSS backdrop-filter behind the compositor's own surfaces (window
// titlebars, the taskbar, the start and power menus). This file only registers
// effects; the owned output pass blurs and composites them (scene_output.c,
// stage 5 of docs/plans/scene-graph.md). An effect is a scene node without a
// buffer placed below its target: its place in paint order is where the blur
// reads the framebuffer, and resolve gives it the target's box (projection.c).
#define WLR_USE_UNSTABLE
#include <stdlib.h>
#include <wlr/util/addon.h>
#include "glass.h"
#include "node.h"

enum glass_kind { GLASS_TITLEBAR, GLASS_TASKBAR, GLASS_PANEL, GLASS_SIDEBAR };
struct glass_effect;
struct glass_engine {
	struct wl_list effects;
	// A dragged opaque titlebar, or every effect during camera motion, keeps
	// its last blur (stage 5, D2).
	struct glass_effect *held;
	bool hold_all;
	uint64_t next_serial;
};
struct glass_effect {
	struct glass_engine *engine;
	struct wl_list link;
	struct rediwm_buffer *node, *target;
	struct wl_listener destroy, target_destroy;
	struct wlr_addon addon; // on the node, for rediwm_glass_effect_info
	enum glass_kind kind;
	uint64_t serial;
	float radius, opacity;
};

struct glass_engine *rediwm_glass_create(void)
{
	struct glass_engine *engine = calloc(1, sizeof(*engine));
	if (!engine)
		return NULL;
	wl_list_init(&engine->effects);
	return engine;
}
static void handle_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_effect *effect = wl_container_of(listener, effect, destroy);
	wlr_addon_finish(&effect->addon);
	if (effect->engine->held == effect)
		effect->engine->held = NULL;
	wl_list_remove(&effect->destroy.link);
	wl_list_remove(&effect->target_destroy.link);
	wl_list_remove(&effect->link);
	free(effect);
}
static void handle_target_destroy(struct wl_listener *listener, void *data)
{
	(void)data;
	struct glass_effect *effect = wl_container_of(listener, effect, target_destroy);
	rediwm_node_destroy(&effect->node->node);
}
static void addon_destroy(struct wlr_addon *addon) { wlr_addon_finish(addon); }
static const struct wlr_addon_interface effect_addon = {.name = "rediwm glass effect",
							  .destroy = addon_destroy};
static struct glass_effect *effect_of(struct rediwm_node *node)
{
	struct wlr_addon *addon = wlr_addon_find(&node->addons, NULL, &effect_addon);
	struct glass_effect *effect;
	return addon ? (effect = wl_container_of(addon, effect, addon)) : NULL;
}
bool rediwm_glass_effect_info(struct rediwm_node *node, struct rediwm_glass_info *out)
{
	struct glass_effect *effect = effect_of(node);
	if (!effect)
		return false;
	*out = (struct rediwm_glass_info){
	    .target = effect->target,
	    // Sidebars retain background shapes through a lighter frost.
	    .sigma = effect->kind == GLASS_SIDEBAR ? 8 : effect->kind == GLASS_TITLEBAR ? 22 : effect->kind == GLASS_TASKBAR ? 24 : 26,
	    .saturation = effect->kind == GLASS_PANEL || effect->kind == GLASS_SIDEBAR ? 1.6f : 1.5f,
	    .opacity = effect->opacity,
	    .radius = effect->radius,
	    .serial = effect->serial,
	    .held = effect->engine->hold_all || effect->engine->held == effect,
	};
	return true;
}
bool rediwm_glass_is_effect_node(struct rediwm_node *node)
{
	return node->type == REDIWM_NODE_BUFFER && effect_of(node);
}
static bool accepts_input(struct rediwm_buffer *buffer, double *x, double *y)
{
	(void)buffer;
	(void)x;
	(void)y;
	return false;
}
struct glass_effect *rediwm_glass_attach(struct glass_engine *engine,
					 struct rediwm_buffer *target,
					 struct rediwm_node *before, enum glass_kind kind)
{
	if (!engine)
		return NULL;
	struct glass_effect *effect = calloc(1, sizeof(*effect));
	if (!effect)
		return NULL;
	effect->node = rediwm_buffer_create(target->node.parent, NULL);
	if (!effect->node) {
		free(effect);
		return NULL;
	}
	effect->engine = engine;
	effect->target = target;
	effect->kind = kind;
	effect->opacity = 1;
	effect->serial = ++engine->next_serial;
	effect->node->point_accepts_input = accepts_input;
	wlr_addon_init(&effect->addon, &effect->node->node.addons, NULL, &effect_addon);
	rediwm_node_place_below(&effect->node->node, before);
	effect->destroy.notify = handle_destroy;
	wl_signal_add(&effect->node->node.events.destroy, &effect->destroy);
	effect->target_destroy.notify = handle_target_destroy;
	wl_signal_add(&target->node.events.destroy, &effect->target_destroy);
	wl_list_insert(&engine->effects, &effect->link);
	return effect;
}
void rediwm_glass_hold(struct glass_engine *engine, struct glass_effect *effect)
{
	if (engine)
		engine->held = effect;
}
void rediwm_glass_hold_all(struct glass_engine *engine, bool hold)
{
	if (engine)
		engine->hold_all = hold;
}
void rediwm_glass_configure(struct glass_effect *effect, float radius, float opacity)
{
	if (!effect)
		return;
	effect->radius = radius;
	effect->opacity = opacity;
}
void rediwm_glass_detach(struct glass_effect *effect)
{
	if (effect)
		rediwm_node_destroy(&effect->node->node);
}
void rediwm_glass_destroy(struct glass_engine *engine)
{
	if (!engine)
		return;
	struct glass_effect *effect, *tmp;
	wl_list_for_each_safe(effect, tmp, &engine->effects, link)
		rediwm_node_destroy(&effect->node->node);
	free(engine);
}
