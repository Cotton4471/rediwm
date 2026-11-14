//! Event-driven operational readiness. No timeouts or synthetic input can
//! satisfy this gate. Backend start and a submitted frame are insufficient.
const Server = @import("../Server.zig");

pub fn check(server: *Server) void {
    if (!server.greeter_mode) return;
    var visible = false;
    var outputs = server.outputs.iterator(.forward);
    while (outputs.next()) |output| {
        if (output.isAvailable() and !output.power_off and output.greeter_presented and output.greeter_unveiled and output.lock_view.content_ready) {
            visible = true;
            break;
        }
    }
    if (!visible) return;
    if (@import("../startup.zig").marks.input_ready_ns == 0) return;
    if (server.session) |session| if (!session.active) return;
    const lock = server.locker orelse return;
    const greeter = lock.greeter orelse return;
    var keyboard_ready = false;
    var keyboards = server.input.keyboards.iterator(.forward);
    while (keyboards.next()) |keyboard| {
        if (!keyboard.synthetic and !@import("../input/text_input.zig").isVirtual(keyboard.device)) {
            keyboard_ready = keyboard.device.toKeyboard().keymap != null;
            if (keyboard_ready) break;
        }
    }
    if (!keyboard_ready) return;
    if (greeter.ready_pointer_required) {
        var pointer_ready = false;
        var pointers = server.input.pointers.iterator(.forward);
        while (pointers.next()) |pointer| {
            if (!@import("../input/devices.zig").blockedVirtual(&server.input, pointer.device)) {
                pointer_ready = true;
                break;
            }
        }
        if (!pointer_ready) return;
    }
    greeter.reportReady();
}
