# zarms.py: handleAction's switch into handlers_*.zig sub-handlers, the action
# half of 0507c7c (line numbers of its parent).
parent src/ipc/handlers.zig
function handleAction
group src/ipc/handlers_input.zig handleInputAction Synthetic input actions: pointer, keys, text, gestures, drags and widget clicks.
  move_cursor move_cursor_relative pointer_button click scroll pinch swipe key key_press type_text drag click_widget hover_widget
group src/ipc/handlers_windows.zig handleWindowAction Window and workspace actions: focus, close, move, spawn, tiling, sizing and zoom.
  focus_window close_window move_window_to spawn set_desktop_mode set_window_gap set_floating_apps set_workspace_layout switch_workspace move_to_workspace tiling_action maximize_window minimize_window restore_window fullscreen_window stop_xwayland set_window_size set_window_zoom
group src/ipc/handlers_frames.zig handleFrameAction Screenshots, frame waits, buffer dumps, pixel samples and performance stats.
  screenshot stop_all_capture wait_for wait_for_frame dump_buffer sample_pixels get_performance_stats reset_performance_stats
