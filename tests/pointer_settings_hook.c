// Noninstalled fake libinput backend. Exercises the production pointer lifecycle
// and UI in an isolated headless compositor, without opening host input devices.
#define _GNU_SOURCE
#define WLR_USE_UNSTABLE
#include <assert.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <libinput.h>
#include <libudev.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-server-core.h>
#include <wlr/backend/headless.h>
#include <wlr/backend/libinput.h>
#include <wlr/interfaces/wlr_pointer.h>

struct fake_device {
    struct wlr_pointer pointer;
    bool live, fail_next;
    double speed;
    bool natural, left, tap, drag, dwt;
    unsigned generation, writes, failures;
    unsigned fail_after;
};
enum { DEVICE_COUNT = 11 };
static struct fake_device devices[DEVICE_COUNT];
static struct wlr_backend *backend;
static const struct wlr_pointer_impl impl = {.name = "pointer-settings-fixture"};
static const char *names[] = {
    "Fixture Mouse", "Fixture Touchpad", "Fixture Mouse", "Fixture Mouse", "Fixture Unsupported", "",
    "Fixture Consumer Control", "Fixture Mouse Macros", "Fixture Touchpad Mouse", "Fixture Keyboard Mouse", "Fixture Pointing Stick",
};
static const char *paths[] = {
    "pci-fixture-usb-0:1:1.0", "platform-fixture-touchpad", "pci-fixture-usb-0:2:1.0", "pci-fixture-usb-0:1:1.0", NULL, "pci-fixture-usb-0:3:1.0",
    "pci-fixture-usb-0:1:1.1", "pci-fixture-usb-0:1:1.2", "platform-fixture-touchpad", "pci-fixture-usb-0:4:1.3", "platform-fixture-touchpad",
};
static char sysnames[DEVICE_COUNT][32];

static int index_of(const void *device) {
    for (unsigned i = 0; i < DEVICE_COUNT; i++) if (device == &devices[i]) return (int)i;
    return -1;
}
static int live_index(const void *device) {
    int i = index_of(device);
    assert(i >= 0 && devices[i].live); // Any stale selected-device access aborts.
    return i;
}
#define REAL(name) __typeof__(&name) real = (__typeof__(&name))dlsym(RTLD_NEXT, #name); assert(real)

static void snapshot(void) {
    const char *path = getenv("REDIWM_TEST_POINTER_STATE");
    assert(path);
    char temporary[4096];
    assert(snprintf(temporary, sizeof(temporary), "%s.tmp", path) < (int)sizeof(temporary));
    FILE *file = fopen(temporary, "w");
    assert(file);
    fputs("[", file);
    for (unsigned i = 0; i < DEVICE_COUNT; i++) {
        struct fake_device *d = &devices[i];
        fprintf(file, "%s{\"live\":%s,\"speed\":%.9g,\"natural\":%s,\"left\":%s,\"tap\":%s,\"drag\":%s,\"dwt\":%s,\"writes\":%u,\"failures\":%u}",
            i ? "," : "", d->live ? "true" : "false", d->speed,
            d->natural ? "true" : "false", d->left ? "true" : "false",
            d->tap ? "true" : "false", d->drag ? "true" : "false", d->dwt ? "true" : "false", d->writes, d->failures);
    }
    fputs("]\n", file);
    assert(fclose(file) == 0);
    assert(rename(temporary, path) == 0);
}

static int input_ready(int fd, uint32_t mask, void *data) {
    (void)mask; (void)data;
    uint32_t packet[2];
    ssize_t n;
    while ((n = read(fd, packet, sizeof(packet))) == sizeof(packet)) {
        unsigned index = packet[1];
        assert(index < DEVICE_COUNT);
        struct fake_device *d = &devices[index];
        switch (packet[0]) {
        case 1:
            assert(!d->live);
            d->live = true;
            d->speed = -.2;
            d->natural = d->left = d->tap = d->drag = d->dwt = false;
            d->fail_next = false;
            d->fail_after = 0;
            d->generation++;
            snprintf(sysnames[index], sizeof(sysnames[index]), "event%u", index + d->generation * 10);
            wlr_pointer_init(&d->pointer, &impl, names[index]);
            wl_signal_emit_mutable(&backend->events.new_input, &d->pointer.base);
            break;
        case 2:
            assert(d->live);
            wlr_pointer_finish(&d->pointer);
            d->live = false;
            break;
        case 3: break;
        case 4: d->fail_next = true; break;
        case 5: d->fail_after = 2; break; // Reject the second reset setter.
        default: assert(false);
        }
        snapshot();
    }
    assert(n <= 0);
    return 0;
}
struct wlr_backend *wlr_headless_backend_create(struct wl_event_loop *loop) {
    REAL(wlr_headless_backend_create);
    backend = real(loop);
    const char *path = getenv("REDIWM_TEST_POINTER_COMMANDS");
    assert(path && backend);
    int fd = open(path, O_RDWR | O_NONBLOCK | O_CLOEXEC);
    assert(fd >= 0);
    assert(wl_event_loop_add_fd(loop, fd, WL_EVENT_READABLE, input_ready, NULL));
    snapshot();
    return backend;
}
void wlr_backend_destroy(struct wlr_backend *target) {
    REAL(wlr_backend_destroy);
    if (target == backend) {
        for (unsigned i = 0; i < DEVICE_COUNT; i++) if (devices[i].live) {
            wlr_pointer_finish(&devices[i].pointer);
            devices[i].live = false;
        }
    }
    real(target);
}
bool wlr_input_device_is_libinput(struct wlr_input_device *device) {
    for (unsigned i = 0; i < DEVICE_COUNT; i++) if (device == &devices[i].pointer.base) return true;
    REAL(wlr_input_device_is_libinput);
    return real(device);
}
struct libinput_device *wlr_libinput_get_device_handle(struct wlr_input_device *device) {
    for (unsigned i = 0; i < DEVICE_COUNT; i++) if (device == &devices[i].pointer.base) {
        assert(devices[i].live);
        return (struct libinput_device *)&devices[i];
    }
    REAL(wlr_libinput_get_device_handle);
    return real(device);
}
const char *libinput_device_get_name(struct libinput_device *device) { return names[live_index(device)]; }
const char *libinput_device_get_sysname(struct libinput_device *device) { return sysnames[live_index(device)]; }
unsigned int libinput_device_get_id_bustype(struct libinput_device *device) { live_index(device); return 3; }
unsigned int libinput_device_get_id_vendor(struct libinput_device *device) { live_index(device); return 0x1234; }
unsigned int libinput_device_get_id_product(struct libinput_device *device) { int i = live_index(device); return i == 1 ? 2 : i == 5 ? 3 : 1; }
struct udev_device *libinput_device_get_udev_device(struct libinput_device *device) { live_index(device); return (struct udev_device *)device; }
struct libinput_device_group *libinput_device_get_device_group(struct libinput_device *device) {
    int i = live_index(device);
    int group = (i == 6 || i == 7) ? 0 : (i == 8 || i == 10) ? 1 : i;
    return (struct libinput_device_group *)&devices[group];
}
struct udev_device *udev_device_unref(struct udev_device *device) {
    if (index_of(device) >= 0) return NULL;
    REAL(udev_device_unref); return real(device);
}
struct udev_device *udev_device_get_parent(struct udev_device *device) {
    if (index_of(device) >= 0) return NULL;
    REAL(udev_device_get_parent); return real(device);
}
const char *udev_device_get_sysattr_value(struct udev_device *device, const char *key) {
    int i = index_of(device);
    if (i >= 0) {
        if (strcmp(key, "bInterfaceNumber") == 0) return "00";
        if (strcmp(key, "bInterfaceClass") == 0) return "03";
        if (strcmp(key, "bInterfaceProtocol") == 0) return i == 7 || i == 9 || i == 10 ? "01" : "00";
        return NULL;
    }
    REAL(udev_device_get_sysattr_value); return real(device, key);
}
const char *udev_device_get_property_value(struct udev_device *device, const char *key) {
    int i = index_of(device);
    if (i >= 0) {
        if (strcmp(key, "ID_PATH") == 0) return paths[i];
        if (strcmp(key, "ID_SERIAL_SHORT") == 0 && i == 1) return "fixture-touchpad-serial";
        if (strcmp(key, "ID_INPUT_TOUCHPAD") == 0) return i == 1 ? "1" : NULL;
        if (strcmp(key, "ID_INPUT_MOUSE") == 0) return i != 1 && i != 4 && i != 6 ? "1" : NULL;
        if (strcmp(key, "ID_INPUT_TRACKBALL") == 0) return i == 5 ? "1" : NULL;
        if (strcmp(key, "ID_INPUT_POINTINGSTICK") == 0) return i == 10 ? "1" : NULL;
        if (strcmp(key, "ID_VENDOR_FROM_DATABASE") == 0 && i == 5) return "Kensington";
        if (strcmp(key, "ID_MODEL_FROM_DATABASE") == 0 && i == 5) return "Expert Mouse";
        return NULL;
    }
    REAL(udev_device_get_property_value); return real(device, key);
}
int libinput_device_has_capability(struct libinput_device *device, enum libinput_device_capability cap) {
    int i = live_index(device);
    return cap == LIBINPUT_DEVICE_CAP_POINTER || (i == 6 && cap == LIBINPUT_DEVICE_CAP_KEYBOARD);
}
int libinput_device_config_accel_is_available(struct libinput_device *device) { return live_index(device) != 4; }
int libinput_device_config_scroll_has_natural_scroll(struct libinput_device *device) { return live_index(device) != 4; }
int libinput_device_config_left_handed_is_available(struct libinput_device *device) { return live_index(device) != 4; }
int libinput_device_config_tap_get_finger_count(struct libinput_device *device) { return live_index(device) == 1 ? 3 : 0; }
int libinput_device_config_dwt_is_available(struct libinput_device *device) { return live_index(device) == 1; }
double libinput_device_config_accel_get_speed(struct libinput_device *device) { return devices[live_index(device)].speed; }
int libinput_device_config_scroll_get_natural_scroll_enabled(struct libinput_device *device) { return devices[live_index(device)].natural; }
int libinput_device_config_left_handed_get(struct libinput_device *device) { return devices[live_index(device)].left; }
enum libinput_config_tap_state libinput_device_config_tap_get_enabled(struct libinput_device *device) { return devices[live_index(device)].tap ? LIBINPUT_CONFIG_TAP_ENABLED : LIBINPUT_CONFIG_TAP_DISABLED; }
enum libinput_config_drag_state libinput_device_config_tap_get_drag_enabled(struct libinput_device *device) { return devices[live_index(device)].drag ? LIBINPUT_CONFIG_DRAG_ENABLED : LIBINPUT_CONFIG_DRAG_DISABLED; }
enum libinput_config_dwt_state libinput_device_config_dwt_get_enabled(struct libinput_device *device) { return devices[live_index(device)].dwt ? LIBINPUT_CONFIG_DWT_ENABLED : LIBINPUT_CONFIG_DWT_DISABLED; }

static enum libinput_config_status can_write(struct fake_device *d, bool supported) {
    assert(d->live);
    if (!supported) { d->failures++; snapshot(); return LIBINPUT_CONFIG_STATUS_UNSUPPORTED; }
    if (d->fail_next || (d->fail_after && --d->fail_after == 0)) {
        d->fail_next = false; d->failures++; snapshot(); return LIBINPUT_CONFIG_STATUS_INVALID;
    }
    d->writes++;
    return LIBINPUT_CONFIG_STATUS_SUCCESS;
}
enum libinput_config_status libinput_device_config_accel_set_speed(struct libinput_device *device, double value) {
    int i = live_index(device); struct fake_device *d = &devices[i];
    enum libinput_config_status status = can_write(d, i != 4);
    if (status == LIBINPUT_CONFIG_STATUS_SUCCESS) d->speed = value;
    snapshot(); return status;
}
#define BOOL_SETTER(name, type, field, support) \
    enum libinput_config_status name(struct libinput_device *device, type value) { \
        int i = live_index(device); struct fake_device *d = &devices[i]; \
        enum libinput_config_status status = can_write(d, (support)); \
        if (status == LIBINPUT_CONFIG_STATUS_SUCCESS) d->field = value != 0; \
        snapshot(); return status; \
    }
BOOL_SETTER(libinput_device_config_scroll_set_natural_scroll_enabled, int, natural, i != 4)
BOOL_SETTER(libinput_device_config_left_handed_set, int, left, i != 4)
BOOL_SETTER(libinput_device_config_tap_set_enabled, enum libinput_config_tap_state, tap, i == 1)
BOOL_SETTER(libinput_device_config_tap_set_drag_enabled, enum libinput_config_drag_state, drag, i == 1)
BOOL_SETTER(libinput_device_config_dwt_set_enabled, enum libinput_config_dwt_state, dwt, i == 1)
