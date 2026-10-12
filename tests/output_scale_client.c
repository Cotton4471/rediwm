// Real fractional-scale client for isolated mixed-density output tests.
#define _GNU_SOURCE
#include "xdg-shell-client-protocol.h"
#include "fractional-scale-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-decoration-client-protocol.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static struct wl_compositor *compositor;
static struct wl_shm *shm;
static struct xdg_wm_base *wm;
static struct wp_fractional_scale_manager_v1 *manager;
static struct wp_viewporter *viewporter;
static struct zxdg_decoration_manager_v1 *decorations;
static struct wl_surface *surface;
// Every wl_output, by name, so enter and leave can say which output.
enum { OUTPUTS = 8 };
static struct wl_output *outputs[OUTPUTS];
static char output_names[OUTPUTS][32];
static int output_count;
static int configured;
static uint32_t density = 120;

static void released(void *data, struct wl_buffer *buffer) {
    (void)data; wl_buffer_destroy(buffer);
}
static const struct wl_buffer_listener buffer_listener = { .release = released };
static void draw(void) {
    if (!configured) return;
    int width = (400 * density + 60) / 120, height = (260 * density + 60) / 120;
    size_t size = (size_t)width * height * 4;
    int fd = memfd_create("scale-client", MFD_CLOEXEC);
    assert(fd >= 0 && ftruncate(fd, (off_t)size) == 0);
    uint32_t *pixels = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    assert(pixels != MAP_FAILED);
    for (size_t i = 0; i < size / 4; i++) pixels[i] = 0xff336699;
    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, (int)size);
    struct wl_buffer *buffer = wl_shm_pool_create_buffer(pool, 0, width, height, width * 4, WL_SHM_FORMAT_ARGB8888);
    wl_buffer_add_listener(buffer, &buffer_listener, NULL);
    wl_surface_attach(surface, buffer, 0, 0);
    wl_surface_damage_buffer(surface, 0, 0, width, height);
    wl_surface_commit(surface);
    wl_shm_pool_destroy(pool);
    munmap(pixels, size);
    close(fd);
    printf("draw %u %d %d\n", density, width, height);
    fflush(stdout);
}
static const char *output_name(struct wl_output *output) {
    for (int i = 0; i < output_count; i++) if (outputs[i] == output) return output_names[i];
    return "unknown";
}
static void output_geometry(void *data, struct wl_output *o, int32_t x, int32_t y, int32_t w, int32_t h,
                            int32_t subpixel, const char *make, const char *model, int32_t transform) {
    (void)data; (void)o; (void)x; (void)y; (void)w; (void)h; (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *o, uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    (void)data; (void)o; (void)flags; (void)w; (void)h; (void)refresh;
}
static void output_done(void *data, struct wl_output *o) { (void)data; (void)o; }
static void output_scale(void *data, struct wl_output *o, int32_t factor) { (void)data; (void)o; (void)factor; }
static void output_named(void *data, struct wl_output *o, const char *name) {
    (void)data;
    for (int i = 0; i < output_count; i++) if (outputs[i] == o) snprintf(output_names[i], sizeof(output_names[i]), "%s", name);
}
static void output_description(void *data, struct wl_output *o, const char *text) { (void)data; (void)o; (void)text; }
static const struct wl_output_listener output_listener = {
    .geometry = output_geometry, .mode = output_mode, .done = output_done, .scale = output_scale,
    .name = output_named, .description = output_description};
static void entered(void *data, struct wl_surface *s, struct wl_output *output) {
    (void)data; (void)s;
    printf("enter %s\n", output_name(output));
    fflush(stdout);
}
static void left(void *data, struct wl_surface *s, struct wl_output *output) {
    (void)data; (void)s;
    printf("leave %s\n", output_name(output));
    fflush(stdout);
}
static const struct wl_surface_listener surface_listener = { .enter = entered, .leave = left };
static void preferred(void *data, struct wp_fractional_scale_v1 *object, uint32_t scale) {
    (void)data; (void)object; density = scale; draw();
}
static const struct wp_fractional_scale_v1_listener scale_listener = { .preferred_scale = preferred };
static void configure(void *data, struct xdg_surface *xdg, uint32_t serial) {
    (void)data; xdg_surface_ack_configure(xdg, serial); configured = 1; draw();
}
static const struct xdg_surface_listener xdg_listener = { .configure = configure };
static void ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    (void)data; xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener wm_listener = { .ping = ping };
static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
    (void)data; (void)version;
#define BIND(text, field, type, v) if (!strcmp(interface, text)) field = wl_registry_bind(registry, name, &type##_interface, v)
    BIND("wl_compositor", compositor, wl_compositor, 4);
    else BIND("wl_shm", shm, wl_shm, 1);
    else BIND("xdg_wm_base", wm, xdg_wm_base, 1);
    else BIND("wp_fractional_scale_manager_v1", manager, wp_fractional_scale_manager_v1, 1);
    else BIND("wp_viewporter", viewporter, wp_viewporter, 1);
    else BIND("zxdg_decoration_manager_v1", decorations, zxdg_decoration_manager_v1, 1);
    else if (!strcmp(interface, "wl_output") && output_count < OUTPUTS && version >= 4) {
        outputs[output_count] = wl_registry_bind(registry, name, &wl_output_interface, 4);
        wl_output_add_listener(outputs[output_count], &output_listener, NULL);
        output_count++;
    }
#undef BIND
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static const struct wl_registry_listener registry_listener = { .global = global, .global_remove = removed };
int main(void) {
    struct wl_display *display = wl_display_connect(NULL);
    assert(display);
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    assert(wl_display_roundtrip(display) >= 0);
    assert(compositor && shm && wm && manager && viewporter && decorations);
    xdg_wm_base_add_listener(wm, &wm_listener, NULL);
    surface = wl_compositor_create_surface(compositor);
    wl_surface_add_listener(surface, &surface_listener, NULL);
    struct wp_viewport *viewport = wp_viewporter_get_viewport(viewporter, surface);
    wp_viewport_set_destination(viewport, 400, 260);
    struct wp_fractional_scale_v1 *scale = wp_fractional_scale_manager_v1_get_fractional_scale(manager, surface);
    wp_fractional_scale_v1_add_listener(scale, &scale_listener, NULL);
    struct xdg_surface *xdg = xdg_wm_base_get_xdg_surface(wm, surface);
    xdg_surface_add_listener(xdg, &xdg_listener, NULL);
    struct xdg_toplevel *top = xdg_surface_get_toplevel(xdg);
    xdg_toplevel_set_app_id(top, "rediwm-scale-test");
    xdg_toplevel_set_title(top, "Scale fixture");
    struct zxdg_toplevel_decoration_v1 *decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(decorations, top);
    zxdg_toplevel_decoration_v1_set_mode(decoration, ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
    wl_surface_commit(surface);
    while (wl_display_dispatch(display) >= 0) {}
    wl_display_disconnect(display);
    return 0;
}
