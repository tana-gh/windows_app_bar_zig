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
    MonitorNotFound,
    InvalidThickness,
    InvalidPlacementRect,
    WindowPlacementFailed,
};

pub const AppBar = struct {
    window: WindowHandle,
    monitor_index: u32,
    edge: Edge,
    thickness: u32,
    callback_message: Message,
    placement_rect: win32.RECT,
    registered: bool,

    /// Registers an AppBar for a window.
    pub fn register(
        window: WindowHandle,
        monitor_index: u32,
        edge: Edge,
        thickness: u32,
    ) Error!AppBar {
        const monitor_rect = try findMonitorRect(monitor_index);
        const proposed_rect = try makeProposedRect(monitor_rect, edge, thickness);

        const callback_message = win32.RegisterWindowMessageW(callback_message_name.ptr);
        if (callback_message == 0) {
            return error.CallbackMessageRegistrationFailed;
        }

        var app_bar_data = makeAppBarData(window, callback_message);
        if (win32.SHAppBarMessage(win32.ABM_NEW, &app_bar_data) == 0) {
            return error.AppBarRegistrationFailed;
        }

        var app_bar = AppBar{
            .window = window,
            .monitor_index = monitor_index,
            .edge = edge,
            .thickness = thickness,
            .callback_message = callback_message,
            .placement_rect = proposed_rect,
            .registered = true,
        };
        errdefer app_bar.cleanup();
        app_bar.queryPosition();
        try app_bar.applyPosition();
        return app_bar;
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

    fn queryPosition(self: *AppBar) void {
        var app_bar_data = makeAppBarData(self.window, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.edge);
        app_bar_data.rc = self.placement_rect;
        _ = win32.SHAppBarMessage(win32.ABM_QUERYPOS, &app_bar_data);
        self.placement_rect = preserveThickness(app_bar_data.rc, self.edge, self.thickness);
    }

    fn applyPosition(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.edge);
        app_bar_data.rc = self.placement_rect;
        _ = win32.SHAppBarMessage(win32.ABM_SETPOS, &app_bar_data);
        self.placement_rect = app_bar_data.rc;

        const position = try windowPositionFromRect(self.placement_rect);
        const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(
            self.window,
            null,
            position.x,
            position.y,
            position.width,
            position.height,
            flags,
        ).toBool()) {
            return error.WindowPlacementFailed;
        }
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

const MonitorSearch = struct {
    index: u32,
    rect: ?win32.RECT = null,
};

fn findMonitorRect(index: u32) Error!win32.RECT {
    var search = MonitorSearch{ .index = index };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        findMonitorCallback,
        @bitCast(@intFromPtr(&search)),
    );
    return search.rect orelse error.MonitorNotFound;
}

fn findMonitorCallback(
    _: win32.HMONITOR,
    _: ?std.os.windows.HDC,
    monitor_rect: *win32.RECT,
    data: LParam,
) callconv(.winapi) std.os.windows.BOOL {
    const search: *MonitorSearch = @ptrFromInt(@as(usize, @bitCast(data)));
    if (search.index == 0) {
        search.rect = monitor_rect.*;
        return .FALSE;
    }

    search.index -= 1;
    return .TRUE;
}

fn makeProposedRect(monitor_rect: win32.RECT, edge: Edge, thickness: u32) Error!win32.RECT {
    const thickness_i32 = try validateThickness(monitor_rect, edge, thickness);
    var proposed_rect = monitor_rect;

    switch (edge) {
        .left => proposed_rect.right = proposed_rect.left + thickness_i32,
        .top => proposed_rect.bottom = proposed_rect.top + thickness_i32,
        .right => proposed_rect.left = proposed_rect.right - thickness_i32,
        .bottom => proposed_rect.top = proposed_rect.bottom - thickness_i32,
    }
    return proposed_rect;
}

fn preserveThickness(rect: win32.RECT, edge: Edge, thickness: u32) win32.RECT {
    const thickness_i32: i32 = @intCast(thickness);
    var adjusted_rect = rect;

    switch (edge) {
        .left => adjusted_rect.right = adjusted_rect.left + thickness_i32,
        .top => adjusted_rect.bottom = adjusted_rect.top + thickness_i32,
        .right => adjusted_rect.left = adjusted_rect.right - thickness_i32,
        .bottom => adjusted_rect.top = adjusted_rect.bottom - thickness_i32,
    }
    return adjusted_rect;
}

fn validateThickness(monitor_rect: win32.RECT, edge: Edge, thickness: u32) Error!i32 {
    if (thickness == 0 or thickness > std.math.maxInt(i32)) {
        return error.InvalidThickness;
    }

    const dimension: i64 = switch (edge) {
        .left, .right => @as(i64, monitor_rect.right) - @as(i64, monitor_rect.left),
        .top, .bottom => @as(i64, monitor_rect.bottom) - @as(i64, monitor_rect.top),
    };
    if (dimension <= 0 or @as(i64, thickness) > dimension) {
        return error.InvalidThickness;
    }
    return @intCast(thickness);
}

const WindowPosition = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

fn windowPositionFromRect(rect: win32.RECT) Error!WindowPosition {
    const width: i64 = @as(i64, rect.right) - @as(i64, rect.left);
    const height: i64 = @as(i64, rect.bottom) - @as(i64, rect.top);
    if (width <= 0 or width > std.math.maxInt(i32) or height <= 0 or height > std.math.maxInt(i32)) {
        return error.InvalidPlacementRect;
    }

    return .{
        .x = rect.left,
        .y = rect.top,
        .width = @intCast(width),
        .height = @intCast(height),
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

test "proposed rectangles preserve the requested thickness on every edge" {
    const monitor_rect = win32.RECT{
        .left = -100,
        .top = 50,
        .right = 900,
        .bottom = 650,
    };

    const left = try makeProposedRect(monitor_rect, .left, 100);
    try std.testing.expectEqual(@as(i32, 0), left.right);

    const top = try makeProposedRect(monitor_rect, .top, 100);
    try std.testing.expectEqual(@as(i32, 150), top.bottom);

    const right = try makeProposedRect(monitor_rect, .right, 100);
    try std.testing.expectEqual(@as(i32, 800), right.left);

    const bottom = try makeProposedRect(monitor_rect, .bottom, 100);
    try std.testing.expectEqual(@as(i32, 550), bottom.top);
}

test "thickness must fit the selected monitor edge" {
    const monitor_rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = 100,
        .bottom = 50,
    };

    try std.testing.expectError(error.InvalidThickness, makeProposedRect(monitor_rect, .left, 0));
    try std.testing.expectError(error.InvalidThickness, makeProposedRect(monitor_rect, .right, 101));
    try std.testing.expectError(error.InvalidThickness, makeProposedRect(monitor_rect, .bottom, 51));
}

test "window placement preserves screen coordinates and dimensions" {
    const position = try windowPositionFromRect(.{
        .left = -300,
        .top = 50,
        .right = 100,
        .bottom = 250,
    });

    try std.testing.expectEqual(@as(i32, -300), position.x);
    try std.testing.expectEqual(@as(i32, 50), position.y);
    try std.testing.expectEqual(@as(i32, 400), position.width);
    try std.testing.expectEqual(@as(i32, 200), position.height);
}

test "window placement rejects empty rectangles" {
    try std.testing.expectError(error.InvalidPlacementRect, windowPositionFromRect(.{
        .left = 100,
        .top = 0,
        .right = 100,
        .bottom = 100,
    }));
}
