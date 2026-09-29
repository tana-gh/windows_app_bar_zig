const std = @import("std");
const api = @import("api.zig");
const win32 = @import("win32.zig");

pub const MessageAction = enum {
    none,
    taskbar_created,
    display_changed,
    dpi_changed,
    activation_changed,
    window_position_changed,
    position_changed,
    state_changed,
    fullscreen_app,
    window_arrange,
    callback,
};

pub fn messageAction(
    callback_message: api.Message,
    taskbar_created_message: api.Message,
    message: api.Message,
    wparam: api.WParam,
) MessageAction {
    if (message == taskbar_created_message) {
        return .taskbar_created;
    }
    if (message == callback_message) {
        return switch (wparam) {
            win32.ABN_POSCHANGED => .position_changed,
            win32.ABN_STATECHANGE => .state_changed,
            win32.ABN_FULLSCREENAPP => .fullscreen_app,
            win32.ABN_WINDOWARRANGE => .window_arrange,
            else => .callback,
        };
    }
    if (message == win32.WM_WINDOWPOSCHANGED) {
        return .window_position_changed;
    }
    if (message == win32.WM_DISPLAYCHANGE) {
        return .display_changed;
    }
    if (message == win32.WM_DPICHANGED) {
        return .dpi_changed;
    }
    if (message == win32.WM_ACTIVATE) {
        return .activation_changed;
    }
    return .none;
}

pub fn stateAfterTaskbarRestart(state: api.Status) api.Status {
    return switch (state) {
        .active => .suspended,
        .suspended, .cleaned => state,
    };
}

pub fn dpiFromWParam(wparam: api.WParam) u32 {
    return @intCast((wparam >> 16) & 0xffff);
}

pub fn shouldRepositionForStateChange(state: api.Status) bool {
    return state == .active;
}

pub fn canReapply(state: api.Status) bool {
    return state != .cleaned;
}

pub fn shouldAutomaticallyReregister(
    state: api.Status,
    allows_automatic_reregistration: bool,
) bool {
    return state == .suspended and allows_automatic_reregistration;
}

pub fn appBarActivationLParam(is_active: bool) api.LParam {
    return @intFromBool(is_active);
}

pub fn fullscreenAppIsOpening(lparam: api.LParam) bool {
    return lparam != 0;
}

pub fn windowArrangeIsBeginning(lparam: api.LParam) bool {
    return lparam != 0;
}

pub fn shouldHideForWindowArrange(is_hidden_for_window_arrange: bool, is_window_visible: bool) bool {
    return !is_hidden_for_window_arrange and is_window_visible;
}

pub fn shouldShowAfterWindowArrange(is_hidden_for_window_arrange: bool) bool {
    return is_hidden_for_window_arrange;
}

test "AppBar callback messages are consumed" {
    const callback_message: api.Message = 0xc000;

    try std.testing.expectEqual(
        MessageAction.position_changed,
        messageAction(callback_message, 0xc001, callback_message, win32.ABN_POSCHANGED),
    );
    try std.testing.expectEqual(
        MessageAction.callback,
        messageAction(callback_message, 0xc001, callback_message, 4),
    );
    try std.testing.expectEqual(
        MessageAction.state_changed,
        messageAction(callback_message, 0xc001, callback_message, win32.ABN_STATECHANGE),
    );
    try std.testing.expectEqual(
        MessageAction.fullscreen_app,
        messageAction(callback_message, 0xc001, callback_message, win32.ABN_FULLSCREENAPP),
    );
    try std.testing.expectEqual(
        MessageAction.window_arrange,
        messageAction(callback_message, 0xc001, callback_message, win32.ABN_WINDOWARRANGE),
    );
}

test "window position changes are forwarded without being consumed" {
    try std.testing.expectEqual(
        MessageAction.window_position_changed,
        messageAction(0xc000, 0xc001, win32.WM_WINDOWPOSCHANGED, 0),
    );
    try std.testing.expectEqual(MessageAction.none, messageAction(0xc000, 0xc001, 1, 0));
}

test "display changes are forwarded without being consumed" {
    try std.testing.expectEqual(
        MessageAction.display_changed,
        messageAction(0xc000, 0xc001, win32.WM_DISPLAYCHANGE, 0),
    );
}

test "DPI changes are consumed and use the Y-axis DPI" {
    try std.testing.expectEqual(
        MessageAction.dpi_changed,
        messageAction(0xc000, 0xc001, win32.WM_DPICHANGED, 0),
    );
    const dpi_wparam: api.WParam = (@as(api.WParam, 144) << 16) | 120;
    try std.testing.expectEqual(@as(u32, 144), dpiFromWParam(dpi_wparam));
}

test "activation changes are forwarded and report the active state" {
    try std.testing.expectEqual(
        MessageAction.activation_changed,
        messageAction(0xc000, 0xc001, win32.WM_ACTIVATE, 0),
    );
    try std.testing.expectEqual(@as(api.LParam, 0), appBarActivationLParam(false));
    try std.testing.expectEqual(@as(api.LParam, 1), appBarActivationLParam(true));
}

test "taskbar state changes reconfigure active AppBars" {
    try std.testing.expect(shouldRepositionForStateChange(.active));
    try std.testing.expect(!shouldRepositionForStateChange(.suspended));
    try std.testing.expect(!shouldRepositionForStateChange(.cleaned));
}

test "automatic re-registration excludes manually unregistered AppBars" {
    try std.testing.expect(shouldAutomaticallyReregister(.suspended, true));
    try std.testing.expect(!shouldAutomaticallyReregister(.suspended, false));
    try std.testing.expect(!shouldAutomaticallyReregister(.active, true));
    try std.testing.expect(!shouldAutomaticallyReregister(.cleaned, true));
}

test "reapply is unavailable after cleanup" {
    try std.testing.expect(canReapply(.active));
    try std.testing.expect(canReapply(.suspended));
    try std.testing.expect(!canReapply(.cleaned));
}

test "fullscreen AppBar notifications use the lParam opening flag" {
    try std.testing.expect(fullscreenAppIsOpening(1));
    try std.testing.expect(!fullscreenAppIsOpening(0));
}

test "window arrangement hides and restores only windows hidden by the AppBar" {
    try std.testing.expect(windowArrangeIsBeginning(1));
    try std.testing.expect(!windowArrangeIsBeginning(0));
    try std.testing.expect(shouldHideForWindowArrange(false, true));
    try std.testing.expect(!shouldHideForWindowArrange(false, false));
    try std.testing.expect(!shouldHideForWindowArrange(true, true));
    try std.testing.expect(shouldShowAfterWindowArrange(true));
    try std.testing.expect(!shouldShowAfterWindowArrange(false));
}

test "TaskbarCreated is consumed and resets only active AppBars" {
    try std.testing.expectEqual(
        MessageAction.taskbar_created,
        messageAction(0xc000, 0xc001, 0xc001, 0),
    );
    try std.testing.expectEqual(api.Status.suspended, stateAfterTaskbarRestart(.active));
    try std.testing.expectEqual(api.Status.suspended, stateAfterTaskbarRestart(.suspended));
    try std.testing.expectEqual(api.Status.cleaned, stateAfterTaskbarRestart(.cleaned));
}
