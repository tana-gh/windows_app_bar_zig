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
    TaskbarCreatedMessageRegistrationFailed,
    AppBarRegistrationFailed,
    MonitorNotFound,
    InvalidThickness,
    InvalidPlacementRect,
    WindowPlacementFailed,
    WindowZOrderFailed,
};

pub const AppBar = struct {
    window: WindowHandle,
    preferred_monitor_index: u32,
    edge: Edge,
    thickness: u32,
    callback_message: Message,
    taskbar_created_message: Message,
    monitor_rect: win32.RECT,
    placement_rect: win32.RECT,
    monitor_id: ?MonitorId,
    window_dpi: u32,
    is_repositioning: bool,
    is_hidden_for_window_arrange: bool,
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
        const taskbar_created_message = win32.RegisterWindowMessageW(taskbar_created_message_name.ptr);
        if (taskbar_created_message == 0) {
            return error.TaskbarCreatedMessageRegistrationFailed;
        }

        var app_bar = AppBar{
            .window = window,
            .preferred_monitor_index = monitor_index,
            .edge = edge,
            .thickness = thickness,
            .callback_message = callback_message,
            .taskbar_created_message = taskbar_created_message,
            .monitor_rect = monitor.rect,
            .placement_rect = proposed_rect,
            .monitor_id = monitor.id,
            .window_dpi = 0,
            .is_repositioning = false,
            .is_hidden_for_window_arrange = false,
            .state = .suspended,
        };
        errdefer app_bar.cleanup();
        try app_bar.activate();
        return app_bar;
    }

    /// Removes the AppBar registration if it is active.
    pub fn cleanup(self: *AppBar) void {
        self.restoreWindowAfterArrange();
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
        switch (messageAction(self.callback_message, self.taskbar_created_message, message, wparam)) {
            .none => return false,
            .taskbar_created => {
                if (self.state == .cleaned) {
                    return false;
                }
                self.restoreAfterTaskbarRestart() catch |err| {
                    self.unregister();
                    return err;
                };
                return true;
            },
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
            .activation_changed => {
                if (self.state == .active) {
                    self.notifyActivation(wparam != win32.WA_INACTIVE);
                }
                return false;
            },
            .window_position_changed => {
                if (self.state != .active) {
                    return false;
                }
                if (self.is_hidden_for_window_arrange or self.is_repositioning) {
                    return false;
                }
                var app_bar_data = makeAppBarData(self.window, 0);
                _ = win32.SHAppBarMessage(win32.ABM_WINDOWPOSCHANGED, &app_bar_data);
                self.refreshDisplayConfiguration() catch |err| {
                    self.unregister();
                    return err;
                };
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
            .state_changed => {
                if (!shouldRepositionForStateChange(self.state)) {
                    return false;
                }
                self.reposition() catch |err| {
                    self.unregister();
                    return err;
                };
                return true;
            },
            .fullscreen_app => {
                if (self.state != .active) {
                    return false;
                }
                try self.setFullscreenZOrder(fullscreenAppIsOpening(lparam));
                return true;
            },
            .window_arrange => {
                if (self.state != .active) {
                    return false;
                }
                self.handleWindowArrange(windowArrangeIsBeginning(lparam));
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
        self.monitor_id = monitor.id;
        self.monitor_rect = monitor.rect;
        if (self.state == .suspended) {
            try self.activate();
            return;
        }
        if (self.state == .active) {
            try self.reposition();
        }
    }

    fn restoreAfterTaskbarRestart(self: *AppBar) Error!void {
        self.state = stateAfterTaskbarRestart(self.state);
        try self.refreshDisplayConfiguration();
    }

    fn reposition(self: *AppBar) Error!void {
        if (self.is_repositioning) {
            return;
        }
        self.is_repositioning = true;
        defer self.is_repositioning = false;
        const proposed_rect = try makeProposedRect(self.monitor_rect, self.edge, self.thickness);
        self.queryPosition(proposed_rect);
        try self.applyPosition();
    }

    fn queryPosition(self: *AppBar, proposed_rect: win32.RECT) void {
        var app_bar_data = makeAppBarData(self.window, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.edge);
        app_bar_data.rc = proposed_rect;
        _ = win32.SHAppBarMessage(win32.ABM_QUERYPOS, &app_bar_data);
        self.placement_rect = preserveThickness(app_bar_data.rc, self.edge, self.thickness);
    }

    fn notifyActivation(self: *AppBar, is_active: bool) void {
        var app_bar_data = makeAppBarData(self.window, 0);
        app_bar_data.lParam = appBarActivationLParam(is_active);
        _ = win32.SHAppBarMessage(win32.ABM_ACTIVATE, &app_bar_data);
    }

    fn setFullscreenZOrder(self: *AppBar, is_opening: bool) Error!void {
        const insert_after: ?WindowHandle = if (is_opening) win32.HWND_BOTTOM else null;
        const flags = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(self.window, insert_after, 0, 0, 0, 0, flags).toBool()) {
            return error.WindowZOrderFailed;
        }
    }

    fn handleWindowArrange(self: *AppBar, is_beginning: bool) void {
        if (is_beginning) {
            if (shouldHideForWindowArrange(
                self.is_hidden_for_window_arrange,
                win32.IsWindowVisible(self.window).toBool(),
            )) {
                _ = win32.ShowWindow(self.window, win32.SW_HIDE);
                self.is_hidden_for_window_arrange = true;
            }
            return;
        }
        self.restoreWindowAfterArrange();
    }

    fn restoreWindowAfterArrange(self: *AppBar) void {
        if (!shouldShowAfterWindowArrange(self.is_hidden_for_window_arrange)) {
            return;
        }
        self.is_hidden_for_window_arrange = false;
        _ = win32.ShowWindow(self.window, win32.SW_SHOWNOACTIVATE);
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

const taskbar_created_message_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "TaskbarCreated",
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

fn messageAction(
    callback_message: Message,
    taskbar_created_message: Message,
    message: Message,
    wparam: WParam,
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

fn stateAfterTaskbarRestart(state: State) State {
    return switch (state) {
        .active => .suspended,
        .suspended, .cleaned => state,
    };
}

fn dpiFromWParam(wparam: WParam) u32 {
    return @intCast((wparam >> 16) & 0xffff);
}

fn shouldRepositionForStateChange(state: State) bool {
    return state == .active;
}

fn appBarActivationLParam(is_active: bool) LParam {
    return @intFromBool(is_active);
}

fn fullscreenAppIsOpening(lparam: LParam) bool {
    return lparam != 0;
}

fn windowArrangeIsBeginning(lparam: LParam) bool {
    return lparam != 0;
}

fn shouldHideForWindowArrange(is_hidden_for_window_arrange: bool, is_window_visible: bool) bool {
    return !is_hidden_for_window_arrange and is_window_visible;
}

fn shouldShowAfterWindowArrange(is_hidden_for_window_arrange: bool) bool {
    return is_hidden_for_window_arrange;
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

test "position queries rebuild candidates from the monitor edge" {
    const monitor_rect = win32.RECT{
        .left = 0,
        .top = 0,
        .right = 1000,
        .bottom = 1000,
    };
    const previous_approved_rect = win32.RECT{
        .left = 0,
        .top = 860,
        .right = 1000,
        .bottom = 960,
    };

    const candidate = try makeProposedRect(monitor_rect, .bottom, 100);
    try std.testing.expect(candidate.top != previous_approved_rect.top);
    try std.testing.expectEqual(@as(i32, 900), candidate.top);
    try std.testing.expectEqual(@as(i32, 1000), candidate.bottom);
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
    const dpi_wparam: WParam = (@as(WParam, 144) << 16) | 120;
    try std.testing.expectEqual(@as(u32, 144), dpiFromWParam(dpi_wparam));
}

test "activation changes are forwarded and report the active state" {
    try std.testing.expectEqual(
        MessageAction.activation_changed,
        messageAction(0xc000, 0xc001, win32.WM_ACTIVATE, 0),
    );
    try std.testing.expectEqual(@as(LParam, 0), appBarActivationLParam(false));
    try std.testing.expectEqual(@as(LParam, 1), appBarActivationLParam(true));
}

test "taskbar state changes reconfigure active AppBars" {
    try std.testing.expect(shouldRepositionForStateChange(.active));
    try std.testing.expect(!shouldRepositionForStateChange(.suspended));
    try std.testing.expect(!shouldRepositionForStateChange(.cleaned));
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
    try std.testing.expectEqual(State.suspended, stateAfterTaskbarRestart(.active));
    try std.testing.expectEqual(State.suspended, stateAfterTaskbarRestart(.suspended));
    try std.testing.expectEqual(State.cleaned, stateAfterTaskbarRestart(.cleaned));
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
