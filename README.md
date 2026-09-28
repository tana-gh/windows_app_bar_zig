# zig_windows_app_bar

A Windows-only Zig wrapper for the Win32 AppBar API.

## Requirements

- Zig 0.16.0
- A Windows target

The development environment is Windows 11. The library does not impose a minimum Windows version because the AppBar API has been available in Windows for a long time.

This project will provide a small, idiomatic interface for reserving an edge of a monitor for an application window. It is intended for applications such as docks, sidebars, and desktop panels that must cooperate with the Windows taskbar and other AppBars.

The public API registers an AppBar with `ABM_NEW`, reserves its position with `ABM_SETPOS`, moves the window with `SetWindowPos`, and removes the AppBar with `ABM_REMOVE`. It also handles AppBar position-change notifications and forwards `WM_WINDOWPOSCHANGED` to the AppBar system. Monitor-configuration and DPI changes have not been implemented yet.

`monitor_index` is zero-based in the order reported by `EnumDisplayMonitors`. That order can change when the monitor configuration changes. The requested thickness must be greater than zero and no larger than the selected monitor dimension along the AppBar edge.

The library uses Zig declarations for the small Win32 surface it needs. They are verified against the Windows SDK and link to `Shell32.lib` and `User32.lib`; consumers do not need to configure C header imports.

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
