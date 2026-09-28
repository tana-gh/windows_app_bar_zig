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
    NotImplemented,
};

pub const AppBar = struct {
    window: WindowHandle,
    monitor_index: u32,
    edge: Edge,
    thickness: u32,
    callback_message: Message,

    /// Registers an AppBar for a window.
    pub fn register(
        window: WindowHandle,
        monitor_index: u32,
        edge: Edge,
        thickness: u32,
    ) Error!AppBar {
        _ = window;
        _ = monitor_index;
        _ = edge;
        _ = thickness;
        return error.NotImplemented;
    }

    /// Removes the AppBar registration when registration is implemented.
    pub fn cleanup(self: *AppBar) void {
        _ = self;
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

test "Edge values match the Windows SDK" {
    try std.testing.expectEqual(win32.ABE_LEFT, @intFromEnum(Edge.left));
    try std.testing.expectEqual(win32.ABE_TOP, @intFromEnum(Edge.top));
    try std.testing.expectEqual(win32.ABE_RIGHT, @intFromEnum(Edge.right));
    try std.testing.expectEqual(win32.ABE_BOTTOM, @intFromEnum(Edge.bottom));
}

test "register has the documented error contract before implementation" {
    const window: WindowHandle = @ptrFromInt(1);
    try std.testing.expectError(error.NotImplemented, AppBar.register(window, 0, .right, 320));
}
