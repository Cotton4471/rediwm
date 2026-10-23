//! Installed data: portals, sessions, polkit policy, wallpapers and cursors.

const std = @import("std");
const Context = @import("context.zig").Context;
const support = @import("support.zig");
const localizedData = support.localizedData;

/// Portal and session files, policies, wallpapers and the generated cursor themes.
pub fn add(ctx: Context) void {
    const b = ctx.b;
    const use_llvm = ctx.use_llvm;
    const i18n_tool = ctx.i18n_tool;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("data/rediwm-portals.conf"),
        .prefix,
        "share/xdg-desktop-portal/rediwm-portals.conf",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("data/rediwm.portal"),
        .prefix,
        "share/xdg-desktop-portal/portals/rediwm.portal",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path("data/xdg-desktop-portal-wlr.ini"),
        .prefix,
        "share/xdg-desktop-portal-wlr/config",
    ).step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        localizedData(b, i18n_tool, "data/rediwm.desktop"),
        .prefix,
        "share/wayland-sessions/rediwm.desktop",
    ).step);

    b.getInstallStep().dependOn(&b.addInstallFileWithDir(localizedData(b, i18n_tool, "data/org.rediwm.accounts.policy"), .prefix, "share/polkit-1/actions/org.rediwm.accounts.policy").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(localizedData(b, i18n_tool, "data/rediwm-release-safe.desktop"), .prefix, "share/wayland-sessions/rediwm-release-safe.desktop").step);

    // Wallpapers, found at runtime through share/rediwm/wallpapers next to
    // the binaries (wallpapers.zig); `[compositor] wallpaper` picks one.
    b.installDirectory(.{
        .source_dir = b.path("assets/wallpapers"),
        .install_dir = .prefix,
        .install_subdir = "share/rediwm/wallpapers",
    });

    // Xcursor themes rendered from the vendored phinger-cursors SVGs. They
    // land in share/icons next to the binaries; the compositor adds that
    // directory to XCURSOR_PATH for itself and its children.
    const cursorgen = b.addExecutable(.{
        .name = "rediwm-cursorgen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cursor_theme_gen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .link_libc = true,
        }),
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });
    cursorgen.root_module.linkSystemLibrary("librsvg-2.0", .{});
    cursorgen.root_module.linkSystemLibrary("cairo", .{});
    const cursorgen_run = b.addRunArtifact(cursorgen);
    cursorgen_run.addDirectoryArg(b.path("assets/cursors"));
    const cursor_themes = cursorgen_run.addOutputDirectoryArg("icons");
    // Cursor aliases are symlinks, which InstallDir drops; cp -a keeps them.
    const install_cursors = b.addSystemCommand(&.{ "sh", "-c", "mkdir -p \"$2\" && cp -a -T \"$1\" \"$2\"", "sh" });
    install_cursors.addDirectoryArg(cursor_themes);
    install_cursors.addArg(b.getInstallPath(.prefix, "share/icons"));
    b.getInstallStep().dependOn(&install_cursors.step);
}
