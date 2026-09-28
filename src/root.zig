const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
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
    preferred_monitor_index: u32,
    edge: Edge,
    thickness: u32,
    callback_message: Message,
    placement_rect: win32.RECT,
    monitor_id: ?MonitorId,
    window_dpi: u32,
    state: State,

    /// Registers an AppBar for a window.
    pub fn register(
        window: WindowHandle,
        monitor_index: u32,
        edge: Edge,
        thickness: u32,
    ) Error!AppBar {
        const monitor = resolveMonitor(monitor_index, null) orelse return error.MonitorNotFound;
        const proposed_rect = try makeProposedRect(monitor.rect, edge, thickness);

        const callback_message = win32.RegisterWindowMessageW(callback_message_name.ptr);
        if (callback_message == 0) {
            return error.CallbackMessageRegistrationFailed;
        }

        var app_bar = AppBar{
            .window = window,
            .preferred_monitor_index = monitor_index,
            .edge = edge,
            .thickness = thickness,
            .callback_message = callback_message,
            .placement_rect = proposed_rect,
            .monitor_id = monitor.id,
            .window_dpi = 0,
            .state = .suspended,
        };
        errdefer app_bar.cleanup();
        try app_bar.activate();
        return app_bar;
    }

    /// Removes the AppBar registration if it is active.
    pub fn cleanup(self: *AppBar) void {
        self.unregister();
        self.state = .cleaned;
    }

    /// Handles a window message and reports whether it was consumed.
    pub fn handleWindowMessage(
        self: *AppBar,
        message: Message,
        wparam: WParam,
        lparam: LParam,
    ) Error!bool {
        _ = lparam;

        switch (messageAction(self.callback_message, message, wparam)) {
            .none => return false,
            .display_changed => {
                if (self.state == .cleaned) {
                    return false;
                }
                self.refreshDisplayConfiguration() catch |err| {
                    self.unregister();
                    return err;
                };
                return false;
            },
            .dpi_changed => {
                if (self.state == .cleaned) {
                    return false;
                }
                self.window_dpi = dpiFromWParam(wparam);
                self.refreshDisplayConfiguration() catch |err| {
                    self.unregister();
                    return err;
                };
                return true;
            },
            .window_position_changed => {
                if (self.state != .active) {
                    return false;
                }
                var app_bar_data = makeAppBarData(self.window, 0);
                _ = win32.SHAppBarMessage(win32.ABM_WINDOWPOSCHANGED, &app_bar_data);
                return false;
            },
            .position_changed => {
                if (self.state != .active) {
                    return false;
                }
                self.reposition() catch |err| {
                    self.unregister();
                    return err;
                };
                return true;
            },
            .callback => return self.state == .active,
        }
    }

    fn activate(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window, self.callback_message);
        if (win32.SHAppBarMessage(win32.ABM_NEW, &app_bar_data) == 0) {
            return error.AppBarRegistrationFailed;
        }
        self.state = .active;
        errdefer self.unregister();
        try self.reposition();
    }

    fn unregister(self: *AppBar) void {
        if (self.state != .active) {
            return;
        }

        var app_bar_data = makeAppBarData(self.window, 0);
        _ = win32.SHAppBarMessage(win32.ABM_REMOVE, &app_bar_data);
        self.state = .suspended;
    }

    fn refreshDisplayConfiguration(self: *AppBar) Error!void {
        const monitor = resolveMonitor(self.preferred_monitor_index, self.monitor_id) orelse {
            self.unregister();
            return;
        };
        const proposed_rect = makeProposedRect(monitor.rect, self.edge, self.thickness) catch |err| {
            self.unregister();
            return err;
        };

        self.monitor_id = monitor.id;
        self.placement_rect = proposed_rect;
        if (self.state == .suspended) {
            try self.activate();
            return;
        }
        if (self.state == .active) {
            try self.reposition();
        }
    }

    fn reposition(self: *AppBar) Error!void {
        self.queryPosition();
        try self.applyPosition();
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

const State = enum {
    active,
    suspended,
    cleaned,
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

const MonitorId = [128]windows.WCHAR;

const Monitor = struct {
    rect: win32.RECT,
    id: ?MonitorId,
};

const MonitorSearch = struct {
    target: union(enum) {
        index: u32,
        id: MonitorId,
    },
    monitor: ?Monitor = null,
};

fn resolveMonitor(preferred_index: u32, previous_id: ?MonitorId) ?Monitor {
    if (previous_id) |id| {
        if (findMonitorById(id)) |monitor| {
            return monitor;
        }
    }
    return findMonitorByIndex(preferred_index) orelse findMonitorByIndex(0);
}

fn findMonitorById(id: MonitorId) ?Monitor {
    var search = MonitorSearch{ .target = .{ .id = id } };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        findMonitorCallback,
        @bitCast(@intFromPtr(&search)),
    );
    return search.monitor;
}

fn findMonitorByIndex(index: u32) ?Monitor {
    var search = MonitorSearch{ .target = .{ .index = index } };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        findMonitorCallback,
        @bitCast(@intFromPtr(&search)),
    );
    return search.monitor;
}

fn findMonitorCallback(
    monitor_handle: win32.HMONITOR,
    _: ?std.os.windows.HDC,
    monitor_rect: *win32.RECT,
    data: LParam,
) callconv(.winapi) std.os.windows.BOOL {
    const search: *MonitorSearch = @ptrFromInt(@as(usize, @bitCast(data)));
    const monitor = Monitor{
        .rect = monitor_rect.*,
        .id = getMonitorId(monitor_handle),
    };

    switch (search.target) {
        .index => |*index| {
            if (index.* == 0) {
                search.monitor = monitor;
                return .FALSE;
            }
            index.* -= 1;
        },
        .id => |id| {
            if (monitor.id) |monitor_id| {
                if (monitorIdsEqual(monitor_id, id)) {
                    search.monitor = monitor;
                    return .FALSE;
                }
            }
        },
    }
    return .TRUE;
}

fn getMonitorId(monitor: win32.HMONITOR) ?MonitorId {
    var monitor_info = win32.MONITORINFOEXW{
        .cbSize = @sizeOf(win32.MONITORINFOEXW),
        .rcMonitor = undefined,
        .rcWork = undefined,
        .dwFlags = 0,
        .szDevice = [_]windows.WCHAR{0} ** 32,
    };
    if (!win32.GetMonitorInfoW(monitor, &monitor_info).toBool()) {
        return null;
    }

    var display_device = win32.DISPLAY_DEVICEW{
        .cb = @sizeOf(win32.DISPLAY_DEVICEW),
        .DeviceName = [_]windows.WCHAR{0} ** 32,
        .DeviceString = [_]windows.WCHAR{0} ** 128,
        .StateFlags = 0,
        .DeviceID = [_]windows.WCHAR{0} ** 128,
        .DeviceKey = [_]windows.WCHAR{0} ** 128,
    };
    if (!win32.EnumDisplayDevicesW(
        @ptrCast(&monitor_info.szDevice),
        0,
        &display_device,
        win32.EDD_GET_DEVICE_INTERFACE_NAME,
    ).toBool()) {
        return null;
    }
    if (display_device.DeviceID[0] == 0) {
        return null;
    }
    return display_device.DeviceID;
}

fn monitorIdsEqual(first: MonitorId, second: MonitorId) bool {
    return std.mem.eql(windows.WCHAR, first[0..], second[0..]);
}

fn selectMonitorFromSlice(
    monitors: []const Monitor,
    preferred_index: u32,
    previous_id: ?MonitorId,
) ?Monitor {
    if (previous_id) |id| {
        for (monitors) |monitor| {
            if (monitor.id) |monitor_id| {
                if (monitorIdsEqual(monitor_id, id)) {
                    return monitor;
                }
            }
        }
    }
    if (preferred_index < monitors.len) {
        return monitors[preferred_index];
    }
    if (monitors.len != 0) {
        return monitors[0];
    }
    return null;
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

const MessageAction = enum {
    none,
    display_changed,
    dpi_changed,
    window_position_changed,
    position_changed,
    callback,
};

fn messageAction(callback_message: Message, message: Message, wparam: WParam) MessageAction {
    if (message == callback_message) {
        return if (wparam == win32.ABN_POSCHANGED) .position_changed else .callback;
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
    return .none;
}

fn dpiFromWParam(wparam: WParam) u32 {
    return @intCast((wparam >> 16) & 0xffff);
}

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

test "AppBar callback messages are consumed" {
    const callback_message: Message = 0xc000;

    try std.testing.expectEqual(
        MessageAction.position_changed,
        messageAction(callback_message, callback_message, win32.ABN_POSCHANGED),
    );
    try std.testing.expectEqual(
        MessageAction.callback,
        messageAction(callback_message, callback_message, 0),
    );
}

test "window position changes are forwarded without being consumed" {
    try std.testing.expectEqual(
        MessageAction.window_position_changed,
        messageAction(0xc000, win32.WM_WINDOWPOSCHANGED, 0),
    );
    try std.testing.expectEqual(MessageAction.none, messageAction(0xc000, 1, 0));
}

test "display changes are forwarded without being consumed" {
    try std.testing.expectEqual(
        MessageAction.display_changed,
        messageAction(0xc000, win32.WM_DISPLAYCHANGE, 0),
    );
}

test "DPI changes are consumed and use the Y-axis DPI" {
    try std.testing.expectEqual(
        MessageAction.dpi_changed,
        messageAction(0xc000, win32.WM_DPICHANGED, 0),
    );
    const dpi_wparam: WParam = (@as(WParam, 144) << 16) | 120;
    try std.testing.expectEqual(@as(u32, 144), dpiFromWParam(dpi_wparam));
}

test "monitor selection prioritizes identity before index fallbacks" {
    var first_id = [_]windows.WCHAR{0} ** 128;
    first_id[0] = 1;
    var second_id = [_]windows.WCHAR{0} ** 128;
    second_id[0] = 2;
    const monitors = [_]Monitor{
        .{ .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 }, .id = first_id },
        .{ .rect = .{ .left = 100, .top = 0, .right = 200, .bottom = 100 }, .id = second_id },
    };

    const identity_match = selectMonitorFromSlice(&monitors, 0, second_id).?;
    try std.testing.expectEqual(@as(i32, 100), identity_match.rect.left);

    const preferred_index_match = selectMonitorFromSlice(&monitors, 1, null).?;
    try std.testing.expectEqual(@as(i32, 100), preferred_index_match.rect.left);

    const zero_index_fallback = selectMonitorFromSlice(&monitors, 9, null).?;
    try std.testing.expectEqual(@as(i32, 0), zero_index_fallback.rect.left);

    try std.testing.expect(selectMonitorFromSlice(&.{}, 0, null) == null);
}
