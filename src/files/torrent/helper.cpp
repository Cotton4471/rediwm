// One per-user torrent session. The UI is a disposable subscriber, never the
// owner of a transfer. All libtorrent and GIO state lives on this main loop.
#include <fcntl.h>
#include <filesystem>
#include <fstream>
#include <gio/gio.h>
#include <glib-unix.h>
#include <iostream>
#include <json-glib/json-glib.h>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <linux/fs.h>
#include <map>
#include <memory>
#include <set>
#include <signal.h>
#include <sstream>
#include <sys/eventfd.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/un.h>
#include <unistd.h>
namespace lt = libtorrent;
namespace fs = std::filesystem;
static constexpr size_t max_packet = 192 * 1024;
static constexpr size_t max_files = 512, max_torrents = 64;
static constexpr char item_iface[] = "org.kde.StatusNotifierItem";
struct Transfer {
  lt::torrent_handle handle;
  std::string id, source, destination, error, publication;
  bool pending = true, published = false, moving = false,
       resume_after_publish = false;
  bool configuring = false, start_after_priority = false;
  std::vector<lt::download_priority_t> requested_priorities;
  int ratio = 1, limit = 1024 * 1024;
  lt::torrent_status cached;
  std::shared_ptr<lt::torrent_info const> cached_info;
  lt::torrent_status status() const {
    return handle.is_valid() ? handle.status() : cached;
  }
  std::shared_ptr<lt::torrent_info const> info() const {
    return handle.is_valid() ? handle.torrent_file() : cached_info;
  }
};
struct Peer {
  int fd;
  guint source;
};
static std::map<std::string, Transfer> transfers;
static std::map<int, Peer> peers;
static std::unique_ptr<lt::session> session;
static GMainLoop *loop;
static GDBusConnection *bus;
static bool bus_attempted = false;
static std::string state_dir, executable;
static int wake_fd = -1;
static guint ticker = 0, idle_exit = 0;
static unsigned ticks = 0;
static bool quitting = false, starting = true;
static std::map<std::string, unsigned> saves;
static void saved(std::string const &id) {
  auto it = saves.find(id);
  if (it != saves.end() && --it->second == 0)
    saves.erase(it);
}
static bool use_scopes = false, tray_upload = false;
static std::string tray_status = "Passive";
static std::string tray_title = "Transfers";
static void publish();
static void schedule();
static void persist(Transfer &t);
static std::string snapshot();
static void restore();
static void create_engine() {
  if (session)
    return;
  lt::settings_pack settings;
  settings.set_int(lt::settings_pack::alert_mask,
                   lt::alert_category::error | lt::alert_category::storage |
                       lt::alert_category::status);
  settings.set_int(lt::settings_pack::connections_limit, 100);
  settings.set_int(lt::settings_pack::upload_rate_limit, 1024 * 1024);
  settings.set_bool(lt::settings_pack::enable_dht, false);
  settings.set_bool(lt::settings_pack::enable_lsd, false);
  settings.set_bool(lt::settings_pack::enable_upnp, false);
  settings.set_bool(lt::settings_pack::enable_natpmp, false);
  session = std::make_unique<lt::session>(settings);
  session->set_alert_notify([] {
    uint64_t one = 1;
    const auto written = write(wake_fd, &one, sizeof one);
    (void)written; // EAGAIN means an alert wake is already pending.
  });
}
static void wake_engine() {
  if (!session) {
    create_engine();
    restore();
  }
}
static void sleep_engine() {
  if (!session)
    return;
  for (auto &[id, t] : transfers) {
    t.cached = t.status();
    t.cached_info = t.info();
    t.handle = {};
  }
  session->set_alert_notify({});
  session.reset();
}
static void request_save(Transfer &t) {
  if (t.handle.is_valid()) {
    ++saves[t.id];
    t.handle.save_resume_data(lt::torrent_handle::save_info_dict);
  }
}
static void finish_configuration(Transfer &t) {
  t.configuring = false;
  t.pending = false;
  t.requested_priorities.clear();
  t.handle.set_upload_limit(t.limit);
  t.handle.unset_flags(lt::torrent_flags::upload_mode);
  if (t.start_after_priority)
    t.handle.resume();
  persist(t);
  request_save(t);
}
static std::string hash_id(lt::info_hash_t const &h) {
  std::ostringstream out;
  if (h.has_v2())
    out << h.v2;
  else
    out << h.v1;
  return out.str();
}
static void atomic_write(std::string const &path, std::string const &data) {
  auto tmp = path + ".tmp";
  int fd = open(tmp.c_str(),
                O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0)
    throw std::runtime_error("Cannot save transfer state");
  size_t n = 0;
  while (n < data.size()) {
    auto r = write(fd, data.data() + n, data.size() - n);
    if (r <= 0) {
      close(fd);
      throw std::runtime_error("Cannot save transfer state");
    }
    n += size_t(r);
  }
  bool ok = fsync(fd) == 0;
  close(fd);
  if (!ok || rename(tmp.c_str(), path.c_str()))
    throw std::runtime_error("Cannot save transfer state");
}
static void persist(Transfer &t) {
  GKeyFile *key = g_key_file_new();
  g_key_file_set_string(key, "transfer", "source", t.source.c_str());
  g_key_file_set_string(key, "transfer", "destination", t.destination.c_str());
  g_key_file_set_string(key, "transfer", "publication", t.publication.c_str());
  g_key_file_set_boolean(key, "transfer", "pending", t.pending);
  g_key_file_set_boolean(key, "transfer", "published", t.published);
  g_key_file_set_integer(key, "transfer", "ratio", t.ratio);
  g_key_file_set_integer(key, "transfer", "limit", t.limit);
  gsize n;
  char *data = g_key_file_to_data(key, &n, nullptr);
  try {
    atomic_write(state_dir + "/" + t.id + ".ini", std::string(data, n));
  } catch (...) {
    g_free(data);
    g_key_file_unref(key);
    throw;
  }
  g_free(data);
  g_key_file_unref(key);
}
static void validate(lt::torrent_info const &info) {
  if (info.num_files() > int(max_files))
    throw std::runtime_error("This torrent exceeds the 512 file limit");
  auto const &files = info.files();
  for (auto i : files.file_range()) {
    fs::path path(files.file_path(i));
    if (path.is_absolute() || path.empty() ||
        (files.file_flags(i) & lt::file_storage::flag_symlink))
      throw std::runtime_error("Unsafe torrent file path");
    for (auto const &part : path)
      if (part == ".." || part == "." || part.empty())
        throw std::runtime_error("Unsafe torrent file path");
  }
}
static void add(std::string const &source, std::string const &destination) {
  if (transfers.size() >= max_torrents)
    throw std::runtime_error("Transfer limit reached (64)");
  if (destination.empty() || destination[0] != '/' ||
      !fs::is_directory(destination))
    throw std::runtime_error("Choose an existing absolute destination folder");
  lt::add_torrent_params p;
  lt::error_code ec;
  if (source.rfind("magnet:?", 0) == 0)
    p = lt::parse_magnet_uri(source, ec);
  else {
    if (source.empty() || source[0] != '/' || !fs::is_regular_file(source) ||
        fs::file_size(source) > 8 * 1024 * 1024)
      throw std::runtime_error("Choose a local torrent file (maximum 8 MiB)");
    p.ti = std::make_shared<lt::torrent_info>(source, ec);
    if (!ec) {
      validate(*p.ti);
      p.info_hashes = p.ti->info_hashes();
    }
  }
  if (ec)
    throw std::runtime_error(ec.message());
  auto id = hash_id(p.info_hashes);
  if (transfers.count(id))
    throw std::runtime_error("This torrent is already in Transfers");
  auto staging = fs::path(destination) / ".rediwm-partials" / id;
  // A private, exclusive staging directory avoids treating incomplete payloads
  // as ordinary files and prevents an existing file from being overwritten.
  auto parent = staging.parent_path();
  if (fs::exists(parent)) {
    struct stat st{};
    if (lstat(parent.c_str(), &st) || !S_ISDIR(st.st_mode) ||
        st.st_uid != getuid() || (st.st_mode & 077))
      throw std::runtime_error("Unsafe partial-download directory");
  } else if (mkdir(parent.c_str(), 0700))
    throw std::runtime_error("Cannot create partial-download directory");
  if (mkdir(staging.c_str(), 0700))
    throw std::runtime_error(
        "Partial data already exists; choose another destination");
  p.save_path = staging.string();
  p.flags &= ~lt::torrent_flags::auto_managed;
  p.flags |=
      lt::torrent_flags::upload_mode | lt::torrent_flags::duplicate_is_error;
  if (p.ti)
    p.file_priorities.assign(p.ti->num_files(), lt::dont_download);
  if (!p.ti)
    p.flags &= ~lt::torrent_flags::paused;
  auto handle = session->add_torrent(p, ec);
  if (ec) {
    fs::remove(staging);
    throw std::runtime_error(ec.message());
  }
  Transfer t{handle, id, source, destination};
  transfers.emplace(id, std::move(t));
  if (snapshot().size() > max_packet - 4096) {
    session->remove_torrent(handle);
    transfers.erase(id);
    throw std::runtime_error("Transfer metadata exceeds the session limit; "
                             "remove an unused transfer first");
  }
  persist(transfers.at(id));
  request_save(transfers.at(id));
}
static std::string string_member(JsonObject *o, char const *name) {
  auto node = json_object_get_member(o, name);
  if (!node || json_node_get_value_type(node) != G_TYPE_STRING)
    throw std::runtime_error("Missing string field");
  return json_node_get_string(node);
}
static void command(JsonObject *o) {
  auto op = string_member(o, "op");
  if (op == "list")
    return;
  wake_engine();
  if (op == "add") {
    add(string_member(o, "source"), string_member(o, "destination"));
    return;
  }
  if (op == "pause_all" || op == "stop_seeding") {
    for (auto &[id, t] : transfers)
      if (op == "pause_all" || t.status().is_finished) {
        t.resume_after_publish = false;
        t.start_after_priority = false;
        t.handle.pause();
        request_save(t);
      }
    return;
  }
  auto id = string_member(o, "id");
  auto it = transfers.find(id);
  if (it == transfers.end())
    throw std::runtime_error("Transfer no longer exists");
  auto &t = it->second;
  if (op == "remove") {
    session->remove_torrent(t.handle); // Never delete payloads.
    fs::remove(state_dir + "/" + id + ".ini");
    fs::remove(state_dir + "/" + id + ".resume");
    saves.erase(id);
    transfers.erase(it);
    return;
  }
  if (op == "pause") {
    t.resume_after_publish = false;
    t.start_after_priority = false;
    t.handle.pause();
  } else if (op == "resume") {
    if (t.pending)
      throw std::runtime_error("Choose files and start the download first");
    t.error.clear();
    t.handle.clear_error();
    t.handle.resume();
  } else if (op == "start") {
    auto info = t.info();
    if (!t.pending || !info || t.configuring)
      throw std::runtime_error("Waiting for torrent metadata");
    validate(*info);
    auto node = json_object_get_member(o, "files");
    if (!node || !JSON_NODE_HOLDS_ARRAY(node))
      throw std::runtime_error("Choose at least one file");
    auto arr = json_node_get_array(node);
    std::vector<lt::download_priority_t> priorities(info->num_files(),
                                                    lt::dont_download);
    bool any = false;
    for (guint i = 0; i < json_array_get_length(arr); ++i) {
      auto index = json_array_get_int_element(arr, i);
      if (index < 0 || index >= info->num_files())
        throw std::runtime_error("Invalid file index");
      priorities[size_t(index)] = lt::default_priority;
      any = true;
    }
    if (!any)
      throw std::runtime_error("Choose at least one file");
    t.ratio = int(json_object_get_int_member_with_default(o, "ratio", 1));
    t.limit = int(json_object_get_int_member_with_default(o, "limit", 1048576));
    if (t.ratio < 0 || t.ratio > 2 || t.limit < 16384 || t.limit > 10485760)
      throw std::runtime_error("Invalid seeding limits");
    // File priorities become effective asynchronously, after disk work. Keep
    // upload-only/paused until the matching alert, so unselected files never
    // briefly inherit the default download priority.
    t.configuring = true;
    t.start_after_priority = true;
    t.requested_priorities = priorities;
    t.handle.pause();
    if (t.handle.get_file_priorities() == priorities)
      finish_configuration(t);
    else
      t.handle.prioritize_files(priorities);
    return;
  } else
    throw std::runtime_error("Unknown command");
  persist(t);
  request_save(t);
}
static std::string display_name(std::string name) {
  if (name.size() > 512)
    name.resize(512);
  while (!name.empty() && !g_utf8_validate(name.c_str(), name.size(), nullptr))
    name.pop_back();
  return name;
}
static void member(JsonBuilder *b, char const *key, std::string const &v) {
  json_builder_set_member_name(b, key);
  json_builder_add_string_value(b, v.c_str());
}
static void number(JsonBuilder *b, char const *key, int64_t v) {
  json_builder_set_member_name(b, key);
  json_builder_add_int_value(b, v);
}
static void boolean(JsonBuilder *b, char const *key, bool v) {
  json_builder_set_member_name(b, key);
  json_builder_add_boolean_value(b, v);
}
static std::string encode(JsonBuilder *b) {
  auto root = json_builder_get_root(b);
  auto gen = json_generator_new();
  json_generator_set_root(gen, root);
  gsize n;
  char *raw = json_generator_to_data(gen, &n);
  std::string result(raw, n);
  g_free(raw);
  g_object_unref(gen);
  json_node_free(root);
  g_object_unref(b);
  return result;
}
static std::string snapshot() {
  auto b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "transfers");
  json_builder_begin_array(b);
  for (auto &[id, t] : transfers) {
    auto s = t.status();
    auto info = t.info();
    json_builder_begin_object(b);
    member(b, "id", id);
    member(b, "name",
           s.name.empty() ? "Fetching file list…" : display_name(s.name));
    member(b, "source", t.source);
    member(b, "download_directory", t.destination);
    member(b, "destination", t.published ? t.publication : t.destination);
    member(b, "storage", s.save_path);
    member(b, "error",
           t.error.empty() ? (s.errc ? s.errc.message() : "") : t.error);
    boolean(b, "pending", t.pending);
    boolean(b, "metadata", bool(info));
    boolean(b, "paused", bool(s.flags & lt::torrent_flags::paused));
    boolean(b, "finished", s.is_finished);
    boolean(b, "published", t.published);
    number(b, "progress", s.progress_ppm);
    number(b, "download_rate", s.download_payload_rate);
    number(b, "upload_rate", s.upload_payload_rate);
    number(b, "peers", s.num_peers);
    number(b, "known_peers", s.list_peers);
    number(b, "seeds", s.num_seeds);
    number(b, "total", s.total_wanted);
    number(b, "done", s.total_wanted_done);
    number(b, "ratio", t.ratio);
    number(b, "limit", t.limit);
    json_builder_set_member_name(b, "files");
    json_builder_begin_array(b);
    if (t.pending && t.error.empty() && info &&
        info->num_files() <= int(max_files))
      for (auto index : info->files().file_range()) {
        if (info->files().pad_file_at(index))
          continue;
        json_builder_begin_object(b);
        number(b, "index", int(index));
        member(b, "path", info->files().file_path(index));
        number(b, "size", info->files().file_size(index));
        json_builder_end_object(b);
      }
    json_builder_end_array(b);
    json_builder_end_object(b);
  }
  json_builder_end_array(b);
  json_builder_end_object(b);
  return encode(b);
}
static void send_error(int fd, std::string const &error) {
  auto b = json_builder_new();
  json_builder_begin_object(b);
  member(b, "error", error);
  json_builder_end_object(b);
  auto data = encode(b);
  (void)send(fd, data.data(), data.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
}
static void drop_peer(int fd) {
  auto it = peers.find(fd);
  if (it == peers.end())
    return;
  g_source_remove(it->second.source);
  close(fd);
  peers.erase(it);
}
static gboolean peer_ready(gint fd, GIOCondition condition, gpointer) {
  char data[max_packet];
  auto n = recv(fd, data, sizeof data, MSG_DONTWAIT | MSG_TRUNC);
  // On SOCK_SEQPACKET, closing with unread replies can report ECONNRESET
  // before the already queued requests. Consume the error, then drain them.
  if (n < 0 && (errno == ECONNRESET || errno == EINTR))
    return G_SOURCE_CONTINUE;
  if (n < 0 && errno == EAGAIN && !(condition & (G_IO_HUP | G_IO_ERR)))
    return G_SOURCE_CONTINUE;
  if (n <= 0 || size_t(n) >= sizeof data) {
    drop_peer(fd);
    schedule();
    return G_SOURCE_REMOVE;
  }
  auto parser = json_parser_new();
  GError *error = nullptr;
  try {
    if (!json_parser_load_from_data(parser, data, n, &error))
      throw std::runtime_error("Invalid transfer request");
    auto root = json_parser_get_root(parser);
    if (!JSON_NODE_HOLDS_OBJECT(root))
      throw std::runtime_error("Invalid request");
    command(json_node_get_object(root));
  } catch (std::exception const &e) {
    send_error(fd, e.what());
  }
  g_clear_error(&error);
  g_object_unref(parser);
  publish();
  schedule();
  return G_SOURCE_CONTINUE;
}
static gboolean accept_peer(gint fd, GIOCondition, gpointer) {
  int client = accept4(fd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
  if (client < 0)
    return G_SOURCE_CONTINUE;
  struct ucred cred{};
  socklen_t size = sizeof cred;
  if (peers.size() >= 32 ||
      getsockopt(client, SOL_SOCKET, SO_PEERCRED, &cred, &size) ||
      cred.uid != getuid()) {
    close(client);
    return G_SOURCE_CONTINUE;
  }
  int buffer = 512 * 1024;
  setsockopt(client, SOL_SOCKET, SO_SNDBUF, &buffer, sizeof buffer);
  peers.emplace(
      client,
      Peer{client,
           g_unix_fd_add(client, GIOCondition(G_IO_IN | G_IO_HUP | G_IO_ERR),
                         peer_ready, nullptr)});
  publish();
  schedule();
  return G_SOURCE_CONTINUE;
}
// Same transient scope contract as session/app_scope.zig and the terminal
// helper.
static void place_scope(pid_t pid, char const *app) {
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
static void init_tray() {
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
static void publish() {
  auto data = snapshot();
  std::vector<int> lost;
  for (auto const &[fd, p] : peers) {
    if (data.size() > max_packet) {
      lost.push_back(fd);
      continue;
    }
    const auto sent =
        send(fd, data.data(), data.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
    // A closed reader may still have queued commands (e.g. pause followed by
    // window close). Drain those through peer_ready before closing its fd.
    if (sent != ssize_t(data.size()) && errno != EPIPE && errno != ECONNRESET)
      lost.push_back(fd);
  }
  for (auto fd : lost)
    drop_peer(fd); // A stalled reader never blocks the engine.
  int active = 0, downloading = 0;
  int64_t down = 0, up = 0;
  for (auto &[id, t] : transfers) {
    auto s = t.status();
    if (!(s.flags & lt::torrent_flags::paused)) {
      ++active;
      if (!s.is_finished)
        ++downloading;
      down += s.download_payload_rate;
      up += s.upload_payload_rate;
    }
  }
  if (active && !bus)
    init_tray();
  auto status = active ? "Active" : "Passive";
  tray_title = std::to_string(active) + " active · ↓ " +
               std::to_string(down / 1024) + " KiB/s · ↑ " +
               std::to_string(up / 1024) + " KiB/s";
  const bool upload = active && !downloading;
  const bool icon_changed = tray_upload != upload;
  tray_upload = upload;
  if (bus) {
    if (icon_changed)
      g_dbus_connection_emit_signal(bus, nullptr, "/StatusNotifierItem",
                                    item_iface, "NewIcon", nullptr, nullptr);
    if (tray_status != status)
      g_dbus_connection_emit_signal(bus, nullptr, "/StatusNotifierItem",
                                    item_iface, "NewStatus",
                                    g_variant_new("(s)", status), nullptr);
    g_dbus_connection_emit_signal(bus, nullptr, "/StatusNotifierItem",
                                  item_iface, "NewToolTip", nullptr, nullptr);
  }
  tray_status = status;
}
static bool active() {
  for (auto &[id, t] : transfers)
    if (!(t.status().flags & lt::torrent_flags::paused) || t.moving ||
        t.configuring)
      return true;
  return false;
}
static void publish_storage(Transfer &t) {
  // Publish the entire private staging directory in one no-replace
  // rename. libtorrent's fail_if_exist has a check/rename race.
  auto s = t.status();
  auto name = fs::path(s.name).filename().string();
  if (name.empty() || name == "." || name == "..")
    name = t.id;
  name.resize(std::min<size_t>(name.size(), 160));
  while (!name.empty() && !g_utf8_validate(name.c_str(), name.size(), nullptr))
    name.pop_back();
  if (name.empty())
    name = t.id;
  t.publication = (fs::path(t.destination) / (name + ".download")).string();
  try {
    persist(t); // recovery knows both locations before the rename
    if (syscall(SYS_renameat2, AT_FDCWD, s.save_path.c_str(), AT_FDCWD,
                t.publication.c_str(), RENAME_NOREPLACE))
      throw std::runtime_error("Destination already exists or cannot be "
                               "written; partial files are kept");
    t.handle.move_storage(t.publication,
                          lt::move_flags_t::reset_save_path_unchecked);
  } catch (std::exception const &e) {
    t.moving = false;
    t.error = e.what();
    t.handle.pause();
    request_save(t);
  }
}
static void maintain() {
  if (!session)
    return;
  for (auto &[id, t] : transfers) {
    auto s = t.status();
    if (!t.pending && s.is_finished && !t.published && !t.moving &&
        t.error.empty()) {
      t.moving = true;
      t.resume_after_publish =
          !(s.flags & lt::torrent_flags::paused) && t.ratio != 0;
      if (s.flags & lt::torrent_flags::paused)
        publish_storage(t);
      else
        t.handle.pause();
    }
    if (!t.pending && s.is_finished && !(s.flags & lt::torrent_flags::paused) &&
        (t.ratio == 0 ||
         s.all_time_upload >= std::max<int64_t>(s.total_wanted, 1) * t.ratio)) {
      t.resume_after_publish = false;
      t.handle.pause();
      request_save(t);
    }
  }
}
static gboolean tick(gpointer) {
  ++ticks;
  if (ticks % 30 == 0)
    for (auto &[id, t] : transfers)
      if (t.handle.is_valid() && t.handle.need_save_resume_data())
        request_save(t);
  maintain();
  publish();
  if (!active()) {
    ticker = 0;
    schedule();
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}
static void schedule() {
  if (session && active()) {
    lt::settings_pack settings;
    settings.set_bool(lt::settings_pack::enable_dht, true);
    settings.set_bool(lt::settings_pack::enable_lsd, true);
    session->apply_settings(settings);
  }
  if (!active() && saves.empty())
    sleep_engine();
  if (active() && !ticker)
    ticker = g_timeout_add_seconds(1, tick, nullptr);
  if (quitting && saves.empty())
    g_main_loop_quit(loop);
  // Let a concurrently opening Files window finish its connection before
  // retiring a stopped session. This is one deadline, never an idle poll.
  if (!starting && !active() && peers.empty() && saves.empty() && !idle_exit)
    idle_exit = g_timeout_add(
        250,
        [](gpointer) -> gboolean {
          idle_exit = 0;
          if (!active() && peers.empty() && saves.empty())
            g_main_loop_quit(loop);
          return G_SOURCE_REMOVE;
        },
        nullptr);
}
static gboolean alerts(gint, GIOCondition, gpointer) {
  uint64_t value;
  while (read(wake_fd, &value, sizeof value) > 0) {
  }
  if (!session)
    return G_SOURCE_CONTINUE;
  std::vector<lt::alert *> events;
  session->pop_alerts(&events);
  for (auto alert : events) {
    auto ta = dynamic_cast<lt::torrent_alert *>(alert);
    if (!ta)
      continue;
    Transfer *t = nullptr;
    for (auto &[id, item] : transfers)
      if (item.handle == ta->handle) {
        t = &item;
        break;
      }
    if (!t)
      continue;
    try {
      if (auto a = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
        auto bytes = lt::write_resume_data_buf(a->params);
        atomic_write(state_dir + "/" + t->id + ".resume",
                     std::string(bytes.data(), bytes.size()));
        saved(t->id);
      }
      if (lt::alert_cast<lt::save_resume_data_failed_alert>(alert))
        saved(t->id);
      if (t->configuring && lt::alert_cast<lt::file_prio_alert>(alert) &&
          t->handle.get_file_priorities() == t->requested_priorities) {
        finish_configuration(*t);
      }
      if (t->pending && lt::alert_cast<lt::metadata_received_alert>(alert)) {
        t->handle.pause();
        validate(*t->info());
        if (snapshot().size() > max_packet - 4096)
          throw std::runtime_error(
              "File list exceeds the session metadata limit");
        request_save(*t);
      }
      if (t->moving && lt::alert_cast<lt::torrent_paused_alert>(alert))
        publish_storage(*t);
      if (lt::alert_cast<lt::storage_moved_alert>(alert)) {
        t->moving = false;
        t->published = true;
        if (t->resume_after_publish)
          t->handle.resume();
        persist(*t);
        request_save(*t);
        if (bus)
          g_dbus_connection_call(
              bus, "org.freedesktop.Notifications",
              "/org/freedesktop/Notifications", "org.freedesktop.Notifications",
              "Notify",
              g_variant_new(
                  "(susss@as@a{sv}i)", "Files", 0u, "folder-download",
                  "Download complete", t->status().name.c_str(),
                  g_variant_new_strv(nullptr, 0),
                  g_variant_new_array(G_VARIANT_TYPE("{sv}"), nullptr, 0), -1),
              nullptr, G_DBUS_CALL_FLAGS_NO_AUTO_START, 2000, nullptr, nullptr,
              nullptr);
      }
      if (auto a = lt::alert_cast<lt::storage_moved_failed_alert>(alert)) {
        t->moving = false;
        t->error = "Could not publish download: " + a->error.message();
        t->handle.pause();
        request_save(*t);
      }
    } catch (std::exception const &e) {
      t->error = e.what();
      t->handle.pause();
      saved(t->id);
    }
  }
  maintain();
  publish();
  schedule();
  return G_SOURCE_CONTINUE;
}
static gboolean stop(gpointer) {
  quitting = true;
  for (auto &[id, t] : transfers)
    request_save(t);
  schedule();
  g_timeout_add_seconds(
      5,
      [](gpointer) -> gboolean {
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
      },
      nullptr);
  return G_SOURCE_REMOVE;
}
static void restore() {
  for (auto const &entry : fs::directory_iterator(state_dir)) {
    if (entry.path().extension() != ".ini" || transfers.size() >= max_torrents)
      continue;
    try {
      auto id = entry.path().stem().string();
      if (id.size() != 40 && id.size() != 64)
        continue;
      auto key = g_key_file_new();
      if (!g_key_file_load_from_file(key, entry.path().c_str(), G_KEY_FILE_NONE,
                                     nullptr)) {
        g_key_file_unref(key);
        continue;
      }
      auto get = [&](char const *name) {
        char *p = g_key_file_get_string(key, "transfer", name, nullptr);
        std::string s = p ? p : "";
        g_free(p);
        return s;
      };
      Transfer t;
      t.id = id;
      t.source = get("source");
      t.destination = get("destination");
      t.publication = get("publication");
      t.pending = g_key_file_get_boolean(key, "transfer", "pending", nullptr);
      t.published =
          g_key_file_get_boolean(key, "transfer", "published", nullptr);
      t.ratio = g_key_file_get_integer(key, "transfer", "ratio", nullptr);
      t.limit = g_key_file_get_integer(key, "transfer", "limit", nullptr);
      g_key_file_unref(key);
      auto path = state_dir + "/" + id + ".resume";
      if (!fs::exists(path) || fs::file_size(path) > 16 * 1024 * 1024)
        continue;
      std::ifstream file(path, std::ios::binary);
      std::vector<char> data((std::istreambuf_iterator<char>(file)), {});
      lt::error_code ec;
      auto p = lt::read_resume_data(data, ec);
      if (ec)
        continue;
      if (p.ti)
        validate(*p.ti);
      // A crash between atomic publication and the next resume alert must
      // not redownload into the now-missing staging directory.
      if (!t.publication.empty() && !fs::exists(p.save_path) &&
          fs::is_directory(t.publication)) {
        p.save_path = t.publication;
        t.published = true;
      }
      p.flags &= ~lt::torrent_flags::auto_managed;
      if (t.pending) {
        p.flags |= lt::torrent_flags::upload_mode;
        if (p.ti)
          p.flags |= lt::torrent_flags::paused;
      }
      create_engine();
      t.handle = session->add_torrent(p, ec);
      if (!ec)
        transfers.insert_or_assign(id, std::move(t));
    } catch (std::exception const &e) {
      std::cerr << "Restore transfer: " << e.what() << '\n';
    }
  }
}
int main(int argc, char **argv) {
  umask(0077);
  signal(SIGPIPE, SIG_IGN);
  try {
    if (getuid() == 0)
      throw std::runtime_error("Transfers must run as a user");
    const char *runtime = getenv("XDG_RUNTIME_DIR");
    if (!runtime)
      throw std::runtime_error("Missing runtime directory");
    struct stat st{};
    if (lstat(runtime, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
        (st.st_mode & 077))
      throw std::runtime_error("Runtime directory is not private");
    auto socket_path = std::string(runtime) + "/files-transfers.sock";
    auto lock_path = socket_path + ".lock";
    int lock = open(lock_path.c_str(),
                    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock < 0 || flock(lock, LOCK_EX | LOCK_NB))
      return 0;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (socket_path.size() >= sizeof address.sun_path)
      throw std::runtime_error("Runtime path too long");
    strcpy(address.sun_path, socket_path.c_str());
    int listener =
        socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    unlink(socket_path.c_str());
    if (bind(listener, reinterpret_cast<sockaddr *>(&address),
             sizeof address) ||
        listen(listener, 16))
      throw std::runtime_error("Cannot listen for Files");
    const char *state = getenv("XDG_STATE_HOME");
    const char *home = getenv("HOME");
    state_dir =
        std::string(state ? state : (home ? home : "")) +
        (state ? "/rediwm/transfers" : "/.local/state/rediwm/transfers");
    fs::create_directories(state_dir);
    struct stat state_stat{};
    if (lstat(state_dir.c_str(), &state_stat) || !S_ISDIR(state_stat.st_mode) ||
        state_stat.st_uid != getuid() || (state_stat.st_mode & 077))
      throw std::runtime_error("Transfer state directory is not private");
    executable =
        (fs::canonical("/proc/self/exe").parent_path() / "rediwm-files")
            .string();
    // Scope policy is supplied by the Files launcher, which uses the same
    // native/nested rules as its other user-app launches.
    use_scopes = argc > 1 && !strcmp(argv[1], "--scope");
    place_scope(getpid(), "transfers");
    loop = g_main_loop_new(nullptr, false);
    wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    g_unix_fd_add(wake_fd, G_IO_IN, alerts, nullptr);
    g_unix_fd_add(listener, G_IO_IN, accept_peer, nullptr);
    g_unix_signal_add(SIGTERM, stop, nullptr);
    g_unix_signal_add(SIGINT, stop, nullptr);
    restore();
    if (active())
      ticker = g_timeout_add_seconds(1, tick, nullptr);
    // Allow the spawning window time to connect; no recurring idle timer.
    g_timeout_add_seconds(
        5,
        [](gpointer) -> gboolean {
          starting = false;
          schedule();
          return G_SOURCE_REMOVE;
        },
        nullptr);
    g_main_loop_run(loop);
    sleep_engine();
    close(wake_fd);
    close(listener);
    unlink(socket_path.c_str());
    close(lock);
    g_main_loop_unref(loop);
  } catch (std::exception const &e) {
    std::cerr << "Transfers: " << e.what() << '\n';
    return 1;
  }
}
