const builtin = @import("builtin");
const std = @import("std");
const api = @import("api.zig");
const app_bar = @import("app_bar.zig");
const app_bar_binding = @import("app_bar_binding.zig");
const monitor = @import("monitor.zig");
const win32 = @import("win32.zig");

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("windows_app_bar supports Windows targets only");
    }
}

pub const WindowHandle = api.WindowHandle;
pub const Message = api.Message;
pub const WParam = api.WParam;
pub const LParam = api.LParam;
pub const Edge = api.Edge;
pub const Rect = api.Rect;
pub const MonitorId = api.MonitorId;
pub const MonitorTarget = api.MonitorTarget;
pub const MonitorInfo = api.MonitorInfo;
pub const AppBarConfig = api.AppBarConfig;
pub const Status = api.Status;
pub const Error = api.Error;
pub const AppBar = app_bar.AppBar;
pub const AppBarBinding = app_bar_binding.AppBarBinding;

pub fn enumerateMonitors(allocator: std.mem.Allocator) std.mem.Allocator.Error![]MonitorInfo {
    return monitor.enumerateMonitors(allocator);
}

test {
    _ = @import("api.zig");
    _ = @import("app_bar.zig");
    _ = @import("app_bar_binding.zig");
    _ = @import("geometry.zig");
    _ = @import("message.zig");
    _ = @import("monitor.zig");
    _ = @import("win32.zig");
}

test "Edge values match the Windows SDK" {
    try std.testing.expectEqual(win32.ABE_LEFT, @intFromEnum(Edge.left));
    try std.testing.expectEqual(win32.ABE_TOP, @intFromEnum(Edge.top));
    try std.testing.expectEqual(win32.ABE_RIGHT, @intFromEnum(Edge.right));
    try std.testing.expectEqual(win32.ABE_BOTTOM, @intFromEnum(Edge.bottom));
}

test "MonitorId stores valid UTF-8 monitor identifiers" {
    const monitor_id = try MonitorId.fromUtf8("monitor-\u{1f5a5}");
    try std.testing.expectEqualStrings("monitor-\u{1f5a5}", monitor_id.utf8());
    try std.testing.expectError(error.InvalidMonitorId, MonitorId.fromUtf8(""));
    try std.testing.expectError(error.InvalidMonitorId, MonitorId.fromUtf8("invalid\x00id"));
    try std.testing.expectError(error.InvalidMonitorId, MonitorId.fromUtf8("\xff"));
}
