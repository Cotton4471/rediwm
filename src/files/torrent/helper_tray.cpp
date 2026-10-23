// The StatusNotifierItem, its D-Bus menu, and opening Files from it.
// Part of rediwm-transfers (helper.cpp).
#include "helper.hpp"

namespace helper {

static bool bus_attempted = false;

// Same transient scope contract as session/app_scope.zig and the terminal
// helper.
void place_scope(pid_t pid, char const *app) {
  if (!use_scopes)
    return;
  GError *e = nullptr;
  auto connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &e);
  g_clear_error(&e);
  if (connection) {
    GVariantBuilder props, pids, aux;
    g_variant_builder_init(&props, G_VARIANT_TYPE("a(sv)"));
    g_variant_builder_init(&pids, G_VARIANT_TYPE("au"));
    g_variant_builder_add(&pids, "u", guint32(pid));
    g_variant_builder_add(&props, "(sv)", "PIDs", g_variant_builder_end(&pids));
    g_variant_builder_add(&props, "(sv)", "Slice",
                          g_variant_new_string("app.slice"));
    g_variant_builder_add(&props, "(sv)", "CollectMode",
                          g_variant_new_string("inactive-or-failed"));
    g_variant_builder_init(&aux, G_VARIANT_TYPE("a(sa(sv))"));
    auto name =
        "app-rediwm-" + std::string(app) + "-" + std::to_string(pid) + ".scope";
    auto reply = g_dbus_connection_call_sync(
        connection, "org.freedesktop.systemd1", "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager", "StartTransientUnit",
        g_variant_new("(ssa(sv)a(sa(sv)))", name.c_str(), "fail", &props, &aux),
        nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, 1500, nullptr, &e);
    if (reply)
      g_variant_unref(reply);
    g_clear_error(&e);
    g_object_unref(connection);
  }
}
static void open_files() {
  char *args[] = {const_cast<char *>(executable.c_str()),
                  const_cast<char *>("--transfers"), nullptr};
  GError *e = nullptr;
  GPid pid = 0;
  if (g_spawn_async(nullptr, args, nullptr, G_SPAWN_SEARCH_PATH, nullptr,
                    nullptr, &pid, &e))
    place_scope(pid, "files");
  g_clear_error(&e);
}
static void tray_method(GDBusConnection *, const gchar *, const gchar *,
                        const gchar *, const gchar *method, GVariant *,
                        GDBusMethodInvocation *inv, gpointer) {
  if (!strcmp(method, "Activate") || !strcmp(method, "SecondaryActivate") ||
      !strcmp(method, "ContextMenu"))
    open_files();
  g_dbus_method_invocation_return_value(inv, nullptr);
}
static GVariant *tray_property(GDBusConnection *, const gchar *, const gchar *,
                               const gchar *, const gchar *property, GError **,
                               gpointer) {
  if (!strcmp(property, "Category"))
    return g_variant_new_string("ApplicationStatus");
  if (!strcmp(property, "Id"))
    return g_variant_new_string("rediwm-transfers");
  if (!strcmp(property, "Title"))
    return g_variant_new_string(tray_title.c_str());
  if (!strcmp(property, "Status"))
    return g_variant_new_string(tray_status.c_str());
  if (!strcmp(property, "IconName"))
    return g_variant_new_string(tray_upload ? "go-up" : "folder-download");
  if (!strcmp(property, "ItemIsMenu"))
    return g_variant_new_boolean(false);
  if (!strcmp(property, "Menu"))
    return g_variant_new_object_path("/MenuBar");
  if (!strcmp(property, "ToolTip"))
    return g_variant_new(
        "(s@a(iiay)ss)", "folder-download",
        g_variant_new_array(G_VARIANT_TYPE("(iiay)"), nullptr, 0), "Transfers",
        tray_title.c_str());
  if (!strcmp(property, "IconPixmap")) {
    unsigned char pixels[24 * 24 * 4]{};
    for (int y = 3; y < 21; ++y)
      for (int x = 4; x < 20; ++x)
        if ((x >= 10 && x <= 13 && y < 16) ||
            (y >= 12 && y < 18 && abs(x - 12) <= 18 - y) || (y == 20)) {
          auto p = &pixels[((tray_upload ? 23 - y : y) * 24 + x) * 4];
          p[0] = 255;
          p[1] = 90;
          p[2] = 180;
          p[3] = 255;
        }
    GVariantBuilder b;
    g_variant_builder_init(&b, G_VARIANT_TYPE("a(iiay)"));
    g_variant_builder_add(&b, "(ii@ay)", 24, 24,
                          g_variant_new_fixed_array(G_VARIANT_TYPE_BYTE, pixels,
                                                    sizeof pixels, 1));
    return g_variant_builder_end(&b);
  }
  return nullptr;
}
static void register_tray(GDBusConnection *connection, const gchar *,
                          const gchar *, gpointer) {
  g_dbus_connection_call(
      connection, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher",
      "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem",
      g_variant_new("(s)", "/StatusNotifierItem"), nullptr,
      G_DBUS_CALL_FLAGS_NONE, 2000, nullptr, nullptr, nullptr);
}
static GVariant *menu_row(int id, const char *label) {
  GVariantBuilder properties, children;
  g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
  g_variant_builder_add(&properties, "{sv}", "label",
                        g_variant_new_string(label));
  g_variant_builder_add(&properties, "{sv}", "enabled",
                        g_variant_new_boolean(true));
  g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
  return g_variant_new("(ia{sv}av)", id, &properties, &children);
}
static void menu_method(GDBusConnection *, const gchar *, const gchar *,
                        const gchar *, const gchar *method,
                        GVariant *parameters, GDBusMethodInvocation *inv,
                        gpointer) {
  if (!strcmp(method, "GetLayout")) {
    GVariantBuilder properties, children;
    g_variant_builder_init(&properties, G_VARIANT_TYPE("a{sv}"));
    g_variant_builder_init(&children, G_VARIANT_TYPE("av"));
    g_variant_builder_add(&children, "v", menu_row(1, "Open Transfers"));
    g_variant_builder_add(&children, "v", menu_row(2, "Pause all"));
    g_variant_builder_add(&children, "v", menu_row(3, "Stop seeding"));
    g_dbus_method_invocation_return_value(
        inv, g_variant_new("(u(ia{sv}av))", 1u, 0, &properties, &children));
    return;
  }
  if (!strcmp(method, "AboutToShow")) {
    g_dbus_method_invocation_return_value(inv, g_variant_new("(b)", false));
    return;
  }
  if (!strcmp(method, "Event")) {
    gint id;
    const char *event;
    GVariant *value;
    guint timestamp;
    g_variant_get(parameters, "(i&svu)", &id, &event, &value, &timestamp);
    g_variant_unref(value);
    if (!strcmp(event, "clicked")) {
      if (id == 1)
        open_files();
      else
        for (auto &[key, t] : transfers) {
          if (t.handle.is_valid() &&
              (id == 2 || (id == 3 && t.status().is_finished))) {
            t.handle.pause();
            request_save(t);
          }
        }
      publish();
      schedule();
    }
  }
  g_dbus_method_invocation_return_value(inv, nullptr);
}
static void init_menu() {
  const char xml[] =
      "<node><interface name='com.canonical.dbusmenu'>"
      "<method name='GetLayout'><arg type='i' direction='in'/><arg type='i' "
      "direction='in'/><arg type='as' direction='in'/><arg type='u' "
      "direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>"
      "<method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' "
      "direction='out'/></method>"
      "<method name='Event'><arg type='i' direction='in'/><arg type='s' "
      "direction='in'/><arg type='v' direction='in'/><arg type='u' "
      "direction='in'/></method>"
      "</interface></node>";
  auto info = g_dbus_node_info_new_for_xml(xml, nullptr);
  static GDBusInterfaceVTable table = {
      menu_method, nullptr, nullptr, {nullptr}};
  g_dbus_connection_register_object(bus, "/MenuBar", info->interfaces[0],
                                    &table, nullptr, nullptr, nullptr);
  g_dbus_node_info_unref(info);
}
void init_tray() {
  if (bus_attempted)
    return;
  bus_attempted = true;
  GError *error = nullptr;
  bus = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  g_clear_error(&error);
  if (!bus)
    return;
  const char xml[] =
      "<node><interface name='org.kde.StatusNotifierItem'>"
      "<method name='Activate'><arg type='i' direction='in'/><arg type='i' "
      "direction='in'/></method>"
      "<method name='SecondaryActivate'><arg type='i' direction='in'/><arg "
      "type='i' direction='in'/></method>"
      "<method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' "
      "direction='in'/></method>"
      "<property name='Category' type='s' access='read'/><property name='Id' "
      "type='s' access='read'/><property name='Title' type='s' access='read'/>"
      "<property name='Status' type='s' access='read'/><property "
      "name='IconName' type='s' access='read'/><property name='IconPixmap' "
      "type='a(iiay)' access='read'/>"
      "<property name='ItemIsMenu' type='b' access='read'/><property "
      "name='Menu' type='o' access='read'/><property name='ToolTip' "
      "type='(sa(iiay)ss)' access='read'/>"
      "<signal name='NewStatus'><arg type='s'/></signal><signal "
      "name='NewTitle'/><signal name='NewIcon'/><signal "
      "name='NewToolTip'/></interface></node>";
  auto info = g_dbus_node_info_new_for_xml(xml, nullptr);
  static GDBusInterfaceVTable table = {
      tray_method, tray_property, nullptr, {nullptr}};
  g_dbus_connection_register_object(bus, "/StatusNotifierItem",
                                    info->interfaces[0], &table, nullptr,
                                    nullptr, nullptr);
  g_dbus_node_info_unref(info);
  init_menu();
  g_bus_watch_name_on_connection(bus, "org.kde.StatusNotifierWatcher",
                                 G_BUS_NAME_WATCHER_FLAGS_NONE, register_tray,
                                 nullptr, nullptr, nullptr);
}

} // namespace helper
