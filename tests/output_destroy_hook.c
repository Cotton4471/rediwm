// Test-only hot-unplug injection and scene lifetime check in the real compositor.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_scene.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>

static struct wlr_scene *scene;
static struct wlr_output *target, *dying;
static struct wl_event_source *timer;
static unsigned mutations;
static bool cursor_destroyed;
static bool unplugged, initialized;
static struct wlr_backend *headless;
static unsigned width, height;
static char *connector_name;
static bool reconnecting;

void wlr_output_set_name(struct wlr_output *output, const char *name) {
    void (*set_name)(struct wlr_output *, const char *) =
        dlsym(RTLD_NEXT, "wlr_output_set_name");
    assert(set_name);
    // Present the same connector identity before the backend emits new_output.
    set_name(output, reconnecting ? connector_name : name);
}

void wlr_cursor_destroy(struct wlr_cursor *cursor) {
    void (*destroy)(struct wlr_cursor *) = dlsym(RTLD_NEXT, "wlr_cursor_destroy");
    assert(destroy);
    cursor_destroyed = true;
    destroy(cursor);
}

void wlr_backend_destroy(struct wlr_backend *backend) {
    void (*destroy)(struct wlr_backend *) = dlsym(RTLD_NEXT, "wlr_backend_destroy");
    assert(destroy);
    // Output/device callbacks may finish gestures and use the cursor/seat.
    assert(!cursor_destroyed);
    destroy(backend);
}

static int unplug(void *data) {
    (void)data;
    if (unplugged) {
        if (access(getenv("REDIWM_TEST_REPLUG"), F_OK) != 0) {
            wl_event_source_timer_update(timer, 20);
            return 0;
        }
        wl_event_source_remove(timer);
        reconnecting = true;
        assert(wlr_headless_add_output(headless, width, height));
        reconnecting = false;
        free(connector_name);
        connector_name = NULL;
        return 0;
    }
    if (access(getenv("REDIWM_TEST_UNPLUG"), F_OK) != 0) {
        wl_event_source_timer_update(timer, 20);
        return 0;
    }
    if (!getenv("REDIWM_TEST_REPLUG")) wl_event_source_remove(timer);
    dying = target;
    wlr_output_destroy(target);
    dying = NULL;
    assert(mutations > 0);
    unplugged = true;
    if (getenv("REDIWM_TEST_REPLUG")) wl_event_source_timer_update(timer, 20);
    return 0;
}

struct wlr_scene_output *wlr_scene_output_create(struct wlr_scene *s,
        struct wlr_output *output) {
    struct wlr_scene_output *(*create)(struct wlr_scene *, struct wlr_output *) =
        dlsym(RTLD_NEXT, "wlr_scene_output_create");
    assert(create);
    struct wlr_scene_output *result = create(s, output);
    if (!initialized && result) {
        initialized = true;
        scene = s;
        target = output;
        headless = output->backend;
        width = output->width;
        height = output->height;
        if (getenv("REDIWM_TEST_REPLUG")) {
            connector_name = strdup(output->name);
            assert(connector_name);
        }
        timer = wl_event_loop_add_timer(output->event_loop, unplug, NULL);
        assert(timer);
        wl_event_source_timer_update(timer, 20);
    }
    return result;
}

void wlr_scene_node_destroy(struct wlr_scene_node *node) {
    void (*destroy)(struct wlr_scene_node *) =
        dlsym(RTLD_NEXT, "wlr_scene_node_destroy");
    assert(destroy);
    if (dying) {
        // Removing per-output chrome must never uncover surfaces on an output
        // whose destroy signal is already in progress (wlroots issue #4096).
        assert(wlr_scene_get_scene_output(scene, dying) == NULL);
        ++mutations;
    }
    destroy(node);
}
