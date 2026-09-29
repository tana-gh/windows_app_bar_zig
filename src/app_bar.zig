const std = @import("std");
const api = @import("api.zig");
const geometry = @import("geometry.zig");
const message_handler = @import("message.zig");
const monitor = @import("monitor.zig");
const win32 = @import("win32.zig");

const WindowHandle = api.WindowHandle;
const Message = api.Message;
const WParam = api.WParam;
const LParam = api.LParam;
const Edge = api.Edge;
const Rect = api.Rect;
const MonitorId = api.MonitorId;
const AppBarConfig = api.AppBarConfig;
const Status = api.Status;
const Error = api.Error;

pub const AppBar = struct {
    window_handle: WindowHandle,
    configuration: PlacementConfiguration,
    callback_message: Message,
    taskbar_created_message: Message,
    monitor_rect: win32.RECT,
    placement_rect: win32.RECT,
    is_repositioning: bool,
    is_hidden_for_window_arrange: bool,
    allows_automatic_reregistration: bool,
    state: Status,

    /// Registers an AppBar for a window using the requested placement configuration.
    pub fn register(window_handle: WindowHandle, config: AppBarConfig) Error!AppBar {
        const selected_monitor = monitor.resolveMonitorTarget(config.monitor) orelse return error.MonitorNotFound;
        const proposed_rect = try geometry.makeProposedRect(selected_monitor.rect, config.edge, config.thickness);
        const callback_message = win32.RegisterWindowMessageW(callback_message_name.ptr);
        if (callback_message == 0) return error.CallbackMessageRegistrationFailed;
        const taskbar_created_message = win32.RegisterWindowMessageW(taskbar_created_message_name.ptr);
        if (taskbar_created_message == 0) return error.TaskbarCreatedMessageRegistrationFailed;

        var app_bar = AppBar{
            .window_handle = window_handle,
            .configuration = .{
                .fallback_monitor_index = selected_monitor.index,
                .edge = config.edge,
                .thickness = config.thickness,
                .monitor_id = selected_monitor.id,
            },
            .callback_message = callback_message,
            .taskbar_created_message = taskbar_created_message,
            .monitor_rect = selected_monitor.rect,
            .placement_rect = proposed_rect,
            .is_repositioning = false,
            .is_hidden_for_window_arrange = false,
            .allows_automatic_reregistration = true,
            .state = .suspended,
        };
        errdefer app_bar.deinit();
        try app_bar.registerWithShell();
        return app_bar;
    }

    /// Returns the window registered as this AppBar.
    pub fn window(self: *const AppBar) WindowHandle {
        return self.window_handle;
    }
    /// Returns the requested edge.
    pub fn edge(self: *const AppBar) Edge {
        return self.configuration.edge;
    }
    /// Returns the zero-based monitor index used if the monitor ID is unavailable.
    pub fn fallbackMonitorIndex(self: *const AppBar) u32 {
        return self.configuration.fallback_monitor_index;
    }
    /// Returns the requested thickness in physical pixels.
    pub fn thickness(self: *const AppBar) u32 {
        return self.configuration.thickness;
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

    /// Updates the requested edge and refreshes the AppBar position.
    pub fn setEdge(self: *AppBar, requested_edge: Edge) Error!void {
        if (self.configuration.edge == requested_edge) return;
        var configuration = self.configuration;
        configuration.edge = requested_edge;
        try self.setConfiguration(configuration);
    }

    /// Updates the target monitor and refreshes the AppBar position.
    pub fn setMonitor(self: *AppBar, target: api.MonitorTarget) Error!void {
        const selected_monitor = monitor.resolveMonitorTarget(target) orelse return error.MonitorNotFound;
        try self.setConfiguration(configurationForMonitor(self.configuration, selected_monitor));
    }

    /// Updates the fallback monitor index and refreshes the AppBar position.
    pub fn setFallbackMonitorIndex(self: *AppBar, monitor_index: u32) Error!void {
        if (self.configuration.fallback_monitor_index == monitor_index) return;
        var configuration = self.configuration;
        configuration.fallback_monitor_index = monitor_index;
        configuration.monitor_id = null;
        try self.setConfiguration(configuration);
    }

    /// Updates the requested thickness in physical pixels and refreshes the AppBar position.
    pub fn setThickness(self: *AppBar, requested_thickness: u32) Error!void {
        if (self.configuration.thickness == requested_thickness) return;
        var configuration = self.configuration;
        configuration.thickness = requested_thickness;
        try self.setConfiguration(configuration);
    }

    /// Returns a fresh candidate rectangle for the currently selected monitor.
    pub fn candidateRect(self: *const AppBar) Error!Rect {
        const selected_monitor = monitor.resolveMonitor(self.configuration.fallback_monitor_index, self.configuration.monitor_id) orelse return error.MonitorNotFound;
        return monitor.rectFromWin32(try geometry.makeProposedRect(selected_monitor.rect, self.configuration.edge, self.configuration.thickness));
    }

    /// Returns the shell-allocated rectangle while the AppBar is registered.
    pub fn allocatedRect(self: *const AppBar) ?Rect {
        if (self.state != .active) return null;
        return monitor.rectFromWin32(self.placement_rect);
    }

    /// Re-resolves the monitor and updates the AppBar position.
    pub fn refresh(self: *AppBar) Error!void {
        if (!message_handler.canRefresh(self.state)) return error.AppBarDeinitialized;
        self.refreshDisplayConfiguration() catch |err| {
            self.unregisterFromShell();
            return err;
        };
    }

    /// Removes the AppBar registration and disables automatic re-registration.
    pub fn unregister(self: *AppBar) void {
        if (self.state == .deinitialized) return;
        self.restoreWindowAfterArrange();
        self.allows_automatic_reregistration = false;
        self.unregisterFromShell();
    }

    /// Re-registers an AppBar that was previously unregistered.
    pub fn reregister(self: *AppBar) Error!void {
        if (!message_handler.canRefresh(self.state)) return error.AppBarDeinitialized;
        self.allows_automatic_reregistration = true;
        if (self.state == .active) return;
        try self.refreshDisplayConfiguration();
    }

    /// Releases the AppBar registration and makes this value unusable.
    pub fn deinit(self: *AppBar) void {
        self.restoreWindowAfterArrange();
        self.unregisterFromShell();
        self.allows_automatic_reregistration = false;
        self.state = .deinitialized;
    }

    /// Handles a Windows message and reports whether it was consumed.
    pub fn handleMessage(self: *AppBar, message: Message, wparam: WParam, lparam: LParam) Error!bool {
        switch (message_handler.messageAction(self.callback_message, self.taskbar_created_message, message, wparam)) {
            .none => return false,
            .taskbar_created => {
                return self.restoreAfterTaskbarRestartIfUsable();
            },
            .display_changed => {
                _ = try self.refreshIfUsable();
                return false;
            },
            .dpi_changed => {
                _ = try self.refreshIfUsable();
                return false;
            },
            .activation_changed => {
                if (self.state == .active) self.notifyActivation(message_handler.activationIsActive(wparam));
                return false;
            },
            .window_position_changed => {
                if (self.state != .active or self.is_hidden_for_window_arrange or self.is_repositioning) return false;
                var app_bar_data = makeAppBarData(self.window_handle, 0);
                _ = win32.SHAppBarMessage(win32.ABM_WINDOWPOSCHANGED, &app_bar_data);
                try self.refresh();
                return false;
            },
            .position_changed, .state_changed => {
                if (self.state != .active) return false;
                try self.repositionOrSuspend();
                return true;
            },
            .fullscreen_app => {
                if (self.state != .active) return false;
                try self.setFullscreenZOrder();
                return true;
            },
            .window_arrange => {
                if (self.state != .active) return false;
                self.handleWindowArrange(message_handler.windowArrangeIsBeginning(lparam));
                return true;
            },
            .callback => return self.state == .active,
        }
    }

    fn registerWithShell(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        if (win32.SHAppBarMessage(win32.ABM_NEW, &app_bar_data) == 0) return error.AppBarRegistrationFailed;
        self.state = .active;
        errdefer self.unregisterFromShell();
        try self.reposition();
    }

    fn unregisterFromShell(self: *AppBar) void {
        if (self.state != .active) return;
        var app_bar_data = makeAppBarData(self.window_handle, 0);
        _ = win32.SHAppBarMessage(win32.ABM_REMOVE, &app_bar_data);
        self.state = .suspended;
    }

    fn setConfiguration(self: *AppBar, configuration: PlacementConfiguration) Error!void {
        if (!message_handler.canRefresh(self.state)) return error.AppBarDeinitialized;
        const selected_monitor = monitor.resolveMonitor(configuration.fallback_monitor_index, configuration.monitor_id);
        try validatePlacementConfiguration(configuration, if (selected_monitor) |value| value.rect else null);
        const previous = ConfigurationSnapshot.fromAppBar(self);
        self.configuration = configuration;
        self.refresh() catch |err| {
            previous.restore(self);
            if (previous.was_registered) self.refresh() catch return error.ConfigurationRollbackFailed;
            return err;
        };
    }

    fn refreshDisplayConfiguration(self: *AppBar) Error!void {
        const selected_monitor = monitor.resolveMonitor(self.configuration.fallback_monitor_index, self.configuration.monitor_id) orelse {
            self.unregisterFromShell();
            return;
        };
        self.configuration.monitor_id = selected_monitor.id;
        self.monitor_rect = selected_monitor.rect;
        if (message_handler.shouldAutomaticallyReregister(self.state, self.allows_automatic_reregistration)) {
            try self.registerWithShell();
            return;
        }
        if (self.state == .active) try self.reposition();
    }

    fn restoreAfterTaskbarRestart(self: *AppBar) Error!void {
        self.state = message_handler.stateAfterTaskbarRestart(self.state);
        try self.refresh();
    }

    fn refreshIfUsable(self: *AppBar) Error!bool {
        if (self.state == .deinitialized) return false;
        try self.refresh();
        return true;
    }

    fn restoreAfterTaskbarRestartIfUsable(self: *AppBar) Error!bool {
        if (self.state == .deinitialized) return false;
        try self.restoreAfterTaskbarRestart();
        return true;
    }

    fn repositionOrSuspend(self: *AppBar) Error!void {
        self.reposition() catch |err| {
            self.unregisterFromShell();
            return err;
        };
    }

    fn reposition(self: *AppBar) Error!void {
        if (self.is_repositioning) return;
        self.is_repositioning = true;
        defer self.is_repositioning = false;
        const proposed_rect = try geometry.makeProposedRect(self.monitor_rect, self.configuration.edge, self.configuration.thickness);
        self.queryPosition(proposed_rect);
        try self.applyPosition();
    }

    fn queryPosition(self: *AppBar, proposed_rect: win32.RECT) void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.configuration.edge);
        app_bar_data.rc = proposed_rect;
        _ = win32.SHAppBarMessage(win32.ABM_QUERYPOS, &app_bar_data);
        self.placement_rect = geometry.preserveThickness(app_bar_data.rc, self.configuration.edge, self.configuration.thickness);
    }

    fn notifyActivation(self: *AppBar, is_active: bool) void {
        var app_bar_data = makeAppBarData(self.window_handle, 0);
        app_bar_data.lParam = message_handler.appBarActivationLParam(is_active);
        _ = win32.SHAppBarMessage(win32.ABM_ACTIVATE, &app_bar_data);
    }

    fn setFullscreenZOrder(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window_handle, 0);
        const taskbar_state = win32.SHAppBarMessage(win32.ABM_GETSTATE, &app_bar_data);
        const insert_after = fullscreenInsertAfter(taskbar_state);
        const flags = win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(self.window_handle, insert_after, 0, 0, 0, 0, flags).toBool()) return error.WindowZOrderFailed;
    }

    fn handleWindowArrange(self: *AppBar, is_beginning: bool) void {
        if (is_beginning) {
            if (message_handler.shouldHideForWindowArrange(self.is_hidden_for_window_arrange, win32.IsWindowVisible(self.window_handle).toBool())) {
                _ = win32.ShowWindow(self.window_handle, win32.SW_HIDE);
                self.is_hidden_for_window_arrange = true;
            }
            return;
        }
        self.restoreWindowAfterArrange();
    }

    fn restoreWindowAfterArrange(self: *AppBar) void {
        if (!message_handler.shouldShowAfterWindowArrange(self.is_hidden_for_window_arrange)) return;
        self.is_hidden_for_window_arrange = false;
        _ = win32.ShowWindow(self.window_handle, win32.SW_SHOWNOACTIVATE);
    }

    fn applyPosition(self: *AppBar) Error!void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.configuration.edge);
        app_bar_data.rc = self.placement_rect;
        _ = win32.SHAppBarMessage(win32.ABM_SETPOS, &app_bar_data);
        self.placement_rect = app_bar_data.rc;
        const position = try geometry.windowPositionFromRect(self.placement_rect);
        const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(self.window_handle, null, position.x, position.y, position.width, position.height, flags).toBool()) return error.WindowPlacementFailed;
    }
};

const PlacementConfiguration = struct {
    fallback_monitor_index: u32,
    edge: Edge,
    thickness: u32,
    monitor_id: ?MonitorId,
};

fn configurationForMonitor(
    current: PlacementConfiguration,
    selected_monitor: monitor.Monitor,
) PlacementConfiguration {
    var configuration = current;
    configuration.fallback_monitor_index = selected_monitor.index;
    configuration.monitor_id = selected_monitor.id;
    return configuration;
}

fn validatePlacementConfiguration(configuration: PlacementConfiguration, monitor_rect: ?win32.RECT) Error!void {
    const rect = monitor_rect orelse return;
    _ = try geometry.validateThickness(rect, configuration.edge, configuration.thickness);
}

const ConfigurationSnapshot = struct {
    configuration: PlacementConfiguration,
    monitor_rect: win32.RECT,
    placement_rect: win32.RECT,
    was_registered: bool,

    fn fromAppBar(app_bar: *const AppBar) ConfigurationSnapshot {
        return .{
            .configuration = app_bar.configuration,
            .monitor_rect = app_bar.monitor_rect,
            .placement_rect = app_bar.placement_rect,
            .was_registered = app_bar.state == .active,
        };
    }

    fn restore(self: ConfigurationSnapshot, app_bar: *AppBar) void {
        app_bar.configuration = self.configuration;
        app_bar.monitor_rect = self.monitor_rect;
        app_bar.placement_rect = self.placement_rect;
    }
};

const callback_message_name = std.unicode.utf8ToUtf16LeStringLiteral("windows_app_bar.AppBarCallback.v1");
const taskbar_created_message_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated");

fn makeAppBarData(window: WindowHandle, callback_message: Message) win32.APPBARDATA {
    return .{ .cbSize = @sizeOf(win32.APPBARDATA), .hWnd = window, .uCallbackMessage = callback_message, .uEdge = 0, .rc = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, .lParam = 0 };
}

fn fullscreenInsertAfter(taskbar_state: usize) WindowHandle {
    return if (taskbar_state & win32.ABS_ALWAYSONTOP != 0) win32.HWND_TOPMOST else win32.HWND_BOTTOM;
}

test "APPBARDATA contains the ABM_NEW fields required by the Windows SDK" {
    const window: WindowHandle = @ptrFromInt(1);
    const callback_message: Message = 0xc000;
    const app_bar_data = makeAppBarData(window, callback_message);
    try std.testing.expectEqual(@as(u32, @sizeOf(win32.APPBARDATA)), app_bar_data.cbSize);
    try std.testing.expectEqual(window, app_bar_data.hWnd);
    try std.testing.expectEqual(callback_message, app_bar_data.uCallbackMessage);
}

test "fullscreen AppBar Z order follows the taskbar always-on-top state" {
    try std.testing.expectEqual(win32.HWND_BOTTOM, fullscreenInsertAfter(0));
    try std.testing.expectEqual(win32.HWND_TOPMOST, fullscreenInsertAfter(win32.ABS_ALWAYSONTOP));
    try std.testing.expectEqual(win32.HWND_TOPMOST, fullscreenInsertAfter(win32.ABS_ALWAYSONTOP | 1));
}

test "configuration validation rejects invalid thickness before applying it" {
    const monitor_rect = win32.RECT{ .left = 0, .top = 0, .right = 100, .bottom = 50 };
    const configuration = PlacementConfiguration{
        .fallback_monitor_index = 0,
        .edge = .right,
        .thickness = 101,
        .monitor_id = null,
    };

    try std.testing.expectError(error.InvalidThickness, validatePlacementConfiguration(configuration, monitor_rect));
    try validatePlacementConfiguration(configuration, null);
}

test "monitor configuration retains a persistent ID and index fallback" {
    const monitor_id = try MonitorId.fromUtf8("monitor-id");
    const current = PlacementConfiguration{
        .fallback_monitor_index = 0,
        .edge = .bottom,
        .thickness = 100,
        .monitor_id = null,
    };
    const selected_monitor = monitor.Monitor{
        .index = 2,
        .rect = .{ .left = 100, .top = 0, .right = 200, .bottom = 100 },
        .id = monitor_id,
    };

    const configuration = configurationForMonitor(current, selected_monitor);
    try std.testing.expectEqual(@as(u32, 2), configuration.fallback_monitor_index);
    try std.testing.expectEqualStrings("monitor-id", configuration.monitor_id.?.utf8());
    try std.testing.expectEqual(Edge.bottom, configuration.edge);
    try std.testing.expectEqual(@as(u32, 100), configuration.thickness);
}

test "read-only AppBar APIs expose configuration and active reservation" {
    const window: WindowHandle = @ptrFromInt(1);
    const placement_rect = win32.RECT{ .left = -20, .top = 10, .right = 180, .bottom = 110 };
    const app_bar = AppBar{
        .window_handle = window,
        .configuration = .{
            .fallback_monitor_index = 2,
            .edge = .right,
            .thickness = 200,
            .monitor_id = null,
        },
        .callback_message = 0xc000,
        .taskbar_created_message = 0xc001,
        .monitor_rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 },
        .placement_rect = placement_rect,
        .is_repositioning = false,
        .is_hidden_for_window_arrange = false,
        .allows_automatic_reregistration = true,
        .state = .active,
    };
    try std.testing.expectEqual(window, app_bar.window());
    try std.testing.expectEqual(Edge.right, app_bar.edge());
    try std.testing.expectEqual(@as(u32, 2), app_bar.fallbackMonitorIndex());
    try std.testing.expectEqual(@as(u32, 200), app_bar.thickness());
    try std.testing.expectEqual(Status.active, app_bar.status());
    try std.testing.expect(app_bar.isRegistered());
    try std.testing.expectEqual(Rect{ .left = -20, .top = 10, .right = 180, .bottom = 110 }, app_bar.allocatedRect().?);
}

test "configuration snapshots restore the previous AppBar settings" {
    var app_bar = AppBar{
        .window_handle = @ptrFromInt(1),
        .configuration = .{
            .fallback_monitor_index = 1,
            .edge = .left,
            .thickness = 120,
            .monitor_id = null,
        },
        .callback_message = 0xc000,
        .taskbar_created_message = 0xc001,
        .monitor_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .placement_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .is_repositioning = false,
        .is_hidden_for_window_arrange = false,
        .allows_automatic_reregistration = true,
        .state = .active,
    };
    const snapshot = ConfigurationSnapshot.fromAppBar(&app_bar);
    app_bar.configuration.fallback_monitor_index = 2;
    app_bar.configuration.edge = .bottom;
    app_bar.configuration.thickness = 200;
    app_bar.monitor_rect.right = 200;
    snapshot.restore(&app_bar);
    try std.testing.expectEqual(@as(u32, 1), app_bar.fallbackMonitorIndex());
    try std.testing.expectEqual(Edge.left, app_bar.edge());
    try std.testing.expectEqual(@as(u32, 120), app_bar.thickness());
    try std.testing.expectEqual(@as(i32, 100), app_bar.monitor_rect.right);
}

test "reserved rectangle is unavailable while the AppBar is not active" {
    var app_bar = AppBar{
        .window_handle = @ptrFromInt(1),
        .configuration = .{
            .fallback_monitor_index = 0,
            .edge = .bottom,
            .thickness = 100,
            .monitor_id = null,
        },
        .callback_message = 0xc000,
        .taskbar_created_message = 0xc001,
        .monitor_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .placement_rect = .{ .left = 0, .top = 0, .right = 100, .bottom = 100 },
        .is_repositioning = false,
        .is_hidden_for_window_arrange = false,
        .allows_automatic_reregistration = true,
        .state = .suspended,
    };
    try std.testing.expect(app_bar.allocatedRect() == null);
    try std.testing.expectEqual(Status.suspended, app_bar.status());
    try std.testing.expect(!app_bar.isRegistered());
    app_bar.state = .deinitialized;
    try std.testing.expect(app_bar.allocatedRect() == null);
    try std.testing.expectEqual(Status.deinitialized, app_bar.status());
    try std.testing.expect(!app_bar.isRegistered());
}
