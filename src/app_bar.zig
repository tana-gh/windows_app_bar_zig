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
const MonitorSelector = api.MonitorSelector;
const Status = api.Status;
const Error = api.Error;

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
    pub fn register(window_handle: WindowHandle, monitor_selector: MonitorSelector, requested_edge: Edge, requested_thickness: u32) Error!AppBar {
        const selected_monitor = monitor.resolveMonitorSelector(monitor_selector) orelse return error.MonitorNotFound;
        const proposed_rect = try geometry.makeProposedRect(selected_monitor.rect, requested_edge, requested_thickness);
        const callback_message = win32.RegisterWindowMessageW(callback_message_name.ptr);
        if (callback_message == 0) return error.CallbackMessageRegistrationFailed;
        const taskbar_created_message = win32.RegisterWindowMessageW(taskbar_created_message_name.ptr);
        if (taskbar_created_message == 0) return error.TaskbarCreatedMessageRegistrationFailed;

        var app_bar = AppBar{
            .window_handle = window_handle,
            .preferred_monitor_index = selected_monitor.index,
            .edge_value = requested_edge,
            .thickness_pixels = requested_thickness,
            .callback_message = callback_message,
            .taskbar_created_message = taskbar_created_message,
            .monitor_rect = selected_monitor.rect,
            .placement_rect = proposed_rect,
            .monitor_id = selected_monitor.id,
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
        if (self.edge_value == requested_edge) return;
        try self.setConfiguration(self.preferred_monitor_index, requested_edge, self.thickness_pixels, self.monitor_id);
    }

    /// Updates the preferred monitor index and reapplies the AppBar position.
    pub fn setPreferredMonitorIndex(self: *AppBar, monitor_index: u32) Error!void {
        if (self.preferred_monitor_index == monitor_index) return;
        try self.setConfiguration(monitor_index, self.edge_value, self.thickness_pixels, null);
    }

    /// Updates the requested thickness in physical pixels and reapplies the AppBar position.
    pub fn setThickness(self: *AppBar, requested_thickness: u32) Error!void {
        if (self.thickness_pixels == requested_thickness) return;
        try self.setConfiguration(self.preferred_monitor_index, self.edge_value, requested_thickness, self.monitor_id);
    }

    /// Returns a fresh candidate rectangle for the currently selected monitor.
    pub fn proposedRect(self: *const AppBar) Error!Rect {
        const selected_monitor = monitor.resolveMonitor(self.preferred_monitor_index, self.monitor_id) orelse return error.MonitorNotFound;
        return monitor.rectFromWin32(try geometry.makeProposedRect(selected_monitor.rect, self.edge_value, self.thickness_pixels));
    }

    /// Returns the shell-approved rectangle while the AppBar is registered.
    pub fn reservedRect(self: *const AppBar) ?Rect {
        if (self.state != .active) return null;
        return monitor.rectFromWin32(self.placement_rect);
    }

    /// Re-queries, reserves, and applies the AppBar position.
    pub fn reapply(self: *AppBar) Error!void {
        if (!message_handler.canReapply(self.state)) return error.AppBarCleaned;
        self.refreshDisplayConfiguration() catch |err| {
            self.unregisterFromShell();
            return err;
        };
    }

    /// Removes the AppBar registration and disables automatic re-registration.
    pub fn unregister(self: *AppBar) void {
        if (self.state == .cleaned) return;
        self.restoreWindowAfterArrange();
        self.allows_automatic_reregistration = false;
        self.unregisterFromShell();
    }

    /// Re-registers an AppBar that was previously unregistered.
    pub fn reregister(self: *AppBar) Error!void {
        if (!message_handler.canReapply(self.state)) return error.AppBarCleaned;
        self.allows_automatic_reregistration = true;
        if (self.state == .active) return;
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
    pub fn handleWindowMessage(self: *AppBar, message: Message, wparam: WParam, lparam: LParam) Error!bool {
        switch (message_handler.messageAction(self.callback_message, self.taskbar_created_message, message, wparam)) {
            .none => return false,
            .taskbar_created => {
                if (self.state == .cleaned) return false;
                try self.restoreAfterTaskbarRestart();
                return true;
            },
            .display_changed => {
                if (self.state == .cleaned) return false;
                try self.reapply();
                return false;
            },
            .dpi_changed => {
                if (self.state == .cleaned) return false;
                self.window_dpi = message_handler.dpiFromWParam(wparam);
                try self.reapply();
                return true;
            },
            .activation_changed => {
                if (self.state == .active) self.notifyActivation(wparam != win32.WA_INACTIVE);
                return false;
            },
            .window_position_changed => {
                if (self.state != .active or self.is_hidden_for_window_arrange or self.is_repositioning) return false;
                var app_bar_data = makeAppBarData(self.window_handle, 0);
                _ = win32.SHAppBarMessage(win32.ABM_WINDOWPOSCHANGED, &app_bar_data);
                try self.reapply();
                return false;
            },
            .position_changed => {
                if (self.state != .active) return false;
                self.reposition() catch |err| {
                    self.unregisterFromShell();
                    return err;
                };
                return true;
            },
            .state_changed => {
                if (!message_handler.shouldRepositionForStateChange(self.state)) return false;
                self.reposition() catch |err| {
                    self.unregisterFromShell();
                    return err;
                };
                return true;
            },
            .fullscreen_app => {
                if (self.state != .active) return false;
                try self.setFullscreenZOrder(message_handler.fullscreenAppIsOpening(lparam));
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

    fn setConfiguration(self: *AppBar, monitor_index: u32, requested_edge: Edge, requested_thickness: u32, requested_monitor_id: ?MonitorId) Error!void {
        if (!message_handler.canReapply(self.state)) return error.AppBarCleaned;
        const previous = ConfigurationSnapshot.fromAppBar(self);
        self.preferred_monitor_index = monitor_index;
        self.edge_value = requested_edge;
        self.thickness_pixels = requested_thickness;
        self.monitor_id = requested_monitor_id;
        self.reapply() catch |err| {
            previous.restore(self);
            if (previous.state == .active) self.reapply() catch return error.ConfigurationRollbackFailed;
            return err;
        };
    }

    fn refreshDisplayConfiguration(self: *AppBar) Error!void {
        const selected_monitor = monitor.resolveMonitor(self.preferred_monitor_index, self.monitor_id) orelse {
            self.unregisterFromShell();
            return;
        };
        self.monitor_id = selected_monitor.id;
        self.monitor_rect = selected_monitor.rect;
        if (message_handler.shouldAutomaticallyReregister(self.state, self.allows_automatic_reregistration)) {
            try self.registerWithShell();
            return;
        }
        if (self.state == .active) try self.reposition();
    }

    fn restoreAfterTaskbarRestart(self: *AppBar) Error!void {
        self.state = message_handler.stateAfterTaskbarRestart(self.state);
        try self.reapply();
    }

    fn reposition(self: *AppBar) Error!void {
        if (self.is_repositioning) return;
        self.is_repositioning = true;
        defer self.is_repositioning = false;
        const proposed_rect = try geometry.makeProposedRect(self.monitor_rect, self.edge_value, self.thickness_pixels);
        self.queryPosition(proposed_rect);
        try self.applyPosition();
    }

    fn queryPosition(self: *AppBar, proposed_rect: win32.RECT) void {
        var app_bar_data = makeAppBarData(self.window_handle, self.callback_message);
        app_bar_data.uEdge = @intFromEnum(self.edge_value);
        app_bar_data.rc = proposed_rect;
        _ = win32.SHAppBarMessage(win32.ABM_QUERYPOS, &app_bar_data);
        self.placement_rect = geometry.preserveThickness(app_bar_data.rc, self.edge_value, self.thickness_pixels);
    }

    fn notifyActivation(self: *AppBar, is_active: bool) void {
        var app_bar_data = makeAppBarData(self.window_handle, 0);
        app_bar_data.lParam = message_handler.appBarActivationLParam(is_active);
        _ = win32.SHAppBarMessage(win32.ABM_ACTIVATE, &app_bar_data);
    }

    fn setFullscreenZOrder(self: *AppBar, is_opening: bool) Error!void {
        const insert_after: ?WindowHandle = if (is_opening) win32.HWND_BOTTOM else null;
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
        app_bar_data.uEdge = @intFromEnum(self.edge_value);
        app_bar_data.rc = self.placement_rect;
        _ = win32.SHAppBarMessage(win32.ABM_SETPOS, &app_bar_data);
        self.placement_rect = app_bar_data.rc;
        const position = try geometry.windowPositionFromRect(self.placement_rect);
        const flags = win32.SWP_NOZORDER | win32.SWP_NOACTIVATE;
        if (!win32.SetWindowPos(self.window_handle, null, position.x, position.y, position.width, position.height, flags).toBool()) return error.WindowPlacementFailed;
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
        return .{ .preferred_monitor_index = app_bar.preferred_monitor_index, .edge_value = app_bar.edge_value, .thickness_pixels = app_bar.thickness_pixels, .monitor_rect = app_bar.monitor_rect, .placement_rect = app_bar.placement_rect, .monitor_id = app_bar.monitor_id, .state = app_bar.state };
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

const callback_message_name = std.unicode.utf8ToUtf16LeStringLiteral("windows_app_bar.AppBarCallback.v1");
const taskbar_created_message_name = std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated");

fn makeAppBarData(window: WindowHandle, callback_message: Message) win32.APPBARDATA {
    return .{ .cbSize = @sizeOf(win32.APPBARDATA), .hWnd = window, .uCallbackMessage = callback_message, .uEdge = 0, .rc = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 }, .lParam = 0 };
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
