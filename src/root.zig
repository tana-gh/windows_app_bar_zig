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

/// A screen rectangle in physical pixels.
pub const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

const max_monitor_id_utf16_units = 127;
const max_monitor_id_utf8_bytes = max_monitor_id_utf16_units * 3;

/// A UTF-8 Windows monitor device interface identifier.
pub const MonitorId = struct {
    bytes: [max_monitor_id_utf8_bytes]u8,
    length: u16,

    /// Creates a monitor identifier from a valid UTF-8 device interface identifier.
    pub fn fromUtf8(value: []const u8) Error!MonitorId {
        if (value.len == 0 or
            value.len > max_monitor_id_utf8_bytes or
            std.mem.indexOfScalar(u8, value, 0) != null or
            !std.unicode.utf8ValidateSlice(value))
        {
            return error.InvalidMonitorId;
        }

        var utf16_length: usize = 0;
        var codepoint_iterator = (std.unicode.Utf8View.init(value) catch return error.InvalidMonitorId).iterator();
        while (codepoint_iterator.nextCodepoint()) |codepoint| {
            utf16_length += std.unicode.utf16CodepointSequenceLength(codepoint) catch {
                return error.InvalidMonitorId;
            };
        }
        if (utf16_length > max_monitor_id_utf16_units) {
            return error.InvalidMonitorId;
        }

        var monitor_id = MonitorId{
            .bytes = undefined,
            .length = @intCast(value.len),
        };
        @memcpy(monitor_id.bytes[0..value.len], value);
        return monitor_id;
    }

    /// Returns the monitor device interface identifier as UTF-8.
    pub fn utf8(self: *const MonitorId) []const u8 {
        return self.bytes[0..self.length];
    }
};

/// Selects a monitor by its current index or persistent device interface identifier.
pub const MonitorSelector = union(enum) {
    index: u32,
    id: MonitorId,
};

/// Information about one monitor in EnumDisplayMonitors order.
pub const MonitorInfo = struct {
    index: u32,
    id: ?MonitorId,
    rect: Rect,
};

/// The AppBar registration lifecycle state.
pub const Status = enum {
    active,
    suspended,
    cleaned,
};

pub const Error = error{
    CallbackMessageRegistrationFailed,
    TaskbarCreatedMessageRegistrationFailed,
    AppBarRegistrationFailed,
    MonitorNotFound,
    InvalidMonitorId,
    InvalidThickness,
    InvalidPlacementRect,
    WindowPlacementFailed,
    WindowZOrderFailed,
    AppBarCleaned,
    ConfigurationRollbackFailed,
};

pub const AppBar = struct {
    window_handle: WindowHandle,
    preferred_monitor_index: u32,
    edge_value: Edge,
    thickness_pixels: u32,
    callback_message: Message,
    taskbar_created_message: Message,
    monitor_rect: win32.RECT,
    placement_rect: win32.RECT,
    monitor_id: ?MonitorId,
    window_dpi: u32,
    is_repositioning: bool,
    is_hidden_for_window_arrange: bool,
    allows_automatic_reregistration: bool,
    state: Status,

    /// Registers an AppBar for a window.
    pub fn register(
        window_handle: WindowHandle,
        monitor_selector: MonitorSelector,
        requested_edge: Edge,
        requested_thickness: u32,
    ) Error!AppBar {
        const monitor = resolveMonitorSelector(monitor_selector) orelse return error.MonitorNotFound;
        const proposed_rect = try makeProposedRect(monitor.rect, requested_edge, requested_thickness);

        const callback_message = win32.RegisterWindowMessageW(callback_message_name.ptr);
        if (callback_message == 0) {
            return error.CallbackMessageRegistrationFailed;
        }
        const taskbar_created_message = win32.RegisterWindowMessageW(taskbar_created_message_name.ptr);
        if (taskbar_created_message == 0) {
            return error.TaskbarCreatedMessageRegistrationFailed;
        }

        var app_bar = AppBar{
            .window_handle = window_handle,
            .preferred_monitor_index = monitor.index,
            .edge_value = requested_edge,
            .thickness_pixels = requested_thickness,
            .callback_message = callback_message,
            .taskbar_created_message = taskbar_created_message,
            .monitor_rect = monitor.rect,
            .placement_rect = proposed_rect,
            .monitor_id = monitor.id,
            .window_dpi = 0,
            .is_repositioning = false,
            .is_hidden_for_window_arrange = false,
            .allows_automatic_reregistration = true,
            .state = .suspended,
        };
        errdefer app_bar.cleanup();
        try app_bar.registerWithShell();
        return app_bar;
    }

    /// Returns the window registered as this AppBar.
    pub fn window(self: *const AppBar) WindowHandle {
        return self.window_handle;
    }

    /// Returns the requested edge.
    pub fn edge(self: *const AppBar) Edge {
        return self.edge_value;
    }

    /// Returns the preferred zero-based monitor index.
    pub fn preferredMonitorIndex(self: *const AppBar) u32 {
        return self.preferred_monitor_index;
    }

    /// Returns the requested thickness in physical pixels.
    pub fn thickness(self: *const AppBar) u32 {
        return self.thickness_pixels;
    }

    /// Returns the current registration lifecycle state.
    pub fn status(self: *const AppBar) Status {
        return self.state;
    }

    /// Reports whether the AppBar is currently registered with the shell.
    pub fn isRegistered(self: *const AppBar) bool {
        return self.state == .active;
    }

    /// Shows the AppBar window without activating it.
    pub fn show(self: *AppBar) void {
        self.is_hidden_for_window_arrange = false;
        _ = win32.ShowWindow(self.window_handle, win32.SW_SHOWNOACTIVATE);
    }

    /// Hides the AppBar window while retaining its reserved screen area.
    pub fn hide(self: *AppBar) void {
        self.is_hidden_for_window_arrange = false;
        _ = win32.ShowWindow(self.window_handle, win32.SW_HIDE);
    }

    /// Reports whether the AppBar window is visible.
    pub fn isVisible(self: *const AppBar) bool {
        return win32.IsWindowVisible(self.window_handle).toBool();
    }

    /// Updates the requested edge and reapplies the AppBar position.
    pub fn setEdge(self: *AppBar, requested_edge: Edge) Error!void {
        if (self.edge_value == requested_edge) {
            return;
        }
        try self.setConfiguration(
            self.preferred_monitor_index,
            requested_edge,
            self.thickness_pixels,
            self.monitor_id,
        );
    }

    /// Updates the preferred monitor index and reapplies the AppBar position.
    pub fn setPreferredMonitorIndex(self: *AppBar, monitor_index: u32) Error!void {
        if (self.preferred_monitor_index == monitor_index) {
            return;
        }
        try self.setConfiguration(
            monitor_index,
            self.edge_value,
            self.thickness_pixels,
            null,
        );
    }

    /// Updates the requested thickness in physical pixels and reapplies the AppBar position.
    pub fn setThickness(self: *AppBar, requested_thickness: u32) Error!void {
        if (self.thickness_pixels == requested_thickness) {
            return;
        }
        try self.setConfiguration(
            self.preferred_monitor_index,
            self.edge_value,
            requested_thickness,
            self.monitor_id,
        );
    }

    /// Returns a fresh candidate rectangle for the currently selected monitor.
    pub fn proposedRect(self: *const AppBar) Error!Rect {
        const monitor = resolveMonitor(self.preferred_monitor_index, self.monitor_id) orelse {
            return error.MonitorNotFound;
        };
        return rectFromWin32(try makeProposedRect(monitor.rect, self.edge_value, self.thickness_pixels));
    }

    /// Returns the shell-approved rectangle while the AppBar is registered.
    pub fn reservedRect(self: *const AppBar) ?Rect {
        if (self.state != .active) {
            return null;
        }
        return rectFromWin32(self.placement_rect);
    }

    /// Re-queries, reserves, and applies the AppBar position.
    pub fn reapply(self: *AppBar) Error!void {
        if (!canReapply(self.state)) {
            return error.AppBarCleaned;
        }
        self.refreshDisplayConfiguration() catch |err| {
            self.unregisterFromShell();
            return err;
        };
    }

    /// Removes the AppBar registration and disables automatic re-registration.
    pub fn unregister(self: *AppBar) void {
        if (self.state == .cleaned) {
            return;
        }
        self.restoreWindowAfterArrange();
        self.allows_automatic_reregistration = false;
        self.unregisterFromShell();
    }

    /// Re-registers an AppBar that was previously unregistered.
    pub fn reregister(self: *AppBar) Error!void {
        if (!canReapply(self.state)) {
            return error.AppBarCleaned;
        }
        self.allows_automatic_reregistration = true;
        if (self.state == .active) {
            return;
        }
        try self.refreshDisplayConfiguration();
    }

    /// Removes the AppBar registration if it is active.
    pub fn cleanup(self: *AppBar) void {
        self.restoreWindowAfterArrange();
        self.unregisterFromShell();
        self.allows_automatic_reregistration = false;
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
                try self.restoreAfterTaskbarRestart();
                return true;
            },
            .display_changed => {
                if (self.state == .cleaned) {
                    return false;
                }
                try self.reapply();
                return false;
            },
            .dpi_changed => {
                if (self.state == .cleaned) {
                    return false;
                }
                self.window_dpi = dpiFromWParam(wparam);
                try self.reapply();
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
                var app_bar_data = makeAppBarData(self.window_handle, 0);
                _ = win32.SHAppBarMessage(win32.ABM_WINDOWPOSCHANGED, &app_bar_data);
                try self.reapply();
                return false;
            },
            .position_changed => {
                if (self.state != .active) {
                    return false;
                }
                self.reposition() catch |err| {
                    self.unregisterFromShell();
                    return err;
                };
                return true;
            },
            .state_changed => {
                if (!shouldRepositionForStateChange(self.state)) {
                    return false;
                }
                self.reposition() catch |err| {
                    self.unregisterFromShell();
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

    fn registerWithShell(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        if (win32.SHAppBarMessage(win32.ABM_NEW, &app_bar_data) == 0) {
            return error.AppBarRegistrationFailed;
        }
        self.state = .active;
        errdefer self.unregisterFromShell();
        try self.reposition();
    }

    fn unregisterFromShell(self: *AppBar) void {
        if (self.state != .active) {
            return;
        }

        var app_bar_data = makeAppBarData(self.window_handle, 0);
        _ = win32.SHAppBarMessage(win32.ABM_REMOVE, &app_bar_data);
        self.state = .suspended;
    }

    fn setConfiguration(
        self: *AppBar,
        monitor_index: u32,
        requested_edge: Edge,
        requested_thickness: u32,
        requested_monitor_id: ?MonitorId,
    ) Error!void {
        if (!canReapply(self.state)) {
            return error.AppBarCleaned;
        }

        const previous = ConfigurationSnapshot.fromAppBar(self);
        self.preferred_monitor_index = monitor_index;
        self.edge_value = requested_edge;
        self.thickness_pixels = requested_thickness;
        self.monitor_id = requested_monitor_id;

        self.reapply() catch |err| {
            previous.restore(self);
            if (previous.state == .active) {
                self.reapply() catch return error.ConfigurationRollbackFailed;
            }
            return err;
        };
    }

    fn refreshDisplayConfiguration(self: *AppBar) Error!void {
        const monitor = resolveMonitor(self.preferred_monitor_index, self.monitor_id) orelse {
            self.unregisterFromShell();
            return;
        };
        self.monitor_id = monitor.id;
        self.monitor_rect = monitor.rect;
        if (shouldAutomaticallyReregister(self.state, self.allows_automatic_reregistration)) {
            try self.registerWithShell();
            return;
        }
        if (self.state == .active) {
            try self.reposition();
        }
    }

    fn restoreAfterTaskbarRestart(self: *AppBar) Error!void {
        self.state = stateAfterTaskbarRestart(self.state);
        try self.reapply();
    }

    fn reposition(self: *AppBar) Error!void {
        if (self.is_repositioning) {
            return;
        }
        self.is_repositioning = true;
        defer self.is_repositioning = false;
        const proposed_rect = try makeProposedRect(self.monitor_rect, self.edge_value, self.thickness_pixels);
        self.queryPosition(proposed_rect);
        try self.applyPosition();
    }

    fn queryPosition(self: *AppBar, proposed_rect: win32.RECT) void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.edge_value);
        app_bar_data.rc = proposed_rect;
        _ = win32.SHAppBarMessage(win32.ABM_QUERYPOS, &app_bar_data);
        self.placement_rect = preserveThickness(app_bar_data.rc, self.edge_value, self.thickness_pixels);
    }

    fn notifyActivation(self: *AppBar, is_active: bool) void {
        var app_bar_data = makeAppBarData(self.window_handle, 0);
        app_bar_data.lParam = appBarActivationLParam(is_active);
        _ = win32.SHAppBarMessage(win32.ABM_ACTIVATE, &app_bar_data);
    }

    fn setFullscreenZOrder(self: *AppBar, is_opening: bool) Error!void {
        const insert_after: ?WindowHandle = if (is_opening) win32.HWND_BOTTOM else null;
        const flags = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(self.window_handle, insert_after, 0, 0, 0, 0, flags).toBool()) {
            return error.WindowZOrderFailed;
        }
    }

    fn handleWindowArrange(self: *AppBar, is_beginning: bool) void {
        if (is_beginning) {
            if (shouldHideForWindowArrange(
                self.is_hidden_for_window_arrange,
                win32.IsWindowVisible(self.window_handle).toBool(),
            )) {
                _ = win32.ShowWindow(self.window_handle, win32.SW_HIDE);
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
        _ = win32.ShowWindow(self.window_handle, win32.SW_SHOWNOACTIVATE);
    }

    fn applyPosition(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.edge_value);
        app_bar_data.rc = self.placement_rect;
        _ = win32.SHAppBarMessage(win32.ABM_SETPOS, &app_bar_data);
        self.placement_rect = app_bar_data.rc;

        const position = try windowPositionFromRect(self.placement_rect);
        const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(
            self.window_handle,
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

const ConfigurationSnapshot = struct {
    preferred_monitor_index: u32,
    edge_value: Edge,
    thickness_pixels: u32,
    monitor_rect: win32.RECT,
    placement_rect: win32.RECT,
    monitor_id: ?MonitorId,
    state: Status,

    fn fromAppBar(app_bar: *const AppBar) ConfigurationSnapshot {
        return .{
            .preferred_monitor_index = app_bar.preferred_monitor_index,
            .edge_value = app_bar.edge_value,
            .thickness_pixels = app_bar.thickness_pixels,
            .monitor_rect = app_bar.monitor_rect,
            .placement_rect = app_bar.placement_rect,
            .monitor_id = app_bar.monitor_id,
            .state = app_bar.state,
        };
    }

    fn restore(self: ConfigurationSnapshot, app_bar: *AppBar) void {
        app_bar.preferred_monitor_index = self.preferred_monitor_index;
        app_bar.edge_value = self.edge_value;
        app_bar.thickness_pixels = self.thickness_pixels;
        app_bar.monitor_rect = self.monitor_rect;
        app_bar.placement_rect = self.placement_rect;
        app_bar.monitor_id = self.monitor_id;
    }
};

const callback_message_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "windows_app_bar.AppBarCallback.v1",
);

const taskbar_created_message_name = std.unicode.utf8ToUtf16LeStringLiteral(
    "TaskbarCreated",
);

fn rectFromWin32(rect: win32.RECT) Rect {
    return .{
        .left = rect.left,
        .top = rect.top,
        .right = rect.right,
        .bottom = rect.bottom,
    };
}

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

const Monitor = struct {
    index: u32,
    rect: win32.RECT,
    id: ?MonitorId,
};

const MonitorSearch = struct {
    target: MonitorSelector,
    next_index: u32 = 0,
    monitor: ?Monitor = null,
};

const MonitorEnumeration = struct {
    monitors: *std.array_list.Managed(MonitorInfo),
    next_index: u32 = 0,
    allocation_failed: bool = false,
};

/// Enumerates monitors in the zero-based order used by MonitorSelector.index.
/// The caller owns the returned slice and must free it with allocator.
pub fn enumerateMonitors(allocator: std.mem.Allocator) std.mem.Allocator.Error![]MonitorInfo {
    var monitors = std.array_list.Managed(MonitorInfo).init(allocator);
    errdefer monitors.deinit();

    var enumeration = MonitorEnumeration{ .monitors = &monitors };
    _ = win32.EnumDisplayMonitors(
        null,
        null,
        enumerateMonitorCallback,
        @bitCast(@intFromPtr(&enumeration)),
    );
    if (enumeration.allocation_failed) {
        return error.OutOfMemory;
    }
    return monitors.toOwnedSlice();
}

fn resolveMonitorSelector(selector: MonitorSelector) ?Monitor {
    return switch (selector) {
        .index => |index| resolveMonitor(index, null),
        .id => |id| findMonitorById(id),
    };
}

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
    if (search.next_index == std.math.maxInt(u32)) {
        return .FALSE;
    }
    const monitor = monitorFromHandle(monitor_handle, monitor_rect.*, search.next_index);
    search.next_index += 1;

    switch (search.target) {
        .index => |index| {
            if (monitor.index == index) {
                search.monitor = monitor;
                return .FALSE;
            }
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

fn enumerateMonitorCallback(
    monitor_handle: win32.HMONITOR,
    _: ?std.os.windows.HDC,
    monitor_rect: *win32.RECT,
    data: LParam,
) callconv(.winapi) std.os.windows.BOOL {
    const enumeration: *MonitorEnumeration = @ptrFromInt(@as(usize, @bitCast(data)));
    if (enumeration.next_index == std.math.maxInt(u32)) {
        return .FALSE;
    }
    const monitor = monitorFromHandle(monitor_handle, monitor_rect.*, enumeration.next_index);
    enumeration.next_index += 1;
    enumeration.monitors.append(.{
        .index = monitor.index,
        .id = monitor.id,
        .rect = rectFromWin32(monitor.rect),
    }) catch {
        enumeration.allocation_failed = true;
        return .FALSE;
    };
    return .TRUE;
}

fn monitorFromHandle(monitor_handle: win32.HMONITOR, rect: win32.RECT, index: u32) Monitor {
    return .{
        .index = index,
        .rect = rect,
        .id = getMonitorId(monitor_handle),
    };
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
    return monitorIdFromUtf16(&display_device.DeviceID);
}

fn monitorIdFromUtf16(utf16: []const windows.WCHAR) ?MonitorId {
    const length = std.mem.indexOfScalar(windows.WCHAR, utf16, 0) orelse utf16.len;
    if (length == 0) {
        return null;
    }

    var bytes: [max_monitor_id_utf8_bytes]u8 = undefined;
    const utf8_length = std.unicode.utf16LeToUtf8(bytes[0..], utf16[0..length]) catch return null;
    return .{
        .bytes = bytes,
        .length = @intCast(utf8_length),
    };
}

fn monitorIdsEqual(first: MonitorId, second: MonitorId) bool {
    return std.mem.eql(u8, first.utf8(), second.utf8());
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

fn stateAfterTaskbarRestart(state: Status) Status {
    return switch (state) {
        .active => .suspended,
        .suspended, .cleaned => state,
    };
}

fn dpiFromWParam(wparam: WParam) u32 {
    return @intCast((wparam >> 16) & 0xffff);
}

fn shouldRepositionForStateChange(state: Status) bool {
    return state == .active;
}

fn canReapply(state: Status) bool {
    return state != .cleaned;
}

fn shouldAutomaticallyReregister(state: Status, allows_automatic_reregistration: bool) bool {
    return state == .suspended and allows_automatic_reregistration;
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

test "MonitorId stores valid UTF-8 monitor identifiers" {
    const monitor_id = try MonitorId.fromUtf8("monitor-\u{1f5a5}");
    try std.testing.expectEqualStrings("monitor-\u{1f5a5}", monitor_id.utf8());
    try std.testing.expectError(error.InvalidMonitorId, MonitorId.fromUtf8(""));
    try std.testing.expectError(error.InvalidMonitorId, MonitorId.fromUtf8("invalid\x00id"));
    try std.testing.expectError(error.InvalidMonitorId, MonitorId.fromUtf8("\xff"));
}

test "APPBARDATA contains the ABM_NEW fields required by the Windows SDK" {
    const window: WindowHandle = @ptrFromInt(1);
    const callback_message: Message = 0xc000;
    const app_bar_data = makeAppBarData(window, callback_message);

    try std.testing.expectEqual(@as(u32, @sizeOf(win32.APPBARDATA)), app_bar_data.cbSize);
    try std.testing.expectEqual(window, app_bar_data.hWnd);
    try std.testing.expectEqual(callback_message, app_bar_data.uCallbackMessage);
}

test "read-only AppBar APIs expose configuration and active reservation" {
    const window: WindowHandle = @ptrFromInt(1);
    const placement_rect = win32.RECT{ .left = -20, .top = 10, .right = 180, .bottom = 110 };
    const app_bar = AppBar{
        .window_handle = window,
        .preferred_monitor_index = 2,
        .edge_value = .right,
        .thickness_pixels = 200,
        .callback_message = 0xc000,
        .taskbar_created_message = 0xc001,
        .monitor_rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
        .placement_rect = placement_rect,
        .monitor_id = null,
        .window_dpi = 0,
        .is_repositioning = false,
        .is_hidden_for_window_arrange = false,
        .allows_automatic_reregistration = true,
        .state = .active,
    };

    try std.testing.expectEqual(window, app_bar.window());
    try std.testing.expectEqual(Edge.right, app_bar.edge());
    try std.testing.expectEqual(@as(u32, 2), app_bar.preferredMonitorIndex());
    try std.testing.expectEqual(@as(u32, 200), app_bar.thickness());
    try std.testing.expectEqual(Status.active, app_bar.status());
    try std.testing.expect(app_bar.isRegistered());
    try std.testing.expectEqual(Rect{ .left = -20, .top = 10, .right = 180, .bottom = 110 }, app_bar.reservedRect().?);
}

test "configuration snapshots restore the previous AppBar settings" {
    var app_bar = AppBar{
        .window_handle = @ptrFromInt(1),
        .preferred_monitor_index = 1,
        .edge_value = .left,
        .thickness_pixels = 120,
        .callback_message = 0xc000,
        .taskbar_created_message = 0xc001,
        .monitor_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .placement_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .monitor_id = null,
        .window_dpi = 0,
        .is_repositioning = false,
        .is_hidden_for_window_arrange = false,
        .allows_automatic_reregistration = true,
        .state = .active,
    };
    const snapshot = ConfigurationSnapshot.fromAppBar(&app_bar);

    app_bar.preferred_monitor_index = 2;
    app_bar.edge_value = .bottom;
    app_bar.thickness_pixels = 200;
    app_bar.monitor_rect.right = 200;
    snapshot.restore(&app_bar);

    try std.testing.expectEqual(@as(u32, 1), app_bar.preferredMonitorIndex());
    try std.testing.expectEqual(Edge.left, app_bar.edge());
    try std.testing.expectEqual(@as(u32, 120), app_bar.thickness());
    try std.testing.expectEqual(@as(i32, 100), app_bar.monitor_rect.right);
}

test "reserved rectangle is unavailable while the AppBar is not active" {
    var app_bar = AppBar{
        .window_handle = @ptrFromInt(1),
        .preferred_monitor_index = 0,
        .edge_value = .bottom,
        .thickness_pixels = 100,
        .callback_message = 0xc000,
        .taskbar_created_message = 0xc001,
        .monitor_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .placement_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .monitor_id = null,
        .window_dpi = 0,
        .is_repositioning = false,
        .is_hidden_for_window_arrange = false,
        .allows_automatic_reregistration = true,
        .state = .suspended,
    };

    try std.testing.expect(app_bar.reservedRect() == null);
    try std.testing.expectEqual(Status.suspended, app_bar.status());
    try std.testing.expect(!app_bar.isRegistered());
    app_bar.state = .cleaned;
    try std.testing.expect(app_bar.reservedRect() == null);
    try std.testing.expectEqual(Status.cleaned, app_bar.status());
    try std.testing.expect(!app_bar.isRegistered());
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
    try std.testing.expectEqual(Status.suspended, stateAfterTaskbarRestart(.active));
    try std.testing.expectEqual(Status.suspended, stateAfterTaskbarRestart(.suspended));
    try std.testing.expectEqual(Status.cleaned, stateAfterTaskbarRestart(.cleaned));
}

test "monitor selection prioritizes identity before index fallbacks" {
    const first_id = try MonitorId.fromUtf8("first");
    const second_id = try MonitorId.fromUtf8("second");
    const monitors = [_]Monitor{
        .{ .index = 0, .rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 }, .id = first_id },
        .{ .index = 1, .rect = .{ .left = 100, .top = 0, .right = 200, .bottom = 100 }, .id = second_id },
    };

    const identity_match = selectMonitorFromSlice(&monitors, 0, second_id).?;
    try std.testing.expectEqual(@as(i32, 100), identity_match.rect.left);
    try std.testing.expectEqual(@as(u32, 1), identity_match.index);

    const preferred_index_match = selectMonitorFromSlice(&monitors, 1, null).?;
    try std.testing.expectEqual(@as(i32, 100), preferred_index_match.rect.left);

    const zero_index_fallback = selectMonitorFromSlice(&monitors, 9, null).?;
    try std.testing.expectEqual(@as(i32, 0), zero_index_fallback.rect.left);

    try std.testing.expect(selectMonitorFromSlice(&.{}, 0, null) == null);
}
