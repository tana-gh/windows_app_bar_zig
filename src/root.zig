const builtin = @import("builtin");
const std = @import("std");
const win32 = @import("win32.zig");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_app_bar supports Windows targets only");
    }
}

pub const WindowHandle = std.os.windows.HWND;
pub const Message = std.os.windows.UINT;
pub const WParam = usize;
pub const LParam = std.os.windows.LPARAM;

pub const Edge = enum(std.os.windows.UINT) {
    left = win32.ABE_LEFT,
    top = win32.ABE_TOP,
    right = win32.ABE_RIGHT,
    bottom = win32.ABE_BOTTOM,
};

pub const Error = error{
    CallbackMessageRegistrationFailed,
    AppBarRegistrationFailed,
};

pub const AppBar = struct {
    window: WindowHandle,
    monitor_index: u32,
    edge: Edge,
    thickness: u32,
    callback_message: Message,
    registered: bool,

    /// Registers an AppBar for a window.
    pub fn register(
        window: WindowHandle,
        monitor_index: u32,
        edge: Edge,
        thickness: u32,
    ) Error!AppBar {
        const callback_message = win32.RegisterWindowMessageW(callback_message_name.ptr);
        if (callback_message == 0) {
            return error.CallbackMessageRegistrationFailed;
        }

        var app_bar_data = makeAppBarData(window, callback_message);
        if (win32.SHAppBarMessage(win32.ABM_NEW, &app_bar_data) == 0) {
            return error.AppBarRegistrationFailed;
        }

        return .{
            .window = window,
            .monitor_index = monitor_index,
            .edge = edge,
            .thickness = thickness,
            .callback_message = callback_message,
            .registered = true,
        };
    }

    /// Removes the AppBar registration if it is active.
    pub fn cleanup(self: *AppBar) void {
        if (!self.registered) {
            return;
        }

        var app_bar_data = makeAppBarData(self.window, 0);
        _ = win32.SHAppBarMessage(win32.ABM_REMOVE, &app_bar_data);
        self.registered = false;
    }

    /// Handles a window message and reports whether it was consumed.
    pub fn handleWindowMessage(
        self: *AppBar,
        message: Message,
        wparam: WParam,
        lparam: LParam,
    ) Error!bool {
        _ = self;
        _ = message;
        _ = wparam;
        _ = lparam;
        return false;
    }
};

const callback_message_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "windows_app_bar.AppBarCallback.v1",
);

fn makeAppBarData(window: WindowHandle, callback_message: Message) win32.APPBARDATA {
    return .{
        .cbSize = @sizeOf(win32.APPBARDATA),
        .hWnd = window,
        .uCallbackMessage = callback_message,
        .uEdge = 0,
        .rc = .{
            .left = 0,
            .top = 0,
            .right = 0,
            .bottom = 0,
        },
        .lParam = 0,
    };
}

test "Edge values match the Windows SDK" {
    try std.testing.expectEqual(win32.ABE_LEFT, @intFromEnum(Edge.left));
    try std.testing.expectEqual(win32.ABE_TOP, @intFromEnum(Edge.top));
    try std.testing.expectEqual(win32.ABE_RIGHT, @intFromEnum(Edge.right));
    try std.testing.expectEqual(win32.ABE_BOTTOM, @intFromEnum(Edge.bottom));
}

test "APPBARDATA contains the ABM_NEW fields required by the Windows SDK" {
    const window: WindowHandle = @ptrFromInt(1);
    const callback_message: Message = 0xc000;
    const app_bar_data = makeAppBarData(window, callback_message);

    try std.testing.expectEqual(@as(u32, @sizeOf(win32.APPBARDATA)), app_bar_data.cbSize);
    try std.testing.expectEqual(window, app_bar_data.hWnd);
    try std.testing.expectEqual(callback_message, app_bar_data.uCallbackMessage);
}
