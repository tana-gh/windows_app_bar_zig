const std = @import("std");
const api = @import("api.zig");
const app_bar_module = @import("app_bar.zig");
const win32 = @import("win32.zig");

const AppBar = app_bar_module.AppBar;

/// Owns an AppBar and routes its window messages through a window subclass.
/// The binding must remain at a stable memory address until detach is called.
pub const AppBarBinding = struct {
    app_bar: ?AppBar = null,
    last_error: ?api.Error = null,
    is_subclass_installed: bool = false,
    target_window_destroyed: bool = false,

    /// Adds an AppBar subclass to window and registers it with the shell.
    pub fn attach(self: *AppBarBinding, target_window: api.WindowHandle, config: api.AppBarConfig) api.Error!void {
        if (self.target_window_destroyed) return error.AppBarWindowDestroyed;
        if (self.is_subclass_installed) return error.AppBarBindingAlreadyAttached;

        self.last_error = null;
        if (!win32.SetWindowSubclass(target_window, subclassProc, subclass_id, @intFromPtr(self)).toBool()) {
            return error.WindowSubclassInstallationFailed;
        }
        self.is_subclass_installed = true;
        errdefer {
            _ = win32.RemoveWindowSubclass(target_window, subclassProc, subclass_id);
            self.is_subclass_installed = false;
        }

        self.app_bar = try AppBar.register(target_window, config);
    }

    /// Removes the AppBar registration and the window subclass.
    pub fn detach(self: *AppBarBinding) void {
        if (!self.is_subclass_installed) return;
        const app_bar = self.app_bar orelse return;
        if (self.app_bar) |*stored_app_bar| stored_app_bar.deinit();
        _ = win32.RemoveWindowSubclass(app_bar.window(), subclassProc, subclass_id);
        self.app_bar = null;
        self.is_subclass_installed = false;
    }

    /// Reports whether the binding is currently attached to a live window.
    pub fn isAttached(self: *const AppBarBinding) bool {
        return self.is_subclass_installed and self.app_bar != null;
    }

    /// Returns the last error raised while processing a window message.
    pub fn lastError(self: *const AppBarBinding) ?api.Error {
        return self.last_error;
    }

    /// Returns the window registered as this AppBar, if attached.
    pub fn window(self: *const AppBarBinding) ?api.WindowHandle {
        const app_bar = self.app_bar orelse return null;
        return app_bar.window();
    }

    /// Returns the requested edge, if attached.
    pub fn edge(self: *const AppBarBinding) ?api.Edge {
        const app_bar = self.app_bar orelse return null;
        return app_bar.edge();
    }

    /// Returns the monitor index used when the monitor ID is unavailable, if attached.
    pub fn fallbackMonitorIndex(self: *const AppBarBinding) ?u32 {
        const app_bar = self.app_bar orelse return null;
        return app_bar.fallbackMonitorIndex();
    }

    /// Returns the requested thickness, if attached.
    pub fn thickness(self: *const AppBarBinding) ?u32 {
        const app_bar = self.app_bar orelse return null;
        return app_bar.thickness();
    }

    /// Returns the AppBar lifecycle status, if attached.
    pub fn status(self: *const AppBarBinding) ?api.Status {
        const app_bar = self.app_bar orelse return null;
        return app_bar.status();
    }

    /// Reports whether the AppBar is currently registered with the shell.
    pub fn isRegistered(self: *const AppBarBinding) bool {
        const app_bar = self.app_bar orelse return false;
        return app_bar.isRegistered();
    }

    /// Shows the AppBar window without activating it.
    pub fn show(self: *AppBarBinding) api.Error!void {
        (try self.mutableAppBar()).show();
    }

    /// Hides the AppBar window while retaining its reserved screen area.
    pub fn hide(self: *AppBarBinding) api.Error!void {
        (try self.mutableAppBar()).hide();
    }

    /// Reports whether the AppBar window is visible.
    pub fn isVisible(self: *const AppBarBinding) bool {
        const app_bar = self.app_bar orelse return false;
        return app_bar.isVisible();
    }

    /// Updates the requested edge and refreshes the AppBar position.
    pub fn setEdge(self: *AppBarBinding, requested_edge: api.Edge) api.Error!void {
        try (try self.mutableAppBar()).setEdge(requested_edge);
    }

    /// Updates the target monitor and refreshes the AppBar position.
    pub fn setMonitor(self: *AppBarBinding, target: api.MonitorTarget) api.Error!void {
        try (try self.mutableAppBar()).setMonitor(target);
    }

    /// Updates the fallback monitor index and refreshes the AppBar position.
    pub fn setFallbackMonitorIndex(self: *AppBarBinding, monitor_index: u32) api.Error!void {
        try (try self.mutableAppBar()).setFallbackMonitorIndex(monitor_index);
    }

    /// Updates the requested thickness and refreshes the AppBar position.
    pub fn setThickness(self: *AppBarBinding, requested_thickness: u32) api.Error!void {
        try (try self.mutableAppBar()).setThickness(requested_thickness);
    }

    /// Returns a fresh candidate rectangle for the currently selected monitor.
    pub fn candidateRect(self: *AppBarBinding) api.Error!api.Rect {
        return (try self.mutableAppBar()).candidateRect();
    }

    /// Returns the shell-allocated rectangle while the AppBar is registered.
    pub fn allocatedRect(self: *const AppBarBinding) ?api.Rect {
        const app_bar = self.app_bar orelse return null;
        return app_bar.allocatedRect();
    }

    /// Re-resolves the monitor and updates the AppBar position.
    pub fn refresh(self: *AppBarBinding) api.Error!void {
        try (try self.mutableAppBar()).refresh();
    }

    /// Removes the AppBar registration and disables automatic re-registration.
    pub fn unregister(self: *AppBarBinding) api.Error!void {
        (try self.mutableAppBar()).unregister();
    }

    /// Re-registers an AppBar that was previously unregistered.
    pub fn reregister(self: *AppBarBinding) api.Error!void {
        try (try self.mutableAppBar()).reregister();
    }

    fn mutableAppBar(self: *AppBarBinding) api.Error!*AppBar {
        if (self.target_window_destroyed) return error.AppBarWindowDestroyed;
        return if (self.app_bar) |*app_bar| app_bar else error.AppBarBindingNotAttached;
    }

    fn subclassProc(
        target_window: api.WindowHandle,
        message: api.Message,
        wparam: api.WParam,
        lparam: api.LParam,
        _: usize,
        reference_data: usize,
    ) callconv(.winapi) isize {
        const self: *AppBarBinding = @ptrFromInt(reference_data);
        if (shouldReleaseForWindowDestruction(message)) {
            self.releaseForTargetWindowDestruction();
            return win32.DefSubclassProc(target_window, message, wparam, lparam);
        }
        if (message == win32.WM_NCDESTROY) {
            self.app_bar = null;
            self.is_subclass_installed = false;
            self.target_window_destroyed = true;
            return win32.DefSubclassProc(target_window, message, wparam, lparam);
        }

        if (self.app_bar) |*app_bar| {
            const consumed = app_bar.handleMessage(message, wparam, lparam) catch |err| {
                self.last_error = err;
                return win32.DefSubclassProc(target_window, message, wparam, lparam);
            };
            if (consumed) return 0;
        }
        return win32.DefSubclassProc(target_window, message, wparam, lparam);
    }

    /// Removes the Shell registration while the target HWND is still valid.
    fn releaseForTargetWindowDestruction(self: *AppBarBinding) void {
        if (self.app_bar) |*app_bar| app_bar.deinit();
        self.app_bar = null;
        self.target_window_destroyed = true;
    }
};

const subclass_id: usize = 1;

fn shouldReleaseForWindowDestruction(message: api.Message) bool {
    return message == win32.WM_DESTROY;
}

test "unattached bindings expose no AppBar or message error" {
    var binding = AppBarBinding{};
    try std.testing.expect(!binding.isAttached());
    try std.testing.expect(binding.status() == null);
    try std.testing.expect(binding.lastError() == null);
    try std.testing.expectError(error.AppBarBindingNotAttached, binding.refresh());
}

test "window destruction makes an attached binding unavailable" {
    var binding = AppBarBinding{ .is_subclass_installed = true };
    binding.releaseForTargetWindowDestruction();

    try std.testing.expect(!binding.isAttached());
    try std.testing.expectError(error.AppBarWindowDestroyed, binding.refresh());
}

test "only WM_DESTROY releases an AppBar before target window destruction" {
    try std.testing.expect(shouldReleaseForWindowDestruction(win32.WM_DESTROY));
    try std.testing.expect(!shouldReleaseForWindowDestruction(win32.WM_NCDESTROY));
    try std.testing.expect(!shouldReleaseForWindowDestruction(win32.WM_DPICHANGED));
}
