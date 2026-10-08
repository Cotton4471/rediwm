// A virtual keyboard with a chosen XKB layout, driven from stdin:
//   key <evdev code> <1|0>   press or release
//   quit
// Prints "ready" once the keymap is in, and "ack <line>" after each command.
#define _GNU_SOURCE
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "virtual-keyboard-unstable-v1-client-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t id, const char *interface, uint32_t version) {
  (void)data; (void)version;
  if (!strcmp(interface, "wl_seat")) seat = wl_registry_bind(registry, id, &wl_seat_interface, 1);
  else if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1"))
    manager = wl_registry_bind(registry, id, &zwp_virtual_keyboard_manager_v1_interface, 1);
}
static void global_remove(void *data, struct wl_registry *registry, uint32_t id) { (void)data; (void)registry; (void)id; }
static const struct wl_registry_listener registry_listener = {global, global_remove};

int main(int argc, char **argv) {
  struct xkb_rule_names names = {.layout = argc > 1 ? argv[1] : "us", .variant = argc > 2 ? argv[2] : ""};
  struct wl_display *display = wl_display_connect(NULL);
  assert(display);
  wl_registry_add_listener(wl_display_get_registry(display), &registry_listener, NULL);
  wl_display_roundtrip(display);
  assert(seat && manager);

  struct xkb_context *context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_keymap *map = xkb_keymap_new_from_names(context, &names, 0);
  assert(map);
  char *text = xkb_keymap_get_as_string(map, XKB_KEYMAP_FORMAT_TEXT_V1);
  size_t size = strlen(text) + 1;
  int fd = memfd_create("virtual-keyboard-client", 0);
  assert(fd >= 0 && write(fd, text, size) == (ssize_t)size);
  struct zwp_virtual_keyboard_v1 *keyboard = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
  zwp_virtual_keyboard_v1_keymap(keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
  close(fd);
  free(text);
  xkb_keymap_unref(map);
  xkb_context_unref(context);
  wl_display_roundtrip(display);
  puts("ready");
  fflush(stdout);

  char line[128];
  uint32_t time = 100;
  while (fgets(line, sizeof line, stdin)) {
    unsigned code, down;
    if (sscanf(line, "key %u %u", &code, &down) == 2) zwp_virtual_keyboard_v1_key(keyboard, time += 5, code, down);
    else if (!strncmp(line, "quit", 4)) break;
    wl_display_roundtrip(display);
    printf("ack %s", line);
    fflush(stdout);
  }
  zwp_virtual_keyboard_v1_destroy(keyboard);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
