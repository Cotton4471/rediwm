// Test-only hot-unplug injection and lifetime checks in the real compositor.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_cursor.h>
#include <wlr/backend.h>
#include <wlr/backend/headless.h>

static struct wlr_output *target;
static struct wl_event_source *timer;
static bool cursor_destroyed;
static bool unplugged, initialized;
static struct wlr_backend *headless;
static unsigned width, height;
static char *connector_name;
static bool reconnecting;

static int unplug(void *data);

// The first output the backend creates is the unplug target. This runs when the
// backend names it, before the compositor has seen it.
void wlr_output_set_name(struct wlr_output *output, const char *name) {
    void (*set_name)(struct wlr_output *, const char *) =
        dlsym(RTLD_NEXT, "wlr_output_set_name");
    assert(set_name);
    if (!initialized) {
        initialized = true;
        target = output;
        headless = output->backend;
        width = output->width;
        height = output->height;
        if (getenv("REDIWM_TEST_REPLUG")) {
            connector_name = strdup(name);
            assert(connector_name);
        }
        timer = wl_event_loop_add_timer(output->event_loop, unplug, NULL);
        assert(timer);
        wl_event_source_timer_update(timer, 20);
    }
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
    wlr_output_destroy(target);
    unplugged = true;
    if (getenv("REDIWM_TEST_REPLUG")) wl_event_source_timer_update(timer, 20);
    return 0;
}
