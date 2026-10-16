const std = @import("std");
const protocol = @import("protocol");
const msg_cli = @import("msg_cli.zig");
const msg_doctor = @import("msg_doctor.zig");
const msg_reply = @import("msg_reply.zig");
const msg_usage = @import("msg_usage.zig");
pub const CliOptions = msg_cli.CliOptions;
pub const Command = msg_cli.Command;
pub const parseButtonNameOrInt = msg_cli.parseButtonNameOrInt;
pub const usageError = msg_cli.usageError;
pub const parseAnimMs = msg_cli.parseAnimMs;
pub const FlagParser = msg_cli.FlagParser;
pub const sendDoctorQuery = msg_doctor.sendDoctorQuery;
pub const nowUs = msg_doctor.nowUs;
pub const runDoctor = msg_doctor.runDoctor;
pub const printUnwrappedJson = msg_reply.printUnwrappedJson;
pub const printJsonValue = msg_reply.printJsonValue;
pub const printOut = msg_reply.printOut;
pub const printTextReply = msg_reply.printTextReply;
pub const local_commands = msg_usage.local_commands;
pub const TopCommandTag = msg_usage.TopCommandTag;
pub const lookupTopCommand = msg_usage.lookupTopCommand;
pub const printUsage = msg_usage.printUsage;
pub const printCommandHelp = msg_usage.printCommandHelp;

pub fn closeFd(fd: std.posix.fd_t) void {
    _ = std.c.close(fd);
}

pub fn getEnv(key: [*:0]const u8) ?[]const u8 {
    if (std.c.getenv(key)) |ptr| {
        return std.mem.span(ptr);
    }
    return null;
}

pub fn main(init: std.process.Init) void {
    const allocator = std.heap.c_allocator;

    runMsg(init, allocator) catch |err| {
        std.debug.print("error: {}\n", .{err});
        std.process.exit(1);
    };
}

pub fn runMsg(init: std.process.Init, allocator: std.mem.Allocator) !void {
    const raw_args = init.minimal.args.vector;
    if (raw_args.len < 2) {
        printUsage();
        std.process.exit(1);
    }

    var opts = CliOptions{};
    var arg_idx: usize = 1;
    const cli: FlagParser = .{ .args = raw_args, .idx = &arg_idx, .opts = &opts, .allocator = allocator };

    // Parse options and subcommand
    while (arg_idx < raw_args.len) {
        const arg = std.mem.span(raw_args[arg_idx]);
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
            arg_idx += 1;
        } else if (std.mem.eql(u8, arg, "--timeout") or std.mem.eql(u8, arg, "-t")) {
            arg_idx += 1;
            if (arg_idx >= raw_args.len) {
                std.debug.print("error: --timeout requires milliseconds\n", .{});
                std.process.exit(1);
            }
            opts.timeout_ms = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch null;
            arg_idx += 1;
        } else if (std.mem.eql(u8, arg, "--raw")) {
            arg_idx += 1;
            if (arg_idx < raw_args.len and !std.mem.startsWith(u8, std.mem.span(raw_args[arg_idx]), "-")) {
                opts.command = .{ .raw = std.mem.span(raw_args[arg_idx]) };
                arg_idx += 1;
            } else {
                var stdin_buf = std.ArrayList(u8).empty;
                var in_chunk: [4096]u8 = undefined;
                while (true) {
                    const nr = std.posix.system.read(std.posix.STDIN_FILENO, &in_chunk, in_chunk.len);
                    if (nr <= 0) break;
                    try stdin_buf.appendSlice(allocator, in_chunk[0..@intCast(nr)]);
                }
                opts.command = .{ .raw = stdin_buf.items };
            }
        } else if (std.mem.eql(u8, arg, "--socket") or std.mem.eql(u8, arg, "-s")) {
            arg_idx += 1;
            if (arg_idx >= raw_args.len) {
                std.debug.print("error: --socket requires a path\n", .{});
                std.process.exit(1);
            }
            opts.socket_path = std.mem.span(raw_args[arg_idx]);
            arg_idx += 1;
        } else if (opts.command == null) {
            const tag = lookupTopCommand(arg) orelse {
                std.debug.print("error: unknown command '{s}'\n", .{arg});
                std.process.exit(1);
            };
            switch (tag) {
                .raw => {
                    arg_idx += 1;
                    if (arg_idx < raw_args.len and !std.mem.eql(u8, std.mem.span(raw_args[arg_idx]), "-")) {
                        opts.command = .{ .raw = std.mem.span(raw_args[arg_idx]) };
                        arg_idx += 1;
                    } else {
                        var stdin_buf = std.ArrayList(u8).empty;
                        var in_chunk: [4096]u8 = undefined;
                        while (true) {
                            const nr = std.posix.system.read(std.posix.STDIN_FILENO, &in_chunk, in_chunk.len);
                            if (nr <= 0) break;
                            try stdin_buf.appendSlice(allocator, in_chunk[0..@intCast(nr)]);
                        }
                        opts.command = .{ .raw = stdin_buf.items };
                    }
                },
                .get_state => {
                    opts.command = .state;
                    arg_idx += 1;
                },
                .describe_ipc => {
                    opts.command = .describe;
                    arg_idx += 1;
                },
                .doctor => {
                    opts.command = .doctor;
                    arg_idx += 1;
                },
                .get_window_debug => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: window-debug requires <window_id>\n", .{});
                        std.process.exit(1);
                    }
                    const wid = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid window id\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    opts.command = .{ .window_debug = .{ .id = wid } };
                },
                .get_window_rules => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: window-rules requires <window_id>\n", .{});
                        std.process.exit(1);
                    }
                    const wid = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid window id\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    opts.command = .{ .window_rules = .{ .id = wid } };
                },
                .match_window_rules => {
                    arg_idx += 1;
                    opts.command = cli.command(.match_window_rules, .{
                        .app_id,
                        .title,
                        .{ .field = "x11_class", .names = .{"--class"} },
                        .{ .field = "x11_instance", .names = .{"--instance"} },
                        .backend,
                        .dialog,
                    }, .{});
                },
                .get_night_light => {
                    opts.command = .night_light;
                    arg_idx += 1;
                },
                .get_notifications => {
                    opts.command = .notifications;
                    arg_idx += 1;
                },
                .get_shell_state => {
                    arg_idx += 1;
                    opts.command = cli.command(.shell_state, .{.output}, .{});
                },
                .get_keyboard_layouts => {
                    opts.command = .keyboard_layouts;
                    arg_idx += 1;
                },
                .switch_layout => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) return error.InvalidArguments;
                    const value = std.mem.span(raw_args[arg_idx]);
                    opts.command = .{ .switch_layout = if (std.ascii.eqlIgnoreCase(value, "next")) .next else if (std.ascii.eqlIgnoreCase(value, "prev")) .prev else .{ .index = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArguments } };
                    arg_idx += 1;
                },
                .get_text_input => {
                    opts.command = .text_input;
                    arg_idx += 1;
                },
                .get_input_state => {
                    opts.command = .input_state;
                    arg_idx += 1;
                },
                .hit_test => {
                    arg_idx += 1;
                    if (arg_idx + 1 >= raw_args.len) {
                        std.debug.print("error: hit-test requires <x> <y>\n", .{});
                        std.process.exit(1);
                    }
                    const x = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid x coordinate\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    const y = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch {
                        std.debug.print("error: invalid y coordinate\n", .{});
                        std.process.exit(1);
                    };
                    arg_idx += 1;
                    opts.command = cli.command(.hit_test, .{.output}, .{ .x = x, .y = y });
                },
                .get_scene_tree => {
                    arg_idx += 1;
                    opts.command = cli.command(.scene_tree, .{.max_depth}, .{});
                },
                .get_layer_surfaces => {
                    opts.command = .layers;
                    arg_idx += 1;
                },
                .list_panels => {
                    opts.command = .panels;
                    arg_idx += 1;
                },
                .get_widget_tree => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: widget-tree requires <panel>\n", .{});
                        std.process.exit(1);
                    }
                    const panel = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = .{ .widget_tree = .{ .panel = panel } };
                },
                .get_config_status => {
                    opts.command = .config;
                    arg_idx += 1;
                },
                .get_runtime_info => {
                    opts.command = .runtime;
                    arg_idx += 1;
                },
                .get_performance_stats => {
                    opts.command = .perf;
                    arg_idx += 1;
                },
                .reset_performance_stats => {
                    opts.command = .perf_reset;
                    arg_idx += 1;
                },
                .wait_for => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: wait requires <condition>\n", .{});
                        std.process.exit(1);
                    }
                    const cond = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = cli.command(.wait, .{
                        .{ .field = "timeout_ms", .names = .{"--timeout"} },
                        .{ .field = "window_id", .names = .{"--id"} },
                        .output,
                    }, .{ .condition = cond });
                },
                .wait_for_frame => {
                    arg_idx += 1;
                    opts.command = cli.command(.wait_frame, .{ .output, .{ .field = "timeout_ms", .names = .{"--timeout"} } }, .{});
                },
                .dump_buffer => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: dump-buffer requires <target>\n", .{});
                        std.process.exit(1);
                    }
                    const tgt = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = cli.command(.dump_buffer, .{ .{ .field = "window_id", .names = .{"--id"} }, .output }, .{ .target = tgt });
                },
                .sample_pixels => {
                    arg_idx += 1;
                    if (arg_idx + 3 >= raw_args.len) {
                        std.debug.print("error: sample-pixels requires <x> <y> <width> <height>\n", .{});
                        std.process.exit(1);
                    }
                    const x = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    const y = std.fmt.parseInt(i32, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    const w = std.fmt.parseInt(u32, std.mem.span(raw_args[arg_idx]), 10) catch 1;
                    arg_idx += 1;
                    const h = std.fmt.parseInt(u32, std.mem.span(raw_args[arg_idx]), 10) catch 1;
                    arg_idx += 1;
                    opts.command = cli.command(.sample_pixels, .{.output}, .{ .x = x, .y = y, .width = w, .height = h });
                },
                .set_output_config => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) return error.MissingOutput;
                    var patch = protocol.OutputConfigPatch{ .output = std.mem.span(raw_args[arg_idx]) };
                    arg_idx += 1;
                    while (arg_idx < raw_args.len) : (arg_idx += 1) {
                        const option = std.mem.span(raw_args[arg_idx]);
                        if (std.mem.eql(u8, option, "--json")) {
                            opts.json = true;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--enabled")) {
                            patch.enabled = true;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--disabled")) {
                            patch.enabled = false;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--primary")) {
                            patch.primary = true;
                            continue;
                        }
                        if (std.mem.eql(u8, option, "--no-primary")) {
                            patch.primary = false;
                            continue;
                        }
                        if (arg_idx + 1 >= raw_args.len) return error.MissingOptionValue;
                        arg_idx += 1;
                        const value = std.mem.span(raw_args[arg_idx]);
                        if (std.mem.eql(u8, option, "--scale")) {
                            if (std.mem.eql(u8, value, "auto")) {
                                patch.auto_scale = true;
                            } else {
                                patch.scale = try std.fmt.parseFloat(f32, value);
                            }
                        } else if (std.mem.eql(u8, option, "--position")) {
                            if (!std.mem.eql(u8, value, "auto")) return error.InvalidPosition;
                            patch.auto_position = true;
                        } else if (std.mem.eql(u8, option, "--transform")) {
                            patch.transform = protocol.parseOutputTransform(value) catch return error.InvalidTransform;
                        } else {
                            var matched = false;
                            inline for (.{ "width", "height", "refresh_mhz", "x", "y" }, .{ "--width", "--height", "--refresh-mhz", "--x", "--y" }) |field, flag| {
                                if (std.mem.eql(u8, option, flag)) {
                                    @field(patch, field) = try std.fmt.parseInt(i32, value, 10);
                                    matched = true;
                                }
                            }
                            if (!matched) return error.UnknownOutputOption;
                        }
                    }
                    try patch.validate();
                    opts.command = .{ .output_config = patch };
                },
                .maximize_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: maximize requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .maximize = .{ .id = id } };
                },
                .minimize_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: minimize requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .minimize = .{ .id = id } };
                },
                .restore_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: restore requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .restore = .{ .id = id } };
                },
                .fullscreen_window => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: fullscreen requires <id>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    opts.command = .{ .fullscreen = .{ .id = id } };
                },
                .set_window_zoom => {
                    arg_idx += 1;
                    if (arg_idx + 1 >= raw_args.len) {
                        std.debug.print("error: set-zoom requires <id> <percent>\n", .{});
                        std.process.exit(1);
                    }
                    const id = std.fmt.parseInt(u64, std.mem.span(raw_args[arg_idx]), 10) catch 0;
                    arg_idx += 1;
                    const pct = std.fmt.parseInt(u8, std.mem.span(raw_args[arg_idx]), 10) catch 100;
                    arg_idx += 1;
                    opts.command = .{ .set_zoom = .{ .id = id, .percent = pct } };
                },
                .close_panel => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: close-panel requires <panel>\n", .{});
                        std.process.exit(1);
                    }
                    const panel = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = .{ .close_panel = .{ .panel = panel } };
                },
                .reload_config => {
                    opts.command = .reload;
                    arg_idx += 1;
                },
                .launch_app => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: launch requires <desktop_id>\n", .{});
                        std.process.exit(1);
                    }
                    const did = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;
                    opts.command = .{ .launch = .{ .desktop_id = did } };
                },
                .version => {
                    opts.command = .version;
                    arg_idx += 1;
                },
                .capabilities => {
                    opts.command = .capabilities;
                    arg_idx += 1;
                },
                .windows => {
                    opts.command = .windows;
                    arg_idx += 1;
                },
                .outputs => {
                    opts.command = .outputs;
                    arg_idx += 1;
                },
                .focused_window => {
                    opts.command = .focused_window;
                    arg_idx += 1;
                },
                .workspaces => {
                    opts.command = .workspaces;
                    arg_idx += 1;
                },
                .event_stream => {
                    arg_idx += 1;
                    opts.command = cli.command(.event_stream, .{ .events, .{ .field = "window_id", .names = .{"--window"} }, .output }, .{});
                },
                .action => {
                    arg_idx += 1;
                    if (arg_idx >= raw_args.len) {
                        std.debug.print("error: action requires a subcommand\n", .{});
                        std.process.exit(1);
                    }
                    const act_cmd = std.mem.span(raw_args[arg_idx]);
                    arg_idx += 1;

                    const action_tag = protocol.commands.lookupCli(true, act_cmd) orelse {
                        std.debug.print("error: unknown action '{s}'\n", .{act_cmd});
                        std.process.exit(1);
                    };
                    switch (action_tag) {
                        .focus_window => {
                            opts.command = cli.command(.focus_window, .{.{ .field = "id", .bare = true }}, .{}) orelse
                                usageError("focus-window requires --id <u64>");
                        },
                        .close_window => {
                            opts.command = cli.command(.close_window, .{.{ .field = "id", .bare = true }}, .{});
                        },
                        .move_window_to => {
                            const cmd = cli.command(.move_window_to, .{ .id, .x, .y, .output }, .{});
                            const move = if (cmd) |c| c.move_window_to else null;
                            if (move == null or ((move.?.x == null or move.?.y == null) and move.?.output == null))
                                usageError("move-window-to requires --id <id> plus --x/--y or --output <output>");
                            opts.command = cmd;
                        },
                        .spawn => {
                            if (arg_idx < raw_args.len and std.mem.eql(u8, std.mem.span(raw_args[arg_idx]), "--")) {
                                arg_idx += 1;
                            }
                            var argv_list = std.ArrayList([]const u8).empty;
                            while (arg_idx < raw_args.len) : (arg_idx += 1) {
                                const a = std.mem.span(raw_args[arg_idx]);
                                if (std.mem.eql(u8, a, "--json") and argv_list.items.len == 0) {
                                    opts.json = true;
                                } else {
                                    try argv_list.append(allocator, a);
                                }
                            }
                            if (argv_list.items.len == 0) {
                                std.debug.print("error: spawn requires a command\n", .{});
                                std.process.exit(1);
                            }
                            opts.command = .{ .spawn = .{ .argv = argv_list.items } };
                        },
                        .move_cursor => {
                            opts.command = cli.command(.move_cursor, .{ .x, .y, .output }, .{}) orelse
                                usageError("move-cursor requires --x <x> --y <y>");
                        },
                        .move_cursor_relative => {
                            opts.command = cli.command(.move_cursor_relative, .{ .dx, .dy }, .{}) orelse
                                usageError("move-cursor-relative requires --dx <dx> --dy <dy>");
                        },
                        .pointer_button => {
                            opts.command = cli.command(.pointer_button, .{ .{ .field = "button", .parse = parseButtonNameOrInt }, .pressed }, .{}) orelse
                                usageError("pointer-button requires --button <button> --pressed <true|false>");
                        },
                        .click => {
                            opts.command = cli.command(.click, .{.{ .field = "button", .parse = parseButtonNameOrInt }}, .{});
                        },
                        .scroll => {
                            opts.command = cli.command(.scroll, .{ .dx, .dy }, .{});
                        },
                        .key => {
                            opts.command = cli.command(.key, .{ .keycode, .pressed }, .{}) orelse
                                usageError("key requires --keycode <keycode> --pressed <true|false>");
                        },
                        .key_press => {
                            opts.command = cli.command(.key_press, .{.{ .field = "key", .bare = true }}, .{}) orelse
                                usageError("key-press requires --key <keyname>");
                        },
                        .type_text => {
                            opts.command = cli.command(.type_text, .{.{ .field = "text", .bare = true }}, .{}) orelse
                                usageError("type-text requires --text <text>");
                        },
                        .drag => {
                            opts.command = cli.command(.drag, .{
                                .from_x,
                                .from_y,
                                .to_x,
                                .to_y,
                                .{ .field = "button", .parse = parseButtonNameOrInt },
                                .output,
                            }, .{}) orelse usageError("drag requires --from-x <x> --from-y <y> --to-x <x> --to-y <y>");
                        },
                        .screenshot => {
                            opts.command = cli.command(.screenshot, .{
                                .{ .field = "output", .names = .{ "--output", "-o" } },
                                .{ .field = "window_id", .names = .{ "--window", "--window-id", "--id", "-w" } },
                                .{ .field = "mode", .names = .{ "--mode", "-m" } },
                                .{ .field = "include_cursor", .presence = true },
                                .path,
                                .{ .field = "save_path", .names = .{"--save"}, .cli = true },
                            }, .{});
                        },
                        .set_master_volume => {
                            opts.command = cli.command(.set_master_volume, .{.volume}, .{}) orelse
                                usageError("set-master-volume requires --volume <0.0-1.0>");
                        },
                        .toggle_mute => {
                            cli.rest();
                            opts.command = .toggle_mute;
                        },
                        .set_app_volume => {
                            opts.command = cli.command(.set_app_volume, .{ .index, .volume }, .{}) orelse
                                usageError("set-app-volume requires --index <N> --volume <0.0-1.0>");
                        },
                        .set_app_mute => {
                            opts.command = cli.command(.set_app_mute, .{ .index, .muted }, .{}) orelse
                                usageError("set-app-mute requires --index <N> --muted <true|false>");
                        },
                        .get_audio_state => {
                            cli.rest();
                            opts.command = .get_audio_state;
                        },
                        .get_panel_stats => {
                            cli.rest();
                            opts.command = .get_panel_stats;
                        },
                        .reset_panel_stats => {
                            opts.command = .reset_panel_stats;
                        },
                        .set_anim_time => {
                            opts.command = cli.command(.set_anim_time, .{.{ .field = "ms", .parse = parseAnimMs }}, .{}) orelse
                                usageError("set-anim-time requires --ms <N|null>");
                        },
                        .open_start_menu => {
                            opts.command = .open_start_menu;
                        },
                        .open_control_center => {
                            opts.command = .open_control_center;
                        },
                        .open_power_menu => {
                            opts.command = .open_power_menu;
                        },
                    }
                },
            }
        } else {
            arg_idx += 1;
        }
    }

    const command = opts.command orelse {
        printUsage();
        std.process.exit(1);
    };

    const socket_path = opts.socket_path orelse getEnv("REDIWM_SOCKET") orelse blk: {
        if (getEnv("XDG_RUNTIME_DIR")) |xdg_dir| {
            if (getEnv("WAYLAND_DISPLAY")) |display| {
                break :blk try std.fmt.allocPrint(allocator, "{s}/rediwm-{s}.sock", .{ xdg_dir, display });
            }
        }
        // rediwm never listens in a shared directory, where another user could plant a socket.
        usageError("no IPC socket: set REDIWM_SOCKET, or XDG_RUNTIME_DIR and WAYLAND_DISPLAY");
    };

    if (command == .doctor) {
        try runDoctor(socket_path, allocator, opts.json);
        return;
    }

    const c = std.posix.system;

    const sock_type = std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC;
    const sock_fd = c.socket(std.posix.AF.UNIX, sock_type, 0);
    if (sock_fd < 0) {
        std.debug.print("error: could not create socket\n", .{});
        std.process.exit(1);
    }
    defer closeFd(sock_fd);

    var addr: std.posix.sockaddr.un = .{ .family = std.posix.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    if (socket_path.len >= 107) {
        std.debug.print("error: socket path too long: {s}\n", .{socket_path});
        std.process.exit(1);
    }
    @memcpy(addr.path[0..socket_path.len], socket_path);
    const addr_len = @as(std.posix.socklen_t, @intCast(@offsetOf(std.posix.sockaddr.un, "path") + socket_path.len + 1));

    if (c.connect(sock_fd, @ptrCast(&addr), addr_len) < 0) {
        std.debug.print("error: failed to connect to socket {s}\n", .{socket_path});
        std.process.exit(1);
    }

    var effective_timeout_ms = opts.timeout_ms;
    if (effective_timeout_ms == null) {
        switch (command) {
            .wait => |p| {
                if (p.timeout_ms) |t| effective_timeout_ms = t + 2000;
            },
            .wait_frame => |p| {
                if (p.timeout_ms) |t| effective_timeout_ms = t + 2000;
            },
            else => {},
        }
    }

    if (effective_timeout_ms) |t_ms| {
        const tv = std.posix.timeval{
            .sec = @intCast(t_ms / 1000),
            .usec = @intCast((t_ms % 1000) * 1000),
        };
        _ = c.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));
        _ = c.setsockopt(sock_fd, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, @ptrCast(&tv), @sizeOf(std.posix.timeval));
    }

    // Construct JSON request string
    var req_buf = std.ArrayList(u8).empty;
    defer req_buf.deinit(allocator);

    switch (command) {
        .doctor => unreachable,
        .version => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"version\"}\n"),
        .capabilities => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"capabilities\"}\n"),
        .windows => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"windows\"}\n"),
        .outputs => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"outputs\"}\n"),
        .focused_window => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"focused_window\"}\n"),
        .workspaces => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"workspaces\"}\n"),
        .event_stream => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.events != null or p.window_id != null or p.output != null) {
                try bw.writeAll("{\"version\":1,\"command\":\"event_stream\",\"params\":{");
                var comma = false;
                if (p.events) |evs| {
                    try bw.writeAll("\"events\":[");
                    for (evs, 0..) |ev, i| {
                        if (i > 0) try bw.writeByte(',');
                        try bw.print("{f}", .{std.json.fmt(ev, .{})});
                    }
                    try bw.writeByte(']');
                    comma = true;
                }
                if (p.window_id) |wid| {
                    if (comma) try bw.writeByte(',');
                    try bw.print("\"window_id\":{d}", .{wid});
                    comma = true;
                }
                if (p.output) |out| {
                    if (comma) try bw.writeByte(',');
                    try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                    comma = true;
                }
                try bw.writeAll("}}\n");
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"event_stream\"}\n");
            }
        },
        .focus_window => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"focus_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .close_window => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.id) |id| {
                try bw.print("{{\"version\":1,\"command\":\"close_window\",\"params\":{{\"id\":{d}}}}}\n", .{id});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"close_window\"}\n");
            }
        },
        .move_window_to => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"move_window_to\",\"params\":{{\"id\":{d}", .{p.id});
            if (p.x) |x| if (p.y) |y| try bw.print(",\"x\":{d},\"y\":{d}", .{ x, y });
            if (p.output) |output| try bw.print(",\"output\":{f}", .{std.json.fmt(output, .{})});
            try bw.writeAll("}}\n");
        },
        .spawn => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"spawn\",\"params\":{\"argv\":[");
            for (p.argv, 0..) |arg, i| {
                if (i > 0) try bw.writeByte(',');
                try bw.print("{f}", .{std.json.fmt(arg, .{})});
            }
            try bw.writeAll("]}}\n");
        },
        .move_cursor => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"move_cursor\",\"params\":{{\"x\":{d},\"y\":{d},\"output\":{f}}}}}\n", .{ p.x, p.y, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"move_cursor\",\"params\":{{\"x\":{d},\"y\":{d}}}}}\n", .{ p.x, p.y });
            }
        },
        .move_cursor_relative => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"move_cursor_relative\",\"params\":{{\"dx\":{d},\"dy\":{d}}}}}\n", .{ p.dx, p.dy });
        },
        .pointer_button => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"pointer_button\",\"params\":{{\"button\":{d},\"pressed\":{s}}}}}\n", .{ p.button, if (p.pressed) "true" else "false" });
        },
        .click => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"click\",\"params\":{{\"button\":{d}}}}}\n", .{p.button});
        },
        .scroll => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"scroll\",\"params\":{{\"dx\":{d},\"dy\":{d}}}}}\n", .{ p.dx, p.dy });
        },
        .key => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"key\",\"params\":{{\"keycode\":{d},\"pressed\":{s}}}}}\n", .{ p.keycode, if (p.pressed) "true" else "false" });
        },
        .key_press => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"key_press\",\"params\":{{\"key\":{f}}}}}\n", .{std.json.fmt(p.key, .{})});
        },
        .type_text => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"type_text\",\"params\":{{\"text\":{f}}}}}\n", .{std.json.fmt(p.text, .{})});
        },
        .drag => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"drag\",\"params\":{{\"from_x\":{d},\"from_y\":{d},\"to_x\":{d},\"to_y\":{d},\"button\":{d},\"output\":{f}}}}}\n", .{ p.from_x, p.from_y, p.to_x, p.to_y, p.button, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"drag\",\"params\":{{\"from_x\":{d},\"from_y\":{d},\"to_x\":{d},\"to_y\":{d},\"button\":{d}}}}}\n", .{ p.from_x, p.from_y, p.to_x, p.to_y, p.button });
            }
        },
        .screenshot => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"screenshot\",\"params\":{");
            var comma = false;
            if (p.output) |out| {
                try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                comma = true;
            }
            if (p.window_id) |wid| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"window_id\":{d}", .{wid});
                comma = true;
            }
            if (p.mode) |m| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"mode\":{f}", .{std.json.fmt(m, .{})});
                comma = true;
            }
            if (p.include_cursor) {
                if (comma) try bw.writeByte(',');
                try bw.writeAll("\"include_cursor\":true");
                comma = true;
            }
            if (p.path) |path| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"path\":{f}", .{std.json.fmt(path, .{})});
                comma = true;
            }
            try bw.writeAll("}}\n");
        },
        .set_master_volume => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_master_volume\",\"params\":{{\"volume\":{d}}}}}\n", .{p.volume});
        },
        .toggle_mute => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"toggle_mute\"}\n"),
        .set_app_volume => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_app_volume\",\"params\":{{\"index\":{d},\"volume\":{d}}}}}\n", .{ p.index, p.volume });
        },
        .set_app_mute => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_app_mute\",\"params\":{{\"index\":{d},\"muted\":{s}}}}}\n", .{ p.index, if (p.muted) "true" else "false" });
        },
        .get_audio_state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_audio_state\"}\n"),
        .get_panel_stats => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_panel_stats\"}\n"),
        .reset_panel_stats => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reset_panel_stats\"}\n"),
        .set_anim_time => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.ms) |ms| {
                try bw.print("{{\"version\":1,\"command\":\"set_anim_time\",\"params\":{{\"ms\":{d}}}}}\n", .{ms});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"set_anim_time\",\"params\":{\"ms\":null}}\n");
            }
        },
        .open_start_menu => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_start_menu\"}\n"),
        .open_control_center => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_control_center\"}\n"),
        .open_power_menu => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"open_power_menu\"}\n"),
        .raw => |r| {
            try req_buf.appendSlice(allocator, r);
            if (!std.mem.endsWith(u8, r, "\n")) {
                try req_buf.append(allocator, '\n');
            }
        },
        .state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_state\"}\n"),
        .describe => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"describe_ipc\"}\n"),
        .window_debug => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_window_debug\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .window_rules => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_window_rules\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .match_window_rules => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"match_window_rules\",\"params\":{");
            var comma = false;
            if (p.app_id) |app| {
                try bw.print("\"app_id\":{f}", .{std.json.fmt(app, .{})});
                comma = true;
            }
            if (p.title) |t| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"title\":{f}", .{std.json.fmt(t, .{})});
                comma = true;
            }
            if (p.x11_class) |cls| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"x11_class\":{f}", .{std.json.fmt(cls, .{})});
                comma = true;
            }
            if (p.x11_instance) |inst| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"x11_instance\":{f}", .{std.json.fmt(inst, .{})});
                comma = true;
            }
            if (p.backend) |b| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"backend\":{f}", .{std.json.fmt(b, .{})});
                comma = true;
            }
            if (p.dialog) |d| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"dialog\":{}", .{d});
            }
            try bw.writeAll("}}\n");
        },
        .night_light => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_night_light\"}\n"),
        .notifications => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_notifications\"}\n"),
        .shell_state => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"get_shell_state\",\"params\":{{\"output\":{f}}}}}\n", .{std.json.fmt(out, .{})});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"get_shell_state\"}\n");
            }
        },
        .keyboard_layouts => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_keyboard_layouts\"}\n"),
        .switch_layout => |target| {
            const bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"switch_layout\",\"params\":{\"layout\":");
            switch (target) {
                .next => try bw.writeAll("\"next\""),
                .prev => try bw.writeAll("\"prev\""),
                .index => |idx| try bw.print("{d}", .{idx}),
            }
            try bw.writeAll("}}\n");
        },
        .text_input => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_text_input\"}\n"),
        .input_state => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_input_state\"}\n"),
        .hit_test => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"hit_test\",\"params\":{{\"x\":{d},\"y\":{d},\"output\":{f}}}}}\n", .{ p.x, p.y, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"hit_test\",\"params\":{{\"x\":{d},\"y\":{d}}}}}\n", .{ p.x, p.y });
            }
        },
        .scene_tree => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.max_depth) |md| {
                try bw.print("{{\"version\":1,\"command\":\"get_scene_tree\",\"params\":{{\"max_depth\":{d}}}}}\n", .{md});
            } else {
                try bw.writeAll("{\"version\":1,\"command\":\"get_scene_tree\"}\n");
            }
        },
        .layers => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_layer_surfaces\"}\n"),
        .panels => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"list_panels\"}\n"),
        .widget_tree => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"get_widget_tree\",\"params\":{{\"panel\":{f}}}}}\n", .{std.json.fmt(p.panel, .{})});
        },
        .config => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_config_status\"}\n"),
        .runtime => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_runtime_info\"}\n"),
        .perf => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"get_performance_stats\"}\n"),
        .perf_reset => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reset_performance_stats\"}\n"),
        .wait => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"wait_for\",\"params\":{{\"condition\":{f}", .{std.json.fmt(p.condition, .{})});
            if (p.timeout_ms) |t| try bw.print(",\"timeout_ms\":{d}", .{t});
            if (p.window_id) |wid| try bw.print(",\"window_id\":{d}", .{wid});
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .wait_frame => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.writeAll("{\"version\":1,\"command\":\"wait_for_frame\",\"params\":{");
            var comma = false;
            if (p.output) |out| {
                try bw.print("\"output\":{f}", .{std.json.fmt(out, .{})});
                comma = true;
            }
            if (p.timeout_ms) |t| {
                if (comma) try bw.writeByte(',');
                try bw.print("\"timeout_ms\":{d}", .{t});
            }
            try bw.writeAll("}}\n");
        },
        .dump_buffer => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"dump_buffer\",\"params\":{{\"target\":{f}", .{std.json.fmt(p.target, .{})});
            if (p.window_id) |wid| try bw.print(",\"window_id\":{d}", .{wid});
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .sample_pixels => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"sample_pixels\",\"params\":{{\"x\":{d},\"y\":{d},\"width\":{d},\"height\":{d}", .{ p.x, p.y, p.width, p.height });
            if (p.output) |out| try bw.print(",\"output\":{f}", .{std.json.fmt(out, .{})});
            try bw.writeAll("}}\n");
        },
        .output_config => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_output_config\",\"params\":{{\"output\":{f}", .{std.json.fmt(p.output, .{})});
            inline for (.{ "width", "height", "refresh_mhz", "x", "y", "scale" }) |field| {
                if (@field(p, field)) |value| try bw.print(",\"{s}\":{d}", .{ field, value });
            }
            if (p.auto_scale) try bw.writeAll(",\"scale\":\"auto\"");
            if (p.auto_position) try bw.writeAll(",\"position\":\"auto\"");
            if (p.enabled) |value| try bw.print(",\"enabled\":{s}", .{if (value) "true" else "false"});
            if (p.primary) |value| try bw.print(",\"primary\":{s}", .{if (value) "true" else "false"});
            if (p.transform) |value| try bw.print(",\"transform\":\"{s}\"", .{protocol.outputTransformName(value)});
            try bw.writeAll("}}\n");
        },
        .maximize => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"maximize_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .minimize => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"minimize_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .restore => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"restore_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
        },
        .fullscreen => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            if (p.output) |out| {
                try bw.print("{{\"version\":1,\"command\":\"fullscreen_window\",\"params\":{{\"id\":{d},\"output\":{f}}}}}\n", .{ p.id, std.json.fmt(out, .{}) });
            } else {
                try bw.print("{{\"version\":1,\"command\":\"fullscreen_window\",\"params\":{{\"id\":{d}}}}}\n", .{p.id});
            }
        },
        .set_zoom => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"set_window_zoom\",\"params\":{{\"id\":{d},\"percent\":{d}}}}}\n", .{ p.id, p.percent });
        },
        .close_panel => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"close_panel\",\"params\":{{\"panel\":{f}}}}}\n", .{std.json.fmt(p.panel, .{})});
        },
        .reload => try req_buf.appendSlice(allocator, "{\"version\":1,\"command\":\"reload_config\"}\n"),
        .launch => |p| {
            var bw = protocol.BufferWriter{ .list = &req_buf, .allocator = allocator };
            try bw.print("{{\"version\":1,\"command\":\"launch_app\",\"params\":{{\"desktop_id\":{f}}}}}\n", .{std.json.fmt(p.desktop_id, .{})});
        },
    }

    _ = c.write(sock_fd, req_buf.items.ptr, req_buf.items.len);

    if (command == .event_stream) {
        var read_buf: [4096]u8 = undefined;
        while (true) {
            const nread = c.read(sock_fd, &read_buf, read_buf.len);
            if (nread <= 0) break;
            _ = c.write(std.posix.STDOUT_FILENO, &read_buf, @intCast(nread));
        }
        return;
    }

    // Read single line reply
    var reply_buf = std.ArrayList(u8).empty;
    defer reply_buf.deinit(allocator);

    var tmp: [1024]u8 = undefined;
    while (true) {
        const nread_res = c.read(sock_fd, &tmp, tmp.len);
        if (nread_res <= 0) break;
        const nread: usize = @intCast(nread_res);
        try reply_buf.appendSlice(allocator, tmp[0..nread]);
        if (std.mem.indexOfScalar(u8, reply_buf.items, '\n') != null) break;
    }

    const trimmed_reply = std.mem.trim(u8, reply_buf.items, " \t\r\n");
    if (trimmed_reply.len == 0) {
        std.debug.print("error: empty reply from compositor\n", .{});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed_reply, .{}) catch {
        std.debug.print("error: invalid JSON reply from compositor: {s}\n", .{trimmed_reply});
        std.process.exit(1);
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        std.debug.print("error: malformed reply: {s}\n", .{trimmed_reply});
        std.process.exit(1);
    }

    if (parsed.value.object.get("Err")) |err_val| {
        if (err_val == .string) {
            std.debug.print("error: {s}\n", .{err_val.string});
        } else {
            std.debug.print("error: unknown error reply\n", .{});
        }
        std.process.exit(1);
    }

    if (parsed.value.object.get("error")) |err_val| {
        if (err_val == .string) {
            std.debug.print("error: {s}\n", .{err_val.string});
        } else {
            std.debug.print("error: unknown error reply\n", .{});
        }
        std.process.exit(1);
    }

    const ok_val = parsed.value.object.get("Ok") orelse {
        std.debug.print("error: reply missing Ok/Err: {s}\n", .{trimmed_reply});
        std.process.exit(1);
    };

    var is_timeout = false;
    if (ok_val == .object) {
        if (ok_val.object.get("WaitFor")) |wf| {
            if (wf == .object) {
                if (wf.object.get("timed_out")) |to| {
                    if (to == .bool and to.bool) is_timeout = true;
                }
            }
        } else if (ok_val.object.get("WaitForFrame")) |wff| {
            if (wff == .object) {
                if (wff.object.get("timed_out")) |to| {
                    if (to == .bool and to.bool) is_timeout = true;
                }
            }
        }
    }

    if (opts.save_path) |save_path| {
        if (ok_val == .object and ok_val.object.get("Screenshot") != null) {
            const sc_obj = ok_val.object.get("Screenshot").?;
            if (sc_obj == .object and sc_obj.object.get("data") != null) {
                const data_val = sc_obj.object.get("data").?;
                if (data_val == .string) {
                    const b64_str = data_val.string;
                    const decoder = std.base64.standard.Decoder;
                    const decoded_len = decoder.calcSizeForSlice(b64_str) catch {
                        std.debug.print("error: invalid base64 data\n", .{});
                        std.process.exit(1);
                    };
                    const raw_bytes = try allocator.alloc(u8, decoded_len);
                    defer allocator.free(raw_bytes);
                    decoder.decode(raw_bytes, b64_str) catch {
                        std.debug.print("error: base64 decode error\n", .{});
                        std.process.exit(1);
                    };

                    const save_fd = std.posix.openat(std.posix.AT.FDCWD, save_path, .{
                        .ACCMODE = .WRONLY,
                        .CREAT = true,
                        .EXCL = true,
                        .CLOEXEC = true,
                        .NOFOLLOW = true,
                    }, 0o644) catch |err| {
                        std.debug.print("error: could not create save file {s}: {}\n", .{ save_path, err });
                        std.process.exit(1);
                    };
                    defer _ = c.close(save_fd);
                    var save_written: usize = 0;
                    while (save_written < raw_bytes.len) {
                        const n = c.write(save_fd, raw_bytes.ptr + save_written, raw_bytes.len - save_written);
                        if (n <= 0) {
                            std.debug.print("error: write failed to {s}\n", .{save_path});
                            std.process.exit(1);
                        }
                        save_written += @intCast(n);
                    }
                    if (!opts.json) {
                        std.debug.print("Screenshot saved to {s}\n", .{save_path});
                        return;
                    }
                }
            }
        }
    }

    if (opts.json) {
        switch (command) {
            .windows => try printUnwrappedJson(ok_val, "Windows"),
            .outputs => try printUnwrappedJson(ok_val, "Outputs"),
            .focused_window => try printUnwrappedJson(ok_val, "FocusedWindow"),
            .workspaces => try printUnwrappedJson(ok_val, "Workspaces"),
            .version => try printUnwrappedJson(ok_val, "Version"),
            .capabilities => try printUnwrappedJson(ok_val, "Capabilities"),
            .state => try printUnwrappedJson(ok_val, "State"),
            .describe => try printUnwrappedJson(ok_val, "DescribeIPC"),
            .window_debug => try printUnwrappedJson(ok_val, "WindowDebug"),
            .window_rules => try printUnwrappedJson(ok_val, "WindowRules"),
            .match_window_rules => try printUnwrappedJson(ok_val, "MatchWindowRules"),
            .shell_state => try printUnwrappedJson(ok_val, "ShellState"),
            .keyboard_layouts => try printUnwrappedJson(ok_val, "KeyboardLayouts"),
            .text_input => try printUnwrappedJson(ok_val, "TextInput"),
            .input_state => try printUnwrappedJson(ok_val, "InputState"),
            .hit_test => try printUnwrappedJson(ok_val, "HitTest"),
            .scene_tree => try printUnwrappedJson(ok_val, "SceneTree"),
            .layers => try printUnwrappedJson(ok_val, "LayerSurfaces"),
            .panels => try printUnwrappedJson(ok_val, "ListPanels"),
            .widget_tree => try printUnwrappedJson(ok_val, "WidgetTree"),
            .config => try printUnwrappedJson(ok_val, "ConfigStatus"),
            .runtime => try printUnwrappedJson(ok_val, "RuntimeInfo"),
            .perf => try printUnwrappedJson(ok_val, "PerformanceStats"),
            .wait => try printUnwrappedJson(ok_val, "WaitFor"),
            .wait_frame => try printUnwrappedJson(ok_val, "WaitForFrame"),
            .dump_buffer => try printUnwrappedJson(ok_val, "DumpBuffer"),
            .sample_pixels => try printUnwrappedJson(ok_val, "SamplePixels"),
            .night_light => try printUnwrappedJson(ok_val, "NightLight"),
            .notifications => try printUnwrappedJson(ok_val, "Notifications"),
            else => try printJsonValue(ok_val),
        }
    } else {
        printTextReply(ok_val);
    }

    if (is_timeout) {
        std.process.exit(1);
    }
}
