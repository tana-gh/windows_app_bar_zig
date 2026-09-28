# zig_windows_app_bar

A Windows-only Zig wrapper for the Win32 AppBar API.

This project will provide a small, idiomatic interface for reserving an edge of a monitor for an application window. It is intended for applications such as docks, sidebars, and desktop panels that must cooperate with the Windows taskbar and other AppBars.

The library is currently at the planning stage; no AppBar functionality has been implemented yet. The implementation will start with registering and removing an AppBar, then add window-message handling and support for monitor, DPI, and taskbar changes.

The intended usage is:

```zig
var app_bar = try AppBar.register(hwnd, monitor_index, .right, width);
defer app_bar.cleanup();

// In the window procedure:
const consumed = try app_bar.handleWindowMessage(message, wparam, lparam);
if (consumed) {
    return 0;
}
```
