#!/usr/bin/env python3
"""Xwayland environment and connection tests. Run after zig build.

Does not use the host DISPLAY. The compositor owns a lazy Xwayland display
and publishes it through GetRuntimeInfo / child spawn env.
"""
import sys

from xwayland_support import ROOT, build_client, ipc_connect, request, start_compositor, start_x11_client, wait_for, wayland_display_name, x11_pointer_window_name  # noqa: F401  (shared with other tests)
from xwayland_core import test_enabled, test_native_scaling_root_geometry, test_disabled, test_missing_executable, test_server_stop_cleanup, test_managed_window, test_native_scaling_managed_window, test_switcher_input, test_unmapped_window_has_no_chrome, test_withdrawn_window_survives_close_animation
from xwayland_gtk import test_gtk_menu_alignment, test_gtk_transient_dialog, test_gtk_file_dialog, test_gtk_combo_and_tooltip, test_gtk_menu_alignment_zoomed, test_gtk_menu_multi_output, test_negative_output_origin, test_gtk_menu_fractional_scale
from xwayland_selection import test_clipboard_bidirectional, test_x11_to_wayland_clipboard_focus_limitation, test_drag_and_drop, test_x11_source_drag_to_wayland_limitation, test_primary_selection_bidirectional


def run():
    test_enabled()
    test_native_scaling_root_geometry()
    test_native_scaling_root_geometry(output_policy=True)
    test_disabled()
    test_missing_executable()
    test_server_stop_cleanup()
    test_managed_window()
    test_native_scaling_managed_window()
    test_switcher_input()
    test_switcher_input(factor=2)
    test_unmapped_window_has_no_chrome()
    test_withdrawn_window_survives_close_animation()
    test_gtk_menu_alignment()
    test_gtk_menu_alignment_zoomed()
    test_gtk_menu_alignment_zoomed(-1280, -720, 1.5)
    test_gtk_menu_alignment_zoomed(-1706, 0, 1.5, zoom=100)
    test_gtk_menu_alignment_zoomed(1920, 1080)
    test_gtk_menu_multi_output()
    test_negative_output_origin()
    test_negative_output_origin(1.5)
    test_gtk_menu_fractional_scale()
    test_gtk_menu_fractional_scale("2")
    test_gtk_transient_dialog()
    test_gtk_file_dialog()
    test_gtk_file_dialog(native=True)
    test_gtk_combo_and_tooltip()
    test_clipboard_bidirectional()
    test_x11_to_wayland_clipboard_focus_limitation()
    test_drag_and_drop()
    test_x11_source_drag_to_wayland_limitation()
    test_primary_selection_bidirectional()
    print("Xwayland environment, connection and managed-window tests passed")


if __name__ == "__main__":
    run()
